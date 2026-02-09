{ subdomain ? "matrix", rootManifest, ... }:
{ config, lib, pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  serverName = "${subdomain}.${domain}";

  dataDir = "/var/lib/conduit";
  user = "conduit";
  group = "conduit";
  port = 6168;

  # Conduit configuration
  conduitConfig = pkgs.writeText "conduit.toml" ''
    [global]
    server_name = "${serverName}"
    database_path = "${dataDir}"
    database_backend = "rocksdb"

    port = ${toString port}
    address = "127.0.0.1"

    # No federation - this is a private instance
    allow_federation = false

    # Registration disabled - users created
    allow_registration = false

    # Allow encryption (required for most Matrix clients)
    allow_encryption = true

    # Trusted servers for key fetching (not used without federation, but required)
    trusted_servers = ["matrix.org"]

    # Performance tuning
    max_concurrent_requests = 100
    max_request_size = 20000000

    # Logging
    log = "warn,state_res=warn"
  '';
in
{
  users.users.${user} = {
    isSystemUser = true;
    group = group;
    description = "Matrix Conduit user";
    home = dataDir;
  };

  users.groups.${group} = { };

  systemd.tmpfiles.rules = [
    "d ${dataDir} 0700 ${user} ${group} -"
  ];

  systemd.services.conduit = {
    description = "Matrix Conduit Homeserver";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    environment = {
      CONDUIT_CONFIG = conduitConfig;
    };

    serviceConfig = {
      Type = "simple";
      User = user;
      Group = group;
      WorkingDirectory = dataDir;
      ExecStart = "${pkgs.matrix-conduit}/bin/conduit";
      Restart = "always";
      RestartSec = "10s";

      # Hardening
      AmbientCapabilities = "";
      CapabilityBoundingSet = "";
      DeviceAllow = "";
      DevicePolicy = "closed";
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateNetwork = false;
      PrivateTmp = true;
      PrivateUsers = true;
      ProcSubset = "pid";
      ProtectClock = true;
      ProtectControlGroups = true;
      ProtectHome = true;
      ProtectHostname = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectProc = "invisible";
      ProtectSystem = "strict";
      ReadWritePaths = [ dataDir ];
      RemoveIPC = true;
      RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      SystemCallArchitectures = "native";
      UMask = "0077";
    };
  };

  fort.cluster.services = [
    {
      name = "conduit";
      subdomain = subdomain;
      port = port;
      visibility = "public";  # No federation; auth handled by Matrix
      sso = {
        mode = "none";  # Matrix has its own auth
      };
    }
  ];
}
