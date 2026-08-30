# hosts/shanghai — Shanghai.
#
# HARDWARE NOT YET CONFIRMED. Run the discovery commands from the runbook on
# this machine and update the notes below before installing:
#   lsblk -o NAME,SIZE,MODEL,TRAN
#   ls /sys/firmware/efi >/dev/null && echo UEFI || echo BIOS
#   lscpu | head -20
#   free -h
#   ip -br link
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
