{
  modulesPath,
  fortConfig,
  lib,
  pkgs,
  config,
  ...
} @ args:
{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    (modulesPath + "/profiles/qemu-guest.nix")
    ./disk-config.nix
  ];
  boot.loader.grub = {
    # no need to set devices, disko will add all devices that have a EF02 partition to the list already
    # devices = [ ];
    efiSupport = true;
    efiInstallAsRemovable = true;
  };
  services.openssh.enable = true;

  environment.systemPackages = map lib.lowPrio [
    pkgs.curl
    pkgs.gitMinimal
  ];

  users.users.root.openssh.authorizedKeys.keys = [ fortConfig.fort.pubkey ];

  age.secrets.nm-secrets = {
    file = ../../secrets/wifi.env.age;
    owner = "root";
    group = "root";
  };

  networking.networkmanager.enable = true;
  networking.networkmanager.ensureProfiles = {
    environmentFiles = [
      config.age.secrets.nm-secrets.path
    ];

    profiles = {
      Primary = {
        connection = {
          id = "Primary";
          type = "wifi";
        };
        ipv4 = {
          method = "auto";
        };
        ipv6 = {
          addr-gen-mode = "stable-privacy";
          method = "auto";
        };
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

  system.stateVersion = "25.05";
}
