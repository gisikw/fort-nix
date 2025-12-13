{ ... }:
{ ... }:
{
  services.actual = {
    enable = true;
    settings = {
      hostname = "127.0.0.1";
      port = 5006;
    };
  };

  fortCluster.exposedServices = [
    {
      name = "actualbudget";
      subdomain = "budget";
      port = 5006;
    }
  ];
}
