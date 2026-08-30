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
#   1. Whenever the bootloader is written — on a switch, and only then — the
#      new generation is NOT allowed to become the permanent default:
#         bootctl set-default  <the generation we are currently running>
#         bootctl set-oneshot  <the new generation>
#      systemd-boot honours LoaderEntryOneShot first, then LoaderEntryDefault,
#      then loader.conf. So the next boot tries the new generation exactly
#      once; if it does not come up, the firmware falls back to the known-good
#      default unaided.                                          <-- gate 3
#
#   2. A timer checks the machine's health 10 minutes after boot and every
#      10 minutes thereafter:
#         healthy    -> promote the running generation to permanent default
#         unhealthy  -> after 3 consecutive failures, act (see below)
#
#   3. If the kernel hangs so hard the timer never runs, the hardware watchdog
#      in modules/base.nix resets the box — and since nothing was promoted, it
#      returns to the known-good generation.
#
# ---------------------------------------------------------------------------
# Two hard-won lessons, both from real failures on 2026-08-31
#
#   * NO awk, sed, basename OR sort IN THESE SCRIPTS.
#     systemd units run with a minimal PATH. coreutils and gnused are on it;
#     **gawk is not**. The first version of this file used awk to find the
#     previous generation. It failed with "awk: command not found", the lookup
#     returned nothing, the script concluded there was no generation to fall
#     back to, and the machine stranded itself on a broken config — precisely
#     the scenario this file exists to prevent. Generation numbers are now
#     parsed with shell builtins, and PATH is set explicitly regardless.
#
#   * THE CHECK IS PERIODIC, NOT BOOT-ONLY.
#     The first version only ran 10 minutes after boot. But a deploy applies
#     with `switch`, which does not reboot — so a config that killed Tailscale
#     without rebooting left the machine unreachable with nothing scheduled to
#     rescue it. Ever. The timer now repeats.
#
# ---------------------------------------------------------------------------
# What "act" means, and why it depends on whether the generation was promoted
#
#   * Running generation was NEVER promoted -> it is on trial. Something we
#     recently booted is bad, so roll the bootloader back to the previous
#     generation and reboot.
#
#   * Running generation WAS promoted -> it booted fine and passed its checks
#     before, so the breakage arrived later, almost certainly from a live
#     `switch`. Rolling the bootloader back would regress a generation that is
#     known good. Reboot instead: the bootloader will try whatever is armed,
#     that generation arrives on trial, and the case above handles it properly.
#
# In both cases only after 3 consecutive failed checks, so a network blip
# cannot reboot the machine.
#
# ---------------------------------------------------------------------------
# REHEARSE THIS BEFORE THE MACHINES LEAVE YOUR DESK — and rehearse it with the
# monitor unplugged, or you will interact with the 5-second boot menu and
# override the one-shot without realising.
# ---------------------------------------------------------------------------

{ config, lib, pkgs, ... }:

