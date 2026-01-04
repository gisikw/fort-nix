{ subdomain ? "id", rootManifest, ... }:
{ config, lib, pkgs, ... }:
let
  pocket-id = import ../../pkgs/pocket-id { inherit pkgs; };
  domain = rootManifest.fortConfig.settings.domain;
  strings = lib.strings;
  ldap_base_dn = strings.concatMapStringsSep "," (s: "dc=${s}") (strings.splitString "." domain);

  dataDir = "/var/lib/pocket-id";
  user = "pocket-id";
  group = "pocket-id";

  # Environment settings for pocket-id
  settings = {
    TRUST_PROXY = "true";
    APP_URL = "https://id.${domain}";
    EMAILS_VERIFIED = "true";
    ALLOW_DOWNGRADE = "true";

    LDAP_ENABLED = "true";
    UI_CONFIG_DISABLED = "true";

    LDAP_URL = "ldap://localhost:3890";
    LDAP_BIND_DN = "cn=admin,ou=people,${ldap_base_dn}";
    LDAP_BIND_PASSWORD_FILE = "/run/pocket-id/ldap-admin-pass";
    LDAP_BASE = ldap_base_dn;
    LDAP_SKIP_CERT_VERIFY = "true";

    LDAP_ATTRIBUTE_USER_UNIQUE_IDENTIFIER = "uid";
    LDAP_ATTRIBUTE_USER_USERNAME = "uid";
    LDAP_ATTRIBUTE_USER_EMAIL = "mail";
    LDAP_ATTRIBUTE_USER_FIRST_NAME = "first_name";
    LDAP_ATTRIBUTE_USER_LAST_NAME = "last_name";
    LDAP_ATTRIBUTE_USER_PROFILE_PICTURE = "avatar";

    LDAP_ATTRIBUTE_GROUP_UNIQUE_IDENTIFIER = "cn";
    LDAP_ATTRIBUTE_GROUP_NAME = "cn";
    LDAP_ATTRIBUTE_ADMIN_GROUP = "admin";
  };

  settingsFile = pkgs.writeText "pocket-id-env" (
    lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: "${k}=${v}") settings)
  );
in
{
  environment.systemPackages = [ pocket-id ];

  users.users.${user} = {
    isSystemUser = true;
    group = group;
    description = "Pocket ID user";
    home = dataDir;
  };

  users.groups.${group} = { };

  systemd.tmpfiles.rules = [
    "d ${dataDir} 0755 ${user} ${group}"
  ];

  systemd.services.pocket-id = {
    description = "Pocket ID";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      User = user;
      Group = group;
      WorkingDirectory = dataDir;
      ExecStart = "${pocket-id}/bin/pocket-id";
      Restart = "always";
      EnvironmentFile = [ settingsFile ];

      LoadCredential = [ "ldap-admin-pass:${config.age.secrets.ldap-admin-pass.path}" ];
      RuntimeDirectory = "pocket-id";
      RuntimeDirectoryMode = "0700";

      ExecStartPre = pkgs.writeShellScript "pocket-id-prep" ''
        tr -d '\n' < /run/credentials/pocket-id.service/ldap-admin-pass \
          > /run/pocket-id/ldap-admin-pass
        chmod 0400 /run/pocket-id/ldap-admin-pass
      '';

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

  systemd.services.pocket-id-service-key = {
    after = [ "pocket-id.service" ];
    wants = [ "pocket-id.service" ];
    startAt = "*:0/30";

    serviceConfig = {
      Type = "oneshot";
      User = user;
      StateDirectory = "pocket-id";
      StateDirectoryMode = "0700";
    };

    path = with pkgs; [ curl jq pocket-id coreutils ];
    script = ''
      cd ${dataDir}
      otp=$(pocket-id one-time-access-token service-account 2>&1 | grep "http" | cut -d/ -f5)

      cookiejar=$(mktemp)
      curl -sX POST -c $cookiejar \
        "https://id.${domain}/api/one-time-access-token/$otp" \
        -H "Origin: https://id.${domain}" \
        -H "Referer: https://id.${domain}/lc/$otp" \
        -H "User-Agent: Mozilla/5.0"

      EXPIRES_AT=$(date -u -d "+1 day" +"%Y-%m-%dT%H:%M:%SZ")
      fresh_token=$(curl -sb $cookiejar \
        -XPOST https://id.${domain}/api/api-keys \
        -d '{"name":"registry-key","description":"service-account","expiresAt":"'$EXPIRES_AT'"}')
      fresh_token_id=$(echo $fresh_token | jq -r '.apiKey.id')

      curl -sb $cookiejar \
        https://id.${domain}/api/api-keys | \
        jq -r '.data[] | select((.description == "service-account") and .id != "'$fresh_token_id'") | .id' |\
        xargs -I{} -n1 curl -sb $cookiejar -XDELETE https://id.${domain}/api/api-keys/{}

      echo $fresh_token | jq -r '.token' > ${dataDir}/service-key
      rm -f $cookiejar
    '';
  };

  fortCluster.exposedServices = [
    {
      name = "pocket-id";
      subdomain = subdomain;
      port = 1411;
      visibility = "public";
    }
  ];
}
