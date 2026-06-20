# Troubleshooting — The Bada Bing coop cam

Symptom → cause → fix. Each section gives concrete commands. Run the **First, a
30-second triage** block before diving in — it usually points you straight at the
broken link in the chain.

The signal chain, end to end:

```
camera → rpicam-vid → ffmpeg → RTSP push → WireGuard → MediaMTX → nginx → browser (WHEP / HLS)
                                              status.json: Pi rsync → coopstatus(rrsync) → nginx /api/
```

---

## First, a 30-second triage

```bash
# --- On the Pi ---
wg show                                     # handshake + recent rx/tx with the droplet?
ping -c2 10.10.0.1                           # can the Pi reach the droplet in-tunnel?
systemctl status badabing-stream.service     # streamer running?
journalctl -u badabing-stream.service -n 30  # last errors
vcgencmd get_throttled                        # 0x0 = power OK

# --- On the droplet ---
wg show                                                  # peer handshake from the Pi?
curl -s http://127.0.0.1:9997/v3/paths/list | jq '.items[] | {name, ready, source}'   # is "coop" ready with a publisher?
systemctl status mediamtx nginx
sudo ufw status verbose
sudo nginx -t

# --- From anywhere ---
curl -sI https://<domain>/                    # 200? cert valid?
curl -s  https://<domain>/api/status.json | jq .
```

Where it breaks tells you the section to read: no `wg show` handshake → §RTSP /
WireGuard; `coop` not `ready` → publisher problem; `coop` ready but no video in
browser → §WHEP / §HLS; `nginx -t` fails → §nginx; status missing → §status.

---

## Viewer loads but the video is black / says "closed" / "offline"

**Cause:** the page reached nginx fine, but MediaMTX has no live publisher — i.e.
the Pi is not currently pushing the `coop` path.

**Fix:**
```bash
# Droplet: is anything publishing the coop path?
curl -s http://127.0.0.1:9997/v3/paths/list | jq '.items[] | {name, ready, source, readers: (.readers|length)}'
# If "coop" is missing or ready:false, the Pi isn't publishing. On the Pi:
systemctl status badabing-stream.service
journalctl -u badabing-stream.service -n 50
wg show ; ping -c2 10.10.0.1
```
If the streamer is crash-looping, read its logs — most often it is a WireGuard
outage (see §RTSP push rejected) or a publish-auth mismatch.

---

## WHEP returns 201 but no video ever appears (WebRTC connects, media never flows)

This is the classic WebRTC failure: **signaling succeeds, media does not.** The
SDP exchange goes through nginx fine (HTTP 201), but the SRTP media has nowhere
to go.

**Causes & fixes (check in order):**

1. **UDP 8189 is not open in BOTH firewalls.** Media (SRTP) flows directly over
   UDP 8189 to the droplet's public IP — it does **not** go through nginx.
   ```bash
   # Droplet:
   sudo ufw status verbose | grep 8189            # must be ALLOW
   ss -lun | grep 8189                              # MediaMTX listening on :8189?
   ```
   Also confirm the **DigitalOcean cloud firewall** has an inbound UDP 8189 rule
   (`digitalocean_firewall.cam` in `main.tf`). Both must allow it.
2. **`webrtcAdditionalHosts` is wrong / stale / empty.** MediaMTX advertises this
   value as the ICE candidate the browser connects to for media. If it still
   says `REPLACE_WITH_DROPLET_RESERVED_IP`, or holds the *old* IP after a droplet
   rebuild, media can't be reached.
   ```bash
   grep webrtcAdditionalHosts /usr/local/etc/mediamtx.yml    # must be the current PUBLIC reserved IP
   sudo systemctl restart mediamtx                            # after fixing it
   ```
3. **It's a DNS name, not an IP.** `webrtcAdditionalHosts` **must** be an IP
   literal (the reserved IP). A hostname there breaks ICE on **Firefox**
   specifically. Use the IP.
4. Behind a symmetric NAT on the viewer side, the public STUN
   (`stun.l.google.com:19302`, already configured) usually suffices; if a
   particular viewer still fails, that's a candidate for adding a TURN server to
   `webrtcICEServers2`.

Quick confirmation that it is media-only: if HLS works but WebRTC never shows
video, it is almost always 8189/UDP or `webrtcAdditionalHosts` (next section).

