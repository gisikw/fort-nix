let
  cluster = import ./common/cluster-context.nix { };
  settings = cluster.manifest.fortConfig.settings;

  sshKeyPub = settings.sshKey.publicKey;
  deployKeys = settings.authorizedDeployKeys;
  primaryKeys = [ sshKeyPub ] ++ deployKeys;

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
  # "./aspects/mosquitto/mosquitto-homeassistant-password.age".publicKeys = activeKeys;
}
