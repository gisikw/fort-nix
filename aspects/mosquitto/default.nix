{ users ? [], ... }:
{ config, lib, ... }:
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
            passwordFile = config.age.secrets.${u.secret}.path;
            acl = [ "readwrite #" ];
          };
        }) users);
      }
    ];
  };
}
