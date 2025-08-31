{ config, fort, ... }:

{
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  imports = [
    ../modules/fort/registry-coredns-subscriber
    ../modules/fort/coredns.nix
    ../modules/fort/registry
    ../modules/fort/announce.nix
    ../modules/fort/webstatus.nix
    ../modules/fort/reverse-proxy.nix
  ];

  networking.firewall.interfaces.wg0.allowedTCPPorts = [ 6379 ];
  services.redis.servers."fort-registry" = {
    enable = true;
    port = 6379;
    bind = null;
    extraParams = [ "--protected-mode no" ];
    appendOnly = true;
    appendFsync = "everysec";
  };

  age.secrets.fort-gatehouse-wg.file = ../secrets/fort_gatehouse_wg.age;

  networking.nat = {
    enable = true;
    internalInterfaces = [ "wg0" ];
  };

  networking.firewall.allowedUDPPorts = [ 51820 ];

  networking.wireguard = {
    enable = true;
    interfaces = {
      wg0 = {
        ips = [ "10.100.0.2/24" ];

        listenPort = 51820;
        privateKeyFile = config.age.secrets.fort-gatehouse-wg.path;
        peers = [{
          name = "fort-barbican";
          publicKey = "IIXIDuJZf1lq9whdhnkAC7+gWX3Gef19dLiTFL37FDA=";
          allowedIPs = [ "10.100.0.1/32" ];
          endpoint = "${fort.settings.domain}:51820";
          persistentKeepalive = 25;
        }];
      };
    };
  };
}