---

## Only HLS ever works; WebRTC never does

**Cause:** WebRTC's UDP media path is blocked while HLS (plain HTTPS over 443)
sails through. Same root causes as above — UDP 8189 closed somewhere, or a wrong/
DNS-name `webrtcAdditionalHosts`. Some restrictive viewer networks also block all
UDP, in which case the HLS fallback is expected and correct.

**Fix:** work the UDP-8189 / `webrtcAdditionalHosts` checklist in the previous
section. If a specific network blocks UDP entirely, HLS is the intended fallback —
nothing to fix server-side.

---

## RTSP push rejected / the Pi can't publish

**Symptoms:** `badabing-stream.service` restarts repeatedly; MediaMTX logs an
auth error or never sees a publisher.

**Cause A — publish password / hash mismatch.** `RTSP_PASS` on the Pi must equal
the plaintext whose value (or `sha256:` hash) is stored for user `chickenpi` in
the droplet's `mediamtx.yml`. The client always sends plaintext; MediaMTX hashes
and compares.
```bash
# Pi:
grep -E 'RTSP_USER|RTSP_PASS' /etc/badabing/badabing-stream.env
# Droplet: confirm the chickenpi user + publish permission on path coop
grep -A4 'user: chickenpi' /usr/local/etc/mediamtx.yml
journalctl -u mediamtx -n 50 | grep -i auth
```
To (re)generate a hash on the droplet:
```bash
echo -n 'YOUR_PLAINTEXT_PASSWORD' | openssl dgst -binary -sha256 | openssl base64
# put "sha256:<that-output>" as the chickenpi pass:, then: sudo systemctl restart mediamtx
```

**Cause B — the Pi can't reach `10.10.0.1` (WireGuard is down).** RTSP rides the
tunnel; if the tunnel is down, the push fails.
```bash
# Pi:
wg show                                     # look for a recent handshake + nonzero transfer
ping -c2 10.10.0.1
sudo systemctl restart wg-quick@wg0
journalctl -u wg-quick@wg0 -n 30
```
Check the basics: the Pi's `Endpoint = <reserved-ip>:51820` is correct, UDP 51820
is open on both droplet firewalls, the keys are the right halves, and
`PersistentKeepalive = 25` is set on the Pi (it keeps the NAT mapping open).
If `wg show` shows no handshake, the keys are almost always swapped or the
endpoint IP is wrong/stale after a droplet rebuild.

**Cause C — path-name mismatch.** All four must be the literal `coop`:
`MTX_PATH` (Pi env), `mediamtx.yml` path, nginx `/coop/`, and `app.js`
`streamPath`. A typo here yields "path not found" on publish.

---

## `nginx -t` fails / nginx returns 502

**`nginx -t` failures:**

- **Missing `/api/` snippet.** `coop.conf` has `include snippets/api-status.conf;`.
  If `/etc/nginx/snippets/api-status.conf` is absent, `nginx -t` fails and nginx
  won't reload. Run `droplet/ssh/setup-coopstatus.sh` (it installs the snippet),
  or copy `droplet/nginx/api-status.conf` to that path.
- **Cert not yet issued.** The `443` block references
  `/etc/letsencrypt/live/<domain>/fullchain.pem`. If that file doesn't exist,
  `nginx -t` fails. Don't enable `coop.conf` until the cert exists — use the
  `acme-bootstrap.conf` vhost to get the cert first (see §certbot).
- **`unknown directive "http2"`** on older nginx: this build uses the legacy
  per-listener `listen 443 ssl http2;` form precisely because Ubuntu 24.04 ships
  nginx 1.24 (the standalone `http2 on;` only exists in 1.25.1+). Keep the legacy
  form.
```bash
sudo nginx -t                       # read the exact line/file it complains about
sudo journalctl -u nginx -n 40
```

**502 Bad Gateway:** nginx is up but can't reach its upstream (MediaMTX on
`127.0.0.1:8888` for HLS or `127.0.0.1:8889` for WHEP).
```bash
systemctl status mediamtx
ss -lnt | grep -E '8888|8889'        # MediaMTX listening on loopback?
journalctl -u mediamtx -n 50
```

