#!/usr/bin/env bash
#
# /usr/local/bin/badabing-nowplaying.sh
#
# The on-track-change hook + "now playing" writer. Blocks on MPD's event system
# (`mpc idle player`) and, on EVERY track change / play / pause, writes the
# current composer + piece to small files under /run (tmpfs, RAM — no SD wear):
#   * NOWPLAYING_TXT  : one human line, e.g.  "Ludwig van Beethoven — Symphony No. 7 in A, II. Allegretto"
#   * NOWPLAYING_JSON : structured, for an on-video overlay / web widget / etc.
#
# Other scripts just read those files; they never have to talk to MPD.
#
# Run as a daemon by badabing-nowplaying.service (Restart=always). It also writes
# once on startup so the file is populated immediately, not only after the first
# track change.
#
set -uo pipefail   # NOT -e: a transient mpc hiccup must not kill the daemon

ENV_FILE="${BADABING_ENV_FILE:-/etc/badabing/badabing-music.env}"
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a; source "$ENV_FILE"; set +a
fi

export MPD_HOST="${MPD_HOST:-/run/mpd/socket}"

NOWPLAYING_DIR="${NOWPLAYING_DIR:-/run/badabing}"
NOWPLAYING_TXT="${NOWPLAYING_TXT:-$NOWPLAYING_DIR/nowplaying.txt}"
NOWPLAYING_JSON="${NOWPLAYING_JSON:-$NOWPLAYING_DIR/nowplaying.json}"

log() { echo "[badabing-nowplaying] $*" >&2; }
command -v mpc >/dev/null 2>&1 || { log "mpc not found (apt install mpc)"; exit 1; }

mkdir -p "$NOWPLAYING_DIR"

# Minimal JSON string escaper (quotes + backslashes; good enough for tag text).
json_escape() { printf '%s' "${1:-}" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

write_nowplaying() {
    # Pull tags individually so we degrade gracefully when a file lacks them.
    # We treat the ARTIST tag as the "composer" (standard for classical rips);
    # COMPOSER tag is used in preference if present.
    local composer title album state file
    composer="$(mpc --format '%composer%' current 2>/dev/null)"
    [[ -z "$composer" || "$composer" == "%composer%" ]] && \
        composer="$(mpc --format '%artist%' current 2>/dev/null)"
    title="$(mpc --format '%title%' current 2>/dev/null)"
    album="$(mpc --format '%album%' current 2>/dev/null)"
    file="$(mpc --format '%file%' current 2>/dev/null)"
    state="$(mpc status 2>/dev/null | sed -n '2p' | awk '{print $1}' | tr -d '[]')"
    [[ -z "$state" ]] && state="stopped"

    # Fallbacks: if tags are missing, derive a readable name from the filename.
    if [[ -z "$title" ]]; then
        title="$(basename "${file:-unknown}")"
        title="${title%.*}"
    fi
    [[ -z "$composer" ]] && composer="Unknown composer"

    # Human line.
    local line
    if [[ -n "$composer" && "$composer" != "Unknown composer" ]]; then
        line="${composer} — ${title}"
    else
        line="${title}"
    fi

    # Atomic write (write temp, mv) so a reader never sees a half-written file.
    local tmp
    tmp="$(mktemp "${NOWPLAYING_DIR}/.np.XXXXXX")"
    printf '%s\n' "$line" > "$tmp"
    mv -f "$tmp" "$NOWPLAYING_TXT"

    tmp="$(mktemp "${NOWPLAYING_DIR}/.npj.XXXXXX")"
    cat > "$tmp" <<EOF
{
  "composer": "$(json_escape "$composer")",
  "piece": "$(json_escape "$title")",
  "album": "$(json_escape "$album")",
  "file": "$(json_escape "$file")",
  "state": "$(json_escape "$state")",
  "updated": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
    mv -f "$tmp" "$NOWPLAYING_JSON"

    log "now playing: $line  [$state]"
}

# Write once up front (don't wait for the first change event).
# Give MPD a moment to be reachable on boot.
for _ in $(seq 1 30); do
    mpc status >/dev/null 2>&1 && break
    sleep 1
done
write_nowplaying

# Event loop: `mpc idle player` blocks until a player event (song change, play,
# pause, stop), then returns; we rewrite and loop. This is MPD's native
# "on-track-change" mechanism — no polling, near-zero CPU, instant updates.
while true; do
    if mpc idle player >/dev/null 2>&1; then
        write_nowplaying
    else
        # MPD restarted or socket vanished (e.g. service bounce): back off and
        # wait for it to return rather than spinning.
        log "lost MPD connection — waiting for it to come back"
        sleep 5
    fi
done
