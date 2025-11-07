{ namespace ? "egress-vpn", ... }:
{ pkgs, config, ... }:
let
  tunnelInterface = "egresstun0";
in
{
  age.secrets.egress-vpn-conf = {
    file = ./egress-vpn-conf.age;
    mode = "0400";
    owner = "root";
  };

  networking.wg-quick.interfaces.${tunnelInterface}.configFile = config.age.secrets.egress-vpn-conf.path;

  systemd.services.egress-vpn-namespace = {
    after = [ "wg-quick-${tunnelInterface}.service" ];
    wants = [ "wg-quick-${tunnelInterface}.service" ];
    wantedBy = [ "multi-user.target" ];

    path = with pkgs; [ iproute2 iptables procps ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
       ExecStart = pkgs.writeShellScript "egress-vpn-namespace-start" ''
        # Create the namespace unless it already exists
        ip netns list | grep -q "^${namespace}\b" || ip netns add ${namespace}

        # Create the veth pair unless it already exists
        if ! ip link show veth-egress >/dev/null 2>&1; then
          ip link add veth-egress type veth peer name veth-egress-ns netns ${namespace}
        fi

        # Assign addresses (/30 avoids Linux treating it as local-only)
        ip addr flush dev veth-egress
        ip addr add 10.200.0.1/30 dev veth-egress
        ip link set veth-egress up

        ip netns exec ${namespace} ip addr flush dev veth-egress-ns
        ip netns exec ${namespace} ip addr add 10.200.0.2/30 dev veth-egress-ns
        ip netns exec ${namespace} ip link set veth-egress-ns up
        ip netns exec ${namespace} ip link set lo up

        # Default route inside the namespace via host
        ip netns exec ${namespace} ip route replace default via 10.200.0.1

        # Enable forwarding globally and on both interfaces
        sysctl -w net.ipv4.ip_forward=1 >/dev/null
        sysctl -w net.ipv4.conf.veth-egress.forwarding=1 >/dev/null
        sysctl -w net.ipv4.conf.${tunnelInterface}.forwarding=1 >/dev/null

        # Allow forwarding out and established return traffic
        iptables -C FORWARD -i veth-egress -o ${tunnelInterface} -j ACCEPT 2>/dev/null || \
          iptables -I FORWARD -i veth-egress -o ${tunnelInterface} -j ACCEPT
        iptables -C FORWARD -i ${tunnelInterface} -o veth-egress -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
          iptables -I FORWARD -i ${tunnelInterface} -o veth-egress -m state --state RELATED,ESTABLISHED -j ACCEPT

        # NAT namespace -> VPN
        iptables -t nat -C POSTROUTING -s 10.200.0.0/30 -o ${tunnelInterface} -j MASQUERADE 2>/dev/null || \
          iptables -t nat -A POSTROUTING -s 10.200.0.0/30 -o ${tunnelInterface} -j MASQUERADE

        # Ensure local route back to the veth pair
        ip route show 10.200.0.0/30 >/dev/null 2>&1 || ip route add 10.200.0.0/30 dev veth-egress

        # Namespace resolver
        mkdir -p /etc/netns/${namespace}
        echo "nameserver 1.1.1.1" > /etc/netns/${namespace}/resolv.conf

        # Policy routing for namespace traffic → VPN
        ip rule list | grep -q "iif veth-egress lookup 100" || \
          ip rule add iif veth-egress lookup 100
        ip route replace default dev ${tunnelInterface} table 100
      '';
    };
  };
}
