# The Bada Bing 🐓🎰

> *Gentlemen's Coop · Live Nightly · Two Drink Minimum (of Water)*

A solar-powered Raspberry Pi Zero 2 W in the backyard streams the chickens to a
public web page, 24/7, neon-Sopranos-marquee style. Tonight's cast: **Tony**
(the rooster, runs the joint), **Adriana** (the headliner), **Pussi** (bantam,
Napoleon streak), and **Rorschach** (broody, mysterious, inkblot plumage).

**What it is:** a backyard chicken-cam with a public, login-free live stream
(low-latency WebRTC, HLS fallback), a now-playing classical-music jukebox, and a
live health/telemetry widget. **How it works:** the Pi lives behind home NAT and
only makes *outbound* connections — it pushes H.264 over RTSP through a WireGuard
tunnel to a cheap DigitalOcean droplet, which runs MediaMTX and an nginx TLS
front door that serves the public viewer. **Why it's built this way:** there is
*never* any inbound connection to the home network and *no* router
port-forwarding — the home side stays sealed.

---

## 🍗 This stream is PUBLIC

There is **no login**. Anyone with the URL can watch the chickens. That is a
deliberate choice. The video, the snapshot, and the status/now-playing widget
are all open to the world. (If you ever change your mind, `nginx` Basic Auth can
be re-enabled by uncommenting two lines and creating an `htpasswd` file — see
the opt-in block in `droplet/nginx/coop.conf`.)

---

## 🏗️ How it hangs together

```
                          HOME (behind NAT, outbound-only)              │            DIGITALOCEAN DROPLET (public)
                                                                        │
  ┌───────────────┐   CSI    ┌──────────────────────────────────┐      │   ┌──────────────────────────────────────────┐
  │ Camera Module │ ───────▶ │ Raspberry Pi Zero 2 W             │      │   │ MediaMTX                                   │
  │ 3 (H.264 HW)  │          │  rpicam-vid → ffmpeg (RTSP push)  │      │   │  RTSP ingest  10.10.0.1:8554 (WG only)     │
  └───────────────┘          │                                  │      │   │  ├─ LL-HLS     127.0.0.1:8888 (loopback)   │
                             │  status.sh → rsync (status.json) │      │   │  └─ WHEP sig.  127.0.0.1:8889 (loopback)   │
                             └───────────────┬──────────────────┘      │   └───────────────┬───────────────┬────────────┘
                                             │                         │                   │ proxy         │ SRTP media
                       ┌─────────────────────┼─────────────────────┐   │           ┌───────┴───────┐       │ (public UDP)
                       │       WireGuard tunnel (UDP 51820)         │   │           │ nginx (TLS)   │       │
                       │  Pi 10.10.0.2  ───outbound──▶  10.10.0.1   │───┼──────────▶│  :443 HTTPS   │       │
                       │  · RTSP/TCP push (video)                   │   │           │  /  viewer    │       │
                       │  · rsync/SSH push (status.json)            │   │           │  /coop/whep   │       │
                       └────────────────────────────────────────────┘   │           │  /coop/*.m3u8 │       │
                                                                        │           │  /api/status… │       │
   ┌──────────────┐    A2DP / Bluetooth                                 │           └───────┬───────┘       │
   │ BT speaker   │ ◀───────────── MPD jukebox (classical, shuffled)    │                   │ HTTPS 443     │ UDP 8189
   └──────────────┘                                                     │                   ▼               ▼
                                                                        │            ┌────────────────────────────┐
   ┌──────────────┐    I2C                                              │            │  Browser (public viewer)   │
   │ INA219 (opt) │ ─────────────▶ status.json (battery telemetry)      │            │  WebRTC ⟂ HLS · widget     │
   └──────────────┘                                                     │            └────────────────────────────┘
```

Three flows ride the same outbound tunnel:

- **VIDEO** — `rpicam-vid` (hardware H.264) → `ffmpeg` (no re-encode) → RTSP/TCP
  push to MediaMTX on the WireGuard IP. Browsers pull it back as WebRTC (WHEP) or
  Low-Latency HLS through nginx.
