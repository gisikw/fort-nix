{ rootManifest, ... }:
{ config, lib, pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  qmd = import ../../pkgs/qmd { inherit pkgs; };
  user = "qmd";
  dataDir = "/var/lib/qmd";
  runnerDir = "/var/lib/qmd-runner";
  tokenFile = "${runnerDir}/registration-token";
  port = 8181;

  # Consumer handler: receives runner-token response, stores it, and registers the runner
  runnerTokenHandler = pkgs.writeShellScript "runner-token-consumer" ''
    set -euo pipefail
    payload=$(${pkgs.coreutils}/bin/cat)

    # Store the registration token
    echo "$payload" | ${pkgs.jq}/bin/jq -r '.token' > ${tokenFile}
    chown ${user}:${user} ${tokenFile}
    chmod 0400 ${tokenFile}

    # If runner already registered with a valid id, skip
    RUNNER_FILE="${runnerDir}/.runner"
    if [ -f "$RUNNER_FILE" ]; then
      RUNNER_ID=$(${pkgs.jq}/bin/jq -r '.id' "$RUNNER_FILE")
      if [ "$RUNNER_ID" != "0" ] && [ "$RUNNER_ID" != "null" ]; then
        echo "Runner already registered (id=$RUNNER_ID), skipping"
        exit 0
      fi
      # Bad registration — remove and re-register
      rm -f "$RUNNER_FILE"
    fi

    # Register using the token
    cd ${runnerDir}
    ${pkgs.su}/bin/su -s /bin/sh ${user} -c '${pkgs.forgejo-runner}/bin/forgejo-runner register --instance "https://git.${domain}" --token "$(cat ${tokenFile})" --name "lordhenry-hoard" --labels "hoard:host" --no-interactive'

    # Restart runner daemon to pick up new registration
    ${pkgs.systemd}/bin/systemctl restart qmd-runner || true
  '';
in
{
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
      # Force Node to resolve "localhost" as 127.0.0.1 — QMD's HTTP server
      # hardcodes listen("localhost") and NixOS resolves it to ::1 (IPv6),
      # but nginx proxies to 127.0.0.1 (IPv4).
      NODE_OPTIONS = "--dns-result-order=ipv4first";
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

  # Write runner config (always, so label/PATH changes are picked up)
  systemd.services.qmd-runner-config = {
    description = "Write QMD runner config";
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      User = user;
      Group = user;
      WorkingDirectory = runnerDir;
      RemainAfterExit = true;
    };

    script = ''
      cat > "${runnerDir}/config.yml" <<'YAML'
runner:
  labels:
    - "hoard:host"
  envs:
    PATH: "${lib.makeBinPath [ qmd pkgs.bash pkgs.coreutils pkgs.gnused pkgs.git pkgs.gnutar pkgs.gzip pkgs.nodejs pkgs.jq ]}"
    HOME: "${dataDir}"
YAML
    '';
  };

  # Forgejo Actions runner daemon (hoard jobs only)
  systemd.services.qmd-runner = {
    description = "Forgejo Actions runner (hoard)";
    after = [ "network.target" "qmd-runner-config.service" ];
    requires = [ "qmd-runner-config.service" ];
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
      RestartSec = "30s";  # Longer backoff — waits for registration via control plane
    };
  };

  # Request runner registration token from forge via control plane
  fort.host.needs.runner-token.qmd = {
    from = "drhorrible";
    request = {};
    handler = runnerTokenHandler;
    nag = "5m";
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
