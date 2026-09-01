# hosts/hong-kong/identity.nix — who you are, and how you reach Immich at all.
#
# Two things live here, and they are separate on purpose:
#
#   tsidp                    an OIDC identity provider for the tailnet, on its
#                            own tsnet node at idp.shark-kitefin.ts.net
#   tailscale-serve-immich   the front door, publishing Immich on this node's
#                            own name over HTTPS, with no reverse proxy and no
#                            open port. architecture.md:217 already chose this.
#
# ---------------------------------------------------------------------------
# WHY tsidp GETS ITS OWN TSNET NODE
#
# services.tsidp.settings.useLocalTailscaled = true would avoid needing an auth
# key. Read what it costs. The module runs tsidp with DynamicUser = true and
# ProtectSystem = "strict"; useLocalTailscaled then grants that service
# ReadWritePaths on /var/lib/tailscale and BindPaths on /var/run/tailscale.
# That is write access to the state of the one daemon that is your only way
# back into a machine 9,000 km away, handed to a binary at version 0.0.12
# whose own README opens with "[!CAUTION] This is an experimental update ...
# may experience breaking changes". It would also want port 443 on this node,
# which is where Immich is served from.
#
# So: its own tsnet node, registered with a TAGGED auth key. Tagged is not
# cosmetic — tagged devices do not expire, and a node key that lapses 180 days
# from now on an unreachable machine is a time bomb.
#
# ---------------------------------------------------------------------------
# WHAT THE TAILNET POLICY ACTUALLY NEEDS
#
# tsidp's README: "Access to the admin UI and dynamic client registration
# endpoints are denied by default." ONLY those two. /authorize, /token and
# /userinfo are open to anything on the tailnet that can reach the node.
#
# So the grant already in tailscale/acl.hujson
#
#     src ["autogroup:admin"]  dst ["tag:container"]
#     app "tailscale.com/cap/tsidp" [{ allow_admin_ui: true, ... }]
#
# is sufficient as it stands, and ordinary users need no grant of their own.
# The node must therefore carry tag:container — that is what the auth key is
# tagged with. Which also means the real access control for Immich logins is
# the plain `acls` rule, not this grant. See the autoRegister note in
# immich.nix.
#
# Optional, once it works: adding
#     "extraClaims": { "immich_role": "admin" }, "includeInUserInfo": true
# to that grant makes your first OIDC login land as an Immich admin. Immich
# only reads the claim at user creation, never afterwards.
#
# The auth key must be: TAGGED tag:container, REUSABLE (so a wiped state dir
# can re-register), NON-EPHEMERAL (an ephemeral node is deleted when it goes
# offline, and the issuer URL has to be stable), and PRE-AUTHORIZED (nothing
# here can wait for a human to click approve).
# ---------------------------------------------------------------------------

{ config, lib, pkgs, ... }:

let
  tailscaleBin = "${config.services.tailscale.package}/bin/tailscale";
  # Reads Immich's port even when ./immich.nix is not imported yet, in which
  # case this is the option default (2283) — the same value. Serving to a port
  # nothing is listening on is a 502, not a failure.
  serveTarget = "http://127.0.0.1:${toString config.services.immich.port}";

  # Explicit PATH, no awk/sed/basename/sort. Operating rule 8.
  serveScript = pkgs.writeShellScript "tailscale-serve-immich" ''
    set -uo pipefail
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.systemd ]}

    # `tailscale serve` is a no-op before the backend is up. Bounded wait: if
    # it runs out, Restart=on-failure has another go in a minute rather than
    # holding a start job open forever.
    i=0
    while [ "$i" -lt 30 ]; do
      if ${tailscaleBin} status --json 2>/dev/null \
         | ${pkgs.jq}/bin/jq -e '.BackendState == "Running"' >/dev/null; then
        break
      fi
      sleep 2
      i=$((i + 1))
    done

    # Idempotent by construction: --bg writes the whole ServeConfig through
    # SetServeConfig, which is a set and not a diff, and tailscaled persists it
    # across reboots on its own. This unit exists so that a REINSTALL gets the
    # front door back without anyone having to remember to type it.
    exec ${tailscaleBin} serve --bg --yes --https=443 ${serveTarget}
  '';
in
{
  # Declared here rather than in ./secrets.nix so that importing this file is
  # all it takes to bring the secret with it.
  sops.secrets.tsidp-env.restartUnits = [ "tsidp.service" ];

  services.tsidp = {
    enable = true;

    # TS_AUTH_KEY=tskey-auth-... , decrypted to /run/secrets by sops-nix.
    # EnvironmentFile is read by PID 1 before the service drops privileges, so
    # 0400 root:root is correct even though tsidp runs as a DynamicUser.
    environmentFile = config.sops.secrets.tsidp-env.path;

    settings = {
      hostName = "idp";           # -> idp.shark-kitefin.ts.net
      port = 443;
      useLocalTailscaled = false; # read the header
      enableFunnel = false;       # nothing here belongs on the public internet
      enableSts = false;          # Immich needs no RFC 8693 token exchange
      logLevel = "info";
    };
  };

  systemd.services.tsidp = {
    # A missing TS_AUTH_KEY is harmless: tsidp prints a login URL and waits.
    # A missing EnvironmentFile is not. systemd fails the unit before exec, and
    # the module's Restart=always with RestartSec=15 never trips systemd's
    # default rate limit of 5 starts per 10s — so you get an infinite
    # four-restarts-a-minute loop into a journal capped at 500 MB.
    #
    # ConditionPathExists SKIPS the unit instead of failing it, which is the
    # right shape here: no IdP is a degraded login, not a broken machine.
    unitConfig.ConditionPathExists = config.sops.secrets.tsidp-env.path;

    serviceConfig.RestartSec = lib.mkForce "60s";
    serviceConfig.MemoryMax = "256M";

    # The lesson of 2026-08-31, applied to the second thing on this box that
    # dials the coordination server: do not start before the network is up.
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
  };

  # ---------------------------------------------------- the front door ------
  # No reverse proxy, no open port, no certificate management. Requires
  # MagicDNS and HTTPS Certificates enabled in the tailnet admin console — the
  # same prerequisite tsidp has.
  #
  # Runs as root, so services.tailscale.permitCertUid is not needed; that
  # option exists for non-root callers of `tailscale cert`.
  #
  # No conflict with this box also being an exit node: serve binds the node's
  # own 100.x address on 443, which arrives on tailscale0 and is already in
  # networking.firewall.trustedInterfaces. Exit-node traffic is forwarded IP
  # and never reaches this listener.
  systemd.services.tailscale-serve-immich = {
    description = "Publish Immich on the tailnet over HTTPS (tailscale serve)";

    after = [ "tailscaled.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    requires = [ "tailscaled.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = serveScript;
      # Allowed for oneshot; only `always` and `on-success` are rejected.
      Restart = "on-failure";
      RestartSec = "60s";
      # Type=oneshot disables TimeoutStartSec by default. The wait loop above
      # is bounded, but do not rely on that alone.
      TimeoutStartSec = "120s";
    };

    # Deliberately NO ExecStop calling `tailscale serve reset`: a unit restart
    # during a deploy would otherwise briefly take the front door away.
  };
}
