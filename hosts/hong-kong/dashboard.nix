# hosts/hong-kong/dashboard.nix — Grafana: the only part of this stack a human
# looks at.
#
# Served at https://grafana.shark-kitefin.ts.net by ./grafana-frontdoor.nix,
# which is a separate file for the same reason ./frontdoor.nix is separate from
# ./immich.nix: revert that one import and the dashboard is unreachable while
# nothing else changes at all.
#
# ---------------------------------------------------------------------------
# THE RULE THIS FILE OBEYS
#
# Grafana is a viewer. It owns no data — Prometheus does — and nothing depends
# on it. If it is down you have lost a convenience, and both the metrics and
# the alert evaluation carry on without it. So it is capped, sliced, and first
# in the queue for the OOM killer, alongside the rest of the stack.
#
# ---------------------------------------------------------------------------
# AUTHENTICATION: TAILSCALE IS THE DEFAULT IdP, AND THE FORM IS HIDDEN
#
# Changed 2026-09-14. Until then this file kept the email/password form on the
# login page as break glass. What follows REPLACES that argument rather than
# abandoning it — read to the end before assuming the escape hatch is gone.
#
# What a browser gets at https://grafana.shark-kitefin.ts.net now:
#
#   * A redirect. /login goes straight to tsidp — that is `auto_login` in the
#     auth.generic_oauth block, which is already running on this box for
#     Immich. You are a tailnet identity by the time you have a route to the
#     node at all, so being asked to type a second one was ceremony. The
#     identity domain is scoped to Admin; anyone else on the tailnet who signs
#     in lands as a Viewer, exactly as before.
#
#   * No email/password fields. auth.disable_login_form does not merely HIDE
#     them. Grafana registers the form password client only when that setting
#     is false — pkg/services/authn/authnimpl/registration.go, the
#     `if !cfg.DisableLoginForm` around ProvideForm — so POST /login stops
#     authenticating too. Hidden and disabled are the same thing here, which
#     is the point: a form that is only invisible is not a smaller attack
#     surface, it is the same one with worse documentation.
#
# BREAK GLASS DID NOT GO AWAY. IT MOVED TO HTTP BASIC.
#
#     curl -u ivan:"$(sops -d --extract '["grafana-admin-password"]' \
#                     secrets/hong-kong.yaml)" \
#          https://grafana.shark-kitefin.ts.net/api/org
#
# That survives the form being disabled because [auth.basic] registers its own
# password client from cfg.BasicAuthEnabled ALONE — five lines up in the same
# file, with no reference to DisableLoginForm — and security.admin_user and
# admin_password below are untouched. The local admin still exists in full;
# only its browser form is gone. It still matters for the reason it always
# did: tsidp is version 0.0.12, its own README opens with a caution about
# breaking changes, the NixOS module runs it with TAILSCALE_USE_WIP_CODE=1,
# and this is the dashboard you would use to diagnose a tsidp outage. Note the
# circularity, which makes this sharper here than it is for Immich.
#
# Basic auth is an API path, not a dashboard you can look at. Nothing makes a
# browser attach the header by itself, and embedding credentials in the URL is
# variously stripped, warned about or refused depending on the browser — so it
# answers "is Grafana alive, and are its users who I think they are", not
# "show me the graphs". For graphs during an outage, escape 2 below.
#
# TWO ESCAPES WHEN TSIDP IS DOWN, IN ORDER OF COST:
#
#   1. https://grafana.shark-kitefin.ts.net/login?disableAutoLogin=true
#      renders the login page instead of bouncing. pkg/api/login.go tests for
#      the PRESENCE of the parameter, so the `=true` is decoration and the
#      bare `?disableAutoLogin` does the same thing. With the form disabled
#      this gets you a page with one button on it — enough to break a redirect
#      loop and read the error, not enough to sign in.
#
#   2. Set `loginFormVisible = true` below and deploy. ONE WORD, in the same
#      spirit as oidcClientId, not a commented-out block. It brings the form
#      back AND turns auto_login off in the same edit, because a form you are
#      redirected past before you can type in it is not a restored form.
#
# auth.anonymous stays OFF. The tailnet ACL in tailscale/acl.hujson is
# currently wide open (`autogroup:member` -> `*:*`), so anonymous access would
# hand every member of the tailnet an unauthenticated seat, and the OIDC path
# already gives them a Viewer one if they want it.
#
# ---------------------------------------------------------------------------
# THE OIDC CLIENT DOES NOT EXIST UNTIL YOU MAKE IT
#
# Same ordering problem Immich had, and the same answer: tsidp issues client
# IDs and secrets as RUNTIME state in /var/lib/tsidp, not as anything Nix can
# declare. So `oidcClientId` below starts as null, which is not a placeholder
# to be tidied up later — it is a working configuration. With it null, Grafana
# deploys with the login form only and no OIDC secret is declared at all, so
# the deploy cannot depend on a secret that has not been created yet.
#
# Fill it in as a SECOND deploy, once tsidp has issued one. One word, not a
# commented-out block. The runbook is stage 7 in ./services.nix.
#
# That staging still works, but since 2026-09-14 it is no longer free: with
# the form hidden, null here would leave nothing to log in with, so going back
# to null means setting loginFormVisible = true in the same commit. The
# assertion below refuses the pair rather than letting you find out at 443.
#
# ---------------------------------------------------------------------------
# BEFORE YOU DEPLOY THIS FILE: THE ADMIN PASSWORD MUST ALREADY BE IN SOPS
#
# `grafana-admin-password` AND `grafana-secret-key` must both exist in
# secrets/hong-kong.yaml BEFORE this import lands. sops-nix does not shrug at
# a declared secret that is missing
# from the file — sops-install-secrets fails, and it fails during ACTIVATION,
# which is a failed deploy. And per tech-debt.md, comin at the pinned revision
# does not roll back and will not retry a generation it has already failed, so
# recovering means a new commit. Read stage 6 of the runbook in ./services.nix
# and do it in the order written.
# ---------------------------------------------------------------------------

