#!/usr/bin/env bash
#
# /usr/local/bin/badabing-pipewire-setup.sh
#
# Run PipeWire + WirePlumber as SYSTEM services on a headless Pi (no logged-in
# user / no desktop session). This is what lets MPD make sound at boot with
# nobody logged in.
#
# Background:
#   On a normal Raspberry Pi OS desktop, PipeWire/WirePlumber run as per-USER
#   services and only exist while that user has a session. A headless solar coop
#   box has no graphical login, so we instead run ONE system-wide PipeWire under
#   a dedicated service account, with its runtime socket in /run/pipewire and a
#   pipewire-pulse socket in /run/pulse. MPD (also a system daemon) then connects
#   via the Pulse compat layer.  refs in badabing-pipewire-system notes.
#
# TWO headless gotchas this script handles (both are mandatory or there is NO
# sound and NO Bluetooth sink — verified against current PipeWire/WirePlumber):
#   1) D-BUS SESSION BUS. PipeWire/WirePlumber/RTKit/BlueZ integration all need a
#      *session* bus, which normally only exists inside a login session. We start
#      a private dbus-daemon --session for the 'pipewire' user and hand every
#      unit DBUS_SESSION_BUS_ADDRESS. Without this, wireplumber exits immediately.
#   2) BLUEZ SEAT MONITORING. WirePlumber's BlueZ monitor only exposes audio
#      nodes for devices on the *active logind seat*; a headless box has no active
#      seat, so the speaker connects but NO bluez sink node ever appears (and
#      badabing-audio-route.sh would find nothing). We disable seat monitoring in
#      a WirePlumber drop-in so A2DP nodes appear without a graphical session.
#
# Run ONCE:
#   sudo /usr/local/bin/badabing-pipewire-setup.sh
#   sudo systemctl enable --now badabing-pipewire.service badabing-wireplumber.service
#
# NOTE: If you'd rather keep it simple and DO have a desktop / autologin user,
# you can skip all of this: enable the per-user services instead
#   ( systemctl --user enable --now pipewire pipewire-pulse wireplumber )
# and set the badabing-mpd.service XDG_RUNTIME_DIR / PULSE_* env to that user's
# /run/user/<uid>. The system-service path here is the robust headless option.
#
set -euo pipefail
log() { echo "[badabing-pipewire-setup] $*" >&2; }
[[ $EUID -eq 0 ]] || { log "run with sudo"; exit 1; }

# --- 1) Packages -------------------------------------------------------------
log "installing PipeWire + WirePlumber + Bluetooth SPA + tools"
apt-get update -qq
# dbus-daemon provides the session bus we start by hand for the headless user.
apt-get install -y --no-install-recommends \
    pipewire pipewire-pulse wireplumber libspa-0.2-bluetooth \
    pulseaudio-utils bluez mpd mpc rtkit jq dbus

# --- 2) Dedicated service user ----------------------------------------------
# Audio device + RT scheduling + Bluetooth + dbus group membership.
if ! id pipewire >/dev/null 2>&1; then
    log "creating 'pipewire' system user"
    useradd --system --home /run/pipewire --shell /usr/sbin/nologin pipewire
fi
for grp in audio bluetooth rtkit; do
    getent group "$grp" >/dev/null 2>&1 && usermod -aG "$grp" pipewire || true
done
# Let MPD reach the pipewire-pulse socket by sharing the group.
getent group pipewire >/dev/null 2>&1 && usermod -aG pipewire mpd 2>/dev/null || true

# --- 3) Real-time limits -----------------------------------------------------
cat > /etc/security/limits.d/99-badabing-pipewire.conf <<'EOF'
pipewire   -   rtprio    95
pipewire   -   memlock   4194304
pipewire   -   nice      -19
EOF

# --- 4) BlueZ policy: auto-enable + tolerant re-pairing ----------------------
# Idempotent edits to /etc/bluetooth/main.conf.
MAINCONF=/etc/bluetooth/main.conf
touch "$MAINCONF"
grep -q '^\s*AutoEnable\s*=' "$MAINCONF" \
    && sed -i 's/^\s*AutoEnable\s*=.*/AutoEnable=true/' "$MAINCONF" \
    || printf '\n[Policy]\nAutoEnable=true\n' >> "$MAINCONF"
grep -q '^\s*JustWorksRepairing\s*=' "$MAINCONF" \
    || printf '\n[General]\nJustWorksRepairing=always\n' >> "$MAINCONF"

