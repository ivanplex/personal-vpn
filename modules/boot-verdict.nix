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
#   1. When a new generation is activated, we do NOT let it become the
#      permanent bootloader default. Instead:
#         bootctl set-default  <the generation we are currently running>
#         bootctl set-oneshot  <the new generation>
#      So the next boot tries the new one exactly once. If it fails to boot,
#      the firmware falls back to the persistent default — the known-good
#      generation — with no help from anybody.          <-- gate 3
#
#   2. Ten minutes after every boot, a timer asks: is this machine actually
#      healthy? Is tailscaled up and talking to the coordination server?
#      Is sshd listening? (Later: is comin running?)
#         healthy  -> promote the running generation to permanent default
#         unhealthy-> switch back to the previous generation and reboot
#                                                        <-- gate 4
#
#   3. If the kernel hangs so hard the timer never runs, the hardware
#      watchdog in modules/base.nix resets the box, and because step 1 never
#      promoted anything, it comes back on the known-good generation.
#
# The three compose: a bad deploy has to survive activation, then a boot,
# then ten minutes of being genuinely reachable, before it is trusted.
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
  # and the bootloader entry for generation 42 is nixos-generation-42.conf
  genHelpers = ''
    profiles=/nix/var/nix/profiles

    # Which generation are we actually RUNNING right now?
    booted_generation() {
      local booted target
      booted=$(readlink -f /run/booted-system)
      for link in "$profiles"/system-*-link; do
        target=$(readlink -f "$link") || continue
        if [ "$target" = "$booted" ]; then
          basename "$link" | sed -e 's/^system-//' -e 's/-link$//'
          return 0
        fi
      done
      return 1
    }

    # Which generation is the newest one installed?
    latest_generation() {
      readlink "$profiles/system" | sed -e 's/^system-//' -e 's/-link$//'
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

  # ---- gate 3: arm the one-shot after every activation ---------------------
  armScript = pkgs.writeShellScript "boot-arm" ''
    set -euo pipefail
    ${genHelpers}

    latest=$(latest_generation)
    booted=$(booted_generation || true)

    # Nothing to do during the very first install, or if we are already
    # running the newest generation (a switch that needed no reboot).
    if [ -z "''${booted:-}" ] || [ "$latest" = "$booted" ]; then
      echo "boot-arm: running the latest generation ($latest), nothing to arm"
      exit 0
    fi

    echo "boot-arm: default stays on known-good $booted, trying $latest once"
    ${bootctl} set-default "nixos-generation-$booted.conf"
    ${bootctl} set-oneshot "nixos-generation-$latest.conf"
  '';

  # ---- gate 4: the verdict, ten minutes after boot -------------------------
  verdictScript = pkgs.writeShellScript "boot-verdict" ''
    set -uo pipefail
    ${genHelpers}

    fail=0
    note() { echo "boot-verdict: $*"; }

    # --- health checks ------------------------------------------------------
    # Add to these as the machine grows. Every check here is a way the box
    # can rescue itself; every gap is a way it can strand you.

    if ! systemctl is-active --quiet tailscaled; then
      note "FAIL tailscaled is not active"; fail=1
    elif ! ${pkgs.tailscale}/bin/tailscale status --json \
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

    # PHASE 3 — once comin is deploying, its own health matters just as much:
    # if ! systemctl is-active --quiet comin; then
    #   note "FAIL comin is not active"; fail=1
    # fi

    # Any unit in a failed state is worth knowing about, but is NOT by itself
    # grounds for a rollback — a broken Immich should not reboot the box.
    failed=$(systemctl list-units --state=failed --no-legend --plain | wc -l)
    note "info $failed failed unit(s)"

    # --- verdict ------------------------------------------------------------
    booted=$(booted_generation || echo "")
    if [ -z "$booted" ]; then
      note "cannot identify the running generation; taking no action"
      exit 0
    fi

    if [ "$fail" -eq 0 ]; then
      note "healthy — promoting generation $booted to permanent default"
      ${bootctl} set-default "nixos-generation-$booted.conf"
      exit 0
    fi

    target=$(previous_generation "$booted")
    if [ -z "$target" ]; then
      note "UNHEALTHY but there is no older generation to fall back to."
      note "Staying put — a reboot loop would not help."
      exit 1
    fi

    note "UNHEALTHY — rolling back to generation $target and rebooting"
    ${bootctl} set-default "nixos-generation-$target.conf"
    "$profiles/system-$target-link/bin/switch-to-configuration" boot || true
    ${pkgs.systemd}/bin/systemctl reboot
  '';
in
{
  # Runs at the end of every activation, including comin's.
  system.activationScripts.bootArm = {
    text = "${armScript}";
    deps = [ "systemd" ];
  };

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
