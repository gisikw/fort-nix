{ ... }:
{ pkgs, ... }:

let
  projectDir = "/home/dev/Projects/headjack";
in
{
  systemd.services.headjack = {
    description = "Headjack - Matrix to cranium-v2 bridge";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "cranium-v2.service" "conduit.service" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "simple";
      User = "dev";
      Group = "users";
      WorkingDirectory = projectDir;
      Restart = "on-failure";
      RestartSec = 5;
    };
    environment = {
      HOME = "/home/dev";
      HEADJACK_CONFIG = "${projectDir}/headjack.yaml";
    };
    path = with pkgs; [ coreutils ];
    script = ''
      exec ${projectDir}/headjack
    '';
  };
}
