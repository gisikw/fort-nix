{ config, lib, pkgs, ... }:

{
  networking.firewall.allowedTCPPorts = [ 53 ];
  networking.firewall.allowedUDPPorts = [ 53 ];

  services.blocky = {
    enable = true;
    settings = {
      ports.dns = 53;

      upstreams.groups.default = [
        "https://1.1.1.1/dns-query"
      ];

      bootstrapDns = {
        upstream = "https://1.1.1.1/dns-query";
        ips = [ "1.1.1.1" "1.0.0.1" ];
      };

      blocking = {
        blackLists = {
          ads = [ "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts" ];
        };
        clientGroupsBlock = {
          default = [ "ads" ];
        };
      };
    };
  };
}
