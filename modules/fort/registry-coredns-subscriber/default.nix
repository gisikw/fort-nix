{ config, pkgs, fort, ... }: 

{
  systemd.services.fort-registry-coredns-subscriber = {
    description = "Update CoreDNS on registry change";
    after = [ "redis-fort-registry.service" ];
    requires = [ "redis-fort-registry.service" ];
    wantedBy = [ "multi-user.target" ];
    script = fort.lib.mkRubyScript ./listener.rb [ "redis" ] {
      registry_sock = config.services.redis.servers."fort-registry".unixSocket;
    };
  };
}
