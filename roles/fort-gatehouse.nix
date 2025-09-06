{ config, fort, pkgs, lib, ... }:

{
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  imports = [
    ../modules/fort/registry-coredns-subscriber
    ../modules/fort/coredns.nix
    ../modules/fort/registry
    ../modules/fort/announce.nix
    # ../modules/fort/webstatus.nix
    # ../modules/fort/reverse-proxy.nix
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

  environment.systemPackages = [ pkgs.neovim ];

  systemd.tmpfiles.rules = [
    "f /var/lib/haproxy/dynamic.cfg 0640 haproxy haproxy -"
  ];

  systemd.services.haproxy.serviceConfig = {
    ExecStart = lib.mkForce "/run/haproxy/haproxy -Ws -f /etc/haproxy.cfg -f /var/lib/haproxy/dynamic.cfg -p /run/haproxy/haproxy.pid";

    ExecReload = lib.mkForce [
      "/run/haproxy/haproxy -c -f /etc/haproxy.cfg -f /var/lib/haproxy/dynamic.cfg"
      "${pkgs.coreutils}/bin/ln -sf ${lib.getExe config.services.haproxy.package} /run/haproxy/haproxy"
      "${pkgs.coreutils}/bin/kill -USR2 $MAINPID"
    ];
  };

  networking.firewall.allowedTCPPorts = [ 443 ];
  services.haproxy = {
    enable = true;
    config = ''
      defaults
        mode tcp
        timeout connect 10s
        timeout client  30s
        timeout server  30s
    '';
  };

}
