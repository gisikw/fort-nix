{ subdomain ? "temporal", ... }:
{ config, lib, pkgs, ... }:

let
  temporal = pkgs.temporal;
  temporalSqlTool = "${temporal}/bin/temporal-sql-tool";
  schemaDir = "${temporal}/share/schema/postgresql/v12";

  uiPort = 8233;
  grpcPort = 7233;
  pgPort = 5432;
  dbUser = "temporal";
  bootstrapDir = "/var/lib/temporal/bootstrap";

  sqlToolFlags = "--plugin postgres12 --ep 127.0.0.1 -p ${toString pgPort} -u ${dbUser}";

  uiConfig = pkgs.writeText "temporal-ui.yaml" (builtins.toJSON {
    temporalGrpcAddress = "127.0.0.1:${toString grpcPort}";
    port = uiPort;
  });
in
{
  # --- PostgreSQL ---
  services.postgresql = {
    enable = true;
    # Trust auth on localhost — dev sandbox, no password complexity needed
    authentication = lib.mkForce ''
      # TYPE  DATABASE        USER            ADDRESS                 METHOD
      local   all             all                                     trust
      host    all             all             127.0.0.1/32            trust
      host    all             all             ::1/128                 trust
    '';
  };

  # --- Schema Bootstrap ---
  systemd.services.temporal-schema-bootstrap = {
    description = "Temporal database schema setup and migration";
    after = [ "postgresql.service" ];
    requires = [ "postgresql.service" ];
    wantedBy = [ "multi-user.target" ];

    path = [ temporal pkgs.postgresql ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      set -euo pipefail

      mkdir -p ${bootstrapDir}

      # Wait for PostgreSQL to accept connections
      for i in $(seq 1 30); do
        if psql -h 127.0.0.1 -U postgres -d postgres -c "SELECT 1" > /dev/null 2>&1; then
          break
        fi
        echo "Waiting for PostgreSQL..."
        sleep 2
      done

      # Ensure temporal role exists
      psql -h 127.0.0.1 -U postgres -d postgres -tc \
        "SELECT 1 FROM pg_roles WHERE rolname='${dbUser}'" | grep -q 1 || \
        psql -h 127.0.0.1 -U postgres -d postgres -c \
          "CREATE ROLE ${dbUser} LOGIN;"

      MARKER="${bootstrapDir}/schema-v2"
      if [ ! -f "$MARKER" ]; then
        echo "=== Initial schema setup ==="

        # Drop databases if they exist (clean slate when marker is absent)
        psql -h 127.0.0.1 -U postgres -d postgres -c \
          "DROP DATABASE IF EXISTS temporal;"
        psql -h 127.0.0.1 -U postgres -d postgres -c \
          "DROP DATABASE IF EXISTS temporal_visibility;"

        # Create fresh databases
        psql -h 127.0.0.1 -U postgres -d postgres -c \
          "CREATE DATABASE temporal OWNER ${dbUser};"
        psql -h 127.0.0.1 -U postgres -d postgres -c \
          "CREATE DATABASE temporal_visibility OWNER ${dbUser};"

        # Create version tracking tables (no --schema-name; let update-schema
        # apply the actual schema from v1.0 onward)
        ${temporalSqlTool} ${sqlToolFlags} \
          --db temporal setup-schema -v 0.0

        ${temporalSqlTool} ${sqlToolFlags} \
          --db temporal_visibility setup-schema -v 0.0

        # Apply all versioned migrations (v1.0 through current)
        ${temporalSqlTool} ${sqlToolFlags} \
          --db temporal update-schema \
          -d ${schemaDir}/temporal/versioned

        ${temporalSqlTool} ${sqlToolFlags} \
          --db temporal_visibility update-schema \
          -d ${schemaDir}/visibility/versioned

        touch "$MARKER"
        echo "Initial schema setup complete"
      fi

      # On subsequent runs, apply any new migrations (idempotent)
      echo "=== Running schema migrations ==="
      ${temporalSqlTool} ${sqlToolFlags} \
        --db temporal update-schema \
        -d ${schemaDir}/temporal/versioned

      ${temporalSqlTool} ${sqlToolFlags} \
        --db temporal_visibility update-schema \
        -d ${schemaDir}/visibility/versioned

      echo "Schema migrations complete"
    '';
  };

  # --- Temporal Server (NixOS module) ---
  services.temporal = {
    enable = true;
    settings = {
      log = {
        stdout = true;
        level = "info";
      };
      persistence = {
        numHistoryShards = 4;
        defaultStore = "default";
        visibilityStore = "visibility";
        datastores = {
          default.sql = {
            pluginName = "postgres12";
            databaseName = "temporal";
            connectAddr = "127.0.0.1:${toString pgPort}";
            connectProtocol = "tcp";
            user = dbUser;
            password = "";
            maxConns = 20;
            maxIdleConns = 20;
          };
          visibility.sql = {
            pluginName = "postgres12";
            databaseName = "temporal_visibility";
            connectAddr = "127.0.0.1:${toString pgPort}";
            connectProtocol = "tcp";
            user = dbUser;
            password = "";
            maxConns = 10;
            maxIdleConns = 10;
          };
        };
      };
      global = {
        membership.broadcastAddress = "127.0.0.1";
      };
      services = {
        frontend.rpc = {
          grpcPort = grpcPort;
          membershipPort = 6933;
          bindOnLocalHost = true;
        };
        history.rpc = {
          grpcPort = 7234;
          membershipPort = 6934;
          bindOnLocalHost = true;
        };
        matching.rpc = {
          grpcPort = 7235;
          membershipPort = 6935;
          bindOnLocalHost = true;
        };
        worker.rpc = {
          grpcPort = 7239;
          membershipPort = 6939;
          bindOnLocalHost = true;
        };
      };
      clusterMetadata = {
        enableGlobalNamespace = false;
        failoverVersionIncrement = 10;
        masterClusterName = "active";
        currentClusterName = "active";
        clusterInformation.active = {
          enabled = true;
          initialFailoverVersion = 1;
          rpcName = "frontend";
          rpcAddress = "127.0.0.1:${toString grpcPort}";
        };
      };
      dcRedirectionPolicy.policy = "noop";
      archival = {
        history.state = "disabled";
        visibility.state = "disabled";
      };
      namespaceDefaults.archival = {
        history.state = "disabled";
        visibility.state = "disabled";
      };
      publicClient.hostPort = "127.0.0.1:${toString grpcPort}";
    };
  };

  # Depend on schema bootstrap
  systemd.services.temporal = {
    after = [ "temporal-schema-bootstrap.service" ];
    requires = [ "temporal-schema-bootstrap.service" ];
  };

  # --- Temporal UI ---
  systemd.services.temporal-ui = {
    description = "Temporal Web UI";
    after = [ "temporal.service" ];
    wants = [ "temporal.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      ExecStartPre = "+" + pkgs.writeShellScript "temporal-ui-setup" ''
        mkdir -p /run/temporal-ui/config
        cp ${uiConfig} /run/temporal-ui/config/temporal-ui.yaml
      '';
      ExecStart = "${pkgs.temporal-ui-server}/bin/temporal-ui-server --env temporal-ui start";
      Restart = "on-failure";
      RestartSec = "5s";
      DynamicUser = true;
      RuntimeDirectory = "temporal-ui";
      WorkingDirectory = "/run/temporal-ui";
      CapabilityBoundingSet = [ "" ];
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
    };
  };

  # Persistent bootstrap state
  systemd.tmpfiles.rules = [
    "d ${bootstrapDir} 0700 root root -"
  ];

  # --- Service Exposure ---
  fort.cluster.services = [{
    name = "temporal";
    inherit subdomain;
    port = uiPort;
    visibility = "local";
    sso.mode = "none";
  }];
}
