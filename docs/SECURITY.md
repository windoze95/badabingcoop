# Security model — The Bada Bing coop cam

This document is the threat model and security posture for the whole system: the
Raspberry Pi at home, the WireGuard tunnel, and the public DigitalOcean droplet
that serves the viewer. If a sentence here ever disagrees with a config file,
the config file is a bug — open an issue.

The one-line summary: **the home network is never reachable from the internet.**
The Pi only ever makes *outbound* connections. The only thing the public can
touch is one hardened nginx on the droplet, and (by deliberate choice) the live
video behind it is public — but the home network behind the Pi is fully isolated
regardless.

---

## 1. Topology and trust boundaries

```
   ┌──────────────── HOME (behind NAT) ────────────────┐        ┌──────── PUBLIC INTERNET ────────┐
   │                                                    │        │                                 │
   │   Raspberry Pi Zero 2 W  (10.10.0.2)               │        │   Viewers (browsers)            │
   │     - rpicam-vid → ffmpeg → RTSP push              │        │        │  HTTPS 443             │
   │     - rsync status.json push                       │        │        ▼  UDP 8189 (WebRTC)     │
   │     - jukebox (optional)                           │        │   ┌─────────────────────────┐   │
   │            │                                       │        │   │  DigitalOcean droplet   │   │
   │            │  OUTBOUND ONLY                        │        │   │  (10.10.0.1)            │   │
   │            ▼  UDP 51820 (WireGuard)  ───────────────────────┼──▶│  nginx (TLS front door) │   │
   │                                                    │        │   │  MediaMTX (loopback/wg) │   │
   │   Home router: NO port-forwarding, NO inbound      │        │   └─────────────────────────┘   │
   └────────────────────────────────────────────────────┘        └─────────────────────────────────┘
```

Trust boundaries, from least to most trusted:

1. **The public internet → the droplet.** Only TCP 443 (nginx), TCP 80 (ACME +
   redirect), UDP 51820 (WireGuard), and UDP 8189 (WebRTC SRTP media) are open.
   Everything else is denied by *two* firewalls (see §3).
2. **The droplet → the home network.** There is **none**. The droplet never
   initiates a connection into the home. The WireGuard tunnel only carries the
   Pi's outbound pushes; the droplet's `AllowedIPs` for the Pi peer is a single
   `/32` (`10.10.0.2/32`), and the Pi's `AllowedIPs` for the droplet is a single
   `/32` (`10.10.0.1/32`). Neither side routes anything but the other's tunnel
   address. No IP forwarding / MASQUERADE is configured on the droplet.
3. **The WireGuard tunnel itself.** Authenticated and encrypted by WireGuard
   (Curve25519). Optionally a pre-shared key (`wg genpsk`) for extra hardening —
   the placeholder is present in both `wg0.conf` files, commented out.

**Why this shape matters:** a residential network has no business accepting
inbound connections. By making the Pi dial *out* to a cheap droplet, there is no
router port-forward to misconfigure, no inbound hole into the LAN, and the public
attack surface is one small, single-purpose Ubuntu box you can rebuild from
scratch at any time.

---

## 2. The PUBLIC viewer decision (stated plainly)

**The live stream and the status widget are public. Anyone who has the URL can
watch.** This is an intentional choice by the operator — the camera points at a
backyard chicken coop, not anything sensitive.

What "public viewer" does **and does not** mean:

- It **does** mean there is no login on `https://<domain>/`, on the WHEP/HLS
  stream, or on `/api/status.json`. There is intentionally **no nginx
  `auth_basic` / `auth_basic_user_file`** anywhere in the live configuration.
- It **does not** weaken the home-network isolation in §1 in any way. Public
  viewers reach *only* nginx on the droplet. They never touch MediaMTX directly
  (it listens on loopback / WireGuard only), and they can never reach the Pi or
  the LAN. A flood of viewers can, at worst, load the droplet — not the home.

If you are uncomfortable with a public stream, see **§10, "Locking it down
later."** Re-enabling Basic Auth is two uncommented lines plus an htpasswd file.

---

## 3. Two firewalls (defense in depth)

Both firewalls enforce the same tiny allow-list. The DigitalOcean **cloud
firewall** (Terraform `digitalocean_firewall.cam`) blocks traffic before it even
reaches the droplet's NIC; **ufw** (`droplet/firewall/ufw-setup.sh`) enforces the
same rules on the host so the box is still protected if it is ever moved off DO
or the cloud firewall is detached.

