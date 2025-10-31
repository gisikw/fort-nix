{ ... }:
{ config, ... }:
{
  age.secrets.nm-secrets = {
    file = ./credentials.env.age;
    owner = "root";
    group = "root";
  };

  environment.persistence."/persist/system".directories = [
    "/etc/NetworkManager/system-connections"
  ];

  systemd.services.NetworkManager = {
    after = [ "basic.target" ];
    requires = [ "basic.target" ];
  };

  networking.networkmanager.enable = true;
  networking.networkmanager.ensureProfiles = {
    environmentFiles = [
      config.age.secrets.nm-secrets.path
    ];

    profiles = {
      Ethernet = {
        connection = {
          id = "Ethernet";
          type = "ethernet";
          autoconnect = true;
          autoconnect-priority = 10;
        };
        ipv4.method = "auto";
        ipv6.method = "auto";
      };
      Primary = {
        connection = {
          id = "Wifi";
          type = "wifi";
          autoconnect = true;
          autoconnect-priority = 1;
        };
        ipv4.method = "auto";
        ipv6.method = "auto";
        wifi = {
          mode = "infrastructure";
          ssid = "$WIFI_SSID";
        };
        wifi-security = {
          key-mgmt = "wpa-psk";
          psk = "$WIFI_PSK";
        };
      };
    };
  };
}
