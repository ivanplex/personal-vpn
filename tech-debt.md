# Tech debt and unproven claims

Last updated: 2026-09-01.

Two lists. The first is work that is written but not finished. The second is
the more important one: **guards that exist in code but have never fired.**
architecture.md:116 is the standard this repo holds itself to —

> a rescue mechanism you have never triggered is a hypothesis, not a feature

— so anything in the second list is a hypothesis until someone ticks it.

---

## 🔴 Gates 3 and 4 do not work with comin (confirmed 2026-09-01)

**comin deploys into its own Nix profile. Every safety mechanism in this repo
reads a different one.** Nothing here is theoretical — it was confirmed on the
box, and it is upstream of all the Immich work.

### What was observed

```
booted   /nix/store/y4hzk5...   = system-6-link      (hand-run nixos-rebuild, Aug 31 20:31)
current  /nix/store/sk8pcnc...  = comin-2-link       (what is actually running)
/nix/var/nix/profiles/system -> system-6-link        (comin never touches this)
/boot/loader/loader.conf: default nixos-comin-generation-2.conf   (correct)
EFI LoaderEntryDefault:   nixos-generation-6.conf                 (wins, and is wrong)
comin log:                "boot-arm: already running the latest generation (6)"
```

### Why

`internal/profile/profile.go` in comin hardcodes

```go
const ( systemProfiles = "/nix/var/nix/profiles/system-profiles"
        profileName    = "comin" )
```

so deployments land in `system-profiles/comin-N-link` and get boot entries named
`nixos-comin-generation-N.conf`. It is **not configurable**.

`modules/boot-verdict.nix` sets `profiles=/nix/var/nix/profiles` and reads
`$profiles/system` and `$profiles/system-*-link` — the *default* profile, which
comin never advances. (`system-profiles/` is not matched by that glob: no
`-link` suffix.)

### Consequences

- [ ] **Every comin deployment is effectively `test`.** The EFI default points
      at the last hand-run generation, so a reboot — planned, watchdog, or power
      cut — silently reverts to the Aug 31 config.
- [ ] **Gate 3 never arms anything.** `booted` and `latest` both resolve to 6
      from the stale profile, so `armScript` short-circuits on
      `"already running the latest generation"`.
- [ ] **Gate 4 is inert the moment the box boots a comin generation.**
      `booted_generation()` finds no match, and `verdictScript` prints
      `"cannot identify the running generation; taking no action"` and exits 0.
      No promotion, no rollback.
- [ ] **`fleet-status` reports the wrong profile**, which is why this looked
      healthy for days: a reassuring `booted 6 / latest 6 / promoted 6` while
      comin had deployed something it cannot see.

Both scripts fail *safely* — they no-op rather than misfire — which is why
nothing broke. It is also exactly why nobody noticed.

### The fix

`boot-verdict.nix` has to learn about `system-profiles/comin` and the
`nixos-comin-generation-N.conf` entry naming, in `genHelpers`, `armScript`,
`verdictScript` (including the rollback target) and `fleetStatus`. The booted
system may come from *either* profile during the transition, so the helpers
must handle both. This is a rewrite of the most load-bearing file in the repo
and deserves its own change, its own rehearsal, and its own PR.

Interim options, both verified:

- `sudo bootctl set-default ""` unsets `LoaderEntryDefault` — bootctl(1): *"When
  an empty string ("") is specified as the ID, then the corresponding EFI
  variable will be unset."* `loader.conf` then governs, and NixOS keeps it
  pointing at the newest comin generation on every deploy. Self-maintaining,
  but gives up the gate-3 fallback entirely.
- `sudo systemctl reboot --boot-loader-entry=nixos-comin-generation-N.conf`
  boots a chosen entry **once**, leaving the EFI default as the fallback. This
  is gate 3's one-shot semantics done by hand, and is the safe way to test a
  comin generation on a machine nobody can power-cycle.

