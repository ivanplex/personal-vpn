# hosts/hong-kong/public.nix — the public internet, and only that.
#
# One `x-fleet: {public: test.ivanchan.me}` in a compose file and that app is
# on the internet under your own domain. Nothing else in this repository
# publishes anything publicly, so this file is the complete answer to "what
# can strangers reach?"
#
#     grep -rn 'public:' hosts/hong-kong/apps/
#
# ---------------------------------------------------------------------------
# THE RULE THIS FILE EXISTS TO ENFORCE
#
#   The only thing reachable from the internet is an app that says so in its
#   own compose file. Not a port. Not a path. Not a typo.
#
# cloudflared runs ON THIS HOST and can therefore reach every loopback service
# on it: Immich on 2283, Prometheus on 9090, Grafana, tsidp. If the ingress
# target were free text, "publish the photo library to the internet" would be
# one mistyped line, deployed by comin within a minute, on a machine 9,000 km
# away.
#
# So it is not free text. `x-fleet.public` takes a HOSTNAME AND NEVER A PORT;
# the target is derived in ./apps.nix from the service's own `ports:` entry and
# handed here finished, as `config.fleet.apps.<app>.target`. Nothing in this
# file parses a port, which is why nothing in this file can get one wrong.
#
# The catch-all is `http_status:404`, always. A catch-all pointing at a service
# would publish that service under every hostname the tunnel answers for,
# including ones added later by mistake.
#
# ---------------------------------------------------------------------------
# WHY A TUNNEL AND NOT TAILSCALE
#
# Evaluated properly on 2026-09-18, because Funnel is the obvious thing to
# reach for on a box that already runs Tailscale, and it does not work here.
#
#   * Funnel serves ONLY <node>.shark-kitefin.ts.net. A CNAME from your own
#     domain resolves, then the browser sends SNI for your name and the relay
#     presents a certificate for the ts.net name. Hard TLS failure. Tailscale
#     cannot issue a certificate for a domain it does not control.
#
#   * The only fix is to front it with Cloudflare and stop validating the
#     origin certificate — at which point you run Cloudflare AND Funnel, two
#     vendors instead of one, and Funnel's end-to-end encryption is gone anyway
#     because Cloudflare terminates TLS. Strictly worse than Cloudflare alone.
#
#   * Funnel offers no WAF, no rate limiting and no DDoS absorption. On this
#     hardware that is the decisive point, not the certificate — see the
#     memory note further down.
#
# Latency was NOT a reason: Tailscale runs a DERP relay in Hong Kong. And
# Funnel remains the better tool anywhere a ts.net URL is acceptable — no new
# vendor, no new credential, and its relays genuinely cannot decrypt. It is the
# custom domain that rules it out.
#
# ---------------------------------------------------------------------------
# WHAT THIS COSTS, HONESTLY
#
#   * CLOUDFLARE SEES PLAINTEXT. They terminate TLS. For a poll scheduler that
#     is an easy trade; do not make it for anything you would not hand them.
#
#   * Cloudflare is now a hard dependency for public access. Not for the
#     tailnet, not for SSH, not for Immich — only for strangers.
#
#   * The tunnel credential can serve content on your domain. It is a secret of
#     the same weight as the Grafana keys, and it lives in sops for the same
#     reason.
#
# WHAT IT BUYS, AND WHY IT IS NOT OPTIONAL HERE
#
# Rate limiting. This box is two cores and 7.6 GB and is already oversubscribed
# at peak (tech-debt.md:632). One aggressive scraper against an unauthenticated
# public app is enough to saturate it — and when memory pressure follows, the
# OOM ladder fires in this order: monitoring at 800 dies FIRST, then Immich at
# 500. The failure mode is losing observability, then the photo library, and
# finding out late because the thing that would have told you died first.
#
# ---------------------------------------------------------------------------
# NATIVE SERVICE, NOT A CONTAINER
#
# cloudflared is the infrastructure that publishes the app mechanism, so it
# must not depend on the app mechanism to run. Exactly the argument
# modules/tailscale-node.nix makes for not containerising tailscaled.
#
# FAILURE MODE, BY DESIGN
#
# If cloudflared is down, strangers cannot reach the apps and NOTHING ELSE
# CHANGES. The box boots, tailscaled runs, sshd answers, Immich and Grafana are
# still there on the tailnet. Gate 4 in modules/boot-verdict.nix checks
# tailscaled, sshd and DNS and counts failed units as information only, so no
# amount of public traffic can reboot this machine or roll it back.
#
# ---------------------------------------------------------------------------
# BOOTSTRAP — the ordering, which is the same shape as the tsidp clients
#
# Not circular: Cloudflare needs nothing from this box. Create the tunnel,
# collect its credentials, then deploy the config that uses them.
#
#   1. Create the tunnel and the DNS records. See ../../cloudflare/README.md —
#      Terraform, exactly as the tailnet policy is.
#
#   2. Put the credentials JSON into sops BEFORE this file is imported on
#      `main`:
#
#          sops secrets/hong-kong.yaml
#          # cloudflared-credentials: |
#          #   {"AccountTag":"...","TunnelID":"...","TunnelSecret":"..."}
#
#      THIS ORDER IS THE RULE, not a suggestion. A declared secret that is
#      missing from the file fails sops-install-secrets during ACTIVATION, and
#      comin neither rolls back nor retries that generation. Same trap the
#      Grafana keys carry in ./services.nix.
#
#   3. Deploy with NO app publishing anything. Confirm the tunnel is healthy
#      and that nothing resolves yet. `zone` and `tunnelName` are set below.
#
#   4. Only then add `x-fleet: {public: ...}` to one app.
# ---------------------------------------------------------------------------

