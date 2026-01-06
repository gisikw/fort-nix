{ subdomain ? null, ... }:
{ config, pkgs, lib, ... }:
let
  rubyEnv = pkgs.bundlerEnv {
    name = "fort-mcp-env";
    ruby = pkgs.ruby_3_3;
    gemdir = ./.;
  };

  appDir = pkgs.runCommand "fort-mcp-app" { } ''
    mkdir -p $out
    cp ${./config.ru} $out/config.ru
    cp ${./server.rb} $out/server.rb
  '';
in
{
  users.users.fort-mcp = {
    isSystemUser = true;
    group = "fort-mcp";
  };
  users.groups.fort-mcp = { };

  age.secrets.fort-mcp-env = {
    file = ./secrets.env.age;
    owner = "fort-mcp";
    mode = "0400";
  };

  systemd.services.fort-mcp = {
    description = "Fort MCP Server";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    restartTriggers = [ config.age.secrets.fort-mcp-env.file ];
    path = with pkgs; [
      tailscale
    ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${rubyEnv}/bin/puma -e production -b tcp://127.0.0.1:9292 ${appDir}/config.ru";
      EnvironmentFile = config.age.secrets.fort-mcp-env.path;
      Restart = "always";
      RestartSec = 5;
      DynamicUser = false;
      User = "fort-mcp";
      Group = "fort-mcp";
      StateDirectory = "fort-mcp";
      WorkingDirectory = "/var/lib/fort-mcp";
    };
  };

  fort.cluster.services = [
    {
      name = "mcp";
      subdomain = subdomain;
      port = 9292;
      visibility = "public";
    }
  ];
}
