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
  services.nginx.virtualHosts."cdn.${domain}".locations = {
    # Fonts are content-addressed — cache forever
    "~* \\.(woff2)$".extraConfig = ''
      add_header Access-Control-Allow-Origin "*";
      add_header Cache-Control "public, max-age=31536000, immutable";
    '';
    # WASM changes at the same URL (no content hash yet) — short TTL
    "~* \\.(wasm)$".extraConfig = ''
      add_header Access-Control-Allow-Origin "*";
      add_header Cache-Control "public, max-age=30, must-revalidate";
    '';
    # JS/JSON may change at the same URL — short TTL, revalidate
    "~* \\.(js|json)$".extraConfig = ''
      add_header Access-Control-Allow-Origin "*";
      add_header Cache-Control "public, max-age=30, must-revalidate";
    '';
  };

  fort.cluster.services = [
    {
      name = "cdn";
      staticRoot = "/home/dev/Projects/hoard/cdn";
      visibility = "public";
      sso.mode = "none";
    }
  ];
}
