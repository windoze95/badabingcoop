# =============================================================================
# The Bada Bing — deployment interface.
#
#   make help            list targets (default)
#   make gen-keys        generate WireGuard keypairs (+ PSK); prints where each goes
#   make tf-init         terraform init        (in droplet/terraform)
#   make tf-plan         terraform plan        (in droplet/terraform)
#   make tf-apply        terraform apply       (in droplet/terraform)
#   make deploy-droplet HOST=user@ip   rsync droplet/ to a bare Ubuntu 24.04 box
#                                       and run droplet/setup/install.sh there
#   make install-pi      run pi/install.sh ON the Pi
#                        (JUKEBOX=1 -> --jukebox, BATTERY=1 -> --battery)
#   make lint            bash -n + shellcheck + terraform fmt + json/yaml checks
#   make verify-sri      verify the pinned hls.js SRI hash in index.html
#
# Every target degrades gracefully if an optional tool is missing.
# =============================================================================

# Repo root (directory of this Makefile), no trailing slash.
ROOT := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
TF_DIR := $(ROOT)/droplet/terraform

# Pinned hls.js (MUST match index.html; do NOT change without re-verifying SRI).
HLS_VERSION := 1.6.16
HLS_URL := https://cdn.jsdelivr.net/npm/hls.js@$(HLS_VERSION)/dist/hls.min.js
INDEX_HTML := $(ROOT)/droplet/web/index.html

SHELL := /bin/bash

.PHONY: help gen-keys tf-init tf-plan tf-apply deploy-droplet install-pi lint verify-sri

# --- help (default): self-documenting from the '## ' comments below -----------
help: ## Show this help.
	@echo "The Bada Bing — make targets:"
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Vars:  HOST=user@ip (deploy-droplet)   JUKEBOX=1 BATTERY=1 (install-pi)"

# --- WireGuard key generation ------------------------------------------------
# Writes NOTHING into the repo — prints the keys and exactly where each goes so
# the operator can paste them into the (gitignored) real configs / tfvars.
gen-keys: ## Generate WireGuard keypairs + PSK and print where each goes.
	@command -v wg >/dev/null 2>&1 || { \
		echo "ERROR: 'wg' (wireguard-tools) not found. Install it:"; \
		echo "  macOS:  brew install wireguard-tools"; \
		echo "  Debian: sudo apt-get install -y wireguard-tools"; \
		exit 1; }
	@set -euo pipefail; \
	srv_priv=$$(wg genkey); \
	srv_pub=$$(printf '%s' "$$srv_priv" | wg pubkey); \
	pi_priv=$$(wg genkey); \
	pi_pub=$$(printf '%s' "$$pi_priv" | wg pubkey); \
	psk=$$(wg genpsk); \
	echo "==============================================================="; \
	echo " WireGuard keys — generated in memory, NOTHING written to repo."; \
	echo " Topology: droplet 10.10.0.1/24  <->  Pi 10.10.0.2/32"; \
	echo "==============================================================="; \
	echo; \
	echo "SERVER (droplet) PRIVATE key  -> droplet/wireguard/wg0.conf [Interface] PrivateKey"; \
	echo "                              -> terraform var wg_server_private_key"; \
	echo "  $$srv_priv"; \
	echo; \
	echo "SERVER (droplet) PUBLIC key   -> the Pi's /etc/wireguard/wg0.conf [Peer] PublicKey"; \
	echo "  $$srv_pub"; \
	echo; \
	echo "PI PRIVATE key                -> the Pi's /etc/wireguard/wg0.conf [Interface] PrivateKey"; \
	echo "  $$pi_priv"; \
	echo; \
	echo "PI PUBLIC key                 -> droplet/wireguard/wg0.conf [Peer] PublicKey"; \
	echo "                              -> terraform var wg_pi_public_key"; \
	echo "  $$pi_pub"; \
	echo; \
	echo "PRESHARED key (optional)      -> [Peer] PresharedKey on BOTH ends"; \
	echo "  $$psk"; \
	echo; \
	echo "Store these in a password manager; do NOT commit them."

# --- Terraform ---------------------------------------------------------------
tf-init: ## terraform init (droplet/terraform).
	terraform -chdir=$(TF_DIR) init

tf-plan: ## terraform plan (droplet/terraform).
	terraform -chdir=$(TF_DIR) plan

tf-apply: ## terraform apply (droplet/terraform).
	terraform -chdir=$(TF_DIR) apply

# --- Manual droplet deploy ---------------------------------------------------
# rsync the canonical droplet/ tree to a bare Ubuntu 24.04 droplet, then run the
# installer there as root. Requires HOST=user@ip.
deploy-droplet: ## rsync droplet/ to HOST and run setup/install.sh (needs HOST=user@ip).
	@test -n "$(HOST)" || { echo "ERROR: set HOST=user@ip  (e.g. make deploy-droplet HOST=chickenadmin@1.2.3.4)"; exit 1; }
	@command -v rsync >/dev/null 2>&1 || { echo "ERROR: rsync not found."; exit 1; }
	@command -v ssh   >/dev/null 2>&1 || { echo "ERROR: ssh not found."; exit 1; }
	@echo "[deploy-droplet] syncing droplet/ -> $(HOST):/opt/badabing/droplet/"
	ssh "$(HOST)" 'sudo mkdir -p /opt/badabing/droplet && sudo chown -R "$$(id -un):$$(id -gn)" /opt/badabing'
	rsync -az --delete \
		--exclude '.terraform/' --exclude '*.tfstate*' --exclude '*.tfvars' \
		"$(ROOT)/droplet/" "$(HOST):/opt/badabing/droplet/"
	@echo "[deploy-droplet] running setup/install.sh as root on $(HOST)"
	ssh -t "$(HOST)" 'sudo bash /opt/badabing/droplet/setup/install.sh'

