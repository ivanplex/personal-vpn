# hosts/hong-kong/immich.nix — Immich, and everything that can write to the
# 7 TB array. The mount itself is in ./storage.nix, which is deployable and
# rehearsable on its own; this file is what makes the disk dangerous, so all
# the guards live here.
#
# ---------------------------------------------------------------------------
# THE RULE THIS FILE EXISTS TO ENFORCE
#
#   Immich must never write a photo library onto the 238 GB root SSD. Doing so
#   would silently fill the disk, which takes out the deploy loop AND the
#   ability to roll back — the worst state this fleet can reach.
#
# Five independent layers. Any one of them failing is survivable.
#
#   1. `nofail` on the mount, in ./storage.nix, so a dead disk cannot strand
#      the boot in the first place.
#
#   2. AssertPathIsMountPoint, NOT ConditionPathIsMountPoint. A failed
#      *Condition* marks the job SUCCESSFUL, and everything with Requires= on
#      it then proceeds — which would let Immich start with the disk absent. A
#      failed *Assert* fails the job and propagates. That difference is the
#      whole guarantee.
#
#   3. RequiresMountsFor= plus BindsTo=. RequiresMountsFor gives Requires= +
#      After= and usefully pulls the mount in. But systemd.unit(5) is explicit
#      that Requires= only propagates a stop when the other unit is
#      *explicitly* stopped; a filesystem unmounted out of band goes inactive
#      with no job at all. BindsTo= covers that case. Both are needed.
#
#   4. The memory caps at the bottom of this file, so Immich can never squeeze
#      tailscaled or sshd on a 7.6 GB box.
#
#   5. Immich's own folder check. It seeds a hidden `.immich` marker in each of
#      upload/ library/ thumbs/ encoded-video/ profile/ backups/ and refuses to
#      start if they existed before and are now missing.
#      https://immich.app/docs/administration/system-integrity
#      Never set IMMICH_IGNORE_MOUNT_CHECK_ERRORS.
#
#   And an eval-time layer on top: the assertion below refuses to build at all
#   if ./storage.nix is not also imported, so this file can never be deployed
#   on its own and quietly create the library on the root disk.
#
# No change is needed to gate 4 in modules/boot-verdict.nix. It counts failed
# units but never escalates on them ("A broken Immich must NOT reboot the
# box"), which is already correct. The one path by which Immich could still
# trip gate 4 is memory — see the slice caps at the bottom.
# ---------------------------------------------------------------------------

{ config, lib, pkgs, utils, ... }:

let
  # Strings, not Nix path literals. A bare absolute path outside the flake is
  # a store copy and breaks pure evaluation.
  #
  # mediaLocation is the single source of truth: mediaRoot is derived from it,
  # and the assertion below checks that ./storage.nix actually declares a
  # filesystem there. Change the path here and a mismatch becomes an eval
  # error, not a library quietly written to the wrong disk.
  mediaLocation = "/mnt/storage/immich";
  mediaRoot     = builtins.dirOf mediaLocation;   # "/mnt/storage"
  mediaParent   = builtins.dirOf mediaRoot;       # "/mnt"

  # "/mnt/storage" -> "mnt-storage.mount". Derived, not hand-written, so the
  # path and the unit name cannot drift apart.
  mountUnit = "${utils.escapeSystemdPath mediaRoot}.mount";

  # coreutils ONLY, and PATH set explicitly. `mountpoint` lives in util-linux —
  # exactly the class of mistake that produced the awk incident documented at
  # the top of modules/boot-verdict.nix. Comparing device numbers with stat(1)
  # answers the same question using nothing but coreutils.
  mediaSetup = pkgs.writeShellScript "immich-media-setup" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.coreutils ]}

    if [ ! -d ${mediaRoot} ]; then
      echo "immich-media-setup: ${mediaRoot} does not exist — the array is absent."
      exit 1
    fi

    # AssertPathIsMountPoint has already run. This is the second belt: it is
    # the only thing standing between 7 TB of photographs and a silent 238 GB
    # root filesystem, so it is worth asking twice.
    if [ "$(stat -c %d ${mediaRoot})" = "$(stat -c %d ${mediaParent})" ]; then
      echo "immich-media-setup: ${mediaRoot} is NOT a mount point; refusing to"
      echo "immich-media-setup: create a photo library on the root disk."
      exit 1
    fi

    # ext4 has no per-mount ownership, so this has to be established on the
    # disk itself, after it is mounted. install -d on an existing directory
    # just fixes the mode and owner, so this is idempotent.
    install -d -o immich -g immich -m 0700 ${mediaLocation}

    echo "immich-media-setup: ${mediaLocation} ready"
  '';
