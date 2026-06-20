#!/usr/bin/env bash
#
# /usr/local/bin/fetch-music.sh
#
# Populate the local music library with GENUINELY FREE / public-domain classical
# RECORDINGS from Musopen's public-domain collections on the Internet Archive.
#
# =============================================================================
# IMPORTANT — composition vs. recording copyright
# =============================================================================
# A classical COMPOSITION (Beethoven's 7th, Chopin's nocturnes, ...) is long in
# the PUBLIC DOMAIN. But a specific RECORDING / performance is its OWN
# copyrighted work — a 2015 orchestra's performance of a 1808 symphony is NOT
# automatically free. So "it's Beethoven, it must be free" is WRONG for audio.
#
# This script only downloads recordings that the performers/Musopen have
# EXPLICITLY released to the public domain (CC0 / "PD CC"). The Internet Archive
# items below are Musopen public-domain sets. If you add your own archive.org
# identifiers, CHECK the item's license shows CC0 / Public Domain before adding
# it — do not assume.
#
# The cleanest, no-ambiguity option is to use YOUR OWN files: see "DROP YOUR OWN
# FILES" at the bottom. This downloader is just a convenience starter library.
# =============================================================================
#
# Usage:
#   sudo /usr/local/bin/fetch-music.sh            # download the default CC0 sets
#   sudo /usr/local/bin/fetch-music.sh --list     # show what it would fetch
#   sudo /usr/local/bin/fetch-music.sh ID [ID...] # fetch specific archive.org IDs
#
set -euo pipefail

ENV_FILE="${BADABING_ENV_FILE:-/etc/badabing/badabing-music.env}"
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a; source "$ENV_FILE"; set +a
fi
MUSIC_DIR="${MUSIC_DIR:-/srv/badabing/music}"

log() { echo "[fetch-music] $*" >&2; }

# --- Default public-domain Internet Archive items ----------------------------
# Licenses VERIFIED on the item pages (Jun 2026 — re-check, they can change):
#   musopen-chopin          : "The Complete Chopin Collection" — CC0 1.0 Universal
#                             (a true public-domain *dedication* / rights waiver).
#   MusopenCollectionAsFlac : Musopen FLAC set — "Public Domain Mark 1.0". NOTE:
#                             the PD Mark is only an ASSERTION that a work is
#                             ALREADY in the public domain; it is NOT a CC0 waiver
#                             and carries NO warranty. Treat it as "very likely
#                             free, but the uploader is vouching for it, not CC."
# Musopen hosts a MIX of licenses (CC0, CC-BY, CC-BY-SA, CC-BY-NC, PD Mark) and
# explicitly does NOT guarantee public-domain status of user uploads, so if you
# add your own identifiers from https://archive.org/details/musopen you MUST open
# each item page and confirm the license badge before adding it here.
DEFAULT_ITEMS=(
    "musopen-chopin"
    "MusopenCollectionAsFlac"
)

# Only pull audio file types; skip the archive.org metadata/derivative cruft.
# NOTE: `ia download --glob` uses PIPE-separated patterns (NOT bash brace
# expansion). wget's -A uses a comma list. We keep both forms in sync below.
IA_GLOB='*.mp3|*.flac|*.ogg|*.opus|*.m4a|*.wav'
WGET_EXTS='mp3,flac,ogg,opus,m4a,wav'

if [[ "${1:-}" == "--list" ]]; then
    log "default public-domain items that would be downloaded into $MUSIC_DIR:"
    printf '  archive.org/details/%s\n' "${DEFAULT_ITEMS[@]}"
    log "ia glob: $IA_GLOB   (wget exts: $WGET_EXTS)"
    exit 0
fi

