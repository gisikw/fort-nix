rec {
  hostName = "minos";
  device = "bc186c00-30ac-11ef-8d7b-488ccae81000";

  roles = [ ];

  apps = [
    {
      name = "homeassistant";
      mqttPasswordFile = ./mosquitto-homeassistant-password.age;
      mqttPasswordSecretName = "mosquitto-homeassistant-password";
      declarative.automations = ./automations.nix;
      declarative.lights = ./lights.nix;
      declarative.scenes = ./scenes.nix;
      declarative.scripts = ./scripts.nix;
    }
  ];

  aspects = [
    "mesh"
    {
      name = "zigbee2mqtt";
      passwordFile = ./mosquitto-zigbee2mqtt-password.age;
      mqttSecretName = "mosquitto-zigbee2mqtt-password";
      iot.manifest = ./iot.manifest.age;
    }
    {
      name = "zwave-js-ui";
      passwordFile = ./mosquitto-zwave-js-ui-password.age;
      mqttSecretName = "mosquitto-zwave-js-ui-password";
      securityKeysFile = ./zwave-security-keys.json.age;
      iot.manifest = ./iot.manifest.age;
    }
    {
      name = "mosquitto";
      users = [
        { name = "zigbee2mqtt"; secret = "mosquitto-zigbee2mqtt-password"; }
        { name = "zwave"; secret = "mosquitto-zwave-js-ui-password"; }
        { name = "hass"; secret = "mosquitto-homeassistant-password"; }
      ];
    }
    "observable"
    "gitops"
  ];

  module =
    { config, ... }:
    {
      config.fort.host = { inherit roles apps aspects; };
    };
}
