# modules/observability-node.nix — what every node exports about itself.
#
# On the spine, so a host is observable the moment it exists. shanghai has
# not been installed yet; when it is, it arrives already exporting, and the
# only edit needed is one line in the `fleet` set in
# hosts/hong-kong/metrics.nix. architecture.md:203 lists "exporters" as part
# of shanghai's duty for exactly this reason.
#
# Nothing here scrapes, stores or alerts. This file only opens a window; the
# things that look through it live on hong-kong.
#
# ---------------------------------------------------------------------------
# THE RULE THIS FILE OBEYS
#
# Same as everything else on these machines: it must not be able to stop the
# box booting or stop tailscaled coming up. So:
#
#   * No new mount, no new secret, no new network dependency at boot.
#   * MemoryMax and a strongly positive OOMScoreAdjust, so under memory
#     pressure the kernel reaches for the exporter long before it reaches for
#     tailscaled (-900) or sshd (-900).
#   * The exporter dying costs you a gap in a graph. Nothing else.
#
# ---------------------------------------------------------------------------
# WHY node_exporter'S systemd COLLECTOR AND NOT prometheus-systemd-exporter
#
# architecture.md:219 asks for a systemd exporter, and is right about why:
# oci-containers and native services are both systemd units, so unit state is
# the container/service signal for a tenth of cAdvisor's memory. It does not
# say it must be a SEPARATE PROCESS, and on a 7.6 GB box already carrying
# Immich, Postgres and a comin evaluation, one binary beats two.
#
# `--collector.systemd` gives node_systemd_unit_state{name,state}, which is
# the whole of "which units are running, failed or flapping". Upgrade to
# services.prometheus.exporters.systemd only if you ever want PER-UNIT cpu and
# memory, which is a different question from per-unit liveness.
#
# NOTE the collector's default unit-exclude is
#   .+\.(automount|device|mount|scope|slice)
# so MOUNTS ARE NOT VISIBLE HERE. /mnt/storage is watched through the
# filesystem collector instead — see the storage group in metrics.nix.
#
# ---------------------------------------------------------------------------
# WHY IT BINDS 0.0.0.0 AND THAT IS NOT A HOLE
#
# Prometheus lives on hong-kong and must reach shanghai over the tailnet, so
# the exporter cannot bind loopback. The perimeter is the firewall, not the
# bind address: modules/base.nix trusts `tailscale0` and opens NOTHING else
# except sshd and tailscaled's UDP port, so 9100 is reachable from the tailnet
# and from nowhere on the physical NIC. openFirewall stays false deliberately —
# turning it on would punch 9100 through on every interface.
#
# The listener is IPv4-only, while MagicDNS answers with both A and AAAA. That
# costs nothing: the tailnet interface is trusted, so a v6 connection reaches
# the kernel and is refused with an immediate RST, and Go's dual-stack dialler
# falls straight through to IPv4. Binding "[::]" would be tidier; it is not
# worth the risk of an unparsed flag on a machine you cannot reach.
# ---------------------------------------------------------------------------

{ config, lib, pkgs, ... }:

{
  services.prometheus.exporters.node = {
    enable = true;
    port = 9100;
    listenAddress = "0.0.0.0"; # read the header before changing this
    openFirewall = false;      # ditto

    # Added to the default set, not replacing it: cpu, filesystem, meminfo,
    # loadavg, diskstats, netdev, vmstat and friends all stay on. vmstat's
    # default include regex already covers oom_kill, which is the single most
    # valuable series on a box this size.
    enabledCollectors = [ "systemd" ];

    # ---------------------------------------------------------------------
    # IF prometheus-node-exporter FAILS TO START, DELETE THESE TWO LINES.
    #
    # Both are opt-in sub-flags of the systemd collector and both are off by
    # default because they cost extra D-Bus round-trips per scrape. They are
    # what turns "this unit is failed" into "this unit is FLAPPING", which is
    # the more useful signal and the one a restart loop shows up in.
    #
    # They are also the only thing in this file that gate 1 cannot check: a
    # flag rename is a runtime failure, not an evaluation error. Confirm on
    # the box with
    #     prometheus-node-exporter --help 2>&1 | grep collector.systemd
    # A failed exporter is a gap in a graph, and gate 4 treats failed units as
    # informational, so the worst case here is boring.
    # ---------------------------------------------------------------------
    extraFlags = [
      "--collector.systemd.enable-restarts-metrics"
      "--collector.systemd.enable-start-time-metrics"
    ];
  };

  systemd.services.prometheus-node-exporter.serviceConfig = {
    # It reads /proc and talks to D-Bus. If it ever needs more than this,
    # something is wrong with it, not with the limit.
    MemoryMax = "128M";

    # tailscaled is -900 and sshd is -900. Monitoring must never be the reason
    # the way back into the machine is the process the kernel picks.
    OOMScoreAdjust = 800;
    CPUWeight = 10;
    IOWeight = 10;

    # Two cores, and a scrape is not urgent.
    Nice = 10;
  };
}
