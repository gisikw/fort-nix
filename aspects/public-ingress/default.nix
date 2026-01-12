{
  rootManifest,
  ...
}:
{ lib, pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;

  # Async handler for proxy configuration
  # Receives aggregate requests, generates nginx vhost config for all public services
  # Input: {"origin:proxy/servicename": {"request": {"fqdn": "..."}}, ...}
  # Output: {"origin:proxy/servicename": "OK", ...}
  proxyConfigureHandler = pkgs.writeShellScript "handler-proxy-configure" ''
    set -euo pipefail

    input=$(${pkgs.coreutils}/bin/cat)
    CONFIG_FILE="/var/lib/fort/nginx/public-services.conf"

    # Start with header
    config="# Managed by fort-proxy-configure

    map \$http_upgrade \$connection_upgrade {
      default upgrade;
      \"\" close;
    }
    "

    # Build response object
    response="{}"

    # Process each request
    for key in $(echo "$input" | ${pkgs.jq}/bin/jq -r 'keys[]'); do
      origin=$(echo "$key" | ${pkgs.coreutils}/bin/cut -d: -f1)
      fqdn=$(echo "$input" | ${pkgs.jq}/bin/jq -r --arg k "$key" '.[$k].request.fqdn')

      # Use hostname - headscale DNS resolves <origin>.fort.<domain>
      upstream="$origin.fort.${domain}"

      config+="
    server {
      listen 80;
      listen 443 ssl;
      http2 on;
      server_name $fqdn;

      ssl_certificate     /var/lib/fort/ssl/${domain}/fullchain.pem;
      ssl_certificate_key /var/lib/fort/ssl/${domain}/key.pem;

      location / {
        proxy_pass https://$upstream:443;
        proxy_set_header Host               \$host;
        proxy_set_header Cookie             \$http_cookie;
        proxy_set_header X-Forwarded-For    \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto  \$scheme;
        proxy_set_header X-Real-IP          \$remote_addr;
        proxy_http_version 1.1;
        proxy_set_header Upgrade    \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_ssl_verify on;
        proxy_ssl_server_name on;
        proxy_ssl_name \$host;
        proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
      }
    }
    "
      response=$(echo "$response" | ${pkgs.jq}/bin/jq --arg k "$key" '. + {($k): "OK"}')
    done

    # Write config and reload
    echo "$config" > "$CONFIG_FILE"
    ${pkgs.systemd}/bin/systemctl reload nginx 2>/dev/null || true

    echo "$response"
  '';
in
{
  services.nginx = {
    enable = lib.mkDefault true;
    appendHttpConfig = ''
      include /var/lib/fort/nginx/public-services.conf;
    '';
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/fort/nginx 0750 root nginx -"
    "f /var/lib/fort/nginx/public-services.conf 0640 root nginx -"
  ];

  # Expose proxy capability for nginx vhost management
  fort.host.capabilities.proxy = {
    handler = proxyConfigureHandler;
    mode = "async";  # Aggregate handler for all proxy requests
    triggers.initialize = true;  # Rebuild config on boot
    description = "Configure nginx reverse proxy for public services";
  };
}