{ config, lib, pkgs, ... }:

let
  tailnet = "shark-kitefin.ts.net";
  origin = "https://grafana.${tailnet}";
  issuer = "https://idp.${tailnet}";

  # ---------------------------------------------------------------- OIDC ---
  # null  -> no OIDC and no OIDC secret declared. Only a legal state now
  #          alongside loginFormVisible = true; the assertion below enforces
  #          the pair, because null on its own is a door with no handles.
  # "..." -> the client id tsidp printed when you registered the client.
  # The ID is not a secret; the secret is, and it lives in sops.
  #
  # Registered with tsidp on 2026-09-01 against the single redirect URI
  # https://grafana.shark-kitefin.ts.net/login/generic_oauth. Setting this
  # non-null is what declares grafana-oauth-client-secret AND enables the
  # whole auth.generic_oauth block below — so putting the secret in sops
  # FIRST is the rule here exactly as it was for the admin password.
  oidcClientId = "9876778ac89351d17411795b17fbd444";
  oidcEnabled = oidcClientId != null;

  # ---------------------------------------------------------- login form ---
  # false -> Tailscale is the only way into the UI: no email/password fields,
  #          and /login redirects to tsidp.
  # true  -> the form is back and auto_login is off, from this one word. The
  #          two move together on purpose; see the header.
  #
  # This does NOT delete the local admin. security.admin_user and
  # admin_password below are unchanged, and HTTP Basic against /api still
  # authenticates with them. That is the break-glass path now, and
  # "auth.basic".enabled below is what keeps it open.
  loginFormVisible = false;

  # Who gets Admin. Everybody else who signs in through tsidp gets Viewer.
  #
  # This is the tailnet identity domain, which is NOT the domain on the Immich
  # admin account — that mismatch is what silently produced two Immich accounts
  # on 2026-09-01 (see progress-log.md). Confirm what tsidp actually puts in
  # the `email` claim before trusting this line: sign in, then read
  # Administration -> Users in Grafana.
  #
  # Getting it wrong is cheap: role_attribute_strict is false below, so a
  # non-matching identity becomes a Viewer rather than being refused, and the
  # local admin login is unaffected either way.
  adminEmailDomain = "@whiteboxsoftware.hk";

  # Fixed uid so the provisioned dashboards can name the datasource and keep
  # naming it across rebuilds. Grafana generates a random one otherwise, and
  # every dashboard silently loses its datasource on the next deploy.
  datasourceUid = "fleet-prometheus";
