#!/usr/bin/env bash
#
# /usr/local/bin/badabing-stream.sh
#
# Capture from the Raspberry Pi Camera Module 3 with rpicam-vid (hardware H.264
# encode where the board supports it), then publish the bitstream to a remote
# MediaMTX server over RTSP using ffmpeg, WITHOUT re-encoding (-c:v copy).
#
# The Pi sits behind home NAT and pushes OUTBOUND over a WireGuard tunnel, so
# the RTSP target is MediaMTX's in-tunnel (wg0) address. Reconnect-on-drop is
# handled by the wrapping systemd unit (Restart=always with backoff): if either
# rpicam-vid or ffmpeg exits, this script exits non-zero and systemd relaunches.
#
# Targets:  Pi Zero 2 W (primary, hardware H.264 @ <=1080p30) - also Pi 4
#           (hardware H.264). On Pi 5 there is NO hardware H.264 encoder; see the
#           note at the bottom of this file for the software-encode variant.
# OS:       Raspberry Pi OS Bookworm or later (rpicam / libcamera stack).
#
set -euo pipefail

# --- Load tunables -----------------------------------------------------------
ENV_FILE="${BADABING_ENV_FILE:-/etc/badabing/badabing-stream.env}"
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a; source "$ENV_FILE"; set +a
fi

# Defaults (used only if the env file is missing a key).
# WG_IP / MTX_PATH defaults MUST match the droplet side (wg0.conf 10.10.0.1 and
# mediamtx.yml path "coop"); the env file normally overrides these.
WG_IP="${WG_IP:-10.10.0.1}"
RTSP_PORT="${RTSP_PORT:-8554}"
MTX_PATH="${MTX_PATH:-coop}"
RTSP_TRANSPORT="${RTSP_TRANSPORT:-tcp}"
WIDTH="${WIDTH:-1280}"
HEIGHT="${HEIGHT:-720}"
FRAMERATE="${FRAMERATE:-15}"
BITRATE="${BITRATE:-1500000}"
INTRA="${INTRA:-$FRAMERATE}"
H264_PROFILE="${H264_PROFILE:-high}"
H264_LEVEL="${H264_LEVEL:-4.1}"
HFLIP="${HFLIP:-0}"
VFLIP="${VFLIP:-0}"
ROTATION="${ROTATION:-0}"
DENOISE="${DENOISE:-cdn_off}"
AF_MODE="${AF_MODE:-manual}"
LENS_POSITION="${LENS_POSITION:-0.4}"
AWB="${AWB:-daylight}"
CAMERA="${CAMERA:-0}"

# --- Build the destination RTSP URL ------------------------------------------
if [[ -n "${RTSP_USER:-}" && -n "${RTSP_PASS:-}" ]]; then
    RTSP_AUTH="${RTSP_USER}:${RTSP_PASS}@"
else
    RTSP_AUTH=""
fi
RTSP_URL="rtsp://${RTSP_AUTH}${WG_IP}:${RTSP_PORT}/${MTX_PATH}"

# --- Assemble rpicam-vid arguments -------------------------------------------
# --codec h264   : use the on-board hardware H.264 encoder (Pi Zero 2 W / Pi 4).
# --inline       : repeat SPS/PPS headers inline before each keyframe so a reader
#                  that joins mid-stream (or after a reconnect) can decode at the
#                  next keyframe - essential for RTSP republishing.
# --intra        : keyframe interval in frames.
# -t 0           : run forever.
# -o -           : write the raw H.264 elementary stream to stdout.
# -n             : no preview (headless).
# --flush        : flush each frame to the pipe immediately (lower latency).
RPICAM_ARGS=(
    --camera "$CAMERA"
    -n
    -t 0
    --codec h264
    --inline
    --flush
    --width "$WIDTH"
    --height "$HEIGHT"
    --framerate "$FRAMERATE"
    --bitrate "$BITRATE"
    --intra "$INTRA"
    --profile "$H264_PROFILE"
    --level "$H264_LEVEL"
    --denoise "$DENOISE"
    --awb "$AWB"
    -o -
)

