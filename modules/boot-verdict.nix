# modules/boot-verdict.nix — GATES 3 AND 4.
#
# READ THIS FILE PROPERLY. It is the only thing standing between you and a
# machine that is 9,000 km away and will not come back.
#
# ---------------------------------------------------------------------------
# The problem
#
#   NixOS gives you two safety nets for free:
#     gate 1  a bad expression fails in CI and never deploys
#     gate 2  a failed activation makes comin restore the previous generation
#
#   Neither helps with:
#     gate 3  the new generation does not boot at all
#     gate 4  it boots, systemd is happy, but Tailscale is dead and you are
#             locked out — nothing "failed", so nothing rolls anything back
#
# ---------------------------------------------------------------------------
# The mechanism
#
#   1. Whenever the bootloader is (re)installed — which happens on a switch,
#      and only then — we refuse to let the new generation become the
#      permanent default. Instead:
#         bootctl set-default  <the generation we are currently running>
#         bootctl set-oneshot  <the new generation>
#      systemd-boot honours LoaderEntryOneShot first, then LoaderEntryDefault.
#      So the next boot tries the new generation exactly once; if it does not
#      come up, the firmware falls back to the known-good default with no
#      help from anybody.                                     <-- gate 3
#
#   2. Ten minutes after every boot a timer asks whether this machine is
#      actually healthy — tailscaled up and talking to the control plane,
#      sshd listening, later comin running.
#         healthy   -> promote the running generation to permanent default
#         unhealthy -> switch back to the previous generation and reboot
#                                                             <-- gate 4
#
#   3. If the kernel hangs so hard the timer never runs, the hardware
#      watchdog in modules/base.nix resets the box — and because nothing was
#      ever promoted, it comes back on the known-good generation.
#
# The three compose: a deploy must survive activation, then a boot, then ten
# minutes of being genuinely reachable, before it is trusted.
#
# ---------------------------------------------------------------------------
# Two deliberate choices
#
#   * The arming hook lives in boot.loader.systemd-boot.extraInstallCommands,
#     NOT in system.activationScripts. Activation scripts also run on every
#     boot, before systemd has mounted /boot, which would both fail and
#     re-arm a generation that had already been rejected. extraInstallCommands
#     runs exactly when the bootloader is written, with /boot mounted.
#
#   * Neither script is allowed to fail. An arming hook that exits non-zero
#     would abort the bootloader install; a verdict that exits non-zero would
#     do nothing useful. A hiccup here must never turn a good deploy bad.
#
# ---------------------------------------------------------------------------
# REHEARSE THIS BEFORE THE MACHINES LEAVE YOUR DESK. Push a commit that sets
# services.tailscale.enable = false and watch the box roll itself back. If
# you have not seen it happen, you do not have the feature.
# ---------------------------------------------------------------------------

{ config, lib, pkgs, ... }:

