#!/usr/bin/env bash
# =============================================================================
# droplet/setup/install.sh
#
# Provision the chicken-cam PUBLIC PROXY droplet from the canonical droplet/
# config files in THIS repo. Run as root on a bare Ubuntu 24.04 LTS droplet:
#
#   sudo bash droplet/setup/install.sh
#
# This is the imperative twin of droplet/cloud-init/cloud-init.yaml: it installs
# the exact same set of files/services, but from the tracked droplet/ tree (so
# `make deploy-droplet` can rsync the tree up and run this). It is IDEMPOTENT —
# re-running it re-applies config and restarts services without breaking a
# working box. It does NOT fill REPLACE_WITH_* placeholders; you fill those
# (by hand, via Terraform templatefile, or a secrets overlay) and re-run.
#
# What it does (each step guarded so re-runs are safe):
#   1. base packages
#   2. WireGuard            (droplet/wireguard/wg0.conf -> /etc/wireguard/)
#   3. MediaMTX v1.19.1     (pinned release binary + droplet/mediamtx/mediamtx.yml)
#   4. nginx                (droplet/nginx/coop.conf + api-status snippet; web root)
#   5. certbot              (webroot ACME bootstrap; prints the cmd if DNS not ready)
#   6. ufw                  (runs droplet/firewall/ufw-setup.sh)
#   7. fail2ban             (droplet/fail2ban/jail.local)
#   8. SSH hardening        (droplet/ssh/99-hardening.conf)
#
# After it finishes it prints clear NEXT STEPS (fill placeholders, create the
# coopstatus deploy account with the Pi's pubkey, point DNS, issue the cert).
# =============================================================================
set -euo pipefail

# Pinned MediaMTX release (matches mediamtx.yml + cloud-init.yaml).
MTX_VERSION="v1.19.1"
MTX_ARCH="linux_amd64"

# Resolve the repo's droplet/ dir from this script's location (setup/ -> ..).
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
DROPLET_DIR="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"

