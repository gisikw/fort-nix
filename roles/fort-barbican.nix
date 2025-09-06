{ config, pkgs, fort, ... }:

{
  age.secrets.fort-barbican-wg.file = ../secrets/fort_barbican_wg.age;

  environment.systemPackages = [ pkgs.redis ];

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

  networking.firewall.allowedTCPPorts = [ 80 443 ];
  services.haproxy = {
    enable = true;
    config = ''
      defaults
        mode tcp
        timeout connect 10s
        timeout client  30s
        timeout server  30s

      frontend https-in
        bind *:443
        tcp-request inspect-delay 5s
        tcp-request content accept if { req_ssl_hello_type 1 }
        default_backend gatehouse

      backend gatehouse
        mode tcp
        server gatehouse 10.100.0.2:443

      frontend http-in
        bind *:80
        mode http
        redirect scheme https code 301
      '';
  };
}
