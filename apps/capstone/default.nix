{ ... }:
{ lib, config, ... }:
{
  # nginx needs to read from /home/dev/capstone
  systemd.services.nginx.serviceConfig = {
    ProtectHome = lib.mkForce "tmpfs";
    BindReadOnlyPaths = [ "/home/dev/capstone" ];
  };

  fort.cluster.services = [
    {
      name = "capstone";
      staticRoot = "/home/dev/capstone";
      visibility = "vpn";
      sso.mode = "none";
    }
  ];
}
