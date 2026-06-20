# =============================================================================
# Outputs.
# =============================================================================

output "reserved_ip" {
  description = "Stable public IP. Point your DNS A record (cam.example.com) here, and use it as the Pi's WireGuard Endpoint."
  value       = digitalocean_reserved_ip.cam.ip_address
}

output "droplet_public_ip" {
  description = "The droplet's own (ephemeral) public IPv4. Prefer reserved_ip for everything."
  value       = digitalocean_droplet.cam.ipv4_address
}

output "droplet_ipv6" {
  description = "The droplet's public IPv6."
  value       = digitalocean_droplet.cam.ipv6_address
}

output "next_steps" {
  description = "What to do after apply."
  value       = <<-EOT
    1. Create DNS A record: ${var.domain} -> ${digitalocean_reserved_ip.cam.ip_address}
       (the cert + first boot need this live; certbot retries via certbot.timer.)
    2. The reserved IP ${digitalocean_reserved_ip.cam.ip_address} is already baked into the droplet's
       cloud-init (mediamtx.yml webrtcAdditionalHosts). Put the SAME IP in the
       Pi's wg0.conf Endpoint = ${digitalocean_reserved_ip.cam.ip_address}:51820.
    3. SSH in (chickenadmin@${digitalocean_reserved_ip.cam.ip_address}) and confirm:
         wg show ; systemctl status mediamtx nginx fail2ban ; ufw status
    4. Start the Pi pushing RTSP over WireGuard to:
         rtsp://chickenpi:<pi_publish_password>@10.10.0.1:8554/coop
    5. Browse the PUBLIC viewer (no login): https://${var.domain}/
         WHEP:   https://${var.domain}/coop/whep
         LL-HLS: https://${var.domain}/coop/index.m3u8
         status: https://${var.domain}/api/status.json
  EOT
}
