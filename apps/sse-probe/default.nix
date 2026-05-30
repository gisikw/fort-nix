{ mode ? "serve", port ? 9400, targets ? [], rootManifest, ... }:
{ pkgs, lib, ... }:
let
  sse-probe = import ../../pkgs/sse-probe { inherit pkgs; };
  domain = rootManifest.fortConfig.settings.domain;
  isServe = mode == "serve";
  isMonitor = mode == "monitor";

  targetArgs = lib.concatMapStringsSep " " (t: "--target ${t}") targets;
in
{
  systemd.services.sse-probe = {
    description = "SSE drop-rate diagnostic ${if isServe then "broadcaster" else "monitor"}";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      ExecStart =
        if isServe then
          "${sse-probe}/bin/sse-probe serve --port ${toString port}"
        else
          "${sse-probe}/bin/sse-probe monitor ${targetArgs} --log /var/lib/sse-probe/drops.jsonl";
      Restart = "always";
      RestartSec = 5;
      DynamicUser = true;
      StateDirectory = lib.mkIf isMonitor "sse-probe";
    };
  };

  # Open the port for broadcasters so the monitor can reach them over Tailscale
  networking.firewall.allowedTCPPorts = lib.mkIf isServe [ port ];
}