# --- Pi install (run ON the Pi) ----------------------------------------------
install-pi: ## Run pi/install.sh on the Pi (JUKEBOX=1, BATTERY=1 enable extras).
	@flags=""; \
	[ "$(JUKEBOX)" = "1" ] && flags="$$flags --jukebox"; \
	[ "$(BATTERY)" = "1" ] && flags="$$flags --battery"; \
	echo "[install-pi] sudo bash pi/install.sh$$flags"; \
	sudo bash "$(ROOT)/pi/install.sh" $$flags

# --- Lint --------------------------------------------------------------------
# bash -n every shell script; shellcheck if present; terraform fmt -check if
# present; python json.tool on every .json; a yaml load if PyYAML/yq present.
# Each tool is optional and skipped (with a note) when missing.
lint: ## Lint shell, terraform, json, yaml (skips any missing tool).
	@set -euo pipefail; \
	echo "== bash -n =="; \
	found=0; \
	while IFS= read -r f; do \
		found=1; bash -n "$$f" && echo "  ok   $$f" || { echo "  FAIL $$f"; exit 1; }; \
	done < <(find "$(ROOT)" -name '*.sh' -not -path '*/.git/*' | sort); \
	[ "$$found" = 1 ] || echo "  (no .sh files found)"; \
	echo "== shellcheck =="; \
	if command -v shellcheck >/dev/null 2>&1; then \
		find "$(ROOT)" -name '*.sh' -not -path '*/.git/*' -print0 \
			| xargs -0 shellcheck -S warning || { echo "  shellcheck reported issues"; exit 1; }; \
		echo "  ok"; \
	else echo "  SKIP (shellcheck not installed)"; fi; \
	echo "== terraform fmt =="; \
	if command -v terraform >/dev/null 2>&1; then \
		terraform fmt -check -recursive "$(TF_DIR)" || { echo "  run: terraform fmt -recursive $(TF_DIR)"; exit 1; }; \
		echo "  ok"; \
	else echo "  SKIP (terraform not installed)"; fi; \
	echo "== json =="; \
	if command -v python3 >/dev/null 2>&1; then \
		jcount=0; \
		while IFS= read -r j; do \
			jcount=1; python3 -m json.tool "$$j" >/dev/null && echo "  ok   $$j" || { echo "  FAIL $$j"; exit 1; }; \
		done < <(find "$(ROOT)" -name '*.json' -not -path '*/.git/*' -not -path '*/.terraform/*' | sort); \
		[ "$$jcount" = 1 ] || echo "  (no .json files found)"; \
	else echo "  SKIP (python3 not installed)"; fi; \
	echo "== yaml =="; \
	if python3 -c 'import yaml' >/dev/null 2>&1; then \
		while IFS= read -r y; do \
			python3 -c 'import sys,yaml; list(yaml.safe_load_all(open(sys.argv[1])))' "$$y" \
				&& echo "  ok   $$y" || { echo "  FAIL $$y"; exit 1; }; \
		done < <(find "$(ROOT)" \( -name '*.yml' -o -name '*.yaml' \) -not -path '*/.git/*' | sort); \
	elif command -v yq >/dev/null 2>&1; then \
		while IFS= read -r y; do \
			yq -e '.' "$$y" >/dev/null && echo "  ok   $$y" || { echo "  FAIL $$y"; exit 1; }; \
		done < <(find "$(ROOT)" \( -name '*.yml' -o -name '*.yaml' \) -not -path '*/.git/*' | sort); \
	else echo "  SKIP (no PyYAML / yq)"; fi; \
	echo "lint: done."

# --- Verify the pinned hls.js SRI hash --------------------------------------
# Download the exact pinned hls.js, compute its sha384, and compare to the
# integrity="sha384-..." attribute baked into index.html.
verify-sri: ## Verify index.html's hls.js SRI hash against the real CDN bytes.
	@command -v curl >/dev/null 2>&1 || { echo "ERROR: curl not found."; exit 1; }
	@if command -v openssl >/dev/null 2>&1; then :; \
	elif command -v shasum >/dev/null 2>&1; then :; \
	elif command -v sha384sum >/dev/null 2>&1; then :; \
	else echo "ERROR: need one of openssl / shasum / sha384sum."; exit 1; fi
	@set -euo pipefail; \
	echo "[verify-sri] downloading $(HLS_URL)"; \
	tmp=$$(mktemp); trap 'rm -f "$$tmp"' EXIT; \
	curl -fsSL "$(HLS_URL)" -o "$$tmp"; \
	if command -v openssl >/dev/null 2>&1; then \
		got="sha384-$$(openssl dgst -sha384 -binary "$$tmp" | openssl base64 -A)"; \
	elif command -v shasum >/dev/null 2>&1; then \
		got="sha384-$$(shasum -a 384 "$$tmp" | cut -d' ' -f1 | xxd -r -p | base64)"; \
	else \
		got="sha384-$$(sha384sum "$$tmp" | cut -d' ' -f1 | xxd -r -p | base64)"; \
	fi; \
	want=$$(grep -oE 'integrity="sha384-[A-Za-z0-9+/=]+"' "$(INDEX_HTML)" | head -1 | sed -E 's/integrity="([^"]+)"/\1/'); \
	echo "  computed: $$got"; \
	echo "  in HTML:  $$want"; \
	if [ "$$got" = "$$want" ]; then \
		echo "[verify-sri] OK — hls.js@$(HLS_VERSION) SRI matches index.html."; \
	else \
		echo "[verify-sri] MISMATCH — do NOT ship; the pinned hash and CDN bytes disagree."; \
		exit 1; \
	fi
