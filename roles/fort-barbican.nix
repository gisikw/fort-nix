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

  systemd.tmpfiles.rules = [
    "f /var/lib/headscale/extra-records.json 0640 headscale headscale -"
  ];

  services.headscale = {
    enable = true;
    address = "127.0.0.1";
    port = 9080;
    settings = {
      server_url = "https://ts.${fort.settings.domain}";
      listen_addr = "127.0.0.1:9080";
      metrics_listen_addr = "127.0.0.1:9090";
      grpc_listen_addr = "127.0.0.1:50443";
      grpc_allow_insecure = true;

      noise.private_key_path = "/var/lib/headscale/noise_private.key";

      prefixes = {
        v4 = "100.101.0.0/16";
        v6 = "fd7a:115c:a1e0:8249::/64";
        allocation = "sequential";
      };

      dns = {
        magic_dns = true;
        base_domain = "tail.${fort.settings.domain}";
        override_local_dns = true;
        extra_records_path = "/var/lib/headscale/extra-records.json";
        nameservers.global = [
          "1.1.1.1"
          "1.0.0.1"
        ];
        search_domains = [];
      };

      database = {
        type = "sqlite";
        sqlite = {
          path = "/var/lib/headscale/db.sqlite";
          write_ahead_log = true;
        };
      };

      log = {
        level = "info";
        format = "text";
      };
      derp.server.enabled = false;
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
  services.nginx.virtualHosts."ts.${fort.settings.domain}" = {
    forceSSL = true;
    enableACME = true;
    http2 = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:9080";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
      '';
    };
    locations."/headscale.v1.HeadscaleService/" = {
      extraConfig = ''
        grpc_pass grpc://127.0.0.1:50443;
        grpc_set_header Host $host;
        grpc_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      '';
    };
  };

  security.acme = {
    acceptTerms = true;
    defaults.email = "admin@${fort.settings.domain}";
  };
}
