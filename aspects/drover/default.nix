{
  rootManifest,
  deviceProfileManifest,
  coordinator ? false,
  expectedPort,
  tiamatTokenFile,
  ...
}:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  isDarwin = (deviceProfileManifest.platform or "nixos") == "darwin";
  host = config.networking.hostName;
  domain = rootManifest.fortConfig.settings.domain;
  controlPort = 9840;
  sshPort = 9841;
  localSshPort = 22222;
  session = "drover";
  nodeUser = "drover-node";
  nodeGroup = "drover-node";
  nodeHome = "/var/lib/drover-node";
  nodeState = "${nodeHome}/state";
  nodeSocket = "${nodeHome}/.config/herdr/sessions/${session}/herdr.sock";
  piProfile = "${nodeHome}/pi";

  droverRevision = "0a430be873d1eb7e0929478ef11ba5518f482642";
  familiarRevision = "0ba216f41e4f7c1b3f5dc6efcba59281034cd7f7";
  droverFlake = builtins.getFlake "github:gisikw/drover/${droverRevision}";
  familiarFlake = builtins.getFlake "github:gisikw/familiar/${familiarRevision}";
  system = pkgs.stdenv.hostPlatform.system;
  drover = droverFlake.packages.${system}.default;
  # This is exactly the Herdr input locked by the reviewed Drover generation.
  herdr = droverFlake.inputs.herdr.packages.${system}.default;
  # Familiar's package is its reviewed, patched Pi rather than an ambient profile.
  pi = familiarFlake.packages.${system}.pi-coding-agent;
  familiarSource = familiarFlake.outPath;
  python = pkgs.python3;

  publicKeys = {
    coordinatorHost = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPqzDpmjN706jIJ6PwZOkMg61JEnyqlb0Kl1UKXuCWQ2 drover-coordinator-host";
    agentsClient = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOsUluPiLvYKJSzVzJByrinO1iheS4c1+5MgQkI1Q9fd drover-agents-client";
    azulaHost = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBtRBUZ6qQfyrcmy1RtbpC2km2jd8pchP2VD08+v4e+a drover-azula-host";
    azulaTunnel = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEhSgqCAmWxLPgbGebpjcOM3r/K/Vfd9rwGetlBstiA2 drover-azula-tunnel";
    ratchedHost = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIICT5b+zXhx7jQTiKIQCAk1e9wbP6TWbZJvbMd/J8w4G drover-ratched-host";
    ratchedTunnel = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMLH/yZqypZdCr/OwYiNRJbtj8sEsorcYbghjLFRzNGM drover-ratched-tunnel";
    obrienHost = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBd7LIxn1frWflk4FMz1+cjJXCmth2IxeyIJq2/Z8xPa drover-obrien-host";
    obrienTunnel = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKgKUjG2/cEGcPzETxyu+owhZ3eJqlBuY3qNuGFSkYS8 drover-obrien-tunnel";
  };
  hostKey = publicKeys.${host + "Host"};

  runtimePackages = [
    drover
    herdr
    pi
    python
    pkgs.git
    pkgs.ripgrep
    pkgs.fd
    pkgs.openssh
    pkgs.bashInteractive
    pkgs.coreutils
    pkgs.findutils
    pkgs.gnugrep
    pkgs.gnused
    pkgs.gawk
    pkgs.gnutar
    pkgs.gzip
    pkgs.curl
    pkgs.jq
  ]
  ++ lib.optionals (!isDarwin) [ pkgs.util-linux ];
  runtimePath = lib.makeBinPath runtimePackages;

  piSettings = pkgs.writeText "drover-pi-settings.json" (
    builtins.toJSON {
      extensions = [ "${familiarSource}/integrations/pi/extensions/tiamat" ];
      defaultProjectTrust = "never";
      lastChangelogVersion = "0.84.1";
    }
  );

  nodeConfig = pkgs.writeText "drover-${host}-node.json" (
    builtins.toJSON {
      url = "https://drover.${domain}";
      name = host;
      ssh_user = nodeUser;
      inherit session;
      host_key = hostKey;
      socket = nodeSocket;
      identity_file = "${nodeState}/identity.json";
      ssh_config = "${nodeHome}/.ssh/coordinator.conf";
      tunnel_alias = "drover-coordinator-tunnel";
      local_ssh_port = localSshPort;
    }
  );

  coordinatorKnownHosts = pkgs.writeText "drover-coordinator-known-hosts" ''
    [drover.${domain}]:${toString sshPort} ${publicKeys.coordinatorHost}
  '';
  tunnelConfig = pkgs.writeText "drover-${host}-tunnel.conf" ''
    Host drover-coordinator-tunnel
      HostName drover.${domain}
      Port ${toString sshPort}
      User drover-tunnel
      IdentityFile ${config.sops.secrets.drover-node-tunnel-key.path}
      UserKnownHostsFile ${nodeHome}/.ssh/coordinator_known_hosts
      IdentitiesOnly yes
      StrictHostKeyChecking yes
  '';
  nodeAuthorizedKeys = pkgs.writeText "drover-node-authorized-keys" ''
    ${publicKeys.agentsClient}
  '';
  nodeSshdConfig = pkgs.writeText "drover-${host}-sshd.conf" ''
    ListenAddress 127.0.0.1
    Port ${toString localSshPort}
    PidFile /var/run/drover-node-sshd.pid
    HostKey ${config.sops.secrets.drover-node-host-key.path}
    AuthorizedKeysFile ${nodeAuthorizedKeys}
    AllowUsers ${nodeUser}
    AuthenticationMethods publickey
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PermitRootLogin no
    PermitEmptyPasswords no
    AllowTcpForwarding no
    AllowStreamLocalForwarding no
    AllowAgentForwarding no
    X11Forwarding no
    PermitTTY yes
    GatewayPorts no
    UseDNS no
    LogLevel VERBOSE
    Subsystem sftp internal-sftp
  '';

  nodeWrapper = pkgs.writeShellScript "drover-${host}-node" ''
    set -eu
    export DROVER_ENROLLMENT_TOKEN="$(${pkgs.coreutils}/bin/cat ${config.sops.secrets.drover-enrollment-token.path})"
    exec ${drover}/bin/drover --config ${nodeConfig} serve
  '';

  coordinatorConfig = pkgs.writeText "drover-coordinator.json" (
    builtins.toJSON {
      listen = "127.0.0.1:${toString controlPort}";
      state = "/var/lib/drover-coordinator/registry";
      first_port = 24000;
    }
  );
  coordinatorWrapper = pkgs.writeShellScript "drover-coordinator" ''
    set -eu
    export DROVER_ENROLLMENT_TOKEN="$(${pkgs.coreutils}/bin/cat ${config.sops.secrets.drover-enrollment-token.path})"
    export DROVER_CLIENT_TOKEN="$(${pkgs.coreutils}/bin/cat ${config.sops.secrets.drover-client-token.path})"
    exec ${drover}/bin/drover --config ${coordinatorConfig} coordinator
  '';
  healthScript = pkgs.writeShellScript "drover-coordinator-health" ''
    set -eu
    export DROVER_CLIENT_TOKEN="$(${pkgs.coreutils}/bin/cat ${config.sops.secrets.drover-client-token.path})"
    exec ${python}/bin/python - <<'PY'
    import os, time, urllib.request
    request = urllib.request.Request(
        "http://127.0.0.1:9840/v1/machines",
        headers={"Authorization": "Bearer " + os.environ["DROVER_CLIENT_TOKEN"]},
    )
    for attempt in range(30):
        try:
            with urllib.request.urlopen(request, timeout=2) as response:
                if response.status == 200:
                    raise SystemExit(0)
        except Exception:
            if attempt == 29:
                raise
            time.sleep(1)
    PY
  '';

  tunnelKeys = pkgs.writeText "drover-tunnel-authorized-keys" ''
    restrict,port-forwarding,permitlisten="127.0.0.1:24000" ${publicKeys.azulaTunnel}
    restrict,port-forwarding,permitlisten="127.0.0.1:24001" ${publicKeys.ratchedTunnel}
    restrict,port-forwarding,permitlisten="127.0.0.1:24002" ${publicKeys.obrienTunnel}
  '';
  jumpKeys = pkgs.writeText "drover-jump-authorized-keys" ''
    restrict,port-forwarding,permitopen="127.0.0.1:24000",permitopen="127.0.0.1:24001",permitopen="127.0.0.1:24002" ${publicKeys.agentsClient}
  '';
  coordinatorSshdConfig = pkgs.writeText "drover-coordinator-sshd.conf" ''
    ListenAddress 0.0.0.0
    Port ${toString sshPort}
    PidFile /run/drover-coordinator-sshd.pid
    HostKey ${config.sops.secrets.drover-coordinator-host-key.path}
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PermitRootLogin no
    PermitEmptyPasswords no
    AllowUsers drover-tunnel drover-jump
    AllowAgentForwarding no
    AllowStreamLocalForwarding no
    X11Forwarding no
    PermitTTY no
    GatewayPorts no
    UseDNS no
    LogLevel VERBOSE
    MaxSessions 0
    Match User drover-tunnel
      AuthorizedKeysFile ${tunnelKeys}
      AllowTcpForwarding remote
    Match User drover-jump
      AuthorizedKeysFile ${jumpKeys}
      AllowTcpForwarding local
  '';

  secretFor = name: ./secrets + "/${name}.sops";
  linuxNode = {
    users.groups.${nodeGroup} = { };
    users.users.${nodeUser} = {
      isSystemUser = true;
      group = nodeGroup;
      home = nodeHome;
      createHome = true;
      shell = pkgs.bashInteractive;
      hashedPassword = "";
    };

    systemd.tmpfiles.rules = [
      "d ${nodeHome} 0700 ${nodeUser} ${nodeGroup} -"
      "d ${nodeState} 0700 ${nodeUser} ${nodeGroup} -"
      "d ${nodeHome}/.ssh 0700 ${nodeUser} ${nodeGroup} -"
      "d ${piProfile} 0700 ${nodeUser} ${nodeGroup} -"
      "L+ ${piProfile}/settings.json - - - - ${piSettings}"
      "L+ ${nodeHome}/.ssh/coordinator.conf - - - - ${tunnelConfig}"
      "L+ ${nodeHome}/.ssh/coordinator_known_hosts - - - - ${coordinatorKnownHosts}"
    ];

    systemd.services.drover-node-sshd = {
      description = "Drover ${host} loopback SSH endpoint";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStartPre = "${pkgs.openssh}/bin/sshd -t -f ${nodeSshdConfig}";
        ExecStart = "${pkgs.openssh}/bin/sshd -D -e -f ${nodeSshdConfig}";
        Restart = "on-failure";
        RestartSec = "5s";
        TimeoutStopSec = "15s";
      };
    };

    systemd.services.drover-node = {
      description = "Drover ${host} node and private Herdr 0.9 namespace";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "drover-node-sshd.service"
      ]
      ++ lib.optionals coordinator [
        "drover-coordinator-health.service"
        "drover-coordinator-sshd.service"
      ];
      wants = [ "network-online.target" ];
      requires = [
        "drover-node-sshd.service"
      ]
      ++ lib.optionals coordinator [
        "drover-coordinator-health.service"
        "drover-coordinator-sshd.service"
      ];
      path = runtimePackages;
      environment = {
        HOME = nodeHome;
        PI_CODING_AGENT_DIR = piProfile;
        FAMILIAR_TIAMAT_URL = "https://router.${domain}";
        FAMILIAR_TIAMAT_TOKEN_FILE = config.sops.secrets.drover-tiamat-router-token.path;
      };
      serviceConfig = {
        Type = "simple";
        User = nodeUser;
        Group = nodeGroup;
        WorkingDirectory = nodeHome;
        ExecStart = nodeWrapper;
        Restart = "on-failure";
        RestartSec = "5s";
        TimeoutStopSec = "25s";
        KillMode = "control-group";
        UMask = "0077";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ nodeHome ];
      };
    };
  };

  darwinNode = {
    users.knownGroups = [ nodeGroup ];
    users.knownUsers = [ nodeUser ];
    users.groups.${nodeGroup} = {
      gid = 534;
    };
    users.users.${nodeUser} = {
      uid = 534;
      gid = 534;
      home = nodeHome;
      createHome = true;
      shell = "/bin/bash";
      description = "Drover isolated workbox";
      isHidden = true;
    };

    system.activationScripts.preActivation.text = lib.mkAfter ''
      install -d -o ${nodeUser} -g ${nodeGroup} -m 0700 ${nodeHome} ${nodeState} ${nodeHome}/.ssh ${piProfile}
      ln -sfn ${piSettings} ${piProfile}/settings.json
      ln -sfn ${tunnelConfig} ${nodeHome}/.ssh/coordinator.conf
      ln -sfn ${coordinatorKnownHosts} ${nodeHome}/.ssh/coordinator_known_hosts
      chown -h ${nodeUser}:${nodeGroup} ${piProfile}/settings.json ${nodeHome}/.ssh/coordinator.conf ${nodeHome}/.ssh/coordinator_known_hosts
      touch /var/log/drover-node.log /var/log/drover-node-sshd.log
      chown ${nodeUser}:${nodeGroup} /var/log/drover-node.log /var/log/drover-node-sshd.log
      chmod 0640 /var/log/drover-node.log /var/log/drover-node-sshd.log
    '';

    launchd.daemons.drover-node-sshd.serviceConfig = {
      Label = "network.gisi.drover.node-sshd";
      ProgramArguments = [
        "/usr/sbin/sshd"
        "-D"
        "-e"
        "-f"
        "${nodeSshdConfig}"
      ];
      RunAtLoad = true;
      KeepAlive = true;
      ThrottleInterval = 5;
      ExitTimeOut = 15;
      StandardOutPath = "/var/log/drover-node-sshd.log";
      StandardErrorPath = "/var/log/drover-node-sshd.log";
    };

    launchd.daemons.drover-node.serviceConfig = {
      Label = "network.gisi.drover.node";
      ProgramArguments = [ "${nodeWrapper}" ];
      UserName = nodeUser;
      GroupName = nodeGroup;
      WorkingDirectory = nodeHome;
      RunAtLoad = true;
      KeepAlive = true;
      ThrottleInterval = 5;
      ExitTimeOut = 25;
      ProcessType = "Background";
      StandardOutPath = "/var/log/drover-node.log";
      StandardErrorPath = "/var/log/drover-node.log";
      EnvironmentVariables = {
        HOME = nodeHome;
        PI_CODING_AGENT_DIR = piProfile;
        FAMILIAR_TIAMAT_URL = "https://router.${domain}";
        FAMILIAR_TIAMAT_TOKEN_FILE = config.sops.secrets.drover-tiamat-router-token.path;
        PATH = "${runtimePath}:/usr/bin:/bin:/usr/sbin:/sbin";
      };
    };
  };

  coordinatorConfigModule =
    if coordinator then
      {
        users.groups.drover-coordinator = { };
        users.groups.drover-credentials = { };
        users.groups.drover-control = { };
        users.users.drover-coordinator = {
          isSystemUser = true;
          group = "drover-coordinator";
          extraGroups = [
            "drover-credentials"
            "drover-control"
          ];
          home = "/var/lib/drover-coordinator";
          createHome = true;
        };
        users.users.${nodeUser}.extraGroups = [ "drover-credentials" ];
        users.users.drover-tunnel = {
          isSystemUser = true;
          group = "drover-coordinator";
          home = "/var/empty";
          hashedPassword = "";
          shell = pkgs.bashInteractive;
        };
        users.users.drover-jump = {
          isSystemUser = true;
          group = "drover-coordinator";
          home = "/var/empty";
          hashedPassword = "";
          shell = pkgs.bashInteractive;
        };

        sops.secrets.drover-client-token = {
          sopsFile = secretFor "client-token";
          format = "binary";
          owner = "familiar";
          group = "drover-control";
          mode = "0440";
        };
        sops.secrets.drover-coordinator-host-key = {
          sopsFile = secretFor "coordinator-host";
          format = "binary";
          owner = "root";
          group = "root";
          mode = "0400";
        };
        sops.secrets.drover-agents-client-key = {
          sopsFile = secretFor "agents-client";
          format = "binary";
          path = "/run/secrets/drover-agents-client-key";
          owner = "familiar";
          group = "users";
          mode = "0400";
        };

        systemd.tmpfiles.rules = [
          "d /var/lib/drover-coordinator 0700 drover-coordinator drover-coordinator -"
          "d /var/lib/drover-coordinator/registry 0700 drover-coordinator drover-coordinator -"
        ];

        systemd.services.drover-coordinator = {
          description = "Drover fleet coordinator";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ];
          path = [
            drover
            python
            pkgs.coreutils
          ];
          serviceConfig = {
            Type = "simple";
            User = "drover-coordinator";
            Group = "drover-coordinator";
            WorkingDirectory = "/var/lib/drover-coordinator";
            ExecStart = coordinatorWrapper;
            Restart = "on-failure";
            RestartSec = "5s";
            TimeoutStopSec = "20s";
            KillMode = "mixed";
            UMask = "0077";
            NoNewPrivileges = true;
            PrivateTmp = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            ReadWritePaths = [ "/var/lib/drover-coordinator" ];
          };
        };

        systemd.services.drover-coordinator-health = {
          description = "Authenticate and verify the Drover coordinator control plane";
          wantedBy = [ "multi-user.target" ];
          after = [ "drover-coordinator.service" ];
          requires = [ "drover-coordinator.service" ];
          before = [ "drover-node.service" ];
          serviceConfig = {
            Type = "oneshot";
            User = "drover-coordinator";
            Group = "drover-coordinator";
            ExecStart = healthScript;
            RemainAfterExit = true;
            TimeoutStartSec = "35s";
          };
        };

        systemd.services.drover-coordinator-sshd = {
          description = "Drover constrained reverse-tunnel and jump SSH endpoint";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ];
          serviceConfig = {
            Type = "simple";
            ExecStartPre = "${pkgs.openssh}/bin/sshd -t -f ${coordinatorSshdConfig}";
            ExecStart = "${pkgs.openssh}/bin/sshd -D -e -f ${coordinatorSshdConfig}";
            Restart = "on-failure";
            RestartSec = "5s";
            TimeoutStopSec = "15s";
          };
        };

        networking.firewall.extraCommands = ''
          iptables -w -A nixos-fw -p tcp -s ${rootManifest.fortConfig.settings.vpn.ipv4Prefix} --dport ${toString sshPort} -m comment --comment "drover-rendezvous" -j nixos-fw-accept
        '';

        # VPN is the least-public Fort visibility: every enrolled Fort node can
        # reach it, while Drover's own bearer authentication remains mandatory.
        fort.cluster.services = [
          {
            name = "drover";
            port = controlPort;
            visibility = "vpn";
            sso.mode = "none";
            health.enabled = false;
          }
        ];
      }
    else
      { };