**Missing api dir:** if `/var/www/badabing/api` doesn't exist, `/api/status.json`
404s. `setup-coopstatus.sh` creates it (mode `2750`, owner `coopstatus:www-data`).

---

## certbot / ACME failure (no cert, HTTPS down)

**Causes:** DNS not pointed at the reserved IP yet, or port 80 not reachable, or
the challenge couldn't be served.

**Fix:**
```bash
dig +short <domain>                  # must return the droplet's reserved IP
# From outside, port 80 must reach the droplet (both firewalls allow it):
curl -sI http://<domain>/.well-known/acme-challenge/test
# Re-issue with the webroot challenge (the acme-bootstrap vhost serves :80):
sudo certbot certonly --webroot -w /var/www/html -d <domain> \
     --non-interactive --agree-tos -m <your-email>
# Then swap the bootstrap vhost for the TLS site:
sudo rm -f /etc/nginx/sites-enabled/acme-bootstrap.conf
sudo ln -sf /etc/nginx/sites-available/coop.conf /etc/nginx/sites-enabled/coop.conf
sudo nginx -t && sudo systemctl reload nginx
# Confirm the renewal timer is active:
systemctl status certbot.timer
```
Remember the ordering chicken-and-egg: `coop.conf`'s 443 block can't load before
the cert exists, and certbot needs a working nginx on 80 — that's why first boot
uses the bootstrap vhost, gets the cert, then swaps in `coop.conf`.

---

## Status widget shows "offline" or stale data

**Cause A — the timer isn't enabled / firing.**
```bash
# Pi:
systemctl status badabing-status.timer
systemctl list-timers badabing-status.timer        # NEXT/LAST should be ~15s cadence
sudo systemctl enable --now badabing-status.timer
journalctl -u badabing-status.service -n 30
```

**Cause B — the push is failing (key / forced-command / reachability).**
```bash
# Pi: run one push by hand and read the error
sudo systemctl start badabing-status.service ; journalctl -u badabing-status.service -n 20
# Manual rsync to see the raw error:
sudo rsync -e 'ssh -i /etc/badabing/keys/coopstatus_ed25519' \
     /run/badabing/status.json coopstatus@10.10.0.1:./status.json
```
On the droplet, confirm the locked account is set up and the file lands:
```bash
sudo tail -n2 /home/coopstatus/.ssh/authorized_keys   # rrsync -wo -no-del /var/www/badabing/api ...
ls -l /var/www/badabing/api/status.json
sudo journalctl -u ssh -n 30 | grep coopstatus
```
If `setup-coopstatus.sh` was never run (or the Pi's public key isn't in the
`authorized_keys`), the push is rejected — re-run it with the Pi's pubkey.
Also confirm `coopstatus` is still in `AllowUsers` in
`/etc/ssh/sshd_config.d/99-hardening.conf` — removing it silently blocks the push.

**Cause C — clock skew.** `status.json` carries a UTC timestamp; if the Pi's
clock is wrong the widget may look "stale."
```bash
timedatectl status        # check NTP synchronized = yes; fix time, then it self-corrects
```

---

## Pi undervoltage / throttling (random reboots, sluggish, USB drops)

**Cause:** insufficient/under-spec power — an undersized buck converter, thin
USB cable, or a depleted battery on the solar setup.

**Fix:**
```bash
vcgencmd get_throttled
#   0x0          = healthy
#   bit 0  (0x1) = under-voltage NOW
#   bit 16 (0x10000) = under-voltage HAS occurred since boot
vcgencmd measure_volts
vcgencmd measure_temp
```
If you see under-voltage bits: use a beefier 5 V supply / buck converter sized
for the real peak draw (camera + Wi-Fi + any USB dongle), a thicker/shorter
cable, and check the battery state. See `docs/solar-power-budget.md` and
`pi/INA219-WIRING.md`. The streamer's `StartLimitBurst` deliberately stops the
camera after repeated crashes so a dying battery doesn't get pegged by a busy-loop.

---

## Bluetooth audio stutters / cracks

**Cause:** on the Pi Zero 2 W the on-board Bluetooth shares a single 2.4 GHz radio
with Wi-Fi, and the camera is already streaming H.264 over that Wi-Fi 24/7. The
two contend and A2DP audio stutters badly. There is no 5 GHz band to escape to,
and Raspberry Pi closed the upstream bug as "not planned."

