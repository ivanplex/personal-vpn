# hosts/hong-kong/services.nix — PHASE 5 workloads.
#
# THE RULE THAT GOVERNS EVERYTHING IN THIS DIRECTORY: nothing added by these
# files may be able to stop this machine booting, or stop tailscaled coming up.
# Every dependency points from a workload towards the disk, never the other way
# round. Gate 4 in modules/boot-verdict.nix still checks only tailscaled, sshd
# and DNS, and a broken Immich must NOT reboot the box.
#
#   storage.nix   the 7 TB array, and only that. No users, no services, no
#                 secrets — so it deploys and is rehearsed entirely on its own.
#   secrets.nix   sops-nix setup, scoped to this host
#   identity.nix  tsidp (OIDC), on its own tsnet node
#   frontdoor.nix Immich's own tsnet node, so it answers to
#                 immich.shark-kitefin.ts.net. Revert this one import and
#                 Immich is simply unreachable — nothing else changes.
#   immich.nix    the library directory, Immich, and the memory caps
#
#   metrics.nix   Prometheus: what is scraped, how long it is kept, and the
#                 alert rules. No secrets, no UI, loopback only — so it is
#                 deployable and verifiable entirely on its own.
#   dashboard.nix Grafana: the OIDC client, the provisioned datasource and the
#                 dashboards under ./dashboards/.
#   grafana-frontdoor.nix  Grafana's own tsnet node, so it answers to
#                 grafana.shark-kitefin.ts.net. Revert this one import and the
#                 dashboard is unreachable — nothing else changes.
#
# The exporter every host runs is NOT here. It is on the flake spine, in
# modules/observability-node.nix, because shanghai needs it too and it has
# nothing host-specific in it.
#
# Each secret is declared in the file that consumes it, so STAGING IS DONE BY
# COMMENTING OUT IMPORT LINES BELOW — never by commenting out blocks inside a
# file. Half a file does not evaluate: comment out the services.immich block
# and users.users.immich.extraGroups is left orphaned, which trips the
# "Exactly one of isSystemUser and isNormalUser must be set" assertion in
# nixpkgs (nixos/modules/config/users-groups.nix). immich.nix also asserts at
# eval time that storage.nix is imported alongside it.
#
# ===========================================================================
# BOOTSTRAP RUNBOOK
#
# THE ORDERING QUESTION THIS ANSWERS: Immich's config needs a client ID and a
# client secret that only tsidp can issue, and tsidp only issues them once it
# is running. That is not circular, because tsidp needs NOTHING from Immich.
# Its whole Nix config is hostname + port + auth key; OIDC clients are RUNTIME
# state that tsidp generates and stores in /var/lib/tsidp, not something Nix
# declares. So the dependency runs one way: deploy tsidp (stage 2), let it hand
# you an ID and a secret (stage 3), then deploy Immich (stage 4).
#
# And none of this has to touch `main`. Two cheaper ways to try a stage:
#
#   * Push to `testing-hong-kong`. comin watches it and applies with `test`,
#     which never touches the bootloader — a reboot returns you to whatever
#     `main` last gave you. This is the intended safety valve (operating rule 3).
#
#     GOTCHA, learned 2026-09-01: comin SILENTLY SKIPS the testing branch unless
#     the main branch commit is an ANCESTOR of it. See hasNotBeenHardReset() in
#     comin's internal/repository/git.go — it is called for the testing branch
#     with main's commit id, so a diverged testing branch fails with "this
#     branch has been hard reset" and is logged only at debug level. Merging a
#     PR to `main` always causes this divergence, whichever merge style you use.
#     So after EVERY merge to main:
#
#         git fetch origin && git rebase origin/main && git push --force-with-lease
#
#     The symptom is comin doing nothing at all while `fleet-status` looks fine.
#
#   * No commit at all: on the box, in tmux (operating rule 5), from a checkout
#         git add -A && nixos-rebuild test --flake .#hong-kong
#     `git add` is enough — Nix only sees what git tracks, but it reads the
#     INDEX, so staged-but-uncommitted files are visible (operating rule 6).
#
# Use one of those for every stage below and fast-forward `main` only once the
# stage has proven itself. Nothing here touches shanghai, so `stable` never
# needs to move.
#
# -- 0. Prerequisites, by hand ----------------------------------------------
#
#   Admin console: enable MagicDNS and HTTPS Certificates. Both tsidp and
#   `tailscale serve` need them.
#
#   Identify the array — do not guess, and do not format anything, it already
#   has data on it:
#       lsblk -f /dev/sda
#       sudo blkid -s UUID -o value /dev/sda1
#   The UUID goes in storage.nix. CONFIRM THE FSTYPE TOO: if it is NTFS or
#   exFAT rather than ext4/xfs/btrfs, stop — Unix ownership does not exist
#   there and the design needs uid=/gid= mount options instead.
#
#       sudo tune2fs -c 0 -i 0 /dev/sda1
#   so only journal recovery can trigger a check. See the fsck note in
#   storage.nix. This does not touch data.
#
# -- 1. The disk, on its own ------------------------------------------------
#
#   imports = [ ./storage.nix ];
#
#   No secrets, no new flake inputs, nothing that can write to it yet.
#       findmnt /mnt/storage
#       systemctl status mnt-storage.mount
#
#   THEN REHEARSE THE FAILURE. architecture.md:116 — a rescue mechanism you
#   have never triggered is a hypothesis, not a feature. This is the acceptance
#   test for the whole directory, and it is cheapest to run right now, while
#   nothing depends on the disk:
#
#     a) Unplug the array while running. `fleet-status` still shows tailscale,
#        sshd and DNS ok.
#     b) Reboot with it still unplugged, monitor unplugged (operating rule 4).
#        The box comes back, gate 4 promotes at T+10 min, and
#        `systemd-analyze blame | head` shows the boot did not stall.
#     c) Replug and reboot.
#
# -- 2. sops and tsidp ------------------------------------------------------
#
#   imports = [ ./storage.nix ./secrets.nix ./identity.nix ];
#
#   First: uncomment the sops-nix input and module in flake.nix, run
#   `nix flake lock`, and COMMIT flake.lock (operating rule 1). Create the age
#   keys and secrets/hong-kong.yaml with just `tsidp-env` — see secrets.nix.
#
#   The auth key for it: admin console -> Settings -> Keys -> Generate.
#   Reusable YES, Ephemeral NO, Pre-approved YES, Tags tag:container.
#   Tagged matters — tagged devices do not expire.
#
#       systemctl status tsidp && journalctl -u tsidp -n 50
#   Confirm the `idp` node appears in the console, tagged, expiry disabled.
#
# -- 3. Create the OIDC client, in a browser --------------------------------
#
#   Browse https://idp.shark-kitefin.ts.net — the first TLS handshake can take
#   a few minutes while the certificate issues. You reach the admin UI because
#   tailscale/acl.hujson already grants autogroup:admin the tsidp capability on
#   tag:container. Create a client with redirect URIs:
#
#       https://immich.shark-kitefin.ts.net/auth/login
#       https://immich.shark-kitefin.ts.net/user-settings
#       https://immich.shark-kitefin.ts.net/api/oauth/mobile-redirect
#
#   NOT hong-kong.* — Immich has its own tsnet node since 2026-09-01. See
#   ./frontdoor.nix. The UI is server-rendered, so this is scriptable:
#       curl -s https://idp.shark-kitefin.ts.net/clients/          # list
#       curl -s -X POST https://idp.shark-kitefin.ts.net/new \
#            --data-urlencode 'name=Immich' \
#            --data-urlencode $'redirect_uris=URI1\nURI2\nURI3'
#       curl -s -X POST https://idp.shark-kitefin.ts.net/edit/<client_id> ...
#   Authorisation is by tailnet identity, so run it from an admin device.
#
#   The secret is shown ONCE. Put it in secrets/hong-kong.yaml as
#   `immich-oauth-client-secret`, and paste the client ID into immich.nix.
#
# -- 4. Immich --------------------------------------------------------------
#
#   imports = [ ./storage.nix ./secrets.nix ./identity.nix
#              ./frontdoor.nix ./immich.nix ];
#
#       systemctl status immich-server postgresql \
#                        tailscaled-immich immich-front-door
#       journalctl -u immich-server | grep -i "mount folder checks"
#
#   Browse https://immich.shark-kitefin.ts.net. Immich makes the FIRST user
#   the admin, whichever way they sign in. Upload a photo and a video; confirm
#   the files land under /mnt/storage/immich and that the log shows VAAPI
#   rather than software transcoding.
#
#   Then test the OIDC button, and test that PASSWORD LOGIN STILL WORKS — that
#   is the entire point of keeping it (see passwordLogin in immich.nix).
#
#   If you would rather isolate an OIDC failure from an Immich failure, set
#   oauth.enabled = false for this deploy and flip it in a second one. That is
#   a one-word edit, not a commented-out block.
#
# -- 5. The exporters, on their own -----------------------------------------
#
#   Nothing to import here: modules/observability-node.nix is on the flake
#   spine, so this stage arrives with any deploy after it lands. It is the
#   cheapest stage in the file — one extra process, no secret, no mount, no
#   port reachable from off the tailnet.
#
#       systemctl status prometheus-node-exporter
#       curl -s localhost:9100/metrics | grep -c '^node_'
#       curl -s localhost:9100/metrics | grep -c '^node_systemd_unit_state'
#
#   THE ONE THING THAT CAN FAIL HERE is the pair of opt-in systemd sub-flags,
#   which gate 1 cannot check because a flag rename is a runtime error. If the
#   unit is dead, look for "unknown long flag" in the journal and delete the
#   two lines under IF ... FAILS TO START in modules/observability-node.nix.
#   Confirm what the binary actually accepts:
#
#       prometheus-node-exporter --help 2>&1 | grep collector.systemd
#
#   Also confirm the reach, from the MacBook, because this is the property
#   shanghai will depend on and the firewall is the only thing enforcing it:
#
#       curl -s http://hong-kong.shark-kitefin.ts.net:9100/metrics | head -1
#
# -- 6. Prometheus ----------------------------------------------------------
#
#   imports = [ ... ./metrics.nix ];
#
#   No secret, no UI, no new tailnet node. It binds 127.0.0.1 deliberately, so
#   the only way to look at it is a tunnel from the MacBook:
#
#       ssh -N -L 9090:127.0.0.1:9090 ivan@hong-kong.shark-kitefin.ts.net
#
#   Then, at http://127.0.0.1:9090:
#       /targets   every job UP. `node`, `comin` and `prometheus` at this stage.
#       /rules     22 rules, all in state "ok" — a rule that cannot parse shows
#                  as an error here, though promtool should have failed the
#                  build in CI long before.
#       /alerts    inactive is the correct state. Any rule that is FIRING on
#                  the first evaluation is a rule that is wrong, not a machine
#                  that is broken; fix it before it teaches you to ignore it.
#
#   Then leave it alone for a day. Two things are only visible with time
#   behind them: whether the TSDB grows the way metrics.nix predicts
#   (du -sh /var/lib/prometheus2, expect tens of MB a day), and whether
#   anything flaps.
#
# -- 7. Grafana -------------------------------------------------------------
#
#   IN THIS ORDER. Step (a) is the one that must not be skipped.
#
#   a) DONE 2026-09-01 — two secrets into sops, BEFORE anything was pushed.
#      Both were generated with `openssl rand -base64` and set with `sops set`,
#      so neither has ever been typed, displayed or written to a shell history:
#
#          sops set secrets/hong-kong.yaml '["grafana-admin-password"]' "\"$PW\""
#          sops set secrets/hong-kong.yaml '["grafana-secret-key"]'     "\"$SK\""
#
#      Read the admin password back the first time you need it, and put it in
#      the password manager then:
#
#          sops -d --extract '["grafana-admin-password"]' secrets/hong-kong.yaml
#
#      It is BREAK GLASS — the way into the dashboard on the day tsidp is the
#      thing that is broken. The SECRET KEY is not a login: it signs Grafana's
#      session cookie, and nixpkgs otherwise leaves it at Grafana's shipped
#      default, which is published in the manual. See settings.security in
#      ./dashboard.nix.
#
#      IF YOU EVER RE-KEY THIS FILE, both keys must survive the operation, or
#      the two imports below have to be commented out FIRST. A declared secret
#      that is missing from the file fails sops-install-secrets during
#      ACTIVATION, and comin neither rolls back nor retries that generation.
#
#   b) Uncomment ./dashboard.nix and ./grafana-frontdoor.nix above — DONE —
#      and deploy.
#      OIDC is off at this point by design: oidcClientId in dashboard.nix is
#      null, so Grafana comes up with the login form only and declares no
#      OIDC secret at all. One thing at a time.
#
#          systemctl status grafana tailscaled-grafana grafana-front-door
#          journalctl -u tailscaled-grafana | grep logpolicy
#            # must say /var/lib/tailscale-grafana, NOT /var/lib/tailscale
#
#      Confirm the node appears in the admin console as `grafana`, TAGGED
#      tag:container, expiry disabled. If it came up as `grafana-1` stop and
#      read the name-collision warning in ./grafana-frontdoor.nix — every URL
#      below is then wrong.
#
#      Browse https://grafana.shark-kitefin.ts.net. The first TLS handshake on
#      a new name can take a few minutes while the certificate issues. Sign in
#      as `ivan` with the password from (a), and check:
#        * Explore -> datasource Prometheus -> query `up` -> Run query. One
#          row per scrape target, value 1 or 0. This is the check, NOT
#          "Save & test" on the data source page: the data source is
#          provisioned with editable = false, so that button is not available.
#        * All three dashboards are present and drawing: Fleet overview,
#          Services, Deploys.
#        * Alerting -> Alert rules lists the Prometheus rules read-only. If it
#          does not — this is a Grafana-version-dependent view and is NOT
#          load-bearing — the authority is Prometheus's own /alerts page
#          through the tunnel from stage 6.
#
#   c) Then, and only then, OIDC. DONE 2026-09-01 — client
#      9876778ac89351d17411795b17fbd444, ONE redirect URI:
#
#          https://grafana.shark-kitefin.ts.net/login/generic_oauth
#
#          curl -s -X POST https://idp.shark-kitefin.ts.net/new \
#               --data-urlencode 'name=Grafana' \
#               --data-urlencode 'redirect_uris=https://grafana.shark-kitefin.ts.net/login/generic_oauth'
#
#      TWO THINGS THE IMMICH RUNBOOK DOES NOT WARN YOU ABOUT, both learned
#      doing this:
#
#      * tsidp's admin endpoints answer HTML, not JSON. Only /clients/ returns
#        JSON. POST /new CREATES THE CLIENT and hands you the one-time secret
#        inside the response body — so if you discard that body, the client
#        exists and the secret is gone.
#      * Recovering from that does NOT require deleting the client. The edit
#        page has a regenerate action, and it is a plain form POST:
#
#          curl -s -X POST https://idp.shark-kitefin.ts.net/edit/<client_id> \
#               --data-urlencode 'action=regenerate_secret' \
#               --data-urlencode 'name=Grafana' \
#               --data-urlencode 'redirect_uris=<the same URI>'
#
#        Send `name` and `redirect_uris` along with it — the handler takes the
#        whole form. The new secret comes back in an <input id="client-secret">,
#        64 chars, and the OLD ONE STOPS WORKING IMMEDIATELY. Harmless if
#        nothing is using it yet; not harmless once Grafana is authenticating
#        against it.
#
#      Put the secret in secrets/hong-kong.yaml as
#      `grafana-oauth-client-secret`, paste the client ID into oidcClientId in
#      ./dashboard.nix — replacing the null, quotes included — and deploy. Both
#      the secret declaration and the whole auth.generic_oauth block are keyed
#      off that one value, so this single edit turns the feature on.
#
#      TEST THE PASSWORD LOGIN AGAIN afterwards. That is the entire point of
#      keeping it, and it is the check that was worth making for Immich.
#
#      Then read Administration -> Users. If your tailnet identity landed as
#      Viewer rather than Admin, adminEmailDomain in dashboard.nix does not
#      match the email claim tsidp actually issues — the same mismatch that
#      quietly produced two Immich accounts on 2026-09-01. Fix the domain, do
#      not fix the account.
#
# -- 8. What is deliberately still missing ----------------------------------
#
#   Alert DELIVERY. Every rule in ./metrics.nix evaluates, and every one of
#   them surfaces in a web page nobody is looking at. architecture.md:221 is
#   blunt about why that is not enough: Prometheus on hong-kong cannot alert
#   you that hong-kong is down, and with two nodes there is no third machine
#   to notice. Two separate pieces, and they are a separate change:
#
#     * Alertmanager, with a route to somewhere that reaches a phone.
#     * An EXTERNAL dead-man's switch — a five-minute heartbeat from BOTH
#       nodes to healthchecks.io or similar, so a missed ping reaches you even
#       when the whole fleet is dark. The sketch is already in
#       modules/phase3.nix, under "external witness".
#
#   Until those exist, "hong-kong has been healthy for 24 hours" — the soak
#   gate that governs when `stable` may fast-forward — is still something you
#   assert by looking, not something that is watched.
# ===========================================================================

