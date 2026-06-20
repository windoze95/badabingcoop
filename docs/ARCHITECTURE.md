# Architecture

The Bada Bing is one Raspberry Pi behind home NAT and one DigitalOcean droplet on
the public internet, joined by a single WireGuard tunnel. The Pi only ever
*pushes outbound*; the droplet is the only thing the public ever touches. Three
loosely-coupled subsystems ride that one tunnel: **VIDEO**, **TELEMETRY**, and
**JUKEBOX**.

For the network/firewall/key details see [`NETWORK.md`](NETWORK.md).

---

## The three subsystems

### 1. VIDEO — the live coop stream

The camera pipeline runs on the Pi and the playback path runs on the droplet.

**Capture & push (Pi)** — `pi/badabing-stream.sh`, supervised by
`badabing-stream.service`:

1. `rpicam-vid` captures from the Camera Module 3 and encodes H.264 in
   **hardware** (Pi Zero 2 W / Pi 4) at 1280×720@15 ~1.5 Mbps — the solar sweet
   spot. `--inline` repeats SPS/PPS before each keyframe so a mid-stream joiner or
   reconnecting reader can decode at the next keyframe.
2. The raw H.264 elementary stream is piped to `ffmpeg`, which **does not
   re-encode** (`-c:v copy`), stamps packets with the wall clock
   (`-use_wallclock_as_timestamps 1`, the single timestamp source), and pushes via
   **RTSP over TCP** to `rtsp://chickenpi:…@10.10.0.1:8554/coop`.
3. The target IP `10.10.0.1` is the droplet's **WireGuard** address — the push
   rides the encrypted tunnel, never the public internet. `bash`/`systemd`
   pipefail means if either stage dies the unit restarts (auto-reconnect).

**Ingest & serve (droplet)** — `droplet/mediamtx/mediamtx.yml`:

- MediaMTX accepts the publish on its RTSP listener, which is **bound to
  `10.10.0.1` (WireGuard) only**. The publisher authenticates as the internal
  user `chickenpi` (action `publish`, path `coop`, restricted to source IPs in
  `10.10.0.0/24`).
- MediaMTX re-muxes the single `coop` path into two reader transports:
  - **WebRTC / WHEP** signaling on `127.0.0.1:8889` (loopback);
  - **Low-Latency HLS** on `127.0.0.1:8888` (loopback).
- **nginx** (`droplet/nginx/coop.conf`) is the only public TLS front door. It
  terminates HTTPS on :443 and reverse-proxies `/coop/whep` → 8889 and `/coop/`
  → 8888, and serves the static viewer from `/var/www/badabing/`. The viewer is
  **public — no auth_basic** (an opt-in Basic-Auth block is commented out for
  anyone who later wants it).

**Play (browser)** — `droplet/web/app.js`:

- Tries **WebRTC first** (the full WHEP handshake: `OPTIONS` for ICE servers,
  `POST` SDP offer → 201 with answer + session `Location`, `PATCH` trickle ICE,
  `DELETE` on teardown). WebRTC **media (SRTP)** does **not** traverse nginx — it
  flows directly between the browser and the droplet's public IP over **UDP
  8189**, advertised via MediaMTX's `webrtcAdditionalHosts` (the reserved-IP
  literal).
- On WebRTC failure / unsupported browser it **falls back to HLS** (`hls.js`, or
  native HLS on Safari). `hls.js` is pinned to **1.6.16** and loaded from jsDelivr
  with a verified **SRI** hash — do not change either.
- Connection-status pill, exponential-backoff auto-reconnect, and a snapshot
  button (watermarked PNG) round it out.

### 2. TELEMETRY — the public status widget

A backend-free, push-only health channel. The droplet runs **no application
server**; nginx only serves a static JSON file the Pi writes.

**Build & push (Pi)** — `pi/badabing-status.sh` (oneshot
`badabing-status.service` fired by `badabing-status.timer` ~every 15 s):

1. Gather best-effort fields, each degrading to `null` rather than aborting:
   hostname, ISO + epoch timestamps, uptime, load average, CPU temp (`vcgencmd`
   → sysfs), Wi-Fi RSSI (`/proc/net/wireless` → `iw`), **stream up?** (the
   `badabing-stream.service` active state and/or a frame-touch mtime within
   `FRAME_MAX_AGE`), the **now-playing** track (read from the jukebox's
   `nowplaying.json`), and optional **battery** (INA219, only when
   `BATTERY_ENABLE=1`).
2. Compose `status.json` atomically (temp file → rename) into `/run/badabing`
   (tmpfs, no SD wear).
3. `rsync` it over SSH to `coopstatus@10.10.0.1` — again **through WireGuard**.
   The remote side runs an `rrsync` forced-command locked to
   `/var/www/badabing/api` with `-wo -no-del`, so the Pi can only **write**
   `status.json` into that one directory and nothing else.

**Serve (droplet)** — `droplet/nginx/api-status.conf` (included by `coop.conf`):

