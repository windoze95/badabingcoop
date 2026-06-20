#!/usr/bin/env python3
#
# /usr/local/bin/badabing-ina219.py
#
# Tiny CLI that reads an INA219 high-side current/voltage monitor over I2C and
# prints "<bus_voltage_V> <current_mA>" on one line, e.g.:
#
#     13.184 421.9
#
# badabing-status.sh calls this ONLY when BATTERY_ENABLE=1, captures that line,
# and folds it into status.json. If the sensor can't be read we exit non-zero
# and print nothing, so the caller leaves battery fields null.
#
# Hardware: INA219 breakout on the Pi's I2C bus (SDA=GPIO2/pin3, SCL=GPIO3/pin5),
#           default address 0x40. Enable I2C first: `sudo raspi-config` ->
#           Interface Options -> I2C -> enable  (or set dtparam=i2c_arm=on).
#
# Library / dependency choice (IMPORTANT, 2026):
#   We talk to the INA219 registers DIRECTLY via `smbus2`, deliberately NOT via
#   the older `pi-ina219` (chrisb2) PyPI package. Reason: pi-ina219 depends on
#   the ARCHIVED `Adafruit-GPIO` library, which (a) is unmaintained, (b) is only
#   classified up to Python 3.7, and (c) commonly fails on Raspberry Pi OS
#   Bookworm with "Could not determine default I2C bus for platform". Bookworm
#   also ships Python 3.11 under PEP 668 (externally-managed-environment), so a
#   bare `sudo pip3 install pi-ina219` is REFUSED outright. `smbus2` is the path
#   the pi-ina219 maintainer themselves recommend migrating to (issue #28).
#
#   Install smbus2 on Bookworm (pick ONE):
#       sudo apt install -y python3-smbus2          # preferred: system package
#       # or, if that package is unavailable on your image:
#       sudo pip3 install --break-system-packages smbus2
#
#   No raw Adafruit dependency, no venv required, works on the system python.
#
# Register math is straight from the TI INA219 datasheet (SBOS448):
#   * Bus voltage (reg 0x02): (raw >> 3) * 4 mV  -> volts.
#   * Shunt voltage (reg 0x01): signed 16-bit, LSB = 10 uV.
#   * Calibration (reg 0x05) = trunc(0.04096 / (current_lsb * shunt_ohms)).
#   * Current (reg 0x04, signed) * current_lsb -> amps  (after calibration).
# We program calibration from the configured shunt + max current so current()
# returns real amps; current_lsb = max_amps / 32768.
#
# We measure the PACK side: wire the INA219 with VIN+ to battery +, VIN- to the
# load (the buck converter input), GND common. The BUS voltage pin (V-/VIN-)
# then reads the pack voltage downstream of the shunt, which for a tiny shunt
# drop (0.1 ohm * a few hundred mA = tens of mV) is effectively pack voltage and
# is what we want for SoC estimation.
#
# Env (all optional, defaults match a typical Adafruit-style 0.1Ohm breakout):
#   INA219_BUS         I2C bus number              (default 1)
#   INA219_ADDR        7-bit address, hex or dec   (default 0x40)
#   INA219_SHUNT_OHMS  shunt resistance in ohms    (default 0.1)
#   INA219_MAX_AMPS    max expected current (A)    (default 3.0)
#
import os
import sys

# INA219 register addresses (TI datasheet).
_REG_CONFIG = 0x00
_REG_SHUNT_VOLTAGE = 0x01
_REG_BUS_VOLTAGE = 0x02
_REG_CALIBRATION = 0x05
_REG_CURRENT = 0x04

# CONFIG = 16V bus range, gain /8 (+/-320mV), 12-bit bus & shunt ADC,
# continuous shunt+bus mode. = 0x399F (TI datasheet default-ish for 16V/full).
_CONFIG_16V_320MV_12BIT_CONTINUOUS = 0x399F

