let
  configFile = ./config.toml;
  fortConfig = builtins.fromTOML (builtins.readFile configFile);

  devicePubkeys = builtins.catAttrs "pubkey" (builtins.attrValues fortConfig.devices);

  registryHosts = 
    builtins.filter (host: builtins.elem "fort-registry" host.services) 
                    (builtins.attrValues fortConfig.hosts);

  registryDevicePubkeys = 
    builtins.map (host: fortConfig.devices.${host.device}.pubkey)
                 registryHosts;
in
{
  "./secrets/wifi.env.age".publicKeys = [ fortConfig.fort.pubkey ] ++ devicePubkeys;
  "./secrets/hmac_key.age".publicKeys = [ fortConfig.fort.pubkey ] ++ devicePubkeys;
  "./secrets/registry_key.age".publicKeys = [ fortConfig.fort.pubkey ] ++ registryDevicePubkeys;
}
