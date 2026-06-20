#!/usr/bin/env bash
#
# /usr/local/bin/badabing-power-tune.sh
#
# Trim the Raspberry Pi's idle power draw for a solar-powered, headless coop cam.
# Two layers:
#   1) Persistent settings written to /boot/firmware/config.txt (applied at the
#      NEXT boot) - disables HDMI display init, Bluetooth, on-board audio, and
#      tries to disable the ACT/PWR LEDs via device-tree params.
#   2) A runtime pass (this script, run now / at boot via the unit below) that
#      forces the LEDs off and powers down HDMI immediately, because the
#      config.txt LED dtparams are unreliable on the Pi Zero 2 W.
#
# Run once to apply persistent config, then reboot:
#   sudo /usr/local/bin/badabing-power-tune.sh --persist
#   sudo reboot
#
# The systemd oneshot unit (badabing-power-tune.service, below) re-applies the
# RUNTIME bits on every boot so the LEDs stay off.
#
set -euo pipefail

CONFIG_TXT="/boot/firmware/config.txt"   # Bookworm path (was /boot/config.txt on older OS)

log() { echo "[badabing-power-tune] $*" >&2; }

# -----------------------------------------------------------------------------
# Runtime LED control via sysfs.
# On the Pi Zero 2 W the green ACT LED is led0 and there is no separate
# software-controllable power LED. On Pi 4/5 the LEDs may be named ACT/PWR.
# We disable every LED trigger we can find and force brightness to 0.
# -----------------------------------------------------------------------------
runtime_leds_off() {
    for led in /sys/class/leds/*; do
        [[ -e "$led" ]] || continue
        name="$(basename "$led")"
        if [[ -w "$led/trigger" ]]; then
            echo none > "$led/trigger" 2>/dev/null || true
        fi
        if [[ -w "$led/brightness" ]]; then
            echo 0 > "$led/brightness" 2>/dev/null || true
        fi
        log "LED off: $name"
    done
}

# -----------------------------------------------------------------------------
# Runtime HDMI power-down.
# vcgencmd display_power is deprecated/unreliable under Bookworm's Wayland/labwc,
# so we try the KMS-aware path first (write to the DRM connector's force-off via
# /sys is not standardised); in practice on a HEADLESS image no display pipeline
# is started at all. We still attempt vcgencmd as a best-effort no-op-if-absent.
# -----------------------------------------------------------------------------
runtime_hdmi_off() {
    if command -v vcgencmd >/dev/null 2>&1; then
        vcgencmd display_power 0 >/dev/null 2>&1 && log "vcgencmd display_power 0 OK" \
            || log "vcgencmd display_power not effective (expected on Wayland) - relying on config.txt"
    fi
}

# -----------------------------------------------------------------------------
# Persistent config.txt edits. Idempotent: each line is appended under a guard
# block only if the block is not already present.
# -----------------------------------------------------------------------------
persist_config() {
    [[ -w "$CONFIG_TXT" ]] || { log "ERROR: $CONFIG_TXT not writable (run with sudo)"; exit 1; }

    local marker="# >>> badabing power-tune >>>"
    if grep -qF "$marker" "$CONFIG_TXT"; then
        log "config.txt already has the badabing block - leaving it alone"
        return 0
    fi

    log "appending power-tune block to $CONFIG_TXT"
    cat >> "$CONFIG_TXT" <<'EOF'

# >>> badabing power-tune >>>
# Disable on-board Bluetooth (frees the UART and saves idle power).
dtoverlay=disable-bt
# Disable on-board audio (we never play sound).
dtparam=audio=off
# Disable Wi-Fi power-save chatter is handled in NetworkManager, not here.
# Disable the camera/display auto-detect overhead we do not use; keep the
# camera auto-detect ON because we DO use the camera.
camera_auto_detect=1
display_auto_detect=0
# Do not initialise an HDMI display on a headless unit.
# (On KMS/Bookworm, omitting a display pipeline is the effective HDMI-off.)
# Best-effort LED disable via device tree (may be a no-op on Pi Zero 2 W).
dtparam=act_led_trigger=none
dtparam=act_led_activelow=off
dtparam=pwr_led_trigger=none
dtparam=pwr_led_activelow=off
# <<< badabing power-tune <<<
EOF
    log "done - reboot to apply persistent settings"
}

# -----------------------------------------------------------------------------
# Runtime-only knobs that do not need a reboot.
# -----------------------------------------------------------------------------
runtime_misc() {
    if ! command -v systemctl >/dev/null 2>&1; then
        return 0
    fi
    # COEXISTENCE RECONCILIATION (music subsystem):
    # If the Bluetooth-music stack is installed (badabing-bt-connect.service is
    # enabled), we must NOT tear down the bluetooth daemon — the music feature
    # needs it (on-board OR a USB dongle both use bluetooth.service). Disabling it
    # here every boot would silently kill music. So only stop/disable BT when the
    # music stack is absent (a camera-only build).
    if systemctl is-enabled --quiet badabing-bt-connect.service 2>/dev/null; then
        log "badabing-bt-connect.service is enabled -> leaving bluetooth.service UP for music"
        # We can still drop hciuart IF on-board BT is overlaid off (USB dongle
        # path); but to be safe with on-board BT we leave both alone here.
        return 0
    fi
    # Camera-only build: stop + disable Bluetooth to save idle power.
    systemctl stop hciuart bluetooth 2>/dev/null || true
    systemctl disable hciuart bluetooth 2>/dev/null || true
    log "no music stack detected -> bluetooth services stopped/disabled (power save)"
}

main() {
    case "${1:-}" in
        --persist)
            persist_config
            runtime_leds_off
            runtime_hdmi_off
            runtime_misc
            ;;
        --runtime|"")
            # Default: runtime-only pass (what the boot unit calls every boot).
            runtime_leds_off
            runtime_hdmi_off
            runtime_misc
            ;;
        *)
            echo "usage: $0 [--persist | --runtime]" >&2
            exit 2
            ;;
    esac
}

main "$@"
