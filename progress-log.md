# Progress log

Newest entry first. What was actually done, what it cost, and what was learned —
the things that do not survive in a diff. `tech-debt.md` holds what is *left*;
this holds what *happened*.

---

## 2026-09-01 — Immich groundwork: the array, sops-nix, tsidp

Goal: run Immich from a NixOS module, library on the 7 TB external array,
authenticated by Tailscale's tsidp, without any of it being able to stop the
box booting or take out the tailnet.

### Written

All of PHASE 5, split so each piece deploys and reverts on its own:

| file | what |
|---|---|
| `hosts/hong-kong/storage.nix` | the `nofail` mount, and nothing else |
| `hosts/hong-kong/secrets.nix` | sops-nix setup, scoped to this host |
| `hosts/hong-kong/identity.nix` | tsidp + the `tailscale serve` front door |
| `hosts/hong-kong/immich.nix` | library dir, Immich, memory caps — **not yet imported** |
| `hosts/hong-kong/services.nix` | aggregator; its header is the staging runbook |
| `tech-debt.md` | what is left and what is unproven |

Plus `OOMScoreAdjust = -900` on tailscaled (`modules/tailscale-node.nix`) and
sshd (`modules/base.nix`), so Immich can never squeeze the two processes that
are the only ways back into the machine.

### Decided

- **Secrets: sops-nix**, scoped to `hosts/hong-kong/` rather than `modules/`,
  so shanghai never gets a `defaultSopsFile` and keeps building untouched.
- **Immich ML off**, per architecture.md — and `settings.machineLearning.enabled`
  set explicitly too, because the NixOS option only stops the systemd unit.
- **Immich settings declarative**, so the admin UI goes read-only and OAuth
  lives in git.
- **`passwordLogin.enabled = true` stays**, as break-glass on a v0.0.12 IdP.
- **EFI `LoaderEntryDefault` unset** as an interim fix; proper `boot-verdict`
  rewrite deferred until after Immich lands. See `tech-debt.md`.

### Three things found that had nothing to do with Immich

**1. Gates 3 and 4 have never worked under comin.** comin hardcodes its own Nix
profile (`system-profiles/comin`); `boot-verdict.nix` reads the default profile.
So `armScript` compared 6 against 6 and armed nothing, `verdictScript` would
no-op the moment the box booted a comin generation, and the EFI default was
pinned to the last hand-run `nixos-rebuild` from Aug 31 — meaning **every comin
deployment was effectively `test` and would vanish on reboot.** Both scripts
fail *safely*, which is precisely why nobody noticed; `fleet-status` reported a
reassuring `6 / 6 / 6` throughout. Full detail at the top of `tech-debt.md`.

**2. comin silently skips a diverged testing branch.** `hasNotBeenHardReset()`
in comin's `internal/repository/git.go` requires main's commit to be an ancestor
of the testing head, and the failure is logged at **debug** level only. Merging
any PR to `main` causes exactly that divergence, whichever merge style is used.
Symptom: comin does nothing at all, no error anywhere, `fleet-status` fine. Cost
here was one confusing round of "why are none of these units present". The habit
is now in the `services.nix` runbook:

```
git fetch origin && git rebase origin/main && git push --force-with-lease
```

**3. Near-miss: `.sops.yaml` had the same key in both recipient slots.**
hong-kong's host key had been pasted into `&offline` as well as `&host_hk`.
This would have *appeared* to work — the box could decrypt, so deploys would
have succeeded — while the offline recipient was decorative and the file could
not be reopened for editing on the MacBook. Losing the host key to a reinstall
would have lost every secret permanently, which is the exact scenario the file's
own header warns about in capitals. Caught by comparing the pasted value against
`# public key:` in `keys.txt`; both distinct recipients are now confirmed
present in `secrets/hong-kong.yaml`'s metadata.

### Verified on the box

- `nofail` proven at the generator level, without a reboot:
  `RequiredBy=` empty, `WantedBy=local-fs.target`, `Before=umount.target` only.
  That, not the `findmnt` options, is where `nofail` shows up.
- Array mounts: `/dev/sda1`, ext4, 7.3 T with 1.6 T of pre-existing data left
  strictly alone.
- Live removal: `umount` while running left tailscale and sshd untouched.
- `bootctl set-default ""` unset the EFI variable; `bootctl` now resolves the
  default through `loader.conf` to `nixos-comin-generation-2.conf`.

### State at end of session

- `main` = `8c9279e` — stage 1 (the mount) is live and persistent.
- `testing-hong-kong` = `80702fc` — stage 2 (sops-nix + tsidp) pushed, applied
  with `test`. **Deploy not yet verified.**
- `hosts/hong-kong/default.nix` imports `disko, storage, secrets, identity`.
  `immich.nix` is deliberately still out: it needs a client ID only a running
  tsidp can issue.
- Two placeholders remain: the tsidp client ID in `immich.nix`, and the
  `immich-oauth-client-secret` key in `secrets/hong-kong.yaml`.

### Next

1. Verify the stage 2 deploy — `sops-install-secrets`, `/run/secrets/tsidp-env`,
   `tsidp`, and the `idp` node appearing tagged in the console.
2. Tonight: the physical unplug drill. First boot of a comin generation, so do
   it with a console in reach — see the warning in `tech-debt.md`.
3. Stage 3: create the OIDC client at `https://idp.shark-kitefin.ts.net`.
4. Stage 4: import `./immich.nix`.
5. Then the `boot-verdict.nix` rewrite, which is now the largest known risk.
