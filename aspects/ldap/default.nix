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

  # Expected format
  # uid email group1 group2
  # uid2 email2 group1 group3
  age.secrets.ldap-users = {
    file = ./ldap-users.age;
    owner = "lldap";
    group = "lldap";
    mode = "0400";
  };

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
    serviceConfig = {
      Type = "oneshot";
      User = "lldap";
      Restart = "on-failure";
      RestartSec = "5s";
    };
    path = with pkgs; [ lldap-cli netcat ];
    script = ''
      set -euo pipefail
      IFS=$'\n\t'

      for i in {1..10}; do
        nc -z localhost 17170 && break
        echo "Waiting for LLDAP to be ready..."
        sleep 1
      done

      users="${config.age.secrets.ldap-users.path}"

      password=$(< /run/agenix/ldap-admin-pass)
      eval "$(lldap-cli -D admin -w "$password" login)"

      target_users=$(cut -d, -f1 "$users" | sort)
      existing_users=$(lldap-cli user list | sort)

      # Deletions
      comm -23 <(echo "$existing_users") <(echo "$target_users") |
      while read -r uid; do
        lldap-cli user del "$uid"
      done

      # Additions
      comm -13 <(echo "$existing_users") <(echo "$target_users") |
      while read -r uid; do
        IFS=, read -r _ email groupstr <<< "$(grep "^$uid," "$users")"
        lldap-cli user add "$uid" "$email"
        if [[ -n "$groupstr" ]]; then
          IFS=, read -ra groups <<< "$groupstr"
          for group in "''${groups[@]}"; do
            echo "Adding group $group"
            if ! output=$(lldap-cli group add "$group" 2>&1); then
              if ! grep -qi "UNIQUE constraint" <<< "$output"; then
                echo "Error creating group '$group': $output" >&2
                exit 1
              fi
            fi
            lldap-cli user group add "$uid" "$group"
          done
        fi
      done

      # Updates
      comm -12 <(echo "$existing_users") <(echo "$target_users") |
      while read -r uid; do
        IFS=, read -r _ email groupstr <<< "$(grep "^$uid," "$users")"
        lldap-cli user update set "$uid" mail "$email"

        target_groups=$(echo "$groupstr" | tr ',' '\n' | sort)
        existing_groups=$(lldap-cli user group list "$uid" | sort)

        comm -13 <(echo "$existing_groups") <(echo "$target_groups") |
        while read -r group; do
          if ! output=$(lldap-cli group add "$group" 2>&1); then
            if ! grep -qi "UNIQUE constraint" <<< "$output"; then
              echo "Error creating group '$group': $output" >&2
              exit 1
            fi
          fi
          lldap-cli user group add "$uid" "$group"
        done

        comm -23 <(echo "$existing_groups") <(echo "$target_groups") |
        while read -r group; do
          lldap-cli user group del "$uid" "$group"
        done
      done
    '';
  };
}
