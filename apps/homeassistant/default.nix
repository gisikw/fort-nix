{ mqttPasswordFile, mqttPasswordSecretName, rootManifest, ... }:
{ config, pkgs, lib, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
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

      http = {
        server_port = 8123;
        use_x_forwarded_for = true;
        trusted_proxies = [ "127.0.0.1" ];
      };
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/hass 0750 hass hass -"
    "f /var/lib/hass/automations.yaml 0640 hass hass -"
    "f /var/lib/hass/scripts.yaml 0640 hass hass -"
    "f /var/lib/hass/scenes.yaml 0640 hass hass -"
  ];

  fortCluster.exposedServices = [
    {
      name = "homeassistant";
      subdomain = "house";
      visibility = "local";
      port = 8123;
    }
  ];
}
