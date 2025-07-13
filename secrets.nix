let
  configFile = ./config.toml;
  fortConfig = builtins.fromTOML (builtins.readFile configFile);
  devicePubkeys = builtins.catAttrs "pubkey" (builtins.attrValues fortConfig.devices);
in
{
  "./secrets/wifi.env.age".publicKeys = [ fortConfig.fort.pubkey ] ++ devicePubkeys;
  "./secrets/hmac_key.age".publicKeys = [ fortConfig.fort.pubkey ] ++ devicePubkeys;
}
