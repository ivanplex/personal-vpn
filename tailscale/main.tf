terraform {
  required_providers {
    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.29.0"
    }
  }
}

provider "tailscale" {
  oauth_client_id     = var.TAILSCALE_OAUTH_CLIENT_ID
  oauth_client_secret = var.TAILSCALE_OAUTH_CLIENT_SECRET
  tailnet             = var.TAILSCALE_TAILNET
}

resource "tailscale_acl" "main_policy" {
  acl = file("${path.module}/acl.hujson")
}