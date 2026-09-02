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

  # ---------------------------------------------------------------------------
  # A GENERATION IS A (PROFILE, NUMBER) PAIR, NOT A NUMBER.
  #
  # Two profiles deploy to this machine, and their counters are INDEPENDENT:
  #
  #   default   /nix/var/nix/profiles/system-N-link
  #             -> boot entry  nixos-generation-N.conf
  #             written by a hand-run `nixos-rebuild`
  #
  #   comin     /nix/var/nix/profiles/system-profiles/comin-N-link
  #             -> boot entry  nixos-comin-generation-N.conf
  #             written by comin, which hardcodes both names in
  #             internal/profile/profile.go and offers no option to change them
  #
  # The first version of this file knew only about the default profile. Once
  # comin took over deploying, `booted_generation` matched nothing: gate 3
  # short-circuited on "already running the latest generation" and never armed
  # anything, and gate 4 printed "cannot identify the running generation" and
  # exited 0 — for days, while `fleet-status` reported perfect health.
  # Both failed SAFELY, which is precisely why nobody noticed.
  # Confirmed on the box 2026-09-01; see tech-debt.md.
  #
  # Generations are passed around as a TOKEN — "system:6" or "comin:3" — and
  # the helpers below are the ONLY place that knows how a token maps to a
  # symlink and to a boot entry name.
  #
  # ORDERING IS BY TIME, NOT BY NUMBER. "comin-3" and "system-6" say nothing
  # about which came first, so `latest_generation` and `previous_generation`
  # order by the mtime of the profile symlink — when the generation was
  # actually installed. It is the only ordering that means anything across two
  # counters, and it is what makes a rollback land on the thing that really
  # ran before this one.
  genHelpers = ''
    export PATH=${binPath}:$PATH
    profiles=/nix/var/nix/profiles
    cominProfiles=/nix/var/nix/profiles/system-profiles
    espEntries=/boot/loader/entries

    # token -> the profile symlink pointing at its toplevel
    _gen_link() {
      case "$1" in
        system:*) printf '%s' "$profiles/system-''${1#system:}-link" ;;
        comin:*)  printf '%s' "$cominProfiles/comin-''${1#comin:}-link" ;;
        *) return 1 ;;
      esac
    }

    # token -> the systemd-boot entry that boots it
    _gen_entry() {
      case "$1" in
        system:*) printf 'nixos-generation-%s.conf' "''${1#system:}" ;;
        comin:*)  printf 'nixos-comin-generation-%s.conf' "''${1#comin:}" ;;
        *) return 1 ;;
      esac
    }

    # Can this generation actually be booted? configurationLimit keeps only
    # the last 10 entries on the ESP, so a profile link outlives the entry
    # that boots it. Rolling back to a generation with no entry is a one-way
    # trip, so previous_generation() will not choose one.
    _gen_bootable() {
      local e
      e=$(_gen_entry "$1") || return 1
      [ -e "$espEntries/$e" ]
    }

    # Every installed generation, one token per line, both profiles. If comin
    # has never deployed here the second glob simply matches nothing.
    all_generations() {
      local link n
      for link in "$profiles"/system-*-link; do
        [ -L "$link" ] || continue
        n=''${link##*/system-}; n=''${n%-link}
        case "$n" in ""|*[!0-9]*) continue ;; esac
        printf 'system:%s\n' "$n"
      done
      for link in "$cominProfiles"/comin-*-link; do
        [ -L "$link" ] || continue
        n=''${link##*/comin-}; n=''${n%-link}
        case "$n" in ""|*[!0-9]*) continue ;; esac
        printf 'comin:%s\n' "$n"
      done
    }

    # When was this generation installed? The mtime of the symlink ITSELF —
    # stat does not follow symlinks unless asked, which is what we want here.
    _gen_mtime() {
      local link t
      link=$(_gen_link "$1") || return 1
      t=$(stat -c %Y "$link" 2>/dev/null) || return 1
      case "$t" in ""|*[!0-9]*) return 1 ;; esac
      printf '%s' "$t"
    }

    # Which generation are we actually RUNNING right now?
    booted_generation() {
      local booted target tok
      booted=$(readlink -f /run/booted-system 2>/dev/null) || return 1
      [ -n "$booted" ] || return 1
      for tok in $(all_generations); do
        target=$(readlink -f "$(_gen_link "$tok")" 2>/dev/null) || continue
        if [ "$target" = "$booted" ]; then
          printf '%s' "$tok"
          return 0
        fi
      done
      return 1
    }

    # The most recently installed generation, across both profiles.
    latest_generation() {
      local tok t best="" bestt=""
      for tok in $(all_generations); do
        t=$(_gen_mtime "$tok") || continue
        if [ -z "$best" ] || [ "$t" -gt "$bestt" ]; then
          best=$tok
          bestt=$t
        fi
      done
      [ -n "$best" ] || return 1
      printf '%s' "$best"
    }

    # The newest BOOTABLE generation installed strictly before $1 — i.e. the
    # rollback target.
    previous_generation() {
      local cur=$1 curt tok t best="" bestt=""
      curt=$(_gen_mtime "$cur") || return 1
      for tok in $(all_generations); do
        if [ "$tok" = "$cur" ]; then continue; fi
        _gen_bootable "$tok" || continue
        t=$(_gen_mtime "$tok") || continue
        [ "$t" -lt "$curt" ] || continue
        if [ -z "$best" ] || [ "$t" -gt "$bestt" ]; then
          best=$tok
          bestt=$t
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
    ${bootctl} set-default "$(_gen_entry "$booted")" \
      || echo "boot-arm: WARNING could not set default"
    ${bootctl} set-oneshot "$(_gen_entry "$latest")" \
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

    # DNS. A machine that cannot resolve names cannot be deployed to, yet it
    # passes every other check here — which is exactly how one goes quiet
    # without anyone noticing. This happened on 2026-08-31: *.ts.net resolved
    # perfectly while github.com resolved not at all, for a good while.
    #
    # Deliberately lenient: several names, short timeouts, and it only counts
    # as a failure when ALL of them fail. A rollback cannot fix somebody
    # else's DNS outage, so this must not be trigger-happy.
    dns_ok=""
    for host in github.com cache.nixos.org one.one.one.one; do
      if [ -n "$(timeout 5 ${pkgs.dnsutils}/bin/dig +short +time=3 +tries=1 \
                 "$host" A 2>/dev/null)" ]; then
        dns_ok="$host"; break
      fi
    done
    if [ -z "$dns_ok" ]; then
      note "FAIL cannot resolve github.com, cache.nixos.org or one.one.one.one"
      fail=1
    else
      note "ok   dns (via $dns_ok)"
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
        if ${bootctl} set-default "$(_gen_entry "$booted")"; then
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
    "$(_gen_link "$target")/bin/switch-to-configuration" boot \
      || note "WARNING switch-to-configuration failed; rebooting anyway"
    ${bootctl} set-default "$(_gen_entry "$target")" \
      || note "WARNING could not set default to $target"

    ${pkgs.systemd}/bin/systemctl reboot
  '';

  # ---- fleet-status: one command, the whole truth ---------------------------
  # Three different sources claim to know which generation boots next, and
  # they disagree. `bootctl list` marks (default) from loader.conf, which is
  # the LOWEST priority of the three. The real precedence is:
  #     one-shot  ->  EFI LoaderEntryDefault  ->  loader.conf
  # An hour was lost to reading the wrong one. This prints all of them.
  fleetStatus = pkgs.writeShellScriptBin "fleet-status" ''
    set -uo pipefail
    ${genHelpers}

    efivar() {
      local f
      for f in /sys/firmware/efi/efivars/"$1"-*; do
        [ -e "$f" ] || continue
        tail -c +5 "$f" 2>/dev/null | tr -d '\0'
        return 0
      done
      return 1
    }

    # HONESTY CHECK — do not skip this, it is the whole point of the command.
    #
    # Two things fleet-status reads are root-only, and NEITHER is a mistake:
    #   /nix/var/nix/profiles/system-profiles   comin creates it mode 0000
    #   /boot/loader/entries                    the ESP is mounted umask=0077
    #
    # Run as a normal user, the generation lines below are not WRONG, they are
    # BLIND: the comin profile is invisible, so `booted` reads "?" and `latest`
    # reports the newest hand-run generation as though nothing else existed.
    # That is precisely the shape of the bug that hid the comin profile
    # mismatch for days — a reassuring answer produced by a script that could
    # not see. So say so, at the top, before any number is printed.
    blind=""
    if [ ! -r "$cominProfiles" ] || [ ! -x "$cominProfiles" ]; then
      blind="the comin profile directory"
    fi
    if [ ! -r "$espEntries" ] || [ ! -x "$espEntries" ]; then
      blind="''${blind:+$blind and }the ESP"
    fi

    booted=$(booted_generation) || booted="?"
    latest=$(latest_generation) || latest="?"
    promoted=$(cat ${promotedFile} 2>/dev/null || echo "never")
    defaultRaw=$(efivar LoaderEntryDefault || echo "")
    oneshot=$(efivar LoaderEntryOneShot || echo "")

    # loader.conf is the LOWEST-priority of the three, and on this box since
    # 2026-09-01 it is the one actually in charge: the interim fix for the
    # comin profile bug unset LoaderEntryDefault so NixOS's own
    # "default nixos-comin-generation-N.conf" line would govern. Printing it
    # is the difference between knowing what boots next and guessing. Gate 4
    # sets LoaderEntryDefault again the first time it promotes, which takes
    # the fallback back off loader.conf and under this module's control.
    loaderconf=""
    if [ -r /boot/loader/loader.conf ]; then
      while read -r k v; do
        if [ "$k" = "default" ]; then loaderconf=$v; fi
      done < /boot/loader/loader.conf
    fi

    # The whole point of this command: resolve the three sources in
    # systemd-boot's own precedence order and say what will actually happen.
    if [ -n "$oneshot" ]; then
      nextboot="$oneshot  (one-shot, consumed on use)"
    elif [ -n "$defaultRaw" ]; then
      nextboot="$defaultRaw  (EFI LoaderEntryDefault)"
    elif [ -n "$loaderconf" ]; then
      nextboot="$loaderconf  (loader.conf)"
    else
      nextboot="(cannot tell)"
    fi

    echo
    echo "  $(hostname)"
    echo
    if [ -n "$blind" ]; then
      echo "  !! CANNOT READ $blind — run: sudo fleet-status"
      echo "     the generations below are INCOMPLETE, not authoritative."
      echo
    fi
    echo "  generations"
    echo "    booted        $booted"
    if [ "$latest" != "$booted" ]; then
      echo "    latest        $latest   <- installed but NOT running"
    else
      echo "    latest        $latest"
    fi
    echo "    promoted      $promoted"
    echo
    echo "  bootloader   (one-shot beats default beats loader.conf)"
    echo "    one-shot      ''${oneshot:-(none)}"
    echo "    default       ''${defaultRaw:-(unset)}"
    echo "    loader.conf   ''${loaderconf:-(not set)}"
    echo "    boots next    $nextboot"
    echo
    echo "  health"
    printf '    tailscale     %s\n' \
      "$(${pkgs.tailscale}/bin/tailscale status --json 2>/dev/null \
         | ${pkgs.jq}/bin/jq -r '.BackendState' 2>/dev/null || echo unknown)"
    printf '    sshd          %s\n' "$(systemctl is-active sshd 2>&1)"
    printf '    dns           %s\n' \
      "$(timeout 5 ${pkgs.dnsutils}/bin/dig +short +time=3 +tries=1 github.com A \
         2>/dev/null | head -1 || true)"
    printf '    failed units  %s\n' \
      "$(systemctl list-units --state=failed --no-legend --plain | wc -l)"
    echo
    systemctl list-timers boot-verdict.timer --no-legend --no-pager 2>/dev/null \
      | while read -r line; do echo "  next check    $line"; done
    echo
  '';
in
{
  environment.systemPackages = [ fleetStatus ];

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
