{ subdomain ? null, rootManifest, ... }:
{ pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  yamlFormat = pkgs.formats.yaml { };
  homepageConfig = {
    title = "Fort Nix";
    description = "This is a test description";
  };
  configFile = yamlFormat.generate "homepage-config.yaml" homepageConfig;
in
{

  virtualisation.oci-containers = {
    containers.homepage = {
      image = "containers.${domain}/ghcr.io/gethomepage/homepage:latest";
      ports = [ "8425:3000" ];
      volumes = [ "/var/lib/homepage/config:/app/config" ];
      environment.HOMEPAGE_ALLOWED_HOSTS = "home.${domain}";
    };
  };

  system.activationScripts.homepageConfig = ''
    install -Dm0640 ${configFile} /var/lib/homepage/config/settings.yaml
  '';

  systemd.tmpfiles.rules = [
    "d /var/lib/homepage/config 0755 root root -"
  ];

  fortCluster.exposedServices = [
    {
      name = "home";
      subdomain = subdomain;
      port = 8425;
    }
  ];
}
