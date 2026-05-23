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

  # CORS + caching for assets served cross-origin
  # Fonts and wasm blobs are content-addressed — cache forever
  services.nginx.virtualHosts."cdn.${domain}".locations."~* \\.(woff2|wasm)$".extraConfig = ''
    add_header Access-Control-Allow-Origin "*";
    add_header Cache-Control "public, max-age=31536000, immutable";
  '';
  # JS/JSON may change at the same URL — short TTL, revalidate
  services.nginx.virtualHosts."cdn.${domain}".locations."~* \\.(js|json)$".extraConfig = ''
    add_header Access-Control-Allow-Origin "*";
    add_header Cache-Control "public, max-age=300, must-revalidate";
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
