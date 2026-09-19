# hosts/hong-kong/frontdoors.nix — tailnet names for compose apps.
#
# `x-fleet: {frontdoor: rallly}` and the app answers at
# https://rallly.shark-kitefin.ts.net, on the tailnet, with a real certificate
# and no open port.
#
# This is the GENERALISATION of ./frontdoor.nix (Immich) and
# ./grafana-frontdoor.nix. Those two stay hand-written: their targets come from
# NixOS module options rather than a compose file, and rewriting working
# front doors for two services to save duplication is a bad trade on a machine
# nobody can walk up to. READ ./frontdoor.nix FIRST — its header is the full
# argument for every flag below, and it is not repeated here.
#
# ---------------------------------------------------------------------------
# WHY A NODE PER APP AND NOT A PATH
#
# `tailscale serve` publishes on the serving node's OWN MagicDNS name, and
# ts.net has no CNAMEs. A distinct name is therefore a distinct NODE — there is
# no aliasing mechanism to borrow. hong-kong itself cannot be reused: it is the
# machine, it is an exit node, and its name is how you SSH in.
#
# THE COST IS REAL AND WORTH STATING. Each app here adds a tailscaled process,
# a state directory, a device in the admin console and an auth-key rotation.
# Immich, tsidp and Grafana already have one each; this file adds one per
# exposed app on top. On a 7.6 GB box that is not free, which is why the memory
# cap below is small and the OOM score is high.
#
# ---------------------------------------------------------------------------
# HOW THESE ARE KEPT AWAY FROM THE REAL tailscaled
#
# THE PRIME DIRECTIVE: tailscaled and sshd are the only ways back into a
# machine 9,000 km away. Every flag below exists to make a second daemon
# incapable of disturbing the first — userspace networking so there is no TUN
# and no NET_ADMIN, `--accept-dns=false` because DNS on this box must have
# exactly one author, `--accept-routes=false`, `--port=0`, and its own state
# directory and socket. ./frontdoor.nix explains each at length.
#
# NAME COLLISION, and it has already happened once. `--hostname=X` is a
# REQUEST. If a node called X already exists, this one silently becomes `X-1`
# and every URL is wrong with nothing logged as an error. tech-debt.md:292 and
# progress-log.md:370 are the 2026-09-01 incident where `idp` did exactly this.
# Before wiping a state directory, DELETE THE OLD NODE in the admin console
# first.
#
# ---------------------------------------------------------------------------
# FAILURE MODE, BY DESIGN
#
# If these units are down, the apps are unreachable BY NAME and nothing else
# is. The box boots, the real tailscaled runs, sshd answers, and gate 4 in
# modules/boot-verdict.nix checks none of them. Note the asymmetry that
# follows: an app with `x-fleet.public` stays reachable by strangers while
# being unreachable by you. That is correct — the two doors are independent on
# purpose — but it is worth knowing before debugging one through the other.
#
# ---------------------------------------------------------------------------
# THE AUTH KEY
#
# The same `tailscale-authkey` ./frontdoor.nix and ./identity.nix use, with the
# same four required properties: TAGGED tag:container, REUSABLE,
# NON-EPHEMERAL, PRE-AUTHORIZED. Tagged matters most — tagged devices do not
# expire, and an expired key on a node nobody can reach is an outage with no
# remedy.
#
# No key, no registration: each unit is skipped by ConditionPathExists rather
# than failed. A missing front door is a degraded machine, not a broken one.
# ---------------------------------------------------------------------------

{ config, lib, pkgs, ... }:

