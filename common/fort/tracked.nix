# Fort Tracked Services (runtime-deployed from project flakes)
#
# Decouples app deployment cadence from nix evaluation cadence without the
# overlay system's dependency chain (forgejo CI -> attic -> overlay.nix in
# the project repo). A tracked service is a git repo that MUST expose a
# flake; the host builds the checkout itself and activates it atomically
# through a nix profile.
#
#   fort.tracked.golemd = {
#     repo = "gisikw/golem";        # github shorthand, or set gitUrl
#     flakeAttr = "full";           # packages.<system>.<attr>
#     autoUpdate = true;            # poll branch tip; false = manual sha file
#     exec = "golemd --config ...";  # resolved against <profile>/bin
#     unit = { ... };               # merged into the generated systemd unit
#   };
#
# Split of responsibilities:
#   fetch unit  (fort-tracked-<name>-fetch): resolve desired sha, git fetch,
#     nix build repo#attr --profile /nix/var/nix/profiles/fort-tracked/<name>,
#     then restart the runner. Only succeeds on successful build; a broken
#     main leaves the old profile (and running service) untouched.
#   runner unit (<name>): fully statically defined; expects mise en place.
#     ConditionPathExists on the profile keeps first-boot-before-first-fetch
#     from flapping; the fetch unit starts it once the profile exists.
#
# Control surface in /var/lib/fort-tracked/<name>/:
#   desired.sha — what should be running. autoUpdate=true: written by the
#     poller (record). autoUpdate=false: written by YOU; a systemd path unit
#     watches it and triggers the fetch oneshot.
#   current.sha — what was last successfully built+activated (status only).
#
# Profiles under /nix/var/nix/profiles/ are garbage-collector roots by
# default, and profile generations give rollback for free:
#   nix-env -p /nix/var/nix/profiles/fort-tracked/<name> --rollback
#
# Trust note: autoUpdate=true means push-access-to-branch equals code
# execution on this host. Default is false; only enable for repos whose
# branch you solely control.
{ rootManifest, cluster, ... }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  stateBase = "/var/lib/fort-tracked";
  profileBase = "/nix/var/nix/profiles/fort-tracked";

  cfg = config.fort.tracked;

  urlFor = svc: if svc.gitUrl != null then svc.gitUrl else "https://github.com/${svc.repo}.git";

  fetchScriptFor =
    name: svc:
    let
      state = "${stateBase}/${name}";
      profile = "${profileBase}/${name}";
      url = urlFor svc;
    in
    pkgs.writeShellScript "fort-tracked-${name}-fetch" ''
      set -euo pipefail
      export PATH="${
        lib.makeBinPath [
          pkgs.git
          pkgs.nix
          pkgs.coreutils
          pkgs.util-linux
          pkgs.systemd
        ]
      }:$PATH"
      log() { logger -t fort-tracked-${name} "$@"; }

      mkdir -p "${state}" "${profileBase}"

      ${
        if svc.autoUpdate then
          ''
            desired=$(git ls-remote "${url}" "refs/heads/${svc.branch}" | cut -f1)
            if [ -z "$desired" ]; then
              log "ls-remote returned nothing for ${svc.branch}; will retry next interval"
              exit 1
            fi
            printf '%s\n' "$desired" > "${state}/desired.sha"
          ''
        else
          ''
            desired=$(tr -d '[:space:]' < "${state}/desired.sha" 2>/dev/null || true)
            if [ -z "$desired" ]; then
              log "no desired.sha present; nothing to do"
              exit 0
            fi
          ''
      }

      current=$(cat "${state}/current.sha" 2>/dev/null || true)
      if [ "$desired" = "$current" ] && [ -e "${profile}" ]; then
        exit 0
      fi

      log "updating ${name} to $desired"
      if [ ! -d "${state}/repo/.git" ]; then
        git init -q "${state}/repo"
        git -C "${state}/repo" remote add origin "${url}"
      fi
      git -C "${state}/repo" remote set-url origin "${url}"
      git -C "${state}/repo" fetch -q origin "$desired"
      git -C "${state}/repo" checkout -qf "$desired"
      # Flake eval treats untracked files as a dirty tree; scrub leftovers.
      git -C "${state}/repo" clean -fdxq

      log "building ${state}/repo#${svc.flakeAttr}"
      nix build "${state}/repo#${svc.flakeAttr}" --no-link --profile "${profile}" \
        2>&1 | logger -t fort-tracked-${name}-build
      # (pipefail: a failed build fails the unit here; old profile survives)

      nix-env -p "${profile}" --delete-generations +5 >/dev/null 2>&1 || true
      printf '%s\n' "$desired" > "${state}/current.sha"
      log "activated $desired"
      ${lib.optionalString svc.restartOnUpdate ''
        systemctl restart ${name}.service || log "restart of ${name}.service failed"
      ''}
    '';

  # NOTE on structure: the top-level `config` attrset below must have a
  # STATIC shape — deriving the mkMerge list at the top level from
  # config.fort.tracked causes infinite recursion (the module system cannot
  # resolve the merge structure without evaluating config). Per-service
  # merging therefore happens inside each option's value.
  profileFor = name: "${profileBase}/${name}";
  fetchUnitFor = name: "fort-tracked-${name}-fetch";
  perService = f: lib.mapAttrsToList f cfg;
