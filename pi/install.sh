#!/usr/bin/env bash
# =============================================================================
# pi/install.sh
#
# Install the Bada Bing coop-cam software ON the Raspberry Pi (Raspberry Pi OS
# Bookworm). Run from a checkout of this repo, as root:
#
#   sudo bash pi/install.sh                 # core: stream + power-tune + status
#   sudo bash pi/install.sh --jukebox       # + Bluetooth/MPD/PipeWire jukebox
#   sudo bash pi/install.sh --battery       # + INA219 battery telemetry deps
#   sudo bash pi/install.sh --jukebox --battery
#
# CORE (always): rpicam/ffmpeg capture+push, power tuning, and the status
# reporter that pushes status.json to the droplet over WireGuard.
#
# Idempotent: safe to re-run. It copies scripts/units/env from this repo to
# their canonical /usr/local/bin, /etc/badabing, /etc/systemd/system targets,
# sets perms (env files with secrets -> 0600), and enables the services. It does
# NOT overwrite an existing /etc/badabing/*.env (so it never clobbers your filled
# secrets) — it seeds the file only if missing.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

DO_JUKEBOX=0
DO_BATTERY=0

usage() {
    cat <<EOF
Usage: sudo bash pi/install.sh [--jukebox] [--battery]

  --jukebox   Also install the Bluetooth speaker + MPD + PipeWire "classical
              jukebox" subsystem (scripts, units, badabing-music.env) and run
              the headless PipeWire setup. Reminds you to pair the speaker.
  --battery   Also install the INA219 battery-telemetry deps (i2c-tools,
              python3-smbus2) + the reader CLI, and remind you to set
              BATTERY_ENABLE=1 in badabing-status.env.
  -h, --help  Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --jukebox) DO_JUKEBOX=1 ;;
        --battery) DO_BATTERY=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

log()  { echo "[pi-install] $*"; }
warn() { echo "[pi-install] WARNING: $*" >&2; }
die()  { echo "[pi-install] ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "must run as root (sudo bash $0)"

export DEBIAN_FRONTEND=noninteractive

# install_bin SRC -> /usr/local/bin/<basename>, 0755.
install_bin() {
    local src="$1"
    [[ -f "$src" ]] || die "missing file: $src"
    install -m 0755 "$src" "/usr/local/bin/$(basename "$src")"
}
# install_unit SRC -> /etc/systemd/system/<basename>, 0644.
install_unit() {
    local src="$1"
    [[ -f "$src" ]] || die "missing unit: $src"
    install -m 0644 "$src" "/etc/systemd/system/$(basename "$src")"
}
# seed_env SRC DSTNAME MODE: copy into /etc/badabing only if absent (never
# clobber an operator-filled secret); chmod MODE either way.
seed_env() {
    local src="$1" name="$2" mode="$3" dst="/etc/badabing/$2"
    [[ -f "$src" ]] || die "missing env: $src"
    if [[ -f "$dst" ]]; then
        log "  keeping existing $dst (not overwriting your filled values)"
    else
        install -m "$mode" "$src" "$dst"
        log "  seeded $dst (FILL its placeholders)"
    fi
    chmod "$mode" "$dst"
}

install -d -m 0755 /etc/badabing

# =============================================================================
log "CORE: capture/encode deps"
# =============================================================================
apt-get update -y
# rpicam-apps provides rpicam-vid on Bookworm; ffmpeg muxes the RTSP push; jq is
# used by the status reporter. openssh-client provides ssh/ssh-keygen for the
# rrsync status push; rsync does the push itself.
apt-get install -y --no-install-recommends \
    rpicam-apps ffmpeg jq rsync openssh-client

# =============================================================================
log "CORE: stream service"
# =============================================================================
install_bin  "${SCRIPT_DIR}/badabing-stream.sh"
install_unit "${SCRIPT_DIR}/badabing-stream.service"
# Contains the publish password -> 0600.
seed_env "${SCRIPT_DIR}/badabing-stream.env" "badabing-stream.env" 0600

# =============================================================================
log "CORE: power tuning"
# =============================================================================
install_bin  "${SCRIPT_DIR}/badabing-power-tune.sh"
install_unit "${SCRIPT_DIR}/badabing-power-tune.service"

# =============================================================================
log "CORE: status reporter (status.json -> droplet over WireGuard)"
# =============================================================================
install_bin  "${SCRIPT_DIR}/badabing-status.sh"
# The INA219 reader is referenced by the status env (BATTERY) but is harmless to
# install in the core path (it is only invoked when BATTERY_ENABLE=1).
install_bin  "${SCRIPT_DIR}/badabing-ina219.py"
install_unit "${SCRIPT_DIR}/badabing-status.service"
install_unit "${SCRIPT_DIR}/badabing-status.timer"
# No secret in this env, but it points at the deploy key path -> 0644 is fine.
seed_env "${SCRIPT_DIR}/badabing-status.env" "badabing-status.env" 0644
# The deploy key dir; the key itself is generated below if absent.
install -d -m 0700 /etc/badabing/keys
if [[ ! -f /etc/badabing/keys/coopstatus_ed25519 ]]; then
    log "  generating unattended deploy keypair /etc/badabing/keys/coopstatus_ed25519"
    ssh-keygen -t ed25519 -N '' -C 'coopstatus@coop-pi' \
        -f /etc/badabing/keys/coopstatus_ed25519 >/dev/null
    chmod 600 /etc/badabing/keys/coopstatus_ed25519
else
    log "  deploy key already present; keeping it"
fi

# =============================================================================
log "CORE: enabling services"
# =============================================================================
systemctl daemon-reload
systemctl enable --now badabing-power-tune.service || warn "power-tune failed; see journalctl -u badabing-power-tune"
systemctl enable --now badabing-stream.service     || warn "stream failed; check the camera + badabing-stream.env (RTSP_PASS)"
systemctl enable --now badabing-status.timer       || warn "status timer failed; see journalctl -u badabing-status"

# =============================================================================
if [[ $DO_JUKEBOX -eq 1 ]]; then
    log "JUKEBOX: Bluetooth + MPD + PipeWire"
    # The headless PipeWire setup installs pipewire/wireplumber/bluez/mpd/mpc and
    # the system pipewire units; run it first so MPD's deps + sink exist.
    [[ -f "${SCRIPT_DIR}/badabing-pipewire-setup.sh" ]] || die "missing badabing-pipewire-setup.sh"
    bash "${SCRIPT_DIR}/badabing-pipewire-setup.sh"

    # MPD config + music/playlist library dirs.
    install -m 0644 "${SCRIPT_DIR}/mpd.conf" /etc/mpd.conf
    install -d -o mpd -g audio /srv/badabing/music /srv/badabing/playlists 2>/dev/null \
        || install -d /srv/badabing/music /srv/badabing/playlists
    # A starter playlist if shipped.
    [[ -f "${SCRIPT_DIR}/badabing-starter-playlist.m3u" ]] && \
        install -m 0644 "${SCRIPT_DIR}/badabing-starter-playlist.m3u" \
            /srv/badabing/playlists/badabing-starter-playlist.m3u

    # Jukebox helper scripts.
    for s in badabing-bt-setup.sh badabing-bt-connect.sh badabing-audio-route.sh \
             badabing-mpd-init.sh badabing-nowplaying.sh fetch-music.sh; do
        install_bin "${SCRIPT_DIR}/${s}"
    done

    # Jukebox units (the stock mpd.service/socket are disabled in favour of ours).
    systemctl disable --now mpd.service mpd.socket 2>/dev/null || true
    for u in badabing-mpd.service badabing-mpd-init.service \
             badabing-bt-connect.service badabing-nowplaying.service; do
        install_unit "${SCRIPT_DIR}/${u}"
    done

    # Music env (BT MAC etc.) — seed if missing.
    seed_env "${SCRIPT_DIR}/badabing-music.env" "badabing-music.env" 0644

    systemctl daemon-reload
    systemctl enable --now badabing-bt-connect.service  || warn "bt-connect failed (pair the speaker first)"
    systemctl enable --now badabing-mpd.service         || warn "mpd failed; see journalctl -u badabing-mpd"
    systemctl enable --now badabing-nowplaying.service  || warn "nowplaying failed; see journalctl -u badabing-nowplaying"
    systemctl enable --now badabing-mpd-init.service    || warn "mpd-init failed; re-run after the speaker connects"

    cat <<'EOF'
[pi-install] JUKEBOX next steps:
  1) Set BT_SPEAKER_MAC (and BT_CONTROLLER) in /etc/badabing/badabing-music.env.
  2) Pair + trust the speaker ONCE (put it in pairing mode), over SSH:
       sudo /usr/local/bin/badabing-bt-setup.sh
  3) Add music:  sudo /usr/local/bin/fetch-music.sh   (or copy files into
     /srv/badabing/music), then:  mpc update
  Reminder: on the Pi Zero 2 W use a USB Bluetooth dongle so A2DP audio does not
  fight the camera's Wi-Fi (see badabing-bt-setup.sh).