in
lib.mkMerge [
  {
    assertions = [
      {
        assertion = builtins.elem host [
          "azula"
          "ratched"
          "obrien"
        ];
        message = "drover: only the three explicitly keyed fleet hosts may enable this aspect";
      }
      {
        assertion =
          expectedPort == {
            azula = 24000;
            ratched = 24001;
            obrien = 24002;
          }
          .${host};
        message = "drover: expected port must preserve immutable enrollment-generation ordering";
      }
      {
        assertion =
          lib.hasPrefix "/nix/store/" (toString piSettings)
          && familiarFlake.sourceInfo.rev == familiarRevision
          && droverFlake.sourceInfo.rev == droverRevision;
        message = "drover: Pi settings and Familiar/Drover assets must remain immutable and pinned";
      }
    ];

    sops.secrets.drover-enrollment-token = {
      sopsFile = secretFor "enrollment-token";
      format = "binary";
      owner = if coordinator then "drover-coordinator" else nodeUser;
      group = if coordinator then "drover-credentials" else nodeGroup;
      mode = if coordinator then "0440" else "0400";
    };
    sops.secrets.drover-node-host-key = {
      sopsFile = secretFor "${host}-host";
      format = "binary";
      owner = "root";
      group = "root";
      mode = "0400";
    };
    sops.secrets.drover-node-tunnel-key = {
      sopsFile = secretFor "${host}-tunnel";
      format = "binary";
      owner = nodeUser;
      group = nodeGroup;
      mode = "0400";
    };
    sops.secrets.drover-tiamat-router-token = {
      sopsFile = tiamatTokenFile;
      format = "binary";
      owner = nodeUser;
      group = nodeGroup;
      mode = "0400";
    };
  }
  (if isDarwin then darwinNode else linuxNode)
  coordinatorConfigModule
]
