let
  hostManifest = import ./manifest.nix;
  primaryKeys = [
    hostManifest.fortConfig.settings.pubkey
    hostManifest.fortConfig.settings.deployPubkey
  ];
  deviceKeys = builtins.map (uuid: (import ./devices/${uuid}/manifest.nix).pubkey) (
    builtins.attrNames (builtins.readDir ./devices)
  );

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
