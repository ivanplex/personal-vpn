# hosts/hong-kong/apps

Every `*.yaml` here is a real Docker Compose file, and **committing one is the
deploy**. `../apps.nix` reads this directory at evaluation time, so the
containers are part of the NixOS generation and every one of the four gates
applies to them.

This file also exists so that git tracks the directory when it is otherwise
empty. Do not delete it.

## The one rule

**What the file says is what the box runs.** `../apps.nix` refuses to build on
any key it does not implement rather than ignoring it, because a translator
that quietly drops `healthcheck:` would make this repository *look* like the
source of truth while the machine ran something else.

So expect the build to fail the first time you paste an upstream compose file
in. The error names the file, the service and the key.

## Adding an app

1. **Resolve the digest.** Floating tags are refused.

   ```sh
   skopeo inspect docker://docker.io/traefik/whoami:v1.10.2 | jq -r '.Digest'
   ```

2. **Write `<name>.yaml`.** The *service name* inside becomes the podman
   container and the systemd unit (`podman-<service>`), and must be unique
   across every file in here. The filename stem is only a label.

3. **`git add` it.** Nix reads the git index, not the working tree. An
   untracked file is invisible and will not deploy, silently. This is
   operating rule 6 and it will catch you once.

4. **Push to `testing-hong-kong` first.** comin applies that branch with
   `test`, which never touches the bootloader, so a reboot undoes it. Rebase
   after every merge to `main` or comin skips the branch without saying so —
   see the header of `../services.nix`.

5. **Watch it.** `systemctl status podman-<service>`.

## What is supported

| Compose key | Notes |
|---|---|
| `image` | **Must** carry an `@sha256:` digest |
| `ports` | Strings only, and **must** start `127.0.0.1:` |
| `volumes` | Bind mounts with absolute host paths only — no named volumes |
| `environment`, `labels` | Map or `- K=V` list form, both fine |
| `command`, `entrypoint` | List (exec) form only |
| `depends_on` | Plain list only → systemd `After=`/`Requires=` |
| `user`, `working_dir` | |
| `cap_add`, `cap_drop`, `read_only`, `security_opt`, `tmpfs` | |
| `restart` | Accepted and ignored — systemd governs restarts |

Refused, each with its own explanation in the build error: `env_file`,
`networks`, `build`, `healthcheck`, `deploy`, `configs`, `secrets`,
`profiles`, `extends`, `devices`, `privileged`, `network_mode`.

## The `x-fleet` block

`x-` keys are compose's own extension mechanism — `docker compose` ignores
them — so a file stays a valid compose file while carrying the things this
fleet needs and compose cannot express.

```yaml
x-fleet:
  enable: true              # default true. false = present, validated, not deployed
  memoryHigh: "48M"         # soft cap, reclaim pressure
  memoryMax: "64M"          # hard cap
  memorySwapMax: "0"
  oomScoreAdjust: 900       # default 900 — see below
  cpuWeight: 10
  ioWeight: 10
  requiresMounts: []        # paths that must be real mountpoints before this starts
  secrets: []               # sops key names → --env-file /run/secrets/<name>
  public: null              # a LABEL → <label>.<zone> on the internet. See below.
  frontdoor: null           # a LABEL → <label>.shark-kitefin.ts.net. See below.
```

`x-fleet` applies to **every service in the file**. A file with two services
gives both the same caps; if that is wrong, split it into two files.

### `oomScoreAdjust`

Higher means the kernel kills it **first**. The ladder on this box:

| | |
|---|---|
| `tailscaled`, `sshd` | −900 |
| Immich | 500 |
| monitoring | 800 |
| **anything in this directory** | **900** |

A third-party app off the internet is the most expendable thing on this
machine. The box is already oversubscribed at peak (`tech-debt.md:632`), and
this ladder is what manages it.

### `requiresMounts`

For anything whose data lives on the 7 TB array. It generates the
`AssertPathIsMountPoint` + `RequiresMountsFor` + `BindsTo=` treatment that
`../immich.nix` spends its header explaining. Without it, a container whose
array is unplugged will happily recreate its data directory on the 238 GB root
SSD and fill it — which takes out the deploy loop *and* the ability to roll
back.

