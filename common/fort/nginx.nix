# nginx virtual-host generation (q-d9cba37c)
#
# The nginx side of service exposure: realip/geo plumbing shared by every
# vhost, and one virtual host per fort.cluster.services entry (static root,
# direct proxy, oauth2-proxy socket, njs token validation, or identity-proxy
# auth_request — the auth backends themselves live in auth.nix).
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

  inherit (import ./service-lib.nix) subdomainOf;

  # Get services using bearer token auth
  tokenServices = builtins.filter (svc: svc.sso.mode == "token") config.fort.cluster.services;

  # njs token validator script path (for nginx js_import)
  tokenValidatorScript = ./token-validator.js;
in
{
  config = lib.mkMerge [
    # VPN geo block - always defined so aspects (like host-status) can use it
    # Also configure realip to trust X-Real-IP from VPN (beacon proxy)
    {
      # headers-more module: loaded unconditionally alongside the more_set_headers
      # directive below so the two never desync (a directive without its module is
      # an nginx emerg). Merges with any additionalModules defined elsewhere.
      services.nginx.additionalModules = [ pkgs.nginxModules.moreheaders ];
      services.nginx.commonHttpConfig = lib.mkBefore (
        ''
          # Trust X-Real-IP header from VPN peers (beacon proxy)
          set_real_ip_from ${vpnIpv4Prefix};
          real_ip_header X-Real-IP;
          real_ip_recursive on;

          # Stamp every response -- including nginx-generated errors like 413 --
          # with a per-host header so the responding (and traversed) nginx is
          # always identifiable from the client side. Unique header NAME per host
          # means edge and backend never collide: a proxied response carries the
          # full hop path (e.g. X-Fort-Hop-raishan + X-Fort-Hop-lordhenry), and an
          # error that dies at the edge carries only the edge's header -- so you can
          # tell exactly which nginx rejected a request. Uses more_set_headers
          # (headers-more) rather than add_header because add_header is silently
          # dropped whenever a location defines its own add_header, and does not
          # fire on internally-generated error responses.
          more_set_headers "X-Fort-Hop-${config.networking.hostName}: 1";

          # Disable proxy buffering globally so SSE streams flush immediately
          proxy_buffering off;

          geo $is_vpn {
            default 0;
            ${vpnIpv4Prefix} 1;
          }

          geo $is_local {
            default 0;
            ${lanIpv4Prefix} 1;
            127.0.0.0/8 1;
          }
        ''
        + lib.optionalString (tokenServices != [ ]) ''

          # njs token validator for sso.mode = "token"
          js_import token_validator from ${tokenValidatorScript};
        ''
      );
    }

    (lib.mkIf (lib.length config.fort.cluster.services >= 1) {

      services.nginx = {
        enable = true;
        recommendedProxySettings = true;
        # Extend proxy read timeout for long-running SSE streams (LLM inference,
        # livereload, TTS, transcription). Default 60s kills idle streams.
        proxyTimeout = "600s";
        additionalModules = lib.optionals (tokenServices != [ ]) [ pkgs.nginxModules.njs ];

        virtualHosts = lib.listToAttrs (
          map (
            svc:
            let
              subdomain = subdomainOf svc;
              isStatic = svc.staticRoot != null;
              needsAuthProxy =
                svc.sso.mode != "none"
                && svc.sso.mode != "oidc"
                && svc.sso.mode != "token"
                && svc.sso.mode != "identity";
              isTokenMode = svc.sso.mode == "token";
              isIdentityMode = svc.sso.mode == "identity";
              anyBypass = svc.sso.vpnBypass || svc.sso.localBypass;
              directBackend =
                lib.optionalString (!isStatic)
                  "http://${if svc.inEgressNamespace then "10.200.0.2" else "127.0.0.1"}:${toString svc.port}";
              authProxySocket = "http://unix:/run/fort-auth/${svc.name}.sock";
            in
            {
              name = "${subdomain}.${domain}";
              value = {
                forceSSL = true;
                sslCertificate = "/var/lib/fort/ssl/${domain}/fullchain.pem";
                sslCertificateKey = "/var/lib/fort/ssl/${domain}/key.pem";
                # Allow iframing within the domain (lair app shell)
                extraConfig = ''
                  add_header Content-Security-Policy "frame-ancestors 'self' https://*.${domain}" always;
                '';
                # Static file serving mode
                root = lib.mkIf isStatic svc.staticRoot;
                locations."/" =
                  if isStatic then
                    {
                      extraConfig = lib.concatStringsSep "\n" (
                        lib.filter (s: s != "") [
                          "try_files $uri $uri/ =404;"
                          (lib.optionalString (svc.visibility == "vpn") ''
                            if ($is_vpn = 0) {
                              return 444;
                            }
                          '')
                          (lib.optionalString (svc.maxBodySize != null) ''
                            client_max_body_size ${svc.maxBodySize};
                          '')
                        ]
                      );
                    }
                  else
                    {
                      extraConfig = lib.concatStringsSep "\n" (
                        lib.filter (s: s != "") [
                          # Ensure cookies are forwarded (not included in recommendedProxySettings)
                          "proxy_set_header Cookie $http_cookie;"
                          (lib.optionalString (svc.visibility == "vpn") ''
                            if ($is_vpn = 0) {
                              return 444;
                            }
                          '')
                          (lib.optionalString (svc.maxBodySize != null) ''
                            client_max_body_size ${svc.maxBodySize};
                          '')
                          # Token mode: nginx auth_request to njs validator
                          (lib.optionalString isTokenMode ''
                            auth_request /_fort_validate_token;
                          '')
                          # Identity mode: nginx auth_request to identity-proxy
                          (lib.optionalString isIdentityMode ''
                            auth_request /_identity/validate;
                            auth_request_set $identity_user $upstream_http_x_identity_user;
                            auth_request_set $identity_email $upstream_http_x_identity_email;
                            auth_request_set $identity_groups $upstream_http_x_identity_groups;
                            proxy_set_header X-Forwarded-User $identity_user;
                            proxy_set_header X-Forwarded-Email $identity_email;
                            proxy_set_header X-Forwarded-Groups $identity_groups;
                            # RFC 9728/6750 advertisement: native clients that get a
                            # 401 learn where to run the authorization dance.
                            # more_set_headers, not add_header: add_header at
                            # location level drops the server-level CSP header
                            # (gixy add_header_redefinition).
                            more_set_headers 'WWW-Authenticate: Bearer resource_metadata="https://$host/.well-known/oauth-protected-resource"';
                            error_page 401 = @identity_login;
                          '')
                          # Conditional routing: bypass auth for trusted networks, otherwise go through oauth2-proxy
                          # When proxyPass is null, NixOS doesn't add recommended headers, so we must add them
                          (
                            lib.optionalString (anyBypass && needsAuthProxy) ''
                              proxy_set_header Host $host;
                              proxy_set_header X-Real-IP $remote_addr;
                              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                              proxy_set_header X-Forwarded-Proto $scheme;
                              proxy_set_header X-Forwarded-Host $host;
                              proxy_set_header X-Forwarded-Server $host;
                              set $backend "${authProxySocket}";
                            ''
                            + lib.optionalString (svc.sso.vpnBypass && needsAuthProxy) ''
                              if ($is_vpn = 1) {
                                set $backend "${directBackend}";
                              }
                            ''
                            + lib.optionalString (svc.sso.localBypass && needsAuthProxy) ''
                              if ($is_local = 1) {
                                set $backend "${directBackend}";
                              }
                            ''
                            + lib.optionalString (anyBypass && needsAuthProxy) ''
                              proxy_pass $backend;
                            ''
                          )
                        ]
                      );
                      # Only set proxyPass when not using bypass conditional routing
                      proxyPass =
                        if (anyBypass && needsAuthProxy) then
                          null
                        else if needsAuthProxy then
                          authProxySocket
                        else
                          directBackend;
                      proxyWebsockets = true;
                    };
                # Internal location for njs token validation (auth_request target)
                locations."/_fort_validate_token" = lib.mkIf isTokenMode {
                  extraConfig = ''
                    internal;
                    set $token_vpn_bypass ${if svc.sso.vpnBypass then "1" else "0"};
                    set $token_local_bypass ${if svc.sso.localBypass then "1" else "0"};
                    js_content token_validator.validate;
                  '';
                };
                # Identity proxy auth_request target
                locations."= /_identity/validate" = lib.mkIf isIdentityMode {
                  extraConfig = ''
                    internal;
                    client_max_body_size 0;
                    proxy_pass http://unix:/run/identity-proxy/identity-proxy.sock;
                    proxy_pass_request_body off;
                    proxy_set_header Content-Length "";
                    proxy_set_header X-Original-URI $request_uri;
                    proxy_set_header X-Original-Host $host;
                    proxy_set_header X-Real-IP $remote_addr;
                    proxy_set_header X-Identity-Required-Groups "${lib.concatStringsSep "," svc.sso.groups}";
                  '';
                };
                # Identity proxy login redirect
                locations."@identity_login" = lib.mkIf isIdentityMode {
                  extraConfig = ''
                    return 302 https://$host/_identity/login?rd=$scheme://$host$request_uri;
                  '';
                };
                # Identity proxy endpoints (login, callback)
                locations."/_identity/" = lib.mkIf isIdentityMode {
                  extraConfig = ''
                    proxy_pass http://unix:/run/identity-proxy/identity-proxy.sock;
                    proxy_set_header Host $host;
                    proxy_set_header X-Original-Host $host;
                    proxy_set_header X-Real-IP $remote_addr;
                  '';
                };
                # RFC 9728 protected resource metadata (native-client discovery)
                locations."= /.well-known/oauth-protected-resource" = lib.mkIf isIdentityMode {
                  extraConfig = ''
                    proxy_pass http://unix:/run/identity-proxy/identity-proxy.sock/_identity/protected-resource;
                    proxy_set_header Host $host;
                    proxy_set_header X-Original-Host $host;
                  '';
                };
              };
            }
          ) config.fort.cluster.services
        );
      };

      networking.firewall.allowedTCPPorts = [
        80
        443
      ];
    })
  ];
}
