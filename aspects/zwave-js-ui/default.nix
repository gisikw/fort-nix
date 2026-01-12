{ passwordFile, mqttSecretName, securityKeysFile, iot, ... }:
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

  age.secrets.zwave-iot-manifest = {
    file = iot.manifest;
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

      # Generate settings.json with MQTT password and security keys
      MQTT_PASSWORD=$(cat ${config.age.secrets.${mqttSecretName}.path})
      ${pkgs.gnused}/bin/sed "s/__MQTT_PASSWORD__/$MQTT_PASSWORD/" ${settingsFile} \
        | ${pkgs.jq}/bin/jq -s '.[0] * .[1]' - ${config.age.secrets.zwave-security-keys.path} \
        > /var/lib/zwave-js-ui/settings.json
      chmod 644 /var/lib/zwave-js-ui/settings.json

      # Generate nodes.json from iot manifest (DSK -> friendly name mapping)
      JSONL=""
      for f in /var/lib/zwave-js-ui/[a-f0-9]*.jsonl; do
        if [ -f "$f" ]; then
          JSONL="$f"
          break
        fi
      done
      if [ -n "$JSONL" ]; then
        HOME_ID="0x$(basename "$JSONL" .jsonl)"

        # Build DSK -> nodeID mapping from jsonl
        declare -A dsk_to_node
        while IFS= read -r line; do
          key=$(echo "$line" | ${pkgs.jq}/bin/jq -r '.k // empty')
          if [[ "$key" =~ ^node\.([0-9]+)\.dsk$ ]]; then
            node_id="''${BASH_REMATCH[1]}"
            dsk=$(echo "$line" | ${pkgs.jq}/bin/jq -r '.v')
            dsk_to_node["$dsk"]="$node_id"
          fi
        done < "$JSONL"

        # Build nodes.json from manifest
        NODES_JSON="{\"$HOME_ID\":{}}"
        while IFS=: read -r dsk script_name friendly_name; do
          [ -z "$dsk" ] && continue
          [[ "$dsk" =~ ^# ]] && continue
          node_id="''${dsk_to_node[$dsk]:-}"
          if [ -n "$node_id" ]; then
            NODES_JSON=$(echo "$NODES_JSON" | ${pkgs.jq}/bin/jq --arg hid "$HOME_ID" --arg nid "$node_id" --arg name "$friendly_name" '.[$hid][$nid] = {"name": $name}')
          fi
        done < ${config.age.secrets.zwave-iot-manifest.path}

        echo "$NODES_JSON" > /var/lib/zwave-js-ui/nodes.json
        chmod 644 /var/lib/zwave-js-ui/nodes.json
      fi
    '';
  };

  systemd.services.zwave-js-ui.restartTriggers = [
    config.age.secrets.${mqttSecretName}.file
    config.age.secrets.zwave-iot-manifest.file
  ];

  fortCluster.exposedServices = [
    {
      name = "zwave";
      port = 8091;
    }
  ];
}
