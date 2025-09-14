{ config, lib, pkgs, ... }:

{
  age.secrets.egress-vpn-conf = {
    file = ../../secrets/egress-vpn-conf.age;
    mode = "0400";
    owner = "root";
  };


  networking.wg-quick.interfaces.tun0.configFile = config.age.secrets.egress-vpn-conf.path;

  users.groups.vpngroup = {};

  networking.firewall.extraCommands = ''
    ${pkgs.iproute2}/bin/ip rule add fwmark 0x1 lookup 100 # || true
    ${pkgs.iproute2}/bin/ip route add default dev tun0 table 100 # || true
    ${pkgs.iptables}/bin/iptables -t mangle -C OUTPUT -m owner --gid-owner vpngroup -j MARK --set-mark 0x1 \
    || ${pkgs.iptables}/bin/iptables -t mangle -A OUTPUT -m owner --gid-owner vpngroup -j MARK --set-mark 0x1
  '';
}