let
  tailscalePkg = config.services.tailscale.package;
  authKey = config.sops.secrets.tailscale-authkey.path;

  # Apps that asked for a tailnet name AND have a target to point at. Anything
  # that failed validation in ./apps.nix never reaches here — same reasoning as
  # `servedApps` in ./public.nix: an assertion promises the build stops, this
  # guarantees the unit is never constructed.
  doors = lib.filterAttrs (_: a: a.frontdoor != null && a.target != null) config.fleet.apps;

  mkDoor =
    _stem: app:
    let
      name = app.frontdoor;
      stateDir = "/var/lib/tailscale-${name}";
      sock = "/run/tailscale-${name}/tailscaled.sock";

      # Bundling the socket into the name makes it impossible to forget and
      # accidentally reconfigure the REAL daemon. ./frontdoor.nix does the same.
      ts = "${tailscalePkg}/bin/tailscale --socket=${sock}";

      script = pkgs.writeShellScript "${name}-front-door" ''
        set -uo pipefail
        export PATH=${lib.makeBinPath [ pkgs.coreutils ]}

        # "Started" is not the same as "the LocalAPI socket exists". Bounded
        # wait, then fail and let Restart=on-failure try again in a minute.
        i=0
        while [ ! -S ${sock} ]; do
          if [ "$i" -ge 60 ]; then
            echo "${name}-front-door: ${sock} never appeared; giving up for now"
            exit 1
          fi
          sleep 1
          i=$((i + 1))
        done

        # Idempotent: on an already-registered node this is a no-op re-up and
        # the auth key is ignored. file: keeps the key out of the process
        # argument list.
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

        # --bg writes the whole ServeConfig through SetServeConfig — a set, not
        # a diff — and tailscaled persists it. This unit exists so a REINSTALL
        # restores the front door with nobody having to remember to type it.
        exec ${ts} serve --bg --yes --https=443 ${app.target}
      '';
    in
    {
      "tailscaled-${name}" = {
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

          RuntimeDirectory = "tailscale-${name}";
          StateDirectory = "tailscale-${name}";
          StateDirectoryMode = "0700";

          Restart = "on-failure";
          RestartSec = "60s";
          TimeoutStartSec = "30s";

          MemoryMax = "192M";
          # The real tailscaled is -900. This one should die long before it.
          OOMScoreAdjust = 300;
        };
      };

      "${name}-front-door" = {
        description = "Publish ${app.service} at ${name}.shark-kitefin.ts.net";

        after = [ "tailscaled-${name}.service" "podman-${app.service}.service" ];
        requires = [ "tailscaled-${name}.service" ];
        wantedBy = [ "multi-user.target" ];

        # Skip rather than fail: no key means no front door, which is degraded,
        # not broken. Same reasoning as the ConditionPathExists on tsidp.
        unitConfig.ConditionPathExists = authKey;

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = script;
          Restart = "on-failure";
          RestartSec = "60s";
          # Type=oneshot disables TimeoutStartSec by default. The waits above
          # are bounded, but do not rely on that alone.
          TimeoutStartSec = "300s";
        };

        # Deliberately NO ExecStop calling `serve reset`: a unit restart during
        # a deploy would otherwise briefly take the front door away.
      };
    };
in
{
  assertions = [
    {
      # `Wants=` on podman-<service> is deliberately absent — a front door
      # should come up and wait rather than drag a container with it — but the
      # After= above names the unit, so the app must actually exist.
      assertion = config.virtualisation.podman.enable;
      message = ''
        hosts/hong-kong/frontdoors.nix publishes compose apps on the tailnet,
        and no container runtime is enabled. Import ./podman.nix and ./apps.nix
        alongside it.
      '';
    }
  ];

  # Declared here so that importing this file brings its secret with it — the
  # same principle ./immich.nix follows. Note ./frontdoor.nix declares the SAME
  # secret; sops-nix merges the two declarations and the restartUnits lists
  # concatenate, which is what we want.
  sops.secrets.tailscale-authkey.restartUnits = lib.mapAttrsToList (
    _: a: "${a.frontdoor}-front-door.service"
  ) doors;

  systemd.services = lib.foldl' lib.recursiveUpdate { } (lib.mapAttrsToList mkDoor doors);
}
