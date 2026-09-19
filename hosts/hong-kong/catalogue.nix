# hosts/hong-kong/catalogue.nix — what is running, where you can reach it,
# and what it costs.
#
# ---------------------------------------------------------------------------
# THE PROBLEM THIS SOLVES
#
# Grafana can already answer "is the unit active" — node_exporter's systemd
# collector gives node_systemd_unit_state. It cannot answer either of the two
# questions you actually want next:
#
#   "IS THIS ON THE PUBLIC INTERNET, AND AT WHAT ADDRESS?"
#       Not runtime state. It is a fact about the REPOSITORY — a line in a
#       compose file plus a zone in ./public.nix. Prometheus has no way to
#       learn it by looking at the machine, so this file EXPORTS it, and the
#       dashboard joins it to the live series by unit name.
#
#   "WHAT IS IT USING?"
#       node_exporter's systemd collector emits state, tasks, restarts and
#       start time, and NO cpu or memory — checked against
#       collector/systemd_linux.go, not assumed. cAdvisor is the usual answer
#       and architecture.md:219 already refused it, correctly: it is an extra
#       daemon on a two-core box and it only sees CONTAINERS, so it would
#       leave Immich, Grafana, Postgres and tsidp — most of what actually
#       uses this machine — invisible.
#
#       So resources come from the cgroup files systemd already maintains,
#       which cover native units and containers identically and cost one
#       small script every thirty seconds.
#
# ---------------------------------------------------------------------------
# TWO METRICS, TWO DIFFERENT LIFETIMES
#
#   fleet_service_info          STATIC. Generated at build time, written into
#                               the store, symlinked into the textfile
#                               directory. It changes when you commit, never
#                               at runtime — which is exactly right, because
#                               what it describes is the repository.
#
#   fleet_service_{memory,cpu}  DYNAMIC. A timer reads the cgroups.
#
# Both land in the same textfile directory modules/comin-liveness.nix already
# set up, so this adds no exporter and no port.
#
# WHY A `1`-VALUED INFO METRIC. It carries everything in labels and the value
# is meaningless — the standard Prometheus "info" pattern. The dashboard joins
# it to node_systemd_unit_state on `unit`, which is why the unit name in the
# catalogue below has to match the real unit exactly. It is asserted where it
# can be and hand-checked where it cannot; see nativeServices.
#
# ---------------------------------------------------------------------------
# THE HAND-MAINTAINED HALF, AND WHY IT IS NOT AUTOMATIC
#
# Compose apps come from config.fleet.apps and are therefore always correct —
# adding one to ./apps/ puts it on the dashboard with no edit here.
#
# The native services cannot be, because each is a hand-written .nix file with
# its own module and its own unit name. A catalogue that quietly missed one
# would be worse than no catalogue: you would look at a dashboard showing five
# services, believe it was five, and be wrong. So they are listed explicitly
# below, and adding a native service means adding a line here. That is the
# cost of the dashboard being trustworthy.
# ---------------------------------------------------------------------------

{ config, lib, pkgs, ... }:

