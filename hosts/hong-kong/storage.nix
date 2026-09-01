# hosts/hong-kong/storage.nix — the 7 TB external array, and only that.
#
# Deliberately separate from immich.nix so it can be deployed, rehearsed and
# reverted entirely on its own. A fileSystems entry needs no users, no service
# and no secrets, so this file is the one piece of PHASE 5 that can go out
# first and prove itself before anything depends on it. See stage 1 of the
# runbook in ./services.nix.
#
# ---------------------------------------------------------------------------
# THE RULE THIS FILE EXISTS TO ENFORCE
#
#   An enclosure that drops off — and it will — must degrade Immich and
#   nothing else. It must not hold up the boot and it must not stop tailscaled.
#
#   `nofail` is what does it. systemd.mount(5), verbatim: "this mount will be
#   only wanted, not required, by local-fs.target. Moreover the mount unit is
#   NOT ordered before these target units. This means that the boot will
#   continue without waiting for the mount unit and regardless whether the
#   mount point can be mounted successfully."
#
#   The other four layers guarding the same rule live in immich.nix, where the
#   things that could write to this disk live.
#
# ---------------------------------------------------------------------------
# WHAT IS DELIBERATELY ABSENT, AND WHY
#
#   * No systemd.tmpfiles rule for the mount point. NixOS re-runs tmpfiles on
#     EVERY comin deploy (systemd-tmpfiles-resetup.service), and `nofail`
#     removes this mount from that ordering. A `d /mnt/storage 0000 root root -`
#     rule would therefore chmod the MOUNTED array's root inode on some deploys
#     and not others — and Immich runs with CapabilityBoundingSet="", so with no
#     CAP_DAC_OVERRIDE it could not then traverse into its own library.
#     systemd creates the mount point itself at 0755 root:root
#     (systemd.mount(5), DirectoryMode=). Leave it alone.
#
#   * No neededForBoot, and nothing under /var. That flag puts the entry in the
#     initrd fstab and makes stage 1 of the boot wait for this disk.
#     nixos/lib/utils.nix ALSO treats /, /nix, /var, /var/log, /var/lib, /etc
#     and /usr as needed-for-boot regardless of the flag — which is exactly why
#     the library lives under /mnt and not somewhere tidier like /var/lib.
#
#   * No x-systemd.automount. With autofs the path IS a mount point even when
#     the real filesystem is not mounted, so immich.nix's AssertPathIsMountPoint
#     silently becomes a no-op — and anything that so much as stats the path
#     blocks in uninterruptible sleep until the device timeout expires.
#
#   * No disko stanza. `disko-install --disk` and disko's destroy modes are a
#     footgun aimed at 7 TB of photographs; a plain fileSystems entry cannot
#     format anything. This disk is partitioned once, by hand, and never
#     described declaratively.
# ---------------------------------------------------------------------------

{ ... }:

{
  # ------------------------------------------------------------- the disk ---
  # A hardware-RAID enclosure presenting one 7.28 TiB volume, GPT, single
  # partition, already carrying data. Nothing here formats or repartitions it.
  #
  # Keyed on the FILESYSTEM UUID: not /dev/sdX (enumeration order is not
  # stable) and not by-id (that names the enclosure, which you will replace
  # long before you replace the filesystem). Read it off the box with:
  #
  #   lsblk -f /dev/sda
  #   blkid -s UUID -o value /dev/sda1
  #
  # passno is left at its default of 2, so systemd-fsck@ runs. That is right
  # for a data disk, but note that systemd-fsck@ has an infinite TimeoutSec: a
  # forced full check on 7 TB can leave Immich down for an hour. `nofail` keeps
  # that off the boot path regardless. Run `tune2fs -c 0 -i 0 /dev/sda1` once
  # so that only journal recovery can trigger a check — it does not touch data.
  # Kept in step with hosts/hong-kong/immich.nix, which derives its own
  # mediaRoot from mediaLocation and asserts at eval time that a filesystem
  # is declared here. Change one and the build fails rather than the disk.
  fileSystems."/mnt/storage" = {
    device = "/dev/disk/by-uuid/84010f4f-384a-4cd2-b732-a87b878a85b7";
    fsType = "ext4"; # confirm with lsblk -f before the first deploy

    options = [
      "nofail"                       # the whole point of this file
      "x-systemd.device-timeout=30s" # bound the wait for the DEVICE to appear
      "x-systemd.mount-timeout=2min" # bound how long mount(8) itself may take
      "errors=remount-ro"            # an I/O error goes read-only, not corrupt
      "noatime"
      "nosuid"
      "nodev"
    ];

    # neededForBoot stays false. Read the header before changing this.
  };
}
