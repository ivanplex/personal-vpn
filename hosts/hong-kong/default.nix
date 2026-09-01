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
  # ./services.nix aggregates every phase-5 workload — storage, secrets,
  # identity, Immich, and now Prometheus — and its header is the
  # stage-by-stage runbook for all of it. Staging is done by commenting import
  # lines THERE, not here and not inside a file.
  imports = [ ./disko.nix ./services.nix ];

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
  # Stages 1-7(b) are all imported now: the array, sops, tsidp, Immich,
  # Prometheus, Grafana and its tsnet node. What is left:
  #
  #   Stage 7(c) — OIDC for Grafana. `oidcClientId` in ./dashboard.nix is
  #   null, which is a WORKING configuration, not a placeholder: Grafana comes
  #   up with the login form only and declares no OIDC secret at all. tsidp
  #   has to issue the client first, exactly as it did for Immich.
  #
  #   Stage 8 — alert delivery, not written at all. Alertmanager and the
  #   external dead-man's-switch heartbeat, without which Prometheus on
  #   hong-kong is a thing that knows hong-kong is dying and cannot tell
  #   anyone.
  #
  # Note the eval-time assertions that make partial imports impossible:
  # ./immich.nix refuses to build unless a filesystem is declared at its
  # mediaLocation's parent (so it cannot quietly build a photo library on the
  # root SSD); ./dashboard.nix refuses unless Prometheus is enabled; and
  # ./grafana-frontdoor.nix refuses unless Grafana is.
}
