#!/usr/bin/env bash
#
# /usr/local/bin/badabing-status.sh
#
# Compose a small status.json describing the coop-cam Pi's health plus the
# currently-playing jukebox track, then PUSH it to the droplet's nginx web root
# over the existing outbound WireGuard tunnel using rsync-over-SSH.
#
# Why this shape:
#   * The droplet runs nginx serving STATIC FILES ONLY. There is no app server,
#     no inbound path into the home network. The Pi is the only thing that ever
#     writes; it pushes outbound over WireGuard (Pi 10.10.0.2 -> droplet
#     10.10.0.1) to a single directory the deploy key is locked to (rrsync).
#   * The browser just polls /api/status.json every ~10-15s. No backend logic.
#
# Resilience / idempotency:
#   * Always rebuilds status.json from scratch into a temp file, then atomically
#     renames it locally before pushing (readers never see a half-written file).
#   * The push uses rsync --partial with short ConnectTimeout; if the droplet is
#     briefly unreachable the script exits non-zero and the systemd TIMER simply
#     fires again ~15s later. Nothing accumulates, nothing locks.
#   * Every field degrades gracefully: a sensor or file that can't be read yields
#     null rather than aborting the whole report.
#
# Optional battery telemetry (INA219 over I2C) is gated behind BATTERY_ENABLE so
# a Pi without the sensor produces a valid report with battery: null.
#
set -uo pipefail   # NOTE: deliberately NOT -e — we want best-effort field reads
                   # to fail soft (null) instead of killing the whole report.

# --- Load tunables -----------------------------------------------------------
ENV_FILE="${BADABING_STATUS_ENV_FILE:-/etc/badabing/badabing-status.env}"
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a; source "$ENV_FILE"; set +a
fi

# Where to push. DEPLOY_HOST is the droplet's IN-TUNNEL WireGuard address, never
# its public IP — all traffic rides the tunnel. The remote dir is implied by the
# rrsync forced-command on the droplet, so we sync to ":" (the locked root).
DEPLOY_USER="${DEPLOY_USER:-coopstatus}"
DEPLOY_HOST="${DEPLOY_HOST:-10.10.0.1}"
DEPLOY_SSH_KEY="${DEPLOY_SSH_KEY:-/etc/badabing/keys/coopstatus_ed25519}"
DEPLOY_SSH_PORT="${DEPLOY_SSH_PORT:-22}"
# Remote destination. With an rrsync forced-command locked to /var/www/badabing/api,
# the path we pass is RELATIVE to that locked root. "." = the api/ dir itself.
DEPLOY_REMOTE_PATH="${DEPLOY_REMOTE_PATH:-.}"

# Local staging dir (tmpfs-friendly). status.json is built here then pushed.
STAGE_DIR="${STAGE_DIR:-/run/badabing}"
STATUS_FILE="${STAGE_DIR}/status.json"

# Jukebox now-playing source file. The jukebox (badabing-nowplaying.service)
# writes the current track here. Format is auto-detected:
#   * the project's MPD now-playing JSON {composer,piece,album,state,updated}, or
#   * a generic {artist,title,playing} object, or
#   * a single plain-text "Artist - Title" line.
# Set to empty to disable the music field.
NOWPLAYING_FILE="${NOWPLAYING_FILE:-/run/badabing/nowplaying.json}"

# Stream freshness probe. The streamer (badabing-stream.service) is considered
# "up" if its unit is active AND a recent frame/heartbeat exists. We check the
# systemd unit and, if present, the mtime of a frame-touch file the streamer can
# update. Either signal alone is enough to report stream_up=true.
STREAM_UNIT="${STREAM_UNIT:-badabing-stream.service}"
# Optional file whose mtime tracks the last delivered frame (touch it from the
# stream pipeline if you want a true last-frame age). If unset/missing we fall
# back to the unit's active state + active-enter timestamp.
FRAME_TOUCH_FILE="${FRAME_TOUCH_FILE:-/run/badabing/last-frame}"
# How many seconds since the last frame still counts as "up".
FRAME_MAX_AGE="${FRAME_MAX_AGE:-30}"

# Wireless interface to read RSSI from.
WIFI_IFACE="${WIFI_IFACE:-wlan0}"