log()  { echo "[install] $*"; }
warn() { echo "[install] WARNING: $*" >&2; }
die()  { echo "[install] ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "must run as root (sudo bash $0)"

# Verify we can see the canonical config files we install from.
for f in \
    "${DROPLET_DIR}/wireguard/wg0.conf" \
    "${DROPLET_DIR}/mediamtx/mediamtx.yml" \
    "${DROPLET_DIR}/systemd/mediamtx.service" \
    "${DROPLET_DIR}/systemd/wg-quick@wg0.service.d-override.conf" \
    "${DROPLET_DIR}/nginx/coop.conf" \
    "${DROPLET_DIR}/nginx/api-status.conf" \
    "${DROPLET_DIR}/firewall/ufw-setup.sh" \
    "${DROPLET_DIR}/fail2ban/jail.local" \
    "${DROPLET_DIR}/ssh/99-hardening.conf" ; do
    [[ -f "$f" ]] || die "missing canonical config: $f (run from a full droplet/ tree)"
done

export DEBIAN_FRONTEND=noninteractive

# -----------------------------------------------------------------------------
log "1/8 base packages"
# -----------------------------------------------------------------------------
apt-get update -y
apt-get install -y --no-install-recommends \
    nginx certbot python3-certbot-nginx \
    wireguard wireguard-tools \
    ufw fail2ban apache2-utils \
    curl ca-certificates tar rsync unattended-upgrades

# -----------------------------------------------------------------------------
log "2/8 WireGuard"
# -----------------------------------------------------------------------------
install -d -m 0700 /etc/wireguard
install -m 0600 "${DROPLET_DIR}/wireguard/wg0.conf" /etc/wireguard/wg0.conf
# Restart-resilience drop-in for the templated wg-quick@.service.
install -d -m 0755 /etc/systemd/system/wg-quick@wg0.service.d
install -m 0644 "${DROPLET_DIR}/systemd/wg-quick@wg0.service.d-override.conf" \
    /etc/systemd/system/wg-quick@wg0.service.d/override.conf
systemctl daemon-reload
if grep -q 'REPLACE_WITH_' /etc/wireguard/wg0.conf; then
    warn "wg0.conf still has REPLACE_WITH_* placeholders; NOT starting wg-quick@wg0 yet."
    warn "Fill the keys then: systemctl enable --now wg-quick@wg0"
else
    systemctl enable wg-quick@wg0
    # 'restart' (not just start) so an edited config takes effect on re-runs.
    systemctl restart wg-quick@wg0 || warn "wg-quick@wg0 failed to come up (check keys)."
fi

# -----------------------------------------------------------------------------
log "3/8 MediaMTX ${MTX_VERSION}"
# -----------------------------------------------------------------------------
# Dedicated unprivileged service account.
id mediamtx >/dev/null 2>&1 || \
    useradd --system --no-create-home --shell /usr/sbin/nologin mediamtx
# Install the pinned binary only if missing or version differs.
need_mtx=1
if [[ -x /usr/local/bin/mediamtx ]]; then
    if /usr/local/bin/mediamtx --version 2>/dev/null | grep -q "${MTX_VERSION#v}"; then
        need_mtx=0
        log "  mediamtx ${MTX_VERSION} already installed"
    fi
fi
if [[ $need_mtx -eq 1 ]]; then
    tmp="$(mktemp -d)"
    url="https://github.com/bluenviron/mediamtx/releases/download/${MTX_VERSION}/mediamtx_${MTX_VERSION}_${MTX_ARCH}.tar.gz"
    log "  downloading ${url}"
    curl -fsSL "$url" -o "${tmp}/mediamtx.tgz"
    tar -xzf "${tmp}/mediamtx.tgz" -C "$tmp" mediamtx
    install -m 0755 -o root -g root "${tmp}/mediamtx" /usr/local/bin/mediamtx
    rm -rf "$tmp"
fi
# Config + unit from the canonical files.
install -d -m 0755 /usr/local/etc
install -m 0644 "${DROPLET_DIR}/mediamtx/mediamtx.yml" /usr/local/etc/mediamtx.yml
install -m 0644 "${DROPLET_DIR}/systemd/mediamtx.service" /etc/systemd/system/mediamtx.service
systemctl daemon-reload
systemctl enable mediamtx
if grep -q 'REPLACE_WITH_' /usr/local/etc/mediamtx.yml; then
    warn "mediamtx.yml still has REPLACE_WITH_* (publish password / reserved IP)."
    warn "Fill them then: systemctl restart mediamtx"
fi
# MediaMTX binds to 10.10.0.1; only (re)start it if WireGuard is actually up.
if ip -brief addr show wg0 2>/dev/null | grep -q '10.10.0.1'; then
    systemctl restart mediamtx || warn "mediamtx failed to start (check mediamtx.yml)."
else
    warn "wg0/10.10.0.1 not up yet; mediamtx enabled but not started (it binds 10.10.0.1)."
fi

# -----------------------------------------------------------------------------
log "4/8 nginx + web root"
# -----------------------------------------------------------------------------
# Unified web document root: viewer + /api status, both under /var/www/badabing.
install -d -m 0755 /var/www/badabing
install -d -m 0755 /var/www/badabing/api
install -d -m 0755 /var/www/html
# Deploy the static viewer if it is present in the tree (Agent A owns these).
if [[ -d "${DROPLET_DIR}/web" ]]; then
    for asset in index.html app.js styles.css; do
        [[ -f "${DROPLET_DIR}/web/${asset}" ]] && \
            install -m 0644 "${DROPLET_DIR}/web/${asset}" "/var/www/badabing/${asset}"
    done
fi
# Placeholder index so nginx always serves something before the viewer is up.
if [[ ! -f /var/www/badabing/index.html ]]; then
    printf '%s\n' '<h1>The Bada Bing</h1><p>Viewer not deployed yet.</p>' \
        > /var/www/badabing/index.html
fi
# Seed a valid status.json so /api/status.json is non-404 before the Pi's first push.
if [[ ! -f /var/www/badabing/api/status.json ]]; then
    printf '%s\n' \
        '{ "schema": 1, "host": null, "ts": null, "stream": { "up": false }, "music": { "playing": false }, "battery": null, "note": "awaiting first push from coop Pi" }' \
        > /var/www/badabing/api/status.json
fi
chown -R www-data:www-data /var/www/badabing

# nginx config: the public-status snippet (coop.conf includes it) + the site.
install -d -m 0755 /etc/nginx/snippets
install -m 0644 "${DROPLET_DIR}/nginx/api-status.conf" /etc/nginx/snippets/api-status.conf
install -m 0644 "${DROPLET_DIR}/nginx/coop.conf" /etc/nginx/sites-available/coop.conf

# HTTP-only ACME bootstrap vhost: lets certbot --webroot answer the challenge
# even before the TLS cert (which coop.conf's 443 block needs) exists. Without an
# enabled :80 vhost, an empty sites-enabled makes nginx 404 the challenge.
cat > /etc/nginx/sites-available/acme-bootstrap.conf <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    root /var/www/html;
    location /.well-known/acme-challenge/ { root /var/www/html; allow all; }
    location / { return 404; }
}
EOF
rm -f /etc/nginx/sites-enabled/default

# Decide which site to enable: coop.conf (443) only once its cert exists; until
# then serve the ACME bootstrap vhost so the cert can be issued.
domain="$(grep -m1 -oE 'server_name[[:space:]]+[^;]+' /etc/nginx/sites-available/coop.conf | awk '{print $2}')"
cert_live="/etc/letsencrypt/live/${domain}/fullchain.pem"
if [[ -n "$domain" && -f "$cert_live" ]]; then
    rm -f /etc/nginx/sites-enabled/acme-bootstrap.conf
    ln -sf ../sites-available/coop.conf /etc/nginx/sites-enabled/coop.conf
    log "  TLS cert present for ${domain}; enabled coop.conf (443)."
