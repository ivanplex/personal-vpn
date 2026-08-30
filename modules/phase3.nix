# modules/phase3.nix — secrets and the GitOps loop.
#
# NOT IMPORTED YET. Do not enable any of this until:
#   * both machines are installed and booting,
#   * you can SSH in over Tailscale with the monitor unplugged,
#   * gates 3 and 4 have been rehearsed and you have watched a machine
#     roll itself back without help.
#
# Why it cannot come earlier: sops-nix decrypts using a key derived from the
# machine's SSH host key, and that key does not exist until the machine has
# been installed. And comin should not be handed the wheel until the config
# it will pull has been proven to work.
#
# ---------------------------------------------------------------------------
# Turning it on
#
#   1. On each machine:
#        nix-shell -p ssh-to-age --run \
#          'ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub'
#
#   2. Put both age recipients in .sops.yaml, plus an OFFLINE age key of your
#      own as an extra recipient on every rule. If you ever lose both host
#      keys at once, that offline key is the only way back into your secrets.
#
#   3. Create the encrypted files:
#        nix-shell -p sops --run 'sops secrets/hong-kong.yaml'
#        nix-shell -p sops --run 'sops secrets/shanghai.yaml'
#
#   4. Uncomment the inputs in flake.nix, the module list entries, and the
#      body below. Commit. Deploy by hand once. Only then let comin take over.
# ---------------------------------------------------------------------------

{ config, lib, pkgs, ... }:

{
  # --------------------------------------------------------------- sops ----
  # sops.defaultSopsFile = ../secrets/${config.networking.hostName}.yaml;
  # sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  #
  # sops.secrets.tailscale-authkey = { };
  # sops.secrets.deploy-key = {
  #   # comin reads this to clone the private repo.
  #   mode = "0400";
  # };
  # sops.secrets.healthcheck-url = { };

  # -------------------------------------------------------------- comin ----
  # Pull-based GitOps. Each machine polls, matches the config to its own
  # hostname, and deploys. Note the branch differs per host: this is the soak
  # gate — hong-kong rides `main`, shanghai rides `stable`, and `stable`
  # only fast-forwards to a commit hong-kong has run quietly for 24 hours.
  #
  # services.comin = {
  #   enable = true;
  #   remotes = [{
  #     name = "origin";
  #     url = "git@github.com:ivanplex/personal-vpn.git";
  #     branches.main.name =
  #       if config.networking.hostName == "hong-kong" then "main" else "stable";
  #     auth.access_token_path = config.sops.secrets.deploy-key.path;
  #   }];
  # };
  #
  # Once comin is live, add it to the gate 4 health check in
  # modules/boot-verdict.nix — a machine whose deploy agent is dead is a
  # machine you have quietly lost, even though everything looks fine.

  # ---------------------------------------------------- external witness ----
  # Prometheus lives on hong-kong, so it cannot report its own death, and
  # with only two nodes there is no third machine to notice. Both ping an
  # outside dead-man's-switch; a missed ping emails you even if the whole
  # fleet is dark. At two nodes this is not optional.
  #
  # systemd.services.heartbeat = {
  #   description = "External dead-man's-switch heartbeat";
  #   serviceConfig = {
  #     Type = "oneshot";
  #     LoadCredential = "url:${config.sops.secrets.healthcheck-url.path}";
  #     ExecStart = pkgs.writeShellScript "heartbeat" ''
  #       ${pkgs.curl}/bin/curl -fsS -m 10 --retry 3 \
  #         "$(cat "$CREDENTIALS_DIRECTORY/url")"
  #     '';
  #   };
  # };
  # systemd.timers.heartbeat = {
  #   wantedBy = [ "timers.target" ];
  #   timerConfig = { OnBootSec = "2min"; OnUnitActiveSec = "5min"; };
  # };
}
