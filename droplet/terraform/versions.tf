# =============================================================================
# Provider + version pinning.
# DigitalOcean provider latest: v2.91.0 (June 2026). Pin to the 2.x line.
# =============================================================================
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.91"
    }
  }
}

# Token via env var DIGITALOCEAN_TOKEN, or pass var.do_token.
provider "digitalocean" {
  token = var.do_token
}
