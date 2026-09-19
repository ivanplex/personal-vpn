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
    # A HOSTNAME, never a port. See ./public.nix — the cloudflared target is
    # DERIVED from the service's own ports: entry, so that "publish the photo
    # library to the internet" is not a one-line typo away.
    "public"
    # A NAME LABEL, never a port, for the same reason. See ./frontdoors.nix —
    # this app gets its own tsnet node and answers at
    # https://<label>.shark-kitefin.ts.net on the tailnet.
    "frontdoor"
    # A podman network this file's services join, so they can reach each other
    # by container name and nothing else can reach them. This is how an
    # EXPOSURE GROUP is expressed: public apps share a network and a database,
    # and cannot see the internal ones. See the network section below.
    "network"
    # Container names this app must start after — the CROSS-FILE version of
    # compose's depends_on, which can only name services in its own file.
    # A shared database lives in its own file precisely so the group can use
    # it, so the dependency has to be expressible across files.
    "dependsOn"
    # uid[:gid] to own this app's bind-mount directories. Omit it and they are
    # created root-owned, which is right for images that chown their own data
    # directory (the official postgres entrypoint does) and WRONG for images
    # that drop privileges first. See the directory section below.
    "volumeOwner"
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

  # Known, understood, deliberately NOT implemented — the x-fleet equivalent of
  # refusedServiceKeys above. Empty since 2026-09-18, when `frontdoor` stopped
  # being refused and became ./frontdoors.nix. Kept rather than deleted: the
  # next key someone reaches for and does not find should get an explanation,
  # not "unknown key".
  refusedFleetKeys = { };

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

        # ---- x-fleet.public and x-fleet.frontdoor --------------------------
        # Both put this app somewhere other than the box's own loopback. They
        # are deliberately SYMMETRIC: each takes a one-word LABEL, and the name
        # is built from it —
        #
        #     public:    rallly   ->  https://rallly.<zone>              (internet)
        #     frontdoor: rallly   ->  https://rallly.shark-kitefin.ts.net (tailnet)
        #
        # Two things fall out of building the name rather than accepting one.
        #
        # A zone never appears in a compose file, so it cannot be typo'd there,
        # and "hostname on a domain you do not own" stops being an error that
        # has to be CHECKED and becomes one that cannot be EXPRESSED. The
        # assertion that used to catch it is gone because there is nothing left
        # for it to catch.
        #
        # And neither takes a port. The target is derived from the service's
        # own ports: entry, so aiming the public internet at Immich (2283) or
        # Prometheus (9090) is not a typo away — it is not sayable. See
        # ./public.nix and ./frontdoors.nix; neither parses a port, because
        # neither is given one.
        exposureKeys =
          if builtins.isAttrs fleet then
            lib.filter (k: fleet ? ${k}) [ "public" "frontdoor" ]
          else
            [ ];

        # Every x-fleet key whose value becomes a NAME somewhere — a DNS label,
        # a systemd unit, a podman object. They share one rule because the
        # strictest of them (frontdoor, which is also a state directory) is the
        # one everything must satisfy anyway.
        labelKeys =
          if builtins.isAttrs fleet then
            lib.filter (k: fleet ? ${k}) [ "public" "frontdoor" "network" ]
          else
            [ ];

        labelErrors = lib.concatMap (
          k:
          lib.optional
            (
              builtins.isString (fleet.${k} or null)
              && builtins.match "[a-z0-9]([a-z0-9-]*[a-z0-9])?" fleet.${k} == null
            )
            ''
              ${file}: `x-fleet.${k}` is `${toString fleet.${k}}`, which is not a
              usable name label.

              It is a LABEL, not a hostname and not a URL — the rest of the
              name is built for you. Lowercase letters, digits and interior
              hyphens only.

              If you wrote a full hostname like `app.example.com`, write just
              `app`: the domain comes from one place, and that is the point.
            ''
        ) labelKeys
        ++ lib.optional (
          (fleet.network or null) != null && !(builtins.isString fleet.network)
        ) "${file}: `x-fleet.network` must be a string.";

        exposureErrors =
          if exposureKeys == [ ] then
            [ ]
          else
            let
              svcNames = if builtins.isAttrs services then lib.attrNames services else [ ];
              n = builtins.length svcNames;
              portCount =
                if n == 1 then builtins.length (services.${builtins.head svcNames}.ports or [ ]) else 0;
              named = lib.concatMapStringsSep " and " (k: "`x-fleet.${k}`") exposureKeys;
            in
            lib.concatMap (
              k:
              lib.optional (
                !(builtins.isString fleet.${k})
              ) "${file}: `x-fleet.${k}` must be a string."
            ) exposureKeys


            ++ lib.optional (n != 1) ''
              ${file}: ${named} is set, but this file defines ${toString n} service(s).

              x-fleet applies to the WHOLE FILE, so with anything other than
              exactly one service there is no way to say which one is being
              exposed — and ambiguity about what is reachable is the dangerous
              kind of ambiguity. One exposed app per file.
            ''
            ++ lib.optional (n == 1 && portCount != 1) ''
              ${file}, service `${builtins.head svcNames}`: ${named} is set, but the service publishes ${toString portCount} port(s).

              The target is DERIVED from this service's own ports: entry — you
              never type a port, precisely so that a mistake cannot aim it at
              Immich (2283), Prometheus (9090) or tsidp. That derivation needs
              exactly one port to point at.
            '';

      in
      topErrors ++ fleetErrors ++ serviceErrors ++ labelErrors ++ exposureErrors;

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

  # "127.0.0.1:8088:8088" -> "8088". The HOST side of the mapping, which is
  # what anything on this box connects to over loopback. The optional "/tcp"
  # suffix hangs off the container side, so it is stripped first.
  #
  # This is the ONLY place a public port is ever derived, and nothing outside
  # this file computes one. See the options block at the bottom.
  hostPortOf =
    p:
    let
      parts = lib.splitString ":" (builtins.head (lib.splitString "/" p));
    in
    if builtins.length parts >= 3 then builtins.elemAt parts 1 else null;

  # What ./public.nix consumes. Only apps that passed every assertion and are
  # enabled appear here, so `target` is only ever computed for a service that
  # was proven to publish exactly one loopback port.
  appSummary = lib.mapAttrs (
    _stem: e:
    let
      fleet = fleetOf e;
      # Meaningful when the file defines one service, which is exactly the
      # case x-fleet.public is asserted into. Otherwise informational.
      svcName = builtins.head (lib.attrNames e.doc.services);
      str = k: if builtins.isString (fleet.${k} or null) then fleet.${k} else null;
      exposed = str "public" != null || str "frontdoor" != null;

      # Derived only when something actually asks to be exposed, and only then
      # is it proven (by exposureErrors) that there is exactly one service with
      # exactly one port to derive it from.
      ports = e.doc.services.${svcName}.ports or [ ];
      hostPort = if exposed && builtins.length ports == 1 then hostPortOf (builtins.head ports) else null;
    in
    {
      inherit (e) file;
      service = svcName;
      public = str "public";
      frontdoor = str "frontdoor";
      target = if hostPort == null then null else "http://127.0.0.1:${hostPort}";
    }
  ) liveApps;

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
        # compose's depends_on (same file) plus x-fleet.dependsOn (any file).
        # oci-containers resolves both against the GLOBAL container set, which
        # is why service names are asserted unique across every compose file.
        #
        # Ordering only — systemd has no notion of "ready", so a database that
        # is started but still running initdb will still refuse a connection.
        # RestartSec above is what actually covers that gap; this just stops
        # the app trying before the database exists at all.
        dependsOn =
          map scalarToString (svc.depends_on or [ ])
          ++ map scalarToString (fleet.dependsOn or [ ]);

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

        # oci-containers can ATTACH to a podman network; it cannot create one.
        # The missing half is the oneshot generated below, which every
        # container on a network is ordered after.
        networks = lib.optional (fleet ? network) fleet.network;

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

  # ---------------------------------------------------------------------------
  # BIND-MOUNT DIRECTORIES
  #
  # Added 2026-09-19 after rallly and public-db both came up dead on first
  # deploy. The mechanism asserted that the ARRAY was mounted but never
  # created the app's OWN directories, so every bind mount pointed at a path
  # that did not exist. ./immich.nix has done this correctly since the
  # beginning, with `install -d -o immich -g immich`; apps.nix simply never
  # carried it over, which made it a gap for every app with a volume rather
  # than a bug in these two files.
  #
  # TWO THINGS THIS HAS TO GET RIGHT.
  #
  # OWNERSHIP. An image that starts as root and drops privileges itself — the
  # official postgres entrypoint does exactly this — is happy with a
  # root-owned empty directory. An image that starts as an unprivileged user
  # is not, and fails with EACCES. There is no way to infer which, so
  # x-fleet.volumeOwner says, and omitting it means root.
  #
  # ORDERING. A directory under /mnt/storage MUST NOT be created before the
  # array is mounted, or it lands on the 238 GB root disk and the array's real
  # contents are shadowed when it does mount. That is the whole failure
  # ./immich.nix's header is about, so this unit carries the same
  # AssertPathIsMountPoint guards as the container it prepares for, and the
  # container is ordered after it.
  # ---------------------------------------------------------------------------
  #
  # "/var/lib/trek/data:/app/data" -> "/var/lib/trek/data". Only absolute host
  # paths reach here; named volumes are refused by the volume assertion.
  hostPathOf = v: builtins.head (lib.splitString ":" v);

  dirUnitsOf =
    e:
    let
      fleet = fleetOf e;
      mounts = map scalarToString (fleet.requiresMounts or [ ]);
      owner = fleet.volumeOwner or null;
    in
    lib.concatMapAttrs (
      svcName: svc:
      let
        paths = lib.unique (map hostPathOf (lib.filter builtins.isString (svc.volumes or [ ])));
      in
      lib.optionalAttrs (paths != [ ]) {
        "podman-${svcName}-dirs" = {
          description = "Prepare bind-mount directories for ${svcName}";

          unitConfig = lib.optionalAttrs (mounts != [ ]) {
            RequiresMountsFor = mounts;
            # Assert, NOT Condition. A failed Condition marks the job
            # SUCCESSFUL and the container proceeds — creating its data
            # directory on the root disk, which is the one outcome this whole
            # file exists to prevent.
            AssertPathIsMountPoint = mounts;
          };

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = pkgs.writeShellScript "podman-${svcName}-dirs" ''
              set -uo pipefail
              export PATH=${lib.makeBinPath [ pkgs.coreutils ]}

              # MODE 0755, NOT 0700, AND THAT IS NOT LAXNESS.
              #
              # A bind mount is frequently the PARENT of what the container
              # actually writes. postgres mounts /var/lib/postgresql/data but
              # puts its cluster in data/pgdata, and its entrypoint chowns
              # only $PGDATA — so with the parent at 0700 root:root, postgres
              # (uid 999) cannot TRAVERSE into its own data directory and dies
              # with EACCES. 0700 here broke public-db while leaving trek
              # working, because trek's mount IS its data directory and its
              # `chown -R /app/data` covers the mount point itself.
              #
              # 0755 is also what podman's own -v auto-create uses, so this
              # matches the behaviour it replaces rather than quietly
              # tightening it. What is inside stays protected by whatever the
              # application sets — postgres puts 0700 on the cluster itself.
              #
              # install -d on an existing directory fixes mode and owner and
              # is otherwise a no-op, so this is idempotent across deploys.
              install -d ${lib.optionalString (owner != null) "-o ${owner}"} -m 0755 \
                ${lib.escapeShellArgs paths}
            '';
          };
        };
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
    lib.mapAttrs (
      svcName: svc:
      let
        hasVolumes = (lib.filter builtins.isString (svc.volumes or [ ])) != [ ];
      in
      {
      unitConfig =
        {
          # A unit that gives up and leaves evidence beats one that flails
          # forever — the reasoning immich-server uses in ./immich.nix.
          #
          # BUT READ THE RestartSec NOTE BELOW BEFORE CHANGING THESE. Copying
          # immich's 5-in-10min without also setting RestartSec was a bug: it
          # made the limit fire in half a second.
          StartLimitIntervalSec = "10min";
          StartLimitBurst = 10;
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

      # The network must EXIST before a container tries to join it. Requires=
      # rather than Wants=: a container attached to a network that was never
      # created starts and is unreachable, which is the silent failure this
      # whole file is built to avoid.
      requires =
        lib.optional (fleet ? network) "podman-network-${fleet.network}.service"
        ++ lib.optional hasVolumes "podman-${svcName}-dirs.service";
      after =
        mountUnits
        ++ lib.optional (fleet ? network) "podman-network-${fleet.network}.service"
        ++ lib.optional hasVolumes "podman-${svcName}-dirs.service";

      serviceConfig =
        {
          OOMScoreAdjust = fleet.oomScoreAdjust or defaultOomScoreAdjust;

          # THIS LINE IS LOAD-BEARING AND WAS MISSING UNTIL 2026-09-19.
          #
          # virtualisation.oci-containers sets Restart="on-failure" and NO
          # RestartSec (nixos/modules/virtualisation/oci-containers.nix:539),
          # so systemd's default of 100ms applies. Combined with the
          # StartLimitBurst above, a container burned every retry in well
          # under a second and then stayed down FOREVER — which is what
          # happened to rallly on its first deploy while it waited for
          # public-db to finish initdb.
          #
          # immich.nix's "the module's RestartSec=3" note is about the NixOS
          # immich module, which does set one. oci-containers does not, and
          # copying the numbers without the delay inverted their meaning.
          #
          # 15s x 10 attempts = about two and a half minutes of trying, which
          # is enough for a database to come up and still bounded.
          RestartSec = "15s";
        }
        // lib.optionalAttrs (fleet ? memoryHigh) { MemoryHigh = fleet.memoryHigh; }
        // lib.optionalAttrs (fleet ? memoryMax) { MemoryMax = fleet.memoryMax; }
        // lib.optionalAttrs (fleet ? memorySwapMax) { MemorySwapMax = fleet.memorySwapMax; }
        // lib.optionalAttrs (fleet ? cpuWeight) { CPUWeight = fleet.cpuWeight; }
        // lib.optionalAttrs (fleet ? ioWeight) { IOWeight = fleet.ioWeight; };
      }
    ) e.doc.services;

  # Every distinct network the live apps ask for. One oneshot each, shared by
  # however many files declare it — which is the point: a network is how an
  # EXPOSURE GROUP is expressed, so it is deliberately not per-app.
  networksWanted = lib.unique (
    lib.concatMap (stem: lib.optional ((fleetOf liveApps.${stem}) ? network) (fleetOf liveApps.${stem}).network)
      (lib.attrNames liveApps)
  );

  mkNetworkUnit = net: {
    "podman-network-${net}" = {
      description = "podman network ${net} (exposure group)";

      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      # No `path =`. The script sets PATH explicitly with makeBinPath, which
      # is operating rule 8 and is the only one of the two that survives
      # someone reading the script on its own.
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;

        # Idempotent, and quiet about it. `network exists` is the documented
        # check and returns non-zero rather than erroring, so this is a
        # no-op on every deploy after the first.
        ExecStart = pkgs.writeShellScript "podman-network-${net}" ''
          set -uo pipefail
          export PATH=${lib.makeBinPath [ pkgs.coreutils config.virtualisation.podman.package ]}
          podman network exists ${net} && exit 0
          exec podman network create ${net}
        '';

        # Deliberately NO ExecStop removing the network. Stopping this unit
        # during a deploy would tear the network out from under running
        # containers; a network left behind costs nothing. Removing one is a
        # deliberate `podman network rm` — which is the piece quadlet-nix
        # would manage declaratively, and the reason architecture.md still
        # points there for anything more than this.
      };
    };
  };

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
  # ---------------------------------------------------------------------------
  # The parsed, validated, ENABLED apps, published for ./public.nix to consume.
  #
  # It exists so the IFD above runs ONCE. Two modules each reading ./apps/ would
  # mean two conversions, and IFD serialises evaluation — the exact cost the
  # header spends three mitigations avoiding.
  #
  # `target` is the whole point of the shape: the loopback URL is computed HERE,
  # from the service's own ports: entry, and handed over finished. ./public.nix
  # never parses a port and therefore cannot get one wrong.
  # ---------------------------------------------------------------------------
  options.fleet.apps = lib.mkOption {
    # internal, not readOnly: readOnly counts this option's own `default`
    # alongside the definition below and throws "set multiple times". Only
    # ./apps.nix ever sets it, which is the property readOnly would have been
    # buying.
    internal = true;
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          file = lib.mkOption { type = lib.types.str; };
          service = lib.mkOption { type = lib.types.str; };
          public = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
          };
          frontdoor = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
          };
          target = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
          };
        };
      }
    );
    default = { };
    description = "Compose apps deployed on this host, keyed by file stem.";
  };

  config.assertions = [
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

  config.virtualisation.oci-containers.containers = mergeAll (
    map (stem: containersOf liveApps.${stem}) (lib.attrNames liveApps)
  );

  config.systemd.services =
    lib.mapAttrs' (n: v: lib.nameValuePair "podman-${n}" v) (
      mergeAll (map (stem: unitOverridesOf liveApps.${stem}) (lib.attrNames liveApps))
    )
    // mergeAll (map mkNetworkUnit networksWanted)
    // mergeAll (map (stem: dirUnitsOf liveApps.${stem}) (lib.attrNames liveApps));

  config.fleet.apps = appSummary;

  config.sops.secrets = lib.listToAttrs (
    map (
      s:
      lib.nameValuePair s {
        restartUnits = lib.unique (map (r: r.unit) (lib.filter (r: r.secret == s) secretRefs));
      }
    ) (lib.unique (map (r: r.secret) secretRefs))
  );
}
