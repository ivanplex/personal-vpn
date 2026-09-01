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
#   identity.nix  tsidp (OIDC) and the tailscale serve front door
#   immich.nix    the library directory, Immich, and the memory caps
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
#       https://hong-kong.shark-kitefin.ts.net/auth/login
#       https://hong-kong.shark-kitefin.ts.net/user-settings
#       https://hong-kong.shark-kitefin.ts.net/api/oauth/mobile-redirect
#
#   The secret is shown ONCE. Put it in secrets/hong-kong.yaml as
#   `immich-oauth-client-secret`, and paste the client ID into immich.nix.
#
# -- 4. Immich --------------------------------------------------------------
#
#   imports = [ ./storage.nix ./secrets.nix ./identity.nix ./immich.nix ];
#
#       systemctl status immich-server postgresql tailscale-serve-immich
#       journalctl -u immich-server | grep -i "mount folder checks"
#
#   Browse https://hong-kong.shark-kitefin.ts.net. Immich makes the FIRST user
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
# ===========================================================================

{ ... }:

{
  imports = [
    ./storage.nix
    ./secrets.nix
    ./identity.nix
    ./immich.nix
  ];
}
