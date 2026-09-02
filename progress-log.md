# Progress log

Newest entry first. What was actually done, what it cost, and what was learned —
the things that do not survive in a diff. `tech-debt.md` holds what is *left*;
this holds what *happened*.

---

## 2026-09-02 — Direct access, at last: the disk drill, and the gates stop being a hypothesis

The machine was physically reachable for the first time since it was deployed.
That is the scarce resource, so the day was spent on the things that **cannot**
be done over SSH, and the SSH-only backlog was deliberately left alone.

Two results, and both were overdue: **`nofail` at boot is proven**, and
**gates 3 and 4 work**.

### Step 0 first: prove the escape hatch before relying on it

`modules/base.nix` sets `editor = false`, so the boot menu offers a choice
between at most ten generations and nothing else — no cmdline editing, no
rescue shell. Worth knowing *before* the day you need it, along with whether
the display shows anything during the firmware's five seconds and whether the
keyboard registers before the kernel's USB driver exists. Both were fine.

### The unplug drill — `nofail` finally exercised

Run against stage 1, which is what `main` booted, so it tested one variable
rather than three.

| | result |
|---|---|
| unplug while running | `mnt-storage.mount` → `inactive (dead)` via a clean `Deactivated successfully`; tailscale, sshd, DNS all ok, 0 failed units |
| reboot with it absent | box came back; slowest unit was `dhcpcd` at 10 s and the mount was nowhere near the top of `systemd-analyze blame` |
| replug and reboot | mount returns |

The middle row is the one that matters. `nofail` was inspected at the generator
level a day earlier and written up as "inspected, not exercised". It is now
exercised.

**And the drill found the thing drills are for.** The array does **not**
remount itself when the enclosure comes back. With the disk absent the mount
job gives up after `x-systemd.device-timeout=30s` — `systemctl list-jobs` goes
empty — so when the device reappears there is nothing queued to notice.
Confirmed directly: `lsblk -f` showed the array back with the right UUID and an
empty `MOUNTPOINTS` until `systemctl start mnt-storage.mount` was run by hand.

That is the *realistic* failure. Nobody unplugs a 7 TB enclosure on purpose;
enclosures brown out for twenty seconds and return. And nothing pages anybody
when it happens — the filesystem series simply stops existing, which is silence
rather than an alarm.

### boot-verdict rewritten, and the gates ran end to end

The diagnosis was already in `tech-debt.md` from the day before: comin deploys
into `/nix/var/nix/profiles/system-profiles/comin`, every guard in this repo
read `/nix/var/nix/profiles/system`, so gate 3 never armed and gate 4 exited 0
with "cannot identify the running generation".

The rewrite makes a generation a **token** — `comin:3` or `system:6` — with
`_gen_link` and `_gen_entry` the only code that knows how one maps to a symlink
and a boot entry name. The part that took the actual thinking:

**Ordering is by time, not by number.** The two profiles have independent
counters, so `comin-3` and `system-6` say nothing about which came first, and
"the previous generation" — the rollback target — is only meaningful
chronologically. It is now the mtime of the profile symlink. `previous_generation`
also refuses any generation whose ESP entry has aged out under
`configurationLimit = 10`; rolling back to one of those would have been a
one-way trip, and the old code would happily have done it.

No nix on the MacBook, so the helpers were extracted from the Nix string,
unescaped, and run against a fake profile tree with a deliberately mixed
history — five generations across both profiles, interleaved in time, with one
comin entry missing from the ESP. Twelve assertions, including that the
rollback target skips the unbootable generation and crosses profiles correctly.
Cheap, and it caught the shape of the problem before the box did.

Then, on the machine, in order:

```
promoted comin:2                         gate 4, for the first time ever
one-shot nixos-comin-generation-3.conf   gate 3, arming, default held at comin-2
booted comin:3 / boots next comin:2      running the new one, still pointing home
healthy — promoting generation comin:3   T+10, and all three sources agree
```

That third line is the whole design in one row: **running generation 3, would
fall back to generation 2 if power-cycled.** A generation genuinely on trial.

The merge to `main` therefore happened *with* the safety net rather than
without it, which reverses the ordering the previous session had planned. It
also makes Immich, tsidp, Grafana and Prometheus persistent — before today they
were a `test` activation that evaporated on every reboot.

