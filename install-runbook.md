# Node install runbook

**Reusable.** This is the procedure for bringing any new machine into the
fleet — Shanghai next, the UK box whenever access returns, and any rebuild
after a dead disk. Corrected against what actually happened installing
`hong-kong` on 2026-08-30/31; see `claude/build-log.md` for why each step
reads the way it does.

**Repo:** `github.com/ivanplex/personal-vpn` (private)
**Tailnet:** `shark-kitefin.ts.net`
**ISO:** `nixos-minimal-26.05.*-x86_64-linux.iso`

| Node | Status |
|---|---|
| `hong-kong` | Complete. All four gates proven, comin deploying. |
| `shanghai` | Not started. Hardware unconfirmed. |
| `uk` | Deferred — no access. Reinstall via `nixos-anywhere` when it returns. |

---

## Rules that override intuition

Every one of these cost real time. Read them before starting.

1. **Commit `flake.lock`.** comin clones into a read-only store and cannot
   write a lock, so a missing or stale lock means the node silently stops
   deploying. This caused three separate failures in three disguises. CI now
   uses `--no-update-lock-file` so it fails the same way comin would.
2. **Test every reboot with the monitor unplugged.** `loader.conf` has
   `timeout 5`; touching the boot menu overrides the one-shot and makes gate 3
   look broken when it isn't.
3. **Never run `nixos-rebuild switch` in a bare SSH session.** If the deploy
   touches `tailscaled` it kills your connection and SIGHUPs itself
   mid-flight, leaving the profile advanced and the bootloader unarmed. Use
   `tmux`, or `nixos-rebuild boot` + reboot. Once comin is running this stops
   mattering — it deploys as a system service.
4. **Nix only sees what git tracks.** A new file is invisible until
   `git add`. And **`git checkout <path>` restores from the INDEX, not HEAD** —
   a staged change survives it. Use `git checkout HEAD -- <path>`.
5. **`cp -r src/* dest/` skips dotfiles.** `.github` and `.sops.yaml` get
   silently dropped. Name them explicitly.
6. **No `awk`, `sed`, `basename` or `sort` in systemd unit scripts.** Units
   get a minimal PATH and gawk is not on it. A missing binary there fails
   silently in the one script whose job is rescuing an unreachable machine.
7. **Read `LoaderEntryDefault`, not `bootctl list`.** The `(default)` marker
   reports `loader.conf`, which is the lowest-priority source. Precedence is
   one-shot → `LoaderEntryDefault` → `loader.conf`. Or just run `fleet-status`.

---

## Phase 0 — BIOS. The only unrecoverable part.

- [ ] **UEFI only, CSM/Legacy off.** systemd-boot requires it, and gate 3
      requires systemd-boot. `hong-kong` shipped in legacy mode; check
      `ls /sys/firmware/efi` in the installer.
- [ ] **Restore on AC power loss → Power On.** Default is usually "stay off".
      Skip this and the first power cut ends the machine permanently.
- [ ] **Secure Boot off**
- [ ] Boot order: internal disk first
- [ ] Halt-on-error / "no keyboard detected" → **disabled**, so it boots headless
- [ ] Wake-on-LAN on
- [ ] Note whether a watchdog timer option exists
- [ ] No BIOS password — you would have to be present to type it
- [ ] Fan curve for an unattended warm room, not for quiet
- [ ] Record the MAC address, label the box, photograph the BIOS screens
- [ ] **Boot with no monitor and no keyboard attached and confirm it comes up**

---

## Phase 1 — install

### Get off the console first

Do not type long commands or tokens on a screen with no clipboard. At the
physical keyboard, only:

```
passwd            # short throwaway password, dies at reboot
ip -br a          # note the address
```

Then from your laptop: `ssh nixos@<ip>`, `sudo -i`. Now you have paste and
scrollback, and can send output into chat.

*Rebooting the ISO regenerates its host key; clear it with `ssh-keygen -R <ip>`.*

### Discovery — record these before installing

```
lsblk -o NAME,SIZE,MODEL,TRAN
ls /sys/firmware/efi >/dev/null && echo UEFI || echo BIOS
lscpu | head -20
free -h
ip -br link
```

Add the results to `hosts/<name>/default.nix` and confirm the disk device in
`hosts/<name>/disko.nix`. **The installer USB usually appears as `/dev/sda`;
the target is normally the NVMe.** Do not mix them up.

### Install — two steps, NOT `disko-install`

