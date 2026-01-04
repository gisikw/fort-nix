{ subdomain ? "budget", ... }:
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
      subdomain = subdomain;
      port = 5006;
    }
  ];
}
