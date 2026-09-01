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

### The `idp` / `idp-1` name collision (12:07)

Stage 2 verification turned up the issuer pointing at the wrong name:

```
tsidp server started server_url=https://idp-1.shark-kitefin.ts.net
```

An older container already held `idp`, so the coordination server handed the
new tsnet node `idp-1` and the OIDC issuer moved with it. Nothing errored;
`systemctl status tsidp` was green throughout. `settings.hostName` is a
*request*, and the answer can carry a suffix — there is no way to assert the
result from Nix.

Fixed by deleting the old container to free the name, then moving
`/var/lib/private/tsidp` aside and restarting, rather than renaming in the
console. The wipe was chosen deliberately: it costs nothing today (no OIDC
client exists yet, so nothing depended on the issuer) and it **tests the auth
key at the moment failure is cheapest**. tech-debt.md had listed reusable,
pre-approved and tagged as unverified. All three now proven in one restart:

```
12:07:13 LocalBackend state is NeedsLogin; running StartLoginInteractive...
12:07:15 INFO tsidp server started server_url=https://idp.shark-kitefin.ts.net
12:07:18 AuthLoop: state is Running; done
```

Five seconds, no human interaction — a single-use or approval-required key
could not have done that. `tailscale status --json` confirms
`Tags=["tag:container"]` with no `KeyExpiry`. Non-ephemeral is still open, and
is being tested for free: the stale `idp-1` is offline, and an ephemeral node
would be deleted shortly after going offline.

Also verified in passing, closing two more stage-2 boxes: MagicDNS and HTTPS
Certificates are both on — the discovery endpoint under
`https://idp.shark-kitefin.ts.net` returns
`"issuer": "https://idp.shark-kitefin.ts.net"` over a valid certificate.

**The durable lesson**, now in both `identity.nix` and `tech-debt.md`: before
wiping tsidp state or reinstalling this box, delete the old node in the console
*first*, then grep `server_url` from the journal. After stage 3 this stops
being free — `immich.nix` pins `issuerUrl`, and a suffixed issuer fails OIDC
discovery with an error that points at Immich rather than at the name.

### Stages 3 and 4: the OIDC client, and Immich actually running (14:12)

**Stage 3 turned out not to need a browser.** The runbook assumed the tsidp
admin UI was a click-through. It is server-rendered HTML with no JavaScript:
`GET /new` is a plain form, `POST /new` with `name` and newline-separated
`redirect_uris` creates the client, and `GET /clients/` returns JSON.
Authorisation is by tailnet identity — tsidp does a WhoIs on the connection —
so any admin device on the tailnet can drive the whole thing with `curl`.

Client `127eb5a31f4804aee40b282d618052cd` created with all three redirect URIs,
read back from `/clients/` to confirm. The secret went into
`secrets/hong-kong.yaml` through `sops set … --value-stdin`, so it never
appeared in a process argument list, and **both recipients were re-checked on
the file afterwards** — that was this morning's near-miss, so it is a habit now
rather than a one-off.

**Stage 4 deployed and came up clean.** Built first (`nixos-rebuild build`,
Immich 2.7.5 entirely from cache), then activated with `test` from a copy of
the working tree — the runbook's no-commit path, so nothing is on a branch and
nothing is in the bootloader.

What the guards actually did, rather than what they promise:

- `immich-media-setup` compared device numbers and passed: `/mnt/storage` is
  2049, `/` is 66307. The library is on the array. Root moved 5.7 G → 7.3 G,
  which is Postgres and store paths, not photographs.
- Immich seeded and verified all six mount markers itself —
  `"mountChecks":{"thumbs":true,"upload":true,"backups":true,"library":true,
  "profile":true,"encoded-video":true}`.
- The slice caps landed: `MemoryHigh=2G`, `MemoryMax=3G`, `immich-server`
  inside `system-immich.slice` at `OOMScoreAdjust=500`. Sitting at 1.36 G.
- `boot-verdict` ran 13 seconds after activation: tailscale ok, sshd ok, DNS
  ok, **0 failed units**. The thing this whole directory was designed not to
  disturb was not disturbed.
- `/api/server/features` reports `oauth: true`, `oauthAutoLaunch: false`,
  `passwordLogin: true` — break-glass intact, as designed.

### Immich got its own tailnet node (15:47)

`hong-kong.shark-kitefin.ts.net` → `immich.shark-kitefin.ts.net`.

The constraint that decided the design: **a name in the ts.net zone belongs to
a node.** MagicDNS has no CNAMEs, and `tailscale serve` always publishes on the
serving node's own name. `hong-kong` cannot be renamed — it is the machine, an
exit node, and the name you SSH to. So a distinct name meant a distinct node,
and that meant a second tailscaled.

