{ subdomain ? null, hostManifest, rootManifest, cluster, ... }:
{
  config,
  pkgs,
  lib,
  ...
}:
let
  domain = rootManifest.fortConfig.settings.domain;
  hostDirs = builtins.attrNames (builtins.readDir cluster.hostsDir);
  hostManifests = map (name: import (cluster.hostsDir + "/" + name + "/manifest.nix")) hostDirs;
  observableHosts = builtins.filter (m: builtins.elem "observable" m.aspects) hostManifests;
  observableTargets = map (m: "${m.hostName}.fort.${domain}:9100") observableHosts;
in
{
  systemd.tmpfiles.rules = [
    "d /var/lib/prometheus 0755 prometheus prometheus -"
  ];

  services.prometheus = {
    enable = true;
    scrapeConfigs = [
      {
        job_name = "node";
        static_configs = [
          { targets = observableTargets; }
        ];
      }
    ];
  };

  age.secrets.grafana-admin-pass = {
    file = ./grafana-admin-pass.age;
    owner = "grafana";
    group = "grafana";
    mode = "0400";
  };

  services.grafana = {
    enable = true;
    settings = {
      server = {
        http_port = 3000;
        http_addr = "0.0.0.0";
      };
      security = {
        admin_user = "admin";
        admin_password = "$__file{${config.age.secrets.grafana-admin-pass.path}}";
      };
      "auth.proxy" = {
        enabled = true;
        header_name = "X-Forwarded-User";
      };
    };

    provision = {
      enable = true;

      datasources.settings.datasources = [
        {
          name = "Prometheus";
          type = "prometheus";
          url = "http://localhost:9090";
          access = "proxy";
          isDefault = true;
        }
      ];

      dashboards.settings.providers = [
        {
          name = "Fort Health Status";
          options.path = pkgs.runCommand "grafana-node-dashboard" { } ''
            mkdir -p $out
            cp ${
              pkgs.fetchurl {
                url = "https://grafana.com/api/dashboards/1860/revisions/32/download";
                sha256 = "sha256-I/YQPGg6mgTb1IFH68cfXMV2B77991JZmI0yffNlY2o=";
              }
            } $out/node_exporter_full.json
          '';
        }
      ];
    };
  };

  networking.firewall.allowedTCPPorts = [
    9090
    9100
  ];

  fort.cluster.services = [
    {
      name = "monitor";
      subdomain = subdomain;
      port = 3000;
      sso.mode = "headers";
    }
  ];
}
