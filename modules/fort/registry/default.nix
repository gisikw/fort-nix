{ config, pkgs, lib, fort, ... }:

let
  port = 60452;
in
{
  networking.firewall.allowedTCPPorts = [ port ];

  age.secrets.hmac_key = {
    file = ../../../secrets/hmac_key.age;
    owner = "root";
    group = "root";
  };

  age.secrets.registry_key = {
    file = ../../../secrets/registry_key.age;
    owner = "root";
    group = "root";
  };

  systemd.services.fort-registry = {
    description = "Supports dynamic registration of fort-nix managed hosts";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];

    serviceConfig = {
      ExecStart = fort.lib.mkRubyScript ./server.rb
        [ "sinatra" "rackup" "puma" ]
        {
          inherit port;
          domain = fort.settings.domain;
        };
      Environment = [
        "REGISTRY_KEY_PATH=${config.age.secrets.registry_key.path}"
        "HMAC_SECRET_PATH=${config.age.secrets.hmac_key.path}"
      ];
      DynamicUser = false;
    };

    path = [ pkgs.age ];
  };
}
