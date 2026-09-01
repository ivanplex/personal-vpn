# hosts/hong-kong/metrics.nix — Prometheus: the scraping, the storing and the
# rules. Grafana is a separate file, and a separate stage, because this one is
# useful and verifiable without it.
#
# ---------------------------------------------------------------------------
# THE RULE THIS FILE OBEYS
#
# Monitoring is the least important thing on this machine. It watches the exit
# node; it is not the exit node. So:
#
#   * It binds LOOPBACK ONLY. Nothing outside this box talks to Prometheus.
#     The dashboard is Grafana's job, over `tailscale serve` on its own node.
#   * It is capped, in a slice, and marked as the first thing the kernel should
#     kill. See the memory note at the bottom.
#   * Its TSDB is bounded by BOTH time and size. "Disk full" is in the brick
#     table in architecture.md:281 — a full root disk means no deploys AND no
#     rollbacks, which is the worst state this fleet can reach. A monitoring
#     system that causes the outage it was installed to detect is not a joke
#     anyone finds funny at 9,000 km.
#   * Its data lives on the internal SSD, NOT on /mnt/storage. The array is
#     mounted `nofail` precisely so that losing it degrades one workload; a
#     TSDB on it would make losing a USB enclosure also mean losing the
#     ability to see why.
#
# ---------------------------------------------------------------------------
# HOW TO LOOK AT PROMETHEUS ITSELF
#
# There is no front door for it, on purpose. From the MacBook:
#
#     ssh -N -L 9090:127.0.0.1:9090 ivan@hong-kong.shark-kitefin.ts.net
#     open http://127.0.0.1:9090/targets
#
# Day to day you should not need this: the fleet dashboard graphs `up` for
# every target, which is the /targets page as a metric.
#
# ---------------------------------------------------------------------------
# WHAT IS NOT SCRAPED, AND WHY
#
#   * Immich. It can emit OpenTelemetry metrics via IMMICH_TELEMETRY_INCLUDE,
#     but turning that on edits a working, deployed Immich for a nice-to-have.
#     Its LIVENESS is already covered by node_systemd_unit_state. Separate
#     change, separate stage, if ever.
#   * tsidp. Version 0.0.12 exposes no metrics endpoint. Liveness only.
#   * The two extra tailscaled instances. Same: liveness through systemd.
#   * cAdvisor. architecture.md:219 — deliberately skipped.
# ---------------------------------------------------------------------------

{ config, lib, pkgs, ... }:

let
  tailnet = "shark-kitefin.ts.net";

  # ------------------------------------------------------------ the fleet ---
  # Every host Prometheus is expected to be able to reach, and the address it
  # is reached at.
  #
  # hong-kong is scraped over LOOPBACK, not over its own MagicDNS name. It is
  # the same machine, so going out to the tailnet and back would make the
  # local scrape depend on DNS and on tailscaled — the two things most likely
  # to be broken when you most need the graphs.
  #
  # shanghai is NOT in this list. It has not been installed
  # (architecture.md:7, "Not started"), and a target that is permanently down
  # is an alert that teaches you to ignore alerts. The day it boots, delete
  # the comment. That is the entire change on this side; the exporter is
  # already in the spine, in modules/observability-node.nix.
  fleet = {
    hong-kong = "127.0.0.1";
    # shanghai = "shanghai.${tailnet}";
  };

  # The `instance` label is taken from __address__ only when it is not already
  # set, so setting it here is enough — no relabel_configs needed, and the
  # dashboards get a bare hostname rather than a host:port.
  mkTargets = port:
    lib.mapAttrsToList
      (host: addr: {
        targets = [ "${addr}:${toString port}" ];
        labels = { instance = host; };
      })
      fleet;