| Port / proto | Allowed? | Purpose | Why it is safe |
|---|---|---|---|
| 22/tcp | allow (rate-limited; lock to your IP) | SSH admin + status push | key-only, hardened, fail2ban |
| 80/tcp | allow | ACME HTTP-01 + redirect to 443 | serves only the challenge + a 301 |
| 443/tcp | allow | nginx: viewer + HLS + WHEP signaling | the only public app surface |
| 51820/udp | allow | WireGuard (the Pi dials in) | authenticated/encrypted by WireGuard |
| 8189/udp | allow | WebRTC media (SRTP) | carries no credentials (DTLS-SRTP keyed via already-authenticated signaling) |
| **8554/tcp** | **DENY** | RTSP ingest | bound to `10.10.0.1` (WireGuard) only |
| **8888/tcp** | **DENY** | HLS | bound to `127.0.0.1`; nginx fronts it |
| **8889/tcp** | **DENY** | WebRTC signaling | bound to `127.0.0.1`; nginx fronts it |
| **9997/tcp** | **DENY** | MediaMTX control API | bound to `127.0.0.1` only |

The deny rules on 8554/8888/8889/9997 are belt-and-braces: those services are
already bound to loopback or the WireGuard IP in `mediamtx.yml`, so they are not
reachable publicly even without the deny — but the explicit deny makes the intent
auditable and protects against a future config slip that accidentally rebinds one
of them to `0.0.0.0`.

**MediaMTX bind audit (`droplet/mediamtx/mediamtx.yml`):**

- `rtspAddress: 10.10.0.1:8554`, `rtpAddress: 10.10.0.1:8000`,
  `rtcpAddress: 10.10.0.1:8001` — WireGuard IP only.
- `hlsAddress: 127.0.0.1:8888`, `webrtcAddress: 127.0.0.1:8889`,
  `apiAddress: 127.0.0.1:9997` — loopback only.
- `webrtcLocalUDPAddress: :8189` — the **only** publicly-bound MediaMTX listener,
  and the only one allowed through both firewalls.

---

## 4. TLS / HTTPS

- TLS is terminated **only** at nginx on the droplet, using a Let's Encrypt
  certificate issued by certbot (HTTP-01 webroot challenge on first boot, then
  renewed automatically by `certbot.timer`).
- `ssl_protocols TLSv1.2 TLSv1.3;` — no SSLv3/TLS1.0/1.1.
- A modern ECDHE cipher suite, `ssl_session_tickets off`, and short session
  cache are configured in `droplet/nginx/coop.conf`.
- **HSTS** is enabled: `Strict-Transport-Security "max-age=63072000"` (2 years).
  Turn HSTS on only once you are confident HTTPS works for the domain — once a
  browser has seen the header it will refuse plain HTTP for that long.
- Additional response headers: `X-Content-Type-Options: nosniff`,
  `Referrer-Policy: no-referrer`.
- **nginx `add_header` inheritance footgun:** the moment a `location` block
  declares *any* `add_header`, it drops *all* server-level `add_header`
  directives for that location. That is why the security headers are re-declared
  inside the `/coop/` and `/api/` blocks. If you add a new `location` with its
  own `add_header`, you must re-declare HSTS/nosniff/Referrer-Policy there too.
- The Pi → droplet RTSP push is **not** TLS-encrypted at the RTSP layer
  (`rtspEncryption: "no"`) — it does not need to be, because it rides *inside*
  the WireGuard tunnel, which already encrypts everything.

---

## 5. SSH hardening

Source of truth: `droplet/ssh/99-hardening.conf` (installed at
`/etc/ssh/sshd_config.d/99-hardening.conf`).

- `PermitRootLogin no`, `PasswordAuthentication no`,
  `KbdInteractiveAuthentication no`, `PermitEmptyPasswords no` — **key-only**.
- `AllowUsers chickenadmin coopstatus` — only two accounts may log in:
  - `chickenadmin` — the interactive admin (member of `sudo`, NOPASSWD).
  - `coopstatus` — the restricted, shell-less status-push account (see §6).
    **Do not remove it from `AllowUsers`** or the status feature silently breaks.
- Reduced surface: `X11Forwarding no`, `AllowAgentForwarding no`,
  `AllowTcpForwarding no`, `PermitTunnel no`, `MaxAuthTries 3`, `MaxSessions 4`,
  `LoginGraceTime 20`.
- Modern crypto only: post-quantum-ish KEX (`sntrup761x25519`), AEAD ciphers
  (`chacha20-poly1305`, AES-GCM), ETM MACs, Ed25519/RSA-SHA2 host & user keys.
- `LogLevel VERBOSE` so fail2ban and audits have data.

**Hardening tip:** lock SSH to your own IP. In Terraform set
`ssh_admin_source_addresses = ["203.0.113.7/32"]`; or in `ufw-setup.sh` replace
`ufw limit 22/tcp` with `ufw limit from <your-ip> to any port 22 proto tcp`.