The single-command form runs out of space: the installer's Nix store is a
~3.9 GB tmpfs, too small for a system closure. Partitioning first activates
the swap partition from the config, which lets the tmpfs spill into it.

```
# 1. partition, format, mount — DESTROYS THE TARGET DISK
nix --experimental-features "nix-command flakes" \
  run 'github:nix-community/disko/latest' -- \
  --mode destroy,format,mount --flake '/root/pv#<hostname>'

lsblk; df -h /mnt; free -h      # /mnt mounted, swap active

# 2. build and install, with temp space on the real disk
mkdir -p /mnt/tmp
TMPDIR=/mnt/tmp nixos-install --flake '/root/pv#<hostname>'
```

Get the repo onto the installer first with a **fine-grained PAT** (this repo
only, Contents: Read-only, short expiry):

```
git clone https://TOKEN@github.com/ivanplex/personal-vpn.git /root/pv
```

**Let `nixos-install` prompt for a root password.** Root SSH is disabled so it
only works at the physical console — and the `ivan` account has no password,
so without it there is no local login at all.

Then `reboot`, pull the USB, revoke the PAT.

---

## Phase 2 — join the tailnet

```
sudo tailscale up --ssh --advertise-exit-node --advertise-tags=tag:<yourtag>
```

Authenticate in the browser. **Tag the node** — tagged devices have no key
expiry, which removes the failure where a remote box silently drops off the
tailnet months later. Then **approve it as an exit node** in the machine's
route settings; "offers exit node" only means advertised.

The tags are declared in `tailscale/acl.hujson` (`tagOwners`). A node that
carries a tag listed under `autoApprovers.exitNode` there is approved as an
exit node automatically, with no visit to the route settings.

> **Gate:** unplug monitor and keyboard, reboot, and SSH in over Tailscale
> from another machine. If that fails you are not finished, and nothing
> later matters.

---

## Phase 3 — hand over to comin

One manual file, because it is a secret:

```
sudo mkdir -p /etc/comin && sudo chmod 700 /etc/comin
sudo install -m 0400 /dev/stdin /etc/comin/github-token <<'EOF'
github_pat_...
EOF
```

Fine-grained, this repo only, Contents: Read-only, **long expiry**, with a
calendar reminder to rotate. An expired token means silent non-deployment.

Then one last manual deploy **inside tmux**:

```
tmux new -s deploy
nixos-rebuild switch --flake /root/pv#<hostname>
```

Verify: `fleet-status`, `systemctl status comin`, `journalctl -u comin -f`.

From here, pushing to the branch this host tracks IS the deploy.
`hong-kong` tracks `main`; `shanghai` tracks `stable`.

---

## Phase 4 — rehearse the gates before it leaves

Non-negotiable for any machine going somewhere you cannot reach.

```
cd /root/pv
# set services.tailscale.enable = false in modules/tailscale-node.nix
git add -A
nixos-rebuild boot --flake /root/pv#<hostname>   # 'boot', so nothing disconnects
```

Confirm `boot-arm: default stays on known-good N; N+1 gets one try`, then
reboot headless and **leave it alone for forty minutes**. Expected:

- +10 min — `FAIL tailscaled is not active`, check 1 of 3
- +20 min — check 2 of 3
- +30 min — check 3 of 3 → `UNHEALTHY — rolling back to generation N`
- reboots itself, comes back healthy

The line that matters is `rolling back to generation N` with a real number.
Then `git checkout HEAD -- modules/` to discard the break.

---

## Phase 5 — workloads (hong-kong only)

Last, because it is the only part whose failure costs data rather than
uptime. Attic cache, Prometheus + Grafana + Alertmanager, Immich on the 7 TB
disk (`nofail`, always), external heartbeats from both nodes.

---

## Shanghai specifics

- Deploy order is permanent: `main` → hong-kong → 24 h soak → `stable` →
  shanghai. hong-kong is the canary.
- Mirror the repo to a Forgejo instance on hong-kong; comin supports multiple
  remotes, so shanghai can try the tailnet first and GitHub second.
- Substituters in order: Attic on hong-kong → a domestic mirror (TUNA/USTC) →
  `cache.nixos.org`.
- Consider a DERP relay on hong-kong if latency is poor.
- Add a global nameserver in the Tailscale admin console. The tailnet has
  split-DNS routes but no global resolvers, which is what caused hong-kong's
  DNS loop; shanghai would hit it identically.
- Safe failure mode: a node that cannot reach git simply does not update.