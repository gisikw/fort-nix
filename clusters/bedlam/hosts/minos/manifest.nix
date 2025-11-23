rec {
  hostName = "minos";
  device = "bc186c00-30ac-11ef-8d7b-488ccae81000";

  roles = [ ];

  apps = [ ];

  aspects = [
    "mesh"
    { 
      name = "zigbee2mqtt"; 
      passwordFile = ./mosquitto-zigbee2mqtt-password.age; 
      mqttSecretName = "mosquitto-zigbee2mqtt-password";
    }
    { 
      name = "mosquitto";
      users = [
        { name = "zigbee2mqtt"; secret = "mosquitto-zigbee2mqtt-password"; }
      ];
    }
    "observable"
  ];

  module =
    { config, ... }:
    {
      config.fort.host = { inherit roles apps aspects; };
    };
}
