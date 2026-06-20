# Setup runbook — The Bada Bing coop cam

End-to-end, copy-pasteable instructions to stand up the whole system: a public
DigitalOcean droplet that serves the viewer, a WireGuard tunnel, and a Raspberry
Pi Zero 2 W at home that pushes the camera (and, optionally, plays music and
reports battery telemetry).

> Conventions
> - `<domain>` = your domain, e.g. `cam.example.com` (placeholder used throughout the repo).
> - `REPLACE_WITH_DROPLET_RESERVED_IP` = the droplet's stable reserved IP.
> - Run `make help` at the repo root to see every target referenced below.
> - The Pi is always **behind home NAT** and only makes outbound connections;
>   you never open a port on your home router.

---

## 0. Prerequisites

- **A domain you control** and the ability to create an `A` record for it.
- **A DigitalOcean account** (and, for the Terraform path, an API token and at
  least one SSH key uploaded to your DO account).
- **Hardware at home:** a Raspberry Pi Zero 2 W + Camera Module 3, an SD card,
  and a 5 V supply (or the solar setup — see `docs/solar-power-budget.md`).
- **A workstation** with: `make`, `git`, `ssh`, `rsync`, `wg`/`wireguard-tools`,
  and (for Path A) `terraform` and optionally `doctl`.
- Clone this repo and work from its root:
  ```bash
  cd /path/to/badabingcoop
  make help
  ```

---

## 1. Generate WireGuard keys

```bash
make gen-keys
```

This produces two keypairs. Note where each half goes (private keys never leave
the host they belong to):

| Key | Goes to |
|---|---|
| **server private** | droplet `/etc/wireguard/wg0.conf` → `[Interface] PrivateKey` (Terraform var `wg_server_private_key`) |
| **server public** | the Pi's `/etc/wireguard/wg0.conf` → `[Peer] PublicKey` |
| **Pi private** | the Pi's `/etc/wireguard/wg0.conf` → `[Interface] PrivateKey` |
| **Pi public** | droplet `/etc/wireguard/wg0.conf` → `[Peer] PublicKey` (Terraform var `wg_pi_public_key`) |

Fixed addressing (do not change): droplet `10.10.0.1/24`, Pi `10.10.0.2/32`,
WireGuard UDP `51820`. The Pi sets `PersistentKeepalive = 25`; the Pi's
`AllowedIPs` is just `10.10.0.1/32`.

(Optional extra hardening: `wg genpsk` and put the same `PresharedKey` in both
`[Peer]` blocks — the commented placeholders are already there.)

---

## 2. Deploy the droplet

Pick **one** path. Path A (Terraform) is recommended.

### Path A — Terraform (recommended)

Provisions the droplet, a **reserved IP**, and a **cloud firewall**, and (if you
use the template) injects secrets via `templatefile(user-data.tftpl)`.

```bash
cd droplet/terraform
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars        # fill in EVERY value (see below)
```

Fill in `terraform.tfvars` (it is gitignored — never commit it):

- `do_token` — your DO API token.
- `region`, `droplet_size` (`s-1vcpu-1gb` is plenty), `droplet_name`.
- `ssh_key_fingerprints` — from `doctl compute ssh-key list`.
- `ssh_public_key` — the matching public key contents.
- `admin_email` — for Let's Encrypt.
- `domain` — your `<domain>`.
- `wg_server_private_key` — the **server private** key from step 1.
- `wg_pi_public_key` — the **Pi public** key from step 1.
- `pi_publish_password` — a strong password the Pi will use to publish RTSP.
- (optional) `ssh_admin_source_addresses = ["<your-ip>/32"]` to lock SSH.

> Note: the default `main.tf` uses `file("../cloud-init/cloud-init.yaml")`
> verbatim and **does not** inject secrets — you would fill the
> `REPLACE_WITH_*` placeholders yourself. To have Terraform inject secrets *and*
> the reserved IP into `webrtcAdditionalHosts` automatically, switch the `local`
> in `main.tf` to `templatefile("${path.module}/user-data.tftpl", { ... })` as
> shown in that file's comment block, then proceed.

Then:

```bash
make tf-init
make tf-plan        # review
make tf-apply
```

Read the outputs — `reserved_ip` is the IP you point DNS at and use everywhere.

### Path B — Manual

Two sub-options:

