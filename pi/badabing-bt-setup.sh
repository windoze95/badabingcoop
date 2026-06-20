#!/usr/bin/env bash
#
# /usr/local/bin/badabing-bt-setup.sh
#
# ONE-TIME interactive helper: pair + trust the Bluetooth speaker so the boot
# auto-reconnect service (badabing-bt-connect.service) can reconnect to it
# unattended forever after. Run this ONCE, by hand, over SSH.
#
#   sudo /usr/local/bin/badabing-bt-setup.sh
#
# It reads BT_SPEAKER_MAC / BT_CONTROLLER from /etc/badabing/badabing-music.env.
#
# =============================================================================
# READ THIS FIRST — Wi-Fi / Bluetooth COEXISTENCE on the Pi Zero 2 W
# =============================================================================
# The Pi Zero 2 W has a SINGLE 2.4 GHz combo radio shared between Wi-Fi and
# Bluetooth. This coop Pi is ALREADY streaming H.264 video over 2.4 GHz Wi-Fi
# 24/7 (see badabing-stream.*). Running Bluetooth A2DP on the SAME on-board radio
# at the same time is a documented worst case: the audio stutters/cracks to the
# point of being unusable while Wi-Fi is busy, and the Zero 2 W has NO 5 GHz band
# to escape to. Raspberry Pi closed the upstream bug as "not planned".
#   refs: github.com/raspberrypi/linux/issues/5293
#         forums.raspberrypi.com/viewtopic.php?t=344671
#
# MITIGATIONS, best first:
#
#   1) USB BLUETOOTH DONGLE on its own controller (RECOMMENDED).
#      A cheap CSR8510-class USB Bluetooth adapter gives Bluetooth a SEPARATE
#      radio/antenna, so A2DP no longer fights the camera's Wi-Fi for airtime.
#      Plug it into the Zero 2 W's USB OTG port (via a micro-USB OTG adapter or
#      a USB hub if the camera also needs USB). WHICH hciX it becomes depends on
#      whether on-board BT is disabled:
#        * with power-tune's `dtoverlay=disable-bt` ACTIVE (the recommended combo)
#          the dongle is the ONLY controller and is hci0;
#        * with on-board BT still enabled, the dongle is usually hci1 — but
#          enumeration order is NOT guaranteed, so VERIFY with `bluetoothctl list`.
#      Point BT_CONTROLLER at the right adapter in badabing-music.env (the
#      scripts resolve hciX -> the controller's MAC). A Class 1 dongle also gives
#      more range. NOTE: this DOES draw from the Pi's solar budget (~0.1-0.3 W) —
#      the SPEAKER itself is powered separately, but the dongle is on the Pi's
#      5 V rail, so account for it.
#
#   2) USB AUDIO ADAPTER + WIRED/PASSIVE SPEAKER (MOST RELIABLE FALLBACK).
#      Skip Bluetooth entirely: a $5 USB sound card feeds a wired (or small
#      powered/passive) speaker. No 2.4 GHz contention at all, no pairing, no
#      reconnect logic, nothing to drop. If unattended reliability matters more
#      than going wireless, do THIS. (The on-board 3.5 mm jack does not exist on
#      the Zero 2 W and the power-tune script sets dtparam=audio=off anyway, so a
#      USB DAC is the wired path here.) MPD just outputs to the ALSA/Pulse sink
#      for the USB card — the player/now-playing pieces of this build are
#      identical; only the audio sink changes.
#
#   3) If you MUST use on-board Bluetooth: drop the camera bitrate/framerate (a
#      lighter Wi-Fi load coexists slightly better) and accept occasional
#      dropouts. Not recommended for an unattended box.
#
# HEADS-UP — badabing-power-tune.sh and Bluetooth + audio.
#   That script writes `dtoverlay=disable-bt` and `dtparam=audio=off` to
#   config.txt. Its runtime pass USED to stop/disable bluetooth on EVERY boot;
#   it now SKIPS that whenever badabing-bt-connect.service is enabled (so it no
#   longer fights the music feature). You still need to set things up correctly:
#     * If using a USB DONGLE: leaving `disable-bt` is actually FINE and even
#       desirable (it kills the on-board radio so it can't contend) — the dongle
#       is a separate controller and is unaffected. But you MUST enable the
#       bluetooth.service (the daemon), which a camera-only power-tune run had
#       disabled. `unmask` is harmless even if it was only disabled, not masked:
#           sudo systemctl unmask bluetooth
#           sudo systemctl enable --now bluetooth
#       NOTE: with disable-bt the dongle is the SOLE controller and is hci0 — set
#       BT_CONTROLLER=hci0 in badabing-music.env (the default).
#     * If using ON-BOARD Bluetooth: remove `dtoverlay=disable-bt` from
#       /boot/firmware/config.txt, enable hciuart + bluetooth, and reboot; set
#       BT_CONTROLLER to the on-board adapter (hci0 if it's the only one).
#     * Audio: `dtparam=audio=off` only disables the (non-existent on Zero 2 W)
#       on-board audio; Bluetooth A2DP and USB DACs are unaffected by it, so you
#       can leave it. PipeWire is the sink either way.
# =============================================================================
set -euo pipefail