let
  tailnet = "shark-kitefin.ts.net";
  textfileDir = "/var/lib/node-exporter-textfile";

  # Compose apps, straight from the translator. public/frontdoor are LABELS;
  # the full names are built the same way ./public.nix and ../../cloudflare/
  # build them, from the one zone.
  zone = "ivanchan.me";

  composeEntries = lib.mapAttrsToList (_stem: a: {
    service = a.service;
    unit = "podman-${a.service}.service";
    kind = "container";
    public = if a.public == null then "" else "${a.public}.${zone}";
    tailnetAddr = if a.frontdoor == null then "" else "${a.frontdoor}.${tailnet}";
  }) config.fleet.apps;

  # See the header: this half is hand-maintained on purpose. Unit names are
  # what the dashboard joins on, so a typo here shows as a service that is
  # permanently "unknown" rather than as an error.
  nativeEntries = [
    {
      service = "immich";
      unit = "immich-server.service";
      kind = "native";
      public = "";
      tailnetAddr = "immich.${tailnet}";
    }
    {
      service = "grafana";
      unit = "grafana.service";
      kind = "native";
      public = "";
      tailnetAddr = "grafana.${tailnet}";
    }
    {
      service = "tsidp";
      unit = "tsidp.service";
      kind = "native";
      public = "";
      tailnetAddr = "idp.${tailnet}";
    }
    {
      service = "prometheus";
      unit = "prometheus.service";
      kind = "native";
      public = "";
      tailnetAddr = ""; # loopback only, deliberately — see ./metrics.nix
    }
    {
      service = "postgresql";
      unit = "postgresql.service";
      kind = "native";
      public = "";
      tailnetAddr = "";
    }
  ]
  # cloudflared's unit name contains the tunnel name, so it is derived rather
  # than typed. No tunnel configured, no entry.
  ++ map (t: {
    service = "cloudflared";
    unit = "cloudflared-tunnel-${t}.service";
    kind = "native";
    public = "";
    tailnetAddr = "";
  }) (lib.attrNames (config.services.cloudflared.tunnels or { }));

  entries = nativeEntries ++ composeEntries;

  infoLines = map (
    e:
    ''fleet_service_info{service="${e.service}",unit="${e.unit}",kind="${e.kind}",public="${e.public}",tailnet="${e.tailnetAddr}",exposure="${
      if e.public != "" then "public" else if e.tailnetAddr != "" then "tailnet" else "internal"
    }"} 1''
  ) entries;

  infoFile = pkgs.writeText "fleet-service-info.prom" ''
    # HELP fleet_service_info Static catalogue of services on this host: where they can be reached, and how.
    # TYPE fleet_service_info gauge
    ${lib.concatStringsSep "\n" infoLines}
  '';

  units = map (e: e.unit) entries;

  resourceScript = pkgs.writeShellScript "fleet-service-resources" ''
    set -uo pipefail
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.systemd pkgs.gnugrep ]}

    out=${textfileDir}/fleet-service-resources.prom
    tmp=$out.new

    {
      echo "# HELP fleet_service_memory_bytes Current memory charged to the unit's cgroup."
      echo "# TYPE fleet_service_memory_bytes gauge"
      echo "# HELP fleet_service_cpu_seconds_total Cumulative CPU time for the unit's cgroup."
      echo "# TYPE fleet_service_cpu_seconds_total counter"

      for unit in ${lib.escapeShellArgs units}; do
        # Resolve the cgroup rather than guessing the path: immich-server
        # lives under system-immich.slice, not directly under system.slice,
        # and a guessed path would silently report nothing for exactly the
        # service whose memory matters most.
        cg=$(systemctl show -p ControlGroup --value "$unit" 2>/dev/null || true)
        [ -n "$cg" ] || continue

        base=/sys/fs/cgroup$cg
        [ -d "$base" ] || continue

        if [ -r "$base/memory.current" ]; then
          mem=$(cat "$base/memory.current")
          echo "fleet_service_memory_bytes{unit=\"$unit\"} $mem"
        fi

        if [ -r "$base/cpu.stat" ]; then
          line=$(grep -m1 '^usage_usec ' "$base/cpu.stat" || true)
          usec=''${line#usage_usec }
          if [ -n "$usec" ] && [ "$usec" != "$line" ]; then
            # Integer maths only — no awk, no bc. Microseconds to seconds with
            # six decimal places, which is more precision than a rate() over
            # thirty-second samples can possibly use.
            printf 'fleet_service_cpu_seconds_total{unit="%s"} %d.%06d\n' \
              "$unit" "$((usec / 1000000))" "$((usec % 1000000))"
          fi
        fi
      done
    } > "$tmp"

    # node_exporter reads this directory on every scrape and WILL read a
    # half-written file. Build elsewhere, rename into place.
    mv -f "$tmp" "$out"
  '';
in
{
  assertions = [
    {
      assertion = config.services.prometheus.exporters.node.enable;
      message = ''
        hosts/hong-kong/catalogue.nix publishes metrics through the node
        exporter's textfile collector, and no node exporter is enabled. It
        comes from modules/observability-node.nix on the flake spine.
      '';
    }
  ];

  # The static half. A symlink to a store path, so it changes only when the
  # configuration does and there is no unit to run, fail or forget.
  systemd.tmpfiles.rules = [
    "L+ ${textfileDir}/fleet-service-info.prom - - - - ${infoFile}"
  ];

  systemd.services.fleet-service-resources = {
    description = "Sample cgroup memory and CPU for catalogued services";

    serviceConfig = {
      Type = "oneshot";
      ExecStart = resourceScript;

      # Monitoring's rung: above Immich at 500, far below tailscaled at -900.
      OOMScoreAdjust = 800;
      MemoryMax = "64M";
      CPUWeight = 10;
      IOWeight = 10;
    };
  };

  systemd.timers.fleet-service-resources = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      # Prometheus scrapes more often than this, so the series is a staircase
      # rather than a curve. That is the right trade on a two-core box: this
      # is for "what is using the machine", not for catching a spike.
      OnUnitActiveSec = "30s";
      AccuracySec = "5s";
    };
  };
}