in
{
  options.fort.tracked = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          repo = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "GitHub owner/repo shorthand (ignored when gitUrl is set).";
          };

          gitUrl = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Full clone URL; overrides repo (e.g. a forgejo remote).";
          };

          branch = lib.mkOption {
            type = lib.types.str;
            default = "main";
            description = "Branch whose tip is tracked when autoUpdate is enabled.";
          };

          flakeAttr = lib.mkOption {
            type = lib.types.str;
            default = "default";
            description = "Flake package attribute to build from the checkout.";
          };

          autoUpdate = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              If true, poll the branch tip and deploy on change. If false,
              deployment is triggered by writing a commit sha to
              /var/lib/fort-tracked/<name>/desired.sha.
            '';
          };

          pollInterval = lib.mkOption {
            type = lib.types.str;
            default = "15m";
            description = "Polling interval (systemd time span) when autoUpdate is enabled.";
          };

          exec = lib.mkOption {
            type = lib.types.str;
            description = ''
              Runner command line. The leading word is resolved against the
              tracked profile's bin/ via ExecSearchPath, so use a bare binary
              name (e.g. "golemd --config /etc/...").
            '';
          };

          restartOnUpdate = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Restart the runner after a successful profile flip.";
          };

          addToPath = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Add the tracked profile's bin/ to interactive shell PATH.";
          };

          unit = lib.mkOption {
            type = lib.types.attrs;
            default = { };
            description = ''
              Merged into the generated systemd.services.<name> definition:
              description, after, wants, path, preStart, environment,
              serviceConfig (User, StateDirectory, ...), etc.
            '';
          };

          expose = lib.mkOption {
            type = lib.types.nullOr lib.types.attrs;
            default = null;
            description = ''
              Optional fort.cluster.services entry (port, visibility, sso,
              ...) to expose the tracked service through the normal
              vhost/SSO/DNS machinery. The service name is filled in.
            '';
          };
        };
      }
    );
    default = { };
    description = "Runtime-deployed services tracked from project flakes.";
  };

  config = {
    assertions = perService (
      name: svc: {
        assertion = svc.repo != null || svc.gitUrl != null;
        message = "fort.tracked.${name}: either repo or gitUrl must be set";
      }
    );

    systemd.tmpfiles.rules = lib.optionals (cfg != { }) (
      [ "d ${stateBase} 0755 root root -" ]
      ++ perService (name: _: "d ${stateBase}/${name} 0755 root root -")
    );

    systemd.services = lib.mkMerge (
      perService (
        name: svc: {
          ${fetchUnitFor name} = {
            description = "Fort tracked service ${name} - fetch, build, activate";
            after = [ "network-online.target" ];
            wants = [ "network-online.target" ];
            # Manual mode has no timer; run at boot to verify the pinned sha
            # (exits fast when current == desired and the profile exists).
            wantedBy = lib.optionals (!svc.autoUpdate) [ "multi-user.target" ];
            serviceConfig = {
              Type = "oneshot";
              TimeoutStartSec = "1h";
              ExecStart = fetchScriptFor name svc;
            };
          };

          ${name} = lib.mkMerge [
            {
              wantedBy = [ "multi-user.target" ];
              unitConfig.ConditionPathExists = profileFor name;
              serviceConfig = {
                ExecSearchPath = "${profileFor name}/bin";
                ExecStart = svc.exec;
                Restart = lib.mkDefault "on-failure";
                RestartSec = lib.mkDefault 5;
              };
            }
            svc.unit
          ];
        }
      )
    );

    # Polling mode: timer drives the fetch oneshot.
    systemd.timers = lib.mkMerge (
      perService (
        name: svc:
        lib.optionalAttrs svc.autoUpdate {
          ${fetchUnitFor name} = {
            description = "Fort tracked service ${name} - poll for updates";
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnBootSec = "2m";
              OnUnitActiveSec = svc.pollInterval;
              RandomizedDelaySec = "30s";
            };
          };
        }
      )
    );

    # Manual mode: a path unit fires the fetch oneshot when desired.sha is
    # written. Deliberately PathChanged=, not PathExists=: a persistent file
    # plus a oneshot under PathExists is a documented retrigger loop.
    systemd.paths = lib.mkMerge (
      perService (
        name: svc:
        lib.optionalAttrs (!svc.autoUpdate) {
          ${fetchUnitFor name} = {
            description = "Fort tracked service ${name} - watch desired.sha";
            wantedBy = [ "multi-user.target" ];
            pathConfig = {
              PathChanged = "${stateBase}/${name}/desired.sha";
              Unit = "${fetchUnitFor name}.service";
            };
          };
        }
      )
    );

    environment.extraInit = lib.mkAfter (
      lib.concatStrings (
        perService (
          name: svc:
          lib.optionalString svc.addToPath ''
            export PATH="${profileFor name}/bin:$PATH"
          ''
        )
      )
    );

    fort.cluster.services = lib.concatLists (
      perService (name: svc: lib.optional (svc.expose != null) ({ inherit name; } // svc.expose))
    );
  };
}
