{ ... }:
{ config, ... }:
{
  services.mosquitto = {
    enable = true;
    listeners = [
      {
        address = "127.0.0.1";
        port = 1883;
        users = {
          zigbee2mqtt = {
            passwordFile = config.age.secrets.mosquitto-zigbee2mqtt-password.path;
            acl = [ "readwrite #" ];
          };
          homeassistant = {
            passwordFile = config.age.secrets.mosquitto-homeassistant-password.path;
            acl = [ "readwrite #" ];
          };
        };
      }
    ];
  };

  age.secrets.mosquitto-zigbee2mqtt-password = {
    file = ./mosquitto-zigbee2mqtt-password.age;
    owner = "mosquitto";
  };
  age.secrets.mosquitto-homeassistant-password = {
    file = ./mosquitto-homeassistant-password.age;
    owner = "mosquitto";
  };
}
