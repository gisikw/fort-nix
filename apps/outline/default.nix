{ rootManifest, ... }:
{ ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
in
{
  services.outline = {
    enable = true;
    port = 4654;
    publicUrl = "https://outline.${domain}";
    storage.storageType = "local";
  };

  fortCluster.exposedServices = [
    {
      name = "outline";
      port = 4654;
    }
  ];
}