**The interim `bootctl set-default ""` workaround is superseded.** Gate 4 sets
`LoaderEntryDefault` on every promotion now.

### A status command that could not see, and did not say so

`fleet-status` kept printing `booted ?` after the fix, while the root-run
service was resolving `comin:2` perfectly. The cause: comin creates
`/nix/var/nix/profiles/system-profiles` as `d---------`, mode 0000, and the ESP
is mounted `umask=0077` by `disko.nix`. As a normal user the glob matched
nothing, so it reported `booted ?` and — worse — a confident
`latest system:6`, which is the newest *hand-run* generation and was not the
truth.

**This is the same failure as the original bug wearing different clothes: a
reassuring answer produced by a script that was not allowed to look.** The fix
is not to loosen the permissions — the ESP's `umask=0077` is deliberate — but
to say so:

```
!! CANNOT READ the comin profile directory and the ESP — run: sudo fleet-status
   the generations below are INCOMPLETE, not authoritative.
```

A tool that reports what it can see, without reporting what it *couldn't*, is
worse than no tool. That is twice in two days on this one file.

### Not done, and why

- **Gate 4's rollback path.** Still never fired, and it is the half that
  matters — a generation that boots, fails its checks, and gets thrown away.
  The recipe is in `tech-debt.md` and needs no broken commit: remove
  `/var/lib/boot-verdict/promoted`, stop `tailscaled`, wait 30 minutes.
  **Deferred: no monitor was plugged into the machine.** The drill deliberately
  breaks the only way in, so it needs a screen in the room, not merely a body
  in the building.
- Everything on the SSH-only list — Immich password login, promoting the OAuth
  account to admin, the nightly `pg_dump`, the `tailscaled-grafana` logpolicy
  check, the node_exporter flags. Deliberately untouched: none of them needed
  the access, and the access was the scarce thing.

### Next

1. **The rollback drill**, next time there is a screen. It is now the largest
   unproven thing in the repo.
2. **Make the array recover on its own** — a `.path` unit or a periodic
   `systemctl start mnt-storage.mount`, plus an alert for the filesystem series
   going absent. `x-systemd.automount` remains ruled out: it would make
   `AssertPathIsMountPoint` a no-op.
3. The SSH-only backlog, from anywhere.
4. The tailnet migration, which is the only item with somebody else's clock on
   it. See `tailnet-migration.md` on its branch.

---

## 2026-09-01 — Monitoring: Prometheus, Grafana, and 22 rules nobody has seen fire

Goal: architecture.md's step 10, finally. Prometheus and Grafana on hong-kong,
scraping the fleet over the tailnet, so that "hong-kong has been healthy for 24
hours" — the soak gate that governs when `stable` may fast-forward — becomes
something observed rather than asserted.

### Written

| file | what |
|---|---|
| `modules/observability-node.nix` | node_exporter, **on the flake spine** so shanghai arrives observable |
| `hosts/hong-kong/metrics.nix` | Prometheus: scrape config, retention, 22 alert rules |
| `hosts/hong-kong/dashboard.nix` | Grafana, OIDC via tsidp, provisioning |
| `hosts/hong-kong/grafana-frontdoor.nix` | Grafana's own tsnet node |
| `hosts/hong-kong/dashboards/*.json` | Fleet overview, Services, Deploys |

Stages 5-8 appended to the runbook in `services.nix`.

### Decided

- **The exporter goes on the spine, not on a host.** architecture.md:203 lists
  exporters as part of shanghai's duty, and a host that arrives already
  observable is one line of `fleet` away from being monitored. shanghai is
  deliberately *not* in that list yet: it has never been installed, and a
  permanently-down target is an alert that teaches you to ignore alerts.

- **node_exporter's systemd collector, not a second exporter process.**
  architecture.md:219 asks for a systemd exporter and is right about why —
  unit state is the container signal for a tenth of cAdvisor's memory — but it
  does not say it must be a separate binary, and this box has 7.6 GB and two
  cores. `node_systemd_unit_state` is the whole of "running, failed or
  flapping". Note its default `unit-exclude` hides mounts, so `/mnt/storage` is
  watched through the filesystem collector instead.