ENV_FILE="${BADABING_ENV_FILE:-/etc/badabing/badabing-music.env}"
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a; source "$ENV_FILE"; set +a
fi

BT_SPEAKER_MAC="${BT_SPEAKER_MAC:-}"
BT_SPEAKER_NAME="${BT_SPEAKER_NAME:-Bluetooth speaker}"
BT_CONTROLLER="${BT_CONTROLLER:-hci0}"

log() { echo "[badabing-bt-setup] $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

[[ $EUID -eq 0 ]] || die "run me with sudo (need bluetoothctl + service control)"
command -v bluetoothctl >/dev/null 2>&1 || die "bluetoothctl not found (apt install bluez)"

if [[ ! "$BT_SPEAKER_MAC" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ || "$BT_SPEAKER_MAC" == "AA:BB:CC:DD:EE:FF" ]]; then
    die "set a real BT_SPEAKER_MAC in $ENV_FILE first (run 'bluetoothctl scan on' with the speaker in pairing mode to find it)"
fi

# Make sure the bluetooth daemon is actually running (power-tune may have masked
# it). We do NOT silently unmask — we tell the user, because that is a power
# decision, but we do refuse to continue if the daemon is down.
if ! systemctl is-active --quiet bluetooth; then
    die "bluetooth.service is not active. If badabing-power-tune masked it, run:
         sudo systemctl unmask bluetooth && sudo systemctl enable --now bluetooth
       then re-run this script."
fi

log "using controller $BT_CONTROLLER, speaker $BT_SPEAKER_MAC ($BT_SPEAKER_NAME)"
log "make sure the speaker is POWERED ON and in PAIRING mode now."

# Select the desired controller (matters when both on-board hci0 and a USB
# dongle are present). `select` takes the controller MAC, not hciX, so map.
# CRITICAL: `select` does NOT persist across separate bluetoothctl invocations,
# so EVERY invocation below must re-issue it (sel) or pair/connect silently hit
# the default controller (usually on-board hci0), defeating the dongle mitigation.
# NOTE on enumeration: if config.txt has `dtoverlay=disable-bt` (power-tune
# default) the on-board radio is gone, so the USB dongle is the ONLY controller
# and is hci0 — set BT_CONTROLLER=hci0 in that case (see badabing-music.env).
CTRL_MAC="$(bluetoothctl list 2>/dev/null | awk -v c="$BT_CONTROLLER" '$0 ~ c {print $2}' | head -n1 || true)"
if [[ -z "$CTRL_MAC" ]]; then
    log "WARNING: no controller matched '$BT_CONTROLLER' in 'bluetoothctl list'."
    log "         Available controllers:"
    bluetoothctl list 2>/dev/null | sed 's/^/           /' >&2 || true
    log "         Falling back to the default controller. If you have a USB dongle,"
    log "         set BT_CONTROLLER to the right hciX (with disable-bt it is hci0)."
fi

# Emit a `select <ctrl-mac>` line iff we resolved one (used at the top of every
# piped bluetoothctl block so the controller choice actually sticks).
sel() { [[ -n "$CTRL_MAC" ]] && printf 'select %s\n' "$CTRL_MAC"; }

bt() { bluetoothctl "$@"; }

log "powering on the adapter and enabling the agent..."
{
    sel
    echo "power on"
    echo "agent on"
    echo "default-agent"
    echo "pairable on"
    # We are the A2DP SOURCE (we connect OUT to a speaker), so we do NOT need to
    # stay discoverable; keep it off to reduce 2.4 GHz chatter.
    echo "discoverable off"
    sleep 1
} | bt >/dev/null 2>&1 || true

log "scanning 12 s for the speaker..."
{ sel; echo "scan on"; sleep 12; echo "scan off"; } | bt >/dev/null 2>&1 || true

log "pairing..."
{ sel; echo "pair $BT_SPEAKER_MAC"; sleep 6; } | bt 2>&1 | sed 's/^/  bt> /' || true

log "trusting (so the boot service can reconnect WITHOUT a pairing agent)..."
{ sel; echo "trust $BT_SPEAKER_MAC"; sleep 2; } | bt 2>&1 | sed 's/^/  bt> /' || true

log "connecting to verify..."
{ sel; echo "connect $BT_SPEAKER_MAC"; sleep 6; } | bt 2>&1 | sed 's/^/  bt> /' || true

# Verify it actually paired + trusted; that is what auto-reconnect relies on.
INFO="$(bluetoothctl info "$BT_SPEAKER_MAC" 2>/dev/null || true)"
echo "$INFO" | sed 's/^/  /'

if echo "$INFO" | grep -q "Paired: yes" && echo "$INFO" | grep -q "Trusted: yes"; then
    log "SUCCESS: speaker is Paired + Trusted. Enable the auto-reconnect service:"
    log "  sudo systemctl enable --now badabing-bt-connect.service"
    if echo "$INFO" | grep -q "Connected: yes"; then
        log "It is also Connected now — test audio with: speaker-test -c2 -twav  (Ctrl-C to stop)"
    fi
else
    die "pairing/trust did not complete. Put the speaker back in pairing mode and re-run."
fi
