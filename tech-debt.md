# Tech debt and unproven claims

Last updated: 2026-09-01.

Two lists. The first is work that is written but not finished. The second is
the more important one: **guards that exist in code but have never fired.**
architecture.md:116 is the standard this repo holds itself to —

> a rescue mechanism you have never triggered is a hypothesis, not a feature

— so anything in the second list is a hypothesis until someone ticks it.

---

## Where PHASE 5 actually stands

Immich, tsidp and the 7 TB array are written across `hosts/hong-kong/`:
`storage.nix`, `secrets.nix`, `identity.nix`, `immich.nix`, tied together by
`services.nix`, whose header is the stage-by-stage runbook. Only `storage.nix`
is imported by `hosts/hong-kong/default.nix` today.

### ⚠️ Live state you will forget

- [ ] **The mount is deployed with `test`, not `switch`.** It came from branch
      `testing-hong-kong` (`b605cea`), which comin applies without touching the
      bootloader. **A reboot right now loses the mount entirely.** Nothing
      depends on it yet, so that is harmless — but do not mistake the current
      working state for a persistent one. It becomes real when the PR merges
      to `main`.

### Stage 1 — the disk

- [x] `nofail` mount of `/dev/disk/by-uuid/84010f4f-…` at `/mnt/storage`, ext4
      confirmed by `lsblk -f`, 7.3 T with 1.6 T of pre-existing data untouched.
- [x] `nofail` verified at the generator level: `RequiredBy=` empty,
      `WantedBy=local-fs.target`, `Before=umount.target` only. Inspected, not
      exercised — see the hypotheses list.
- [x] Runtime removal: `umount` while running left tailscale and sshd
      untouched; `systemctl start mnt-storage.mount` brought it straight back.
- [ ] PR `testing-hong-kong` → `main`, green CI, merge. Until then, see above.
- [ ] Reboot with the disk **present**, from `main`. First real exercise of
      gates 3 and 4 on this box.
- [ ] `sudo tune2fs -c 0 -i 0 /dev/sda1` — stop mount-count and time-based
      fsck. `systemd-fsck@` has an infinite `TimeoutSec`, so a forced full
      check on 7 TB can leave Immich down for an hour. `nofail` keeps it off
      the boot path either way. Does not touch data.
- [ ] **Physical unplug drill — planned for the evening of 2026-09-01.**
      Unplug the enclosure, reboot, confirm the box returns with tailscale
      Running and `systemd-analyze blame | head` showing no stall; then replug
      and reboot. This is the acceptance test for the entire feature and the
      only one that cannot be done over SSH.

### Stage 2 — sops and tsidp

- [ ] Age keys: host key via `ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub`,
      plus an **offline** `age-keygen` key stored away from the fleet. Without
      the offline key, a regenerated host key means the secrets are gone.
- [ ] Replace the two `age1REPLACE_ME_*` placeholders in `.sops.yaml`
      (hong-kong and offline). The shanghai rule stays a placeholder — no
      `secrets/shanghai.yaml` is created, so it is never evaluated.
- [ ] Create `secrets/hong-kong.yaml` with `tsidp-env`.
- [ ] Uncomment the sops-nix input **and** module in `flake.nix`, run
      `nix flake lock`, commit `flake.lock` (operating rule 1).
- [ ] Tailscale auth key: reusable, non-ephemeral, pre-approved, tagged
      `tag:container`. Tagged matters — tagged devices do not expire, and a
      node key lapsing in 180 days on an unreachable box is a time bomb.
- [ ] Confirm the `idp` node registers, carries the tag, and shows expiry
      disabled.
- [ ] Confirm HTTPS certificates and MagicDNS are enabled on the tailnet.
      Both tsidp and `tailscale serve` need them.

### Stage 3 — the OIDC client

- [ ] Create the Immich client in tsidp's admin UI at
      `https://idp.shark-kitefin.ts.net` with redirect URIs `/auth/login`,
      `/user-settings`, `/api/oauth/mobile-redirect` under
      `https://hong-kong.shark-kitefin.ts.net`.
- [ ] Secret → `immich-oauth-client-secret` in `secrets/hong-kong.yaml`.
      It is shown **once**.
- [ ] Client ID → `hosts/hong-kong/immich.nix` (`REPLACE-ME-WITH-THE-TSIDP-CLIENT-ID`).

### Stage 4 — Immich

- [ ] Deploy, complete first sign-up (Immich makes the first user admin).
- [ ] Upload a photo and a video; confirm files land under
      `/mnt/storage/immich` and the log shows VAAPI, not software transcoding.
- [ ] Confirm OIDC login works, **and** that password login still works.
- [ ] Confirm the nightly `pg_dump` lands in `/mnt/storage/immich/backups`.

---

## Hypotheses — guards that have never fired

Each of these is real code with a real reason. None has been observed doing
its job on this machine.

- [ ] **`nofail` at boot.** Inspected via `systemctl show`, never exercised
      with the disk actually absent. The evening drill closes this.
