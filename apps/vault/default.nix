{ ... }:
{ lib, config, ... }:
{
  # nginx needs to read from /home/dev/vault
  systemd.services.nginx.serviceConfig = {
    ProtectHome = lib.mkForce "tmpfs";
    BindReadOnlyPaths = [ "/home/dev/vault" ];
  };

  fort.cluster.services = [
    {
      name = "vault";
      staticRoot = "/home/dev/vault";
      visibility = "public";
      sso = {
        mode = "gatekeeper";
        vpnBypass = true;
      };
    }
  ];
}
