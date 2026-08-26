# Familiar instance runner.
#
# Runs a private Familiar instance (config/identity/memory repo) against the
# code tree maintained by fort.tracked.<trackedName> (see
# common/fort/tracked.nix). The split is deliberate:
#
#   code  = gisikw/familiar, tracked + built + validated by fort.tracked
#   state = a private instance repo (familiar.toml, identity/, versioned
#           memory) that must NEVER be part of the familiar flake
#
# The unit execs <tracked repo>/familiar.sh --config <instanceDir>/familiar.toml
# server. The tracked fetch unit restarts this service after a successful
# update (declare it in the tracked service's restartUnits).
#
# Instance provisioning: if instanceDir does not exist and instanceRepo is
# set, it is cloned at first start. An existing directory is left untouched.
#
# CAUTION (archive-fork invariant): cloning a live instance repo onto a second
# host and running both means two agents committing divergent memory. Only
# point instanceRepo at a repo whose instance is not running anywhere else.
{
  hostManifest,
  # Absolute path of the private instance directory (familiar.toml lives here).
  instanceDir,
  # Optional git URL cloned into instanceDir when it is missing.
  instanceRepo ? null,
  # Name of the fort.tracked entry providing the code tree.
  trackedName ? "familiar",
  # systemd unit name for this instance.
  serviceName ? "familiar-instance",
  user,
  group ? "users",
  home ? "/home/${user}",
  ...
}:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  repoDir = "/var/lib/fort-tracked/${trackedName}/repo";
in
{
  systemd.services.${serviceName} = {
    description = "Familiar instance (${instanceDir}) on tracked ${trackedName} tree";
    after = [
      "network-online.target"
      "fort-tracked-${trackedName}-fetch.service"
    ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    # Until the first successful tracked fetch there is nothing to run; the
    # fetch unit's post-update restart cold-starts us once the tree exists.
    unitConfig.ConditionPathExists = "${repoDir}/familiar.sh";
    path = [
      pkgs.bash
      pkgs.coreutils
      pkgs.git
      pkgs.nix
      pkgs.tmux
      pkgs.curl
      pkgs.jq
      pkgs.gnused
      pkgs.gnugrep
      pkgs.gawk
      pkgs.findutils
      pkgs.util-linux
      pkgs.openssh
    ];
    preStart = ''
      if [ ! -e "${instanceDir}/familiar.toml" ]; then
        ${
          if instanceRepo != null then
            ''
              if [ ! -d "${instanceDir}" ]; then
                echo "cloning instance repo ${instanceRepo}"
                git clone "${instanceRepo}" "${instanceDir}"
              fi
            ''
          else
            ''
              echo "instance dir ${instanceDir} has no familiar.toml and no instanceRepo is configured" >&2
              exit 1
            ''
        }
      fi
    '';
    environment = {
      HOME = home;
      FAMILIAR_CONFIG_PATH = "${instanceDir}/familiar.toml";
    };
    serviceConfig = {
      User = user;
      Group = group;
      WorkingDirectory = repoDir;
      ExecStart = "${repoDir}/familiar.sh --config ${instanceDir}/familiar.toml server";
      Restart = "on-failure";
      RestartSec = 10;
      # Default KillMode (control-group) on purpose: familiar.sh re-execs
      # through a nix devshell, so MainPID is a wrapper and process-scoped
      # signalling would orphan the supervisor tree (children then hold ports
      # across restarts). Cost: the detached Presence runtime dies with the
      # unit despite teardown_presence=false — acceptable for a test
      # instance. Preserving Presence across unit restarts needs presence.sh
      # to escape the cgroup (e.g. systemd-run --scope); future work before
      # a primary instance runs under this unit.
      TimeoutStopSec = 30;
    };
  };
}
