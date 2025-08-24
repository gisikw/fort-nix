{ ... }: 

{
  services.redis.servers."fort-registry" = {
    enable = true;
    port = 6379;
    appendOnly = true;
    appendFsync = "everysec";
  };

  imports = [
    ../modules/fort/registry-coredns-subscriber
    ../modules/fort/coredns.nix
    ../modules/fort/registry
  ];
}
