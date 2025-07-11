let
  configFile = ./config.toml;
  configDefs = builtins.fromTOML (builtins.readFile configFile);
  devicePubkeys = builtins.catAttrs "pubkey" (builtins.attrValues configDefs.devices);
in
{
  "./secrets/wifi.env.age".publicKeys = [ configDefs.fort.pubkey ] ++ devicePubkeys;
}