### Decision, 2026-09-01

Interim fix **applied**: `LoaderEntryDefault` unset, so `loader.conf` governs and
NixOS keeps it pointing at the newest comin generation. The proper
`boot-verdict.nix` rewrite is **deferred until after Immich lands**.

Know what that costs in the meantime: with the EFI default unset *and* gate 4
inert, a newest generation that fails to BOOT has no automatic fallback — the
watchdog reboots into the same entry. The 5-second boot menu is the only escape
and this machine is headless. Until boot-verdict understands the comin profile,
**the first boot of any materially new generation should happen while somebody
can see a console.**

### Knock-on: the drill

Tonight's physical unplug drill must boot a generation that actually contains
the mount. Booting the current EFI default would boot the Aug 31 generation,
which has no `/mnt/storage` at all — it would "pass" while testing nothing.

---

## 🔴 comin silently skips a diverged testing branch (confirmed 2026-09-01)

`internal/repository/repository.go` passes the **main** branch's commit id in
when resolving the testing branch, and `hasNotBeenHardReset()` in
`internal/repository/git.go` then requires it to be an ancestor of the testing
head:

```go
ok, err := isAncestor(r.Repository, *currentMainHash, *remoteMainHead)
if !ok {
    return fmt.Errorf("this branch has been hard reset: its head '%s' is not on top of '%s'", ...)
}
```

**Merging any PR into `main` creates exactly that divergence**, whichever merge
style is used, because `main` gains a commit the testing branch does not have.

The failure is logged at **debug level only** —
`logrus.Debugf("Failed to getHeadFromRemoteAndBranch: %s", err)` — so at the
default log level the symptom is comin doing *nothing at all*: no error, no
deployment, and `fleet-status` reporting perfect health. Same class as operating
rule 10 (an expired token means silent non-deployment).

Fix, now recorded in the `hosts/hong-kong/services.nix` runbook. After **every**
merge to main:

```
git fetch origin && git rebase origin/main && git push --force-with-lease
```

- [ ] Worth raising the comin log level, or adding a `fleet-status` line that
      shows the selected branch and commit, so this is visible rather than
      inferred. Right now nothing on the box tells you the testing branch was
      rejected.

---

## Where PHASE 5 actually stands

Immich, tsidp and the 7 TB array are written across `hosts/hong-kong/`:
`storage.nix`, `secrets.nix`, `identity.nix`, `immich.nix`, tied together by
`services.nix`, whose header is the stage-by-stage runbook. Only `storage.nix`
is imported by `hosts/hong-kong/default.nix` today.

### ⚠️ Live state you will forget

- [x] Stage 1 (the mount) is on `main` (`8c9279e`) and persistent.
- [ ] **Stage 2 (sops-nix + tsidp) is on `testing-hong-kong` (`80702fc`),
      applied with `test`.** comin does not touch the bootloader for the testing
      branch, so **a reboot drops back to stage 1** — no sops, no tsidp. That is
      the intended safety valve, not a bug, but do not mistake a working tsidp
      for a persistent one. It becomes real when the PR merges to `main`.
- [ ] **The stage 2 deploy has not been verified.** Everything checked before
      the rebase was still generation 2's config — see the divergence finding
      below. This is the first real evaluation of `flake.nix` with sops-nix,
      `secrets.nix` and `identity.nix`.

### Stage 1 — the disk

- [x] `nofail` mount of `/dev/disk/by-uuid/84010f4f-…` at `/mnt/storage`, ext4
      confirmed by `lsblk -f`, 7.3 T with 1.6 T of pre-existing data untouched.
- [x] `nofail` verified at the generator level: `RequiredBy=` empty,
      `WantedBy=local-fs.target`, `Before=umount.target` only. Inspected, not
      exercised — see the hypotheses list.
- [x] Runtime removal: `umount` while running left tailscale and sshd
      untouched; `systemctl start mnt-storage.mount` brought it straight back.
