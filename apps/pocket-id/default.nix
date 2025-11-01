{ rootManifest, ... }:
{ config, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
in
{
  services.pocket-id = {
    enable = true;
    settings = {
      TRUST_PROXY = true;
      APP_URL = "https://id.${domain}";
    };
  };

  fortCluster.exposedServices = [
    {
      name = "pocket-id";
      subdomain = "id";
      port = 1411;
      openToLAN = true;
      openToWAN = true;
    }
  ];
}
