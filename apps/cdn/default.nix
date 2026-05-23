{ ... }:
{ lib, config, ... }:
let
  domain = config.fort.cluster.settings.domain;
in
{
  # nginx needs to read from /home/dev/Projects/hoard/cdn
  system.activationScripts.cdnPerms = "chmod o+x /home/dev";
  systemd.services.nginx.serviceConfig = {
    ProtectHome = lib.mkForce "tmpfs";
    BindReadOnlyPaths = [ "/home/dev/Projects/hoard/cdn" ];
  };

  # CORS headers for assets served cross-origin (fonts, wasm, js)
  services.nginx.virtualHosts."cdn.${domain}".locations."~* \\.(woff2|wasm|js|json)$".extraConfig = ''
    add_header Access-Control-Allow-Origin "*";
    add_header Cache-Control "public, max-age=31536000, immutable";
  '';

  fort.cluster.services = [
    {
      name = "cdn";
      staticRoot = "/home/dev/Projects/hoard/cdn";
      visibility = "public";
      sso.mode = "none";
    }
  ];
}
