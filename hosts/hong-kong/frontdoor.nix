# hosts/hong-kong/frontdoor.nix — Immich on its own tailnet name.
#
#   https://immich.shark-kitefin.ts.net  ->  127.0.0.1:2283
#
# ---------------------------------------------------------------------------
# WHY THIS IS NOT JUST `tailscale serve` ON THIS NODE
#
# It used to be. architecture.md:217 sets out the pattern — `tailscale serve`
# for HTTPS on the tailnet, no reverse proxy and no open port — and that part
# still stands; this file keeps it. What changes is only WHICH NODE serves.
# `tailscale serve` publishes on the node's OWN MagicDNS name, so Immich was
# reachable at
# hong-kong.shark-kitefin.ts.net. There is no alias mechanism to change that:
# MagicDNS has no CNAMEs, and a name in the ts.net zone belongs to a node.
#
# So a distinct name means a distinct NODE. hong-kong itself cannot be renamed
# — it is the machine, it is an exit node, and its name is how you SSH to it.
#
# modules/tailscale-node.nix argues against exactly this, and is worth reading
# before changing anything here: a second Tailscale identity costs "a second
# identity, a second key to rotate, a state volume and NET_ADMIN for no gain."
# Three of those four still apply. What has changed is the last one: there IS
# a gain now, and it is the name. NET_ADMIN is the one cost we do not pay —
# see below.
#
# ---------------------------------------------------------------------------
# HOW THIS IS KEPT AWAY FROM THE REAL tailscaled
#
# THE PRIME DIRECTIVE OF THIS BOX is that tailscaled and sshd are the only
# ways back into a machine 9,000 km away. A second daemon speaking to the same
# coordination server is the sort of thing that takes out the first one. Every
# flag below exists to make that impossible:
#
#   --tun=userspace-networking   No TUN device, so no NET_ADMIN, no route
#                                table entries, no interference with the exit
#                                node. It cannot touch the host's networking
#                                because it never enters the kernel's.
#
#   --accept-dns=false           THE IMPORTANT ONE. tailscaled manages
#                                /etc/resolv.conf. On 2026-08-31 this box was
#                                left able to resolve *.ts.net and nothing
#                                else, and that was ONE daemon getting DNS
#                                wrong. A second daemon writing resolv.conf
#                                would be the same failure with two authors.
#                                It must never do so.
#
#   --accept-routes=false        Advertised subnet routes are the first
#                                daemon's business, not this one's.
#
#   --port=0                     Ephemeral WireGuard port. The default is
#                                41641, which the real tailscaled already has.
#
#   --statedir / --socket        Its own state and its own LocalAPI socket,
#                                under /var/lib/tailscale-immich and
#                                /run/tailscale-immich. It has no path to the
#                                real daemon's state — which is precisely the
#                                objection identity.nix raises against
#                                tsidp's useLocalTailscaled.
#
# And if memory ever gets tight: OOMScoreAdjust is positive here and -900 on
# the real tailscaled, so the kernel reaches for this one first, by a mile.
#
# ---------------------------------------------------------------------------
# FAILURE MODE, BY DESIGN
#
# If this file's units are down, Immich is unreachable but NOTHING ELSE IS.
# The box still boots, tailscaled still runs, sshd still answers, and gate 4
# in modules/boot-verdict.nix does not check either unit. That is the correct
# blast radius for a front door.
#
# The auth key must be TAGGED tag:container, REUSABLE, NON-EPHEMERAL and
# PRE-AUTHORIZED — the same four properties identity.nix needs, for the same
# four reasons. It is the same key.
#
# NAME COLLISION: read the warning at services.tsidp.settings.hostName in
# ./identity.nix. It applies here identically. `--hostname=immich` is a
# REQUEST; if a node called `immich` already exists, this one silently becomes
# `immich-1` and every URL below is wrong. Before wiping
# /var/lib/tailscale-immich, delete the old node in the admin console first.
# ---------------------------------------------------------------------------

{ config, lib, pkgs, ... }:

let
  tailscalePkg = config.services.tailscale.package;

  stateDir = "/var/lib/tailscale-immich";
  sock     = "/run/tailscale-immich/tailscaled.sock";

  # Every CLI call in this file must be aimed at the SECOND daemon. Bundling
  # the socket into the name makes it impossible to forget and accidentally
  # reconfigure the real one.
  ts = "${tailscalePkg}/bin/tailscale --socket=${sock}";

  # Immich's port, read from the module so the two cannot drift.
  serveTarget = "http://127.0.0.1:${toString config.services.immich.port}";

  authKey = config.sops.secrets.tailscale-authkey.path;

  # Explicit PATH, no awk/sed/basename. Operating rule 8.
  frontDoorScript = pkgs.writeShellScript "immich-front-door" ''
    set -uo pipefail
    export PATH=${lib.makeBinPath [ pkgs.coreutils ]}

    # The daemon is Requires=/After= this unit, but "started" is not the same
    # as "the LocalAPI socket exists". Bounded wait, then fail and let
    # Restart=on-failure try again in a minute.
    i=0
    while [ ! -S ${sock} ]; do
      if [ "$i" -ge 60 ]; then
        echo "immich-front-door: ${sock} never appeared; giving up for now"
        exit 1
      fi
      sleep 1
      i=$((i + 1))
    done

    # Idempotent: on an already-registered node this is a no-op re-up, and the
    # auth key is ignored. file: reads the key from disk so it never appears
    # in a process argument list.
    ${ts} up \
      --auth-key=file:${authKey} \
      --hostname=immich \
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
    # the front door back with nobody having to remember to type it.
    exec ${ts} serve --bg --yes --https=443 ${serveTarget}
  '';
in
{
  sops.secrets.tailscale-authkey.restartUnits = [ "immich-front-door.service" ];

  # ------------------------------------------------- the second daemon ------
  systemd.services.tailscaled-immich = {
    description = "tailscaled for the immich tsnet node (userspace networking)";

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

      RuntimeDirectory = "tailscale-immich";
      StateDirectory = "tailscale-immich";
      StateDirectoryMode = "0700";

      Restart = "on-failure";
      RestartSec = "60s";
      # Do not let a second Tailscale hiccup delay boot, same as the first.
      TimeoutStartSec = "30s";

      MemoryMax = "192M";
      # The real tailscaled is -900. This one should die long before it.
      OOMScoreAdjust = 300;
    };
  };

  # ------------------------------------------------------- the front door ---
  systemd.services.immich-front-door = {
    description = "Publish Immich at immich.shark-kitefin.ts.net";

    after = [ "tailscaled-immich.service" ];
    requires = [ "tailscaled-immich.service" ];
    wantedBy = [ "multi-user.target" ];

    # No key, no registration. Skip the unit rather than fail it: no front
    # door is a degraded machine, not a broken one. Same reasoning as the
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
    # deploy would otherwise briefly take the front door away.
  };
}
