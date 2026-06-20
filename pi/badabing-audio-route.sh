#!/usr/bin/env bash
#
# /usr/local/bin/badabing-audio-route.sh
#
# Route audio to the Bluetooth speaker's A2DP sink under PipeWire/WirePlumber,
# and make it the DEFAULT sink so MPD (via the Pulse compat layer) lands there.
#
# Background — why this is needed:
#   When a trusted speaker connects, WirePlumber auto-creates a PipeWire node for
#   it and (usually) picks the A2DP profile and makes it default. But on a
#   headless box, after a reconnect, or when several sinks exist (e.g. a USB DAC
#   fallback AND Bluetooth), the default can land on the wrong node or on the
#   low-quality HSP/HFP (headset) profile instead of A2DP. This script forces:
#     1) the Bluetooth card onto its A2DP (a2dp-sink) profile, and
#     2) that A2DP sink as the system default.
#
# Run it:
#   * once after a fresh connect to verify routing, and
#   * automatically on each connect via badabing-bt-connect (or a WirePlumber
#     rule) — it is idempotent and safe to re-run.
#
# It is written for PipeWire running as a SYSTEM service (the headless pattern,
# see badabing-pipewire-system.md). It talks to PipeWire through wpctl/pactl,
# pointing XDG_RUNTIME_DIR at the system PipeWire runtime dir.
#
set -euo pipefail

ENV_FILE="${BADABING_ENV_FILE:-/etc/badabing/badabing-music.env}"
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a; source "$ENV_FILE"; set +a
fi

BT_SPEAKER_MAC="${BT_SPEAKER_MAC:-}"

# Point CLI tools at the system PipeWire instance (created by the system-service
# setup). For a normal logged-in user this is /run/user/<uid>; for the headless
# system service it is /run/pipewire (see badabing-pipewire-system.md).
export XDG_RUNTIME_DIR="${PIPEWIRE_RUNTIME_DIR:-/run/pipewire}"
export PIPEWIRE_RUNTIME_DIR="${PIPEWIRE_RUNTIME_DIR:-/run/pipewire}"
# pactl talks to pipewire-pulse; the system setup exposes it on a known socket.
export PULSE_RUNTIME_PATH="${PULSE_RUNTIME_PATH:-/run/pulse}"
# wpctl/pactl reach the headless system PipeWire over its private session bus —
# without this they cannot see the daemon's objects (same bus the units use).
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/pipewire/bus}"

log() { echo "[badabing-audio-route] $*" >&2; }

command -v wpctl  >/dev/null 2>&1 || { log "wpctl not found (apt install wireplumber)"; exit 1; }
command -v pactl  >/dev/null 2>&1 || { log "pactl not found (apt install pulseaudio-utils / pipewire-pulse)"; exit 1; }

# Bluetooth MACs appear in PipeWire/Pulse names with '_' instead of ':'.
MAC_UNDERSCORE="${BT_SPEAKER_MAC//:/_}"

# --- 1) Force the Bluetooth card onto the A2DP profile ------------------------
# Card name looks like: bluez_card.AA_BB_CC_DD_EE_FF
# IMPORTANT: under PipeWire the high-quality A2DP profile is simply "a2dp-sink"
# (codec is negotiated separately — NOT the legacy pulseaudio-modules-bt names
# like "a2dp-sink-sbc_xq", which do NOT exist on PipeWire). We just need to get
# off any HSP/HFP headset profile and onto a2dp-sink. We pick the first profile
# whose name starts with a2dp-sink (covers a2dp-sink and any codec-qualified
# variant a given build might expose) and fall back to the literal a2dp-sink.
CARD="$(pactl list cards short 2>/dev/null | awk '/bluez_card\./ {print $2}' | grep -i "$MAC_UNDERSCORE" | head -n1 || true)"
if [[ -n "$CARD" ]]; then
    PROFILE="$(pactl list cards 2>/dev/null \
        | awk -v c="$CARD" '
            $0 ~ "Name: "c {incard=1; next}
            incard && /^[[:space:]]+Profile/ {next}
            incard && /a2dp-sink[^:]*: / {gsub(/:$/,"",$1); print $1; exit}
          ' || true)"
    PROFILE="${PROFILE:-a2dp-sink}"
    log "setting card $CARD profile -> $PROFILE"
    pactl set-card-profile "$CARD" "$PROFILE" 2>/dev/null \
        || log "could not set profile $PROFILE (it may already be active)"
    # Best-effort: ask PipeWire to use SBC-XQ if the speaker supports it. This is
    # the PipeWire-correct codec switch (NOT a profile name). Harmless if absent.
    if [[ -n "${BT_CODEC:-}" ]]; then
        pactl send-message "/card/$CARD/bluez" switch-codec "\"${BT_CODEC/sbc-xq/sbc_xq}\"" >/dev/null 2>&1 \
            || true
    fi
else
    log "no bluez_card for $BT_SPEAKER_MAC yet — is the speaker connected? (run badabing-bt-connect)"
fi

# --- 2) Make the A2DP sink the DEFAULT ----------------------------------------
# Sink name looks like: bluez_output.AA_BB_CC_DD_EE_FF.1  (the trailing index
# varies; match on the MAC). Give the node a moment to appear after profile set.
for _ in 1 2 3 4 5 6; do
    SINK="$(pactl list sinks short 2>/dev/null | awk '/bluez_output\./ {print $2}' | grep -i "$MAC_UNDERSCORE" | head -n1 || true)"
    [[ -n "$SINK" ]] && break
    sleep 1
done

if [[ -n "$SINK" ]]; then
    log "setting default sink -> $SINK"
    pactl set-default-sink "$SINK"
    # Move any already-playing streams (e.g. MPD that started before the speaker
    # reconnected) onto the Bluetooth sink so audio follows the speaker.
    pactl list sink-inputs short 2>/dev/null | awk '{print $1}' | while read -r in; do
        [[ -n "$in" ]] && pactl move-sink-input "$in" "$SINK" 2>/dev/null || true
    done
    # Unmute + set a sane starting volume (70%). The speaker has its own volume
    # knob; this just stops a silent-because-muted surprise.
    pactl set-sink-mute   "$SINK" 0          2>/dev/null || true
    pactl set-sink-volume "$SINK" 70%        2>/dev/null || true
    log "routed. default sink is now the A2DP speaker."
else
    log "no A2DP sink for $BT_SPEAKER_MAC found — speaker not connected or still on HSP/HFP."
    exit 1
fi
