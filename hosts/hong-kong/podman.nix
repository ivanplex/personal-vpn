# hosts/hong-kong/podman.nix — the container RUNTIME, and only that.
#
# Deliberately separate from ./apps.nix for the same reason ./storage.nix is
# separate from ./immich.nix: this file installs a substrate and runs nothing,
# so it can be deployed, watched and reverted entirely on its own before
# anything depends on it. ./apps.nix is the file that makes it dangerous, and
# all the guards live there.
#
# ---------------------------------------------------------------------------
# THE RULE THIS FILE EXISTS TO ENFORCE
#
#   Installing a container runtime must not change how this machine boots,
#   how it reaches the tailnet, or how it resolves DNS.
#
# Podman earns its place here by being the runtime that does least. There is
# no daemon, so there is no long-running process whose death takes every
# container with it, and nothing that has to be up before
# switch-to-configuration can succeed. Every container is an ordinary systemd
# unit — which is also what makes it monitorable for free: see
# modules/observability-node.nix, which trades cAdvisor away precisely because
# node_systemd_unit_state already says which containers are running, failed or
# flapping.
#
# WHAT IS DELIBERATELY ABSENT, AND WHY
#
#   * No `dockerSocket.enable`. That symlinks /run/docker.sock onto podman's
#     API socket. Nothing on this box speaks the Docker API, so the alias buys
#     nothing and widens what has to be reasoned about.
#
#     BUT READ THIS, because the option name invites the wrong conclusion:
#     turning it off does NOT mean there is no socket. nixpkgs sets
#     `systemd.sockets.podman.wantedBy = [ "sockets.target" ]`
#     UNCONDITIONALLY (nixos/modules/virtualisation/podman/default.nix:295),
#     so /run/podman/podman.sock is listening whenever podman is enabled.
#     dockerSocket.enable only adds the second name for it.
#
#     That socket is a ROOT-EQUIVALENT INTERFACE — anything that can write to
#     it can start a privileged container with / bind-mounted. What keeps it
#     safe here is its SocketGroup, `podman`, which the same module creates
#     EMPTY (line 329). So the invariant to hold on to is not "there is no
#     socket", it is:
#
#         THE `podman` GROUP MUST HAVE NO MEMBERS.
#
#     Adding a user to it is granting that user root. If you ever want a
#     non-root account to run containers, that is the moment to reach for
#     rootless podman instead, not for this group. Check it with
#     `getent group podman` — the member list must be empty.
#
#   * No `dockerCompat`. It symlinks a `docker` binary into the system path.
#     Nothing here calls `docker`, and the alias makes it possible to run a
#     command believing you are talking to a daemon that does not exist.
#
#   * No `defaultNetwork.settings.dns_enabled`. That would put aardvark-dns on
#     the DEFAULT network, which every container joins unless told otherwise.
#
#     AMENDED 2026-09-19, because this note was read as banning aardvark
#     outright and that is not what it means. The concern is HOST dns: this
#     machine must have exactly one author for /etc/resolv.conf, which is the
#     lesson of 2026-08-31 when tailscaled owned it and the box could resolve
#     *.ts.net and nothing else. aardvark-dns does not touch the host
#     resolver — it binds a podman bridge address and answers only for
#     containers on that bridge.
#
#     So the rule is narrower than it first appears: no name resolution on the
#     default network, where it would apply to everything for no reason. On a
#     USER-DEFINED network it is both unavoidable and wanted — it is how
#     rallly finds public-db by container name, and ./apps.nix creates those
#     networks deliberately, one per exposure group. See x-fleet.network.
#
#   * No rootless/user containers. Everything runs as root under a system
#     unit, so there is no lingering user session, no /run/user dependency and
#     no uid-mapping to reason about when a bind mount's ownership looks wrong.
#     The isolation that matters here comes from the per-container capability
#     and read-only settings that ./apps.nix carries through from the compose
#     file, not from the uid podman itself runs as.
#
# AUTOPRUNE IS DANGLING-ONLY, ON PURPOSE
#
# `flags = [ "--all" ]` would also remove images that no container is
# currently running — and a container is momentarily not running during every
# deploy that restarts it. Combined with `pull = "missing"` (the nixpkgs
# default, and the right one for digest-pinned images) that turns a routine
# prune into a mandatory network round trip on a box whose whole design
# assumes GitHub may be unreachable. Dangling layers are reclaimed
# automatically; a retired app's image waits for a deliberate
# `podman image prune -a`, which is the tidying you do while watching, not
# something a timer does behind you.
#
# FAILURE MODE, BY DESIGN
#
# If podman is broken, containers do not run and nothing else changes. Gate 4
# in modules/boot-verdict.nix checks tailscaled, sshd and DNS, and counts
# failed units as INFORMATION ONLY, so no container — and no runtime — can
# reboot this machine or roll it back.
# ---------------------------------------------------------------------------

{ pkgs, ... }:

{
  virtualisation.podman = {
    enable = true;

    # See the header. All three of these default to false; they are written
    # out so that turning one on is a visible, reviewable diff rather than a
    # silent inheritance.
    dockerSocket.enable = false;
    dockerCompat = false;
    defaultNetwork.settings.dns_enabled = false;

    # Dangling layers only. Read the autoprune note in the header before
    # adding `flags = [ "--all" ]`.
    autoPrune = {
      enable = true;
      dates = "weekly";
    };
  };

  virtualisation.oci-containers.backend = "podman";

  # skopeo is how you resolve `image: foo/bar:latest` into the digest that
  # ./apps.nix demands. It is on the box rather than only on the MacBook
  # because there is no nix on the MacBook (see flake.nix) and this is the one
  # tool the compose workflow cannot proceed without.
  #
  # yq-go is NOT here for people — it is the YAML parser ./apps.nix needs at
  # EVALUATION time, and being in the system closure is what guarantees it is
  # already in the store when comin evaluates. Read the IFD section of
  # ./apps.nix before removing it.
  environment.systemPackages = with pkgs; [
    skopeo
    yq-go
  ];
}
