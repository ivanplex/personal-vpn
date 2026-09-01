# hosts/hong-kong/secrets.nix — sops-nix, scoped to this host only.
#
# This is phase 3b, finally switched on, and deliberately NOT placed in
# modules/. Putting it here keeps shanghai — the box on `stable`, whose whole
# job is not to move — entirely out of this change: it never gets a
# defaultSopsFile, never needs secrets/shanghai.yaml, and keeps building.
# (sops-nix's own config is `mkIf (cfg.secrets != {})`, so merely importing the
# module with no secrets declared is inert.)
#
# modules/phase3.nix is left alone on purpose. Its comin block describes an
# older ssh-deploy-key design that conflicts with the live modules/comin.nix;
# only its sops sketch is superseded by this file.
#
# Each host decrypts with an age key derived from its own SSH host key, so
# there is nothing to copy onto the machine and nothing to lose. The offline
# recipient in .sops.yaml is not optional — it is the only way back in if the
# host key is ever regenerated.
#
# Creating and editing the file:
#
#   nix-shell -p ssh-to-age --run \
#     'ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub'   # on hong-kong
#   age-keygen                                            # your offline key
#   # put both recipients in .sops.yaml, then:
#   nix-shell -p sops --run 'sops secrets/hong-kong.yaml'
#
# Expected contents (add the second key at stage 3, once tsidp has issued it —
# sops-nix only extracts keys that a module actually declares, so an unused key
# sitting in the file is harmless and a missing one only breaks its consumer):
#
#   tsidp-env: |
#     TS_AUTH_KEY=tskey-auth-...
#   immich-oauth-client-secret: <the secret tsidp issues for the Immich client>
#
# Both land in /run/secrets as 0400 root:root, which is correct: EnvironmentFile
# and LoadCredential are both read by PID 1 before the service drops
# privileges, so neither tsidp's DynamicUser nor the immich user needs to be
# able to read the file itself.
#
# If sops-install-secrets ever fails to decrypt, /run/secrets stays empty:
# tsidp is skipped by its ConditionPathExists and immich-server fails to start.
# Neither tailscaled nor sshd is affected, and gate 4 treats failed units as
# informational — so a broken secret is a degraded login, not a lost machine.

{ config, ... }:

{
  sops.defaultSopsFile = ../../secrets/hong-kong.yaml;
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  # Individual secrets are declared next to whatever consumes them —
  # tsidp-env in ./identity.nix, immich-oauth-client-secret in ./immich.nix —
  # so that adding an import adds its secret, and a partially-staged deploy
  # never declares a secret for a unit that does not exist yet.
}
