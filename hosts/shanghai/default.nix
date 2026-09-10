# hosts/shanghai — Shanghai.
#
# Hardware confirmed 2026-09-10 on the machine itself:
#   Lenovo ThinkCentre M710q Tiny, 10MR0023UK, BIOS M1AKT24A (2017-07-25)
#   UEFI (Secure Boot off) · i3-7100T Kaby Lake 2C/4T · 7.6 GiB
#   Kingston SA400S37120G, 111.8 G, SATA — NO NVMe, both M.2 slots empty
#   enp0s31f6, MAC 6c:4b:90:24:b9:13
#   Intel 8265 wifi/BT at 01:00.0 — blacklisted below
#
# Duty: exit node only. Nothing else lives here — it is the hardest machine
# to reach and the one with the least margin for surprises.
{ config, lib, pkgs, ... }:

{
  imports = [ ./disko.nix ];

  networking.hostName = "shanghai";

  boot.initrd.availableKernelModules = [
    "xhci_pci" "nvme" "ahci" "usb_storage" "sd_mod" "rtsx_pci_sdmmc"
  ];
  boot.kernelModules = [ "kvm-intel" ];

  # Kaby Lake IGD loses the display at the i915 modeset on this box — the
  # firmware console dies the instant the kernel takes over. Confirmed
  # 2026-09-10 on real hardware; nomodeset restores it. Costs VAAPI, which
  # this host does not need.
  boot.kernelParams = [ "nomodeset" ];

  # Intel 8265 wifi/BT at 01:00.0 — no firmware, unconfigured, unwanted.
  # Attack surface on a hostile network with no upside.
  boot.blacklistedKernelModules = [ "iwlwifi" "btusb" ];

  # ---- PHASE 3+: living behind the Great Firewall ---------------------------
  # GitHub is unreliable from the mainland and cache.nixos.org is slow, so
  # this host gets extra remotes and substituters. Configured here rather
  # than in base.nix because it is genuinely host-specific.
  #
  # nix.settings.substituters = lib.mkForce [
  #   "https://hong-kong.shark-kitefin.ts.net/attic/fleet"
  #   "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store"
  #   "https://cache.nixos.org"
  # ];
  #
  # And this host tracks `stable`, not `main` — it is deliberately a day
  # behind hong-kong, which is what makes hong-kong the canary. See phase3.nix.
}
