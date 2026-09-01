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

  systemd.services.tailscaled = {
    # Wait for an actual network before starting. Without this, tailscaled came
    # up six seconds into boot, logged "connect: network is unreachable" against
    # every bootstrap server, and configured DNS having captured no upstream
    # resolvers — leaving the machine able to resolve *.ts.net and nothing else.
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      # Do not let a Tailscale hiccup delay boot indefinitely.
      TimeoutStartSec = "30s";

      # PHASE 5. hong-kong now runs Immich, Postgres and a comin evaluation of
      # this flake on 7.6 GB. Under a global OOM the kernel picks by oom_score,
      # and the one process it must never pick is the only way back into the
      # machine. -900 makes tailscaled effectively last.
      #
      # NOT MemoryMin: cgroup v2 memory.min is clamped by every ancestor, and
      # neither system.slice nor -.slice sets one, so it would be inert.
      OOMScoreAdjust = -900;
    };
  };
}
