{ rootManifest, ... }:
{ config, lib, pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  strings = lib.strings;
in
{
  users.groups.lldap = {};
  users.users.lldap = {
    isSystemUser = true;
    group = "lldap";
  };

  age.secrets.ldap-admin-pass = {
    file = ./ldap-admin-pass.age;
    owner = "lldap";
    group = "lldap";
    mode = "0400";
  };

  age.secrets.ldap-users.file = ./ldap-users.age;
  age.secrets.ldap-groups.file = ./ldap-groups.age;

  services.lldap = {
    enable = true;
    settings = {
      ldap_base_dn = strings.concatMapStringsSep "," (s: "dc=${s}") (strings.splitString "." domain);
      ldap_user_pass_file = config.age.secrets.ldap-admin-pass.path;
      force_ldap_user_pass_reset = "always";
    };
  };

  systemd.services.lldap-bootstrap = {
    after = [ "lldap.service" ];
    wants = [ "lldap.service" ];
    wantedBy = [ "multi-user.target" ];
    path = with pkgs; [ bash curl jq jo lldap coreutils ];

    serviceConfig = {
      Type = "oneshot";
      LoadCredential = [ 
        "admin-pass:${config.age.secrets.ldap-admin-pass.path}" 
        "users:${config.age.secrets.ldap-users.path}" 
        "groups:${config.age.secrets.ldap-groups.path}" 
      ];
      Environment = [
        "LLDAP_URL=http://localhost:17170"
        "LLDAP_ADMIN_USERNAME=admin"
        "LLDAP_ADMIN_PASSWORD_FILE=/run/credentials/lldap-bootstrap.service/admin-pass"
        "USER_CONFIGS_DIR=/run/lldap-bootstrap/users"
        "GROUP_CONFIGS_DIR=/run/lldap-bootstrap/groups"
        "DO_CLEANUP=true"
      ];

      RuntimeDirectory = "lldap-bootstrap";
      RuntimeDirectoryMode = "0700";

      ExecStartPre = pkgs.writeShellScript "prep-managed-records" ''
        set -euo pipefail
        mkdir -p /run/lldap-bootstrap/{users,groups}
        cp /run/credentials/lldap-bootstrap.service/users /run/lldap-bootstrap/users/users.json
        cp /run/credentials/lldap-bootstrap.service/groups /run/lldap-bootstrap/groups/groups.json
      '';

      ExecStart = pkgs.writeShellScript "lldap-bootstrap" ''
        exec ${pkgs.bash}/bin/bash ${pkgs.fetchurl {
          url = "https://raw.githubusercontent.com/lldap/lldap/refs/tags/v0.6.2/scripts/bootstrap.sh";
          sha256 = "sha256-Z5mQ7PwjYr3pgg+CCemTbYGbrY8CvXK3m7dpqDqSlBg=";
        }} "$@"
      '';
    };
  };
}
