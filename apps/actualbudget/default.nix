{ ... }:
{ ... }:
{
  services.actual-server = {
    enable = true;
    host = "127.0.0.1";
    port = 5006;
  };

  fortCluster.exposedServices = [
    {
      name = "actualbudget";
      subdomain = "budget";
      port = 5006;
    }
  ];
}