EOF
fi

# =============================================================================
if [[ $DO_BATTERY -eq 1 ]]; then
    log "BATTERY: INA219 telemetry deps"
    apt-get install -y --no-install-recommends i2c-tools python3-smbus2
    # The reader CLI is already installed in the core step; ensure it is present.
    install_bin "${SCRIPT_DIR}/badabing-ina219.py"
    cat <<'EOF'
[pi-install] BATTERY next steps:
  1) Enable I2C:  sudo raspi-config -> Interface Options -> I2C -> enable
     (or set dtparam=i2c_arm=on), then reboot.
  2) Wire the INA219 (see pi/INA219-WIRING.md) and confirm it appears:
       i2cdetect -y 1        # expect 0x40
  3) In /etc/badabing/badabing-status.env set BATTERY_ENABLE=1 (and tune
     BATT_FULL_V / BATT_EMPTY_V for your pack), then:
       sudo systemctl restart badabing-status.timer
EOF
fi

# =============================================================================
cat <<EOF

=================================  DONE  ====================================
Core coop-cam software installed. NEXT STEPS:

  1) Fill /etc/badabing/badabing-stream.env -> RTSP_PASS (the MediaMTX publish
     password), then:  sudo systemctl restart badabing-stream.service

  2) Authorize this Pi's status pushes on the DROPLET. Copy this Pi's PUBLIC key
     and run setup-coopstatus.sh there:
       --- this Pi's coopstatus public key ---
$(cat /etc/badabing/keys/coopstatus_ed25519.pub 2>/dev/null || echo '  (key not found)')
       ---------------------------------------
     On the droplet:
       sudo PI_PUBKEY="ssh-ed25519 AAAA... coopstatus@coop-pi" \\
            droplet/ssh/setup-coopstatus.sh

  3) Apply the PERSISTENT power tweaks once and reboot (LEDs/HDMI/BT off in
     config.txt) — optional but recommended for the solar budget:
       sudo /usr/local/bin/badabing-power-tune.sh --persist && sudo reboot

  Check:  systemctl status badabing-stream badabing-status.timer
          journalctl -u badabing-stream -f
=============================================================================
EOF
