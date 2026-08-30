# Darwin service exposure (fort.cluster.services on nix-darwin hosts)
#
# The darwin counterpart of fort.nix + fort/{services,nginx,auth,ssl}.nix,
# scoped to what a darwin host actually needs to participate in the cluster's
# service mesh. When a darwin host declares fort.cluster.services:
#
#   - nginx (launchd, root) takes over port 443: one TLS vhost per service
#     (identity/none SSO modes), plus the control-plane vhost that proxies
#     /fort/ to fort-provider on 127.0.0.1:8444 (see control-plane.nix — the
#     provider vacates 443 when services are declared).
#   - identity-proxy runs under launchd for sso.mode = "identity" services,
#     with TAILSCALED_SOCKET pointed at darwin's tailscaled path so VPN
#     clients keep transparent whois auth.
#   - The same discovery needs a NixOS host would auto-generate are declared:
#     proxy (beacon ingress) for public services, dns-headscale (VPN DNS) for
#     all services, ssl-cert (cluster cert) and oidc-register for identity.
#
# Deliberately NOT ported (v1 seams, see git history for context):
#   - dns-coredns needs: the coredns provider resolves the origin's LAN IP
#     via the `lan-ip` capability, which only the NixOS mesh aspect exposes.
#     LAN clients fall back to public DNS (wildcard -> beacon) and hairpin.
#   - SSO modes other than none/identity (oauth2-proxy, njs token validation).
#     An assertion rejects them rather than half-working.
#   - staticRoot / inEgressNamespace services.
#
# App modules can add http-level nginx config (e.g. an internal backend
# server) via fort.darwin.nginxExtraHttpConfig.
{ rootManifest, cluster, ... }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  domain = rootManifest.fortConfig.settings.domain;
  vpnIpv4Prefix = rootManifest.fortConfig.settings.vpn.ipv4Prefix;
  lanIpv4Prefix = rootManifest.fortConfig.settings.lan.ipv4Prefix;
  hostName = config.networking.hostName;

  inherit (import ./service-lib.nix) subdomainOf;

  services = config.fort.cluster.services;
  hasServices = services != [ ];

  # Same beacon/forge discovery as fort/services.nix
  hostFiles = builtins.readDir cluster.hostsDir;
  allHosts = builtins.mapAttrs (name: _: import (cluster.hostsDir + "/" + name + "/manifest.nix")) hostFiles;
  beacons = builtins.filter (h: builtins.elem "beacon" h.roles) (builtins.attrValues allHosts);
  beaconHost = if beacons != [ ] then (builtins.head beacons).hostName else null;

  publicServices = builtins.filter (svc: svc.visibility == "public") services;
  identityServices = builtins.filter (svc: svc.sso.mode == "identity") services;
  hasIdentityServices = identityServices != [ ];
  unsupportedServices = builtins.filter (svc: !(builtins.elem svc.sso.mode [ "none" "identity" ]) || svc.staticRoot != null || svc.inEgressNamespace) services;

  identity-proxy = import ../../pkgs/identity-proxy { inherit pkgs; };
  fort-certcheck = import ../../pkgs/fort-certcheck { inherit pkgs; };

  sslDir = "/var/lib/fort/ssl/${domain}";
  nginxStateDir = "/var/lib/fort-nginx";
  identitySocket = "/var/run/identity-proxy/identity-proxy.sock";

  nginxLabel = "network.gisi.fort.nginx";
  identityLabel = "network.gisi.fort.identity-proxy";

  # Per-service TLS vhost. Mirrors the shape fort/nginx.nix generates on
  # NixOS (identity mode auth_request plumbing kept byte-compatible with the
  # identity-proxy contract), with recommendedProxySettings inlined since
  # there is no NixOS nginx module here.
  serviceVhost = svc:
    let
      subdomain = subdomainOf svc;
      isIdentity = svc.sso.mode == "identity";
    in ''
    server {
      listen 443 ssl;
      http2 on;
      server_name ${subdomain}.${domain};

      ssl_certificate ${sslDir}/fullchain.pem;
      ssl_certificate_key ${sslDir}/key.pem;

      add_header Content-Security-Policy "frame-ancestors 'self' https://*.${domain}" always;
      add_header X-Fort-Host ${hostName} always;

      location / {
        ${lib.optionalString (svc.visibility == "vpn") ''
        if ($is_vpn = 0) {
          return 444;
        }
        ''}
        ${lib.optionalString (svc.maxBodySize != null) "client_max_body_size ${svc.maxBodySize};"}
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header Cookie $http_cookie;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        ${lib.optionalString isIdentity ''
        auth_request /_identity/validate;
        auth_request_set $identity_user $upstream_http_x_identity_user;
        auth_request_set $identity_email $upstream_http_x_identity_email;
        auth_request_set $identity_groups $upstream_http_x_identity_groups;
        proxy_set_header X-Forwarded-User $identity_user;
        proxy_set_header X-Forwarded-Email $identity_email;
        proxy_set_header X-Forwarded-Groups $identity_groups;
        error_page 401 = @identity_login;
        ''}
        proxy_pass http://127.0.0.1:${toString svc.port};
      }

      ${lib.optionalString isIdentity ''
      location = /_identity/validate {
        internal;
        proxy_pass http://unix:${identitySocket};
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_set_header X-Original-URI $request_uri;
        proxy_set_header X-Original-Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Identity-Required-Groups "${lib.concatStringsSep "," svc.sso.groups}";
      }

      location @identity_login {
        return 302 https://$host/_identity/login?rd=$scheme://$host$request_uri;
      }

      location /_identity/ {
        proxy_pass http://unix:${identitySocket};
        proxy_set_header Host $host;
        proxy_set_header X-Original-Host $host;
        proxy_set_header X-Real-IP $remote_addr;
      }
      ''}
    }
  '';

  nginxConf = pkgs.writeText "fort-nginx.conf" ''
    # Managed by fort darwin-services (common/fort/darwin-services.nix)
    # Workers run as nobody:nobody — the identity-proxy socket is root:nobody
    # 0660 to match, and the apple-dist data dir is world-readable.
    user nobody nobody;
    worker_processes 2;
    pid ${nginxStateDir}/nginx.pid;
    error_log /var/log/fort-nginx.log warn;

    events {
      worker_connections 1024;
    }

    http {
      include ${pkgs.nginx}/conf/mime.types;
      default_type application/octet-stream;
      access_log ${nginxStateDir}/access.log;

      client_body_temp_path ${nginxStateDir}/client-body;
      proxy_temp_path ${nginxStateDir}/proxy;
      fastcgi_temp_path ${nginxStateDir}/fastcgi;
      uwsgi_temp_path ${nginxStateDir}/uwsgi;
      scgi_temp_path ${nginxStateDir}/scgi;

      sendfile on;

      # Trust X-Real-IP from mesh peers (beacon proxy), mirroring fort/nginx.nix
      set_real_ip_from ${vpnIpv4Prefix};
      real_ip_header X-Real-IP;
      real_ip_recursive on;

      # SSE/long-poll parity with the NixOS hosts
      proxy_buffering off;
      proxy_read_timeout 600s;
      proxy_send_timeout 600s;

      geo $is_vpn {
        default 0;
        ${vpnIpv4Prefix} 1;
      }

      geo $is_local {
        default 0;
        ${lanIpv4Prefix} 1;
        127.0.0.0/8 1;
      }

      # Control-plane access: mesh peers + loopback
      geo $fort_allowed {
        default 0;
        ${vpnIpv4Prefix} 1;
        127.0.0.0/8 1;
      }

      map $http_upgrade $connection_upgrade {
        default upgrade;
        "" close;
      }

      ${config.fort.darwin.nginxExtraHttpConfig}

      # Control-plane vhost: preserves the fort CLI contract
      # (https://<host>.fort.<domain>/fort/...) now that the provider is on
      # loopback. Self-signed cert is fine — the CLI uses curl -sk.
      server {
        listen 443 ssl default_server;
        http2 on;
        server_name ${hostName}.fort.${domain};

        ssl_certificate /var/lib/fort/tls/cert.pem;
        ssl_certificate_key /var/lib/fort/tls/key.pem;

        location /fort/ {
          if ($fort_allowed = 0) {
            return 444;
          }
          proxy_pass https://127.0.0.1:8444;
          proxy_ssl_verify off;
          proxy_http_version 1.1;
          proxy_set_header Host $host;
          proxy_set_header X-Fort-Origin $http_x_fort_origin;
          proxy_set_header X-Fort-Timestamp $http_x_fort_timestamp;
          proxy_set_header X-Fort-Signature $http_x_fort_signature;
        }

        location / {
          return 404;
        }
      }

      ${lib.concatStringsSep "\n" (map serviceVhost services)}
    }
  '';

  # identity-proxy wrapper: /var/run is wiped at boot on macOS, so the socket
  # dir must be re-created at daemon start, and first-boot state (cookie key,
  # OIDC placeholder creds) mirrors the NixOS ExecStartPre in fort/auth.nix.
  identityProxyWrapper = pkgs.writeShellScript "identity-proxy-darwin" ''
    set -euo pipefail
    mkdir -p /var/run/identity-proxy
    # BSD semantics: files inherit the parent directory's group. The socket
    # must come up root:nobody so nginx workers (nobody) can connect — group
    # the dir accordingly (the daemon's 0660 chmod does the rest).
    chown root:nobody /var/run/identity-proxy
    chmod 750 /var/run/identity-proxy
    mkdir -p /var/lib/identity-proxy /var/lib/fort-auth/identity-proxy
    if [ ! -s /var/lib/identity-proxy/cookie-key ]; then
      head -c32 /dev/urandom | base64 > /var/lib/identity-proxy/cookie-key
      chmod 600 /var/lib/identity-proxy/cookie-key
    fi
    if [ ! -s /var/lib/fort-auth/identity-proxy/client-id ]; then
      echo "identity-proxy-pending" > /var/lib/fort-auth/identity-proxy/client-id
    fi
    if [ ! -s /var/lib/fort-auth/identity-proxy/client-secret ]; then
      echo "pending" > /var/lib/fort-auth/identity-proxy/client-secret
    fi
    exec ${identity-proxy}/bin/identity-proxy
  '';

  # OIDC credential handler — darwin variant of mkOidcHandler in fort/auth.nix
  # (launchctl kickstart instead of systemctl restart).
  identityOidcHandler = pkgs.writeShellScript "oidc-handler-identity-proxy-darwin" ''
    set -euo pipefail

    AUTH_DIR="/var/lib/fort-auth/identity-proxy"
    payload=$(${pkgs.coreutils}/bin/cat)
    ${pkgs.coreutils}/bin/mkdir -p "$AUTH_DIR"

    new_client_id=$(echo "$payload" | ${pkgs.jq}/bin/jq -r '.client_id')
    new_client_secret=$(echo "$payload" | ${pkgs.jq}/bin/jq -r '.client_secret')

    old_client_id=""
    old_client_secret=""
    [ -f "$AUTH_DIR/client-id" ] && old_client_id=$(${pkgs.coreutils}/bin/cat "$AUTH_DIR/client-id")
    [ -f "$AUTH_DIR/client-secret" ] && old_client_secret=$(${pkgs.coreutils}/bin/cat "$AUTH_DIR/client-secret")

    if [ "$new_client_id" = "$old_client_id" ] && [ "$new_client_secret" = "$old_client_secret" ]; then
      exit 0
    fi

    ${pkgs.coreutils}/bin/printf '%s' "$new_client_id" > "$AUTH_DIR/client-id"
    ${pkgs.coreutils}/bin/printf '%s' "$new_client_secret" > "$AUTH_DIR/client-secret"
    ${pkgs.coreutils}/bin/chmod 644 "$AUTH_DIR/client-id"
    ${pkgs.coreutils}/bin/chmod 600 "$AUTH_DIR/client-secret"

    /bin/launchctl kickstart -k system/${identityLabel} || true
  '';

  # SSL cert consumer — darwin variant of the handler in fort/ssl.nix. Same
  # resilience rules (validate, refuse downgrades, atomic install), nginx
  # restart via launchctl instead of systemctl reload.
  sslCertHandler = pkgs.writeShellScript "ssl-cert-handler-darwin" ''
    set -euo pipefail

    ssl_dir="${sslDir}"
    payload=$(${pkgs.coreutils}/bin/cat)

    if ! echo "$payload" | ${pkgs.jq}/bin/jq -e '.cert and .key and .chain' >/dev/null 2>&1; then
      echo "ssl-cert handler: payload missing cert/key/chain, refusing" >&2
      exit 1
    fi

    mkdir -p "$ssl_dir"
    workdir=$(${pkgs.coreutils}/bin/mktemp -d "$ssl_dir/.incoming.XXXXXX")
    trap 'rm -rf "$workdir"' EXIT

    echo "$payload" | ${pkgs.jq}/bin/jq -r '.cert' | ${pkgs.coreutils}/bin/base64 -d > "$workdir/fullchain.pem"
    echo "$payload" | ${pkgs.jq}/bin/jq -r '.key' | ${pkgs.coreutils}/bin/base64 -d > "$workdir/key.pem"
    echo "$payload" | ${pkgs.jq}/bin/jq -r '.chain' | ${pkgs.coreutils}/bin/base64 -d > "$workdir/chain.pem"

    rc=0
    ${fort-certcheck}/bin/fort-certcheck should-install \
      --cert "$workdir/fullchain.pem" \
      --key "$workdir/key.pem" \
      --current "$ssl_dir/fullchain.pem" || rc=$?

    if [ "$rc" = "3" ]; then
      echo "ssl-cert handler: pushed cert/key pair is unusable, refusing" >&2
      exit 1
    fi
    if [ "$rc" != "0" ]; then
      exit 0
    fi

    chmod u=rw,go=r "$workdir"/*.pem
    mv -f "$workdir/fullchain.pem" "$ssl_dir/fullchain.pem"
    mv -f "$workdir/key.pem" "$ssl_dir/key.pem"
    mv -f "$workdir/chain.pem" "$ssl_dir/chain.pem"

    /bin/launchctl kickstart -k system/${nginxLabel} || true
  '';

  sslCertFreshnessCheck = pkgs.writeShellScript "ssl-cert-fresh-darwin" ''
    exec ${fort-certcheck}/bin/fort-certcheck fresh \
      --cert ${sslDir}/fullchain.pem \
      --min-days 21
  '';
in
{
  options.fort.darwin.nginxExtraHttpConfig = lib.mkOption {
    type = lib.types.lines;
    default = "";
    description = ''
      Extra http-level nginx config on darwin hosts with fort.cluster.services
      (the appendHttpConfig equivalent — e.g. an internal backend server block
      that a service vhost proxies to).
    '';
  };

  config = lib.mkMerge [
    (lib.mkIf hasServices {
    assertions = [
      {
        assertion = unsupportedServices == [ ];
        message = "fort darwin-services: only sso.mode none/identity, non-static, non-egress services are supported on darwin (offending: ${lib.concatStringsSep ", " (map (s: s.name) unsupportedServices)})";
      }
      {
        assertion = beaconHost != null || publicServices == [ ];
        message = "fort darwin-services: public services declared but no beacon host in cluster";
      }
    ];

    # State dirs + placeholder cluster cert so nginx can start before the
    # ssl-cert need delivers real certs (mirrors fort/ssl.nix preStart).
    system.activationScripts.preActivation.text = lib.mkAfter ''
      mkdir -p ${nginxStateDir}
      touch /var/log/fort-nginx.log
      if [ ! -f ${sslDir}/fullchain.pem ] \
         || [ ! -f ${sslDir}/key.pem ] \
         || ! ${pkgs.openssl}/bin/openssl x509 -in ${sslDir}/fullchain.pem -noout 2>/dev/null; then
        mkdir -p ${sslDir}
        ${pkgs.openssl}/bin/openssl req -x509 -newkey ec \
          -pkeyopt ec_paramgen_curve:prime256v1 \
          -days 1 -nodes -subj "/CN=${domain}" \
          -keyout ${sslDir}/key.pem \
          -out ${sslDir}/fullchain.pem 2>/dev/null
        cp ${sslDir}/fullchain.pem ${sslDir}/chain.pem
      fi
    '';

    launchd.daemons.fort-nginx = {
      serviceConfig = {
        Label = nginxLabel;
        # macOS 26 no longer reliably infers root for third-party system jobs;
        # an omitted UserName leaves the job in launchd with EX_CONFIG.
        UserName = "root";
        ProgramArguments = [
          "${pkgs.nginx}/bin/nginx"
          "-p" nginxStateDir
          "-c" "${nginxConf}"
          "-e" "/var/log/fort-nginx.log"
          "-g" "daemon off;"
        ];
        RunAtLoad = true;
        KeepAlive = true;
        # Certs/dirs appear via activation; retry fast until they do.
        ThrottleInterval = 5;
        # launchd's default 256-fd limit is below worker_connections. Raising
        # only the soft limit above that hard limit makes launchd reject the
        # job with EX_CONFIG, so the limits must move together.
        SoftResourceLimits.NumberOfFiles = 4096;
        HardResourceLimits.NumberOfFiles = 4096;
        StandardOutPath = "/var/log/fort-nginx.log";
        StandardErrorPath = "/var/log/fort-nginx.log";
      };
    };

    # ssl-cert need — all darwin hosts with services consume from the broker
    fort.host.needs.ssl-cert.default = {
      from = "drhorrible";
      request = { };
      handler = sslCertHandler;
      nag = "1h";
      check = sslCertFreshnessCheck;
    };

    # Proxy needs for public services (side-effect-only; the beacon writes
    # its ingress config and proxies https://<this-host>:443 with SNI)
    fort.host.needs.proxy = lib.mkIf (publicServices != [ ] && beaconHost != null) (lib.listToAttrs (map (svc: {
      name = svc.name;
      value = {
        from = beaconHost;
        request = { fqdn = "${subdomainOf svc}.${domain}"; };
        nag = "1h";
      };
    }) publicServices));

    # VPN DNS records — point the fqdn at this host's tailscale IP so VPN
    # clients connect directly (and identity-proxy can whois them)
    fort.host.needs.dns-headscale = lib.mkIf (beaconHost != null) (lib.listToAttrs (map (svc: {
      name = svc.name;
      value = {
        from = beaconHost;
        request = { fqdn = "${subdomainOf svc}.${domain}"; };
        nag = "1h";
      };
    }) services));
    })
    (lib.mkIf (hasServices && hasIdentityServices) {
    sops.secrets.identity-proxy-doc = {
      sopsFile = ./identity.toml.sops;
      format = "binary";
      mode = "0400";
    };

    launchd.daemons.fort-identity-proxy = {
      serviceConfig = {
        Label = identityLabel;
        ProgramArguments = [ "${identityProxyWrapper}" ];
        # Socket access comes from the wrapper chowning its directory to
        # root:nobody; do not ask launchd to assume the special nobody group.
        # macOS 26 rejects that launchd GroupName with EX_CONFIG, and needs
        # the system job's root identity stated explicitly.
        UserName = "root";
        RunAtLoad = true;
        KeepAlive = true;
        # identity doc arrives via sops at activation; OIDC discovery needs
        # the network — retry fast until both are up.
        ThrottleInterval = 5;
        StandardOutPath = "/var/log/fort-identity-proxy.log";
        StandardErrorPath = "/var/log/fort-identity-proxy.log";
        EnvironmentVariables = {
          LISTEN_SOCKET = identitySocket;
          IDENTITY_DOC = config.sops.secrets.identity-proxy-doc.path;
          COOKIE_SIGNING_KEY = "/var/lib/identity-proxy/cookie-key";
          OIDC_CLIENT_ID_FILE = "/var/lib/fort-auth/identity-proxy/client-id";
          OIDC_CLIENT_SECRET_FILE = "/var/lib/fort-auth/identity-proxy/client-secret";
          OIDC_ISSUER = "https://id.${domain}";
          COOKIE_DOMAIN = ".${domain}";
          # darwin tailscaled local API socket (Linux default differs)
          TAILSCALED_SOCKET = "/var/run/tailscaled.socket";
        };
      };
    };

    # OIDC client registration for identity-proxy (wildcard callback covers
    # every service subdomain on this host)
    fort.host.needs.oidc-register.identity-proxy = {
      from = "drhorrible";
      request = {
        client_name = "identity-proxy-${hostName}.${domain}";
        groups = [ ];
        callback_urls = [ "https://*.${domain}/_identity/callback" ];
      };
      handler = identityOidcHandler;
      nag = "15m";
    };
    })
  ];
}
