rec {
  hostName = "minos";
  device = "bc186c00-30ac-11ef-8d7b-488ccae81000";

  roles = [ ];

  apps = [
    {
      name = "homeassistant";
      mqttPasswordFile = ./mosquitto-homeassistant-password.sops;
      mqttPasswordSecretName = "mosquitto-homeassistant-password";
      declarative.automations = ./automations.nix;
      declarative.lights = ./lights.nix;
      declarative.scenes = ./scenes.nix;
      declarative.scripts = ./scripts.nix;
      declarative.helpers = ./helpers.nix;
      declarative.dashboards = ./dashboards.nix;
    }
    {
      name = "frigate";
      mqttPasswordFile = ./mosquitto-frigate-password.sops;
      mqttPasswordSecretName = "mosquitto-frigate-password";
      envFile = ./frigate-env.sops;
      envSecretName = "frigate-env";
    }
  ];

  aspects = [
    "mesh"
    {
      name = "zigbee2mqtt";
      passwordFile = ./mosquitto-zigbee2mqtt-password.sops;
      mqttSecretName = "mosquitto-zigbee2mqtt-password";
      iot.manifest = ./iot.manifest.sops;
      # Living-room dimmer: family-hub on ratched subscribes to this topic and
      # has no other way to learn the current state, so it must be retained.
      retainDevices = [ "0xacebe6fffee80f60" ];
    }
    {
      name = "zwave-js-ui";
      passwordFile = ./mosquitto-zwave-js-ui-password.sops;
      mqttSecretName = "mosquitto-zwave-js-ui-password";
      securityKeysFile = ./zwave-security-keys.json.sops;
      iot.manifest = ./iot.manifest.sops;
    }
    {
      name = "mosquitto";
      # Opened to the fort mesh (VPN-prefix-scoped firewall rule, not the LAN)
      # so family-hub on ratched can drive lights via zigbee2mqtt directly.
      mesh = true;
      users = [
        { name = "zigbee2mqtt"; secret = "mosquitto-zigbee2mqtt-password"; }
        # Least privilege: the wall-tablet hub may read the bridge device list
        # and drive its one dimmer. It cannot touch locks, sensors, or the
        # bridge's request topics, so a compromised tablet-facing service
        # cannot rekey the Zigbee network.
        {
          name = "family-hub";
          secret = "mosquitto-family-hub-password";
          # Declared here rather than by a consuming module: unlike the other
          # broker users, family-hub's client lives on another host.
          passwordFile = ./mosquitto-family-hub-password.sops;
          acl = [
            "read zigbee2mqtt/bridge/devices"
            "read zigbee2mqtt/0xacebe6fffee80f60"
            "read zigbee2mqtt/0xacebe6fffee80f60/availability"
            "write zigbee2mqtt/0xacebe6fffee80f60/set"
          ];
        }
        { name = "zwave"; secret = "mosquitto-zwave-js-ui-password"; }
        { name = "hass"; secret = "mosquitto-homeassistant-password"; }
        { name = "frigate"; secret = "mosquitto-frigate-password"; }
      ];
    }
    "observable"
    "gitops"
  ];

  module =
    { config, pkgs, ... }:
    {
      config.environment.systemPackages = [
        pkgs.ffmpeg
      ];

      config.fort.host = { inherit roles apps aspects; };
    };
}