in
{
  services.prometheus = {
    enable = true;

    # LOOPBACK. Read the header.
    listenAddress = "127.0.0.1";
    port = 9090;

    # Retention is bounded twice, and whichever bound is hit first wins.
    # Sizing, at a 30 s scrape: roughly 5,000 series across the fleet at about
    # 2 bytes per compressed sample is ~30 MB a day, so 90 days is ~2.6 GB.
    # The size cap is therefore headroom, not a plan — it is the backstop that
    # keeps a runaway cardinality bug off the root disk.
    retentionTime = "90d";
    extraFlags = [ "--storage.tsdb.retention.size=6GB" ];

    globalConfig = {
      # Two cores. 30 s is plenty for a fleet whose fastest interesting event
      # is a systemd unit restarting.
      scrape_interval = "30s";
      scrape_timeout = "10s";
      evaluation_interval = "30s";
      external_labels = { fleet = tailnet; };
    };

    scrapeConfigs = [
      {
        job_name = "node";
        static_configs = mkTargets 9100;
      }
      {
        # modules/comin.nix:73 already exports on 4243, and comin's exporter
        # defaults to listening on every interface with the firewall closed —
        # same perimeter argument as the node exporter. Metric names confirmed
        # against the pinned rev ffeadf3, internal/prometheus/prometheus.go.
        job_name = "comin";
        static_configs = mkTargets 4243;
      }
      {
        job_name = "prometheus";
        static_configs = [{
          targets = [ "127.0.0.1:9090" ];
          labels = { instance = "hong-kong"; };
        }];
      }
      # The Grafana scrape job is declared in ./dashboard.nix, not here.
      # NixOS merges these lists across modules, so keeping it next to the
      # thing it scrapes means staging still works: with dashboard.nix
      # un-imported there is no job pointing at a port nothing is listening
      # on, and therefore no permanently-firing alert.
    ];

    # ---------------------------------------------------------------------
    # RULES
    #
    # services.prometheus.checkConfig defaults to true, so promtool validates
    # every expression below AT BUILD TIME — which means gate 1 catches a
    # malformed rule in CI, on a branch, before any machine sees it.
    #
    # What promtool cannot check is whether a metric NAME exists. Every name
    # used here is either a node_exporter default, a documented opt-in
    # collector, or read off comin's source at the pinned revision. Where a
    # metric may be absent the rule is written so that absence means SILENCE,
    # never a false alarm — an alert nobody believes is worse than no alert.
    #
    # Severity is a promise about consequence, not about how annoying the
    # thing is:
    #   critical  you may be losing, or about to lose, the machine
    #   warning   a workload is degraded; the machine is fine
    #   info      worth knowing at leisure
    #
    # NOTHING DELIVERS THESE YET. They surface in Grafana's Alerting page and
    # nowhere else. Alertmanager and the healthchecks.io dead-man's switch
    # (architecture.md:221) are the next change, and they are the ones that
    # make the 24 h soak gate mean something.
    # ---------------------------------------------------------------------
    rules = [
      ''
        groups:
          # =================================================== reachability ==
          - name: fleet-reachability
            rules:
              - alert: ExporterDown
                expr: up == 0
                for: 10m
                labels:
                  severity: warning
                annotations:
                  summary: "{{ $labels.job }} on {{ $labels.instance }} has not answered a scrape in 10 minutes"
                  description: >-
                    Either the exporter died or the host is unreachable. If
                    every job for one instance is down at once, suspect the
                    host. If one job is down on a healthy host, suspect the
                    unit: systemctl status prometheus-node-exporter.

              - alert: FleetHostUnreachable
                expr: count by (instance) (up == 0) == count by (instance) (up)
                for: 10m
                labels:
                  severity: critical
                annotations:
                  summary: "every scrape target on {{ $labels.instance }} is down"
                  description: >-
                    The host itself, not one exporter. Note the blind spot
                    this cannot see: hong-kong runs Prometheus, so hong-kong
                    going dark produces silence, not an alert. That is what
                    the external heartbeat is for, and it does not exist yet.

              - alert: TailscaledNotRunning
                expr: node_systemd_unit_state{name="tailscaled.service",state="active"} == 0
                for: 5m
                labels:
                  severity: critical
                annotations:
                  summary: "tailscaled is not active on {{ $labels.instance }}"
                  description: >-
                    The only way back into this machine. Gate 4 in
                    modules/boot-verdict.nix is also watching, and will act
                    before you can. This alert is how you find out it did.

              - alert: SshdNotRunning
                expr: node_systemd_unit_state{name="sshd.service",state="active"} == 0
                for: 5m
                labels:
                  severity: critical
                annotations:
                  summary: "sshd is not active on {{ $labels.instance }}"
                  description: The second door, per modules/base.nix.

              - alert: HostRebootLoop
                expr: changes(node_boot_time_seconds[1h]) > 2
                labels:
                  severity: critical
                annotations:
                  summary: "{{ $labels.instance }} has rebooted {{ $value }} times in an hour"
                  description: >-
                    Gate 3 failing over and over, or the hardware watchdog in
                    modules/base.nix firing repeatedly. Either way the box is
                    not staying up long enough to be deployed to.

          # ======================================================== deploys ==
          - name: deploys
            rules:
              - alert: CominExporterDown
                expr: up{job="comin"} == 0
                for: 10m
                labels:
                  severity: critical
                annotations:
                  summary: "comin is not answering on {{ $labels.instance }}"
                  description: >-
                    A machine whose deploy agent is dead is a machine you have
                    quietly lost: it keeps running, keeps passing every other
                    check, and ignores everything you push. Gate 4 does not
                    check comin yet (tech-debt.md). Until it does, this alert
                    is the only thing that notices.

              - alert: CominFetchFailing
                expr: comin_last_fetch_failed == 1
                for: 30m
                labels:
                  severity: warning
                annotations:
                  summary: "comin cannot fetch from {{ $labels.remote_name }} on {{ $labels.instance }}"
                  description: >-
                    Usually an expired GitHub PAT in /etc/comin/github-token,
                    or GitHub unreachable. The failure mode is benign — the
                    node keeps running its last good generation — but it is
                    silent, which is why 30 minutes of it is worth saying out
                    loud.

              - alert: CominEvaluationFailing
                expr: comin_last_eval_failed == 1
                for: 15m
                labels:
                  severity: warning
                annotations:
                  summary: "comin cannot evaluate the flake on {{ $labels.instance }}"
                  description: >-
                    Almost always a missing or stale flake.lock (operating
                    rule 1), or the evaluation running out of memory.

              - alert: CominBuildFailing
                expr: comin_last_build_failed == 1
                for: 15m
                labels:
                  severity: warning
                annotations:
                  summary: "comin cannot build the configuration on {{ $labels.instance }}"

              - alert: CominDeploymentFailed
                expr: comin_last_deployment_failed == 1
                for: 5m
                labels:
                  severity: critical
                annotations:
                  summary: "the last comin deployment failed on {{ $labels.instance }}"
                  description: >-
                    Read tech-debt.md before assuming this rolled back: at the
                    pinned rev comin sets the system profile BEFORE running
                    switch-to-configuration and does not roll back, and
                    IsAlreadyDeployed keys on OutPath, so it will NOT retry
                    this generation. After fixing the cause you must start the
                    unit by hand or push a new commit.

              - alert: CominNeedsReboot
                expr: comin_need_to_reboot == 1
                for: 6h
                labels:
                  severity: info
                annotations:
                  summary: "{{ $labels.instance }} has been waiting on a reboot for 6 hours"
                  description: >-
                    A new kernel or initrd is deployed but not running. On this
                    fleet a reboot is a gate-3 event, so it is a decision, not
                    a chore. Do it while you can watch it.

              - alert: CominSuspended
                expr: comin_is_suspended == 1
                for: 1h
                labels:
                  severity: warning
                annotations:
                  summary: "comin is suspended on {{ $labels.instance }}"

          # ====================================================== resources ==
          - name: resources
            rules:
              - alert: RootFilesystemFilling
                expr: >-
                  100 * (1 - node_filesystem_avail_bytes{mountpoint="/",fstype!~"tmpfs|ramfs|overlay"}
                  / node_filesystem_size_bytes{mountpoint="/",fstype!~"tmpfs|ramfs|overlay"}) > 80
                for: 30m
                labels:
                  severity: critical
                annotations:
                  summary: "root is {{ $value | printf \"%.0f\" }}% full on {{ $labels.instance }}"
                  description: >-
                    architecture.md:281. A full root disk means no more deploys
                    AND no more rollbacks. nix.settings.min-free should have
                    garbage-collected before this fired, so if it did fire,
                    something is writing that Nix does not own.

              - alert: BootPartitionFilling
                expr: >-
                  100 * (1 - node_filesystem_avail_bytes{mountpoint="/boot"}
                  / node_filesystem_size_bytes{mountpoint="/boot"}) > 75
                for: 30m
                labels:
                  severity: critical
                annotations:
                  summary: "the ESP is {{ $value | printf \"%.0f\" }}% full on {{ $labels.instance }}"
                  description: >-
                    1 GB, ten generations, a kernel and an initrd each. A full
                    ESP breaks the bootloader install, which breaks gate 3 —
                    the net that catches a generation that will not boot.
                    Lower boot.loader.systemd-boot.configurationLimit.

              - alert: MemoryAlmostExhausted
                expr: 100 * node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < 10
                for: 15m
                labels:
                  severity: warning
                annotations:
                  summary: "{{ $labels.instance }} has {{ $value | printf \"%.0f\" }}% memory available"
                  description: >-
                    7.6 GB, and comin evaluates this flake on the box at
                    1.5-3 GB. Sustained pressure is how a global OOM becomes
                    possible, and a global OOM is the one path by which a
                    workload can reach tailscaled.

              - alert: KernelOomKilled
                expr: increase(node_vmstat_oom_kill[30m]) > 0
                labels:
                  severity: critical
                annotations:
                  summary: "the kernel OOM-killed something on {{ $labels.instance }}"
                  description: >-
                    Find out what, immediately: journalctl -k | grep -i
                    "out of memory". The OOMScoreAdjust ladder (tailscaled and
                    sshd at -900, Immich at 500, monitoring at 800) is designed
                    so the answer is never tailscaled. Confirm that it wasn't.

              - alert: FilesystemReadOnly
                expr: node_filesystem_readonly{mountpoint=~"/|/mnt/storage"} == 1
                for: 5m
                labels:
                  severity: critical
                annotations:
                  summary: "{{ $labels.mountpoint }} has gone read-only on {{ $labels.instance }}"
                  description: >-
                    errors=remount-ro did its job, which means the underlying
                    device threw an I/O error. On / this is a dying NVMe.

          # ======================================================== services ==
          - name: services
            rules:
              - alert: SystemdUnitFailed
                expr: node_systemd_unit_state{state="failed"} == 1
                for: 15m
                labels:
                  severity: warning
                annotations:
                  summary: "{{ $labels.name }} is failed on {{ $labels.instance }}"
                  description: >-
                    Warning, never critical, and deliberately so. Gate 4 counts
                    failed units but never escalates on them: a broken Immich
                    must not reboot the box.

              - alert: WatchedServiceDown
                expr: >-
                  node_systemd_unit_state{state="active",
                  name=~"comin.service|postgresql.service|tsidp.service|immich-server.service|tailscaled-immich.service|tailscaled-grafana.service|grafana.service|prometheus.service"} == 0
                for: 10m
                labels:
                  severity: warning
                annotations:
                  summary: "{{ $labels.name }} is not active on {{ $labels.instance }}"
                  description: >-
                    The named workloads. A unit that is not deployed produces
                    no series and therefore no alert, which is what lets this
                    list name every stage of hosts/hong-kong/services.nix
                    without the un-imported ones crying wolf.

              - alert: ServiceRestartLoop
                expr: increase(node_systemd_service_restart_total[30m]) > 5
                labels:
                  severity: warning
                annotations:
                  summary: "{{ $labels.name }} has restarted {{ $value }} times in 30 minutes on {{ $labels.instance }}"
                  description: >-
                    Flapping, not down, which is the failure that hides from a
                    liveness check. Needs
                    --collector.systemd.enable-restarts-metrics in
                    modules/observability-node.nix; if that flag was removed
                    this rule is silent rather than wrong.

          # ========================================================= storage ==
          - name: storage
            rules:
              - alert: MediaArrayNotMounted
                expr: >-
                  absent(node_filesystem_size_bytes{mountpoint="/mnt/storage"})
                  and on () (sum(up{job="node"}) > 0)
                for: 15m
                labels:
                  severity: warning
                annotations:
                  summary: "the 7 TB array is not mounted on hong-kong"
                  description: >-
                    WARNING, NOT CRITICAL, and that is the whole design:
                    hosts/hong-kong/storage.nix mounts it `nofail` so that an
                    enclosure dropping off degrades Immich and nothing else.
                    Immich will refuse to start rather than write a library to
                    the root SSD. The `and on ()` guard means a dead node
                    exporter reads as "unknown", not as "the disk is gone".

              - alert: MediaArrayFilling
                expr: >-
                  100 * (1 - node_filesystem_avail_bytes{mountpoint="/mnt/storage"}
                  / node_filesystem_size_bytes{mountpoint="/mnt/storage"}) > 90
                for: 1h
                labels:
                  severity: warning
                annotations:
                  summary: "the array is {{ $value | printf \"%.0f\" }}% full"
                  description: >-
                    Photographs plus the nightly pg_dump under
                    /mnt/storage/immich/backups. Nothing on the boot path
                    depends on this disk.
      ''
    ];
  };

  # ---------------------------------------------------------------- memory ---
  # The whole observability stack in one slice, so it is capped as a unit and
  # cannot be argued about component by component. Grafana joins it in
  # ./dashboard.nix.
  #
  # The budget it has to fit into, on 7.6 GB: base OS ~1 GB, Postgres ~0.5 GB,
  # redis ~0.1 GB, the Immich slice up to 3 GB, and a comin evaluation of this
  # flake at 1.5-3 GB. That is already oversubscribed at the peak, which the
  # design accepts and manages with the OOMScoreAdjust ladder rather than by
  # pretending. Monitoring gets 1 GB, and is the first thing the kernel takes.
  #
  # MemoryHigh brakes with reclaim pressure and no kill; MemoryMax kills. An
  # in-cgroup kill of Prometheus is bounded and boring — it restarts, and the
  # TSDB replays its WAL. Exactly the trade immich.nix makes.
  systemd.slices.system-observability.sliceConfig = {
    MemoryHigh = "768M";
    MemoryMax = "1G";
    MemorySwapMax = "512M";
    CPUWeight = 10;  # loses to everything else in system.slice
    IOWeight = 10;
  };

  systemd.services.prometheus.serviceConfig = {
    Slice = "system-observability.slice";
    # Above Immich's 500. Under global pressure the order the kernel should
    # pick is: monitoring, then the photo library, then — never — the way in.
    OOMScoreAdjust = 800;
    Nice = 10;
  };
}
