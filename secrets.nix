let
  configFile = ./config.toml;
  fortConfig = builtins.fromTOML (builtins.readFile configFile);

  devicePubkeys = builtins.catAttrs "pubkey" (builtins.attrValues fortConfig.devices);

  registryHosts = 
    builtins.filter (host: builtins.elem "fort-nameserver" (host.roles or []))
                    (builtins.attrValues fortConfig.hosts);

  registryDevicePubkeys = 
    builtins.map (host: fortConfig.devices.${host.device}.pubkey)
                 registryHosts;
in
{
  "./secrets/wifi.env.age".publicKeys = [ fortConfig.settings.pubkey ] ++ devicePubkeys;
  "./secrets/hmac_key.age".publicKeys = [ fortConfig.settings.pubkey ] ++ devicePubkeys;
  "./secrets/registry_key.age".publicKeys = [ fortConfig.settings.pubkey ] ++ registryDevicePubkeys;
}