- **Prometheus binds loopback.** No front door for it at all. Grafana reaches
  it over 127.0.0.1; a human reaches it with
  `ssh -N -L 9090:127.0.0.1:9090`. One less thing on the tailnet.

- **Grafana gets its own tsnet node**, `grafana.shark-kitefin.ts.net`, rather
  than `tailscale serve` on hong-kong's own name — which is free now that
  Immich vacated 443, and was still the wrong answer. hong-kong is the machine
  and the SSH target; Immich was moved off exactly that arrangement a day
  earlier, and moving monitoring onto it would have to be undone the first
  time a second service wanted a name.

- **OIDC through tsidp, with the login form kept.** Same shape as Immich, and
  the circularity is sharper here: an IdP outage must not lock you out of the
  dashboard you would use to diagnose the IdP outage. `oidcClientId = null` is
  a *working* configuration, not a placeholder — Grafana comes up with the
  login form only and declares no OIDC secret at all, so the first deploy
  cannot depend on a secret tsidp has not issued yet.

- **Dashboards are files, not database rows.** `allowUiUpdates = false`, the
  same trade `services.immich.settings` makes for Immich's System Settings
  page. Editing workflow is in `hosts/hong-kong/dashboards/README.md`.

### The one thing that is genuinely awkward

**Grafana reads its own secrets.** Everything else in this repo hands a secret
to PID 1 — tsidp through `EnvironmentFile`, Immich through `LoadCredential` —
so `0400 root:root` is correct and the service never needs read access.
Grafana resolves `$__file{...}` itself, *after* dropping to the `grafana` user,
so all three of its secrets are declared `owner = "grafana"`. Wider than
anything else here, and the only shape that works.

One of those three is a fix rather than a feature: nixpkgs leaves
`settings.security.secret_key` at Grafana's own shipped default, the literal
`SW2YcwTIb9zpOOhoPsMm`, which signs the session cookie and is published in the
manual. With `acl.hujson` as wide open as it currently is, that is a session
any tailnet member could mint. It now comes from sops.

The consequence is an ordering rule, and it was followed rather than
documented-and-hoped: `grafana-admin-password` and `grafana-secret-key` went
into `secrets/hong-kong.yaml` **first**, and only then were the two imports
uncommented. sops-nix does not shrug at a declared-but-missing secret —
`sops-install-secrets` fails during *activation*, which is a failed deploy, and
comin neither rolls back nor retries a generation it has already failed.
Nothing enforces the ordering; it stays a runbook rule, because Nix cannot see
inside an encrypted file.

Both values were generated with `openssl rand -base64` and written with
`sops set`, so neither has been typed, displayed, or put in a shell history.
The admin password comes back out with
`sops -d --extract '["grafana-admin-password"]' secrets/hong-kong.yaml` —
worth doing once, into the password manager, because it is the way in on the
day tsidp is the broken thing.

### Verified, and not

**Verified:** the 22 rules parse as YAML and every expression is balanced; all
three dashboards are valid JSON, reference the pinned datasource uid
`fleet-prometheus`, and fit the 24-column grid. comin's metric names were read
off the pinned revision `ffeadf3` (`internal/prometheus/prometheus.go`) rather
than guessed — `comin_last_fetch_failed`, `comin_last_eval_failed`,
`comin_last_build_failed`, `comin_last_deployment_failed`,
`comin_deployment_info{commit_id,status}`, `comin_need_to_reboot`,
`comin_is_suspended`, `comin_fetch_count{remote_name,status}` — and its
exporter serves `/metrics` on every interface, with the firewall as the
perimeter.

**Not verified — this is the honest part.** Nothing here has run. No rule has
fired. The memory numbers are estimates stacked on top of the Immich estimates.
The two opt-in `--collector.systemd.*` flags are the one thing gate 1 cannot
check, because a flag rename is a runtime error rather than an evaluation one.
And `tailscaled-grafana`'s isolation from the real daemon is *claimed* on the
strength of the `logpolicy` check that proved it for `tailscaled-immich`, not
on the strength of running it. All of it is in `tech-debt.md`.

### Next

1. **Merge and deploy stages 5 and 6** — the exporter and Prometheus. Neither
   declares a secret, neither opens a port off the tailnet, and Prometheus
   binds loopback, so this is the cheapest stage in phase 5. Check
   `prometheus-node-exporter` came up at all; that is where the flag risk is.