else
    rm -f /etc/nginx/sites-enabled/coop.conf
    ln -sf ../sites-available/acme-bootstrap.conf /etc/nginx/sites-enabled/acme-bootstrap.conf
    log "  no cert yet for '${domain:-<unset>}'; enabled HTTP-only ACME bootstrap vhost."
fi
if nginx -t; then
    systemctl enable nginx
    systemctl reload nginx 2>/dev/null || systemctl restart nginx
else
    warn "'nginx -t' failed; not reloading. Fix the config above and re-run."
fi

# -----------------------------------------------------------------------------
log "5/8 certbot (TLS)"
# -----------------------------------------------------------------------------
install -d -m 0755 /var/www/html/.well-known/acme-challenge
if [[ -f "$cert_live" ]]; then
    log "  cert already issued for ${domain}; skipping."
elif [[ -z "$domain" || "$domain" == "cam.example.com" ]]; then
    warn "domain still the placeholder ('${domain:-<unset>}'); skipping certbot."
    warn "Set your domain in coop.conf, point DNS at the reserved IP, then run:"
    warn "  certbot certonly --webroot -w /var/www/html -d <domain> -m <email> --agree-tos -n"
    warn "  then re-run this script (it will enable coop.conf once the cert exists)."
else
    log "  issuing cert for ${domain} (requires DNS A/AAAA -> reserved IP to be live)"
    if certbot certonly --webroot -w /var/www/html --non-interactive --agree-tos \
        --register-unsafely-without-email -d "$domain"; then
        rm -f /etc/nginx/sites-enabled/acme-bootstrap.conf
        ln -sf ../sites-available/coop.conf /etc/nginx/sites-enabled/coop.conf
        nginx -t && { systemctl reload nginx || systemctl restart nginx; }
        log "  cert issued; coop.conf (443) enabled."
    else
        warn "certbot failed (check DNS / port 80). Issue the cert by hand, then re-run."
    fi
    systemctl enable --now certbot.timer 2>/dev/null || true
fi

# -----------------------------------------------------------------------------
log "6/8 ufw firewall"
# -----------------------------------------------------------------------------
# Run the canonical firewall script verbatim (do not duplicate its rules here).
bash "${DROPLET_DIR}/firewall/ufw-setup.sh"

# -----------------------------------------------------------------------------
log "7/8 fail2ban"
# -----------------------------------------------------------------------------
install -m 0644 "${DROPLET_DIR}/fail2ban/jail.local" /etc/fail2ban/jail.local
systemctl enable fail2ban
systemctl restart fail2ban || warn "fail2ban failed to (re)start; check /etc/fail2ban/jail.local."

# -----------------------------------------------------------------------------
log "8/8 SSH hardening"
# -----------------------------------------------------------------------------
install -d -m 0755 /etc/ssh/sshd_config.d
install -m 0644 "${DROPLET_DIR}/ssh/99-hardening.conf" /etc/ssh/sshd_config.d/99-hardening.conf
if sshd -t; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    log "  SSH hardening applied."
else
    warn "'sshd -t' failed; NOT reloading sshd (you'd risk lockout). Fix and reload manually."
fi

# -----------------------------------------------------------------------------
cat <<EOF

=================================  DONE  ====================================
The Bada Bing proxy droplet is provisioned. NEXT STEPS:

  1) Fill any remaining REPLACE_WITH_* placeholders, then re-run this script:
       - /etc/wireguard/wg0.conf        (WireGuard keys)
       - /usr/local/etc/mediamtx.yml    (publish password, reserved IP in
                                         webrtcAdditionalHosts)
       - /etc/nginx/sites-available/coop.conf  (your domain in server_name +
                                                 cert paths)

  2) Point DNS:  <domain> A/AAAA -> the droplet's reserved IP. Then, if the
     cert was skipped above:
       certbot certonly --webroot -w /var/www/html -d <domain> -m <email> \\
           --agree-tos -n
     and re-run this script (it enables coop.conf once the cert exists).

  3) Create the restricted status-push account using the Pi's PUBLIC key:
       sudo PI_PUBKEY="\$(cat coopstatus_ed25519.pub)" \\
            ${DROPLET_DIR}/ssh/setup-coopstatus.sh

  4) On the Pi, fill /etc/badabing/badabing-stream.env (RTSP_PASS) and bring up
     the stream (pi/install.sh). Verify:
       systemctl status mediamtx wg-quick@wg0 nginx
       https://<domain>/            (viewer)
       https://<domain>/api/status.json
=============================================================================
EOF
