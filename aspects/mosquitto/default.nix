{ users ? [], deviceProfileManifest, ... }:
{ config, lib, ... }:
if (deviceProfileManifest.platform or "nixos") != "nixos" then
  throw "fort-nix: aspect 'mosquitto' is Linux-only (services.mosquitto NixOS module); remove it from this darwin host's manifest"
else
{
  services.mosquitto = {
    enable = true;
    listeners = [
      {
        address = "127.0.0.1";
        port = 1883;
        users = lib.listToAttrs (map (u: {
          name = u.name;
          value = {
            passwordFile = config.sops.secrets.${u.secret}.path;
            acl = [ "readwrite #" ];
          };
        }) users);
      }
    ];
  };
}
