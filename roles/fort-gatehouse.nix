{ ... }: 

{
  services.redis.servers."fort-registry" = {
    enable = true;
    port = 6379;
    appendOnly = true;
    appendFsync = "everysec";
  };

  imports = [
    ../modules/fort/registry-coredns-subscriber
  ];

  # systemd.services.fort-registry-coredns = {
  #   description = "Update CoreDNS on registry change";
  #   path = [ pkgs.jq, pkgs.redis ];
  #   script = ''
  #       cat <<'EOF' > script.rb
  #         puts 5
  #       EOF
  #     "
  #     set -e
  #     redis-cli -s /run/redis-fort-registry/redis.sock SUBSCRIBE updates | \
  #     while read -r _msg; do
  #       read -r _channel; read -r _payload
  #       redis-cli -s /run/redis-fort-registry/redis.sock keys '*' | while read -r key; do

  #       done
  #     done
  #   '';
  # };


  # networking.firewall.interfaces."wg0".allowedTCPPorts = [ 6379 ];
}