- [x] PR `testing-hong-kong` → `main`, green CI, merged as `8c9279e`.
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

- [x] Age keys generated: hong-kong's `age1a8np7j…` and an offline
      `age19grl7z…` at `~/Library/Application Support/sops/age/keys.txt`.
      **NOTE:** both slots in `.sops.yaml` initially held the host key; caught
      and fixed. Both distinct recipients are confirmed on
      `secrets/hong-kong.yaml`. Confirm the offline private key is in the
      password manager — that is the only copy off the fleet.
- [x] `.sops.yaml` recipients filled in. The shanghai rule stays a
      placeholder — no `secrets/shanghai.yaml` exists, so it is never evaluated.
- [x] `secrets/hong-kong.yaml` created with `tsidp-env`, encrypted to both
      recipients.
- [x] sops-nix input and module live in `flake.nix`; `flake.lock` regenerated
      **on hong-kong** (no nix on the MacBook) and committed — sops-nix pinned
      at `a8627b2`.
- [x] Tailscale auth key created and encrypted into `tsidp-env`.
      **Reusable and pre-approved: PROVEN 2026-09-01** — the state dir was
      moved aside and tsidp re-registered with no human interaction
      (`AuthLoop: state is Running; done`, 5s). A single-use or
      approval-required key could not have done that.
      **Tagged `tag:container`: PROVEN** — `tailscale status --json` reports
      `Tags=["tag:container"]`, `KeyExpiry` absent. Tagged matters: tagged
      devices do not expire, and a node key lapsing in 180 days on an
      unreachable box is a time bomb.
- [ ] **Non-ephemeral: still open, and being tested for free right now.** The
      stale `idp-1` node is offline. An *ephemeral* node is deleted by the
      coordination server shortly after it goes offline. If `idp-1` is still
      listed an hour after 12:07 on 2026-09-01, the key is non-ephemeral and
      this box can be reinstalled without the issuer URL moving. Delete it by
      hand afterwards — see the cleanup items below.
- [x] The `idp` node registers, carries the tag, and shows expiry disabled.
- [x] HTTPS certificates and MagicDNS are enabled on the tailnet — proven by
      `https://idp.shark-kitefin.ts.net/.well-known/openid-configuration`
      returning `"issuer": "https://idp.shark-kitefin.ts.net"` over a valid
      certificate.

#### THE NAME COLLISION LANDMINE — read before any tsidp state wipe

tsidp derives its OIDC **issuer** from the tsnet node's MagicDNS name, resolved
at startup, and logs it as `server_url=`. That name is assigned by the
coordination server **at registration**, and Tailscale does not reclaim a freed
name for an already-registered node.

So if a node called `idp` already exists when tsidp registers, the new node
silently becomes `idp-1` and the issuer silently becomes
`https://idp-1.shark-kitefin.ts.net`. That is exactly what happened on
2026-09-01: an older container held the name. Nothing errors. `systemctl status
tsidp` is green. You find out from one line in the journal, or not at all.

**Today this cost nothing, because no OIDC client existed yet.** After stage 3
it is expensive: `immich.nix` pins `issuerUrl`, and a mismatched issuer fails
OIDC discovery with an error that points at Immich rather than at the name.

The rule, therefore — **before wiping `/var/lib/private/tsidp` or reinstalling
this box, delete the old `idp` node from the admin console first**, and after
restarting confirm the issuer:

    journalctl -u tsidp | grep server_url
    # must read https://idp.shark-kitefin.ts.net — no -1, -2 suffix

There is no way to assert this from Nix: `settings.hostName` is only a
*request*, and the coordination server is free to answer with a suffix.

#### Cleanup left from the 2026-09-01 rename

- [ ] Delete the stale `idp-1` node (`100.81.145.40`) in the admin console —
      after it has served as the ephemerality test above.
