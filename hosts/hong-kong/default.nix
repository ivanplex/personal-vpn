# hosts/hong-kong — Hong Kong.
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
  # PHASE 5, stage 2: the array, sops-nix, and tsidp. NOT ./immich.nix yet —
  # it needs an OIDC client ID that only a running tsidp can issue, so it lands
  # in stage 4. Widen to ./services.nix (all four) then. The staging rationale
  # and the full runbook are the header of ./services.nix.
  imports = [ ./disko.nix ./storage.nix ./secrets.nix ./identity.nix ];

  networking.hostName = "hong-kong";

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

  # ---- PHASE 5: what is still not wired in --------------------------------
  # ./immich.nix is written and reviewed but not imported. It cannot be until
  # tsidp has issued an OIDC client ID and secret, which requires tsidp to be
  # running first — stages 3 and 4 of the runbook in ./services.nix.
  #
  # When it lands, replace the imports above with:
  #
  #     imports = [ ./disko.nix ./services.nix ];
  #
  # which is exactly the same four files, via the aggregator.
  #
  # Note ./immich.nix asserts at eval time that a filesystem is declared at its
  # mediaLocation's parent, so it cannot be imported without ./storage.nix and
  # quietly build a photo library on the root SSD.
}
