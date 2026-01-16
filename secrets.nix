let
  cluster = import ./common/cluster-context.nix { };
  settings = cluster.manifest.fortConfig.settings;

  # Derive editor keys from principals with "secrets" role
  principalsWithSecrets = builtins.filter
    (p: builtins.elem "secrets" (p.roles or [ ]))
    (builtins.attrValues settings.principals);
  primaryKeys = map (p: p.publicKey) principalsWithSecrets;

  deviceDir = cluster.devicesDir;
  deviceEntries = builtins.readDir deviceDir;
  deviceUuids = builtins.filter (name: deviceEntries.${name} == "directory") (builtins.attrNames deviceEntries);
  deviceKeys = map (uuid: (import "${deviceDir}/${uuid}/manifest.nix").pubkey) deviceUuids;

  keyedForDevices = builtins.getEnv "KEYED_FOR_DEVICES" == "1";
  activeKeys = if keyedForDevices then primaryKeys ++ deviceKeys else primaryKeys;
in
{
  "./aspects/wifi-access/credentials.env.age".publicKeys = activeKeys;
  "./aspects/mesh/auth-key.age".publicKeys = activeKeys;
  "./aspects/certificate-broker/dns-provider.env.age".publicKeys = activeKeys;
  "./aspects/deployer/deployer-key.age".publicKeys = activeKeys;
  "./apps/fort-observability/grafana-admin-pass.age".publicKeys = activeKeys;
  "./aspects/egress-vpn/egress-vpn-conf.age".publicKeys = activeKeys;
  "./aspects/ldap/ldap-admin-pass.age".publicKeys = activeKeys;
  "./aspects/ldap/ldap-users.age".publicKeys = activeKeys;
  "./aspects/ldap/ldap-groups.age".publicKeys = activeKeys;
  "./clusters/bedlam/hosts/minos/mosquitto-zigbee2mqtt-password.age".publicKeys = activeKeys;
  "./clusters/bedlam/hosts/minos/mosquitto-zwave-js-ui-password.age".publicKeys = activeKeys;
  "./clusters/bedlam/hosts/minos/mosquitto-homeassistant-password.age".publicKeys = activeKeys;
  "./clusters/bedlam/hosts/minos/iot.manifest.age".publicKeys = activeKeys;
  "./clusters/bedlam/hosts/minos/zwave-security-keys.json.age".publicKeys = activeKeys;
  "./apps/homeassistant/secrets.yaml.age".publicKeys = activeKeys;
  "./apps/fort-mcp/secrets.env.age".publicKeys = activeKeys;
  "./clusters/bedlam/github-mirror-token.age".publicKeys = activeKeys;
  "./apps/forgejo/runner-secret.age".publicKeys = activeKeys;
  "./apps/attic/attic-server-token.age".publicKeys = activeKeys;
  "./aspects/dev-sandbox/agent-key.age".publicKeys = activeKeys;
  "./clusters/bedlam/hosts/ratched/ssh-key.age".publicKeys = activeKeys;
  "./aspects/dev-sandbox/oauth-client-id.age".publicKeys = activeKeys;
  "./aspects/dev-sandbox/oauth-client-secret.age".publicKeys = activeKeys;
  "./apps/radicale/htpasswd.age".publicKeys = activeKeys;
  "./apps/radicale/password.age".publicKeys = activeKeys;
  "./clusters/bedlam/pii-denylist.age".publicKeys = activeKeys;
}