in
{
  # Grafana with no Prometheus is a login page. Refuse to build rather than
  # deploy one, in the same spirit as the storage assertion in ./immich.nix —
  # and because the memory slice this file joins is defined over there.
  assertions = [
    {
      assertion = config.services.prometheus.enable;
      message = ''
        hosts/hong-kong/dashboard.nix has nothing to display: no Prometheus is
        enabled. Import ./metrics.nix alongside this file. It also defines the
        system-observability slice that grafana.service is placed into.
      '';
    }
    {
      # The two knobs are independent, and exactly one combination locks the
      # door from the inside: no form, and no IdP to replace it. It is also
      # the combination you reach by accident, by blanking oidcClientId to
      # take OIDC out of the picture while debugging. Catch it at build time,
      # where the answer is an eval error, rather than at 443, where the
      # answer is a login page with nothing on it.
      assertion = loginFormVisible || oidcEnabled;
      message = ''
        hosts/hong-kong/dashboard.nix has loginFormVisible = false while
        oidcClientId is null: Grafana would come up with no login form and no
        identity provider, which is no way in through a browser at all. Set
        oidcClientId, or set loginFormVisible = true.

        (HTTP Basic on /api would still work, so this is recoverable — but it
        is not a state to deploy on purpose.)
      '';
    }
  ];

  # ------------------------------------------------------------- secrets ---
  # Declared here rather than in ./secrets.nix so that importing this file is
  # all it takes to bring its secrets with it.
  #
  # owner = "grafana" is NOT optional, and it is the one thing here that
  # differs from every other secret in this repo. tsidp's key is read by PID 1
  # as an EnvironmentFile and Immich's through LoadCredential, so both are
  # fine at the sops-nix default of 0400 root:root. Grafana resolves
  # $__file{...} ITSELF, after it has dropped to the grafana user, so the
  # default would give it a file it cannot read and a login it cannot perform.
  sops.secrets = {
    grafana-admin-password = {
      owner = "grafana";
      restartUnits = [ "grafana.service" ];
    };
    grafana-secret-key = {
      owner = "grafana";
      restartUnits = [ "grafana.service" ];
    };
  } // lib.optionalAttrs oidcEnabled {
    grafana-oauth-client-secret = {
      owner = "grafana";
      restartUnits = [ "grafana.service" ];
    };
  };

  # ------------------------------------------------------------- grafana ---
  services.grafana = {
    enable = true;

    settings = {
      server = {
        # 127.0.0.1, NOT "localhost". Go and Node both resolve that name, and
        # a v6-only bind is how ./grafana-frontdoor.nix would get
        # ECONNREFUSED and you would spend an hour debugging a 502. Same trap
        # documented at services.immich.host in ./immich.nix.
        http_addr = "127.0.0.1";
        http_port = 3000;

        # root_url is what Grafana puts in redirects and, critically, what the
        # OIDC redirect URI is built from. It must match the name the browser
        # used, which is the tsnet node in ./grafana-frontdoor.nix — so the URI
        # to register with tsidp is exactly:
        #     https://grafana.shark-kitefin.ts.net/login/generic_oauth
        domain = "grafana.${tailnet}";
        root_url = "${origin}/";
        enforce_domain = false;
      };

      security = {
        # STILL BREAK GLASS, but no longer through the login page — the form
        # is disabled in `auth` below and HTTP Basic on /api is what these two
        # now unlock. Unchanged on 2026-09-14 and not to be removed as dead
        # config: read the header before touching either of them.
        admin_user = "ivan";
        admin_password = "$__file{${config.sops.secrets.grafana-admin-password.path}}";

        # NOT OPTIONAL, and not the same kind of secret as the password.
        # nixpkgs leaves settings.security.secret_key at Grafana's own shipped
        # default — the literal string SW2YcwTIb9zpOOhoPsMm, which is in the
        # manual, on GitHub and in every other Grafana on earth. It signs the
        # remember-me cookie and encrypts secure datasource settings in the
        # database. Combined with the wide-open `acls` rule in
        # tailscale/acl.hujson, leaving it means any tailnet member who can
        # reach the node can mint themselves a session. It also emits a build
        # warning on every CI run, which is its own reason to fix it.
        secret_key = "$__file{${config.sops.secrets.grafana-secret-key.path}}";

        # tailscale serve terminates TLS, so the browser is always on https
        # even though Grafana itself speaks plain http on loopback.
        cookie_secure = true;
        cookie_samesite = "lax";

        disable_gravatar = true;
      };

      users = {
        # No self-service local accounts. OIDC sign-up is the supported path.
        allow_sign_up = false;
        allow_org_create = false;
        auto_assign_org = true;
        auto_assign_org_role = "Viewer";
        default_theme = "dark";
      };

      analytics = {
        reporting_enabled = false;
        check_for_updates = false;
        feedback_links_enabled = false;
      };

      # Scraped by Prometheus over loopback — see the scrapeConfigs block
      # below. Unauthenticated by design; nothing off this box can reach 3000.
      metrics.enabled = true;

      auth = {
        # Hidden AND disabled — see the header. Derived, so the one word in
        # the let block above is the whole switch.
        disable_login_form = !loginFormVisible;

        # `oauth_auto_login` is DELIBERATELY ABSENT rather than set to false.
        # Grafana deprecated it in favour of per-provider auto_login, and
        # tryAutoLogin() counts providers that set auto_login first, falling
        # back to the old key only when that count is zero. So the old key set
        # to false does not switch the new one off — it only reads as though
        # it might, which is worse than not being here.
      } // lib.optionalAttrs (!loginFormVisible) {
        # Without this, "Sign out" is a no-op you can watch happen: Grafana
        # redirects to /login, auto_login fires, tsidp still has a live
        # session for a tailnet identity that cannot stop being itself, and
        # you are back in. Landing on the one URL that opts out of the bounce
        # is what makes the menu item mean something.
        #
        # Not RP-initiated logout: tsidp is not asked to end its own session,
        # only Grafana's. Signing out of the tailnet is `tailscale logout`.
        signout_redirect_url = "${origin}/login?disableAutoLogin=true";
      };

      "auth.anonymous".enabled = false;

      # THE BREAK-GLASS PATH, and the reason there still is one. Grafana
      # registers the basic-auth password client from cfg.BasicAuthEnabled
      # alone, with no reference to DisableLoginForm, so `curl -u ivan:...`
      # against /api keeps working with the form disabled. Grafana's own
      # default is already true: this line is written out because it became
      # LOAD-BEARING on 2026-09-14, and a later tidy-up deleting it as
      # redundant would be deleting the only way in during a tsidp outage.
      "auth.basic".enabled = true;

      "auth.generic_oauth" = {
        enabled = oidcEnabled;
        name = "Tailscale";
        icon = "signin";

        # THE DEFAULT IdP, not merely an offered one: /login redirects here
        # rather than rendering. Per-provider, because [auth] oauth_auto_login
        # is deprecated — see the note up in `auth`.
        #
        # Tied to loginFormVisible so the revert is genuinely one word: with
        # the form back on, this goes off in the same edit and you get a login
        # page you can actually type into.
        auto_login = oidcEnabled && !loginFormVisible;

        # Whoever can reach the node can already sign in — the tailnet ACL is
        # the gate, exactly as it is for Immich's autoRegister. They land as
        # Viewers, which for a dashboard is close enough to harmless.
        allow_sign_up = true;

        client_id = if oidcEnabled then oidcClientId else "";
        client_secret =
          if oidcEnabled
          then "$__file{${config.sops.secrets.grafana-oauth-client-secret.path}}"
          else "";

        scopes = "openid email profile";

        # tsidp's own README: only the admin UI and dynamic client
        # registration are denied by default; /authorize, /token and /userinfo
        # are open to the tailnet. See ./identity.nix.
        auth_url = "${issuer}/authorize";
        token_url = "${issuer}/token";
        api_url = "${issuer}/userinfo";

        # JMESPath over the claims. Strict = false so an unexpected or missing
        # claim yields the default role instead of refusing the login.
        role_attribute_path =
          "contains(email, '${adminEmailDomain}') && 'Admin' || 'Viewer'";
        role_attribute_strict = false;

        # Both off deliberately: tsidp is 0.0.12, and neither PKCE nor refresh
        # tokens are things this configuration should discover the hard way on
        # a machine it cannot reach. Turn them on later, one at a time, from
        # the tailnet, once the plain flow is known to work.
        use_pkce = false;
        use_refresh_token = false;
      };

      log.level = "info";
    };

    # ---------------------------------------------------------- provisioning --
    # `provision.enable` is an mkEnableOption, so it defaults to FALSE. At the
    # pinned nixpkgs rev the provisioning directory looks to be built and wired
    # into settings.paths.provisioning regardless of it, which would make this
    # line a no-op — but "looks to be" is not a thing to rely on for the
    # difference between a working dashboard and an empty one that comes up
    # clean and entirely convincing. It is the documented contract, and it
    # costs nothing.
    provision.enable = true;

    provision.datasources.settings = {
      apiVersion = 1;
      datasources = [{
        name = "Prometheus";
        uid = datasourceUid;
        type = "prometheus";
        # "proxy": Grafana queries Prometheus server-side over loopback. It
        # must be this — Prometheus binds 127.0.0.1 and no browser can reach it.
        access = "proxy";
        url = "http://127.0.0.1:9090";
        isDefault = true;

        # `editable` is left at the nixpkgs default of FALSE, which is why the
        # datasource page shows a "added by config and cannot be modified
        # using the UI" banner and no working Save & test button. That is the
        # intended state — the datasource is a file, like the dashboards — but
        # it does mean the obvious way to health-check it is not available.
        # Use Explore with the query `up` instead, or just look at whether the
        # Fleet overview panels draw.

        jsonData = {
          # Match the scrape interval so Grafana does not offer a resolution
          # the data cannot support.
          timeInterval = "30s";
          httpMethod = "POST";
        };
      }];
    };

    # ---------------------------------------------------------- dashboards --
    provision.dashboards.settings = {
      apiVersion = 1;
      providers = [{
        name = "fleet";
        orgId = 1;
        type = "file";
        # Every dashboard change is a commit, and edits made in the browser
        # cannot be saved. That is the same trade services.immich.settings
        # makes for Immich's System Settings page, and it is the right one
        # here for the same reason: this repo is the machine.
        allowUiUpdates = false;
        disableDeletion = true;
        updateIntervalSeconds = 60;
        # `options.path` is a declared types.path, so a Nix path literal is
        # correct here and the directory is copied into the store. Nothing
        # else goes under `options`: the provider submodule's freeformType
        # catches unmatched names at the TOP level (which is how orgId,
        # allowUiUpdates and the rest below are accepted), but `options` is
        # itself a declared node containing only `path`, so an undeclared
        # sibling in there is an eval error rather than a passthrough.
        # foldersFromFilesStructure would be one, and its Grafana default is
        # already what we want.
        options.path = ./dashboards;
      }];
    };
  };

  # --------------------------------------------- grafana's own metrics -----
  # Declared HERE, not in ./metrics.nix, so that staging works: with this file
  # un-imported there is no scrape job aimed at a port nothing is listening on,
  # and therefore no permanently-firing ExporterDown. NixOS merges these lists
  # across modules.
  services.prometheus.scrapeConfigs = [{
    job_name = "grafana";
    static_configs = [{
      targets = [ "127.0.0.1:3000" ];
      labels = { instance = "hong-kong"; };
    }];
  }];

  # ---------------------------------------------------------------- memory --
  # Joins the slice defined in ./metrics.nix, so the whole observability stack
  # is capped as one thing. The per-unit cap on top of it stops Grafana
  # squeezing Prometheus out of the shared 1 GB — Prometheus is the one holding
  # the data, and it is the one that should survive.
  systemd.services.grafana.serviceConfig = {
    Slice = "system-observability.slice";
    MemoryMax = "384M";
    OOMScoreAdjust = 800;
    Nice = 10;
  };
}
