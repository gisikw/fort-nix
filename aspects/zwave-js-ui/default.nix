{ passwordFile, mqttSecretName, securityKeysFile, ... }:
{ config, pkgs, lib, ... }:
let
  jsonFormat = pkgs.formats.json { };
  settingsFile = jsonFormat.generate "zwave-js-ui-settings.json" {
    mqtt = {
      name = "zwave-js-ui";
      host = "127.0.0.1";
      port = 1883;
      disabled = false;
      reconnectPeriod = 3000;
      prefix = "zwave";
      qos = 1;
      retain = true;
      clean = true;
      store = true;
      allowSelfsigned = false;
      key = "";
      cert = "";
      ca = "";
      auth = true;
      username = "zwave";
      password = "__MQTT_PASSWORD__";
      _ca = "";
      _key = "";
      _cert = "";
    };
    zwave = {
      port = "/dev/serial/by-id/usb-Zooz_800_Z-Wave_Stick_533D004242-if00";
      commandsTimeout = 30000;
      logEnabled = true;
      logLevel = "info";
      logToFile = false;
      enableStatistics = false;
    };
    gateway = {
      type = 0;
      payloadType = 0;
      nodeNames = true;
      hassDiscovery = true;
      discoveryPrefix = "homeassistant";
      sendEvents = true;
      ignoreStatus = false;
      logEnabled = true;
      logLevel = "info";
      logToFile = false;
    };
  };
in
{
  age.secrets.${mqttSecretName} = {
    file = passwordFile;
    owner = "root";
    mode = "0400";
    group = "root";
  };

  age.secrets.zwave-security-keys = {
    file = securityKeysFile;
    owner = "root";
    mode = "0400";
    group = "root";
  };

  services.zwave-js-ui = {
    enable = true;
    serialPort = "/dev/serial/by-id/usb-Zooz_800_Z-Wave_Stick_533D004242-if00";
    settings = { };
  };

  systemd.services.zwave-js-ui-config = {
    description = "Configure zwave-js-ui settings with MQTT credentials";
    before = [ "zwave-js-ui.service" ];
    requiredBy = [ "zwave-js-ui.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      mkdir -p /var/lib/zwave-js-ui
      MQTT_PASSWORD=$(cat ${config.age.secrets.${mqttSecretName}.path})
      ${pkgs.gnused}/bin/sed "s/__MQTT_PASSWORD__/$MQTT_PASSWORD/" ${settingsFile} \
        | ${pkgs.jq}/bin/jq -s '.[0] * .[1]' - ${config.age.secrets.zwave-security-keys.path} \
        > /var/lib/zwave-js-ui/settings.json
      chmod 600 /var/lib/zwave-js-ui/settings.json
    '';
  };

  systemd.services.zwave-js-ui.restartTriggers = [
    config.age.secrets.${mqttSecretName}.file
  ];

  fortCluster.exposedServices = [
    {
      name = "zwave";
      port = 8091;
    }
  ];
}
