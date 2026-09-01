# hosts/hong-kong/grafana-frontdoor.nix — Grafana on its own tailnet name.
#
#   https://grafana.shark-kitefin.ts.net  ->  127.0.0.1:3000
#
# ---------------------------------------------------------------------------
# THIS FILE IS A DELIBERATE NEAR-COPY OF ./frontdoor.nix
#
# READ THAT FILE'S HEADER FIRST. Every argument in it applies here unchanged:
# why a distinct name means a distinct NODE (MagicDNS has no CNAMEs, and
# `tailscale serve` publishes on the serving node's own name); why the second
# daemon is run with --tun=userspace-networking, --accept-dns=false,
# --accept-routes=false and --port=0; and why its state and LocalAPI socket are
# kept somewhere the real tailscaled cannot be reached from. Those flags are
# not stylistic. They are what stops a third daemon speaking to the same
# coordination server from taking out the one that is your only way home.
#
# Two files now share ~80 lines of that shape, and a third would be too many.
# The duplication is recorded in tech-debt.md ("two hand-rolled tsnet front
# doors") together with the factoring that should replace it. It is not done
# here because ./frontdoor.nix is deployed, working code that carries
# Immich, and refactoring it is a change to Immich's reachability wearing the
# costume of a tidy-up.
#
# What this file does NOT copy is the copy-paste hazard. Everything that
# distinguishes the two — socket, state directory, unit names, MagicDNS name —
# is derived from the single `name` binding below, in the same spirit as
# mediaLocation in ./immich.nix. Aiming this file's `tailscale` calls at the
# IMMICH daemon by forgetting to change a path is structurally impossible
# rather than merely unlikely.
#
# ---------------------------------------------------------------------------
# WHY GRAFANA GETS A NODE AT ALL, WHEN hong-kong's OWN 443 IS FREE
#
# It is free — Immich vacated it on 2026-09-01. Serving Grafana from
# hong-kong.shark-kitefin.ts.net would cost no memory and no second identity,
# and that is a real argument. The name is the reason not to: hong-kong is the
# machine, the exit node and the SSH target, and hanging a web UI off it means
# every later service needs a path prefix and an OAuth redirect that is a
# subdirectory of the box you SSH into. Immich was moved off exactly that
# arrangement a day earlier. Do not move monitoring onto it.
#
# ---------------------------------------------------------------------------
# FAILURE MODE, BY DESIGN
#
# If this file's units are down, the dashboard is unreachable and NOTHING ELSE
# IS. Prometheus keeps scraping, keeps evaluating rules and keeps its history;
# you get at it with the SSH tunnel documented in ./metrics.nix. The box still
# boots, tailscaled still runs, sshd still answers, and gate 4 in
# modules/boot-verdict.nix checks neither unit.
#
# PREREQUISITE, same as tsidp and Immich: MagicDNS and HTTPS Certificates both
# enabled in the admin console. The first TLS handshake on a new name can take
# a few minutes while the certificate issues.
#
# NAME COLLISION: `--hostname=grafana` is a REQUEST. If a node called `grafana`
# already exists the coordination server answers `grafana-1`, every URL below
# is silently wrong, and — because Grafana's OAuth redirect URI is registered
# with tsidp against the name — login breaks in a way that looks like an IdP
# fault. Before wiping /var/lib/tailscale-grafana, delete the old node in the
# admin console first, then check:
#     journalctl -u tailscaled-grafana | grep -i "AuthURL\|Machine\|name"
# The full write-up is "THE NAME COLLISION LANDMINE" in tech-debt.md.
# ---------------------------------------------------------------------------

{ config, lib, pkgs, ... }:

