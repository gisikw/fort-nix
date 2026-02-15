{ subdomain ? "frigate", mqttPasswordFile, mqttPasswordSecretName, envFile, envSecretName, rootManifest, ... }:
{ config, pkgs, lib, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  hostname = "${subdomain}.${domain}";
in
{
  age.secrets.${mqttPasswordSecretName} = {
    file = mqttPasswordFile;
    owner = "root";
    mode = "0400";
    group = "mosquitto";
  };

  age.secrets.${envSecretName} = {
    file = envFile;
    owner = "frigate";
    mode = "0400";
  };

  services.frigate = {
    enable = true;
    hostname = hostname;

    # Config validation fails in sandbox due to env var placeholders
    checkConfig = false;

    settings = {
      mqtt = {
        enabled = true;
        host = "127.0.0.1";
        port = 1883;
        user = "frigate";
        password = "{FRIGATE_MQTT_PASSWORD}";
      };

      go2rtc.streams = {
        upstairs_bedroom = [
          "rtsp://{FRIGATE_RTSP_USER}:{FRIGATE_RTSP_PASSWORD}@{FRIGATE_CAMERA_UPSTAIRS_BEDROOM_HOST}:554/stream1"
        ];
        upstairs_bedroom_low = [
          "rtsp://{FRIGATE_RTSP_USER}:{FRIGATE_RTSP_PASSWORD}@{FRIGATE_CAMERA_UPSTAIRS_BEDROOM_HOST}:554/stream2"
        ];
      };

      cameras.upstairs_bedroom = {
        enabled = true;
        ffmpeg.inputs = [
          {
            path = "rtsp://127.0.0.1:8554/upstairs_bedroom";
            roles = [ "record" ];
          }
          {
            path = "rtsp://127.0.0.1:8554/upstairs_bedroom_low";
            roles = [ "detect" ];
          }
        ];
        detect = {
          enabled = true;
          width = 640;
          height = 480;
          fps = 5;
        };
      };

      objects.track = [ "person" "car" "dog" "cat" ];

      record = {
        enabled = true;
        retain = {
          days = 3;
          mode = "motion";
        };
        events.retain = {
          default = 14;
          mode = "active_objects";
        };
      };

      snapshots = {
        enabled = true;
        retain.default = 14;
      };
    };
  };

  # Inject credentials via environment file
  systemd.services.frigate.serviceConfig.EnvironmentFile =
    config.age.secrets.${envSecretName}.path;

  # SSL for frigate's nginx vhost (managed by frigate module, not fort.cluster.services)
  services.nginx.virtualHosts.${hostname} = {
    forceSSL = true;
    sslCertificate = "/var/lib/fort/ssl/${domain}/fullchain.pem";
    sslCertificateKey = "/var/lib/fort/ssl/${domain}/key.pem";
  };
}
