# cloudflare — the public door

The mirror of [`../tailscale/`](../tailscale): that directory is what the
**tailnet** allows, this one is what the **public internet** can reach.

Everything published to strangers is visible in one command:

```sh
grep -rn 'public:' ../hosts/hong-kong/apps/
```

## Hostnames are not declared here

They live in the compose files, and both consumers read the same source:

```
apps/whoami.yaml      x-fleet: {public: test.ivanchan.me}
       │
       ├─→ hosts/hong-kong/apps.nix  → cloudflared ingress rule   (routing)
       └─→ cloudflare/main.tf        → CNAME → <uuid>.cfargotunnel.com  (name)
```

If this directory kept its own list the two would drift, and drift here looks
like a hostname that resolves to a tunnel with no rule behind it — a 404 that
reads like an app bug and isn't one.

**To publish an app: edit its compose file, push, then `terraform apply` here.**
Never add a record by hand, in Terraform or in the dashboard.

## First-time setup

The ordering matters and is the same shape as the tsidp clients in
`../hosts/hong-kong/services.nix`. It is not circular — Cloudflare needs
nothing from the box.

**1. Credentials.**

```sh
cp terraform.tfvars.example terraform.tfvars
openssl rand -base64 32          # this is tunnel_secret
```

Fill in the token, account ID and zone ID. Scope the token to
`Account:Cloudflare Tunnel:Edit` + `Zone:DNS:Edit` and nothing else — never a
Global API Key.

**2. Create the tunnel**, with no app publishing anything yet:

```sh
terraform init
terraform plan
terraform apply
terraform output tunnel_id
```

**3. Put the credentials into sops — BEFORE `public.nix` reaches `main`.**

```sh
sops ../secrets/hong-kong.yaml
```

```yaml
cloudflared-credentials: |
  {"AccountTag":"<account id>","TunnelID":"<tunnel_id from step 2>","TunnelSecret":"<tunnel_secret>"}
```

> **That order is the rule, not a suggestion.** A secret that is declared but
> missing from the file fails `sops-install-secrets` during **activation**, and
> comin neither rolls back nor retries that generation. The Grafana keys carry
> the same warning for the same reason.

**4. Set `zone` and `tunnelName`** at the top of
`../hosts/hong-kong/public.nix`, import it, and deploy. With no app publishing
anything, the tunnel comes up and answers 404 to everything. That is the
correct stage-1 result — confirm it before going further.

## Applying

```sh
terraform plan      # diff against live DNS
terraform apply
terraform output published_hostnames
```

`published_hostnames` is the list of things a stranger can reach. **If it ever
surprises you, stop and find out why before applying.**

State is local and gitignored, like the tailnet's. It contains
`tunnel_secret`, which is the main reason. If it is lost, re-import with
`terraform import cloudflare_zero_trust_tunnel_cloudflared.main <account_id>/<tunnel_id>`.

## Removing an app from the internet

Delete or blank `x-fleet.public` in the compose file — or set
`x-fleet.enable: false`, which takes the DNS record away too — then push and
`terraform apply`. Both halves are needed: the push stops the tunnel routing
it, the apply stops the name resolving.

## Worth knowing: Cloudflare Access

Access puts authentication (Google, GitHub, email OTP) in front of a hostname
**without the app supporting it at all**. It is not configured here because
the apps published so far are meant to be open — but for anything half-public
it is a better answer than trusting a self-hosted login page, and it is on the
free tier.