- **B1 — cloud-init as user-data:** fill the `REPLACE_WITH_*` placeholders in
  `droplet/cloud-init/cloud-init.yaml` (SSH key, domain, email, WireGuard keys,
  publish password, reserved IP), create a bare Ubuntu 24.04 droplet (and a
  reserved IP + cloud firewall by hand), and paste the filled file as the
  droplet's **user-data**. It self-provisions on first boot.
- **B2 — rsync to a bare droplet:** create a bare Ubuntu 24.04 droplet, then:
  ```bash
  make deploy-droplet HOST=chickenadmin@<reserved-ip>
  ```
  This rsyncs the canonical `droplet/` tree up and runs
  `droplet/setup/install.sh` on the box (idempotent).

Keep `cloud-init.yaml` and `user-data.tftpl` consistent with the standalone
`droplet/` config files if you edit either.

---

## 3. Point DNS at the reserved IP (BEFORE certbot)

certbot uses an HTTP-01 challenge on **port 80**, which requires the domain to
already resolve to the droplet.

1. Create an `A` record: `<domain>` → the `reserved_ip` from step 2.
2. Wait for it to propagate (`dig +short <domain>` should return the reserved IP).
3. Make sure **port 80 is reachable** (it is, in both firewalls).

On first boot the droplet:
- serves the ACME challenge from a minimal `:80` bootstrap vhost,
- runs `certbot certonly --webroot -w /var/www/html ... -d <domain>`,
- and only **after** the cert exists swaps in the TLS site (`coop.conf`).

If DNS was not ready at first boot, certbot logs a failure and you can issue the
cert later by hand (see TROUBLESHOOTING → "certbot / ACME failure"):

```bash
ssh chickenadmin@<reserved-ip>
sudo certbot certonly --webroot -w /var/www/html -d <domain> \
     --non-interactive --agree-tos -m <your-email>
sudo rm -f /etc/nginx/sites-enabled/acme-bootstrap.conf
sudo ln -sf /etc/nginx/sites-available/coop.conf /etc/nginx/sites-enabled/coop.conf
sudo nginx -t && sudo systemctl reload nginx
```

Quick droplet sanity check:

```bash
ssh chickenadmin@<reserved-ip>
wg show                                      # tunnel up? (peer may show no handshake until the Pi connects)
systemctl status mediamtx nginx fail2ban     # all active?
sudo ufw status verbose                       # 22/80/443/51820/8189 allowed; 8554/8888/8889/9997 denied
```

---

## 4. Set up the Pi

1. **Flash Raspberry Pi OS Bookworm** (Lite is fine — this is headless) and boot
   the Pi with networking + SSH enabled.
2. **Enable the camera** (and **I2C** only if you plan to use the optional INA219
   battery sensor):
   ```bash
   sudo raspi-config     # Interface Options -> (camera auto-detected on Bookworm); I2C -> Enable (optional)
   ```
   Verify the camera: `rpicam-hello --list-cameras` should list Camera Module 3.
3. **Put the Pi's WireGuard config in place.** Use
   `droplet/wireguard/wg0-pi.conf.example` as the template:
   ```bash
   sudo install -m 600 /dev/stdin /etc/wireguard/wg0.conf   # paste filled contents
   # fill: [Interface] PrivateKey = <Pi private key>
   #       [Peer] PublicKey = <server public key>
   #       Endpoint = REPLACE_WITH_DROPLET_RESERVED_IP:51820
   #       AllowedIPs = 10.10.0.1/32   (keep as-is)
   #       PersistentKeepalive = 25    (keep as-is)
   sudo systemctl enable --now wg-quick@wg0
   wg show                                    # should show a handshake with the droplet
   ping -c2 10.10.0.1                          # the droplet's in-tunnel address
   ```
4. **Fill the stream env** `pi/badabing-stream.env`:
   - `RTSP_USER=chickenpi`
   - `RTSP_PASS=` **must match** the droplet's publish password
     (`pi_publish_password` / `REPLACE_WITH_PI_PUBLISH_PASSWORD` in `mediamtx.yml`).
   - Leave `WG_IP=10.10.0.1`, `RTSP_PORT=8554`, `MTX_PATH=coop`,
     `RTSP_TRANSPORT=tcp` as-is (they must match the droplet).
   - Tune `WIDTH`/`HEIGHT`/`FRAMERATE`/`BITRATE` for your power budget
     (default 1280x720@15, 1.5 Mbps).