- **TELEMETRY** — `badabing-status.sh` builds `status.json` (uptime, CPU temp,
  Wi-Fi RSSI, stream up/down, battery, now-playing) and `rsync`s it over SSH
  (also through WireGuard) into one rrsync-locked directory. nginx serves it at
  `/api/status.json` with no login.
- **JUKEBOX** — MPD shuffles a public-domain classical library to a Bluetooth
  speaker; `badabing-nowplaying.sh` watches MPD and emits the current track,
  which the telemetry flow folds into `status.json` for the "Now Spinning"
  ticker.

---

## 🔒 Why this is safe

- **Outbound-only.** The Pi *dials out* to the droplet (WireGuard UDP 51820, with
  `PersistentKeepalive`). Nothing ever connects *in* to the home network.
- **No port-forwarding, ever.** The home router needs zero inbound rules. There
  is no public service on the home side to attack.
- **RTSP is bound to the tunnel.** MediaMTX's RTSP ingest listens on
  `10.10.0.1:8554` — the WireGuard interface only — so the camera feed is
  unreachable from the public internet by construction.
- **One public TLS front door.** Only nginx (port 443, plus 80→443 redirect, WG
  51820/udp, and WebRTC media on 8189/udp) is exposed. HLS, WHEP signaling, and
  the MediaMTX API stay on loopback. Two firewalls (ufw + DO cloud firewall)
  enforce it.
- **Write-only status push.** The Pi's deploy SSH key is forced through `rrsync`
  to a single directory (`-wo -no-del`): even if it leaked, it can only write
  `status.json` — no shell, no other paths, no deletes.

---

## 🗺️ Repo map

```
badabingcoop/
├── README.md                      ← you are here
├── docs/
│   ├── ARCHITECTURE.md            subsystems, data flow, canonical port table, design decisions
│   ├── NETWORK.md                 WireGuard topology, key generation, firewalls, endpoint mapping
│   └── solar-power-budget.md      panel/battery sizing for the off-grid build
│
├── pi/                            ── runs ON the Raspberry Pi (Raspberry Pi OS Bookworm) ──
│   ├── badabing-stream.sh         rpicam-vid → ffmpeg RTSP push (the camera pipeline)
│   ├── badabing-stream.env        capture/encode + RTSP target tunables
│   ├── badabing-stream.service    systemd unit (Restart=always) for the stream
│   ├── badabing-status.sh         builds status.json, rsyncs it to the droplet over WG
│   ├── badabing-status.env        telemetry/push tunables
│   ├── badabing-status.service    oneshot that runs the reporter
│   ├── badabing-status.timer      fires the reporter every ~15s
│   ├── badabing-ina219.py         optional INA219 battery voltage/current reader (I2C)
│   ├── INA219-WIRING.md           how to wire the battery monitor
│   ├── badabing-music.env         jukebox tunables (speaker MAC, library, now-playing files)
│   ├── mpd.conf                   MPD config (PipeWire/Pulse out → Bluetooth A2DP)
│   ├── badabing-mpd.service       MPD player unit
│   ├── badabing-mpd-init.sh/.service  arm endless shuffle + route audio at boot
│   ├── badabing-nowplaying.sh/.service  watch MPD, emit nowplaying.{txt,json}
│   ├── badabing-starter-playlist.m3u    seed playlist
│   ├── fetch-music.sh             download genuinely-free public-domain recordings (Musopen)
│   ├── badabing-bt-setup.sh       ONE-TIME pair+trust the Bluetooth speaker
│   ├── badabing-bt-connect.sh/.service  auto-reconnect the trusted speaker
│   ├── badabing-audio-route.sh    force A2DP sink as the default output
│   ├── badabing-pipewire-setup.sh run PipeWire/WirePlumber as system services (headless)
│   └── badabing-power-tune.sh/.service  trim idle power (LEDs/HDMI/BT off) for solar
│
└── droplet/                       ── runs ON the DigitalOcean droplet (Ubuntu 24.04) ──
    ├── mediamtx/mediamtx.yml      MediaMTX: RTSP ingest (WG), LL-HLS + WHEP (loopback), SRTP 8189
    ├── nginx/coop.conf            TLS front door: viewer + /coop/whep + /coop/ HLS (PUBLIC, no auth)
    ├── nginx/api-status.conf      snippet: serves /api/status.json, no login, no-cache
    ├── wireguard/wg0.conf         server WireGuard config (10.10.0.1/24, :51820)
    ├── wireguard/wg0-pi.conf.example  Pi-side WireGuard config template
    ├── firewall/ufw-setup.sh      ufw: allow 22/80/443/51820·udp/8189·udp, deny the rest
    ├── fail2ban/jail.local        fail2ban jails (sshd, nginx)
    ├── ssh/99-hardening.conf      SSH hardening drop-in (key-only, no root)
    ├── ssh/coopstatus.authorized_keys  rrsync forced-command for the status deploy key
    ├── ssh/setup-coopstatus.sh    create the write-only coopstatus deploy account
    ├── systemd/mediamtx.service   MediaMTX unit (After=wg-quick@wg0)
    ├── systemd/wg-quick@wg0…override.conf  restart resilience for the tunnel
    ├── web/index.html             the neon viewer page (cast bios, widget, jukebox ticker)
    ├── web/app.js                 WHEP-first player with HLS fallback + snapshot
    ├── web/styles.css             the Bada Bing neon look
    ├── cloud-init/cloud-init.yaml manual user-data (annotated, placeholder copy)
    └── terraform/                 droplet + reserved IP + cloud firewall, secrets via templatefile
```