> Warning: `PasswordAuthentication no` means your SSH **public** key must already
> be installed (cloud-init / Terraform `ssh_keys` does this) before the hardening
> drop-in is applied, or you will lock yourself out. Always validate with
> `sshd -t` before `systemctl reload ssh`.

---

## 6. The status-push key is write-only and path-locked (rrsync)

The Pi reports health by `rsync`-ing one file, `status.json`, to the droplet over
WireGuard. The account it uses is locked down so hard that a leaked key is nearly
worthless.

Source of truth: `droplet/ssh/coopstatus.authorized_keys` and
`droplet/ssh/setup-coopstatus.sh`.

- The `coopstatus` account has shell `/usr/sbin/nologin` and a locked password.
- Its `authorized_keys` line forces a command and disables tunneling:
  ```
  command="/usr/bin/rrsync -wo -no-del /var/www/badabing/api",
  no-pty,no-agent-forwarding,no-port-forwarding,no-X11-forwarding ssh-ed25519 AAAA...
  ```
- `command=` replaces whatever the client asks to run with **rrsync**, which:
  - confines every path to the single directory `/var/www/badabing/api`
    (rejects absolute paths and `..` traversal),
  - `-wo` = **write-only** (the key can write files but not read the dir back),
  - `-no-del` forbids `--delete*` / `--remove*`,
  - filters rsync's server options down to a safe subset, rejecting tricks like
    `--copy-links` and `-s/--secluded-args`.
- `no-pty` → no interactive shell; the forwarding restrictions → the key cannot
  be turned into a tunnel or a pivot into the droplet or the LAN.
- **Network-locked too:** the account is only reachable over WireGuard
  (SSH:22 is rate-limited and ideally IP-locked at the firewall), so a leaked key
  is both path-locked *and* network-locked.

Verify the lock holds — these MUST fail:

```bash
ssh -i KEY coopstatus@10.10.0.1                              # -> no shell
rsync -e 'ssh -i KEY' /etc/passwd coopstatus@10.10.0.1:../../etc/   # -> rejected (escape attempt)
```

> Hard requirement: the `/var/www/badabing/api` path is baked into the rrsync
> forced-command, the nginx `/api/` location, and the Pi reporter. Do not change
> it in one place without the others.

---

## 7. The PUBLIC `status.json` contract

`status.json` is served to anyone at `/api/status.json` with `Cache-Control:
no-cache` and **no login**. Because it is public, it must contain **only
non-sensitive fields**.

**Allowed (what the Pi reporter actually emits — `pi/badabing-status.sh`):**

