# modules/comin.nix — the GitOps loop. This is the point of the whole exercise.
#
# From here on, pushing to the repository IS the deploy. Each machine polls,
# finds the configuration matching its own hostname, and applies it. Nothing
# reaches into the machines; they reach out.
#
# ---------------------------------------------------------------------------
# Why this also fixes a failure we actually hit
#
# On 2026-08-31 a `nixos-rebuild switch` run over Tailscale SSH stopped
# tailscaled, dropped the connection, and SIGHUP'd itself mid-deploy — leaving
# the profile advanced but the bootloader never armed. comin runs as a system
# service, so a deploy that severs your SSH has no effect on the deploy.
#
# ---------------------------------------------------------------------------
# THE TOKEN — one manual step, deliberately not in git
#
#   sudo mkdir -p /etc/comin && sudo chmod 700 /etc/comin
#   sudo install -m 0400 /dev/stdin /etc/comin/github-token <<'EOF'
#   github_pat_...
#   EOF
#
# Use a fine-grained PAT: this repository only, Contents: Read-only, and a
# long expiry. Put a calendar reminder to rotate it — an expired token means a
# machine quietly stops deploying while looking perfectly healthy.
#
# PHASE 3b replaces this with sops-nix, so the encrypted token lives in git
# and a rebuilt machine picks it up automatically. See modules/phase3.nix.
# ---------------------------------------------------------------------------

{ config, lib, pkgs, ... }:

{
  systemd.tmpfiles.rules = [ "d /etc/comin 0700 root root -" ];

  services.comin = {
    enable = true;

    # `hostname` defaults to networking.hostName, and comin deploys
    # nixosConfigurations."<hostname>". This is precisely why renaming
    # hkg -> hong-kong mattered: if the two disagree, comin finds nothing.

    remotes = [{
      name = "origin";
      url = "https://github.com/ivanplex/personal-vpn.git";
      auth.access_token_path = "/etc/comin/github-token";

      # THE SOAK GATE.
      # hong-kong rides `main` and picks up changes within a minute.
      # shanghai rides `stable`, which only ever fast-forwards to a commit
      # hong-kong has been running quietly for 24 hours. That is how hong-kong
      # becomes shanghai's canary, now that the UK box is gone.
      branches.main.name =
        if config.networking.hostName == "hong-kong" then "main" else "stable";

      # `switch` applies immediately. Safe now that gate 4 runs periodically
      # and handles a live switch that breaks connectivity without a reboot.
      branches.main.operation = "switch";

      # comin also watches `testing-<hostname>` automatically, applying it with
      # `test` — activated but NOT written to the bootloader, so a reboot
      # returns you to `main` no matter how badly it goes. To try something
      # risky on hong-kong without touching main:
      #     git push origin HEAD:testing-hong-kong
      # It is the cheapest safety valve in the whole system.

      poller.period = 60;
    }];

    # Which node is on which commit, and when it last deployed. Scraped by
    # Prometheus in phase 5. The firewall only trusts tailscale0, so this is
    # not reachable from outside the tailnet.
    exporter.port = 4243;

    # Worth knowing about: services.comin.machineId pins a configuration to one
    # physical machine's /etc/machine-id, so hong-kong's config can never be
    # deployed onto the wrong box. Hostname already does that job here, but it
    # is the belt-and-braces option if you ever clone a disk.
  };

  # ---------------------------------------------------------------------------
  # AFTER comin is confirmed working, add it to gate 4 in boot-verdict.nix:
  #
  #     if ! systemctl is-active --quiet comin; then
  #       note "FAIL comin is not active"; fail=1
  #     fi
  #
  # A machine whose deploy agent is dead is one you have quietly lost — it will
  # keep running and keep passing every other check, while silently ignoring
  # everything you push. Do it as a SECOND deploy, not this one: if comin
  # cannot start for some reason, you do not want gate 4 rolling the machine
  # back before you have seen why.
  # ---------------------------------------------------------------------------
}
