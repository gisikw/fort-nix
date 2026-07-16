{
  rootManifest,
  deviceProfileManifest,
  ...
}:
{ config, lib, pkgs, ... }:
let
  isDarwin = (deviceProfileManifest.platform or "nixos") == "darwin";
  domain = rootManifest.fortConfig.settings.domain;
  fortCli = import ../../pkgs/fort { inherit pkgs domain; };
  user = "ci-runner";
  runnerDir = "/var/lib/ci-runner";
  tokenFile = "${runnerDir}/registration-token";
  hostName = config.networking.hostName;
  atticCiToken = "${runnerDir}/attic-ci-token";
  atticCacheUrl = "https://cache.${domain}";

  # --- Darwin (macOS/iOS build box) ---
  #
  # The runner daemon runs as admin (keychain + simulator + provisioning
  # profiles live in admin's home), registered with macos:host + ios:host
  # labels (matching the nixos:host / hoard:host convention). Jobs get the
  # Apple toolchain from the system paths (/usr/bin/xcodebuild, security,
  # xcrun) plus a nix PATH for git/node/jq — node is required by
  # actions/checkout. No postgres, no attic, no FORT_SSH_KEY: iOS builds
  # need none of them (add when a workflow does).
  darwinRunnerLabel = "network.gisi.fort.ci-runner";
  darwinJobPath = "${lib.makeBinPath [
    pkgs.bash
    pkgs.coreutils
    pkgs.gnused
    pkgs.git
    pkgs.jq
    pkgs.curl
    pkgs.gnutar
    pkgs.gzip
    pkgs.nodejs
  ]}:/usr/bin:/bin:/usr/sbin:/sbin";

  # Registration consumer — same idempotency dance as the Linux handler
  # (.runner id check), with darwin's /usr/bin/su and launchctl.
  darwinRunnerTokenHandler = pkgs.writeShellScript "ci-runner-token-consumer-darwin" ''
    set -euo pipefail
    payload=$(${pkgs.coreutils}/bin/cat)

    echo "$payload" | ${pkgs.jq}/bin/jq -r '.token' > ${tokenFile}
    chown admin:staff ${tokenFile}
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

    /usr/bin/su admin -c 'cd ${runnerDir} && ${pkgs.forgejo-runner}/bin/forgejo-runner register --instance "https://git.${domain}" --token "$(cat ${tokenFile})" --name "${hostName}-runner" --labels "macos:host,ios:host" --no-interactive'

    /bin/launchctl kickstart -k system/${darwinRunnerLabel} || true
  '';

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
if isDarwin then
{
  # Runner state dir + config + log file. config.yml is (re)written every
  # activation so label/PATH changes are picked up (parity with the
  # ci-runner-config oneshot on Linux). The log is pre-created root-side and
  # chowned because launchd opens Standard{Out,Error}Path as the daemon's
  # UserName and /var/log is not admin-writable (see muse-serve).
  system.activationScripts.preActivation.text = lib.mkAfter ''
    mkdir -p ${runnerDir}
    chown admin:staff ${runnerDir}
    chmod 750 ${runnerDir}
    touch /var/log/ci-runner.log
    chown admin:staff /var/log/ci-runner.log
    chmod 0644 /var/log/ci-runner.log
    cat > ${runnerDir}/config.yml <<'YAML'
runner:
  labels:
    - "macos:host"
    - "ios:host"
  envs:
    PATH: "${darwinJobPath}"
YAML
    chown admin:staff ${runnerDir}/config.yml
  '';

  launchd.daemons.ci-runner = {
    serviceConfig = {
      Label = darwinRunnerLabel;
      ProgramArguments = [
        "${pkgs.forgejo-runner}/bin/forgejo-runner"
        "daemon"
        "-c"
        "${runnerDir}/config.yml"
      ];
      UserName = "admin";
      GroupName = "staff";
      WorkingDirectory = runnerDir;
      RunAtLoad = true;
      KeepAlive = true;
      # Exits until the registration handler writes .runner; retry calmly.
      ThrottleInterval = 30;
      StandardOutPath = "/var/log/ci-runner.log";
      StandardErrorPath = "/var/log/ci-runner.log";
      EnvironmentVariables = {
        HOME = "/Users/admin";
        PATH = darwinJobPath;
      };
    };
  };

  # Request runner registration token from forge
  fort.host.needs.runner-token.ci-runner = {
    from = "drhorrible";
    request = { };
    handler = darwinRunnerTokenHandler;
    nag = "5m";
  };
}
else
{
  # PostgreSQL for CI pipelines that need a database (e.g., cranium)
  services.postgresql = {
    enable = true;
    authentication = ''
      local all all trust
      host all all 127.0.0.1/32 trust
      host all all ::1/128 trust
    '';
  };

  sops.secrets.ci-agent-key = {
    sopsFile = ../../apps/forgejo/ci-agent-key.sops;
    format = "binary";
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
    PATH: "${lib.makeBinPath [ pkgs.bash pkgs.coreutils pkgs.gnused pkgs.nix pkgs.git pkgs.gnutar pkgs.gzip pkgs.nodejs pkgs.jq pkgs.sops pkgs.curl pkgs.attic-client fortCli ]}"
    FORT_SSH_KEY: "${config.sops.secrets.ci-agent-key.path}"
    FORT_ORIGIN: "ci"
    ATTIC_TOKEN_FILE: "${atticCiToken}"
    ATTIC_CACHE_URL: "${atticCacheUrl}"
YAML
    '';
  };

  # Forgejo Actions runner daemon
  systemd.services.ci-runner = {
    description = "Forgejo Actions runner";
    after = [ "network.target" "ci-runner-config.service" "postgresql.service" ];
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
