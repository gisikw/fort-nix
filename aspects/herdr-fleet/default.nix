{ rootManifest, deviceProfileManifest, ... }:
{ config, lib, pkgs, ... }:
if (deviceProfileManifest.platform or "nixos") != "nixos" then
  throw "fort-nix: aspect 'herdr-fleet' is currently Linux-only"
else
let
  port = 9473;
  vpnIpv4Prefix = rootManifest.fortConfig.settings.vpn.ipv4Prefix;
  herdr = pkgs.stdenvNoCC.mkDerivation {
    pname = "herdr";
    version = "0.8.0";
    src = pkgs.fetchurl {
      url = "https://github.com/herdrdev/herdr/releases/download/v0.8.0/herdr-linux-x86_64";
      sha256 = "b872ea7e40fa2cb17e857ac9b62b1bf26db7b403c622f5d2f3f5b35f6e9acd28";
    };
    dontUnpack = true;
    installPhase = ''
      install -Dm755 "$src" "$out/bin/herdr"
    '';
  };
  claude = import ../../pkgs/claude-code { inherit pkgs; };
in
{
  users.groups.herdr-fleet = { };
  users.users.herdr-fleet = {
    isSystemUser = true;
    group = "herdr-fleet";
    home = "/var/lib/herdr-fleet";
    createHome = true;
    shell = pkgs.bashInteractive;
    description = "Persistent Herdr fleet session";
  };

  environment.systemPackages = [ herdr ];

  systemd.services.herdr-fleet = {
    description = "Persistent Herdr fleet session";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [ herdr claude pkgs.bashInteractive pkgs.coreutils pkgs.git ];
    environment = {
      HOME = "/var/lib/herdr-fleet";
      HERDR_SESSION = "fleet";
      ANTHROPIC_BASE_URL = "http://lordhenry:8900";
      ANTHROPIC_AUTH_TOKEN = "tiamat-tailnet";
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
      DISABLE_TELEMETRY = "1";
    };
    serviceConfig = {
      Type = "simple";
      User = "herdr-fleet";
      Group = "herdr-fleet";
      WorkingDirectory = "/var/lib/herdr-fleet";
      ExecStart = "${herdr}/bin/herdr server";
      Restart = "always";
      RestartSec = "2s";
    };
  };

  # Herdr already speaks newline-delimited JSON over its Unix socket. Socat only
  # carries that byte stream onto the mesh; it adds no second protocol.
  systemd.services.herdr-fleet-socket = {
    description = "Expose Herdr fleet socket on the fort mesh";
    wantedBy = [ "multi-user.target" ];
    requires = [ "herdr-fleet.service" ];
    after = [ "herdr-fleet.service" ];
    serviceConfig = {
      Type = "simple";
      User = "herdr-fleet";
      Group = "herdr-fleet";
      ExecStart = "${pkgs.socat}/bin/socat TCP-LISTEN:${toString port},bind=0.0.0.0,reuseaddr,fork UNIX-CONNECT:/var/lib/herdr-fleet/.config/herdr/sessions/fleet/herdr.sock";
      Restart = "always";
      RestartSec = "2s";
    };
  };

  # Tailnet membership is the identity boundary. Do not also invent application
  # credentials for this internal control socket.
  networking.firewall.extraCommands = ''
    iptables -w -A nixos-fw -p tcp -s ${vpnIpv4Prefix} --dport ${toString port} \
      -m comment --comment "herdr-fleet-mesh" -j nixos-fw-accept
  '';

  fort.cluster.services = [
    {
      name = "herdr-fleet";
      port = port;
      visibility = "vpn";
      sso.mode = "none";
      health.enabled = false;
    }
  ];
}
