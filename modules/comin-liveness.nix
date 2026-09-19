# modules/comin-liveness.nix — is this machine still listening to you?
#
# ---------------------------------------------------------------------------
# THE INCIDENT THIS EXISTS FOR — 2026-09-18
#
# hong-kong stopped accepting deploys for an hour and every health check said
# it was fine. comin's own metrics, read off the box at the time:
#
#     comin_deployment_info{commit_id="bf27a1b...",status="done"} 1
#     comin_last_fetch_failed        0
#     comin_last_eval_failed         0
#     comin_last_build_failed        0
#     comin_last_deployment_failed   0
#     comin_is_suspended             0
#     comin_fetch_count              17684
#
# Nothing had failed. comin had fetched the new commits — twice, and logged
# both — and then declined to deploy them, because `main` had been amended and
# the deployed commit was no longer an ancestor of it. hasNotBeenHardReset()
# returns quietly and logs at DEBUG. `fleet-status` was green throughout.
#
# THE POINT: every alert in metrics.nix's comin group keys off a comin metric,
# and comin had no metric for "I decided not to". A machine that fetches and
# silently refuses is indistinguishable, from the inside, from a machine with
# nothing to do. You cannot detect it with comin's numbers — you have to ask
# somebody else what the branch head is.
#
# So this compares two things that come from opposite directions:
#
#     comin's exporter   ->  the commit it says it deployed
#     the git forge      ->  the commit the branch actually points at
#
# and exports whether they agree. That single boolean is the thing that was
# missing, and it is the only alert in the fleet whose signal does not
# originate on the machine it is watching.
#
# ---------------------------------------------------------------------------
# WHAT THIS IS NOT
#
# NOT an external witness. It still runs ON the box, so it cannot tell you the
# box is dead — architecture.md:221 is right that only a dead-man's switch off
# the machine can do that, and that is still unbuilt. This covers the narrower
# and sneakier case: the machine is alive, healthy, reachable, and has quietly
# stopped being yours to change.
#
# NOT a replacement for branch protection. It tells you a push did not land.
# It cannot tell you it was a bad push.
#
# ---------------------------------------------------------------------------
# WHY IT ASKS GITHUB RATHER THAN RUNNING `git ls-remote`
#
# The GitHub API with `Accept: application/vnd.github.sha` answers with the
# bare 40-character hash and nothing else. No JSON parser in the closure, no
# git clone, no work directory, nothing to go stale. The token never reaches a
# process argument list — it goes into a 0600 curl config on tmpfs, which is
# the same standard ./tailscale-node.nix and hosts/hong-kong/frontdoor.nix
# hold their auth keys to.
#
# FAILURE MODE, BY DESIGN
#
# If the check cannot reach comin's exporter or the forge, it writes NO match
# series at all rather than writing a zero. A zero would mean "comin is not
# deploying", and "I could not tell" is a different statement. The absence is
# then caught by CominLivenessCheckStale in hosts/hong-kong/metrics.nix, which
# is a warning about the watcher rather than a critical about the fleet.
# ---------------------------------------------------------------------------

{ config, lib, pkgs, ... }:

