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
  # PHASE 5, stage 1: the 7 TB array on its own. No users, no services, no
  # secrets — just a nofail mount, so this stage can be proven before anything
  # depends on it. Widen to ./services.nix once the prerequisites listed at the
  # bottom of this file are met.
  imports = [ ./disko.nix ./storage.nix ];

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

  # ---- PHASE 5: workloads ---------------------------------------------------
  # Immich on the 7 TB array, tsidp for OIDC, and the tailscale serve front
  # door. All written and reviewed in ./services.nix and the four files it
  # imports, but NOT WIRED IN HERE YET, because the later stages cannot
  # evaluate until out-of-band state exists that no commit can carry:
  #
  #   * secrets/hong-kong.yaml must exist and be encrypted to this host's age
  #     key — sops.defaultSopsFile is a path, so eval fails without it.
  #   * flake.nix's sops-nix input and module must be uncommented and
  #     `nix flake lock` run, or comin cannot deploy at all (operating rule 1).
  #   * immich.nix needs a client ID that only a running tsidp can issue.
  #
  # None of that is true of the disk, though. ./storage.nix is a bare
  # fileSystems entry with no users, services or secrets, its UUID is already
  # filled in, and it is the piece whose failure mode most needs rehearsing —
  # so it goes first, on its own:
  #
  #     imports = [ ./disko.nix ./storage.nix ];
  #
  # then widen to the full set once the later prerequisites are met:
  #
  #     imports = [ ./disko.nix ./services.nix ];
  #
  # Left disabled rather than gated on builtins.pathExists, so that a missing
  # prerequisite is loud rather than a silent non-deployment. The stage-by-stage
  # runbook — including why tsidp has to be deployed before Immich can be
  # configured, and how to try a stage without touching `main` — is the header
  # of ./services.nix.
}
