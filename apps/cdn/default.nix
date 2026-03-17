{ ... }:
{ ... }:
{
  fort.cluster.services = [
    {
      name = "cdn";
      staticRoot = "/home/dev/Projects/hoard/cdn";
      visibility = "public";
      sso.mode = "none";
    }
  ];
}
