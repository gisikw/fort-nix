{ config, pkgs, ... }:

{
  age.secrets.fort-barbican-wg.file = ../secrets/fort_barbican_wg.age;

  environment.systemPackages = [ pkgs.redis ];

  networking.nat = {
    enable = true;
    externalInterface = "eth0";
    internalInterfaces = [ "wg0" ];
  };

  networking.firewall.allowedUDPPorts = [ 51820 ];

  networking.wireguard = {
    enable = true;
    interfaces = {
      wg0 = {
        ips = [ "10.100.0.1/24" ];

        listenPort = 51820;
        privateKeyFile = config.age.secrets.fort-barbican-wg.path;
        peers = [{
          name = "fort-gatehouse";
          publicKey = "u4r/24By0l498kVeCaJeAIyGHDi6wobUVEUuJ866KC4=";
          allowedIPs = [ "10.100.0.2/32" ];
        }];
      };
    };
  };
}