- [ ] `sudo rm -rf /var/lib/private/tsidp.bak-idp-1` on hong-kong. It is the
      superseded state dir, kept only so the rename was reversible. It holds a
      dead node key and the old `idp-1` certificate; inert, but it is secret
      material with no remaining purpose.

### Stage 3 — the OIDC client — DONE 2026-09-01

- [x] Immich client created at `https://idp.shark-kitefin.ts.net`, client ID
      `127eb5a31f4804aee40b282d618052cd`, all three redirect URIs registered
      and read back from `GET /clients/`.
      **No browser needed.** tsidp's admin UI is server-rendered: `GET /new`
      is a plain form and `POST /new` with `name` + newline-separated
      `redirect_uris` creates the client, while `GET /clients/` returns JSON.
      Authorisation is by tailnet identity (WhoIs on the connection), so any
      admin device on the tailnet can drive it with `curl`. Worth knowing —
      it makes the IdP scriptable, and it means anything that can reach the
      node *as an admin* can create clients.
- [x] Secret → `immich-oauth-client-secret` in `secrets/hong-kong.yaml`, via
      `sops set … --value-stdin` so it never appeared in a process argument
      list. Round-trip verified against the value tsidp returned, and **both
      recipients confirmed still on the file** after re-encryption — that was
      the near-miss of earlier today, so it is checked every time now.
- [x] Client ID → `hosts/hong-kong/immich.nix`.

### 🟠 Rotate the tsidp auth key

- [ ] **`TS_AUTH_KEY` in `secrets/hong-kong.yaml` was printed in cleartext to
      a terminal on 2026-09-01** while masking the decrypted sops output; the
      mask pattern did not account for the value being a YAML block scalar.
      It did not leave the machine or reach the repo, but it is in a
      transcript and in scrollback.
      That key is reusable, non-expiring, pre-approved and tagged
      `tag:container` — and `tag:container` has `dst: ["*:*"]` in
      `tailscale/acl.hujson`, so it is effectively a permanent join-anything
      credential for the tailnet. Revoke it in the admin console, issue a
      replacement with the same four properties, and `sops set` it in.
      **TWO entries now hold this same key** and both must be updated:
      `tsidp-env` (env-file format, `TS_AUTH_KEY=…`) and `tailscale-authkey`
      (raw, for the immich node). Deliberately one key with two encodings —
      one credential to rotate, not two.
      **Cost of rotating is near zero**: `TS_AUTH_KEY` is only read when the
      tsnet state directory is empty, so the running `idp` and `immich` nodes
      are unaffected and do not re-register. Create the new key and deploy it
      BEFORE revoking the old one — if revocation ever did deregister a node,
      it would re-register into the name-collision trap and come back as
      `idp-1` / `immich-1`, taking the OIDC issuer and the Immich URL with it.

#### Verifying an auth key without touching `idp` or `immich`

Proven 2026-09-01 on the current key: it registered a third node with no human
interaction, tagged. That is **reusable** and **pre-approved** and **tagged**
demonstrated directly, without wiping any state dir that matters.

    ssh hong-kong.shark-kitefin.ts.net
    sudo mkdir -p /tmp/keytest
    sudo env STATE_DIRECTORY=/tmp/keytest \
      tailscaled --tun=userspace-networking --socket=/tmp/keytest/sock \
                 --statedir=/tmp/keytest --port=0 &
    sleep 3
    sudo tailscale --socket=/tmp/keytest/sock up \
      --auth-key=file:/run/secrets/tailscale-authkey \
      --hostname=keytest --accept-dns=false --accept-routes=false

**`STATE_DIRECTORY` is not optional, and `--statedir` does not cover it.**
tailscaled's logpolicy reads `$STATE_DIRECTORY` and otherwise falls back to the
hardcoded `/var/lib/tailscale` — the REAL daemon's directory — regardless of
`--statedir`, which only governs node state. The first run of this recipe
omitted it and logged `logpolicy: using system state directory
"/var/lib/tailscale"`. No harm done that time (`tailscaled.state` and
`tailscaled.log.conf` mtimes both confirmed unchanged; only the shared
`tailscaled.log*.txt` buffers were touched) but it is not a thing to repeat.

