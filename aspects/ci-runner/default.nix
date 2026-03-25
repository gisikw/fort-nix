{
  rootManifest,
  ...
}:
{ config, lib, pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  fortCli = import ../../pkgs/fort { inherit pkgs domain; };
  user = "ci-runner";
  runnerDir = "/var/lib/ci-runner";
  tokenFile = "${runnerDir}/registration-token";
  hostName = config.networking.hostName;
  atticCiToken = "${runnerDir}/attic-ci-token";
  atticCacheUrl = "https://cache.${domain}";

  # Handler for attic-token: extract push token for CI cache access
  atticTokenHandler = pkgs.writeShellScript "ci-runner-attic-token" ''
    set -euo pipefail
    payload=$(${pkgs.coreutils}/bin/cat)
    echo "$payload" | ${pkgs.jq}/bin/jq -r '.pushToken' > ${atticCiToken}
    chown ${user}:${user} ${atticCiToken}
    chmod 0400 ${atticCiToken}
  '';

  runnerTokenHandler = pkgs.writeShellScript "ci-runner-token-consumer" ''
    set -euo pipefail
    payload=$(${pkgs.coreutils}/bin/cat)

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
      rm -f "$RUNNER_FILE"
    fi

    cd ${runnerDir}
    ${pkgs.su}/bin/su -s /bin/sh ${user} -c '${pkgs.forgejo-runner}/bin/forgejo-runner register --instance "https://git.${domain}" --token "$(cat ${tokenFile})" --name "${hostName}-runner" --labels "nixos:host" --no-interactive'

    ${pkgs.systemd}/bin/systemctl restart ci-runner || true
  '';
in
{
  age.secrets.ci-agent-key = {
    file = ../../apps/forgejo/ci-agent-key.age;
    owner = user;
    group = user;
    mode = "0400";
  };

  users.users.${user} = {
    isSystemUser = true;
    group = user;
    home = runnerDir;
    createHome = true;
  };
  users.groups.${user} = {};

  systemd.tmpfiles.rules = [
    "d ${runnerDir} 0750 ${user} ${user} -"
  ];

  # Write runner config (always, so label/PATH changes are picked up)
  systemd.services.ci-runner-config = {
    description = "Write CI runner config";
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
    - "nixos:host"
  envs:
    PATH: "${lib.makeBinPath [ pkgs.bash pkgs.coreutils pkgs.gnused pkgs.nix pkgs.git pkgs.gnutar pkgs.gzip pkgs.nodejs pkgs.jq pkgs.age pkgs.curl pkgs.attic-client fortCli ]}"
    FORT_SSH_KEY: "${config.age.secrets.ci-agent-key.path}"
    FORT_ORIGIN: "ci"
    ATTIC_TOKEN_FILE: "${atticCiToken}"
    ATTIC_CACHE_URL: "${atticCacheUrl}"
YAML
    '';
  };

  # Forgejo Actions runner daemon
  systemd.services.ci-runner = {
    description = "Forgejo Actions runner";
    after = [ "network.target" "ci-runner-config.service" ];
    requires = [ "ci-runner-config.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.forgejo-runner pkgs.bash pkgs.coreutils pkgs.nix pkgs.git pkgs.nodejs ];

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
      RestartSec = "30s";
    };
  };

  # Request runner registration token from forge
  fort.host.needs.runner-token.ci-runner = {
    from = "drhorrible";
    request = {};
    handler = runnerTokenHandler;
    nag = "5m";
  };

  # Request attic cache push token from forge
  fort.host.needs.attic-token.ci-runner = {
    from = "drhorrible";
    request = {};
    handler = atticTokenHandler;
  };
}
