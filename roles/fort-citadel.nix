{ config, fort, ... }:

{
  services.openssh.settings = {
    PermitRootLogin = "no";
    PasswordAuthentication = false;
  };

  users.extraUsers.fort = {
    isNormalUser = true;
    home = "/home/fort";
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHOfSazjaPhDc9+aBUtYNo9F+w9kNil7K8XzjHxCjsR5 fort-access"
    ];
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
