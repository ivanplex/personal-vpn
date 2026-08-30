# modules/tailscale-node.nix — every node is an exit node.
#
# Native tailscaled, not a container. On a declarative host the usual reason
# to containerise Tailscale (keeping the base system clean) does not apply,
# and a container would cost you a second identity, a second key to rotate,
# a state volume and NET_ADMIN for no gain.
{ config, lib, pkgs, ... }:

{
  services.tailscale = {
    enable = true;
    # "both" = advertise an exit node AND accept subnet routes.
    useRoutingFeatures = "both";

    # PHASE 1: no key here. You run `tailscale up` by hand once, at the
    # console, while you still can. State persists in /var/lib/tailscale and
    # survives reboots, so this only ever matters again on a reinstall.
    #
    # PHASE 3: once sops is in place, an auth key from a tagged OAuth client
    # makes a reinstall unattended:
    # authKeyFile = config.sops.secrets.tailscale-authkey.path;

    extraUpFlags = [
      "--advertise-exit-node"
      "--ssh"                 # Tailscale SSH: auth via tailnet ACLs
    ];
  };

  # Required for exit-node traffic to be forwarded at all.
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
  };

  # Tailscale's own advice: strict reverse-path filtering drops exit-node
  # traffic on some kernels.
  networking.firewall.checkReversePath = "loose";

  # Do not let a Tailscale hiccup delay boot.
  systemd.services.tailscaled.serviceConfig.TimeoutStartSec = "30s";
}