5. **Install the core Pi services:**
   ```bash
   make install-pi
   ```
   This installs the streamer + status reporter (`badabing-stream.service`,
   `badabing-status.service` + `.timer`) and their env files under `/etc/badabing`.
   Add `JUKEBOX=1` and/or `BATTERY=1` (see steps 6–7) to include the optional bits.
6. Confirm the stream is publishing:
   ```bash
   sudo systemctl status badabing-stream.service
   journalctl -u badabing-stream.service -f
   ```

---

## 5. Enable the status push

The Pi pushes a small `status.json` to the droplet over WireGuard via an rrsync-
locked, write-only account.

1. **On the Pi**, generate the deploy keypair (no passphrase — the timer runs
   unattended):
   ```bash
   sudo install -d -m 0700 /etc/badabing/keys
   sudo ssh-keygen -t ed25519 -N '' -C 'coopstatus@coop-pi' \
        -f /etc/badabing/keys/coopstatus_ed25519
   sudo chmod 600 /etc/badabing/keys/coopstatus_ed25519
   sudo cat /etc/badabing/keys/coopstatus_ed25519.pub      # copy this public key
   ```
2. **On the droplet**, run the setup script with that public key. It creates the
   shell-less `coopstatus` account, writes the rrsync forced-command
   `authorized_keys`, creates `/var/www/badabing/api`, and installs the nginx
   `/api/` snippet:
   ```bash
   sudo PI_PUBKEY="ssh-ed25519 AAAA... coopstatus@coop-pi" \
        /path/to/droplet/ssh/setup-coopstatus.sh
   # or, with the .pub file present:
   sudo /path/to/droplet/ssh/setup-coopstatus.sh /path/to/coopstatus_ed25519.pub
   ```
3. **Enable the timer on the Pi:**
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable --now badabing-status.timer
   systemctl list-timers badabing-status.timer
   ```
4. Verify the push end-to-end:
   ```bash
   # On the Pi:
   journalctl -u badabing-status.service -f
   # From anywhere:
   curl -s https://<domain>/api/status.json | jq .
   ```

> The remote directory `/var/www/badabing/api` is hard-coded in the rrsync
> forced-command, the nginx `/api/` location, and the Pi reporter. Do not change
> it in only one place.

---

## 6. (Optional) Jukebox — classical music over Bluetooth

> Strongly recommended: use a **USB Bluetooth dongle**, not the Pi Zero 2 W's
> on-board radio. The Zero 2 W shares one 2.4 GHz radio between Wi-Fi and
> Bluetooth, and the camera is already saturating Wi-Fi — on-board A2DP stutters
> badly. See the long coexistence note at the top of `pi/badabing-bt-setup.sh`.

1. **Plug in a USB BT dongle** (CSR8510-class) via the Zero 2 W's USB OTG port.
   With power-tune's `dtoverlay=disable-bt` active, the dongle is the sole
   controller and is `hci0` (the default in `pi/badabing-music.env`).
2. **Set up headless PipeWire** (mandatory for sound with nobody logged in — it
   handles the private D-Bus session bus and disables BlueZ seat-monitoring):
   ```bash
   sudo /usr/local/bin/badabing-pipewire-setup.sh
   ```
3. **Make sure the BT daemon is up** (a camera-only power-tune run may have
   disabled it):
   ```bash
   sudo systemctl unmask bluetooth && sudo systemctl enable --now bluetooth
   ```
4. **Pair the speaker** — put a real MAC in `pi/badabing-music.env`
   (`BT_SPEAKER_MAC=`, find it with `bluetoothctl scan on`), then:
   ```bash
   sudo /usr/local/bin/badabing-bt-setup.sh          # pairs + trusts, one time
   sudo systemctl enable --now badabing-bt-connect.service
   ```
5. **Install the jukebox services:**
   ```bash
   make install-pi JUKEBOX=1
   ```
   This wires up MPD, the now-playing writer, and audio routing.
6. **Get music** — either drop your own legally-clean files into
   `/srv/badabing/music` (then `mpc update`), or fetch a public-domain starter
   set:
   ```bash
   sudo apt install -y python3-internetarchive     # Bookworm is PEP-668; use apt, not pip
   sudo /usr/local/bin/fetch-music.sh --list       # see what it would fetch
   sudo /usr/local/bin/fetch-music.sh              # download CC0 / PD sets
   ```
   Set the **composer/artist** and **title** tags so the now-playing line reads
   nicely (e.g. "Beethoven — Symphony No. 7"). The current track shows up in
   `status.json` (`music.artist` / `music.title`).

---

## 7. (Optional) Battery telemetry — INA219

1. **Wire the INA219** on the pack side per `pi/INA219-WIRING.md` (3.3 V logic —
   never 5 V; SDA→pin 3, SCL→pin 5; VIN+ → battery +, VIN- → buck input +).
2. **Enable I2C and verify:**
   ```bash
   sudo raspi-config       # Interface Options -> I2C -> Enable   (then reboot)
   sudo apt-get install -y i2c-tools python3-smbus2
   i2cdetect -y 1          # the INA219 shows at 0x40 (or your jumper address)
   INA219_ADDR=0x40 INA219_SHUNT_OHMS=0.1 INA219_MAX_AMPS=3.0 \
     /usr/local/bin/badabing-ina219.py     # prints "<volts> <milliamps>"
   ```
3. **Turn it on** in `/etc/badabing/badabing-status.env`:
   `BATTERY_ENABLE=1`, plus `INA219_ADDR`, `INA219_SHUNT_OHMS`,
   `INA219_MAX_AMPS`, and `BATT_FULL_V` / `BATT_EMPTY_V` tuned to your pack
   (defaults assume 4S LiFePO4 ≈ 13.4 V full / 12.0 V empty).
4. **Install with the battery bit and restart the timer:**
   ```bash
   make install-pi BATTERY=1
   sudo systemctl restart badabing-status.timer
   ```
   Within ~15 s `status.json` carries a `"battery": { ... }` block instead of `null`.

---

## 8. Verify the whole system

1. **Open the viewer:** `https://<domain>/` — you should see live video. WebRTC
   (WHEP) is tried first for low latency, with LL-HLS as the fallback.