# --- 4b) WirePlumber: disable BlueZ seat monitoring (headless-critical) -------
# Without this, WirePlumber refuses to create audio nodes for a connected
# Bluetooth device because there is no ACTIVE logind seat on a headless box, so
# the speaker connects but produces NO sink — badabing-audio-route.sh then finds
# nothing. The drop-in lives under /etc/wireplumber/wireplumber.conf.d (the 0.5+
# config path; the old ~/.config/.../*.lua path is obsolete).
install -d /etc/wireplumber/wireplumber.conf.d
cat > /etc/wireplumber/wireplumber.conf.d/50-badabing-headless-bluez.conf <<'EOF'
# Headless: no active logind seat, so allow BlueZ audio nodes regardless of seat.
monitor.bluez.properties = {
  # accept devices even with no active seat
  bluez5.enable-sbc-xq = true
  bluez5.enable-hw-volume = true
}
wireplumber.settings = {
  monitor.bluez.seat-monitoring = false
}
EOF

# --- 5) System service units -------------------------------------------------
log "writing system service units for the dbus session bus + PipeWire stack"

# A private SESSION dbus for the headless 'pipewire' user. Everything else
# depends on this; its socket address is fixed so the other units can point at
# it. dbus-daemon stays in the foreground (--nofork) so systemd supervises it.
cat > /etc/systemd/system/badabing-dbus.service <<'EOF'
[Unit]
Description=Bada Bing — private D-Bus session bus for headless PipeWire
After=network.target

[Service]
Type=simple
User=pipewire
Group=pipewire
RuntimeDirectory=pipewire
RuntimeDirectoryPreserve=yes
Environment=XDG_RUNTIME_DIR=/run/pipewire
ExecStart=/usr/bin/dbus-daemon --session --nofork --nopidfile --address=unix:path=/run/pipewire/bus
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/badabing-pipewire.service <<'EOF'
[Unit]
Description=Bada Bing — PipeWire (system-wide, headless)
After=badabing-dbus.service network.target sound.target
Requires=badabing-dbus.service
Wants=badabing-wireplumber.service

[Service]
Type=simple
User=pipewire
Group=pipewire
RuntimeDirectory=pipewire
RuntimeDirectoryPreserve=yes
Environment=XDG_RUNTIME_DIR=/run/pipewire
Environment=PIPEWIRE_RUNTIME_DIR=/run/pipewire
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/pipewire/bus
ExecStart=/usr/bin/pipewire
Restart=always
RestartSec=3
LimitRTPRIO=95
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/badabing-wireplumber.service <<'EOF'
[Unit]
Description=Bada Bing — WirePlumber (system-wide session manager)
After=badabing-pipewire.service badabing-dbus.service
BindsTo=badabing-pipewire.service
Requires=badabing-dbus.service

[Service]
Type=simple
User=pipewire
Group=pipewire
Environment=XDG_RUNTIME_DIR=/run/pipewire
Environment=PIPEWIRE_RUNTIME_DIR=/run/pipewire
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/pipewire/bus
ExecStart=/usr/bin/wireplumber
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/badabing-pipewire-pulse.service <<'EOF'
[Unit]
Description=Bada Bing — pipewire-pulse (PulseAudio compat for MPD)
After=badabing-pipewire.service badabing-wireplumber.service
BindsTo=badabing-pipewire.service

[Service]
Type=simple
User=pipewire
Group=pipewire
RuntimeDirectory=pulse
RuntimeDirectoryPreserve=yes
Environment=XDG_RUNTIME_DIR=/run/pipewire
Environment=PIPEWIRE_RUNTIME_DIR=/run/pipewire
Environment=PULSE_RUNTIME_PATH=/run/pulse
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/pipewire/bus
ExecStart=/usr/bin/pipewire-pulse
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
log "enabling dbus + PipeWire system services"
systemctl enable --now badabing-dbus.service
systemctl enable --now badabing-pipewire.service badabing-wireplumber.service badabing-pipewire-pulse.service

log "done. Verify with:"
log "  sudo -u pipewire XDG_RUNTIME_DIR=/run/pipewire DBUS_SESSION_BUS_ADDRESS=unix:path=/run/pipewire/bus wpctl status"
log "Then pair the speaker (badabing-bt-setup.sh) and route audio (badabing-audio-route.sh)."