{ config, lib, ... }:

let
  # ---- THE TWO VALUES THAT TIE THIS TO CLOUDFLARE ---------------------------
  # The zone you own. Every `x-fleet.public` hostname must be under it, checked
  # at eval time, so that a typo cannot try to create a record on a domain that
  # is not yours.
  #
  # This is the PARENT domain, not the hostname: `test.ivanchan.me` is an app,
  # `ivanchan.me` is the boundary every app is checked against. Setting it to a
  # single hostname would make the check exact but would need editing for every
  # new app, and editing the boundary to add an app is how boundaries stop
  # meaning anything.
  zone = "ivanchan.me";

  # The Cloudflare tunnel's name, as created in ../../cloudflare/. Must match
  # `tunnel_name` there, or cloudflared starts cleanly and serves nothing —
  # which is a miserable thing to debug, because nothing errors.
  tunnelName = "test-tunnel";
  # ---------------------------------------------------------------------------

  # Only apps that are enabled, passed every assertion in ./apps.nix, AND asked
  # to be public. `target` was derived there from the service's own port — see
  # the rule at the top of this file.
  publicApps = lib.filterAttrs (_: a: a.public != null) config.fleet.apps;

  badZone = lib.filterAttrs (
    _: a: !(lib.hasSuffix ".${zone}" a.public) && a.public != zone
  ) publicApps;

  noTarget = lib.filterAttrs (_: a: a.target == null) publicApps;

  # What is ACTUALLY published. The assertions below already fail the build on
  # everything in badZone and noTarget, so this filter is redundant — and it is
  # here anyway, for the same reason ./apps.nix only translates apps that
  # passed every check.
  #
  # An assertion is a promise that a build will not complete. This is a
  # guarantee that the ingress map cannot contain the hostname in the first
  # place. On the one file in this repository that decides what strangers can
  # reach, those are worth having both of.
  servedApps = builtins.removeAttrs publicApps (lib.attrNames badZone ++ lib.attrNames noTarget);
in
{
  assertions = [
    {
      assertion = config.virtualisation.podman.enable;
      message = ''
        hosts/hong-kong/public.nix publishes containers, and no container
        runtime is enabled. Import ./podman.nix and ./apps.nix alongside it.
      '';
    }
  ]
  ++ lib.mapAttrsToList (stem: a: {
    assertion = false;
    message = ''
      hosts/hong-kong/apps/${a.file}: `x-fleet.public` is `${a.public}`, which
      is not under the zone this host is configured for (`${zone}`).

      Publishing is refused rather than attempted. A hostname on a domain you
      do not own cannot work, and the failure would otherwise appear as a
      Terraform error hours later rather than as a build failure now.

      Fix the hostname, or if the zone itself is wrong, change `zone` at the
      top of hosts/hong-kong/public.nix — there is exactly one place.
    '';
  }) badZone
  ++ lib.mapAttrsToList (stem: a: {
    assertion = false;
    message = ''
      hosts/hong-kong/apps/${a.file}: `x-fleet.public` is set but no loopback
      target could be derived from the service's `ports:` entry.

      This should be unreachable — ./apps.nix asserts exactly one published
      port before it gets here. If you are seeing it, the port is in a form
      hostPortOf in ./apps.nix does not understand, and THAT is the bug. Do not
      work around it by hand-writing a target: deriving it is the only thing
      stopping a typo from publishing Immich.
    '';
  }) noTarget;

  # The credential is declared next to what consumes it, so importing this file
  # brings its secret with it — the same principle immich-oauth-client-secret
  # follows in ./immich.nix. LoadCredential reads it as PID 1 before the unit
  # drops to DynamicUser, so the sops default of 0400 root:root is correct.
  sops.secrets.cloudflared-credentials.restartUnits = [
    "cloudflared-tunnel-${tunnelName}.service"
  ];

  services.cloudflared = {
    enable = true;

    tunnels.${tunnelName} = {
      credentialsFile = config.sops.secrets.cloudflared-credentials.path;

      # hostname -> loopback URL, one entry per app that asked for it. Derived,
      # never typed. An empty set here is a WORKING configuration: the tunnel
      # comes up and answers 404 to everything, which is exactly what stage 1
      # of the bootstrap wants to see.
      ingress = lib.mapAttrs' (_stem: a: lib.nameValuePair a.public a.target) servedApps;

      # Anything not named above. NEVER a service — see the rule at the top.
      default = "http_status:404";
    };
  };

  # --------------------------------------------------------------- limits ---
  # The same treatment every app gets in ./apps.nix, for the same reasons.
  systemd.services."cloudflared-tunnel-${tunnelName}" = {
    unitConfig = {
      # Give up and leave evidence in the journal rather than flail forever, on
      # a machine nobody can walk up to.
      StartLimitIntervalSec = "10min";
      StartLimitBurst = 5;
    };

    serviceConfig = {
      # The ladder: tailscaled -900, Immich 500, monitoring 800. HIGHER means
      # the kernel takes it first. Public access is the most expendable thing
      # on this box — more so than monitoring, which is how you would find out
      # anything was wrong.
      OOMScoreAdjust = 900;

      MemoryHigh = "128M";
      MemoryMax = "256M";
      CPUWeight = 20;
      IOWeight = 20;
    };
  };
}
