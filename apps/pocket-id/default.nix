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

  # Handler for oidc-register capability (async aggregate mode)
  # Input: {key -> {request: {client_name}, response?: {client_id, client_secret}}}
  # Output: {key -> {client_id, client_secret}}
  # Creates/manages pocket-id OIDC clients for SSO services
  oidcRegisterHandler = pkgs.writeShellScript "handler-oidc-register" ''
    set -euo pipefail

    SERVICE_KEY_FILE="${dataDir}/service-key"
    POCKETID_URL="https://id.${domain}"

    # Read aggregate input
    input=$(${pkgs.coreutils}/bin/cat)

    # Ensure we have the service key
    if [ ! -s "$SERVICE_KEY_FILE" ]; then
      echo "$input" | ${pkgs.jq}/bin/jq 'to_entries | map({key: .key, value: {error: "Service key not yet created"}}) | from_entries'
      exit 0
    fi
    SERVICE_KEY=$(${pkgs.coreutils}/bin/cat "$SERVICE_KEY_FILE")

    # Helper function to make authenticated API calls
    api_call() {
      local method="$1"
      local endpoint="$2"
      local data="''${3:-}"

      if [ -n "$data" ]; then
        ${pkgs.curl}/bin/curl -s -X "$method" \
          "$POCKETID_URL$endpoint" \
          -H "X-API-KEY: $SERVICE_KEY" \
          -H "Content-Type: application/json" \
          -d "$data"
      else
        ${pkgs.curl}/bin/curl -s -X "$method" \
          "$POCKETID_URL$endpoint" \
          -H "X-API-KEY: $SERVICE_KEY"
      fi
    }

    # Get all existing OIDC clients
    get_all_clients() {
      local page=1
      local all_clients="[]"
      while true; do
        local response=$(api_call GET "/api/oidc/clients?pagination%5Bpage%5D=$page")
        local data=$(echo "$response" | ${pkgs.jq}/bin/jq -c '.data // []')
        local total_pages=$(echo "$response" | ${pkgs.jq}/bin/jq -r '.pagination.totalPages // 1')
        local current_page=$(echo "$response" | ${pkgs.jq}/bin/jq -r '.pagination.currentPage // 1')

        all_clients=$(${pkgs.jq}/bin/jq -n --argjson a "$all_clients" --argjson b "$data" '$a + $b')

        if [ "$current_page" -ge "$total_pages" ]; then
          break
        fi
        page=$((page + 1))
      done
      echo "$all_clients"
    }

    # Look up group UUID from group name (returns empty if not found)
    get_group_id() {
      local group_name="$1"
      local response=$(api_call GET "/api/user-groups?search=$group_name")
      # Find exact match by name
      echo "$response" | ${pkgs.jq}/bin/jq -r --arg name "$group_name" \
        '.data[] | select(.name == $name) | .id // empty'
    }

    # Set allowed user groups on an OIDC client
    # Takes client_id and JSON array of group names
    set_allowed_groups() {
      local client_id="$1"
      local groups_json="$2"

      # If no groups specified (empty array), clear restrictions
      local group_count=$(echo "$groups_json" | ${pkgs.jq}/bin/jq 'length')
      if [ "$group_count" = "0" ]; then
        api_call PUT "/api/oidc/clients/$client_id/allowed-user-groups" '{"userGroupIds": []}' >/dev/null
        return 0
      fi

      # Look up group UUIDs from names
      local group_ids="[]"
      for group_name in $(echo "$groups_json" | ${pkgs.jq}/bin/jq -r '.[]'); do
        local group_id=$(get_group_id "$group_name")
        if [ -n "$group_id" ]; then
          group_ids=$(echo "$group_ids" | ${pkgs.jq}/bin/jq --arg id "$group_id" '. + [$id]')
        else
          echo "WARNING: Group '$group_name' not found in pocket-id" >&2
        fi
      done

      # Update allowed groups
      local payload=$(${pkgs.jq}/bin/jq -n --argjson ids "$group_ids" '{"userGroupIds": $ids}')
      api_call PUT "/api/oidc/clients/$client_id/allowed-user-groups" "$payload" >/dev/null
    }

    # Create a new OIDC client and return its secret
    create_client() {
      local client_name="$1"
      local groups_json="$2"

      # Create the client
      local create_response=$(api_call POST "/api/oidc/clients" "{
        \"name\": \"$client_name\",
        \"callbackURLs\": [],
        \"logoutCallbackURLs\": [],
        \"isPublic\": false,
        \"pkceEnabled\": false,
        \"requiresReauthentication\": false
      }")

      local client_id=$(echo "$create_response" | ${pkgs.jq}/bin/jq -r '.id // empty')
      if [ -z "$client_id" ]; then
        echo "ERROR: Failed to create client $client_name" >&2
        return 1
      fi

      # Set allowed groups if specified
      if [ -n "$groups_json" ]; then
        set_allowed_groups "$client_id" "$groups_json"
      fi

      # Generate client secret
      local secret_response=$(api_call POST "/api/oidc/clients/$client_id/secret" "{}")
      local client_secret=$(echo "$secret_response" | ${pkgs.jq}/bin/jq -r '.secret // empty')

      if [ -z "$client_secret" ]; then
        echo "ERROR: Failed to generate secret for client $client_name" >&2
        return 1
      fi

      ${pkgs.jq}/bin/jq -n --arg id "$client_id" --arg secret "$client_secret" \
        '{client_id: $id, client_secret: $secret}'
    }

    # Get existing clients for lookup
    existing_clients=$(get_all_clients)

    # Track which client names are needed (for GC)
    needed_names="[]"

    # Build output for all requesters
    output='{}'
    for key in $(echo "$input" | ${pkgs.jq}/bin/jq -r 'keys[]'); do
      request=$(echo "$input" | ${pkgs.jq}/bin/jq -c --arg k "$key" '.[$k].request // {}')
      cached_response=$(echo "$input" | ${pkgs.jq}/bin/jq -c --arg k "$key" '.[$k].response // null')

      # Client name is the FQDN (e.g., "outline.gisi.network")
      client_name=$(echo "$request" | ${pkgs.jq}/bin/jq -r '.client_name // empty')
      # Allowed groups (array of LDAP group names)
      groups_json=$(echo "$request" | ${pkgs.jq}/bin/jq -c '.groups // []')

      if [ -z "$client_name" ]; then
        output=$(echo "$output" | ${pkgs.jq}/bin/jq --arg k "$key" \
          '.[$k] = {error: "client_name required in request"}')
        continue
      fi

      # Track this name as needed
      needed_names=$(echo "$needed_names" | ${pkgs.jq}/bin/jq --arg n "$client_name" '. + [$n]')

      # Check if we have a cached response with valid credentials
      if [ "$cached_response" != "null" ]; then
        cached_id=$(echo "$cached_response" | ${pkgs.jq}/bin/jq -r '.client_id // empty')
        cached_secret=$(echo "$cached_response" | ${pkgs.jq}/bin/jq -r '.client_secret // empty')

        # Verify client still exists
        client_exists=$(echo "$existing_clients" | ${pkgs.jq}/bin/jq -r --arg id "$cached_id" \
          'any(.[]; .id == $id)')

        if [ "$client_exists" = "true" ] && [ -n "$cached_secret" ]; then
          # Reuse cached credentials, but sync groups (true-up)
          set_allowed_groups "$cached_id" "$groups_json"
          output=$(echo "$output" | ${pkgs.jq}/bin/jq --arg k "$key" --argjson resp "$cached_response" \
            '.[$k] = $resp')
          continue
        fi
      fi

      # Check if client already exists by name
      existing_client=$(echo "$existing_clients" | ${pkgs.jq}/bin/jq -c --arg name "$client_name" \
        '[.[] | select(.name == $name)] | if length > 0 then .[0] else null end')

      if [ "$existing_client" != "null" ] && [ -n "$existing_client" ]; then
        # Client exists but we don't have the secret cached - regenerate it
        existing_id=$(echo "$existing_client" | ${pkgs.jq}/bin/jq -r '.id')
        # Sync groups (true-up)
        set_allowed_groups "$existing_id" "$groups_json"
        secret_response=$(api_call POST "/api/oidc/clients/$existing_id/secret" "{}")
        client_secret=$(echo "$secret_response" | ${pkgs.jq}/bin/jq -r '.secret // empty')

        if [ -n "$client_secret" ]; then
          output=$(echo "$output" | ${pkgs.jq}/bin/jq --arg k "$key" --arg id "$existing_id" --arg secret "$client_secret" \
            '.[$k] = {client_id: $id, client_secret: $secret}')
        else
          output=$(echo "$output" | ${pkgs.jq}/bin/jq --arg k "$key" \
            '.[$k] = {error: "Failed to regenerate secret for existing client"}')
        fi
      else
        # Create new client
        if new_creds=$(create_client "$client_name" "$groups_json"); then
          output=$(echo "$output" | ${pkgs.jq}/bin/jq --arg k "$key" --argjson creds "$new_creds" \
            '.[$k] = $creds')
        else
          output=$(echo "$output" | ${pkgs.jq}/bin/jq --arg k "$key" \
            '.[$k] = {error: "Failed to create client"}')
        fi
      fi
    done

    # GC: Delete clients that are no longer needed
    for client_json in $(echo "$existing_clients" | ${pkgs.jq}/bin/jq -c '.[]'); do
      client_name=$(echo "$client_json" | ${pkgs.jq}/bin/jq -r '.name')
      client_id=$(echo "$client_json" | ${pkgs.jq}/bin/jq -r '.id')

      is_needed=$(echo "$needed_names" | ${pkgs.jq}/bin/jq -r --arg n "$client_name" 'any(. == $n)')
      if [ "$is_needed" = "false" ]; then
        echo "GC: Deleting orphaned client: $client_name" >&2
        api_call DELETE "/api/oidc/clients/$client_id" || true
      fi
    done

    echo "$output"
  '';

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

    # lldap uses groupOfUniqueNames with uniqueMember (not groupOfNames with member)
    LDAP_USER_GROUP_SEARCH_FILTER = "(objectClass=groupOfUniqueNames)";
    LDAP_ATTRIBUTE_GROUP_MEMBER = "uniqueMember";
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

  fort.cluster.services = [
    {
      name = "pocket-id";
      subdomain = subdomain;
      port = 1411;
      visibility = "public";
    }
  ];

  # Expose oidc-register capability for OIDC client management
  fort.host.capabilities.oidc-register = {
    handler = oidcRegisterHandler;
    mode = "async";  # Returns handles, needs GC
    cacheResponse = true;  # Preserve client secrets across restarts
    description = "Register and manage OIDC clients for SSO services";
  };
}