This is also why `frontdoor.nix` is safe: systemd's `StateDirectory=` exports
`$STATE_DIRECTORY`, and `tailscaled-immich` correctly logs
`logpolicy: using $STATE_DIRECTORY, "/var/lib/tailscale-immich"`. Verified.

Cleanup, and two traps in it:

    # NOT `pkill -f keytest` — the pattern matches your own ssh command line
    # and kills the session. Resolve PIDs first, then kill by number.
    ps -eo pid,args --no-headers | grep '[t]ailscaled' | grep tmp/keytest
    sudo kill <pid>
    sudo rm -rf /tmp/keytest

    # `tailscale logout` does NOT remove the node. Delete `keytest` in the
    # admin console by hand.

- [ ] Delete the leftover `keytest` node (`100.97.6.9`) in the admin console.
      While it sits there offline it doubles as the **ephemerality test**: an
      ephemeral node is deleted by the coordination server shortly after going
      offline, so if `keytest` is still listed an hour after 16:41 on
      2026-09-01, the key is non-ephemeral — the last of the four properties.

### Stage 4 — Immich — DEPLOYED 2026-09-01, running under `test`

Activated with `nixos-rebuild test --flake /tmp/pv#hong-kong` from a copy of
the working tree — the runbook's "no commit at all" path. **Not on any branch
and not in the bootloader**, so a reboot reverts it. See the persistence note
below.

- [x] Deploys and activates. `sops-install-secrets` decrypted
      `immich-oauth-client-secret` with the host key; `immich-media-setup`,
      `immich-server`, `postgresql`, `redis-immich` and `system-immich.slice`
      all started clean, and `boot-verdict` reported **0 failed units**
      immediately afterwards.
- [x] **The library is on the array, not the root disk.** `/mnt/storage` is
      device 2049, `/` is 66307 — different devices, which is the check the
      whole file exists to guarantee. Root went 5.7 G → 7.3 G (Postgres and
      store paths only), 207 G free.
- [x] All six mount markers seeded and verified by Immich itself:
      `"mountChecks":{"thumbs":true,"upload":true,"backups":true,
      "library":true,"profile":true,"encoded-video":true}`.
- [x] Memory caps live on the slice: `MemoryHigh=2G`, `MemoryMax=3G`,
      `MemorySwapMax=2G`, `CPUWeight=20`, `IOWeight=20`, with `immich-server`
      inside it at `OOMScoreAdjust=500`. Sitting at 1.36 G with 5.3 G
      available.
- [x] Front door works: `https://hong-kong.shark-kitefin.ts.net` returns 200,
      and `/api/server/features` reports `oauth: true`,
      `oauthAutoLaunch: false`, `passwordLogin: true` — the break-glass path
      is intact.
- [ ] **First sign-up — do this promptly.** Immich makes the FIRST user the
      admin, whichever way they sign in, and the tailnet's `acls` rule is
      wide open with `autoRegister = true`. Until you claim it, any member of
      the tailnet who reaches the page becomes the administrator.
      The URL is now `https://immich.shark-kitefin.ts.net`.
- [ ] Upload a photo and a video; confirm files land under
      `/mnt/storage/immich` and the log shows VAAPI, not software transcoding.
- [ ] Confirm OIDC login works, **and** that password login still works.
- [ ] Confirm the nightly `pg_dump` lands in `/mnt/storage/immich/backups`
      (cron `30 03 * * *`, keeps 14).

#### Immich moved to its own tailnet node — 2026-09-01

`https://immich.shark-kitefin.ts.net`, not `hong-kong.…` any more.

