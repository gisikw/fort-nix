let
  configFile = ./config.toml;
  fortConfig = builtins.fromTOML (builtins.readFile configFile);

  devicePubkeys = builtins.catAttrs "pubkey" (builtins.attrValues fortConfig.devices);

  gatehouseHosts =
    builtins.filter (host: builtins.elem "fort-gatehouse" (host.roles or []))
                    (builtins.attrValues fortConfig.hosts);

  gatehouseDevicePubkeys =
    builtins.map (host: fortConfig.devices.${host.device}.pubkey)
                 gatehouseHosts;

  barbicanHosts =
    builtins.filter (host: builtins.elem "fort-barbican" (host.roles or []))
                    (builtins.attrValues fortConfig.hosts);

  barbicanDevicePubkeys =
    builtins.map (host: fortConfig.devices.${host.device}.pubkey)
                 barbicanHosts;

  citadelHosts =
    builtins.filter (host: builtins.elem "fort-citadel" (host.roles or []))
                    (builtins.attrValues fortConfig.hosts);

  citadelDevicePubkeys =
    builtins.map (host: fortConfig.devices.${host.device}.pubkey)
                 citadelHosts;
in
{
  "./secrets/wifi.env.age".publicKeys = [ fortConfig.settings.pubkey ] ++ devicePubkeys;
  "./secrets/hmac_key.age".publicKeys = [ fortConfig.settings.pubkey ] ++ devicePubkeys;
  "./secrets/registry_key.age".publicKeys = [ fortConfig.settings.pubkey ] ++ gatehouseDevicePubkeys;
  "./secrets/fort_gatehouse_wg.age".publicKeys = [ fortConfig.settings.pubkey ] ++ gatehouseDevicePubkeys;
  "./secrets/fort_barbican_wg.age".publicKeys = [ fortConfig.settings.pubkey ] ++ barbicanDevicePubkeys;
  "./secrets/dns_provider.env.age".publicKeys = [ fortConfig.settings.pubkey ] ++ citadelDevicePubkeys;
  "./secrets/fort.key.age".publicKeys = [ fortConfig.settings.pubkey ] ++ citadelDevicePubkeys;
  "./secrets/egress-vpn-conf.age".publicKeys = [ fortConfig.settings.pubkey ] ++ devicePubkeys;
  "./secrets/zitadel-master-key.age".publicKeys = [ fortConfig.settings.pubkey ] ++ barbicanDevicePubkeys;
  "./secrets/tailscale-default.age".publicKeys = [ fortConfig.settings.pubkey ] ++ devicePubkeys;
}
