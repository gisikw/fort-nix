{ ... }:
{ config, pkgs, lib, ... }:
let
  fort-tokens = import ../../pkgs/fort-tokens { inherit pkgs; };
in
{
  age.secrets.fort-token-secret-tokens = {
    file = ../../common/fort/token-secret.age;
    path = "/var/lib/fort-auth/token-secret";
    mode = "0400";
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/fort-tokens 0700 root root -"
  ];

  systemd.services.fort-tokens = {
    description = "Fort token management service";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      ExecStart = "${fort-tokens}/bin/fort-tokens";
      Restart = "on-failure";
      RestartSec = "5s";
      StateDirectory = "fort-tokens";
      Environment = [
        "TOKEN_SECRET_FILE=/var/lib/fort-auth/token-secret"
        "TOKEN_DB_PATH=/var/lib/fort-tokens/tokens.db"
        "LISTEN_ADDR=127.0.0.1:9471"
      ];
    };
  };

  fort.cluster.services = [{
    name = "fort-tokens";
    subdomain = "tokens";
    port = 9471;
    visibility = "public";
    sso = {
      mode = "headers";
      groups = [ "admin" ];
      restart = "fort-tokens.service";
    };
  }];
}