2. **Leave it a day**, then look at TSDB growth (`du -sh /var/lib/prometheus2`)
   and at whether anything flaps. Any rule FIRING on its first evaluation is a
   wrong rule, not a broken machine — fix it before it trains you to ignore
   the page.
3. **Then stage 7(c), OIDC** — its own deploy, after Grafana is known good on
   the password login. Register the client with tsidp against the single
   redirect URI `https://grafana.shark-kitefin.ts.net/login/generic_oauth`,
   put the secret in sops, replace the `null` in `oidcClientId`. Then test the
   password login *again*: that is the whole point of keeping it.
4. **Then alert delivery**, which is the part that makes any of this matter at
   3 a.m.: Alertmanager, and the external heartbeat from *both* nodes.
   Prometheus on hong-kong cannot tell you hong-kong is dead.

Everything from the previous session's list still stands ahead of this on
`boot-verdict.nix`, which remains the largest known risk.

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

### A credential was exposed — and has since been rotated

While masking the decrypted sops output to check both keys had survived
re-encryption, the mask pattern did not account for `tsidp-env` being a YAML
block scalar, and **the Tailscale auth key was printed in full**. It did not
leave the machine or reach the repo, but it is in a transcript and in terminal
scrollback.

That key is reusable, non-expiring, pre-approved and tagged `tag:container` —
and `tag:container` carries `dst: ["*:*"]` in `acl.hujson`, so it is a
permanent join-anything credential for the tailnet.

**Rotated the same evening.** Verified by hashing the bare key value in all
three places it lives — `sops -d` on the repo file, `/run/secrets/tailscale-authkey`,
and the value inside `/run/secrets/tsidp-env` — and getting `61f5402c` from
each. Both age recipients survived the re-encryption; that check is a habit now.

tsidp then confirmed the design prediction word for word on restart:

```
Authkey is set; but state is NoState. Ignoring authkey.
```

which is exactly why rotation was free — the key is consulted only when the
tsnet state directory is empty, so neither running node re-registered and the
issuer never moved. Revocation of the old key is the one part nothing on the
box can confirm; it only exists in the admin console.

The lesson worth keeping: **do not mask secrets with a regex.** Print the key
names and the value lengths, or nothing at all. The mask that failed here was
written specifically to protect this value, and it is what leaked it.

### Verifying the key, and two ways to shoot yourself doing it

The new key's properties can only be proven by a registration, and wiping
`idp` or `immich` state trips the name-collision trap. So: register a
throwaway. It worked — `keytest` came up `tagged-devices` with no human
interaction, which demonstrates **reusable**, **pre-approved** and **tagged**
in one go, on a node nothing depends on.

Two things went wrong doing it, both now in `tech-debt.md`:

**1. `--statedir` does not cover logpolicy.** tailscaled reads
`$STATE_DIRECTORY` for its log configuration and otherwise falls back to a
hardcoded `/var/lib/tailscale` — the *real* daemon's directory — no matter what
`--statedir` says. Run by hand, the throwaway logged
`logpolicy: using system state directory "/var/lib/tailscale"`. No harm that
time (`tailscaled.state` and `tailscaled.log.conf` mtimes both confirmed
unchanged; only the shared `tailscaled.log*.txt` buffers were touched), but the
recipe now sets `STATE_DIRECTORY` explicitly.

This is also, incidentally, the proof that `frontdoor.nix` is safe: systemd's
`StateDirectory=` exports `$STATE_DIRECTORY`, and `tailscaled-immich` logs
`logpolicy: using $STATE_DIRECTORY, "/var/lib/tailscale-immich"`. The isolation
claimed in that file's header is real, and now checked rather than assumed.

**2. `pkill -f keytest` killed the ssh session.** The pattern matched the
command line carrying it. Resolve PIDs first, kill by number.

Also worth knowing: `tailscale logout` does **not** remove a node. It has to be
deleted in the admin console.

### Immich, exercised with real media

Two videos (299 MB) and one photo (1150 kB), uploaded and viewed from the phone
app over Tailscale.

- **VAAPI works.** `Transcoding video … with VAAPI-accelerated encoding and
  decoding` for both videos — the Kaby Lake iGPU is doing the work, not the
  two CPU cores.
