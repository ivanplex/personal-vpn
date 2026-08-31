variable "TAILSCALE_OAUTH_CLIENT_ID" {
  type      = string
  sensitive = true
}

variable "TAILSCALE_OAUTH_CLIENT_SECRET" {
  type      = string
  sensitive = true
}

variable "TAILSCALE_TAILNET" {
  type = string
}