let
  cfg = config.services.comin;

  remote = if cfg.remotes == [ ] then null else builtins.head cfg.remotes;

  # "https://github.com/ivanplex/personal-vpn.git" -> "ivanplex/personal-vpn"
  repoPath = lib.removeSuffix ".git" (lib.removePrefix "https://github.com/" (remote.url or ""));

  # The branch THIS host tracks. modules/comin.nix decides it per hostname —
  # `main` on hong-kong, `stable` on shanghai — so reading it from config is
  # what keeps this correct on a host that is deliberately a day behind.
  branch = remote.branches.main.name or null;

  tokenPath = remote.auth.access_token_path or null;

  apiUrl = "https://api.github.com/repos/${repoPath}/commits/${branch}";

  textfileDir = "/var/lib/node-exporter-textfile";

  # Only where every piece exists. A non-GitHub remote, no token, or comin
  # disabled means this module contributes nothing rather than half of
  # something.
  usable =
    cfg.enable
    && remote != null
    && branch != null
    && tokenPath != null
    && lib.hasPrefix "https://github.com/" (remote.url or "");

  script = pkgs.writeShellScript "comin-liveness" ''
    set -uo pipefail
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.curl pkgs.gnugrep ]}

    out=${textfileDir}/comin-liveness.prom
    tmp=$out.new

    deployed=""
    remote_head=""

    # -- 1. what comin says it deployed --------------------------------------
    # From comin's OWN exporter, deliberately: if this check read the profile
    # symlink instead it could disagree with the metric the dashboard shows,
    # and then you would have two numbers and no answer.
    if body=$(curl -sf -m 10 http://127.0.0.1:${toString cfg.exporter.port}/metrics); then
      line=$(printf '%s\n' "$body" | grep -m1 '^comin_deployment_info{' || true)
      if [ -n "$line" ]; then
        rest=''${line#*commit_id=}
        rest=''${rest#\"}
        deployed=''${rest%%\"*}
      fi
    fi

    # -- 2. what the branch head actually is ---------------------------------
    # The token goes into a 0600 file on tmpfs, never into argv. `cat` only
    # ever sees the PATH in its arguments, and printf is a shell builtin, so
    # the secret is not visible in /proc at any point.
    if [ -r ${tokenPath} ]; then
      cfgfile="$RUNTIME_DIRECTORY/curl.cfg"
      ( umask 077; printf 'header = "Authorization: Bearer %s"\n' "$(cat ${tokenPath})" > "$cfgfile" )
      remote_head=$(curl -sf -m 15 -K "$cfgfile" \
        -H "Accept: application/vnd.github.sha" \
        ${apiUrl} || true)
      rm -f "$cfgfile"
    fi

    # -- 3. write the answer, atomically -------------------------------------
    # node_exporter reads this directory on every scrape and WILL read a
    # half-written file, so it is built elsewhere and renamed into place.
    {
      echo "# HELP comin_remote_head_check_success 1 if both comin's exporter and the git forge answered."
      echo "# TYPE comin_remote_head_check_success gauge"
      echo "# HELP comin_remote_head_check_timestamp_seconds Unix time this check last completed."
      echo "# TYPE comin_remote_head_check_timestamp_seconds gauge"
      echo "# HELP comin_remote_head_matches_deployed 1 if comin's deployed commit is the head of the branch it tracks."
      echo "# TYPE comin_remote_head_matches_deployed gauge"

      if [ -n "$deployed" ] && [ -n "$remote_head" ]; then
        echo "comin_remote_head_check_success 1"
        if [ "$deployed" = "$remote_head" ]; then
          echo "comin_remote_head_matches_deployed 1"
        else
          echo "comin_remote_head_matches_deployed 0"
        fi
      else
        # NO match series. "I could not tell" is not "comin is not deploying",
        # and emitting a zero here would page you for a DNS blip.
        echo "comin_remote_head_check_success 0"
      fi

      echo "comin_remote_head_check_timestamp_seconds $(date +%s)"
    } > "$tmp"

    mv -f "$tmp" "$out"
  '';
in
lib.mkIf usable {
  # The collector and its directory are declared HERE rather than in
  # modules/observability-node.nix so that this module is one file to read and
  # one import to revert. Both options are lists, so the module system merges
  # them with whatever that file already sets.
  services.prometheus.exporters.node = {
    enabledCollectors = [ "textfile" ];
    extraFlags = [ "--collector.textfile.directory=${textfileDir}" ];
  };

  # Root writes, the exporter reads. Safe under the tmpfiles re-run that
  # happens on every deploy — unlike a mount point, which is why
  # hosts/hong-kong/storage.nix refuses to use tmpfiles at all.
  systemd.tmpfiles.rules = [ "d ${textfileDir} 0755 root root -" ];

  systemd.services.comin-liveness = {
    description = "Compare comin's deployed commit against the ${branch} branch head";

    after = [ "network-online.target" "comin.service" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = script;

      RuntimeDirectory = "comin-liveness";
      RuntimeDirectoryMode = "0700";

      # Monitoring's rung. Above Immich at 500, below tailscaled at -900: this
      # must never be the reason the way back into the machine is the process
      # the kernel picks.
      OOMScoreAdjust = 800;
      MemoryMax = "64M";
      CPUWeight = 10;
      IOWeight = 10;
    };
  };

  systemd.timers.comin-liveness = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # comin polls every 60s and a deploy takes a couple of minutes, so
      # checking faster than this would mostly measure deploys in progress.
      # The alert's `for:` is what actually sets the detection floor.
      OnBootSec = "3min";
      OnUnitActiveSec = "5min";
      RandomizedDelaySec = "30s";
      Persistent = true;
    };
  };
}
