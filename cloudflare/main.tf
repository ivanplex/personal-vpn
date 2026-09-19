# cloudflare/main.tf — the public side of the fleet.
#
# The mirror of ../tailscale/: that directory is what the TAILNET allows, this
# one is what the PUBLIC INTERNET can reach. Both are Terraform, both hold
# credentials in a gitignored tfvars, and both are applied by hand rather than
# by comin — a tunnel or an ACL is not something a machine should be able to
# change about itself.
#
# ---------------------------------------------------------------------------
# THE ONE THING TO UNDERSTAND
#
# The hostnames are NOT declared here. They are read out of the compose files
# in ../hosts/hong-kong/apps/, which is the same source hosts/hong-kong/apps.nix
# reads to build cloudflared's ingress rules. One declaration, two consumers:
#
#     apps/rallly.yaml          x-fleet: {public: polls.example.com}
#            │
#            ├─→ apps.nix     → cloudflared ingress rule   (the routing)
#            └─→ main.tf      → CNAME → <uuid>.cfargotunnel.com  (the name)
#
# If this file listed hostnames of its own, the two would drift, and the
# symptom of that drift is a name that resolves to a tunnel with no rule
# behind it — a 404 that looks like an app bug and is not.
#
# So: to publish an app, edit its compose file and run `terraform apply` here.
# Never add a record by hand, in this file or in the dashboard.
#
# ---------------------------------------------------------------------------
# WHAT IS DELIBERATELY NOT HERE
#
#   * The tunnel SECRET. Terraform generates it; you copy it into sops once.
#     See ./README.md. It is in the state file, which is why the state file is
#     gitignored and why ../.sops.yaml does not cover this directory.
#
#   * Cloudflare Access policies. Worth knowing they exist — Access can put
#     Google/GitHub/email-OTP auth in front of a hostname without the app
#     supporting it at all, which is a better answer than trusting a
#     self-hosted login page for anything half-public. Not configured here
#     because the apps published so far are meant to be open.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5"
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.40"
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# ---------------------------------------------------------------- the apps --
locals {
  apps_dir = "${path.module}/../hosts/hong-kong/apps"

  # The tunnel name as hosts/hong-kong/public.nix declares it. Read out of the
  # Nix source rather than duplicated, so the precondition below compares
  # against the real thing instead of a second copy that could also be wrong.
  #
  # THIS COUPLES TERRAFORM TO THAT FILE'S FORMATTING. Reformat the
  # `tunnelName = "..."` line and regex() finds nothing and throws. That is
  # deliberate: it fails loudly at plan time, naming this file, which is
  # enormously better than the alternative it replaced — a silent rename that
  # destroys the tunnel and staleness the sops credential. If you hit it, fix
  # the pattern; do not wrap it in try() and hand back the silence.
  nix_tunnel_name = regex(
    "tunnelName = \"([a-z0-9-]+)\"",
    file("${path.module}/../hosts/hong-kong/public.nix")
  )[0]

  # Every compose file, parsed. yamldecode is Terraform's own — no external
  # tooling, and it fails loudly on a malformed file rather than skipping it.
  composed = {
    for f in fileset(local.apps_dir, "*.yaml") :
    f => yamldecode(file("${local.apps_dir}/${f}"))
  }

  # Only the ones asking to be public, and only while enabled. `enable: false`
  # must take the DNS record away too — otherwise a disabled app keeps a name
  # pointing at a tunnel that no longer routes it.
  public_hosts = {
    for f, doc in local.composed :
    doc["x-fleet"].public => f
    if try(doc["x-fleet"].public, null) != null
    && try(doc["x-fleet"].enable, true) == true
  }
}

# ------------------------------------------------------------- the tunnel --
# NOT `cloudflare_tunnel`: that spelling is deprecated and goes away in the
# provider's next major version.
resource "cloudflare_zero_trust_tunnel_cloudflared" "main" {
  account_id = var.cloudflare_account_id
  name       = var.tunnel_name
  secret     = var.tunnel_secret
  config_src = "local" # the config lives in hosts/hong-kong/public.nix, not here

  lifecycle {
    # THE NAME IS DECLARED IN TWO PLACES AND THEY MUST AGREE. Renaming a tunnel
    # forces REPLACEMENT — a new tunnel ID — which silently invalidates the
    # TunnelID inside the sops credentials on hong-kong. cloudflared then
    # starts cleanly, connects to nothing, and no error says why.
    #
    # This happened on 2026-09-19: terraform.tfvars still carried the old
    # `tunnel_name = "hong-kong"` from an earlier copy of the example, a tfvars
    # value beats a variable default, and `terraform plan` proposed destroying
    # a working tunnel. Hence both this check and the example no longer
    # offering the variable at all.
    precondition {
      condition     = var.tunnel_name == local.nix_tunnel_name
      error_message = "tunnel_name is '${var.tunnel_name}' but hosts/hong-kong/public.nix says tunnelName = '${local.nix_tunnel_name}'. They must match. Fix one — and note that CHANGING THE NAME DESTROYS AND RECREATES THE TUNNEL, which invalidates the TunnelID in secrets/hong-kong.yaml."
    }

    # Backstop. Destroying this tunnel is always an incident: public apps drop
    # AND the sops credential goes stale. To do it deliberately, delete this
    # line in the same commit, so the intent is visible in the diff.
    prevent_destroy = true
  }
}

# --------------------------------------------------------------- the names --
# One CNAME per public app, pointed at the tunnel. Proxied, so Cloudflare's
# WAF, rate limiting and DDoS absorption are actually in the path — that is
# most of the reason this design was chosen over Tailscale Funnel.
resource "cloudflare_record" "app" {
  for_each = local.public_hosts

  zone_id = var.cloudflare_zone_id
  name    = each.key
  content = "${cloudflare_zero_trust_tunnel_cloudflared.main.id}.cfargotunnel.com"
  type    = "CNAME"
  proxied = true

  comment = "Managed by terraform from hosts/hong-kong/apps/${each.value}"
}

output "tunnel_id" {
  value       = cloudflare_zero_trust_tunnel_cloudflared.main.id
  description = "Set as TunnelID in the sops credentials JSON."
}

output "published_hostnames" {
  value       = keys(local.public_hosts)
  description = "Everything a stranger can reach. If this list surprises you, stop."
}
