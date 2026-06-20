#!/usr/bin/env bash
#
# /usr/local/bin/badabing-mpd-init.sh
#
# Put MPD into "continuous shuffled library" mode and start it playing. Run once
# at boot (by badabing-mpd-init.service, after mpd is up) and it is idempotent so
# it can be re-run any time to re-arm shuffle.
#
# What "continuous shuffle of the whole library" means here:
#   * random  on  -> next track is picked at random
#   * repeat  on  -> the queue never ends (wraps), so + random = endless shuffle
#   * single  off -> don't stop after one track
#   * consume off -> tracks stay in the queue (so repeat has something to wrap)
#   * load EVERY track in the library into the queue, then play.
#
set -euo pipefail

ENV_FILE="${BADABING_ENV_FILE:-/etc/badabing/badabing-music.env}"
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a; source "$ENV_FILE"; set +a
fi

# Talk to MPD over its local socket (matches bind_to_address in mpd.conf).
export MPD_HOST="${MPD_HOST:-/run/mpd/socket}"

log() { echo "[badabing-mpd-init] $*" >&2; }
command -v mpc >/dev/null 2>&1 || { log "mpc not found (apt install mpc)"; exit 1; }

# Wait for MPD to be answering on the socket (it may still be loading the DB).
for _ in $(seq 1 30); do
    if mpc status >/dev/null 2>&1; then break; fi
    sleep 1
done
mpc status >/dev/null 2>&1 || { log "MPD not responding on $MPD_HOST"; exit 1; }

# Make sure the database reflects whatever is on disk (new downloads / dropped
# files), and WAIT for the update to finish before we populate the queue.
log "updating library database..."
mpc update --wait >/dev/null 2>&1 || mpc update >/dev/null 2>&1 || true

# Arm continuous-shuffle flags.
log "setting random=on repeat=on single=off consume=off"
mpc random on    >/dev/null
mpc repeat on    >/dev/null
mpc single off   >/dev/null
mpc consume off  >/dev/null

# (Re)build the queue from the entire library if it is empty or tiny. We clear
# and reload so a re-run gives a fresh full-library queue.
COUNT="$(mpc playlist 2>/dev/null | wc -l | tr -d ' ')"
if [[ "${COUNT:-0}" -lt 1 ]]; then
    log "queue empty — loading entire library and shuffling"
    mpc clear   >/dev/null
    mpc add /   >/dev/null            # '/' = everything under music_directory
    mpc shuffle >/dev/null            # initial shuffle of queue order too
fi

# If there is nothing in the library at all, say so loudly (silent speaker is a
# confusing failure mode on an unattended box).
if [[ "$(mpc playlist 2>/dev/null | wc -l | tr -d ' ')" -lt 1 ]]; then
    log "WARNING: music library is EMPTY ($MUSIC_DIR). Run fetch-music.sh or drop files in, then re-run."
    exit 0
fi

# Start playing (idempotent: if already playing this is a no-op-ish nudge).
STATE="$(mpc status 2>/dev/null | sed -n '2p' | awk '{print $1}' | tr -d '[]')"
if [[ "$STATE" != "playing" ]]; then
    log "starting playback"
    mpc play >/dev/null
else
    log "already playing"
fi

log "done. now playing: $(mpc current 2>/dev/null || echo '(unknown)')"