let
  # Explicit PATH. Never rely on what systemd happens to provide.
  binPath = lib.makeBinPath [ pkgs.coreutils pkgs.systemd ];

  bootctl = "${pkgs.systemd}/bin/bootctl";

  stateDir = "/var/lib/boot-verdict";
  promotedFile = "${stateDir}/promoted";   # survives reboots
  failFile = "/run/boot-verdict.fails";    # resets every boot

  # Generation numbers live in the names of these symlinks:
  #   /nix/var/nix/profiles/system-42-link -> /nix/store/...
  # and generation 42's boot entry is nixos-generation-42.conf
  genHelpers = ''
    export PATH=${binPath}:$PATH
    profiles=/nix/var/nix/profiles

    # Pull "42" out of ".../system-42-link". Shell builtins only — see the
    # awk lesson at the top of this file.
    _gen_num() {
      local n=''${1##*system-}
      n=''${n%-link}
      case "$n" in
        ""|*[!0-9]*) return 1 ;;
      esac
      printf '%s' "$n"
    }

    # Which generation are we actually RUNNING right now?
    booted_generation() {
      local booted target link
      booted=$(readlink -f /run/booted-system 2>/dev/null) || return 1
      [ -n "$booted" ] || return 1
      for link in "$profiles"/system-*-link; do
        target=$(readlink -f "$link" 2>/dev/null) || continue
        if [ "$target" = "$booted" ]; then
          _gen_num "$link" && return 0
        fi
      done
      return 1
    }

    # Which generation is the newest one installed?
    latest_generation() {
      local t
      t=$(readlink "$profiles/system" 2>/dev/null) || return 1
      _gen_num "$t"
    }

    # The highest generation strictly below $1 — our rollback target.
    previous_generation() {
      local current=$1 best="" n link
      for link in "$profiles"/system-*-link; do
        n=$(_gen_num "$link") || continue
        if [ "$n" -lt "$current" ]; then
          if [ -z "$best" ] || [ "$n" -gt "$best" ]; then
            best=$n
          fi
        fi
      done
      [ -n "$best" ] || return 1
      printf '%s' "$best"
    }
  '';

  # ---- gate 3: arm the one-shot whenever the bootloader is written ---------
  # No `set -e`: this runs inside the bootloader installer, and a non-zero
  # exit would abort the install and leave the ESP half-written.
  armScript = pkgs.writeShellScript "boot-arm" ''
    set -uo pipefail
    ${genHelpers}

    # During the very first install there is no running generation to protect
    # and no EFI variables to write. NixOS sets this for us.
    if [ "''${NIXOS_INSTALL_BOOTLOADER:-0}" = "1" ]; then
      echo "boot-arm: initial install, nothing to arm"
      exit 0
    fi

    latest=$(latest_generation) || latest=""
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
    ${bootctl} set-default "nixos-generation-$booted.conf" \
      || echo "boot-arm: WARNING could not set default"
    ${bootctl} set-oneshot "nixos-generation-$latest.conf" \
      || echo "boot-arm: WARNING could not set oneshot"
    exit 0
  '';

  # ---- gate 4: the verdict, every 10 minutes -------------------------------
  verdictScript = pkgs.writeShellScript "boot-verdict" ''
    set -uo pipefail
    ${genHelpers}

    THRESHOLD=3
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
    note "info $(systemctl list-units --state=failed --no-legend --plain | wc -l) failed unit(s)"

    # --- where are we? ------------------------------------------------------
    booted=$(booted_generation) || booted=""
    latest=$(latest_generation) || latest=""
    promoted=$(cat ${promotedFile} 2>/dev/null || echo "")

    if [ -z "$booted" ]; then
      note "cannot identify the running generation; taking no action"
      exit 0
    fi

    if [ -n "$latest" ] && [ "$latest" != "$booted" ]; then
      note "note generation $latest is installed but $booted is running"
    fi

    # --- healthy ------------------------------------------------------------
    if [ "$fail" -eq 0 ]; then
      echo 0 > ${failFile}
      if [ "$promoted" != "$booted" ]; then
        note "healthy — promoting generation $booted to permanent default"
        if ${bootctl} set-default "nixos-generation-$booted.conf"; then
          mkdir -p ${stateDir} && echo "$booted" > ${promotedFile}
        else
          note "WARNING could not promote; will retry at the next check"
        fi
      fi
      exit 0
    fi

    # --- unhealthy ----------------------------------------------------------
    count=$(cat ${failFile} 2>/dev/null || echo 0)
    case "$count" in
      ""|*[!0-9]*) count=0 ;;
    esac
    count=$((count + 1))
    echo "$count" > ${failFile}
    note "unhealthy — consecutive failed check $count of $THRESHOLD"

    if [ "$count" -lt "$THRESHOLD" ]; then
      note "not acting yet; a transient fault must not reboot the machine"
      exit 0
    fi

    if [ "$promoted" = "$booted" ]; then
      # This generation booted cleanly and passed its checks before, so the
      # breakage came later — almost certainly a live `switch`. Rolling the
      # bootloader back would regress a known-good generation. Reboot instead
      # and let whatever is armed arrive on trial.
      note "generation $booted was already promoted; the fault arrived later"
      note "rebooting so the boot path can judge whatever is armed"
      ${pkgs.systemd}/bin/systemctl reboot
      exit 0
    fi

    target=$(previous_generation "$booted") || target=""
    if [ -z "$target" ]; then
      note "UNHEALTHY, but there is no older generation to fall back to."
      note "Staying put — a reboot loop would not help."
      exit 0
    fi

    note "UNHEALTHY — rolling back to generation $target and rebooting"

    # Order matters: switch-to-configuration reinstalls the bootloader and
    # would overwrite the default, so set it afterwards, immediately before
    # rebooting. The system profile pointer is deliberately left alone so you
    # can still see which generation was attempted.
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
    description = "Gate 4 — health verdict and automatic rollback";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${verdictScript}";
      StateDirectory = "boot-verdict";
    };
  };

  systemd.timers.boot-verdict = {
    description = "Judge system health 10 minutes after boot, then every 10";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10min";
      OnUnitActiveSec = "10min";
      AccuracySec = "30s";
    };
  };
}