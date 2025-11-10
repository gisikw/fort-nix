{ rootManifest, ... }:
{ config, lib, pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  strings = lib.strings;
  ldap_base_dn = strings.concatMapStringsSep "," (s: "dc=${s}") (strings.splitString "." domain);
in
{
  environment.systemPackages = [ pkgs.pocket-id ];

  systemd.services.pocket-id.serviceConfig = {
    LoadCredential = [ "ldap-admin-pass:${config.age.secrets.ldap-admin-pass.path}" ];

    RuntimeDirectory = "pocket-id";
    RuntimeDirectoryMode = "0700";

    ExecStartPre = pkgs.writeShellScript "strip-newline" ''
      tr -d '\n' < /run/credentials/pocket-id.service/ldap-admin-pass \
        > /run/pocket-id/ldap-admin-pass
      chmod 0400 /run/pocket-id/ldap-admin-pass
    '';
  };

  services.pocket-id = {
    enable = true;
    settings = {
      TRUST_PROXY = true;
      APP_URL = "https://id.${domain}";

      LDAP_ENABLED = true;
      UI_CONFIG_DISABLED = true;

      LDAP_URL = "ldap://localhost:3890";
      LDAP_BIND_DN = "cn=admin,ou=people,${ldap_base_dn}";
      LDAP_BIND_PASSWORD_FILE = "/run/pocket-id/ldap-admin-pass";
      LDAP_BASE = ldap_base_dn;
      LDAP_SKIP_CERT_VERIFY = true;

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
  };


  fortCluster.exposedServices = [
    {
      name = "pocket-id";
      subdomain = "id";
      port = 1411;
      visibility = "public";
    }
  ];
}