Note the split that `../immich.nix` already makes and you should copy: bulk
data on the array, **databases on the root SSD**. A USB enclosure that drops
off mid-write corrupts SQLite far more readily than it corrupts a video file.

### `secrets`

```yaml
x-fleet:
  secrets: [ my-app-env ]
```

declares `sops.secrets.my-app-env` and passes `/run/secrets/my-app-env` to
podman as `--env-file`. The file itself is a set of `KEY=value` lines, edited
with `sops secrets/hong-kong.yaml` — see `../secrets.nix`.

**Order matters**, and it is the same rule Grafana's keys follow: put the key
in the sops file *before* the compose file that references it reaches `main`.
A declared secret that is missing from the file fails
`sops-install-secrets` during **activation**, and comin neither rolls back nor
retries that generation.

### `public`

```yaml
x-fleet:
  public: polls          # -> https://polls.ivanchan.me
```

Puts the app **on the public internet** through the Cloudflare tunnel in
`../public.nix`. Read that file's header before using it.

**A label. Not a hostname, not a domain, not a port.** The zone lives in
`../public.nix` and the port comes from this service's own `ports:` entry, so
neither is sayable here — which is the entire design:

- You cannot publish to a domain you do not own, because you cannot name one.
- You cannot aim the tunnel at Immich (2283), Prometheus (9090) or tsidp,
  because you cannot name a port. cloudflared runs on the host and can reach
  all of them; if a target were typeable, publishing the photo library would
  be one mistyped line deployed within a minute on a machine 9,000 km away.

Two things fail the build rather than guess:

- `public:` on a file with more than one service — which one would it publish?
- `public:` on a service with more than one port — which one would it target?

Publishing needs **both halves**: the push (so the tunnel routes it) and
`terraform apply` in `../../cloudflare/` (so the name resolves). Same for
taking it down. `enable: false` removes both.

And the thing to actually keep in mind: **the app's own login page is now the
only thing between strangers and this box.** tsidp is tailnet-only and stays
that way, so a public app cannot use it. If an app should not be wide open,
Cloudflare Access can put authentication in front of the hostname without the
app supporting it at all — see `../../cloudflare/README.md`.

What can strangers reach?

```sh
grep -rn 'public:' .
```

### `frontdoor`

```yaml
x-fleet:
  frontdoor: rallly      # -> https://rallly.shark-kitefin.ts.net
```

Gives the app its **own tailnet name** — real certificate, no open port.
Handled by `../frontdoors.nix`.

Exactly the same shape as `public`: a label, and the rest is built for you.
The two differ only in which door they open, so an app reachable both ways
usually repeats the same label twice.

Lowercase letters, digits and interior hyphens only. `frontdoor` is the
stricter of the two because it also becomes a systemd unit name and a state
directory under `/var/lib` — so both keys are held to that rule rather than
having two.

**It costs a whole tailscaled process.** `tailscale serve` publishes on the
serving node's own MagicDNS name and ts.net has no CNAMEs, so a distinct name
means a distinct *node* — there is no aliasing to borrow, and hong-kong's own
name is reserved for the machine. Each one is a daemon, a state directory, a
device in the admin console and an auth key to rotate. On a 7.6 GB box that is
not free. Give a name to things that need one, not to everything.

> **Name collisions are silent.** `--hostname=X` is a *request*. If a node
> called `X` already exists, this one quietly becomes `X-1` and every URL is
> wrong with no error logged. This has happened once already — `idp`, on
> 2026-09-01, `tech-debt.md:292`. Before wiping a state directory, delete the
> old node in the admin console first.

The two doors are independent: `public` is the internet via Cloudflare,
`frontdoor` is the tailnet via Tailscale. An app can have either, both, or
neither.

## What you do not get yet

**Nothing, for exposure.** Both doors exist: `x-fleet.public` for the internet
and `x-fleet.frontdoor` for the tailnet.

What is still hand-written is the *other* direction — Immich and Grafana keep
their own `../frontdoor.nix` and `../grafana-frontdoor.nix`, because their
targets come from NixOS module options rather than compose files. Rewriting two
working front doors to remove duplication is a bad trade on a machine nobody
can walk up to.