- [ ] **`AssertPathIsMountPoint` on `immich-media-setup`.** The distinction
      from `ConditionPathIsMountPoint` is the whole guarantee — a failed
      *Condition* marks the job successful and lets `Requires=` dependents run.
      Never triggered. Worth deliberately breaking once, on
      `testing-hong-kong`, by pointing `storage.nix` at a bogus UUID and
      confirming `immich-server` refuses to start rather than creating a
      library on the root disk.
- [ ] **`BindsTo` on an out-of-band `umount`.** Nothing with `BindsTo` is
      deployed yet — the stage 1 `umount` test proved only that the system
      does not care. Re-run it after stage 4 and confirm Immich stops.
- [ ] **Memory caps.** `MemoryHigh=2G` / `MemoryMax=3G` on `system-immich.slice`
      and `OOMScoreAdjust=-900` on tailscaled and sshd. Numbers are estimates,
      not measurements. Watch `systemctl status system-immich.slice` under a
      real import before trusting them.
- [ ] **Immich's `.immich` marker check.** Independent of everything above.
      Unverified that it behaves as documented on this setup.
- [ ] **sops decryption failure.** Expected to leave `/run/secrets` empty,
      skip tsidp via `ConditionPathExists`, and fail `immich-server` — while
      tailscaled and sshd carry on. Never tested.
- [ ] **Gate 3 and gate 4 on this box.** README.md:113 says to rehearse them
      before the machines leave your desk. They left.

---

## Pre-existing debt found while doing this work — none of it fixed

- [ ] **Gate 2 does not exist as documented.** README.md:92-113 and
      architecture.md both claim a failed `switch-to-configuration` makes comin
      restore the previous generation. At the pinned rev (`ffeadf3`),
      `internal/executor/utils.go:deployLinux` calls `profile.SetSystemProfile`
      **first**, then `switchToConfigurationLinux`, and merely returns the
      error. There is no rollback anywhere in `internal/` — the only match for
      "rollback" is a comment in `utils/reboot.go`. Gates 3 and 4 are
      unaffected. **Fix the docs, not the code.**
- [ ] **Consequence of the above, worth its own line:** `Deployer.IsAlreadyDeployed`
      keys on `OutPath` alone, so comin will **not retry a generation it has
      already failed**. After fixing whatever broke a deploy you must
      `systemctl start <unit>` by hand or push a new commit.
- [ ] **`extraUpFlags` is dead code.** `modules/tailscale-node.nix:24` sets
      `[ "--advertise-exit-node" "--ssh" ]`, but upstream applies it only
      inside `tailscaled-autoconnect`, which is `mkIf (authKeyFile != null)`.
      With no auth key those flags never run — the live settings came from the
      manual `tailscale up`. `extraSetFlags` is the option that applies.
- [ ] **CI does not pass `--no-update-lock-file`** despite architecture.md:62
      and install-runbook.md:28 both stating that it does. That is the flag
      that makes CI fail the same way comin does.
- [ ] **`personal-vpn.tar.gz`** at the repo root is a 45-byte truncated gzip,
      committed by accident.
- [ ] **install-runbook.md:6 references `claude/build-log.md`**, which does not
      exist.
- [ ] **README.md:16-18 says to replace a `REPLACE THIS` block** in
      `modules/base.nix`. There is no such block; the keys are already in place.
- [ ] **Gate 4 does not check comin.** Deliberately deferred
      (`modules/boot-verdict.nix:232-235`, `modules/comin.nix:81-93`) to a
      second deploy. A machine whose deploy agent is dead is a machine you have
      quietly lost. Still deferred.
- [ ] **`.github/workflows/build.yml` references a `vm-boot` check** in a
      commented block. `flake.nix` does not define one.

---

## Decisions taken deliberately, worth revisiting later

- **`oauth.autoRegister = true`** plus the wide-open `acls` rule in
  `tailscale/acl.hujson` means every member of `shark-kitefin.ts.net` can
  create themselves an Immich account. tsidp capability grants are *not* what
  gates this — tsidp denies only the admin UI and dynamic client registration
  by default. On a personal tailnet this is probably the intent. It is still a
  choice.
- **`passwordLogin.enabled = true` stays on** until tsidp has earned trust.
  tsidp is v0.0.12 and the NixOS module sets `TAILSCALE_USE_WIP_CODE=1`.
  OIDC-only on an unreachable box means a tsidp outage locks you out of your
  own photographs.
- **Immich's admin System Settings page is read-only** because
  `services.immich.settings` is non-null. Every change is a commit. The
  corollary that bites: it is a *partial* config, so anything not set takes
  Immich's default rather than whatever is in the database — which is why
  `settings.machineLearning.enabled = false` has to be set explicitly
  alongside `machine-learning.enable = false`.
- **The existing 1.6 TB on the array is not exposed to Immich.** Making it
  browsable would be an *external library* — a different feature, a separate
  change.
- **Postgres stays on the internal SSD**, per architecture.md:203. The nightly
  `pg_dump` into `/mnt/storage/immich/backups` is what keeps the array
  self-consistent.
