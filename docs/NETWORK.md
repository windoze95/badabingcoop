# Network

Everything between the home and the public internet rides one WireGuard tunnel.
The Pi makes **only outbound** connections; the droplet is the only host the
public ever touches. This doc covers the WireGuard topology, the outbound-only
NAT rationale, key generation and placement, the `AllowedIPs` reasoning, the
ports table, both firewalls, and how the public endpoints map through nginx.

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the subsystem-level picture.

---

## WireGuard topology

```
        HOME (behind NAT)                         DIGITALOCEAN
   ┌───────────────────────┐                 ┌───────────────────────┐
   │ Raspberry Pi (wg0)    │   UDP 51820     │ Droplet (wg0)         │
   │ 10.10.0.2/24          │ ──outbound────▶ │ 10.10.0.1/24          │
   │ AllowedIPs 10.10.0.1/32│  PersistentKA  │ ListenPort 51820      │
   │ Endpoint = <reserved IP>:51820          │ AllowedIPs 10.10.0.2/32│
   └───────────────────────┘                 └───────────────────────┘
            (Pi dials out; the home router needs NO inbound rules)
```

| Item                    | Value                                  |
|-------------------------|----------------------------------------|
| Tunnel subnet           | `10.10.0.0/24`                         |
| Droplet (server) tunnel IP | `10.10.0.1/24`                      |
| Pi (client) tunnel IP   | `10.10.0.2/32`                         |
| WireGuard UDP port      | `51820/udp` (on the droplet)           |
| Pi `Endpoint`           | `<droplet reserved IP>:51820`          |
| Pi `PersistentKeepalive`| `25` seconds                           |
| Pi `AllowedIPs`         | `10.10.0.1/32` (route only the droplet)|
| Droplet peer `AllowedIPs` | `10.10.0.2/32` (the Pi is the only peer) |

Config files:

- **Server:** `droplet/wireguard/wg0.conf` → installed at `/etc/wireguard/wg0.conf`
  on the droplet (chmod 600, root). Holds the **server private key** + the **Pi
  public key**.
- **Client:** `droplet/wireguard/wg0-pi.conf.example` → copy to the Pi as
  `/etc/wireguard/wg0.conf` (chmod 600). Holds the **Pi private key** + the
  **server public key**.

Bring it up with `systemctl enable --now wg-quick@wg0` on each side. On the
droplet, MediaMTX is ordered `After=wg-quick@wg0` (and the unit has a restart
drop-in) because it binds to `10.10.0.1`, which only exists once the tunnel is up.

---

## Outbound-only NAT rationale

This is the entire reason the project exists in this shape:

- The Pi lives on a residential network behind NAT. The home router does **not**
  forward any ports, and there is **no inbound connection to the home network,
  ever**.
- The Pi **dials out** to the droplet on `51820/udp` and holds the NAT mapping
  open with `PersistentKeepalive = 25`. Once the tunnel is established, traffic
  flows both ways *inside* it, but the *initiation* is always from the Pi.
- All home-side traffic uses the tunnel for one purpose only — reaching the
  droplet's `10.10.0.1`:
  - **video**: RTSP/TCP publish to `10.10.0.1:8554`;
  - **telemetry**: `rsync`-over-SSH to `coopstatus@10.10.0.1:22`.
- The droplet deliberately runs **no IP forwarding / MASQUERADE** — it is a media
  endpoint, not a gateway. The Pi doesn't route its general internet over the
  tunnel either (see `AllowedIPs` below).

Net effect: the public attack surface is entirely on the droplet, and even a
fully-compromised droplet cannot reach into the home network — it can only talk
back to `10.10.0.2` over the tunnel, and there's nothing listening there that
matters.

---

## Generating WireGuard keys

Use `wg` from `wireguard-tools`. Generate **two keypairs** — one for the droplet,
one for the Pi:

```bash
# On a trusted machine (or each host). Keys are just text; keep the *private*
# ones secret and never commit them.

# Server (droplet) keypair
wg genkey | tee server_private.key | wg pubkey > server_public.key

# Pi keypair
wg genkey | tee pi_private.key     | wg pubkey > pi_public.key

# OPTIONAL: a pre-shared key for an extra symmetric layer (post-quantum-ish).
# The SAME psk goes on both peers.
wg genpsk > preshared.key
```

(`make gen-keys` wraps this.)

**Where each key goes:**

| Key file              | Goes into                                   | As                  |
|-----------------------|---------------------------------------------|---------------------|
| `server_private.key`  | droplet `wg0.conf` `[Interface] PrivateKey` | the droplet's identity |
| `pi_public.key`       | droplet `wg0.conf` `[Peer] PublicKey`       | who may connect     |
| `pi_private.key`      | Pi `wg0.conf` `[Interface] PrivateKey`      | the Pi's identity   |
| `server_public.key`   | Pi `wg0.conf` `[Peer] PublicKey`            | who the Pi trusts   |
| `preshared.key` (opt) | **both** sides `[Peer] PresharedKey`        | shared extra layer  |

