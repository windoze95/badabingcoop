#!/usr/bin/env bash
#
# /usr/local/bin/badabing-bt-connect.sh
#
# Keep the (already paired + trusted) Bluetooth speaker CONNECTED, forever,
# unattended. Run by badabing-bt-connect.service:
#   * once at boot, and
#   * as a long-lived loop that re-issues `connect` whenever the speaker drops
#     (power cycle, out of range, RF starvation, sleep timeout, etc).
#
# This is the auto-reconnect half of the Bluetooth setup. Pairing/trust is a
# one-time thing done by badabing-bt-setup.sh; this script never pairs, it only
# (re)connects a trusted device, so no pairing agent is required.
#
set -euo pipefail

ENV_FILE="${BADABING_ENV_FILE:-/etc/badabing/badabing-music.env}"
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a; source "$ENV_FILE"; set +a
fi

BT_SPEAKER_MAC="${BT_SPEAKER_MAC:-}"
BT_CONTROLLER="${BT_CONTROLLER:-hci0}"
# How often to check the link, in seconds. 15 s is responsive without spamming
# the radio (each probe is cheap; an actual reconnect only happens on a drop).
CHECK_INTERVAL="${BT_CHECK_INTERVAL:-15}"

log() { echo "[badabing-bt-connect] $*" >&2; }

[[ -n "$BT_SPEAKER_MAC" && "$BT_SPEAKER_MAC" != "AA:BB:CC:DD:EE:FF" ]] \
    || { log "ERROR: BT_SPEAKER_MAC not set in $ENV_FILE"; exit 1; }

# Resolve the controller's own MAC so we can `select` it (relevant when a USB
# dongle coexists with the on-board radio — we must connect on the RIGHT
# controller to dodge Wi-Fi coexistence). A USB dongle can enumerate a few
# seconds AFTER this script starts, so we re-resolve lazily until we find it
# instead of caching an empty value for the life of the process.
CTRL_MAC=""
resolve_ctrl() {
    [[ -n "$CTRL_MAC" ]] && return 0
    CTRL_MAC="$(bluetoothctl list 2>/dev/null | awk -v c="$BT_CONTROLLER" '$0 ~ c {print $2}' | head -n1 || true)"
    [[ -n "$CTRL_MAC" ]] && log "controller $BT_CONTROLLER resolved to $CTRL_MAC"
}

select_ctrl() {
    resolve_ctrl
    [[ -n "$CTRL_MAC" ]] && printf 'select %s\n' "$CTRL_MAC"
}

is_connected() {
    bluetoothctl info "$BT_SPEAKER_MAC" 2>/dev/null | grep -q "Connected: yes"
}

ensure_powered() {
    { select_ctrl; echo "power on"; } | bluetoothctl >/dev/null 2>&1 || true
}

connect_once() {
    # `connect` on a trusted device; bluetoothctl is async so give it a moment.
    { select_ctrl; echo "connect $BT_SPEAKER_MAC"; sleep 6; } \
        | bluetoothctl >/dev/null 2>&1 || true
}

log "auto-reconnect loop for $BT_SPEAKER_MAC on $BT_CONTROLLER (every ${CHECK_INTERVAL}s)"
ensure_powered

# Initial connect (with a few retries — speaker may still be booting at power-on).
for i in 1 2 3 4 5; do
    if is_connected; then break; fi
    log "initial connect attempt $i..."
    connect_once
done
is_connected && log "connected." || log "not connected yet; will keep retrying in the loop."

# Steady-state watchdog. On each tick: if the link is down, power the adapter
# and reconnect. systemd (Restart=always) covers the case where THIS script
# itself dies; this loop covers the far more common case of the SPEAKER dropping
# while the script keeps running.
while true; do
    if ! is_connected; then
        log "link down — reconnecting..."
        ensure_powered
        connect_once
        if is_connected; then
            log "reconnected."
        else
            log "reconnect failed (speaker off / out of range?) — retrying."
        fi
    fi
    sleep "$CHECK_INTERVAL"
done