ITEMS=("$@")
[[ ${#ITEMS[@]} -eq 0 ]] && ITEMS=("${DEFAULT_ITEMS[@]}")

mkdir -p "$MUSIC_DIR"

# --- Downloader: prefer the official `ia` tool, fall back to wget ------------
# The `ia` (internetarchive) CLI does checksummed, resumable, glob-filtered
# downloads — ideal for a flaky solar/Wi-Fi link.
have_ia=0
if command -v ia >/dev/null 2>&1; then
    have_ia=1
else
    log "the 'ia' tool isn't installed. Install it for best results:"
    log "    sudo apt install -y python3-internetarchive   # Debian/RPi OS Bookworm"
    log "  (or, if that package is unavailable:  sudo apt install -y pipx && pipx install internetarchive )"
    log "  NOTE: Bookworm's Python is externally-managed (PEP 668), so a bare"
    log "        'pip3 install' will refuse; use the apt package or pipx."
    log "Falling back to wget recursive download."
    command -v wget >/dev/null 2>&1 || { log "ERROR: neither ia nor wget present"; exit 1; }
fi

download_item() {
    local id="$1"
    local dest="$MUSIC_DIR/$id"
    mkdir -p "$dest"
    log "downloading archive.org item '$id' -> $dest"
    if [[ $have_ia -eq 1 ]]; then
        # --glob limits to audio (PIPE-separated patterns — brace expansion is
        # NOT supported by ia). --checksum re-downloads only when the local file's
        # checksum differs, so it is resume/idempotent-friendly across a spotty
        # solar/Wi-Fi link and safe to re-run. --destdir writes under MUSIC_DIR
        # (ia creates the per-item subdir itself). We retry the whole item in a
        # small loop because `ia download` has no reliable per-file --retries.
        local try
        for try in 1 2 3; do
            if ia download "$id" \
                    --glob="$IA_GLOB" \
                    --destdir="$MUSIC_DIR" \
                    --checksum; then
                break
            fi
            log "WARN: ia attempt $try for $id failed; retrying"
            sleep 5
        done
    else
        # wget mirror of the item's download dir. -A restricts to audio
        # extensions (comma list); -nc skips existing; -c resumes partial files.
        wget -e robots=off -r -np -nH --cut-dirs=2 -nc -c \
             -A "$WGET_EXTS" \
             -P "$dest" \
             "https://archive.org/download/${id}/" \
             || log "WARN: wget reported errors for $id"
    fi
}

for id in "${ITEMS[@]}"; do
    download_item "$id"
done

# Fix ownership so MPD (user 'mpd') can read everything we just wrote.
if id mpd >/dev/null 2>&1; then
    chown -R mpd:audio "$MUSIC_DIR" 2>/dev/null || true
fi

# Tell MPD to rescan (best-effort; ignored if MPD/mpc absent).
if command -v mpc >/dev/null 2>&1; then
    MPD_HOST="${MPD_HOST:-/run/mpd/socket}" mpc update --wait >/dev/null 2>&1 \
        || MPD_HOST="${MPD_HOST:-/run/mpd/socket}" mpc update >/dev/null 2>&1 \
        || log "could not trigger 'mpc update' (run it yourself once MPD is up)"
fi

log "done. library now under $MUSIC_DIR"
log "verify each item's license at https://archive.org/details/<id> shows CC0 / Public Domain Mark / PD before relying on it for a PUBLIC stream."

# =============================================================================
# DROP YOUR OWN FILES (recommended for full control / guaranteed-clean rights)
# =============================================================================
# You don't need this script at all if you have your own legally-obtained rips.
# Just copy .mp3/.flac/.ogg/.opus/.m4a files (subfolders fine) into:
#       $MUSIC_DIR        (default: /srv/badabing/music)
# e.g. from your laptop:
#       rsync -av ~/Music/Classical/  pi@coop.local:/srv/badabing/music/
# then:
#       sudo chown -R mpd:audio /srv/badabing/music
#       MPD_HOST=/run/mpd/socket mpc update --wait
# Good tags help the now-playing writer: set the COMPOSER (or ARTIST) and TITLE
# tags so /run/badabing/nowplaying.txt reads like "Beethoven — Symphony No. 7".
# =============================================================================