# Orientation
[[ "$HFLIP" == "1" ]] && RPICAM_ARGS+=( --hflip )
[[ "$VFLIP" == "1" ]] && RPICAM_ARGS+=( --vflip )
[[ "$ROTATION" != "0" ]] && RPICAM_ARGS+=( --rotation "$ROTATION" )

# Auto-focus (Camera Module 3). Manual + fixed lens position avoids AF hunting,
# which saves power and keeps a fixed scene sharp.
if [[ "$AF_MODE" == "manual" ]]; then
    RPICAM_ARGS+=( --autofocus-mode manual --lens-position "$LENS_POSITION" )
else
    RPICAM_ARGS+=( --autofocus-mode "$AF_MODE" )
fi

# --- Assemble ffmpeg arguments -----------------------------------------------
# Raw H.264 from the pipe carries NO container timestamps. The correct fix is a
# SINGLE input-side mechanism: -use_wallclock_as_timestamps 1 stamps each packet
# as it is read with the wall-clock time, which is exactly what RTP needs.
#
# IMPORTANT: do NOT also pass `-fflags +genpts`. genpts only synthesises a PTS
# from an existing DTS; with raw H.264 there is no DTS either, and once
# use_wallclock_as_timestamps is supplying real timestamps, +genpts is at best a
# no-op and at worst fights the wallclock stamping (duplicate/again non-monotonic
# PTS warnings). One timestamp source, not two.
#
# -use_wallclock_as_timestamps 1 : (INPUT opt) anchor PTS to wall clock.
# -f h264                : declare the input as a raw H.264 elementary stream.
# -r N                   : (INPUT opt) tell the raw demuxer the nominal rate. The
#                          raw h264/video demuxers take -r, NOT -framerate (which
#                          is the image2/v4l2 demuxer option); -r is the portable
#                          spelling here.
# -i pipe:0              : read from stdin.
# -c:v copy             : NO re-encode - pass the hardware-encoded H.264 through.
# -an                   : no audio.
# -f rtsp -rtsp_transport tcp : publish as an RTSP client (push) over TCP.
# -muxdelay/-muxpreload 0 : keep buffering minimal.
# NOTE: -rtsp_transport / -muxdelay / -muxpreload are OUTPUT (muxer) options and
#       must sit before the output URL (they do here).
FFMPEG_ARGS=(
    -hide_banner
    -loglevel warning
    -use_wallclock_as_timestamps 1
    -f h264
    -r "$FRAMERATE"
    -i pipe:0
    -an
    -c:v copy
    -muxdelay 0
    -muxpreload 0
    -rtsp_transport "$RTSP_TRANSPORT"
    -f rtsp
    "$RTSP_URL"
)

echo "[badabing-stream] capturing ${WIDTH}x${HEIGHT}@${FRAMERATE} ${BITRATE}bps -> ${RTSP_URL} (transport=${RTSP_TRANSPORT})" >&2

# --- Run the pipeline --------------------------------------------------------
# pipefail (set above) means if EITHER side dies the pipeline returns non-zero,
# the script exits, and systemd restarts us - that is the auto-reconnect.
exec rpicam-vid "${RPICAM_ARGS[@]}" | ffmpeg "${FFMPEG_ARGS[@]}"

# -----------------------------------------------------------------------------
# Pi 5 NOTE - Pi 5 has NO hardware H.264 encoder. rpicam-vid --codec h264 falls
# back to a SOFTWARE encoder (more CPU/power). If you must run on a Pi 5, you can
# still keep this exact pipeline (rpicam-vid does the software encode and ffmpeg
# copies), or transcode in ffmpeg instead. For the LOW-POWER solar goal, stick
# with a Pi Zero 2 W or Pi 4 where the encode is in hardware.
# -----------------------------------------------------------------------------
