# hosts/hong-kong/apps.nix — compose files are the source of truth.
#
# Every *.yaml in ./apps/ is a real Docker Compose file, and dropping one in
# and pushing IS the deploy. comin already makes push-equals-deploy true for
# NixOS generations; this file extends that property to containers WITHOUT
# stepping outside the four gates.
#
# ---------------------------------------------------------------------------
# THE RULE THIS FILE EXISTS TO ENFORCE
#
#   What the compose file says must be what the box runs. A translator that
#   silently drops a key it does not understand is worse than no translator at
#   all: the repository would LOOK like the source of truth while the machine
#   ran something else, and nothing in the diff would ever show it.
#
#   So: an explicit allowlist, and ANY key outside it fails the build. Not a
#   warning — warnings scroll past. See `refusedServiceKeys` below, where each
#   unsupported key gets its own message explaining what it would have meant,
#   because "unknown key: networks" would be a lie. We know exactly what
#   networks means; it is simply not implemented.
#
# ---------------------------------------------------------------------------
# WHY THE TRANSLATION HAPPENS AT EVALUATION TIME
#
# Because that is what puts the containers inside system.build.toplevel, and
# therefore inside all four gates:
#
#   Gate 1  CI builds hong-kong, so a bad compose file fails in Actions and
#           never reaches the machine.
#   Gate 2  a container that breaks activation is a generation comin restores.
#   Gate 3  the bootloader entry that rolls back takes the containers with it.
#   Gate 4  boot-verdict checks tailscaled, sshd and DNS and counts failed
#           units as INFORMATION ONLY, so no container can reboot the box.
#
# The obvious alternative — a systemd unit running `podman compose up` against
# a checkout — was rejected for exactly this reason. It would sit outside all
# four: nothing would build it, nothing could roll it back, and the running
# state would drift from the commit with no way to tell.
#
# ---------------------------------------------------------------------------
# IMPORT-FROM-DERIVATION: THE COST, AND THE THREE THINGS THAT PAY IT
#
# Nix has no builtins.fromYAML. Reading a YAML file at evaluation time
# therefore means building a derivation mid-evaluation and importing its
# result — IFD. On a box where comin evaluates LOCALLY on two cores, that
# deserves saying out loud rather than burying:
#
#   IF THE CONVERTER IS NOT IN THE STORE AND SUBSTITUTION IS UNAVAILABLE,
#   EVALUATION FAILS — and no deploy happens, including the unrelated fix you
#   were trying to push.
#
# Three mitigations, all cheap:
#
#   1. ONE derivation for every file, never one per file. IFD serialises
#      evaluation (realisation is parallel; evaluation is not), so N compose
#      files must not mean N sequential builds. The converter below walks the
#      directory once.
#
#   2. yq-go is in environment.systemPackages (./podman.nix). That roots it in
#      the running generation's closure, so it can never be garbage collected
#      while that generation exists, so every evaluation after the first is a
#      store hit that cannot need the network. THAT IS WHY IT IS THERE — it is
#      not a convenience for a human at a prompt. Do not remove it.
#
#   3. The converter never dies on one bad file. A YAML parse failure becomes
#      an error marker in the JSON, which becomes a named assertion here. A
#      malformed file still fails the build — that is gate 1 doing its job —
#      but it does so naming the file, instead of handing you a yq stack trace
#      and eleven candidates.
#
# BLAST RADIUS, STATED PLAINLY: auto-discovery plus IFD means one broken
# compose file blocks EVERY deploy to hong-kong until it is fixed. Branch
# protection on `main` plus gate 1 is what makes that acceptable — the
# breakage happens in Actions, not on the machine.
#
# ---------------------------------------------------------------------------
# THE GOTCHA THAT WILL BITE YOU ONCE
#
# Nix reads the GIT INDEX, not the working tree (operating rule 6). A compose
# file you have not `git add`ed is INVISIBLE — it will not deploy, and nothing
# will say so. If a new app appears to do nothing at all, check `git status`
# before you check anything else.
#
# ---------------------------------------------------------------------------
# ADDING AN APP
#
#   1. Resolve the image to a digest. Floating tags are refused (see the
#      digest assertion below), and skopeo is on the box for this:
#
#          skopeo inspect docker://docker.io/traefik/whoami:v1.10.2 \
#            | jq -r '.Digest'
#
#   2. Write ./apps/<name>.yaml. The stem becomes nothing by itself; the
#      SERVICE NAME inside becomes the podman container and the systemd unit,
#      and must be unique across every file here.
#
#   3. `git add` it (see the gotcha above) and push to `testing-hong-kong`
#      first. comin applies that branch with `test`, which never touches the
#      bootloader, so a reboot undoes it. Remember to rebase after every merge
#      to main or comin silently skips the branch — the header of
#      ./services.nix explains why.
#
#   4. Watch it: `systemctl status podman-<service>`.
#
# TO TURN ONE OFF without deleting it: `x-fleet: {enable: false}`. The file is
# still validated — a disabled app that has rotted into something that no
# longer builds is not a thing this directory will hold.
# ---------------------------------------------------------------------------