- Serves `/var/www/badabing/api/status.json` at **`/api/status.json`** with
  `auth_basic off` (public, no login), `Cache-Control: no-cache, no-store,
  must-revalidate`, and CORS GET allowed. The browser polls it every ~10–15 s.
- The `/api` path is **hard-coded** in three places that must agree: the
  `coopstatus` SSH forced-command, the Pi reporter's destination, and this nginx
  snippet. Do not change it.

### 3. JUKEBOX — classical-over-Bluetooth (optional)

Entirely on the Pi; its only tie to the rest of the system is the now-playing
track folded into `status.json`.

- **PipeWire/WirePlumber as system services** (`badabing-pipewire-setup.sh`) so a
  headless box can make sound with nobody logged in.
- **Bluetooth**: a one-time `badabing-bt-setup.sh` pairs + trusts the speaker;
  `badabing-bt-connect.service` keeps it connected forever; `badabing-audio-route.sh`
  forces the **A2DP** sink as default (not the low-quality HSP/HFP profile). A USB
  BT dongle is recommended so music doesn't compete with the camera's Wi-Fi on
  the Pi Zero 2 W's single 2.4 GHz radio.
- **MPD** (`badabing-mpd.service`, `mpd.conf`) plays a library of **genuinely
  public-domain** recordings (`fetch-music.sh` pulls from Musopen/Internet
  Archive — note: a *recording* has its own copyright separate from the
  composition). `badabing-mpd-init.sh` arms endless shuffle (random + repeat).
- `badabing-nowplaying.sh` blocks on `mpc idle player` and, on every change,
  atomically writes `nowplaying.txt` + `nowplaying.json` to `/run/badabing`. The
  telemetry reporter reads that file; the page shows "Now Spinning".

---

## Detailed data flow

```
  ┌──────────────────────────── HOME / Raspberry Pi Zero 2 W ────────────────────────────┐
  │                                                                                       │
  │  Camera Module 3 ──CSI──▶ rpicam-vid (HW H.264) ──pipe──▶ ffmpeg (-c:v copy)          │
  │                                                              │ RTSP/TCP                │
  │  INA219 ──I2C──▶ badabing-ina219.py ─┐                       │ (publish "coop")        │
  │                                       ▼                      │                         │
  │  MPD (shuffle) ──A2DP──▶ BT speaker   badabing-status.sh ────┼─┐ rsync/ssh             │
  │     │                                  builds status.json    │ │ (status.json)         │
  │     └─▶ mpc idle ─▶ nowplaying.json ──▶ (read) ──────────────┘ │                       │
  └───────────────────────────────────────────────────────────────┼───────────┼──────────┘
                                                                    │           │
                            WireGuard tunnel (UDP 51820, outbound)  │           │
                          Pi 10.10.0.2 ───────────────────────────▶ 10.10.0.1   │
                                                                    │           │
  ┌──────────────────────────── DIGITALOCEAN DROPLET ──────────────┼───────────┼──────────┐
  │                                                                 ▼           ▼          │
  │   MediaMTX  rtsp 10.10.0.1:8554 ◀── publish                rrsync (-wo) ─▶ /var/www/    │
  │      ├─ LL-HLS   127.0.0.1:8888 ─┐                          badabing/api/status.json    │
  │      └─ WHEP sig 127.0.0.1:8889 ─┤ loopback                       │                     │
  │      └─ SRTP media   :8189/udp ──┼──────── public UDP ──────┐     │                     │
  │                                  ▼                          │     │ (static read)       │
  │   nginx :443  ── /coop/ ───▶ 8888 (HLS)                     │     ▼                     │
  │              ── /coop/whep ▶ 8889 (WHEP signaling)          │  /api/status.json (no auth)│
  │              ── /          ▶ /var/www/badabing (viewer)     │     │                     │
  └────────────────────────────────────┬───────────────────────┼─────┼─────────────────────┘
                                        │ HTTPS 443             │     │
                                        ▼                       ▼     ▼
                                  Browser: WebRTC media (UDP 8189) ⟂ HLS/HTTPS · widget poll
```

---

## Canonical endpoint / port / path table

Every listener in the system, what binds it, and where it is reachable from.

