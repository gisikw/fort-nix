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
# The outer unit execs <tracked repo>/familiar.sh --config
# <instanceDir>/familiar.toml server. A separate Presence unit owns the resident
# tmux/Pi cgroup. The tracked fetch unit therefore restarts only the outer
# service after a successful update (declare it in restartUnits).
#
# One-time migration: declarative activation starts the Presence monitor but
# cannot adopt a tmux server already born in the old outer cgroup. Stop the
# outer unit once; the monitor detects the lost tmux and restarts into its own
# cgroup. Start the outer unit again and verify ownership before enabling code
# updates that assume restart-independent Presence.
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
  # systemd unit name for the outer Familiar supervisor.
  serviceName ? "familiar-instance",
  # Presence has an independent lifecycle so routine outer-stack deploys do
  # not kill the resident conversation. These defaults match Familiar's
  # private-instance layout but remain explicit escape hatches.
  presenceServiceName ? "${serviceName}-presence",
  presenceStateDir ? "${instanceDir}/state/presence",
  presenceSocket ? "${presenceStateDir}/tmux.sock",
  presenceSession ? "presence",
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
  presenceCtl = "${repoDir}/services/presence/presence.sh";
  runtimePath = [
    pkgs.bash
    pkgs.bashInteractive
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
    pkgs.systemd
  ];
  instanceConditions = [
    "${repoDir}/familiar.sh"
  ]
  ++ lib.optional (instanceRepo == null) "${instanceDir}/familiar.toml";
  provisionInstance = ''
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
  presenceEnvironment = {
    HOME = home;
    FAMILIAR_CONFIG_PATH = "${instanceDir}/familiar.toml";
    FAMILIAR_REPO = repoDir;
    FAMILIAR_PRESENCE_CWD = instanceDir;
    FAMILIAR_PRESENCE_STATE_DIR = presenceStateDir;
    FAMILIAR_PRESENCE_SOCKET = presenceSocket;
    FAMILIAR_PRESENCE_SESSION = presenceSession;
    FAMILIAR_PRESENCE_BASH = "${pkgs.bash}/bin/bash";
    FAMILIAR_INTERACTIVE_SHELL = "${pkgs.bashInteractive}/bin/bash";
  };
  # ExecStart itself creates tmux: systemd may reap daemons forked by
  # ExecStartPre before starting the main process. The foreground monitor keeps
  # ownership of the cgroup, announces readiness only after Presence exists,
  # and uses pinned tmux rather than re-reading a moving tracked checkout.
  presenceMonitor = pkgs.writeShellScript "${presenceServiceName}-monitor" ''
    set -euo pipefail
    ctl=${lib.escapeShellArg presenceCtl}
    socket=${lib.escapeShellArg presenceSocket}
    session=${lib.escapeShellArg presenceSession}
    target="$session:0.0"

    "$ctl" ensure
    ${pkgs.systemd}/bin/systemd-notify --ready --status="Presence is live at $socket"

    while :; do
      if ! ${pkgs.tmux}/bin/tmux -S "$socket" has-session -t "$session" >/dev/null 2>&1; then
        echo "familiar presence monitor: tmux session disappeared" >&2
        exit 1
      fi
      pane_dead="$(${pkgs.tmux}/bin/tmux -S "$socket" display-message -p -t "$target" '#{pane_dead}' 2>/dev/null || true)"
      if [ "$pane_dead" != 0 ]; then
        echo "familiar presence monitor: resident pane is absent or dead" >&2
        exit 1
      fi
      sleep 2
    done
  '';
in
{
  # This unit owns the resident tmux server, worker, and Pi process. It is not
  # PartOf the outer stack: restarting familiar-instance must leave Presence
  # untouched. An explicit Presence stop/restart still tears down the complete
  # dedicated cgroup.
  systemd.services.${presenceServiceName} = {
    description = "Familiar Presence runtime (${instanceDir})";
    after = [
      "network-online.target"
      "fort-tracked-${trackedName}-fetch.service"
    ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    unitConfig.ConditionPathExists = instanceConditions ++ [ presenceCtl ];
    path = runtimePath;
    preStart = provisionInstance;
    environment = presenceEnvironment;
    serviceConfig = {
      User = user;
      Group = group;
      Type = "notify";
      NotifyAccess = "all";
      WorkingDirectory = instanceDir;
      ExecStart = presenceMonitor;
      ExecStop = "${presenceCtl} stop";
      Restart = "on-failure";
      RestartSec = 2;
      KillMode = "control-group";
      TimeoutStartSec = 60;
      TimeoutStopSec = 30;
    };
  };

  systemd.services.${serviceName} = {
    description = "Familiar instance (${instanceDir}) on tracked ${trackedName} tree";
    after = [
      "network-online.target"
      "fort-tracked-${trackedName}-fetch.service"
      "${presenceServiceName}.service"
    ];
    requires = [ "${presenceServiceName}.service" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    # The first activation cannot move an already-running tmux between cgroups.
    # Keep the old outer unit alive until the operator deliberately stops it;
    # the Presence monitor then restarts and recreates tmux under its own unit.
    # Explicit tracked-service restarts continue to work normally.
    restartIfChanged = false;
    # Until the first successful tracked fetch there is nothing to run; the
    # fetch unit's post-update restart cold-starts us once the tree exists.
    # An explicitly provisioned private instance (instanceRepo = null) stays
    # cleanly inactive until its custody transfer lands familiar.toml. The
    # operator starts it after transfer; configured clone-on-start instances
    # must not receive this second condition or preStart could never clone.
    unitConfig.ConditionPathExists = instanceConditions;
    path = runtimePath;
    preStart = provisionInstance;
    environment = {
      HOME = home;
      FAMILIAR_CONFIG_PATH = "${instanceDir}/familiar.toml";
    };
    serviceConfig = {
      User = user;
      Group = group;
      WorkingDirectory = instanceDir;
      ExecStart = "${repoDir}/familiar.sh --config ${instanceDir}/familiar.toml server";
      Restart = "on-failure";
      RestartSec = 10;
      # Default KillMode (control-group) on purpose: familiar.sh re-execs
      # through a nix devshell, so process-scoped signalling would orphan the
      # supervised component tree and leave ports occupied. Presence is safe
      # because its tmux server belongs to the independent unit above.
      KillMode = "control-group";
      TimeoutStopSec = 30;
    };
  };
}
