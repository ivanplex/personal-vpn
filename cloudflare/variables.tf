variable "cloudflare_api_token" {
  type        = string
  sensitive   = true
  description = <<-EOT
    Cloudflare API token. Scope it down — this token only needs:
      Account : Cloudflare Tunnel : Edit
      Zone    : DNS               : Edit   (on the one zone)
    Do not use a Global API Key. It is account-wide and cannot be revoked
    without breaking everything else that uses it.
  EOT
}

variable "cloudflare_account_id" {
  type        = string
  description = "Cloudflare account ID — dashboard sidebar, or `Account Home`."
}

variable "cloudflare_zone_id" {
  type        = string
  description = <<-EOT
    Zone ID for the domain being published under. Must be the same zone as
    `zone` in hosts/hong-kong/public.nix, which asserts every hostname is
    under it at build time.
  EOT
}

variable "tunnel_name" {
  type        = string
  default     = "test-tunnel"
  description = <<-EOT
    Must match `tunnelName` in hosts/hong-kong/public.nix. If they disagree,
    cloudflared starts cleanly and serves nothing, which is a miserable thing
    to debug.
  EOT
}

variable "tunnel_secret" {
  type        = string
  sensitive   = true
  description = <<-EOT
    Base64, 32+ bytes:  openssl rand -base64 32

    Generate it ONCE. It goes in three places and they must agree:
      1. here, via terraform.tfvars
      2. the TunnelSecret field of the credentials JSON in sops
      3. nowhere else

    Rotating it means regenerating the sops entry and redeploying, in that
    order — the secret must reach the box before the config that needs it.
  EOT
}