---

## 🚀 Quickstart

Full step-by-step lives in **[`docs/SETUP.md`](docs/SETUP.md)**. The short version,
driven by the repo-root `Makefile`:

```bash
make help                       # list every target

# 1. Keys
make gen-keys                   # generate the WireGuard keypairs

# 2. Droplet (pick ONE path)
make tf-init && make tf-plan && make tf-apply        # Terraform (recommended)
#   …or provision a bare Ubuntu 24.04 droplet, then:
make deploy-droplet HOST=root@<droplet-ip>           # rsync droplet/ + run install.sh

# 3. Raspberry Pi (run ON the Pi)
make install-pi                 # core services
JUKEBOX=1 BATTERY=1 make install-pi   # add the Bluetooth jukebox + battery telemetry

# 4. Sanity
make lint                       # shellcheck / config linting
make verify-sri                 # confirm the hls.js SRI hash matches the CDN bytes
```

Then fill the placeholders (domain, droplet reserved IP, WireGuard keys, publish
password, your email/SSH key, the speaker MAC) — they are intentionally left as
`REPLACE_WITH_*` / `cam.example.com` so nothing real is ever committed.

---

## ✨ Features

- 📺 **Public live stream** — low-latency **WebRTC (WHEP)** with automatic
  **LL-HLS** fallback (and native HLS on Safari/iOS), auto-reconnect with backoff.
- 📸 **Snapshot** — one-tap grab of the current frame to a watermarked PNG.
- 📊 **Public status widget** — live uptime, CPU temp, Wi-Fi RSSI, stream
  up/down, optional battery %, all login-free from `status.json`.
- 🎶 **Now-Spinning jukebox** — headless MPD shuffling **public-domain classical**
  recordings to a **classic-Bluetooth (A2DP)** speaker, with the current track on
  the page.
- ☀️ **Solar-friendly** — 720p15 hardware H.264, aggressive idle-power tuning,
  optional INA219 battery telemetry. See `docs/solar-power-budget.md`.

---

## 💸 Cost ballpark

- **Droplet:** the cheapest DigitalOcean Basic droplet (~$4–6/mo) is plenty — it
  only proxies one stream and serves a static page.
- **Reserved (floating) IP:** free while attached to a running droplet.
- **Domain:** ~$10–15/yr (your registrar of choice).
- **TLS:** free (Let's Encrypt / certbot).
- **Hardware (one-time):** Pi Zero 2 W, Camera Module 3, SD card, solar panel +
  LiFePO4 battery + charge controller, optional INA219 and a USB Bluetooth dongle.

So roughly **a few dollars a month** plus a one-time hardware spend.

---

## 📄 License

MIT. See `LICENSE`. Do whatever you want; the chickens waive all rights.
