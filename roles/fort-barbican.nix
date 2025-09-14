{ config, pkgs, fort, ... }:

# Shout out to https://lukadeka.com/blog/setting-up-netbird-with-zitadel-on-nixos/

{
  services.postgresql = {
    enable = true;
    authentication = pkgs.lib.mkOverride 10 ''
      local all      all     trust
    '';
  };

  age.secrets.zitadel-master-key = {
    file = ../secrets/zitadel-master-key.age;
    owner = "zitadel";
    group = "zitadel";
  };

  systemd.services.zitadel.serviceConfig.Environment = [
    "ZITADEL_MACHINE_IDENTIFICATION_HOSTNAME_ENABLED=true"
    "ZITADEL_LOG_LEVEL=debug"
  ];
  services.zitadel = {
    enable = true;

    masterKeyFile = config.age.secrets.zitadel-master-key.path;

    tlsMode = "external";
    settings = {
      Port = 39995;
      ExternalPort = 443;
      ExternalDomain = "auth.${fort.settings.domain}";
      Database = {
        Clean = true;
        postgres = {
          Host = "/var/run/postgresql";
          Port = 5432;
          Database = "zitadel";
          MaxOpenConns = 15;
          MaxIdleConns = 10;
          MaxConnLifetime = "1h";
          MaxConnIdleTime = "5m";
          User.Username = "zitadel";
          Admin.Username = "postgres";
        };
      };
    };
    steps = {
      FirstInstance = {
        InstanceName = "Zitadel";
        Org.Human = {
          UserName = "admin";
          FirstName = "Admin";
          LastName = "Account";
          DisplayName = "Admin";
          Password = "ChangeMe123!";
          PasswordChangeRequired = true;
          Email = {
            Address = "admin@${fort.settings.domain}";
            Verified = true;
          };
        };
      };
    };
  };

  networking.firewall.allowedTCPPorts = [ 80 443 ];

  services.nginx.enable = true;
  services.nginx.virtualHosts."auth.${fort.settings.domain}" = {
    forceSSL = true;
    enableACME = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:39995";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
      '';
    };
  };

  security.acme = {
    acceptTerms = true;
    defaults.email = "admin@${fort.settings.domain}";
  };
}