in
{
  # This file is useless and actively dangerous without ./storage.nix. Refuse
  # to build rather than let a partial import create the library on the root.
  assertions = [
    {
      assertion = builtins.hasAttr mediaRoot config.fileSystems;
      message = ''
        hosts/hong-kong/immich.nix expects a filesystem mounted at ${mediaRoot},
        but none is declared. Import ./storage.nix alongside this file, or
        Immich would create its library on the root disk.
      '';
    }
  ];

  # Declared here rather than in ./secrets.nix so that importing this file is
  # all it takes to bring the secret with it. It is consumed below through
  # settings.oauth.clientSecret._secret, which the module wires to
  # LoadCredential — read by PID 1 before immich-server drops privileges, so
  # the default 0400 root:root is correct.
  sops.secrets.immich-oauth-client-secret.restartUnits = [ "immich-server.service" ];

  # -------------------------------------------- the library directory -------
  systemd.services.immich-media-setup = {
    description = "Prepare the Immich library directory on the external disk";

    unitConfig = {
      # Requires= + After= on the mount unit (systemd.unit(5)), which also
      # PULLS THE MOUNT IN — local-fs.target only Wants= it under nofail.
      RequiresMountsFor = mediaRoot;
      # Assert, not Condition. See layer 2 in the header.
      AssertPathIsMountPoint = mediaRoot;
    };

    # Requires= does not propagate a stop from an out-of-band umount.
    bindsTo = [ mountUnit ];
    after = [ mountUnit ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = mediaSetup;
    };
  };

  # ------------------------------------------------------------- immich -----
  services.immich = {
    enable = true;

    mediaLocation = mediaLocation;

    # NOT "localhost". Node resolves that name and, since v17's verbatim:true
    # default, may bind ::1 only — in which case `tailscale serve` against
    # 127.0.0.1 gets ECONNREFUSED and you debug a 502 for an hour.
    host = "127.0.0.1";
    port = 2283;

    # Nothing but `tailscale serve` reaches this. See identity.nix.
    openFirewall = false;

    # OFF. Two cores and 7.6 GB of RAM, and this machine's first duty is to
    # stay reachable. See settings.machineLearning.enabled below — this option
    # only stops the systemd unit, it does not stop Immich queueing the jobs.
    machine-learning.enable = false;

    # HD Graphics 630 (Kaby Lake): H.264 and 8-bit HEVC encode via VAAPI.
    # A non-empty list flips PrivateDevices off, but sets DeviceAllow to
    # exactly this node — a NARROWER device policy than PrivateDevices gave
    # us, not a wider one.
    accelerationDevices = [ "/dev/dri/renderD128" ];

    settings = {
      # A non-null `settings` makes the module write IMMICH_CONFIG_FILE, which
      # makes Immich's admin System Settings page READ-ONLY. Every change from
      # here on is a commit. It also means this is a PARTIAL config: anything
      # not set below silently takes Immich's own default, not whatever is
      # currently in the database. Keep this block as small as you can live
      # with — an Immich upgrade that renames a key can stop startup.
      newVersionCheck.enabled = false;

      server = {
        externalDomain = "https://hong-kong.shark-kitefin.ts.net";
        publicUsers = false;
      };

      # BREAK GLASS. tsidp is version 0.0.12 and its own README opens with a
      # caution about breaking changes. OIDC-only on a machine you cannot
      # reach means a tsidp outage locks you out of your own photographs.
      # Turn this off later, from the tailnet, once tsidp has earned it.
      passwordLogin.enabled = true;

      # THE ONE THAT BITES. services.immich.machine-learning.enable = false
      # only suppresses the systemd unit; Immich's OWN default here is true.
      # Without this line Immich queues smart-search, face-detection and OCR
      # jobs against a http://localhost:3003 that nothing is listening on,
      # forever, on a two-core box.
      machineLearning.enabled = false;

      oauth = {
        enabled = true;
        issuerUrl = "https://idp.shark-kitefin.ts.net";

        # Created by hand in tsidp's admin UI — see the runbook in
        # hosts/hong-kong/services.nix. The ID is not a secret; the secret is.
        clientId = "REPLACE-ME-WITH-THE-TSIDP-CLIENT-ID";
        clientSecret._secret = config.sops.secrets.immich-oauth-client-secret.path;

        scope = "openid email profile";
        signingAlgorithm = "RS256";        # id_token_signed_response_alg
        profileSigningAlgorithm = "none";  # userinfo_signed_response_alg
        tokenEndpointAuthMethod = "client_secret_post";

        buttonText = "Sign in with Tailscale";
        # A broken IdP must not make the login page unusable.
        autoLaunch = false;
        # NOTE: combined with the tailnet's wide-open acls rule, this means
        # every member of shark-kitefin.ts.net can create themselves an Immich
        # account. On a personal tailnet that is the intent — but it is a
        # choice, and tsidp capability grants are NOT what gates it.
        autoRegister = true;
        storageLabelClaim = "preferred_username";

        # tsidp validates redirect URIs and may reject the app.immich:///
        # custom scheme. Immich already ships /api/oauth/mobile-redirect, which
        # forwards to it, so only https URIs need registering with the IdP.
        mobileOverrideEnabled = true;
        mobileRedirectUri =
          "https://hong-kong.shark-kitefin.ts.net/api/oauth/mobile-redirect";
      };

      ffmpeg = {
        # accelerationDevices above only OPENS the device. This is what makes
        # Immich actually use it.
        accel = "vaapi";
        accelDecode = true;
        preferredHwDevice = "/dev/dri/renderD128";
        targetVideoCodec = "h264"; # Kaby Lake cannot encode 10-bit HEVC
        threads = 2;
      };

      # Two cores. Immich's defaults (thumbnailGeneration 3, metadataExtraction
      # 5) will peg both of them, and gate 4's dig(1) times out at 5 seconds.
      job = {
        thumbnailGeneration.concurrency = 1;
        videoConversion.concurrency = 1;
        metadataExtraction.concurrency = 2;
        backgroundTask.concurrency = 2;
      };

      # Dumps land in <mediaLocation>/backups, so the array carries the library
      # AND the database snapshot that matches it. Postgres itself stays on the
      # internal SSD, where a dropped USB cable cannot corrupt it mid-write.
      backup.database = {
        enabled = true;
        cronExpression = "30 03 * * *";
        keepLastAmount = 14;
      };
    };
  };

  # /dev/dri/renderD128 is crw-rw---- root:render. accelerationDevices sets
  # DeviceAllow, which is a cgroup permission; the user still needs the group.
  # systemd.exec(5): SupplementaryGroups= "does not override, but extends the
  # list of supplementary groups configured in the system group database", so
  # this coexists with the module's own group for the redis socket. Both
  # survive PrivateUsers=true — upstream relies on exactly that for redis.
  users.users.immich.extraGroups = [ "video" "render" ];

  # ----------------------------------------- coupling immich to the disk ----
  systemd.services.immich-server = {
    unitConfig = {
      RequiresMountsFor = mediaRoot;

      # Five failures in ten minutes and it stays down. On a machine you cannot
      # reach, a unit that gives up and leaves evidence in the journal beats a
      # unit that flails forever. The defaults (5 in 10s) never trip against
      # the module's RestartSec=3.
      StartLimitIntervalSec = "10min";
      StartLimitBurst = 5;
    };

    bindsTo = [ mountUnit ];
    requires = [ "immich-media-setup.service" ];
    after = [ mountUnit "immich-media-setup.service" ];

    # If a global OOM happens anyway, the kernel should reach for Immich long
    # before it reaches for tailscaled.
    serviceConfig.OOMScoreAdjust = 500;
  };

  # ------------------------------------------------------------ memory ------
  # 7.6 GB total, and comin evaluates this flake ON the box (1.5-3 GB). The
  # rest: base OS ~1 GB, postgres ~0.5 GB, redis ~0.1 GB. That leaves about
  # 3 GB for Immich, so that is the cap.
  #
  # MemoryHigh brakes first (reclaim pressure, no kill). MemoryMax kills. An
  # in-cgroup OOM kill is bounded and confined — immich-server restarts, and
  # StartLimitBurst above stops it looping. That is strictly better than a
  # global OOM, where the kernel is free to pick tailscaled, gate 4 then sees
  # three failed checks, and a machine whose only fault was a large video
  # reboots itself in a loop. That is the ONE path by which Immich can trip
  # gate 4, and this is what closes it.
  #
  # Note postgres and redis are their own units in system.slice, NOT in here.
  # This caps immich-server and its ffmpeg children only.
  systemd.slices.system-immich.sliceConfig = {
    MemoryHigh = "2G";
    MemoryMax = "3G";
    MemorySwapMax = "2G"; # let it swap a little before it dies
    CPUWeight = 20;       # loses to everything else in system.slice
    IOWeight = 20;
  };
}
