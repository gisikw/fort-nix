{ ... }:
{ config, pkgs, lib, ... }:
let
  rebootListener = pkgs.buildGoModule {
    pname = "emergency-reboot";
    version = "0.1.0";
    src = ./.;
    vendorHash = null;
    meta.description = "Emergency UDP reboot listener — software BMC for wedged hosts";
  };

  port = 9999;

  # Client script — available on all hosts so any box can reboot any other
  rebootClient = pkgs.writeShellScriptBin "emergency-reboot" ''
    set -euo pipefail
    HOST="''${1:?Usage: emergency-reboot <host-ip-or-tailscale-name>}"
    SECRET=$(cat "${config.age.secrets.reboot-secret.path}")
    TS=$(${pkgs.coreutils}/bin/date +%s)
    MAC=$(echo -n "$TS" | ${pkgs.openssl}/bin/openssl dgst -sha256 -hmac "$SECRET" -hex 2>/dev/null | ${pkgs.gawk}/bin/awk '{print $NF}')
    echo "Sending reboot to ''${HOST}:${toString port}..."
    echo -n "''${TS}.''${MAC}" | ${pkgs.libressl.nc}/bin/nc -u -w2 "$HOST" ${toString port}
    echo "Sent. Host should reboot momentarily."
  '';
in
{
  age.secrets.reboot-secret = {
    file = ./reboot-secret.age;
    mode = "0400";
  };

  environment.systemPackages = [ rebootClient ];

  systemd.services.emergency-reboot = {
    description = "Emergency UDP reboot listener";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      ExecStart = "${rebootListener}/bin/emergency-reboot";
      Restart = "always";
      RestartSec = "2s";

      # Survive OOM — the whole point of this service
      OOMScoreAdjust = "-1000";

      # Needs CAP_SYS_BOOT for reboot(2)
      AmbientCapabilities = [ "CAP_SYS_BOOT" ];
      CapabilityBoundingSet = [ "CAP_SYS_BOOT" "CAP_NET_BIND_SERVICE" ];

      Environment = [
        "SECRET_FILE=${config.age.secrets.reboot-secret.path}"
        "LISTEN_ADDR=:${toString port}"
      ];
    };
  };

  # Allow UDP through the firewall
  networking.firewall.allowedUDPPorts = [ port ];
}