**Fix (best first):**
1. **Use a USB Bluetooth dongle** on its own controller so audio doesn't compete
   with the camera's Wi-Fi (recommended). With `dtoverlay=disable-bt` active the
   dongle is the only controller (`hci0`); set `BT_CONTROLLER` accordingly in
   `pi/badabing-music.env` and verify with `bluetoothctl list`.
2. **Go wired:** a $5 USB sound card + wired speaker eliminates 2.4 GHz
   contention entirely (most reliable for an unattended box).
3. If you must use on-board BT, drop the camera bitrate/framerate and accept
   occasional dropouts.

See the long coexistence note at the top of `pi/badabing-bt-setup.sh`.

---

## No sound from the speaker at all (headless)

**Cause:** on a headless Pi (no graphical login) PipeWire/WirePlumber don't run
by default, and two headless gotchas otherwise produce *no* audio sink:
(1) no D-Bus **session** bus, so WirePlumber exits immediately; (2) BlueZ **seat
monitoring** hides the speaker's audio node because there's no active logind seat.

**Fix:** run the system-service PipeWire setup, which handles both:
```bash
sudo /usr/local/bin/badabing-pipewire-setup.sh
sudo systemctl enable --now badabing-pipewire.service badabing-wireplumber.service
# Verify the daemon sees devices:
sudo -u pipewire XDG_RUNTIME_DIR=/run/pipewire \
     DBUS_SESSION_BUS_ADDRESS=unix:path=/run/pipewire/bus wpctl status
```
Then make sure the BT daemon is up (`sudo systemctl enable --now bluetooth`),
the speaker is paired+trusted (`badabing-bt-setup.sh`), and audio is routed to
the A2DP sink:
```bash
sudo /usr/local/bin/badabing-audio-route.sh        # forces a2dp-sink + default sink
```
If `badabing-audio-route.sh` reports "no bluez_card / no A2DP sink," the speaker
isn't connected, is stuck on the low-quality HSP/HFP headset profile, or the
seat-monitoring drop-in didn't take — re-run the pipewire setup and reconnect.

---

## Music won't download (`fetch-music.sh`)

**Cause A — `ia` tool missing / PEP-668.** On Bookworm, Python is
externally-managed, so a bare `pip3 install internetarchive` is refused.
```bash
sudo apt install -y python3-internetarchive
# or, if that package is unavailable:
sudo apt install -y pipx && pipx install internetarchive
```
The script falls back to `wget` if `ia` is absent, but `ia` is more robust over a
flaky solar/Wi-Fi link.

**Cause B — glob syntax.** `ia download --glob` uses **pipe-separated** patterns
(`*.mp3|*.flac|...`), **not** bash brace expansion. The script already uses the
correct form; if you customize it, keep the pipe form for `ia` and the comma list
for `wget -A`.

**After downloading:** fix ownership and rescan so MPD sees the files:
```bash
sudo chown -R mpd:audio /srv/badabing/music
MPD_HOST=/run/mpd/socket mpc update --wait
```
And remember: a public-domain *composition* is not the same as a public-domain
*recording* — verify each archive.org item's license badge (CC0 / PD Mark) before
relying on it for a public stream.

---

## Quick command reference

```bash
# WireGuard
wg show ; sudo systemctl restart wg-quick@wg0 ; journalctl -u wg-quick@wg0

# Services (Pi)
systemctl status badabing-stream.service badabing-status.timer
journalctl -u badabing-stream.service -f
journalctl -u badabing-status.service -n 30

# Services (droplet)
systemctl status mediamtx nginx fail2ban
sudo nginx -t ; sudo systemctl reload nginx
curl -s http://127.0.0.1:9997/v3/paths/list | jq .       # MediaMTX paths
sudo ufw status verbose
sudo fail2ban-client status sshd                          # who's banned

# Health (Pi)
vcgencmd get_throttled ; vcgencmd measure_temp ; vcgencmd measure_volts
i2cdetect -y 1                                            # INA219 at 0x40?
timedatectl status                                        # clock / NTP

# From anywhere
curl -sI https://<domain>/
curl -s  https://<domain>/api/status.json | jq .
```