{ config, lib, pkgs, utils, ... }:

let
  composeDir = ./apps;
  dirLabel = "hosts/hong-kong/apps";

  # ===========================================================================
  # 1. THE SCHEMA
  # ===========================================================================

  # Compose keys this translator implements. Anything else is a build failure.
  # Service-level `x-` keys are allowed and ignored, which is exactly what
  # docker compose itself does with them.
  serviceKeys = [
    "image"
    "environment"
    "ports"
    "volumes"
    "command"
    "entrypoint"
    "user"
    "working_dir"
    "depends_on"
    "labels"
    "cap_add"
    "cap_drop"
    "read_only"
    "security_opt"
    "tmpfs"
    "restart"
  ];

  # Top level. `version` is dead in modern compose and `name` is the project
  # name; both are accepted and ignored, which is what compose does, and
  # refusing them would fail every file copied from upstream on line 1 for no
  # safety gained.
  topKeys = [ "services" "name" "version" ];

  fleetKeys = [
    "enable"
    "memoryHigh"
    "memoryMax"
    "memorySwapMax"
    "oomScoreAdjust"
    "cpuWeight"
    "ioWeight"
    "requiresMounts"
    "secrets"
  ];

  # Known, understood, deliberately NOT implemented. Each carries its own
  # message — see the rule at the top of this file.
  refusedServiceKeys = {
    env_file = ''
      `env_file:` is refused. It would put the referenced file in the Nix
      store, which is world-readable, and in git, which is worse. Secrets
      reach a container here through sops:

          x-fleet:
            secrets: [ my-app-env ]

      which declares sops.secrets.my-app-env and passes its /run/secrets path
      as --env-file. See ./secrets.nix for how the file is edited, and
      ./identity.nix for the same pattern on tsidp.
    '';

    networks = ''
      `networks:` is refused. virtualisation.oci-containers can ATTACH a
      container to a podman network but it will not CREATE one, so a file
      naming a network would deploy a container wired to nothing — silently.

      Containers here publish to loopback and talk to the host by address.
      An app that genuinely needs two containers on a private network is the
      point at which this mechanism should be replaced with quadlet-nix,
      which manages networks properly. That is a decision, not a workaround.
    '';

    build = ''
      `build:` is refused. Building an image on the box means a compiler, a
      build context and an unpinned result on a two-core machine whose first
      duty is to stay reachable. Build it elsewhere, push it, pin the digest.
    '';

    healthcheck = ''
      `healthcheck:` is refused. Compose healthchecks exist to drive
      `depends_on: condition: service_healthy`, which systemd has no notion
      of. Liveness here is systemd's: Restart=on-failure, bounded by the
      StartLimitBurst this file sets. A unit that gives up and leaves
      evidence in the journal beats one that flails forever.
    '';

    deploy = "`deploy:` is Swarm configuration and does nothing outside it. Resource limits belong in `x-fleet:` — see memoryMax and friends.";
    configs = "`configs:` is refused — it is a Swarm feature. Use a read-only bind mount.";
    secrets = "service-level `secrets:` is refused. Use `x-fleet: {secrets: [...]}`, which is wired to sops.";
    profiles = "`profiles:` is refused. Enabling and disabling apps here is `x-fleet: {enable: false}`, which is one greppable line.";
    extends = "`extends:` is refused. It makes a compose file unreadable on its own, and a file in this directory has to be readable on its own.";
    devices = "`devices:` is refused for now. Passing a device through is the kind of thing that should be a deliberate, reviewed change — see accelerationDevices in ./immich.nix for what it takes to do it narrowly.";
    privileged = "`privileged:` is refused. A privileged container is root on this machine. If one is ever genuinely needed it gets its own hand-written .nix file, not a line in a compose file.";
    network_mode = "`network_mode:` is refused. It is how a container escapes into the host's network namespace, which is where tailscaled lives.";
  };

  refusedFleetKeys = {
    frontdoor = ''
      `x-fleet.frontdoor` is not implemented yet.

      A distinct https://<name>.shark-kitefin.ts.net means a distinct tsnet
      NODE — MagicDNS has no CNAMEs — and that is a second tailscaled, a
      state directory, an auth key and a serve config. ./frontdoor.nix does
      it for Immich and ./grafana-frontdoor.nix for Grafana; neither has been
      generalised, and generalising the thing that publishes a service to the
      tailnet is not a change to make in passing.

      Until it is, write the front door by hand, copying ./frontdoor.nix.
    '';
  };

  # ===========================================================================
  # 2. THE CONVERSION (this is the IFD — see the header)
  # ===========================================================================

  composeJSON =
    if !(builtins.pathExists composeDir) then
      null
    else
      pkgs.runCommand "hong-kong-compose-apps.json"
        {
          src = composeDir;
          nativeBuildInputs = [ pkgs.yq-go ];
        }
        ''
          set -uo pipefail

          work="$PWD"
          mkdir -p "$work/parts"

          # WORK FROM INSIDE $src, AND PASS yq A BARE FILENAME. This is not
          # tidiness — it is load-bearing. yq puts the path it was given into
          # its error text, so `yq /nix/store/xxx-apps/broken.yaml` produces an
          # error mentioning a store path. That string ends up in the JSON
          # below, and builtins.readFile SCANS FILE CONTENT for store paths and
          # adds them to the string's context — at which point
          # builtins.fromJSON refuses the whole thing with
          #
          #     '...' is not allowed to refer to a store path
          #
          # which is precisely the incomprehensible failure that mitigation 3
          # in the header exists to prevent. Passing a bare name keeps the
          # error text free of store paths, and names the file the way the
          # reader actually thinks of it.
          cd "$src"

          for f in *.yaml *.yml; do
            [ -e "$f" ] || continue

            base="$f"
            stem="''${base%.*}"

            # The stem is only used to key the result and to name files, but a
            # name that needs quoting would let a filename inject JSON below,
            # so it is refused outright rather than escaped.
            case "$stem" in
              "" | *[!a-z0-9-]*)
                echo "compose-apps: illegal file name '$base'." >&2
                echo "compose-apps: only lowercase letters, digits and hyphens." >&2
                exit 1
                ;;
            esac

            # stdout -> the document, stderr -> captured. Order matters:
            # `2>&1 >file` sends stderr to the command substitution and stdout
            # to the file, which is the opposite of the usual idiom.
            if err="$(yq --output-format=json '.' "$base" 2>&1 >"$work/parts/$stem.doc")"; then
              {
                printf '{"file":"%s","doc":' "$base"
                cat "$work/parts/$stem.doc"
                printf '}\n'
              } > "$work/parts/$stem.json"
            else
              # An error MARKER, not a failure. Mitigation 3 in the header.
              {
                printf '{"file":"%s","error":' "$base"
                ERR="$err" yq --output-format=json --null-input 'strenv(ERR)'
                printf '}\n'
              } > "$work/parts/$stem.json"
            fi
            rm -f "$work/parts/$stem.doc"
          done

          cd "$work"

          # One object keyed by file stem. Assembled with printf rather than a
          # second yq pass because every part is already valid JSON, and this
          # way the shape of the result is obvious from reading the code.
          {
            printf '{\n'
            first=1
            for p in parts/*.json; do
              [ -e "$p" ] || continue
              pbase="''${p##*/}"
              [ "$first" -eq 1 ] || printf ',\n'
              first=0
              printf '"%s":\n' "''${pbase%.json}"
              cat "$p"
            done
            printf '\n}\n'
          } > combined.json

          # An empty apps/ yields "{\n\n}" — a valid empty object. Prove that
          # rather than assume it: a malformed result here would surface as an
          # incomprehensible builtins.fromJSON error with no context at all.
          if ! yq --output-format=json '.' combined.json >/dev/null 2>&1; then
            echo "compose-apps: internal error — assembled invalid JSON:" >&2
            cat combined.json >&2
            exit 1
          fi

          cp combined.json "$out"
        '';

  # { "<stem>" = { file = "<stem>.yaml"; doc = {...}; }  # parsed
  #             | { file = "<stem>.yaml"; error = "..."; }; }  # did not parse
  # unsafeDiscardStringContext is not optional here, and it is not a shortcut.
  #
  # builtins.readFile SCANS THE FILE'S CONTENT for anything that looks like a
  # store path and adds it to the returned string's CONTEXT. builtins.fromJSON
  # then rejects any string carrying context, with
  #
  #     '<the entire JSON>' is not allowed to refer to a store path
  #
  # — an error that names no file and explains nothing. The converter above
  # already keeps store paths out of yq's error text, which covers the case
  # that actually bit during testing; this covers the rest, because a compose
  # file is free to contain a path of its own (`volumes: ["/nix/store/...:/x"]`
  # is unusual but perfectly legal) and one of those must not be able to take
  # every deploy to this host down with an unreadable message.
  #
  # Discarding is CORRECT, not merely expedient: the real dependency is the
  # apps/ directory, and that is already captured by `src` on the derivation.
  # Nothing is built from these strings — they are configuration data being
  # read, not paths being referenced.
  rawApps =
    if composeJSON == null then
      { }
    else
      builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.readFile composeJSON));

  # ===========================================================================
  # 3. VALIDATION
  #
  # Every check returns a list of MESSAGES, which become assertions at the
  # bottom. A message always names the file, because the file is what you edit.
  # ===========================================================================

  # Compose lets several fields be either a mapping or a list of "K=V"
  # strings. Both are accepted — refusing one form would be friction with no
  # safety gained — and normalised here, in one place.
  kvPairs =
    v:
    if builtins.isAttrs v then
      lib.mapAttrs (_: scalarToString) v
    else if builtins.isList v then
      builtins.listToAttrs (
        map (
          s:
          let
            parts = lib.splitString "=" (scalarToString s);
          in
          lib.nameValuePair (builtins.head parts) (lib.concatStringsSep "=" (builtins.tail parts))
        ) v
      )
    else
      { };

  # YAML scalars arrive as bools, ints and nulls. `toString true` is "1" in
  # Nix, which is not what compose means, so this does it properly.
  scalarToString =
    v:
    if builtins.isString v then
      v
    else if builtins.isBool v then
      (if v then "true" else "false")
    else if v == null then
      ""
    else
      toString v;

  appErrors =
    stem: entry:
    let
      file = "${dirLabel}/${entry.file}";
    in
    if entry ? error then
      [
        ''
          ${file} is not valid YAML:

          ${entry.error}
        ''
      ]
    else if !(builtins.isAttrs entry.doc) then
      [ "${file} is empty, or its top level is not a mapping. A compose file needs a `services:` key." ]
    else
      let
        doc = entry.doc;
        fleet = doc."x-fleet" or { };
        services = doc.services or { };

        topErrors =
          lib.optional (!(doc ? services)) "${file} has no `services:` key."
          ++ lib.optional (
            doc ? services && !(builtins.isAttrs doc.services)
          ) "${file}: `services:` must be a mapping of service name to definition."
          ++ map (k: "${file}: unsupported top-level key `${k}:`.") (
            lib.filter (k: !(builtins.elem k topKeys) && !(lib.hasPrefix "x-" k)) (lib.attrNames doc)
          );

        fleetErrors =
          if !(builtins.isAttrs fleet) then
            [ "${file}: `x-fleet:` must be a mapping." ]
          else
            map (
              k:
              if refusedFleetKeys ? ${k} then
                "${file}: ${refusedFleetKeys.${k}}"
              else
                "${file}: unknown `x-fleet:` key `${k}`. Supported: ${lib.concatStringsSep ", " fleetKeys}."
            ) (lib.filter (k: !(builtins.elem k fleetKeys)) (lib.attrNames fleet));

        serviceErrors =
          if !(builtins.isAttrs services) then
            [ ]
          else
            lib.concatMap (n: svcErrors n services.${n}) (lib.attrNames services);

        svcErrors =
          svcName: svc:
          let
            where = "${file}, service `${svcName}`";
          in
          if !(builtins.isAttrs svc) then
            [ "${where}: must be a mapping." ]
          else
            # ---- unsupported keys ------------------------------------------
            map (
              k:
              if refusedServiceKeys ? ${k} then
                "${where}: ${refusedServiceKeys.${k}}"
              else
                "${where}: unsupported key `${k}:`. Supported: ${lib.concatStringsSep ", " serviceKeys}."
            ) (lib.filter (k: !(builtins.elem k serviceKeys) && !(lib.hasPrefix "x-" k)) (lib.attrNames svc))

            # ---- the image, and its digest ---------------------------------
            ++ lib.optional (!(svc ? image)) "${where}: no `image:`."
            ++ lib.optional (svc ? image && !(builtins.isString svc.image)) "${where}: `image:` must be a string."
            ++ lib.optional
              (svc ? image && builtins.isString svc.image && !(lib.hasInfix "@sha256:" svc.image))
              ''
                ${where}: image `${svc.image}` is not pinned by digest.

                architecture.md:211 — pin images by digest, not tag. A floating
                tag means a container restart on a machine 9,000 km away can
                quietly start running different code than the one you reviewed,
                with nothing in git to show it. Resolve it on the box:

                    skopeo inspect docker://${svc.image} | jq -r '.Digest'

                then replace the `:tag` with the `@sha256:...` it printed. Keep
                the tag in a comment on the line above — the digest says what
                runs, the tag says what you thought you were running.
              ''

            # ---- ports -----------------------------------------------------
            ++ (
              let
                ps = svc.ports or [ ];
              in
              if !(builtins.isList ps) then
                [ "${where}: `ports:` must be a list." ]
              else
                lib.concatMap (
                  p:
                  if !(builtins.isString p) then
                    [ ''${where}: long-form port mappings are not supported. Write "127.0.0.1:8088:80".'' ]
                  else if !(lib.hasPrefix "127.0.0.1:" p) then
                    [
                      ''
                        ${where}: port "${p}" does not bind loopback explicitly. Write "127.0.0.1:${p}".

                        Nothing on this box is reached by a published port — services
                        are published on the tailnet by `tailscale serve` from their own
                        tsnet node (./frontdoor.nix). The firewall already only trusts
                        tailscale0, so this is defence in depth, and it is the same rule
                        services.immich.host = "127.0.0.1" follows.
                      ''
                    ]
                  else
                    [ ]
                ) ps
            )

            # ---- volumes ---------------------------------------------------
            ++ (
              let
                vs = svc.volumes or [ ];
              in
              if !(builtins.isList vs) then
                [ "${where}: `volumes:` must be a list." ]
              else
                lib.concatMap (
                  v:
                  if !(builtins.isString v) then
                    [ ''${where}: long-form volume entries are not supported. Write "/host/path:/container/path:ro".'' ]
                  else if !(lib.hasPrefix "/" v) then
                    [
                      ''
                        ${where}: volume "${v}" is a named volume, or a relative path.
                        Only bind mounts with an ABSOLUTE host path are accepted.

                        Which disk a container writes to has to be visible in the file.
                        This box has a 238 GB root SSD and a 7 TB array that is expected
                        to drop off, and the whole of ./immich.nix exists because writing
                        to the wrong one silently is the worst state this fleet can reach.
                        A named volume hides that choice inside podman's storage.

                        If the path is on the array, say so in x-fleet.requiresMounts too.
                      ''
                    ]
                  else
                    [ ]
                ) vs
            )

            # ---- privileged ports vs dropped capabilities -------------------
            # Learned the hard way on 2026-09-17: the whoami canary had
            # cap_drop: [ALL] and an app listening on its default port 80. The
            # container started, could not bind, died in 20ms, and restarted
            # until StartLimitBurst gave up. Nothing in the journal says
            # "capability" — it says `bind: permission denied`, and you have to
            # already know what that means.
            #
            # It is a build error now because it is ALWAYS wrong and always
            # knowable in advance.
            ++ (
              let
                # podman accepts NET_BIND_SERVICE and CAP_NET_BIND_SERVICE
                # interchangeably, so compare with the prefix stripped.
                normCap = c: lib.removePrefix "CAP_" (lib.toUpper (scalarToString c));
                dropped = map normCap (svc.cap_drop or [ ]);
                added = map normCap (svc.cap_add or [ ]);

                bindDropped =
                  (builtins.elem "ALL" dropped || builtins.elem "NET_BIND_SERVICE" dropped)
                  && !(builtins.elem "NET_BIND_SERVICE" added);

                # "127.0.0.1:8088:80/tcp" -> "80". The CONTAINER port is what
                # has to be bound inside the namespace; the host side is
                # published by podman and needs nothing.
                containerPort =
                  p:
                  let
                    parts = lib.splitString ":" (builtins.head (lib.splitString "/" p));
                    last = lib.last parts;
                  in
                  if builtins.match "[0-9]+" last != null then lib.toInt last else null;

                offenders = lib.filter (
                  p:
                  let
                    n = containerPort p;
                  in
                  n != null && n < 1024
                ) (lib.filter builtins.isString (svc.ports or [ ]));
              in
              lib.optional (bindDropped && offenders != [ ]) ''
                ${where}: binds a privileged container port (${
                  lib.concatStringsSep ", " (map (p: toString (containerPort p)) offenders)
                }) while CAP_NET_BIND_SERVICE is dropped.

                The container will start, fail to bind with

                    listen tcp :${toString (containerPort (builtins.head offenders))}: bind: permission denied

                and restart until StartLimitBurst gives up. Ports below 1024
                need CAP_NET_BIND_SERVICE, and `cap_drop: [ALL]` takes it away
                even from root.

                PREFER THE FIRST FIX:

                  * Tell the app to listen above 1024. Nothing in this
                    directory should need a privileged port — every app here is
                    reached through `tailscale serve`, which connects to a
                    loopback port of our choosing, so the number is arbitrary.
                    (whoami: command: ["-port", "8088"].)

                  * Or, if the image truly cannot be told:
                    cap_add: [NET_BIND_SERVICE]

                AND DO NOT TRUST A LOCAL DOCKER TEST TO CATCH THIS. Docker
                Desktop for Mac runs a VM with
                net.ipv4.ip_unprivileged_port_start=0, where every port is
                unprivileged and the container starts happily. Real Linux
                defaults to 1024. That difference is what let this reach the
                box on 2026-09-17.
              ''
            )

            # ---- exec form only --------------------------------------------
            ++ lib.optional (svc ? command && !(builtins.isList svc.command))
              "${where}: `command:` must be a list. The string form would need shell splitting, which silently mangles quoted arguments."
            ++ lib.optional (svc ? entrypoint && !(builtins.isList svc.entrypoint))
              "${where}: `entrypoint:` must be a list, for the same reason as `command:`."
            ++ lib.optional (svc ? depends_on && !(builtins.isList svc.depends_on))
              "${where}: long-form `depends_on:` is not supported — systemd has no notion of `condition: service_healthy`. Use a plain list of service names, which becomes After= and Requires=."

            # ---- restart ---------------------------------------------------
            ++ lib.optional
              (svc ? restart && !(builtins.elem (scalarToString svc.restart) [ "always" "unless-stopped" "on-failure" ]))
              ''
                ${where}: `restart: ${scalarToString svc.restart}` is not accepted.

                systemd governs restarts here — the oci-containers module sets
                Restart=on-failure — so "always", "unless-stopped" and
                "on-failure" are all accepted as consistent with that and are
                otherwise ignored. "no" would describe something this box does
                not do, and accepting it silently would be a lie.
              '';
      in
      topErrors ++ fleetErrors ++ serviceErrors;

  errorsByStem = lib.mapAttrs appErrors rawApps;

  # A service name becomes a podman container AND a systemd unit, both of which
  # are global. Two files claiming the same one is a collision that would
  # surface as a mystery at runtime, so it is an eval error.
  allServiceRefs = lib.concatMap (
    stem:
    let
      e = rawApps.${stem};
    in
    if e ? doc && builtins.isAttrs e.doc && builtins.isAttrs (e.doc.services or null) then
      map (s: {
        name = s;
        inherit (e) file;
      }) (lib.attrNames e.doc.services)
    else
      [ ]
  ) (lib.attrNames rawApps);

  duplicateErrors =
    let
      names = map (r: r.name) allServiceRefs;
      countOf = n: builtins.length (lib.filter (x: x == n) names);
      dupes = lib.unique (lib.filter (n: countOf n > 1) names);
    in
    map (
      n:
      "service name `${n}` is defined in more than one compose file (${
        lib.concatStringsSep ", " (map (r: r.file) (lib.filter (r: r.name == n) allServiceRefs))
      }). A service name becomes a container and a systemd unit, and both are global."
    ) dupes;

  allErrors = lib.concatLists (lib.attrValues errorsByStem) ++ duplicateErrors;

  # ===========================================================================
  # 4. TRANSLATION
  #
  # Only apps that passed every check above are translated. That is not
  # tidiness: it keeps this section TOTAL. If a malformed file could reach the
  # code below, a type error would throw a Nix trace and bury the assertion
  # message that actually explains the problem.
  # ===========================================================================

  liveApps = lib.filterAttrs (
    stem: e:
    errorsByStem.${stem} == [ ] && ((e.doc."x-fleet" or { }).enable or true) == true
  ) rawApps;

  fleetOf = e: e.doc."x-fleet" or { };

  containersOf =
    e:
    let
      fleet = fleetOf e;
      oom = fleet.oomScoreAdjust or defaultOomScoreAdjust;
    in
    lib.mapAttrs (
      _svcName: svc:
      {
        inherit (svc) image;
        autoStart = true;

        # ports and volumes are already proven to be strings by the assertions
        # above — nothing reaches here that failed them. The rest are only
        # proven to be LISTS, and YAML turns an unquoted 8080 into an integer,
        # so they go through scalarToString rather than trusting the author to
        # have quoted everything.
        ports = svc.ports or [ ];
        volumes = svc.volumes or [ ];
        cmd = map scalarToString (svc.command or [ ]);
        dependsOn = map scalarToString (svc.depends_on or [ ]);

        environment = kvPairs (svc.environment or { });
        labels = kvPairs (svc.labels or { });

        # Compose's entrypoint is a list; podman's --entrypoint takes either a
        # bare string or a JSON array. toJSON gives the array, which is the
        # only form that survives arguments containing spaces.
        entrypoint = if svc ? entrypoint then builtins.toJSON svc.entrypoint else null;

        user = if svc ? user then scalarToString svc.user else null;
        workdir = svc.working_dir or null;

        # true adds, false drops. See the capabilities option in
        # nixos/modules/virtualisation/oci-containers.nix.
        capabilities =
          lib.listToAttrs (map (c: lib.nameValuePair (scalarToString c) true) (svc.cap_add or [ ]))
          // lib.listToAttrs (map (c: lib.nameValuePair (scalarToString c) false) (svc.cap_drop or [ ]));

        environmentFiles = map (n: config.sops.secrets.${n}.path) (fleet.secrets or [ ]);

        extraOptions =
          lib.optional (svc.read_only or false) "--read-only"
          ++ map (o: "--security-opt=${scalarToString o}") (svc.security_opt or [ ])
          ++ map (t: "--tmpfs=${scalarToString t}") (
            let
              t = svc.tmpfs or [ ];
            in
            if builtins.isString t then [ t ] else t
          )
          # THE MEMORY CAP IS SET TWICE, DELIBERATELY. The unit-level
          # MemoryMax below bounds the unit's cgroup; these bound the container
          # payload's own cgroup. The oci-containers module runs podman with
          # `--cgroups=enabled` and `Delegate=true`, which means podman creates
          # cgroups of its own underneath the unit, and relying on exactly
          # where it puts them is relying on an implementation detail of a
          # module we do not own. Both layers are cheap; either alone is a
          # guess. (memorySwapMax is NOT mapped here: podman's --memory-swap is
          # memory PLUS swap, systemd's MemorySwapMax is swap alone, and
          # silently translating between the two would be exactly the kind of
          # quiet mistranslation this file exists to prevent.)
          ++ lib.optional (fleet ? memoryMax) "--memory=${scalarToString fleet.memoryMax}"
          ++ lib.optional (fleet ? memoryHigh) "--memory-reservation=${scalarToString fleet.memoryHigh}"
          ++ [ "--oom-score-adj=${scalarToString oom}" ];
      }
    ) e.doc.services;

  # The ladder, from tech-debt.md:632-641 — HIGHER means the kernel reaches for
  # it FIRST. tailscaled is -900, Immich 500, monitoring 800. A third-party app
  # off the internet is the most expendable thing on this machine, so it sits
  # above all of them and dies first.
  defaultOomScoreAdjust = 900;

  unitOverridesOf =
    e:
    let
      fleet = fleetOf e;
      mounts = map scalarToString (fleet.requiresMounts or [ ]);
      mountUnits = map (p: "${utils.escapeSystemdPath p}.mount") mounts;
    in
    lib.mapAttrs (_svcName: _svc: {
      unitConfig =
        {
          # Five failures in ten minutes and it stays down. On a machine you
          # cannot reach, a unit that gives up and leaves evidence in the
          # journal beats a unit that flails forever — the same reasoning, and
          # the same numbers, as immich-server in ./immich.nix.
          StartLimitIntervalSec = "10min";
          StartLimitBurst = 5;
        }
        // lib.optionalAttrs (mounts != [ ]) {
          RequiresMountsFor = mounts;
          # Assert, NOT Condition. A failed Condition marks the job SUCCESSFUL
          # and everything depending on it proceeds — which would let a
          # container start with the array absent and write its data to the
          # root SSD. Layer 2 in ./immich.nix's header is the long version.
          AssertPathIsMountPoint = mounts;
        };

      # Requires= does not propagate a stop from an out-of-band umount; a
      # filesystem unmounted behind systemd's back goes inactive with no job at
      # all. BindsTo= is what covers that. Both are needed. (./immich.nix,
      # layer 3.)
      bindsTo = mountUnits;
      after = mountUnits;

      serviceConfig =
        {
          OOMScoreAdjust = fleet.oomScoreAdjust or defaultOomScoreAdjust;
        }
        // lib.optionalAttrs (fleet ? memoryHigh) { MemoryHigh = fleet.memoryHigh; }
        // lib.optionalAttrs (fleet ? memoryMax) { MemoryMax = fleet.memoryMax; }
        // lib.optionalAttrs (fleet ? memorySwapMax) { MemorySwapMax = fleet.memorySwapMax; }
        // lib.optionalAttrs (fleet ? cpuWeight) { CPUWeight = fleet.cpuWeight; }
        // lib.optionalAttrs (fleet ? ioWeight) { IOWeight = fleet.ioWeight; };
    }) e.doc.services;

  mergeAll = lib.foldl' lib.recursiveUpdate { };

  # ---- sops ----------------------------------------------------------------
  # Declared HERE rather than in ./secrets.nix so that adding an app brings its
  # secret with it — the same principle immich-oauth-client-secret follows.
  secretRefs = lib.concatMap (
    stem:
    let
      e = liveApps.${stem};
    in
    lib.concatMap (
      svcName: map (s: { secret = s; unit = "podman-${svcName}.service"; }) ((fleetOf e).secrets or [ ])
    ) (lib.attrNames e.doc.services)
  ) (lib.attrNames liveApps);

in
{
  assertions = [
    {
      assertion = config.virtualisation.podman.enable;
      message = ''
        hosts/hong-kong/apps.nix needs a container runtime, and none is
        enabled. Import ./podman.nix alongside it — it is deliberately a
        separate file so the runtime can be deployed and watched on its own
        first, exactly as ./storage.nix is separate from ./immich.nix.
      '';
    }
  ]
  # One assertion per problem, so a build that has three tells you all three.
  ++ map (m: {
    assertion = false;
    message = m;
  }) allErrors;

  virtualisation.oci-containers.containers = mergeAll (
    map (stem: containersOf liveApps.${stem}) (lib.attrNames liveApps)
  );

  systemd.services = lib.mapAttrs' (n: v: lib.nameValuePair "podman-${n}" v) (
    mergeAll (map (stem: unitOverridesOf liveApps.${stem}) (lib.attrNames liveApps))
  );

  sops.secrets = lib.listToAttrs (
    map (
      s:
      lib.nameValuePair s {
        restartUnits = lib.unique (map (r: r.unit) (lib.filter (r: r.secret == s) secretRefs));
      }
    ) (lib.unique (map (r: r.secret) secretRefs))
  );
}