# Battery (INA219) telemetry — OPTIONAL. Off by default.
BATTERY_ENABLE="${BATTERY_ENABLE:-0}"
# I2C bus + address of the INA219 (default 0x40 with both address pins to GND).
INA219_BUS="${INA219_BUS:-1}"
INA219_ADDR="${INA219_ADDR:-0x40}"
# Shunt resistor (ohms) on the INA219 breakout. Adafruit/most clones use 0.1.
INA219_SHUNT_OHMS="${INA219_SHUNT_OHMS:-0.1}"
# Max expected current (A) — sizes the ADC range; 3.0 is fine for a small load.
INA219_MAX_AMPS="${INA219_MAX_AMPS:-3.0}"
# LiFePO4 voltage window used to derive a rough percentage. A 4S LiFePO4 pack
# (after the buck it powers the Pi, but we measure the PACK side) rests ~13.3V
# full and ~12.0V near-empty. Tune to your chemistry/cell count.
BATT_FULL_V="${BATT_FULL_V:-13.4}"
BATT_EMPTY_V="${BATT_EMPTY_V:-12.0}"
# Helper that prints the INA219 voltage. Defaults to the bundled python reader.
INA219_READER="${INA219_READER:-/usr/local/bin/badabing-ina219.py}"

# --- Small helpers -----------------------------------------------------------

# JSON-escape a string for safe embedding (handles quotes, backslashes, control
# chars). Prints a *quoted* JSON string, or the literal word null on empty.
json_str() {
    local s="${1-}"
    if [[ -z "$s" ]]; then
        printf 'null'
        return
    fi
    # Escape backslash, double-quote, then strip/replace control chars.
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/ }"
    s="${s//$'\r'/}"
    s="${s//$'\n'/ }"
    printf '"%s"' "$s"
}

