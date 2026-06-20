# =============================================================================
# Input variables. Set secrets via TF_VAR_* env vars or a *.auto.tfvars file
# that is gitignored (never commit tokens/keys).
# =============================================================================

variable "do_token" {
  description = "DigitalOcean API token (or set DIGITALOCEAN_TOKEN env var)."
  type        = string
  sensitive   = true
  default     = null
}

variable "region" {
  description = "DO region slug. Pick the one closest to most viewers AND your home (for WireGuard RTT)."
  type        = string
  default     = "nyc3"
}

variable "droplet_size" {
  description = <<-EOT
    Droplet size slug. Smallest sufficient size for a single 720p/1080p
    re-streamed chicken cam: s-1vcpu-1gb (the $6/mo Basic droplet).
    MediaMTX does NOT transcode here (it remuxes the Pi's H.264 into HLS/WebRTC),
    so CPU load is light; 1 vCPU / 1 GB is comfortable for a handful of viewers.
    Bump to s-1vcpu-2gb only if you add many concurrent WebRTC viewers.
  EOT
  type        = string
  default     = "s-1vcpu-1gb"
}

variable "image" {
  description = "Base image. Ubuntu 24.04 LTS x64."
  type        = string
  default     = "ubuntu-24-04-x64"
}

variable "droplet_name" {
  description = "Name/hostname for the droplet."
  type        = string
  default     = "chickencam-proxy"
}

variable "ssh_key_fingerprints" {
  description = <<-EOT
    Fingerprints of SSH keys already uploaded to your DO account (Settings ->
    Security). These are added to the droplet at create time so you can log in.
    Get them with: doctl compute ssh-key list
  EOT
  type        = list(string)
}

variable "ssh_public_key" {
  description = "Your SSH PUBLIC key contents, injected into cloud-init for the admin user."
  type        = string
}

variable "admin_email" {
  description = "Email for Let's Encrypt registration."
  type        = string
}

variable "domain" {
  description = "Fully-qualified domain that will point at the reserved IP, e.g. cam.example.com."
  type        = string
}

# NOTE: there is intentionally NO viewer_password. The viewer is PUBLIC by
# design (no login), so the template installs no auth_basic / htpasswd. See
# user-data.tftpl if you ever want to opt back in to Basic Auth.

variable "wg_server_private_key" {
  description = "WireGuard server private key (wg genkey)."
  type        = string
  sensitive   = true
}

variable "wg_pi_public_key" {
  description = "WireGuard public key of the Raspberry Pi peer (wg pubkey < pi_private.key)."
  type        = string
}

variable "pi_publish_password" {
  description = "Password the Pi uses to PUBLISH RTSP to MediaMTX (over WireGuard)."
  type        = string
  sensitive   = true
}

variable "ssh_admin_source_addresses" {
  description = "CIDRs allowed to reach SSH (22). Lock to your IP. Default is open."
  type        = list(string)
  default     = ["0.0.0.0/0", "::/0"]
}
