{ ... }:
{ lib, ... }:
{
  services.nginx = {
    enable = lib.mkDefault true;
    appendHttpConfig = ''
      include /var/lib/fort/nginx/public-services.conf;
    '';
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/fort/nginx 0750 root nginx -"
    "f /var/lib/fort/nginx/public-services.conf 0640 root nginx -"
  ];
}