Rule of thumb: a host holds **its own private key** and **the other side's
public key**. A public key is safe to share; a private key never leaves its host.
Replace the `REPLACE_WITH_*_KEY` placeholders in the config files with the actual
key contents.

> Separately, the **telemetry push** uses its own SSH keypair
> (`coopstatus_ed25519`), unrelated to WireGuard. The Pi holds the private half
> at `/etc/badabing/keys/coopstatus_ed25519`; the public half goes in the
> droplet's `coopstatus.authorized_keys` behind the `rrsync` forced-command.

---

## `AllowedIPs` reasoning

`AllowedIPs` in WireGuard is both a **routing table** (what gets sent into the
tunnel) and an **ACL** (what's accepted out of it). The choices here are
deliberately tight:

- **Pi side: `AllowedIPs = 10.10.0.1/32`.** The Pi routes *only* the droplet's
  tunnel IP through WireGuard — nothing else. This is **not** `0.0.0.0/0`: the
  Pi's normal home/internet traffic stays off the tunnel (no needless hairpin
  through the droplet, lower power, simpler routing). The Pi only ever needs to
  reach `10.10.0.1` (RTSP + the status push), so `/32` is exactly enough.
- **Droplet side: `AllowedIPs = 10.10.0.2/32`.** The Pi is the only peer, pinned
  to its single tunnel address. Anything claiming to be another address inside
  the tunnel is dropped.

So each side accepts exactly one in-tunnel host and routes exactly that host —
the minimum that makes video + telemetry work.

---

## Ports & firewalls

The public attack surface is intentionally tiny. **Two** firewalls enforce it
(defense in depth): the DigitalOcean **cloud firewall** (Terraform / DO, blocks
traffic before it reaches the droplet NIC) and **ufw** on the droplet itself
(`droplet/firewall/ufw-setup.sh`). Both allow the same set.

**Allowed inbound (public):**

| Port        | Purpose                                            |
|-------------|----------------------------------------------------|
| `22/tcp`    | SSH (rate-limited; consider source-restricting to your IP). Status push arrives over WG to this port. |
| `80/tcp`    | HTTP — ACME HTTP-01 challenge + 301 redirect to 443 |
| `443/tcp`   | HTTPS — nginx: viewer + `/coop/` HLS + `/coop/whep` signaling + `/api/status.json` |
| `51820/udp` | WireGuard — the Pi dials in                         |
| `8189/udp`  | WebRTC media (SRTP) — required for WHEP video to flow |

**Denied / never public** (bound to loopback or the WireGuard IP; ufw also denies
them explicitly so the intent is auditable):

| Port      | Service                | Why not public                         |
|-----------|------------------------|----------------------------------------|
| `8554/tcp`| MediaMTX RTSP ingest   | bound to `10.10.0.1` (WireGuard only)  |
| `8888/tcp`| MediaMTX LL-HLS        | bound to `127.0.0.1`; nginx fronts it  |
| `8889/tcp`| MediaMTX WHEP signaling| bound to `127.0.0.1`; nginx fronts it  |
| `9997/tcp`| MediaMTX control API   | bound to `127.0.0.1`                    |

ufw defaults: **deny incoming, allow outgoing** (the Pi/WHEP need outbound;
viewers pull). SSH is `limit`ed; logging is on (low) for fail2ban + audits. There
is also SSH hardening (`droplet/ssh/99-hardening.conf`: key-only, no root) and
`fail2ban` (`droplet/fail2ban/jail.local`).

---

## How public endpoints map through nginx

nginx on :443 is the single public TLS door. The map:

```
  https://<domain>/                 ──▶  /var/www/badabing/        (static viewer, PUBLIC, no login)
  https://<domain>/coop/whep        ──▶  http://127.0.0.1:8889/coop/whep   (WebRTC/WHEP signaling)
  https://<domain>/coop/index.m3u8  ──▶  http://127.0.0.1:8888/coop/...    (LL-HLS playlist + parts)
  https://<domain>/coop/...         ──▶  http://127.0.0.1:8888/coop/...    (HLS segments)
  https://<domain>/api/status.json  ──▶  /var/www/badabing/api/status.json (PUBLIC, no login, no-cache)
  https://<domain>/coop/whip        ──▶  403                         (publish-over-proxy blocked on purpose)
  http://<domain>/...               ──▶  301 https (except ACME .well-known)
```

Two things deliberately do **not** pass through nginx:

1. **WebRTC media (SRTP).** Only the WHEP *signaling* (POST/PATCH/DELETE) goes
   through nginx; the actual video flows browser ↔ droplet public IP over **UDP
   8189**, advertised by MediaMTX's `webrtcAdditionalHosts` (the reserved-IP
   literal) and opened in both firewalls.
2. **The RTSP publish.** It arrives on the WireGuard interface
   (`10.10.0.1:8554`), entirely separate from the public HTTP path.

The viewer is **public — there is no `auth_basic`** anywhere. (An opt-in
Basic-Auth block is left commented in `coop.conf` for anyone who later wants to
gate it: uncomment two lines and create an `htpasswd` file. The `/api/` location
would stay public via `auth_basic off`.) TLS is Let's Encrypt via certbot; HSTS
and the other security headers are set on every location.
