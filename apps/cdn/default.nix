{ ... }:
{ ... }:
{
  # nginx needs o+x on /home/dev to traverse to the cdn root
  system.activationScripts.cdnPerms = "chmod o+x /home/dev";

  fort.cluster.services = [
    {
      name = "cdn";
      staticRoot = "/home/dev/Projects/hoard/cdn";
      visibility = "public";
      sso.mode = "none";
    }
  ];
}