| Port / path        | Service                  | Bound on            | Exposure                  | Notes |
|--------------------|--------------------------|---------------------|---------------------------|-------|
| **22/tcp**         | SSH (admin + status push)| droplet public NIC  | Public (rate-limited; status push arrives over WG) | hardened: key-only, no root |
| **80/tcp**         | nginx HTTP               | droplet public NIC  | Public                    | ACME HTTP-01 + 301 → 443 |
| **443/tcp**        | nginx HTTPS              | droplet public NIC  | **Public**                | the only public TLS front door |
| **51820/udp**      | WireGuard                | droplet public NIC  | **Public**                | the Pi dials in here |
| **8189/udp**       | WebRTC media (SRTP)      | droplet `:8189`     | **Public**                | carries video, not credentials |
| **8554/tcp**       | MediaMTX RTSP ingest     | **10.10.0.1** (WG)  | WireGuard only            | the camera publish target |
| **8000/udp**       | MediaMTX RTP             | **10.10.0.1** (WG)  | WireGuard only            | RTSP/UDP media (TCP used in practice) |
| **8001/udp**       | MediaMTX RTCP            | **10.10.0.1** (WG)  | WireGuard only            | RTSP/UDP control |
| **8888/tcp**       | MediaMTX LL-HLS          | **127.0.0.1**       | Loopback (nginx → it)     | served publicly as `/coop/` |
| **8889/tcp**       | MediaMTX WHEP signaling  | **127.0.0.1**       | Loopback (nginx → it)     | served publicly as `/coop/whep` |
| **9997/tcp**       | MediaMTX control API     | **127.0.0.1**       | Loopback                  | health/automation only |
| **9998/tcp**       | MediaMTX metrics         | **127.0.0.1**       | Loopback (disabled)       | `metrics: no` |
| `https://<domain>/`            | Viewer page  | nginx :443 → `/var/www/badabing/` | **Public, no login** | static `index.html`/`app.js`/`styles.css` |
| `https://<domain>/coop/whep`   | WHEP signaling | nginx :443 → 127.0.0.1:8889 | Public | WebRTC offer/answer/trickle |
| `https://<domain>/coop/index.m3u8` | LL-HLS   | nginx :443 → 127.0.0.1:8888 | Public | playlist + segments/parts |
| `https://<domain>/api/status.json` | Status JSON | nginx :443 → `/var/www/badabing/api/` | **Public, no login, no-cache** | pushed by the Pi via rrsync |

The stream **path name is `coop`** everywhere — the Pi push URL, `mediamtx.yml`,
the nginx `/coop/` + `/coop/whep` locations, and `app.js` `streamPath`. All four
must agree.

WireGuard addressing: droplet `10.10.0.1/24`, Pi `10.10.0.2/32`, subnet
`10.10.0.0/24`, listen `51820/udp`, Pi `PersistentKeepalive 25`, Pi `AllowedIPs
10.10.0.1/32`. Details in [`NETWORK.md`](NETWORK.md).

---

## Key design decisions (and why)

- **Outbound RTSP/TCP over WireGuard.** The whole point of the project. The Pi is
  behind home NAT and only makes outbound connections; there is **no router
  port-forwarding** and **no inbound path** to the home network — ever. RTSP over
  **TCP** (not UDP) survives a jittery residential uplink without macroblocking,
  and the WireGuard tunnel already encrypts everything (so RTSP itself stays
  plaintext, `rtspEncryption: no`).

- **RTSP ingest bound to the WireGuard IP.** `rtspAddress: 10.10.0.1:8554` (plus
  RTP/RTCP on the same IP) means the ingest is physically unreachable from the
  public internet — a stronger guarantee than a firewall rule alone (though ufw
  *also* denies 8554/8888/8889/9997 belt-and-braces).

- **nginx is the only public TLS front door.** MediaMTX's HLS (8888) and WHEP
  signaling (8889) stay on **loopback**; nginx terminates Let's Encrypt TLS on
  :443 and reverse-proxies to them. One audited surface, real certs, HSTS +
  security headers, and `webrtcTrustedProxies`/`hlsTrustedProxies` set to
  loopback so `X-Forwarded-For` is honored. (nginx footguns are handled
  deliberately: no per-location `proxy_set_header` so server-level headers
  aren't discarded, and security `add_header`s are re-declared in each location
  that adds its own.)

- **WebRTC media on public UDP 8189.** SRTP can't go through an HTTP reverse
  proxy, so the media leg goes browser ↔ droplet public IP directly. The port is
  opened in ufw + the DO cloud firewall; it's safe because it carries no
  credentials (keys come from the already-authenticated DTLS/signaling).
  `webrtcAdditionalHosts` advertises the **reserved-IP literal** (an IP, not a
  DNS name — DNS names break ICE on some browsers), and
  `webrtcIPsFromInterfaces: no` keeps private IPs out of the ICE candidates.

- **LL-HLS as the universal fallback.** WebRTC gives the lowest latency but
  doesn't work everywhere; LL-HLS (1 s segments, 200 ms parts) is CDN-friendly,
  works on Safari/iOS natively, and `app.js` switches to it automatically after
  WebRTC failures.

- **Push model for `status.json` with an rrsync write-only lock.** No backend on
  the droplet: the Pi rsyncs a static file outbound, and the deploy key is forced
  through `rrsync -wo -no-del` into exactly one directory. A leaked key can only
  overwrite `status.json` — no shell, no traversal, no deletes — and it's only
  reachable over WireGuard anyway. The widget is therefore public and read-only
  with zero server-side code.

- **The path name `coop` everywhere.** A single canonical stream name keeps the
  Pi, MediaMTX, nginx, and the browser in lockstep; a mismatch anywhere silently
  breaks publish or playback, so it's deliberately kept identical in all four.

- **Unified web root `/var/www/badabing`.** Both the viewer static files and the
  `api/status.json` live under one document root, so the public site and the
  status endpoint share `root /var/www/badabing` cleanly (the snippet uses
  `root`, not `alias`, to avoid the long-standing nginx `try_files`-under-`alias`
  bug).