- Everything landed on the array: `upload/` 301 M, `encoded-video/` 89 M,
  `thumbs/` 1.1 M, and the root disk did not move. Originals stay in `upload/`
  rather than `library/`; that is normal, the storage template is off by
  default.
- **OIDC login works** — an account was auto-registered from a Tailscale
  identity.

**And a finding that will not stay cheap.** There are two accounts, created
three seconds apart:

| email | admin | password | assets |
|---|---|---|---|
| `hello@ivanchan.me` | yes | SET | 0 |
| `hello@whiteboxsoftware.hk` | **no** | NONE | **3** |

The admin signup form made the first; "Sign in with Tailscale" made the second.
**Immich links OAuth to an existing account by matching email, and nothing
else.** The tailnet identity is `@whiteboxsoftware.hk`, the admin account is
`@ivanchan.me`, so instead of linking it created a second, non-admin account —
which is the one the phone uses and the one that owns every asset.

Fix it at 3 assets rather than 30,000: sign in with the password as
`ivanchan.me` and promote the OAuth account. The `extraClaims immich_role`
trick in `identity.nix` cannot help retroactively — Immich reads that claim
only at user creation.

### State at end of session

- `main` = `8c9279e` — stage 1, the mount and nothing else. **This is still
  what the box boots into.**
- `testing-hong-kong` = `0a8b4ac`, pushed. Stages 2, 3 and 4 all live on it:
  sops-nix, tsidp, Immich's own tsnet node, and Immich. comin deployed it at
  17:09 with `test`.
- **Running on the box**: that commit, via comin. Immich reachable at
  `https://immich.shark-kitefin.ts.net`, tsidp at
  `https://idp.shark-kitefin.ts.net`, six services up, zero failed units.
- **NOT PERSISTENT.** comin does not touch the bootloader for the testing
  branch, and `/boot/loader/loader.conf` still reads
  `default nixos-comin-generation-2.conf` — the last `main` deploy. A reboot
  drops the whole lot back to stage 1. The data survives regardless: originals
  on the array, Postgres on the SSD, the `idp` and `immich` node registrations
  in their state dirs.
- **Uncommitted**: corrections to `tech-debt.md` and this file, ticking off the
  housekeeping and recording the findings above. Held deliberately until after
  the drill so the drill is run against a clean tree.

### Next

Do these in order. The first two are the same evening's work.

1. **The physical unplug drill, against stage 1.** It is what `main` boots, so
   it tests `nofail` with one variable rather than three. Console in reach —
   gate 4 cannot catch a boot failure yet. Unplug the enclosure, reboot,
   confirm the box returns with tailscale Running and `systemd-analyze blame |
   head` showing no stall, then replug and reboot.

   Expect this to wipe the `test` activation. That is correct, not a fault.

2. **Then make Immich persistent.** Commit the doc corrections, merge
   `testing-hong-kong` to `main`, let comin deploy with `switch`, and reboot
   once **while you can still see the screen** — the first boot of a materially
   new generation. Afterwards, remember the comin gotcha:

       git fetch origin && git rebase origin/main && git push --force-with-lease

3. **Promote the OAuth account to admin** — see the two-accounts finding above.
   Cheapest now.

4. **Exercise password login end to end.** `ivanchan.me` is currently the only
   break-glass identity; the OAuth account has no password.

5. **Check the nightly `pg_dump`** landed in `/mnt/storage/immich/backups`
   after the first 03:30 that follows a persistent deploy.

6. **Prove the new auth key's four properties** with the keytest recipe in
   `tech-debt.md` — and note the key expires around **30 November 2026**, which
   silently ends the unattended-reinstall property.

7. **Then `boot-verdict.nix`.** Still the largest known risk: gates 3 and 4 do
   not work with comin's profile, which is the reason every step above needs a
   console. It deserves its own change, its own rehearsal and its own PR.

Behind all of it sits the rehearsal list in `tech-debt.md` — `nofail` at boot,
`AssertPathIsMountPoint`, `BindsTo` on an out-of-band umount, the memory caps,
the `.immich` marker check, sops decryption failure. Every one is still a
hypothesis, which by this repo's own standard means it is not yet a feature.