- `schema`, `host` (the Pi's hostname), `ts` / `ts_epoch`
- `uptime_s`, `load` (1/5/15-min), `cpu_temp_c`
- `wifi_rssi_dbm` (signal strength, dBm)
- `stream` (`up`, `unit_active`, `last_frame_age_s`)
- `music` (`playing`, `artist`, `title`)
- `battery` (`voltage`, `current_ma`, `percent`) or `null`

**NEVER allowed in `status.json`:**

- GPS coordinates / street address / any location data
- public IPs, the reserved IP, the home WAN IP, or LAN topology
- WireGuard keys, the publish password, the SSH key, any secret/hash
- file paths, tokens, or anything that aids an attacker

If you extend the reporter, treat every new field as world-readable. When in
doubt, leave it out. (The `host` field is the Pi's hostname, e.g. `coop-pi` —
keep hostnames non-identifying if that matters to you.)

---

## 8. fail2ban

Source of truth: `droplet/fail2ban/jail.local`. Backend is the systemd journal.

- `[sshd]` — `mode = aggressive`, ban after 3 failures in 10 min for 2 h
  (catches "no matching key exchange / preauth" noise too).
- `[nginx-http-auth]` — bans Basic Auth brute-forcers. **Only relevant if you
  re-enable Basic Auth (§10);** harmless to leave enabled while the viewer is
  public (it simply never sees auth failures).
- `[nginx-botsearch]` — bans path-probing scanners (8 hits / 10 min → 1 h ban).
- `[recidive]` — escalates repeat offenders: banned 3+ times in a day → 1 week.
- `ignoreip = 127.0.0.1/8 ::1 10.10.0.0/24` — never ban yourself or the tunnel.

---

## 9. Service sandboxing (systemd)

Both the droplet and Pi services run with tight systemd sandboxes so a
compromised service is heavily contained:

- **MediaMTX** (`droplet/systemd/mediamtx.service`, mirrored in cloud-init): runs
  as the unprivileged `mediamtx` user with `NoNewPrivileges`, `ProtectSystem=strict`,
  `ProtectHome`, `ProtectKernelTunables/Modules`, `MemoryDenyWriteExecute`,
  `CapabilityBoundingSet=` (empty — no capabilities),
  `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX`, and a read-only config.
- **Pi streamer** (`pi/badabing-stream.service`): `NoNewPrivileges`,
  `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, plus a *minimal explicit*
  `DeviceAllow` list for exactly the camera/encoder nodes it needs (V4L2, media,
  DMA heaps, vchiq) — nothing else.
- **Pi status reporter** (`pi/badabing-status.service`): runs as root (it must
  read sensors, query systemd, and read the 0600 deploy key) but is sandboxed
  with `ProtectSystem=strict`, `ProtectHome=true`, `PrivateTmp`,
  `RestrictAddressFamilies`, and `ReadWritePaths=/run/badabing` only.

---

## 10. Locking it down later (re-enabling Basic Auth)

The viewer is public by design, but a clearly-commented **opt-in** Basic Auth
block is provided so you can gate it later without redesigning anything.

To put the **live video** behind a password while keeping the **status widget**
public:

1. Create an htpasswd file on the droplet:
   ```bash
   sudo htpasswd -c /etc/nginx/.htpasswd_coop viewer
   # add more users later WITHOUT -c:  sudo htpasswd /etc/nginx/.htpasswd_coop alice
   ```
2. In `/etc/nginx/sites-available/coop.conf`, uncomment the two opt-in lines in
   the `server { ... }` block:
   ```nginx
   auth_basic           "Chicken Cam";
   auth_basic_user_file /etc/nginx/.htpasswd_coop;
   ```
   (The same opt-in block is present, commented, in
   `droplet/cloud-init/cloud-init.yaml`.)
3. **Leave the `/api/` location's `auth_basic off;` intact** so the status widget
   stays public even when the video is gated. (If you want the status widget
   private too, remove that `auth_basic off;` line.)
4. Test and reload:
   ```bash
   sudo nginx -t && sudo systemctl reload nginx
   ```
   fail2ban's `[nginx-http-auth]` jail (already enabled) will now actively ban
   anyone brute-forcing the login.

That's it — two uncommented lines and one htpasswd file restore a private stream.

---

## 11. Secret handling — never commit keys or tfvars

Secrets live **only** on the machines that need them, never in git.

- **`.gitignore` (`droplet/terraform/.gitignore`)** excludes `*.tfstate*`,
  `*.tfvars` (but keeps `*.tfvars.example`), `.terraform/`, the lock file, and
  WireGuard `*.key` / `*_public.key` files generated in that directory. Copy
  `terraform.tfvars.example` → `terraform.tfvars` (gitignored) and fill it in, or
  pass secrets via `TF_VAR_*` env vars. **Never commit the real `terraform.tfvars`.**
- **WireGuard keys** (`make gen-keys`): the *private* server key goes only into
  the droplet's `/etc/wireguard/wg0.conf`; the *private* Pi key goes only into
  the Pi's `/etc/wireguard/wg0.conf`; each side holds only the *other's* public
  key. Private keys never leave the host they belong to.
- **The publish password** (`pi_publish_password` / `REPLACE_WITH_PI_PUBLISH_PASSWORD`)
  is shared between the Pi (`pi/badabing-stream.env`, plaintext) and the droplet
  (`mediamtx.yml`, ideally stored as a `sha256:` hash — the client always sends
  the plaintext, MediaMTX hashes and compares).
- **The status-push SSH key** is generated *on the Pi* with no passphrase (so the
  timer runs unattended), kept `0600`, and only its public half is placed in the
  droplet's `coopstatus` `authorized_keys`.
- All the canonical config files ship with `REPLACE_WITH_*` placeholders, never
  real values — so a checkout never contains a working credential.

---

## 12. Patching & maintenance

- The droplet installs `unattended-upgrades` via cloud-init for automatic
  security patching of the OS packages.
- MediaMTX is **pinned** to an exact release (`v1.19.1`) downloaded from GitHub;
  bump it deliberately and re-verify the config schema (the keys change across
  versions — see the comments at the top of `mediamtx.yml`).
- `hls.js` in the viewer is pinned to `1.6.16` with a Subresource Integrity (SRI)
  hash verified against the real CDN bytes. **Do not change the version or the
  hash** without re-verifying (`make verify-sri`); a mismatched hash means the
  browser refuses to load the player.
- Rebuild posture: the droplet is disposable. Because the reserved IP is stable
  and all config is in this repo, you can destroy and re-create the droplet and
  only need to re-issue the cert and re-run `setup-coopstatus.sh`.
