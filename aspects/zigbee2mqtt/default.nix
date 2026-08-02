{
  passwordFile,
  mqttSecretName,
  iot,
  deviceProfileManifest,
  # IEEE addresses whose state topic should be retained by the broker.
  retainDevices ? [ ],
  ...
}:
{ config, lib, pkgs, ... }:
if (deviceProfileManifest.platform or "nixos") != "nixos" then
  throw "fort-nix: aspect 'zigbee2mqtt' is Linux-only (services.zigbee2mqtt, systemd, dialout serial group); remove it from this darwin host's manifest"
else
{
  sops.secrets.${mqttSecretName} = {
    sopsFile = passwordFile;
    format = "binary";
    owner = "zigbee2mqtt";
    mode = "0440";
    group = "mosquitto";
  };

  sops.secrets.iotManifest = {
    sopsFile = iot.manifest;
    format = "binary";
    owner = "zigbee2mqtt";
    mode = "0440";
    group = "hass";
  };

  users.users.zigbee2mqtt.extraGroups = [ "dialout" ];

  systemd.services.zigbee2mqtt = {
    serviceConfig.LoadCredential =
      "mqtt-password:${config.sops.secrets.${mqttSecretName}.path}";
    restartTriggers = [
      config.sops.secrets.${mqttSecretName}.sopsFile
      config.sops.secrets.iotManifest.sopsFile
    ];
  };

  services.zigbee2mqtt = {
    enable = true;
    package = pkgs.writeShellScriptBin "zigbee2mqtt" ''
      while IFS=: read ieee script_name friendly_name; do
        ${pkgs.yq-go}/bin/yq -i ".$ieee.friendly_name = \"$friendly_name\"" /var/lib/zigbee2mqtt/devices.yaml
      done < <(grep -e '^0x' ${config.sops.secrets.iotManifest.path})

      # Retain state topics for devices whose current value a subscriber needs
      # on connect. z2m does NOT retain device state topics by default, so a
      # client that connects between device publishes sees nothing and has no
      # way to learn the current state — for the wall tablet that means a dead
      # light widget after every restart until someone touches the switch.
      # These are per-device options in devices.yaml, same file as the
      # friendly_name pass above. yq creates the entry if absent.
${lib.concatMapStrings (ieee: ''
      ${pkgs.yq-go}/bin/yq -i '.["${ieee}"].retain = true' /var/lib/zigbee2mqtt/devices.yaml
'') retainDevices}

      # Sync external converters from the store. z2m >= 2.0 auto-loads every
      # .js in this directory; the `external_converters` setting no longer
      # exists. Wiped and recopied each start so the repo is the source of
      # truth and removed converters actually disappear.
      rm -rf /var/lib/zigbee2mqtt/external_converters
      install -d -m 0755 /var/lib/zigbee2mqtt/external_converters
      install -m 0644 ${./external-converters}/*.js /var/lib/zigbee2mqtt/external_converters/

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

      permit_join = false;

      frontend = {
        port = 8080;
        host = "127.0.0.1";
      };
    };
  };

  fort.cluster.services = [
    {
      name = "zigbee";
      port = 8080;
      visibility = "local";
    }
  ];
}
