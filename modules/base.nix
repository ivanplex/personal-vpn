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
  # (These moved from systemd.watchdog.* in a recent nixpkgs.)
  systemd.settings.Manager = {
    RuntimeWatchdogSec = "30s";
    RebootWatchdogSec = "10m";
  };

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
      # PHASE 5: your own Attic cache on hong-kong goes first; shanghai
      # additionally gets a domestic mirror second:
      # "https://hong-kong.shark-kitefin.ts.net/attic/fleet"
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
      # Two keys on purpose. They are different keys, held in different
      # places, so losing one does not lose you the machine. Verify each with
      # `ssh-keygen -lf <file>` — the fingerprints are noted below.

      # MacBook Pro — the one you will use day to day.
      #   SHA256:Y1hmRv6RnqVmAkKht6uHoBGppKRayUGd0Oml7Bc4XkY
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEZ/EIDnLKiiq69RUh4bDfXxyWjptpxjRyu9xIKZm5ir ivan@MacBook-Pro-4.local"

      # From https://github.com/ivanplex.keys — wherever that private key
      # lives, it is a second way in. If you no longer hold it, delete this
      # line; a key you cannot use is not a backup.
      #   SHA256:r3FJ4iizkb518dUUXvCKpv8x6WM5zW9i3XflS+xpQYc
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO2OV+Onll7zgHEyV1K2ZLqBr0iASEL6x+jKlXG5TeSr"
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

  # Same reasoning as tailscaled's OOMScoreAdjust in modules/tailscale-node.nix:
  # sshd is the second way in and costs a few MB, so it must outlive anything
  # that eats memory.
  #
  # Leave systemd.oomd alone while you are here. It defaults to enabled but with
  # enableRootSlice / enableSystemSlice / enableUserSlices all false, so it runs
  # and manages nothing. enableSystemSlice = true would put
  # ManagedOOMMemoryPressure=kill on system.slice — which contains tailscaled
  # and sshd, i.e. the exact opposite of what these two lines are for.
  systemd.services.sshd.serviceConfig.OOMScoreAdjust = -900;

  networking.firewall.enable = true;
  # Trust the tailnet interface; expose nothing else by default.
  networking.firewall.trustedInterfaces = [ "tailscale0" ];
  networking.firewall.allowedUDPPorts = [ config.services.tailscale.port ];

  networking.networkmanager.enable = false;
  networking.useDHCP = lib.mkDefault true;

  # ------------------------------------------------------------------ dns ---
  # 2026-08-31: this machine spent a while resolving *.ts.net perfectly while
  # failing to resolve github.com at all, and reported itself healthy the
  # whole time. tailscaled had started before the network was up ("connect:
  # network is unreachable"), captured no upstream resolvers, and owned
  # /etc/resolv.conf through openresolv. comin would simply have stopped
  # deploying, silently.
  #
  # systemd-resolved fixes the structure: Tailscale detects it and uses split
  # DNS over D-Bus — only *.ts.net goes to MagicDNS at 100.100.100.100, and
  # everything else goes to resolved, which holds DHCP-supplied servers AND a
  # hardcoded fallback that survives any startup race.
  services.resolved = {
    enable = true;
    fallbackDns = [ "1.1.1.1" "9.9.9.9" ];
  };

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
