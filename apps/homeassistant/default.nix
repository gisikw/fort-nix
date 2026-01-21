{ subdomain ? "house", mqttPasswordFile, mqttPasswordSecretName, rootManifest, declarative, ... }:
{ config, pkgs, lib, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  yamlFormat = pkgs.formats.yaml { };
  automationsFile = yamlFormat.generate "hass-automations.yaml" (import declarative.automations);
  lightsFile = yamlFormat.generate "hass-lights.yaml" (import declarative.lights);
  scenesFile = yamlFormat.generate "hass-scenes.yaml" (import declarative.scenes);
  scriptsFile = yamlFormat.generate "hass-scripts.yaml" (import declarative.scripts);
  helpers = if declarative ? helpers then import declarative.helpers else {};

  # Dashboard support - each dashboard is { title, icon, config }
  dashboards = if declarative ? dashboards then import declarative.dashboards else {};
  dashboardFiles = lib.mapAttrs (name: dash:
    yamlFormat.generate "hass-dashboard-${name}.yaml" dash.config
  ) dashboards;
  # HA requires dashboard URL paths to contain a hyphen
  lovelaceDashboards = lib.listToAttrs (lib.mapAttrsToList (name: dash: {
    name = "${name}-panel";  # URL path must contain hyphen
    value = {
      mode = "yaml";
      title = dash.title;
      icon = dash.icon;
      show_in_sidebar = true;
      filename = "dashboards/${name}.yaml";  # File uses original name
    };
  }) dashboards);

  # Go handler for notify capability
  notifyProvider = import ./provider { inherit pkgs; };
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

  # Create dashboards directory with correct ownership
  systemd.tmpfiles.rules = lib.mkIf (dashboards != {}) [
    "d /var/lib/hass/dashboards 0755 hass hass -"
  ];

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

      # Lovelace dashboard configuration
      lovelace = lib.mkIf (dashboards != {}) {
        mode = "storage";  # Keep default dashboard UI-editable
        dashboards = lovelaceDashboards;
      };
    } // helpers;
  };

  systemd.services.home-assistant.restartTriggers = [
    automationsFile
    lightsFile
    scenesFile
    scriptsFile
  ] ++ (lib.attrValues dashboardFiles);

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
    ] ++ (lib.attrValues dashboardFiles);
    script = ''
      rm -f /var/lib/hass/automations.yaml
      rm -f /var/lib/hass/lights.yaml
      rm -f /var/lib/hass/scenes.yaml
      rm -f /var/lib/hass/scripts.yaml
      cp ${automationsFile} /var/lib/hass/automations.yaml
      cp ${lightsFile} /var/lib/hass/lights.yaml
      cp ${scenesFile} /var/lib/hass/scenes.yaml
      cp ${scriptsFile} /var/lib/hass/scripts.yaml

      # Copy dashboard files
      # - rm -f: remove existing (may be read-only from prior nix store cp)
      # - install -m 644: copy with writable permissions for future updates
      mkdir -p /var/lib/hass/dashboards
      rm -f /var/lib/hass/dashboards/*.yaml
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: file: ''
        install -m 644 ${file} /var/lib/hass/dashboards/${name}.yaml
      '') dashboardFiles)}

      while IFS=: read ieee script_name friendly_name; do
        [ -z "$ieee" ] && continue
        sed -i "s/$script_name/$ieee/g" /var/lib/hass/automations.yaml
        sed -i "s/$script_name/$ieee/g" /var/lib/hass/scripts.yaml
        sed -i "s/$script_name/$ieee/g" /var/lib/hass/scenes.yaml
        sed -i "s/$script_name/$ieee/g" /var/lib/hass/lights.yaml
        for dashboard in /var/lib/hass/dashboards/*.yaml; do
          [ -f "$dashboard" ] && sed -i "s/$script_name/$ieee/g" "$dashboard"
        done
      done < <(grep -v -e '^$' -e '^#' ${config.age.secrets.iotManifest.path})
    '';
  };

  fort.cluster.services = [
    {
      name = "homeassistant";
      subdomain = subdomain;
      visibility = "local";
      port = 8123;
    }
  ];

  # Expose notify capability for cluster-wide notifications
  fort.host.capabilities.notify = {
    handler = "${notifyProvider}/bin/notify-provider";
    mode = "rpc";
    description = "Send push notification via Home Assistant";
  };
}
