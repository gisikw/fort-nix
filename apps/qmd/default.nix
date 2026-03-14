{ rootManifest, ... }:
{ config, lib, pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  qmd = import ../../pkgs/qmd { inherit pkgs; };
  user = "qmd";
  dataDir = "/var/lib/qmd";
  runnerDir = "/var/lib/qmd-runner";
  port = 8181;
in
{
  # Decrypt runner shared secret (already keyed for all devices in secrets.nix)
  age.secrets.qmd-runner-secret = {
    file = ../forgejo/runner-secret.age;
    owner = user;
    mode = "0400";
  };

  users.users.${user} = {
    isSystemUser = true;
    group = user;
    home = dataDir;
    createHome = true;
  };
  users.groups.${user} = {};

  systemd.tmpfiles.rules = [
    "d ${dataDir} 0750 ${user} ${user} -"
    "d ${dataDir}/data 0750 ${user} ${user} -"
    "d ${runnerDir} 0750 ${user} ${user} -"
  ];

  # QMD MCP HTTP server
  systemd.services.qmd = {
    description = "QMD markdown search MCP server";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    environment = {
      HOME = dataDir;
    };

    serviceConfig = {
      Type = "simple";
      User = user;
      Group = user;
      WorkingDirectory = dataDir;
      ExecStart = "${qmd}/bin/qmd mcp --http --port ${toString port}";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  # Create runner config and register with Forgejo
  systemd.services.qmd-runner-register = {
    description = "Register QMD Forgejo Actions runner";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.forgejo-runner ];

    serviceConfig = {
      Type = "oneshot";
      User = user;
      Group = user;
      WorkingDirectory = runnerDir;
      RemainAfterExit = true;
    };

    script = ''
      set -euo pipefail

      # Runner config: hoard label only, so this runner exclusively serves hoard workflows.
      # PATH includes qmd for embedding, git for checkout, and standard tools.
      cat > "${runnerDir}/config.yml" <<EOF
      runner:
        labels:
          - "hoard:host"
        envs:
          PATH: "${lib.makeBinPath [ qmd pkgs.bash pkgs.coreutils pkgs.gnused pkgs.git pkgs.gnutar pkgs.gzip pkgs.nodejs pkgs.jq ]}"
          HOME: "${dataDir}"
      EOF

      RUNNER_FILE="${runnerDir}/.runner"
      if [ -f "$RUNNER_FILE" ]; then
        echo "Runner already registered"
        exit 0
      fi

      RUNNER_SECRET=$(cat ${config.age.secrets.qmd-runner-secret.path})

      echo "Registering hoard runner with Forgejo"
      forgejo-runner create-runner-file \
        --instance "https://git.${domain}" \
        --secret "$RUNNER_SECRET" \
        --name "lordhenry-hoard"

      echo "Runner registered"
    '';
  };

  # Forgejo Actions runner daemon (hoard jobs only)
  systemd.services.qmd-runner = {
    description = "Forgejo Actions runner (hoard)";
    after = [ "network.target" "qmd-runner-register.service" ];
    requires = [ "qmd-runner-register.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.forgejo-runner pkgs.bash pkgs.coreutils pkgs.git pkgs.nodejs ];

    environment = {
      HOME = runnerDir;
    };

    serviceConfig = {
      Type = "simple";
      User = user;
      Group = user;
      WorkingDirectory = runnerDir;
      ExecStart = "${pkgs.forgejo-runner}/bin/forgejo-runner daemon -c ${runnerDir}/config.yml";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  fort.cluster.services = [
    {
      name = "qmd";
      port = port;
      visibility = "local";
      sso = {
        mode = "token";
        vpnBypass = true;
      };
    }
  ];
}