{ ... }:

{
  imports = [
    ./storage.nix
    ./secrets.nix
    ./identity.nix
    ./frontdoor.nix
    ./immich.nix

    # ---- PHASE 5, stages 5-8: monitoring --------------------------------
    # Prometheus first, on its own. It declares no secrets and binds nothing
    # but loopback, so it cannot fail an activation and cannot be reached
    # from off the box. Stage 6.
    ./metrics.nix

    # Grafana. The prerequisite these two waited on is DONE: both
    # grafana-admin-password and grafana-secret-key were added to
    # secrets/hong-kong.yaml on 2026-09-01, before this line was uncommented,
    # and in that order — sops-nix does not shrug at a declared secret that is
    # absent from the file, sops-install-secrets fails during ACTIVATION, and
    # comin at the pinned revision neither rolls back nor retries a generation
    # it has already failed.
    #
    # If you ever re-key or regenerate secrets/hong-kong.yaml, THAT ORDER IS
    # STILL THE RULE. Comment these two lines back out before removing either
    # key, not after.
    #
    # OIDC is still off: oidcClientId in ./dashboard.nix is null, so Grafana
    # comes up with the login form only and declares no OIDC secret at all.
    # Stage 7(c) turns it on, as its own deploy.
    ./dashboard.nix
    ./grafana-frontdoor.nix
  ];
}