A name in the ts.net zone belongs to a node: MagicDNS has no CNAMEs and no
aliases, and `tailscale serve` always publishes on the serving node's own
name. `hong-kong` cannot be renamed — it is the machine, it is an exit node,
and its name is how you SSH to it. So a distinct name meant a distinct node.

`hosts/hong-kong/frontdoor.nix` runs a **second tailscaled** for it, using the
same nixpkgs `tailscale` package already on the box — no new flake input, and
notably no `tsnsrv`, which is not in nixpkgs. It is fenced off from the real
daemon by construction, and every one of these matters:

| flag | why |
|---|---|
| `--tun=userspace-networking` | no TUN, no `NET_ADMIN`, no routes; cannot touch the exit node |
| `--accept-dns=false` | **the important one.** tailscaled manages `/etc/resolv.conf`; 2026-08-31 was one daemon getting DNS wrong, and two would be worse |
| `--accept-routes=false` | subnet routes are the first daemon's business |
| `--port=0` | ephemeral WireGuard port; the default 41641 is taken |
| `--statedir` / `--socket` | own state under `/var/lib/tailscale-immich`, own LocalAPI socket; no path to the real daemon's state |

`OOMScoreAdjust` is +300 here against −900 on the real tailscaled, so under
memory pressure the kernel reaches for this one first by a wide margin.
Verified after deploy: real tailscaled still active, still advertising the
exit node, `/etc/resolv.conf` untouched.

- [x] Node registered as `immich` — **not `immich-1`**, checked first, per
      this morning's lesson. Tagged `tag:container`, valid Let's Encrypt cert
      (`CN = immich.shark-kitefin.ts.net`), and `/api/server/features` served
      over it.
- [x] tsidp client redirect URIs updated **in place** via
      `POST /edit/<client_id>`, so the client ID and secret did not change —
      no re-encryption of `immich-oauth-client-secret` needed.
- [x] `immich.nix`: `server.externalDomain` and `oauth.mobileRedirectUri`
      moved to the new host. These must match the name the browser actually
      used or OAuth bounces to the wrong origin.

**FOOTGUN, hit during this change:** removing the old `tailscale-serve-immich`
unit does **not** stop the old front door. `tailscale serve` config is
persisted by tailscaled itself, not by the unit — and both this file and
`frontdoor.nix` deliberately have no `ExecStop`, so a deploy never briefly
drops the door. Retiring a front door therefore needs one manual command:

    sudo tailscale serve --https=443 off

Done for `hong-kong`; confirmed `No serve config` there and the immich node
still serving. If a future front door moves again, remember this step or the
old URL keeps working and you will not notice.

#### Persistence: what a reboot costs right now

Verified on the box: `/run/booted-system` is `comin-1`, `/run/current-system`
is the test activation (in no profile at all), and `/boot/loader/loader.conf`
says `default nixos-comin-generation-2.conf`. So **a reboot today boots
comin-2, which is `main` — stage 1, the mount and nothing else.**

What that costs is a redeploy, not work. Everything durable survives: the git
tree, `secrets/hong-kong.yaml`, the registered `idp` node and its OIDC client
in `/var/lib/tsidp`, the Immich library on the array, and the Postgres cluster
on the SSD. The `tailscale serve` mapping also survives, because tailscaled
persists it — it will just 502 until Immich is back.

**Tonight's unplug drill will therefore wipe this activation. That is fine and
expected** — do the drill against stage 1 as planned, so it tests `nofail`
with one variable and not three.

- [ ] **Merging to `main` is the step that needs care, not this one.** That
      makes Immich the boot generation, and with gate 4 inert and
      `LoaderEntryDefault` unset there is no automatic fallback if it fails to
      BOOT. The standing rule applies: the first boot of a materially new
      generation happens with a console in reach. Tonight's drill is that
      window — do the drill first, then merge, then reboot once while you can
      still see the screen.

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
