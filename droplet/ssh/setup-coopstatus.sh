#!/usr/bin/env bash
#
# droplet/ssh/setup-coopstatus.sh
# Run ONCE on the droplet (as root / sudo) to create the restricted `coopstatus`
# deploy account that the coop Pi pushes status.json through.
#
# Idempotent: safe to re-run. It will create-or-update the user, the locked-down
# ~/.ssh/authorized_keys (rrsync forced-command), the target web directory, and
# ensure rrsync exists at /usr/bin/rrsync.
#
# Usage:
#   sudo PI_PUBKEY="$(cat coopstatus_ed25519.pub)" \
#        droplet/ssh/setup-coopstatus.sh
# or:
#   sudo droplet/ssh/setup-coopstatus.sh /path/to/coopstatus_ed25519.pub
#
set -euo pipefail

DEPLOY_USER="${DEPLOY_USER:-coopstatus}"
WEB_DIR="${WEB_DIR:-/var/www/badabing/api}"
# nginx worker user — the dir must be readable by nginx. Debian/Ubuntu: www-data.
WEB_GROUP="${WEB_GROUP:-www-data}"
RRSYNC_DIR="${RRSYNC_DIR:-/var/www/badabing/api}"   # the ONE dir the key can touch

if [[ $EUID -ne 0 ]]; then
    echo "Must run as root (sudo)." >&2
    exit 1
fi

# --- Resolve the Pi public key ----------------------------------------------
PI_PUBKEY="${PI_PUBKEY:-}"
if [[ -z "$PI_PUBKEY" && -n "${1:-}" && -f "${1:-}" ]]; then
    PI_PUBKEY="$(cat "$1")"
fi
if [[ -z "$PI_PUBKEY" ]]; then
    echo "Provide the Pi's public key via PI_PUBKEY env or a file arg." >&2
    echo "  sudo PI_PUBKEY=\"\$(cat coopstatus_ed25519.pub)\" $0" >&2
    exit 1
fi
# Sanity: must look like an OpenSSH public key line.
if [[ "$PI_PUBKEY" != ssh-* && "$PI_PUBKEY" != ecdsa-* && "$PI_PUBKEY" != sk-* ]]; then
    echo "PI_PUBKEY does not look like an OpenSSH public key." >&2
    exit 1
fi

# --- Ensure rrsync is available at /usr/bin/rrsync --------------------------
if ! command -v rrsync >/dev/null 2>&1 && [[ ! -x /usr/bin/rrsync ]]; then
    echo "[setup] rrsync not found; locating/installing from the rsync package..."
    apt-get install -y rsync >/dev/null 2>&1 || true
    if [[ ! -x /usr/bin/rrsync ]]; then
        # Older packaging stashes it under /usr/share/doc/rsync/scripts/
        for cand in \
            /usr/share/doc/rsync/scripts/rrsync \
            /usr/share/doc/rsync/scripts/rrsync.gz ; do
            if [[ -e "$cand" ]]; then
                if [[ "$cand" == *.gz ]]; then
                    gunzip -k "$cand"
                    cand="${cand%.gz}"
                fi
                install -m 0755 "$cand" /usr/bin/rrsync
                break
            fi
        done
    fi
fi
if [[ ! -x /usr/bin/rrsync ]] && ! command -v rrsync >/dev/null 2>&1; then
    echo "[setup] WARNING: could not find rrsync. Install it before the key will work." >&2
fi

# --- Create the restricted account (no shell login, no password) ------------
if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
    echo "[setup] creating user $DEPLOY_USER"
    # A real home (for ~/.ssh) but a no-login shell is fine because the SSH key
    # is forced to rrsync via command=, so the shell is never reached anyway.
    useradd --create-home --shell /usr/sbin/nologin "$DEPLOY_USER"
    passwd -l "$DEPLOY_USER" >/dev/null 2>&1 || true
else
    echo "[setup] user $DEPLOY_USER already exists"
fi

HOME_DIR="$(getent passwd "$DEPLOY_USER" | cut -d: -f6)"
SSH_DIR="${HOME_DIR}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"

