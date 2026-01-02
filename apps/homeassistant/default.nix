{ mqttPasswordFile, mqttPasswordSecretName, rootManifest, declarative, ... }:
{ config, pkgs, lib, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  yamlFormat = pkgs.formats.yaml { };
  automationsFile = yamlFormat.generate "hass-automations.yaml" (import declarative.automations);
  lightsFile = yamlFormat.generate "hass-lights.yaml" (import declarative.lights);
  scenesFile = yamlFormat.generate "hass-scenes.yaml" (import declarative.scenes);
  scriptsFile = yamlFormat.generate "hass-scripts.yaml" (import declarative.scripts);
  helpers = if declarative ? helpers then import declarative.helpers else {};
in
{
  age.secrets.${mqttPasswordSecretName} = {
    file = mqttPasswordFile;
    owner = "hass";
    mode = "0400";
    group = "mosquitto";
  };

  age.secrets.ha-secrets = {
    file = ./secrets.yaml.age;
    owner = "hass";
    path = "/var/lib/hass/secrets.yaml";
  };

  services.home-assistant = {
    enable = true;

    extraComponents = [
      "mqtt"
      "met"
      "sun"
      "zeroconf"
      "esphome"
    ];

    config = {
      default_config = {};

      homeassistant = {
        name = "Home";
        latitude = "!secret latitude";
        longitude = "!secret longitude";
        elevation = "!secret elevation";
        unit_system = "us_customary";
        time_zone = "America/Chicago";
        external_url = "https://house.${domain}";
        internal_url = "https://house.${domain}";
      };

      automation = "!include automations.yaml";
      script = "!include scripts.yaml";
      scene = "!include scenes.yaml";
      light = "!include lights.yaml";

      http = {
        server_port = 8123;
        use_x_forwarded_for = true;
        trusted_proxies = [ "127.0.0.1" ];
      };
    } // helpers;
  };

  systemd.services.home-assistant.restartTriggers = [
    automationsFile
    lightsFile
    scenesFile
    scriptsFile
  ];

  systemd.services.home-assistant-config-fixup = {
    description = "Substitute entity IDs in Home Assistant config";
    before = [ "home-assistant.service" ];
    requiredBy = [ "home-assistant.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "hass";
    };
    restartTriggers = [
      automationsFile
      lightsFile
      scriptsFile
      scenesFile
    ];
    script = ''
      rm -f /var/lib/hass/automations.yaml
      rm -f /var/lib/hass/lights.yaml
      rm -f /var/lib/hass/scenes.yaml
      rm -f /var/lib/hass/scripts.yaml
      cp ${automationsFile} /var/lib/hass/automations.yaml
      cp ${lightsFile} /var/lib/hass/lights.yaml
      cp ${scenesFile} /var/lib/hass/scenes.yaml
      cp ${scriptsFile} /var/lib/hass/scripts.yaml

      while IFS=: read ieee script_name friendly_name; do
        [ -z "$ieee" ] && continue
        sed -i "s/$script_name/$ieee/g" /var/lib/hass/automations.yaml
        sed -i "s/$script_name/$ieee/g" /var/lib/hass/scripts.yaml
        sed -i "s/$script_name/$ieee/g" /var/lib/hass/scenes.yaml
        sed -i "s/$script_name/$ieee/g" /var/lib/hass/lights.yaml
      done < <(grep -v -e '^$' -e '^#' ${config.age.secrets.iotManifest.path})
    '';
  };

  fortCluster.exposedServices = [
    {
      name = "homeassistant";
      subdomain = "house";
      visibility = "local";
      port = 8123;
    }
  ];
}