2. **Check the status widget** on the page, and the raw JSON:
   ```bash
   curl -s https://<domain>/api/status.json | jq .     # uptime, temp, RSSI, stream.up, music, battery
   ```
3. **Stream URLs** (for manual checks):
   - viewer: `https://<domain>/`
   - WHEP signaling: `https://<domain>/coop/whep`
   - LL-HLS manifest: `https://<domain>/coop/index.m3u8`
   - status: `https://<domain>/api/status.json`
4. **On the droplet:**
   ```bash
   wg show                                          # handshake + recent transfer with the Pi
   curl -s http://127.0.0.1:9997/v3/paths/list | jq # MediaMTX: the "coop" path should have a publisher (ready: true)
   sudo systemctl status mediamtx nginx fail2ban
   sudo ufw status verbose
   ```
5. **On the Pi:**
   ```bash
   systemctl status badabing-stream.service badabing-status.timer
   journalctl -u badabing-stream.service -n 50
   wg show ; ping -c2 10.10.0.1
   vcgencmd get_throttled                            # 0x0 = healthy power
   ```

If anything is wrong, see `docs/TROUBLESHOOTING.md` — it maps each common symptom
to a cause and a fix.

---

## Deployment interface quick reference

| Command | What it does |
|---|---|
| `make help` | list all targets |
| `make gen-keys` | generate WireGuard keypairs |
| `make tf-init` / `make tf-plan` / `make tf-apply` | Terraform droplet provisioning |
| `make deploy-droplet HOST=user@ip` | rsync `droplet/` to a bare Ubuntu 24.04 droplet + run `droplet/setup/install.sh` |
| `make install-pi` | install the core Pi services (run **on the Pi**) |
| `make install-pi JUKEBOX=1` | also install the music subsystem |
| `make install-pi BATTERY=1` | also install the INA219 battery telemetry |
| `make lint` | lint shell scripts / configs |
| `make verify-sri` | verify the pinned `hls.js` SRI hash |

Key files referenced above: `droplet/terraform/terraform.tfvars.example`,
`droplet/cloud-init/cloud-init.yaml`, `droplet/terraform/user-data.tftpl`,
`droplet/wireguard/wg0-pi.conf.example`, `droplet/ssh/setup-coopstatus.sh`,
`pi/badabing-stream.env`, `pi/badabing-status.env`, `pi/badabing-music.env`,
`pi/INA219-WIRING.md`.