install -d -m 0700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$SSH_DIR"

# --- Write the forced-command authorized_keys (idempotent) ------------------
# -wo  = write only into the dir; -no-del also forbids any --delete*/--remove*.
OPTS='no-pty,no-agent-forwarding,no-port-forwarding,no-X11-forwarding'
FORCED="command=\"/usr/bin/rrsync -wo -no-del ${RRSYNC_DIR}\",${OPTS}"
LINE="${FORCED} ${PI_PUBKEY}"

umask 077
printf '%s\n' \
    "# Managed by setup-coopstatus.sh — restricted rrsync push for the coop Pi." \
    "$LINE" > "$AUTH_KEYS"
chown "$DEPLOY_USER:$DEPLOY_USER" "$AUTH_KEYS"
chmod 0600 "$AUTH_KEYS"
echo "[setup] wrote $AUTH_KEYS"

# --- Ensure the target web directory exists & is writable by the deploy user -
# The Pi WRITES here (owned by coopstatus); nginx READS here (group www-data).
install -d -m 0755 /var/www/badabing
install -d -m 2750 -o "$DEPLOY_USER" -g "$WEB_GROUP" "$WEB_DIR"
# 2750: setgid so files keep group www-data; group can read, others cannot list.
# Make sure nginx can actually traverse into it (o+x on parents handled by 0755).
chmod 0755 /var/www/badabing

# Seed a placeholder so the endpoint is valid before the Pi's first push.
if [[ ! -f "${WEB_DIR}/status.json" ]]; then
    cat > "${WEB_DIR}/status.json" <<'JSON'
{ "schema": 1, "host": null, "ts": null, "stream": { "up": false }, "music": { "playing": false }, "battery": null, "note": "awaiting first push from coop Pi" }
JSON
    chown "$DEPLOY_USER:$WEB_GROUP" "${WEB_DIR}/status.json"
    chmod 0644 "${WEB_DIR}/status.json"
fi

# --- Install the nginx /api/ snippet that coop.conf includes ------------------
# coop.conf has `include snippets/api-status.conf;`. nginx ERRORS (and `nginx -t`
# fails -> nginx won't reload) if that file is missing. Install it from the repo
# copy that sits next to this script, so enabling the status feature can't leave
# nginx in a broken state.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SNIPPET_SRC="${SCRIPT_DIR}/../nginx/api-status.conf"
SNIPPET_DST="/etc/nginx/snippets/api-status.conf"
if [[ -f "$SNIPPET_SRC" ]]; then
    install -d -m 0755 /etc/nginx/snippets
    install -m 0644 "$SNIPPET_SRC" "$SNIPPET_DST"
    echo "[setup] installed nginx snippet -> $SNIPPET_DST"
    if command -v nginx >/dev/null 2>&1; then
        if nginx -t >/dev/null 2>&1; then
            systemctl reload nginx || true
            echo "[setup] reloaded nginx"
        else
            echo "[setup] WARNING: 'nginx -t' failed; not reloading. Fix coop.conf then reload." >&2
        fi
    fi
else
    echo "[setup] NOTE: ${SNIPPET_SRC} not found; if coop.conf includes" >&2
    echo "        snippets/api-status.conf, install it manually before reloading nginx." >&2
fi

echo "[setup] done."
echo "  - account:        $DEPLOY_USER (nologin, password-locked)"
echo "  - locked to dir:  $RRSYNC_DIR (rrsync -wo -no-del)"
echo "  - web dir:        $WEB_DIR (coopstatus:$WEB_GROUP)"
echo
echo "Test from the Pi (over WireGuard):"
echo "  rsync -e 'ssh -i /etc/badabing/keys/coopstatus_ed25519' \\"
echo "        /run/badabing/status.json ${DEPLOY_USER}@10.10.0.1:./status.json"
echo
echo "Verify the lock holds (these MUST fail):"
echo "  ssh -i KEY ${DEPLOY_USER}@10.10.0.1                 # -> no shell"
echo "  rsync -e 'ssh -i KEY' /etc/passwd ${DEPLOY_USER}@10.10.0.1:../../etc/  # -> rejected"