let
  # Generation numbers live in the names of these symlinks:
  #   /nix/var/nix/profiles/system-42-link -> /nix/store/...
  # and generation 42's boot entry is nixos-generation-42.conf
  genHelpers = ''
    profiles=/nix/var/nix/profiles

    # Which generation are we actually RUNNING right now?
    booted_generation() {
      local booted target
      booted=$(readlink -f /run/booted-system 2>/dev/null) || return 1
      [ -n "$booted" ] || return 1
      for link in "$profiles"/system-*-link; do
        target=$(readlink -f "$link" 2>/dev/null) || continue
        if [ "$target" = "$booted" ]; then
          basename "$link" | sed -e 's/^system-//' -e 's/-link$//'
          return 0
        fi
      done
      return 1
    }

    # Which generation is the newest one installed?
    latest_generation() {
      readlink "$profiles/system" 2>/dev/null \
        | sed -e 's/^system-//' -e 's/-link$//'
    }

    # The highest generation strictly below $1 — our rollback target.
    previous_generation() {
      local current=$1
      for link in "$profiles"/system-*-link; do
        basename "$link" | sed -e 's/^system-//' -e 's/-link$//'
      done | sort -n | awk -v c="$current" '$1 < c' | tail -1
    }
  '';

  bootctl = "${pkgs.systemd}/bin/bootctl";

  # ---- gate 3: arm the one-shot whenever the bootloader is written ---------
  # NOTE: no `set -e`. This runs inside the bootloader installer; a non-zero
  # exit here would abort the install and leave the ESP half-written.
  armScript = pkgs.writeShellScript "boot-arm" ''
    set -uo pipefail
    ${genHelpers}

    # During the very first install there is no running generation to protect
    # and no EFI variables to write. NixOS sets this for us.
    if [ "''${NIXOS_INSTALL_BOOTLOADER:-0}" = "1" ]; then
      echo "boot-arm: initial install, nothing to arm"
      exit 0
    fi

    latest=$(latest_generation)
    booted=$(booted_generation) || booted=""

    if [ -z "$booted" ] || [ -z "$latest" ]; then
      echo "boot-arm: cannot identify generations, leaving the bootloader alone"
      exit 0
    fi

    if [ "$latest" = "$booted" ]; then
      echo "boot-arm: already running the latest generation ($latest)"
      exit 0
    fi

    echo "boot-arm: default stays on known-good $booted; $latest gets one try"
    ${bootctl} set-default "nixos-generation-$booted.conf" || \
      echo "boot-arm: WARNING could not set default"
    ${bootctl} set-oneshot "nixos-generation-$latest.conf" || \
      echo "boot-arm: WARNING could not set oneshot"
    exit 0
  '';

  # ---- gate 4: the verdict, ten minutes after boot -------------------------
  verdictScript = pkgs.writeShellScript "boot-verdict" ''
    set -uo pipefail
    ${genHelpers}

    fail=0
    note() { echo "boot-verdict: $*"; }

    # --- health checks ------------------------------------------------------
    # Every check here is a way the box can rescue itself; every gap is a way
    # it can strand you. Add to them as the machine grows.

    if ! systemctl is-active --quiet tailscaled; then
      note "FAIL tailscaled is not active"; fail=1
    elif ! ${pkgs.tailscale}/bin/tailscale status --json 2>/dev/null \
         | ${pkgs.jq}/bin/jq -e '.BackendState == "Running"' >/dev/null; then
      note "FAIL tailscale backend is not Running"; fail=1
    else
      note "ok   tailscale"
    fi

    if ! systemctl is-active --quiet sshd; then
      note "FAIL sshd is not active"; fail=1
    else
      note "ok   sshd"
    fi

    # PHASE 3 — once comin is deploying, its health matters just as much: a
    # machine whose deploy agent is dead is one you have quietly lost.
    # if ! systemctl is-active --quiet comin; then
    #   note "FAIL comin is not active"; fail=1
    # fi

    # Informational only. A broken Immich must NOT reboot the box.
    failed=$(systemctl list-units --state=failed --no-legend --plain | wc -l)
    note "info $failed failed unit(s)"

    # --- verdict ------------------------------------------------------------
    booted=$(booted_generation) || booted=""
    if [ -z "$booted" ]; then
      note "cannot identify the running generation; taking no action"
      exit 0
    fi

    if [ "$fail" -eq 0 ]; then
      note "healthy — promoting generation $booted to permanent default"
      ${bootctl} set-default "nixos-generation-$booted.conf" || \
        note "WARNING could not promote; will retry after the next boot"
      exit 0
    fi

    target=$(previous_generation "$booted")
    if [ -z "$target" ]; then
      note "UNHEALTHY, but there is no older generation to fall back to."
      note "Staying put — a reboot loop would not help."
      exit 0
    fi

    note "UNHEALTHY — rolling back to generation $target and rebooting"

    # Order matters: switch-to-configuration reinstalls the bootloader and
    # would overwrite the default, so set it afterwards, immediately before
    # the reboot. The system profile pointer is deliberately left alone so
    # you can still see which generation was attempted.
    "$profiles/system-$target-link/bin/switch-to-configuration" boot \
      || note "WARNING switch-to-configuration failed; rebooting anyway"
    ${bootctl} set-default "nixos-generation-$target.conf" \
      || note "WARNING could not set default to $target"

    ${pkgs.systemd}/bin/systemctl reboot
  '';
in
{
  # Runs when the bootloader is written — i.e. on a switch, and not at boot.
  boot.loader.systemd-boot.extraInstallCommands = ''
    ${armScript}
  '';

  systemd.services.boot-verdict = {
    description = "Gate 4 — post-boot health verdict and automatic rollback";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${verdictScript}";
    };
  };

  systemd.timers.boot-verdict = {
    description = "Run the post-boot health verdict once, 10 minutes after boot";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10min";
      AccuracySec = "30s";
    };
  };
}