let
  # THE SINGLE SOURCE OF TRUTH. Everything below is derived from it, so this
  # file cannot be pointed at another node's socket or state by accident.
  name = "grafana";

  tailscalePkg = config.services.tailscale.package;

  stateDir = "/var/lib/tailscale-${name}";
  runDir   = "/run/tailscale-${name}";
  sock     = "${runDir}/tailscaled.sock";

  daemonUnit = "tailscaled-${name}";
  doorUnit   = "${name}-front-door";

  # Bundling the socket into the name makes it impossible to forget and
  # accidentally reconfigure the real tailscaled — or Immich's.
  ts = "${tailscalePkg}/bin/tailscale --socket=${sock}";

  # Read from the module so the two cannot drift. Defaults to 3000 even when
  # ./dashboard.nix is not imported, so this file always evaluates.
  serveTarget =
    "http://127.0.0.1:${toString config.services.grafana.settings.server.http_port}";

  # The same key ./frontdoor.nix uses: TAGGED tag:container, REUSABLE,
  # NON-EPHEMERAL, PRE-AUTHORIZED. Tagged is what makes the node never expire.
  authKey = config.sops.secrets.tailscale-authkey.path;

  # Explicit PATH, no awk/sed/basename. Operating rule 8.
  frontDoorScript = pkgs.writeShellScript doorUnit ''
    set -uo pipefail
    export PATH=${lib.makeBinPath [ pkgs.coreutils ]}

    # The daemon is Requires=/After= this unit, but "started" is not the same
    # as "the LocalAPI socket exists". Bounded wait, then fail and let
    # Restart=on-failure try again in a minute.
    i=0
    while [ ! -S ${sock} ]; do
      if [ "$i" -ge 60 ]; then
        echo "${doorUnit}: ${sock} never appeared; giving up for now"
        exit 1
      fi
      sleep 1
      i=$((i + 1))
    done

    # Idempotent: on an already-registered node this is a no-op re-up and the
    # auth key is ignored. file: reads the key from disk so it never appears
    # in a process argument list.
    ${ts} up \
      --auth-key=file:${authKey} \
      --hostname=${name} \
      --accept-dns=false \
      --accept-routes=false

    # `serve` is a no-op before the backend is Running.
    i=0
    while [ "$i" -lt 60 ]; do
      if ${ts} status --json 2>/dev/null \
         | ${pkgs.jq}/bin/jq -e '.BackendState == "Running"' >/dev/null; then
        break
      fi
      sleep 2
      i=$((i + 1))
    done

    # --bg writes the whole ServeConfig through SetServeConfig — a set, not a
    # diff — and tailscaled persists it. This unit exists so a REINSTALL gets
    # the dashboard back with nobody having to remember to type it.
    exec ${ts} serve --bg --yes --https=443 ${serveTarget}
  '';
in
{
  # A front door in front of nothing is a 502 with a valid certificate. Same
  # reasoning as the assertion in ./dashboard.nix.
  assertions = [
    {
      assertion = config.services.grafana.enable;
      message = ''
        hosts/hong-kong/grafana-frontdoor.nix publishes 127.0.0.1:3000 on the
        tailnet, but no Grafana is enabled. Import ./dashboard.nix alongside
        this file.
      '';
    }
  ];

  sops.secrets.tailscale-authkey.restartUnits = [ "${doorUnit}.service" ];

  # ------------------------------------------------- the third daemon ------
  systemd.services.${daemonUnit} = {
    description = "tailscaled for the ${name} tsnet node (userspace networking)";

    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      ExecStart = lib.concatStringsSep " " [
        "${tailscalePkg}/bin/tailscaled"
        "--tun=userspace-networking"
        "--socket=${sock}"
        "--statedir=${stateDir}"
        "--port=0"
      ];

      # NOT decoration. --statedir does not cover logpolicy: tailscaled reads
      # $STATE_DIRECTORY for its log configuration and otherwise falls back to
      # a hardcoded /var/lib/tailscale — the REAL daemon's directory. systemd's
      # StateDirectory= is what exports it. Learned on 2026-09-01 and recorded
      # in tech-debt.md; confirm with
      #     journalctl -u tailscaled-grafana | grep logpolicy
      # which must name /var/lib/tailscale-grafana, not /var/lib/tailscale.
      RuntimeDirectory = "tailscale-${name}";
      StateDirectory = "tailscale-${name}";
      StateDirectoryMode = "0700";

      Restart = "on-failure";
      RestartSec = "60s";
      # Do not let a third Tailscale hiccup delay boot, same as the first two.
      TimeoutStartSec = "30s";

      MemoryMax = "192M";
      # The real tailscaled is -900 and Immich's front door is 300. This one
      # carries monitoring, so it should die before either of them.
      OOMScoreAdjust = 800;
    };
  };

  # ----------------------------------------------------- the front door ----
  systemd.services.${doorUnit} = {
    description = "Publish Grafana at ${name}.shark-kitefin.ts.net";

    after = [ "${daemonUnit}.service" ];
    requires = [ "${daemonUnit}.service" ];
    wantedBy = [ "multi-user.target" ];

    # No key, no registration. SKIP the unit rather than fail it: no dashboard
    # is a degraded machine, not a broken one. Same reasoning as the
    # ConditionPathExists on tsidp in ./identity.nix.
    unitConfig.ConditionPathExists = authKey;

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = frontDoorScript;
      # Allowed for oneshot; only `always` and `on-success` are rejected.
      Restart = "on-failure";
      RestartSec = "60s";
      # Type=oneshot disables TimeoutStartSec by default. The waits above are
      # bounded, but do not rely on that alone.
      TimeoutStartSec = "300s";
    };

    # Deliberately NO ExecStop calling `serve reset`: a unit restart during a
    # deploy would otherwise briefly take the dashboard away.
  };
}
