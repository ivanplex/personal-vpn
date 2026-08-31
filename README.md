# personal-vpn

Declarative NixOS fleet. Two machines, neither physically reachable once
deployed.

| Host | Location | Duty | Branch |
|---|---|---|---|
| `hong-kong` | Hong Kong | exit node; later Immich, Prometheus + Grafana, Attic cache | `main` |
| `shanghai` | Shanghai | exit node | `stable` |
| `uk` | — | deferred, no access | — |

Tailnet: `shark-kitefin.ts.net`

## Before you install

1. **Put your SSH public key in `modules/base.nix`.** It is marked with a
   `REPLACE THIS` block. This is the only edit the repo needs, and it is how
   you get back into the machine. Do not install without it.
2. **The machine must be in UEFI mode.** Check `ls /sys/firmware/efi` in the
   installer. If it fails, disable CSM/Legacy in the BIOS and boot the USB
   from the entry prefixed `UEFI:`. Gate 3 depends on systemd-boot, which
   depends on UEFI.
3. Push this repo to `github.com/ivanplex/personal-vpn`.

## Installing

From the NixOS installer, booted in UEFI mode, as root:

```sh
nix --experimental-features "nix-command flakes" \
  run 'github:nix-community/disko/latest#disko-install' -- \
  --flake 'git+https://TOKEN@github.com/ivanplex/personal-vpn#hong-kong' \
  --disk main /dev/nvme0n1 \
  --write-efi-boot-entries
```

`TOKEN` is a fine-grained GitHub PAT, this repo only, Contents: Read-only.
It lives in the installer's RAM and dies with the reboot — revoke it after.

**This destroys the target disk.** `--disk main /dev/nvme0n1` is the internal
NVMe; `/dev/sda` is your USB stick. Do not mix them up.

Then reboot, pull the USB, and:

```sh
sudo tailscale up --ssh --advertise-exit-node
```

Tag the node in the Tailscale admin console and **disable key expiry** for
that tag. An expired key on the Shanghai box is an unrecoverable outage.
The tags themselves are declared in `tailscale/acl.hujson` (`tagOwners`) —
see [Tailnet policy](#tailnet-policy) below.

Finally, the gate that matters: **unplug the monitor and keyboard, reboot,
and SSH in over Tailscale from another machine.** If that does not work you
are not finished, and nothing later matters.

## Layout

```
flake.nix                     both hosts, one spine
hosts/hong-kong/              Hong Kong: hardware notes + disk layout
hosts/shanghai/               Shanghai: hardware NOT yet confirmed
modules/base.nix              bootloader, nix settings, users, sshd, firewall
modules/tailscale-node.nix    exit node, native (not containerised)
modules/boot-verdict.nix      GATES 3 AND 4 — read this one properly
modules/phase3.nix            sops + comin + heartbeat, not yet imported
.github/workflows/build.yml   GATE 1
tailscale/                    tailnet policy — ACL, tags, autoApprovers (Terraform)
```

## Tailnet policy

The tailnet side of the picture — who may talk to whom, which tags exist,
which tags are auto-approved as exit nodes, the SSH rule, the Anthropic app
connector — is `tailscale/acl.hujson`, applied as a single `tailscale_acl`
resource by Terraform. `modules/tailscale-node.nix` is what a *node* does;
`tailscale/` is what the *tailnet* allows.

```sh
cd tailscale
terraform plan      # diff against the live policy
terraform apply
```

Credentials are a Tailscale OAuth client in `tailscale/terraform.tfvars`,
which is gitignored — copy `terraform.tfvars.example` and fill it in. State
is local (`terraform.tfstate`, also ignored); if it is ever lost,
`terraform import tailscale_acl.main_policy acl` recovers it. Encrypting the
tfvars with sops is Phase 3 work, alongside the node secrets.

## The four gates

A change has to survive all four before it is trusted:

1. **CI build** — a bad expression fails in Actions and never reaches a
   machine. Free, and catches most mistakes.
2. **Activation** — a failed `switch-to-configuration` makes comin restore
   the previous generation. Free, once comin is running.
3. **Boot** — a new generation is armed as a *one-shot* while the permanent
   default stays on the last known-good one. A kernel that will not boot
   falls back with no help from anybody.
4. **Runtime health** — ten minutes after boot, a timer checks that the
   machine is genuinely reachable. Healthy: promote the generation to
   permanent default. Unhealthy: roll back and reboot.

Gates 3 and 4 both live in `modules/boot-verdict.nix`. They are the two that
matter for a machine you cannot touch, and they are the two you have to
build yourself.

**Rehearse them before the machines leave your desk.** Push a commit setting
`services.tailscale.enable = false` and watch the box recover on its own.
If you have not seen it happen, you do not have the feature.

## Phases

- **1 — install.** No sops, no comin. Just users, sshd, Tailscale, disks.
- **2 — tailnet.** `tailscale up` by hand, once, while you can still reach it.
- **3 — hand over to Git.** sops-nix, comin, external heartbeats.
  See `modules/phase3.nix`.
- **4 — rehearse the gates.** Then Shanghai ships.
- **5 — workloads.** Immich, Prometheus, Grafana, the 7 TB disk, Attic.

After phase 3, SSH is for **looking**. Every change goes through this repo.