_BUS_VOLTAGE_LSB_V = 0.004        # 4 mV per bit, after >>3
_SHUNT_VOLTAGE_LSB_V = 0.00001    # 10 uV per bit (unused here but documented)
_CAL_CONSTANT = 0.04096           # TI calibration constant


def _env_float(name, default):
    try:
        return float(os.environ.get(name, default))
    except (TypeError, ValueError):
        return float(default)


def _env_addr(name, default):
    raw = os.environ.get(name)
    if not raw:
        return default
    raw = raw.strip()
    try:
        # Accept "0x40", "64", etc.
        return int(raw, 0)
    except ValueError:
        return default


def _to_signed_16(value):
    """Interpret a 16-bit register value as signed two's complement."""
    if value > 0x7FFF:
        value -= 0x10000
    return value


def _read_register(bus, addr, reg):
    """Read a 16-bit big-endian register (INA219 returns MSB first)."""
    data = bus.read_i2c_block_data(addr, reg, 2)
    return (data[0] << 8) | data[1]


def _write_register(bus, addr, reg, value):
    value &= 0xFFFF
    bus.write_i2c_block_data(addr, reg, [(value >> 8) & 0xFF, value & 0xFF])


def main():
    bus_num = int(_env_float("INA219_BUS", 1))
    addr = _env_addr("INA219_ADDR", 0x40)
    shunt_ohms = _env_float("INA219_SHUNT_OHMS", 0.1)
    max_amps = _env_float("INA219_MAX_AMPS", 3.0)

    try:
        from smbus2 import SMBus
    except ImportError:
        # Library not installed — caller treats this as "no battery telemetry".
        sys.stderr.write(
            "smbus2 not installed; run: sudo apt install -y python3-smbus2 "
            "(or: sudo pip3 install --break-system-packages smbus2)\n"
        )
        return 3

    # current_lsb sizes the smallest representable current step.
    if max_amps <= 0 or shunt_ohms <= 0:
        sys.stderr.write("INA219: shunt_ohms and max_amps must be > 0\n")
        return 2
    current_lsb = max_amps / 32768.0
    cal = int(_CAL_CONSTANT / (current_lsb * shunt_ohms))
    if cal <= 0 or cal > 0xFFFF:
        sys.stderr.write("INA219: computed calibration out of range\n")
        return 2

    try:
        with SMBus(bus_num) as bus:
            # Configure measurement mode and program calibration so the chip's
            # current register reflects real current.
            _write_register(bus, addr, _REG_CONFIG,
                            _CONFIG_16V_320MV_12BIT_CONTINUOUS)
            _write_register(bus, addr, _REG_CALIBRATION, cal)

            # Bus voltage: top 13 bits, 4 mV LSB.
            raw_bus = _read_register(bus, addr, _REG_BUS_VOLTAGE)
            voltage = (raw_bus >> 3) * _BUS_VOLTAGE_LSB_V

            # Current: signed register * current_lsb -> A -> mA.
            # (Re-reading shunt voltage register is not required; the chip
            #  computes the current register from shunt * calibration.)
            raw_current = _to_signed_16(
                _read_register(bus, addr, _REG_CURRENT))
            current_ma = raw_current * current_lsb * 1000.0
    except FileNotFoundError:
        # /dev/i2c-N missing -> I2C not enabled.
        sys.stderr.write(
            "INA219 read failed: /dev/i2c-%d missing (enable I2C via raspi-config)\n"
            % bus_num
        )
        return 1
    except OSError as exc:
        # Bus error, sensor absent at this address, permission, etc.
        sys.stderr.write("INA219 read failed: %s\n" % exc)
        return 1

    # A wildly out-of-range bus voltage usually means nothing is wired / wrong
    # address answered; treat as unreadable so the caller keeps battery null.
    if voltage <= 0.0 or voltage > 60.0:
        sys.stderr.write("INA219: implausible bus voltage %.3f V\n" % voltage)
        return 1

    sys.stdout.write("%.3f %.1f\n" % (voltage, current_ma))
    return 0


if __name__ == "__main__":
    sys.exit(main())
