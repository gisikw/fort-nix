{ subdomain ? "frigate", mqttPasswordFile, mqttPasswordSecretName, envFile, envSecretName, rootManifest, ... }:
{ config, pkgs, lib, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
  hostname = "${subdomain}.${domain}";
in
{
  sops.secrets.${mqttPasswordSecretName} = {
    sopsFile = mqttPasswordFile;
    format = "binary";
    owner = "root";
    mode = "0400";
    group = "mosquitto";
  };

  sops.secrets.${envSecretName} = {
    sopsFile = envFile;
    format = "binary";
    owner = "frigate";
    mode = "0400";
  };

  services.frigate = {
    enable = true;
    hostname = hostname;

    # Config validation fails in sandbox due to env var placeholders
    checkConfig = false;

    settings = {
      auth.enabled = false;

      mqtt = {
        enabled = true;
        host = "127.0.0.1";
        port = 1883;
        user = "frigate";
        password = "{FRIGATE_MQTT_PASSWORD}";
      };

      cameras.upstairs_bedroom = {
        enabled = true;
        ffmpeg.inputs = [
          {
            path = "rtsp://{FRIGATE_RTSP_USER}:{FRIGATE_RTSP_PASSWORD}@{FRIGATE_CAMERA_UPSTAIRS_BEDROOM_HOST}:554/stream1";
            roles = [ "record" ];
          }
          {
            path = "rtsp://{FRIGATE_RTSP_USER}:{FRIGATE_RTSP_PASSWORD}@{FRIGATE_CAMERA_UPSTAIRS_BEDROOM_HOST}:554/stream2";
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
    config.sops.secrets.${envSecretName}.path;

  # Register with fort for DNS and SSL cert.
  # Fort creates a catch-all location "/" with proxy_pass, but Frigate's NixOS
  # module needs its own location "/" (static frontend served from package).
  # We override fort's location to remove the proxy_pass and let Frigate's
  # nginx config handle all routing.
  fort.cluster.services = [
    {
      name = "frigate";
      subdomain = subdomain;
      port = 5001;
      visibility = "vpn";
    }
  ];

  # Fort adds a server-level CSP (frame-ancestors) add_header to every vhost.
  # The upstream Frigate module generates location blocks with their own
  # add_header lines (Set-Cookie, Cache-Control, ...), and nginx semantics
  # make any child-level add_header drop ALL parent headers — gixy's
  # add_header_redefinition check rightly fails the config build. Frigate is
  # LAN/VPN-only, never public, and never embedded in an iframe (family-hub
  # consumes streams via server-side proxy), so drop the server-level CSP
  # here instead of fighting the upstream module's locations.
  services.nginx.virtualHosts.${hostname} = {
    extraConfig = lib.mkForce "";
    locations."/" = lib.mkForce {
      root = "${config.services.frigate.package.web}";
      tryFiles = "$uri $uri.html $uri/ /index.html";
      extraConfig = ''
        add_header Cache-Control "no-store";
        expires off;
      '';
    };
  };
}
