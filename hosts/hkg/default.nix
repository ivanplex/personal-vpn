# hosts/hkg — Hong Kong.
#
# Confirmed hardware, read off the console 2026-08-30:
#   Intel i3-7100T (Kaby Lake, 2C/4T, 3.4 GHz)
#   7.6 GB usable RAM
#   Samsung MZVLW256HEHP 238.5 GB NVMe  ->  /dev/nvme0n1
#   Intel NIC enp0s31f6, MAC 6c:4b:90:2d:2f:f8
#
# Duty: exit node, plus (phase 5) Immich on a 7 TB external disk,
# Prometheus + Grafana, Attic binary cache, Git mirror.
{ config, lib, pkgs, ... }:

{
  imports = [ ./disko.nix ];

  networking.hostName = "hkg";

  # Kaby Lake hardware video: HD Graphics 630 can do H.264/HEVC transcoding
  # for Immich through VAAPI. Unrelated to the ML features we are skipping.
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver
      vpl-gpu-rt
    ];
  };

  # NVMe + Kaby Lake need nothing exotic; these are the standard modules for
  # a UEFI NVMe box. Regenerate with `nixos-generate-config --no-filesystems`
  # if anything fails to find its root device.
  boot.initrd.availableKernelModules = [
    "xhci_pci" "nvme" "usb_storage" "sd_mod" "rtsx_pci_sdmmc"
  ];
  boot.kernelModules = [ "kvm-intel" ];

  # ---- PHASE 5: workloads ---------------------------------------------------
  # Immich, Prometheus, Grafana and the 7 TB disk arrive here, last, once
  # every safety net underneath them has been rehearsed. The external disk
  # MUST be mounted with `nofail` so a USB dropout degrades Immich instead of
  # holding up the boot and turning a disk hiccup into an unreachable machine.
  #
  # imports = [ ./services.nix ];
}
