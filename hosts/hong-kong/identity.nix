# hosts/hong-kong/identity.nix — who you are, and how you reach Immich at all.
#
# Just tsidp now: an OIDC identity provider for the tailnet, on its own tsnet
# node at idp.shark-kitefin.ts.net.
#
# The front door used to live here too, as a `tailscale serve` on THIS node's
# name. It moved to ./frontdoor.nix on 2026-09-01, when Immich was given its
# own tailnet node so it could answer to immich.shark-kitefin.ts.net rather
# than hong-kong.shark-kitefin.ts.net. That file's header explains why a name
# means a node, and how a second tailscaled is kept away from the real one.
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
      # -> idp.shark-kitefin.ts.net, and therefore the OIDC ISSUER, which
      # immich.nix pins. But this is a REQUEST, not an assertion: if a node
      # named `idp` already exists, the coordination server answers `idp-1`
      # and the issuer silently moves with it. Happened on 2026-09-01; cost
      # nothing then only because no OIDC client existed yet. So before ever
      # wiping /var/lib/private/tsidp or reinstalling this box, delete the old
      # node in the admin console first, then check:
      #     journalctl -u tsidp | grep server_url
      # Full write-up under "THE NAME COLLISION LANDMINE" in tech-debt.md.
      hostName = "idp";
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

}
