{ config, lib, pkgs, fort, ... }:

{
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  environment.systemPackages = with pkgs; [ just git ];

  services.openssh = {
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
    };
    knownHosts =
      lib.mapAttrs'
        (host: hostCfg:
          let
            device = fort.config.devices.${hostCfg.device};
          in {
            name = "${host}.hosts.${fort.settings.domain}";
            value = {
              publicKey = device.pubkey;
            };
          })
        fort.config.hosts;
  };

  users.groups.fort = {};
  users.extraUsers.fort = {
    isNormalUser = true;
    group = "fort";
    extraGroups = [ "wheel" ];
    home = "/home/fort";
    openssh.authorizedKeys.keys = fort.settings.royal_pubkeys;
  };

  age.secrets.fort-key = {
    file = ../secrets/fort.key.age;
    path = "/home/fort/.ssh/fort";
    mode = "0600";
    owner = "fort";
    group = "fort";
  };

  security.sudo.enable = true;
  security.sudo.wheelNeedsPassword = false;

  age.secrets.dns-provider-env = {
    file = ../secrets/dns_provider.env.age;
    owner = "root";
    group = "root";
  };

  security.acme = {
    acceptTerms = true;
    defaults.email = "admin@${fort.settings.domain}";

    certs.${fort.settings.domain} = {
      domain = fort.settings.domain;
      extraDomainNames = [ "*.${fort.settings.domain}" ];
      dnsProvider = fort.settings.dns_provider;
      environmentFile = config.age.secrets.dns-provider-env.path;
    };
  };
}
