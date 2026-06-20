#!/usr/bin/env bash
# =============================================================================
# UFW firewall setup for the chicken-cam public proxy droplet.
# Run once as root:  bash ufw-setup.sh
#
# Public attack surface is deliberately tiny:
#   22/tcp     SSH (consider restricting source to your IP -- see below)
#   443/tcp    HTTPS (nginx: viewer + HLS + WHEP signaling)
#   51820/udp  WireGuard (the Pi dials in here)
#   8189/udp   WebRTC media (SRTP) -- REQUIRED for WHEP video to actually flow
#
# NOT exposed publicly (and must never be):
#   8554/tcp   RTSP ingest  -> bound to WireGuard IP 10.10.0.1 in mediamtx.yml
#   8888/tcp   HLS          -> bound to 127.0.0.1, fronted by nginx
#   8889/tcp   WebRTC sig   -> bound to 127.0.0.1, fronted by nginx
#   9997/tcp   API          -> bound to 127.0.0.1
#   80/tcp     HTTP         -> only for ACME + redirect; allowed below
# =============================================================================
set -euo pipefail

# Reset to a known-good baseline.
ufw --force reset

# Default deny inbound, allow outbound (the Pi/WHEP need outbound; viewers pull).
ufw default deny incoming
ufw default allow outgoing

# --- SSH ---------------------------------------------------------------------
# Rate-limited SSH (ufw 'limit' = block IPs with >6 connections in 30s).
# HARDENING TIP: replace the next line with your admin IP, e.g.
#   ufw limit from 203.0.113.7 to any port 22 proto tcp
ufw limit 22/tcp comment 'SSH (rate-limited)'

# --- HTTP/HTTPS --------------------------------------------------------------
# 80 is needed for Let's Encrypt HTTP-01 challenges and the HTTPS redirect.
ufw allow 80/tcp   comment 'HTTP (ACME + redirect to 443)'
ufw allow 443/tcp  comment 'HTTPS (viewer + HLS + WHEP signaling)'

# --- WireGuard ---------------------------------------------------------------
ufw allow 51820/udp comment 'WireGuard (Pi dials in)'

# --- WebRTC media (SRTP) -----------------------------------------------------
# This carries the actual video for WHEP. Without it, WHEP signaling succeeds
# but no media ever arrives. It carries no credentials (DTLS-SRTP keyed via the
# already-authenticated signaling), so opening it publicly is safe.
ufw allow 8189/udp comment 'WebRTC media (SRTP)'

# Explicitly DENY the internal media ports from the public side, belt-and-braces
# (they are already bound to loopback / wg, but make the intent auditable).
ufw deny 8554/tcp comment 'RTSP ingest: WireGuard only'
ufw deny 8888/tcp comment 'HLS: localhost only (nginx fronts it)'
ufw deny 8889/tcp comment 'WebRTC signaling: localhost only (nginx fronts it)'
ufw deny 9997/tcp comment 'MediaMTX API: localhost only'

# Logging on (low) so fail2ban and audits have data.
ufw logging low

ufw --force enable
ufw status verbose
