# =============================================================================
# Provisions the chicken-cam public proxy: a reserved (floating) IP + a droplet
# (with templated cloud-init user-data that bakes in that IP and all secrets)
# + a cloud firewall.
#
# Defense in depth: BOTH a DigitalOcean cloud firewall (this file) AND ufw
# (on the droplet) restrict the surface to 22, 443, 51820/udp, 8189/udp, 80.
# The cloud firewall blocks traffic before it ever reaches the droplet NIC.
# =============================================================================

# --- Reserved (floating) IP: a stable public IP that survives droplet rebuilds.
#     It is created FIRST, with no droplet attached (region only), so its
#     .ip_address is known at plan/apply time and can be templated into the
#     droplet's cloud-init (webrtcAdditionalHosts + WireGuard endpoint docs).
#     The droplet is then created with that user-data and finally attached via
#     digitalocean_reserved_ip_assignment below. This ordering is what gives the
#     box the correct public IP on its very FIRST boot.
resource "digitalocean_reserved_ip" "cam" {
  region = var.region
}

# Cloud-init user-data, rendered from ./user-data.tftpl.
#
# We use templatefile() (NOT file()) so Terraform injects every secret and the
# reserved IP at apply time. The template writes shell/nginx literal $ tokens as
# $${...} so they survive templating; only the ${var}-style tokens listed in the
# map below are interpolated. The viewer is PUBLIC (no auth_basic / htpasswd), so
# no viewer_password is passed.
locals {
  user_data = templatefile("${path.module}/user-data.tftpl", {
    ssh_public_key        = var.ssh_public_key
    domain                = var.domain
    admin_email           = var.admin_email
    reserved_ip           = digitalocean_reserved_ip.cam.ip_address
    wg_server_private_key = var.wg_server_private_key
    wg_pi_public_key      = var.wg_pi_public_key
    pi_publish_password   = var.pi_publish_password
  })
}

resource "digitalocean_droplet" "cam" {
  name     = var.droplet_name
  image    = var.image
  region   = var.region
  size     = var.droplet_size
  ssh_keys = var.ssh_key_fingerprints

  # cloud-init user-data does all the in-guest provisioning. It already contains
  # the reserved IP, so the droplet must be created AFTER the reserved IP exists.
  user_data = local.user_data

  # Use private networking off (single host) + IPv6 on for future-proofing.
  ipv6              = true
  monitoring        = true
  graceful_shutdown = true

  tags = ["chickencam", "proxy"]

  # Make the dependency explicit (the user_data already references the reserved
  # IP, but spell it out so the create order is unambiguous).
  depends_on = [digitalocean_reserved_ip.cam]
}

# --- Attach the reserved IP to the droplet AFTER both exist.
resource "digitalocean_reserved_ip_assignment" "cam" {
  ip_address = digitalocean_reserved_ip.cam.ip_address
  droplet_id = digitalocean_droplet.cam.id
}

# --- Cloud firewall (the first line of defense, before ufw) ------------------
resource "digitalocean_firewall" "cam" {
  name        = "chickencam-proxy-fw"
  droplet_ids = [digitalocean_droplet.cam.id]

  # SSH (lock source down via var.ssh_admin_source_addresses).
  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = var.ssh_admin_source_addresses
  }

  # HTTP: ACME challenges + redirect to HTTPS.
  inbound_rule {
    protocol         = "tcp"
    port_range       = "80"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # HTTPS: viewer + HLS + WHEP signaling.
  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # WireGuard: the Pi dials in here.
  inbound_rule {
    protocol         = "udp"
    port_range       = "51820"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # WebRTC media (SRTP) -- required for WHEP video to flow.
  inbound_rule {
    protocol         = "udp"
    port_range       = "8189"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # NOTE: RTSP (8554), HLS (8888), WebRTC signaling (8889), API (9997) are
  # intentionally absent -> blocked. They are reachable only via WireGuard or
  # loopback inside the box.

  # --- Outbound: allow all (needed for apt, GitHub release download, certbot,
  #     STUN, and serving streams). ---
  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}