# Print a number, or null if the arg is empty / not numeric.
json_num() {
    local n="${1-}"
    if [[ "$n" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
        printf '%s' "$n"
    else
        printf 'null'
    fi
}

# --- Gather fields (each fails soft to empty -> null) ------------------------

# Hostname / timestamp.
HOSTNAME_S="$(hostname 2>/dev/null || true)"
TS_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
TS_EPOCH="$(date -u +%s 2>/dev/null || true)"

# Uptime in seconds (integer).
UPTIME_S=""
if [[ -r /proc/uptime ]]; then
    UPTIME_S="$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null || true)"
fi

# Load average (1/5/15 min).
LOAD1="" ; LOAD5="" ; LOAD15=""
if [[ -r /proc/loadavg ]]; then
    read -r LOAD1 LOAD5 LOAD15 _ < /proc/loadavg 2>/dev/null || true
fi

# CPU temperature in degrees C. Prefer the Pi's vcgencmd; fall back to sysfs.
CPU_TEMP_C=""
if command -v vcgencmd >/dev/null 2>&1; then
    # vcgencmd prints e.g. "temp=48.3'C"
    CPU_TEMP_C="$(vcgencmd measure_temp 2>/dev/null | sed -n "s/temp=\([0-9.]*\).*/\1/p")"
fi
if [[ -z "$CPU_TEMP_C" && -r /sys/class/thermal/thermal_zone0/temp ]]; then
    # sysfs reports milli-degrees C.
    local_milli="$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || true)"
    if [[ "$local_milli" =~ ^[0-9]+$ ]]; then
        CPU_TEMP_C="$(awk -v m="$local_milli" 'BEGIN{printf "%.1f", m/1000}')"
    fi
fi

# WiFi RSSI (dBm) and link quality from /proc/net/wireless (no extra tools).
WIFI_RSSI_DBM=""
if [[ -r /proc/net/wireless ]]; then
    # Columns: iface | status | link | level | noise | ...
    # "level" (col 4) is the signal in dBm (may carry a trailing '.').
    WIFI_RSSI_DBM="$(awk -v ifc="${WIFI_IFACE}:" \
        '$1==ifc {v=$4; gsub(/\./,"",v); print v}' /proc/net/wireless 2>/dev/null || true)"
fi
# Fall back to iw if available and /proc gave nothing.
if [[ -z "$WIFI_RSSI_DBM" ]] && command -v iw >/dev/null 2>&1; then
    WIFI_RSSI_DBM="$(iw dev "$WIFI_IFACE" link 2>/dev/null \
        | sed -n 's/.*signal:[[:space:]]*\(-\?[0-9]*\).*/\1/p')"
fi

# --- Stream up / last-frame age ---------------------------------------------
STREAM_ACTIVE="false"
if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet "$STREAM_UNIT" 2>/dev/null; then
        STREAM_ACTIVE="true"
    fi
fi

LAST_FRAME_AGE=""      # seconds since last frame (null if unknown)
STREAM_UP="false"
if [[ -n "$FRAME_TOUCH_FILE" && -f "$FRAME_TOUCH_FILE" ]]; then
    frame_mtime="$(stat -c %Y "$FRAME_TOUCH_FILE" 2>/dev/null || true)"
    if [[ "$frame_mtime" =~ ^[0-9]+$ && "$TS_EPOCH" =~ ^[0-9]+$ ]]; then
        LAST_FRAME_AGE=$(( TS_EPOCH - frame_mtime ))
        if (( LAST_FRAME_AGE >= 0 && LAST_FRAME_AGE <= FRAME_MAX_AGE )); then
            STREAM_UP="true"
        fi
    fi
else
    # No frame-touch file: trust the unit's active state as the up signal.
    STREAM_UP="$STREAM_ACTIVE"
fi

# --- Now-playing music track -------------------------------------------------
# Supports either:
#   * the project's MPD now-playing JSON {composer,piece,album,state,updated}
#     (state is play/pause/stopped) — composer->artist, piece->title, or
#   * a generic JSON object {artist,title,playing}, or
#   * a single plain-text line "Artist - Title".
MUSIC_ARTIST="" ; MUSIC_TITLE="" ; MUSIC_PLAYING="false" ; MUSIC_RAW=""
if [[ -n "$NOWPLAYING_FILE" && -r "$NOWPLAYING_FILE" ]]; then
    MUSIC_RAW="$(head -c 4096 "$NOWPLAYING_FILE" 2>/dev/null || true)"
    if command -v jq >/dev/null 2>&1 && printf '%s' "$MUSIC_RAW" | jq -e . >/dev/null 2>&1; then
        # Valid JSON — accept either schema. jq yields empty string for missing
        # keys; prefer artist/title, fall back to composer/piece. "playing" is
        # true if .playing==true OR .state is MPD's "playing" (badabing-nowplaying
        # writes the raw `mpc status` state: "playing"/"paused"/"stopped"). We also
        # accept the short "play" so any other producer's schema still works.
        MUSIC_ARTIST="$(printf '%s' "$MUSIC_RAW" | jq -r '.artist // .composer // empty' 2>/dev/null || true)"
        MUSIC_TITLE="$(printf '%s' "$MUSIC_RAW" | jq -r '.title // .piece // empty' 2>/dev/null || true)"
        MUSIC_PLAYING="$(printf '%s' "$MUSIC_RAW" | jq -r 'if (.playing==true) or (.state=="playing") or (.state=="play") then "true" else "false" end' 2>/dev/null || echo false)"
        # Treat the placeholder "Unknown composer" as no artist.
        [[ "$MUSIC_ARTIST" == "Unknown composer" ]] && MUSIC_ARTIST=""
    else
        # Plain text: take the first non-empty line, split on the first " - ".
        # (awk for portability — BSD/macOS sed dislikes the {p;q} one-liner;
        #  GNU sed on the Pi would be fine, but awk works everywhere.)
        line="$(printf '%s' "$MUSIC_RAW" | awk 'NF{print; exit}')"
        if [[ -n "$line" ]]; then
            MUSIC_PLAYING="true"
            if [[ "$line" == *" - "* ]]; then
                MUSIC_ARTIST="${line%% - *}"
                MUSIC_TITLE="${line#* - }"
            else
                MUSIC_TITLE="$line"
            fi
        fi
    fi
fi

# --- Battery (INA219) — OPTIONAL ---------------------------------------------
BATT_VOLTAGE="" ; BATT_CURRENT_MA="" ; BATT_PERCENT=""
if [[ "$BATTERY_ENABLE" == "1" ]]; then
    # The reader prints "voltage current_ma" (current may be empty). It returns
    # non-zero if the sensor can't be reached — we just leave fields null then.
    if [[ -x "$INA219_READER" ]]; then
        read -r BATT_VOLTAGE BATT_CURRENT_MA < <(
            INA219_BUS="$INA219_BUS" \
            INA219_ADDR="$INA219_ADDR" \
            INA219_SHUNT_OHMS="$INA219_SHUNT_OHMS" \
            INA219_MAX_AMPS="$INA219_MAX_AMPS" \
            "$INA219_READER" 2>/dev/null || true
        )
    fi
    # Derive a rough percentage from the resting-voltage window (clamped 0..100).
    if [[ "$BATT_VOLTAGE" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
        BATT_PERCENT="$(awk -v v="$BATT_VOLTAGE" -v f="$BATT_FULL_V" -v e="$BATT_EMPTY_V" \
            'BEGIN{ if (f<=e){print ""; exit} p=(v-e)/(f-e)*100; if(p<0)p=0; if(p>100)p=100; printf "%.0f", p }')"
    fi
fi

# --- Compose status.json atomically -----------------------------------------
mkdir -p "$STAGE_DIR" 2>/dev/null || true
TMP_FILE="$(mktemp "${STAGE_DIR}/status.XXXXXX.json" 2>/dev/null || echo "${STATUS_FILE}.tmp")"

{
  printf '{\n'
  printf '  "schema": 1,\n'
  printf '  "host": %s,\n'        "$(json_str "$HOSTNAME_S")"
  printf '  "ts": %s,\n'          "$(json_str "$TS_ISO")"
  printf '  "ts_epoch": %s,\n'    "$(json_num "$TS_EPOCH")"
  printf '  "uptime_s": %s,\n'    "$(json_num "$UPTIME_S")"
  printf '  "load": { "one": %s, "five": %s, "fifteen": %s },\n' \
                                  "$(json_num "$LOAD1")" "$(json_num "$LOAD5")" "$(json_num "$LOAD15")"
  printf '  "cpu_temp_c": %s,\n'  "$(json_num "$CPU_TEMP_C")"
  printf '  "wifi_rssi_dbm": %s,\n' "$(json_num "$WIFI_RSSI_DBM")"
  printf '  "stream": { "up": %s, "unit_active": %s, "last_frame_age_s": %s },\n' \
                                  "$STREAM_UP" "$STREAM_ACTIVE" "$(json_num "$LAST_FRAME_AGE")"
  printf '  "music": { "playing": %s, "artist": %s, "title": %s },\n' \
                                  "$MUSIC_PLAYING" "$(json_str "$MUSIC_ARTIST")" "$(json_str "$MUSIC_TITLE")"
  if [[ "$BATTERY_ENABLE" == "1" ]]; then
    printf '  "battery": { "voltage": %s, "current_ma": %s, "percent": %s }\n' \
                                  "$(json_num "$BATT_VOLTAGE")" "$(json_num "$BATT_CURRENT_MA")" "$(json_num "$BATT_PERCENT")"
  else
    printf '  "battery": null\n'
  fi
  printf '}\n'
} > "$TMP_FILE"

# Atomic local publish so any local reader/debug never sees a partial file.
mv -f "$TMP_FILE" "$STATUS_FILE" 2>/dev/null || { cp -f "$TMP_FILE" "$STATUS_FILE"; rm -f "$TMP_FILE"; }

# --- Push to the droplet over WireGuard via rsync-over-SSH -------------------
# Short timeouts so a dead/briefly-unreachable droplet fails fast and the timer
# just retries next tick. BatchMode=yes => never prompt. The remote side runs an
# rrsync forced-command locked to /var/www/badabing/api, so we pass a path
# RELATIVE to that root (DEPLOY_REMOTE_PATH defaults to ".").
# NOTE on known_hosts: the systemd unit sets ProtectHome=true, which makes
# /root (and thus /root/.ssh/known_hosts) INACCESSIBLE to this process. With the
# default UserKnownHostsFile under /root, accept-new would fail to record the key
# and the very first push would error out — silently breaking the reporter. So we
# pin the known_hosts file to the writable staging dir (/run/badabing, granted via
# ReadWritePaths). /run is tmpfs so it re-learns the key after each reboot, which
# is fine: the connection already rides an authenticated WireGuard tunnel, so the
# host key is defence-in-depth rather than the primary trust anchor.
KNOWN_HOSTS_FILE="${KNOWN_HOSTS_FILE:-${STAGE_DIR}/known_hosts}"
SSH_CMD=(ssh
    -i "$DEPLOY_SSH_KEY"
    -p "$DEPLOY_SSH_PORT"
    -o BatchMode=yes
    -o StrictHostKeyChecking=accept-new
    -o UserKnownHostsFile="$KNOWN_HOSTS_FILE"
    -o ConnectTimeout=8
    -o ServerAliveInterval=5
    -o ServerAliveCountMax=2
)

rsync \
    --quiet \
    --times \
    --checksum \
    --partial \
    --timeout=20 \
    -e "$(printf '%q ' "${SSH_CMD[@]}")" \
    "$STATUS_FILE" \
    "${DEPLOY_USER}@${DEPLOY_HOST}:${DEPLOY_REMOTE_PATH}/status.json"

rc=$?
if (( rc != 0 )); then
    echo "[badabing-status] push failed (rc=$rc); will retry on next timer tick" >&2
    exit "$rc"
fi
exit 0
