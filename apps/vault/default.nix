{ ... }:
{ lib, config, ... }:
{
  # nginx needs to read from /home/dev/Projects/hoard/vault
  systemd.services.nginx.serviceConfig = {
    ProtectHome = lib.mkForce "tmpfs";
    BindReadOnlyPaths = [ "/home/dev/Projects/hoard/vault" ];
  };

  fort.cluster.services = [
    {
      name = "vault";
      staticRoot = "/home/dev/Projects/hoard/vault";
      visibility = "public";
      sso = {
        mode = "gatekeeper";
        vpnBypass = true;
      };
    }
  ];
}