`modules/tailscale-node.nix` argues against precisely this: a second identity
costs "a second identity, a second key to rotate, a state volume and NET_ADMIN
for no gain." Three of the four still apply and were accepted. The fourth was
not paid — `--tun=userspace-networking` means no TUN device, so no NET_ADMIN,
no route entries, and no way to disturb the exit node. `tsnsrv` would have been
less code but is not in nixpkgs, and the `tailscale` package already on the box
ships `tailscaled`, so this needed no new flake input.

The flag that actually kept me up: **`--accept-dns=false`**. tailscaled manages
`/etc/resolv.conf`. 2026-08-31 was this box left able to resolve `*.ts.net` and
nothing else — and that was *one* daemon getting DNS wrong. Verified after
deploy that the real tailscaled is still active, still advertising the exit
node, and `/etc/resolv.conf` is still systemd-resolved's stub.

It went in as `hosts/hong-kong/frontdoor.nix` rather than back into
`identity.nix`, so the whole front door is revertible by one import line — the
repo's staging rule, and worth having for the one component that adds a second
daemon to a machine whose prime directive is staying reachable.

Checked the name **before** registering, which is this morning's lesson
already paying for itself: `immich` was free, and the node came up as `immich`
rather than `immich-1`. Cert issued for `CN = immich.shark-kitefin.ts.net`.

The tsidp client did not need recreating — `POST /edit/<client_id>` updates
redirect URIs in place, so the client ID and secret survived and
`immich-oauth-client-secret` never had to be re-encrypted.

**One footgun, hit live.** Removing the old `tailscale-serve-immich` unit did
not retire the old front door: `tailscale serve` config is persisted by
tailscaled, not by the unit, and both files deliberately omit `ExecStop` so a
deploy never briefly drops the door. `hong-kong` kept serving Immich on its own
name until `sudo tailscale serve --https=443 off` was run by hand. Now in
`tech-debt.md`, because the next front-door move will hit it too.

### A credential was exposed, and needs rotating

While masking the decrypted sops output to check both keys had survived
re-encryption, the mask pattern did not account for `tsidp-env` being a YAML
block scalar, and **the Tailscale auth key was printed in full**. It did not
leave the machine or reach the repo, but it is in a transcript and in terminal
scrollback.

That key is reusable, non-expiring, pre-approved and tagged `tag:container` —
and `tag:container` carries `dst: ["*:*"]` in `acl.hujson`, so it is a
permanent join-anything credential for the tailnet. It should be revoked and
reissued. The cost is near zero, which is the one good thing here:
`TS_AUTH_KEY` is read only when the tsnet state directory is empty, so the
running `idp` node is untouched by a rotation. Tracked in `tech-debt.md`.

The lesson worth keeping: **do not mask secrets with a regex.** Print the key
names and the value lengths, or nothing at all.

### State at end of session

- `main` = `8c9279e` — stage 1 (the mount) is live and persistent. **This is
  still what the box boots into.**
- `testing-hong-kong` = `2605366` — stage 2. Verified: sops decrypts, `tsidp`
  is active, and `https://idp.shark-kitefin.ts.net` serves the right issuer.
- **Uncommitted in the working tree**: stage 3 + 4. `default.nix` now imports
  `./services.nix` (all four files), `immich.nix` carries the real client ID,
  and `secrets/hong-kong.yaml` has `immich-oauth-client-secret`. Both
  placeholders are gone.
- **Running on the box**: a `test` activation of that working tree, made from
  `/tmp/pv`. Immich is up at `https://immich.shark-kitefin.ts.net`, on its own
  tsnet node. It is in no profile and no bootloader entry, so it is one reboot
  from disappearing — by design.

### Next

1. **Claim the Immich admin account.** First user to sign in becomes admin,
   the tailnet `acls` are wide open, and `autoRegister = true`. This is the
   only item with a clock on it. **https://immich.shark-kitefin.ts.net**
2. Then, in the same sitting: upload a photo and a video (confirm VAAPI, not
   software transcoding), test the OIDC button, and test that password login
   still works.
3. **Rotate the Tailscale auth key** — exposed today, see above.
4. Tonight: the physical unplug drill, against stage 1 as planned. It will
   wipe the test activation; that is expected. Console in reach.
5. Then commit stages 3+4, merge to `main`, and reboot once **while you can
   still see the screen** — that is the first boot of a materially new
   generation, and gate 4 cannot catch a boot failure yet.
6. Two cleanups: delete the stale `idp-1` node, and
   `rm -rf /var/lib/private/tsidp.bak-idp-1`.
7. Then the `boot-verdict.nix` rewrite, which remains the largest known risk.
