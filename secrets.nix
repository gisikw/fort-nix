let
  rootManifest = import ./manifest.nix;
  cluster = rootManifest.fort.cluster;
  settings = rootManifest.fortConfig.settings;

  sshKeyPub = if settings ? sshKey then settings.sshKey.publicKey else settings.pubkey;
  deployKeys =
    if settings ? authorizedDeployKeys then settings.authorizedDeployKeys else [ settings.deployPubkey ];
  primaryKeys = [ sshKeyPub ] ++ deployKeys;

  deviceDir = cluster.devicesDir;
  deviceEntries =
    if builtins.pathExists deviceDir then builtins.readDir deviceDir else { };
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
}
