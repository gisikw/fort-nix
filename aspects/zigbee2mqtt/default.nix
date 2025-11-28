{ passwordFile, mqttSecretName, iot, ... }:
{ config, pkgs, ... }:
{
  age.secrets.${mqttSecretName} = {
    file = passwordFile;
    owner = "zigbee2mqtt";
    mode = "0440";
    group = "mosquitto";
  };

  age.secrets.iotManifest = {
    file = iot.manifest;
    owner = "zigbee2mqtt";
  };

  users.users.zigbee2mqtt.extraGroups = [ "dialout" ];

  systemd.services.zigbee2mqtt = {
    serviceConfig.LoadCredential = 
      "mqtt-password:${config.age.secrets.${mqttSecretName}.path}";
    restartTriggers = [
      config.age.secrets.${mqttSecretName}.file
      config.age.secrets.iotManifest.file
    ];
  };

  services.zigbee2mqtt = {
    enable = true;
    package = pkgs.writeShellScriptBin "zigbee2mqtt" ''
      while IFS=: read ieee script_name friendly_name; do
        ${pkgs.yq-go}/bin/yq -i ".$ieee.friendly_name = \"$friendly_name\"" /var/lib/zigbee2mqtt/devices.yaml
      done < <(grep -v -e '^$' -e '^#' ${config.age.secrets.iotManifest.path})
      export ZIGBEE2MQTT_CONFIG_MQTT_PASSWORD=$(cat ''${CREDENTIALS_DIRECTORY}/mqtt-password)
      exec ${pkgs.zigbee2mqtt}/bin/zigbee2mqtt "$@"
    '';
    settings = {
      serial = {
        port = "/dev/serial/by-id/usb-Itead_Sonoff_Zigbee_3.0_USB_Dongle_Plus_V2_32c5a1246cf3ef1185ddbd1b6d9880ab-if00-port0";
        adapter = "ember";
      };

      mqtt = {
        server = "mqtt://127.0.0.1:1883";
        user = "zigbee2mqtt";
      };

      homeassistant = true;
      permit_join = false;

      frontend = {
        port = 8080;
        host = "127.0.0.1";
      };
    };
  };

  fortCluster.exposedServices = [
    {
      name = "zigbee";
      port = 8080;
      visibility = "local";
    }
  ];
}
