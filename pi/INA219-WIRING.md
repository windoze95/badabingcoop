# INA219 wiring + setup (optional battery telemetry)

This is OPTIONAL. The status reporter works fine without it (reports
`battery: null`). Enable it only after the sensor is wired and verified.

## What it measures

The INA219 is a high-side current/voltage monitor. We put it on the **pack side**
of the power chain so `status.json` reports true LiFePO4 voltage and the rough
state-of-charge percentage derived from it:

```
LiFePO4 pack (+) ──► [ INA219 VIN+ ]──(internal 0.1Ω shunt)──[ VIN- ] ──► buck converter IN(+) ──► Pi 5V
LiFePO4 pack (−) ───────────────────────────────────────────────────────► buck converter IN(−) / common GND
```

- Current flows **through** the shunt: pack → `VIN+` → `VIN-` → load (the buck).
- The INA219 measures the small voltage drop across that shunt to compute
  current, and the bus-voltage pin (`V-`/`VIN-`) to compute voltage. The reader
  prints that bus voltage; with a 0.1 Ω shunt the drop is only tens of mV at a
  few hundred mA, so bus voltage ≈ pack voltage — close enough for SoC.
- The buck converter then steps the pack voltage down to a clean 5 V for the Pi.
  The INA219 sees the **input** (pack) side, not the regulated 5 V — that is
  deliberate, because pack voltage is what tells you the battery's charge state.

## I2C connections to the Raspberry Pi (3.3 V logic — do NOT use 5 V)

The INA219's logic/I2C side runs at 3.3 V. Use the Pi's 3.3 V pin, never 5 V,
for VCC and the pull-ups.

| INA219 pin | Pi pin (BCM) | Pi physical pin | Notes                                   |
|------------|--------------|-----------------|-----------------------------------------|
| VCC        | 3V3          | pin 1           | sensor logic supply (3.3 V, NOT 5 V)    |
| GND        | GND          | pin 6           | common ground with the Pi               |
| SDA        | GPIO2 / SDA1 | pin 3           | I2C data (board has on-board pull-ups)  |
| SCL        | GPIO3 / SCL1 | pin 5           | I2C clock                               |
| VIN+       | —            | —               | to **battery +** (pack side)            |
| VIN-       | —            | —               | to **load +** (buck converter input +)  |

Most INA219 breakouts (Adafruit and clones) include the 0.1 Ω shunt and SDA/SCL
pull-ups on-board, so no external resistors are needed.

### I2C address

Default address is **0x40** (both A0 and A1 solder jumpers open / tied low).
Bridge A0/A1 to change it (0x41/0x44/0x45…) if 0x40 collides with another
device. Set `INA219_ADDR` in `badabing-status.env` to match.

## Enable I2C and verify

```bash
sudo raspi-config        # Interface Options -> I2C -> Enable   (or: dtparam=i2c_arm=on)
sudo reboot

sudo apt-get install -y i2c-tools
i2cdetect -y 1           # the INA219 should show up at 0x40 (or your jumper addr)

# The reader talks to the INA219 over smbus2 directly (no archived Adafruit-GPIO,
# no PEP 668 / externally-managed-environment fight on Bookworm):
sudo apt install -y python3-smbus2
# Fallback ONLY if your image lacks that package:
#   sudo pip3 install --break-system-packages smbus2
```

Quick standalone test of the bundled reader:

```bash
INA219_ADDR=0x40 INA219_SHUNT_OHMS=0.1 INA219_MAX_AMPS=3.0 \
  /usr/local/bin/badabing-ina219.py
# prints e.g.:  13.184 421.9      (volts  milliamps)
```

## Turn it on in the reporter

In `/etc/badabing/badabing-status.env`:

```ini
BATTERY_ENABLE=1
INA219_ADDR=0x40
INA219_SHUNT_OHMS=0.1
INA219_MAX_AMPS=3.0
BATT_FULL_V=13.4     # tune to YOUR pack (4S LiFePO4 ≈ 13.4 V full)
BATT_EMPTY_V=12.0    # 4S LiFePO4 ≈ 12.0 V near-empty
```

Then `sudo systemctl restart badabing-status.timer`. Within ~15 s,
`status.json` will carry a `"battery": { "voltage": …, "current_ma": …,
"percent": … }` block instead of `null`.

## Notes / gotchas

- The percentage is a **rough** resting-voltage estimate, not a coulomb-counted
  SoC. LiFePO4 has a very flat discharge curve, so treat percent as a coarse
  fuel gauge; voltage is the more honest number. Tune `BATT_FULL_V` /
  `BATT_EMPTY_V` to your cell count and observed rest voltages.
- Current sign depends on which way you wired VIN+/VIN-. If `current_ma` reads
  negative under load, swap your interpretation (or the wiring) — it does not
  affect the voltage/percent fields.
- `INA219_MAX_AMPS` sizes the current resolution (`current_lsb = max_amps /
  32768`) and the calibration register. Set it a little above your real peak
  draw: too low clips/over-reads at peak, too high coarsens resolution. The
  voltage/percent fields are unaffected by this setting.
- Keep `BATTERY_ENABLE=0` on any Pi without the sensor — with it off the reporter
  never touches I2C, so a missing sensor can't slow down or error a status tick.
