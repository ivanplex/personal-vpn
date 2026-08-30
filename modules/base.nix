# modules/base.nix — everything both machines share.
{ config, lib, pkgs, ... }:

{
  # ---------------------------------------------------------------- boot ----
  # systemd-boot, which REQUIRES the machine to be in UEFI mode. If
  # /sys/firmware/efi did not exist in the installer, stop and fix the BIOS
  # before installing — gate 3 depends on this bootloader.
  boot.loader.systemd-boot = {
    enable = true;
    # Keep enough generations to roll back through, but not so many that the
    # ESP fills up. Each entry carries a kernel + initrd, roughly 100 MB.
    configurationLimit = 10;
    editor = false; # no kernel cmdline editing from the boot menu
  };
  boot.loader.efi.canTouchEfiVariables = true;

  # Kernel hang insurance. systemd pings /dev/watchdog; if the kernel stops
  # scheduling, the chipset resets the box. Combined with the boot-verdict
  # module this turns a hard hang into an automatic recovery.
  systemd.watchdog.runtimeTime = "30s";
  systemd.watchdog.rebootTime = "10m";

  hardware.cpu.intel.updateMicrocode = true;
  hardware.enableRedistributableFirmware = true;

  # 8 GB of RAM, so this is a safety net rather than a crutch. It costs
  # nothing when unused and prevents an OOM during a large evaluation.
  zramSwap.enable = true;
  zramSwap.memoryPercent = 25;

  # ----------------------------------------------------------------- nix ----
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];

    # These machines fetch; they should almost never compile.
    max-jobs = 2;
    cores = 2;

    substituters = [
      "https://cache.nixos.org"
      # PHASE 5: your own Attic cache on hkg goes first, and for sha a
      # domestic mirror goes second:
      # "https://hkg.shark-kitefin.ts.net/attic/fleet"
      # "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    ];

    # Stop the disk filling silently. When free space drops below min-free,
    # Nix garbage-collects until max-free. A full disk means no more deploys
    # AND no more rollbacks, which is the worst state this fleet can reach.
    min-free = 5 * 1024 * 1024 * 1024;   # 5 GB
    max-free = 20 * 1024 * 1024 * 1024;  # 20 GB

    auto-optimise-store = true;
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    # Deliberately generous. Old generations are what you roll back TO.
    options = "--delete-older-than 30d";
  };

  # -------------------------------------------------------------- access ----
  users.users.ivan = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    openssh.authorizedKeys.keys = [
      # <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
      # REPLACE THIS with your real public key (~/.ssh/id_ed25519.pub).
      # This is the only edit the repo needs before it will install, and it
      # is how you get back into the machine. Do not install without it.
      "ssh-ed25519 AAAAREPLACEMEREPLACEMEREPLACEME ivan@laptop"
      # >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
    ];
  };

  # No password prompts: on a machine you cannot reach, an interactive sudo
  # prompt during an automated action is a hang, not a security control.
  # Access is already gated by SSH keys and the tailnet ACL.
  security.sudo.wheelNeedsPassword = false;

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
    # Keep sshd as the second door alongside Tailscale SSH.
    openFirewall = true;
  };

  networking.firewall.enable = true;
  # Trust the tailnet interface; expose nothing else by default.
  networking.firewall.trustedInterfaces = [ "tailscale0" ];
  networking.firewall.allowedUDPPorts = [ config.services.tailscale.port ];

  networking.networkmanager.enable = false;
  networking.useDHCP = lib.mkDefault true;

  # ------------------------------------------------------------- basics -----
  time.timeZone = "Asia/Hong_Kong";
  i18n.defaultLocale = "en_GB.UTF-8";

  environment.systemPackages = with pkgs; [
    git vim htop tmux curl jq dnsutils pciutils usbutils lm_sensors
  ];

  # Journals survive reboots — essential when diagnosing why a box came back.
  services.journald.extraConfig = ''
    Storage=persistent
    SystemMaxUse=500M
  '';

  system.stateVersion = "26.05";
}
