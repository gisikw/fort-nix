{
  rootManifest,
  ...
}:
{ config, pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;

  fort-certcheck = import ../../pkgs/fort-certcheck { inherit pkgs; };

  # The nixpkgs acme module renews when fewer than validMinDays (default 30)
  # remain. The watchdog threshold sits below that: it only fires after the
  # normal renewal path has been failing for ~5 days, and it gates on the
  # cert's actual notAfter — never on the acme-success marker (q-6f9d966e).
  watchdogMinDays = 25;

  # Async handler for ssl-cert capability
  # Receives aggregate requests, returns same certs for all consumers (wildcard)
  # Input: {"origin:ssl-cert-default": {"request": {...}}, ...}
  # Output: {"origin:ssl-cert-default": {cert, key, chain, domain, notAfter}, ...}
  sslCertHandler = pkgs.writeShellScript "handler-ssl-cert" ''
    set -euo pipefail

    cert_dir="/var/lib/acme/${domain}"

    if [ ! -d "$cert_dir" ]; then
      echo '{"error": "certificate not found for domain"}' >&2
      exit 1
    fi

    # Read and base64-encode the cert files (same for all consumers - wildcard)
    cert=$(${pkgs.coreutils}/bin/base64 -w0 "$cert_dir/fullchain.pem")
    key=$(${pkgs.coreutils}/bin/base64 -w0 "$cert_dir/key.pem")
    chain=$(${pkgs.coreutils}/bin/base64 -w0 "$cert_dir/chain.pem")

    # notAfter rides along for observability and makes renewal an explicit
    # response change (the provider pushes callbacks on response changes).
    not_after=$(${pkgs.openssl}/bin/openssl x509 -in "$cert_dir/fullchain.pem" -noout -enddate | ${pkgs.coreutils}/bin/cut -d= -f2)

    # Build response template
    response=$(${pkgs.jq}/bin/jq -n \
      --arg cert "$cert" \
      --arg key "$key" \
      --arg chain "$chain" \
      --arg domain "${domain}" \
      --arg notAfter "$not_after" \
      '{domain: $domain, cert: $cert, key: $key, chain: $chain, notAfter: $notAfter}')

    # Read aggregate input and return same response for all keys
    ${pkgs.jq}/bin/jq --argjson resp "$response" 'to_entries | map({key: .key, value: $resp}) | from_entries'
  '';
in
{
  sops.secrets.dns-provider-env = {
    sopsFile = ./dns-provider.env.sops;
    format = "binary";
    mode = "0400";
  };

  security.acme = {
    acceptTerms = true;
    defaults = {
      email = "admin@${domain}";
      dnsPropagationCheck = false;
    };

    certs.${domain} = {
      inherit domain;
      extraDomainNames = [
        "*.${domain}"
        "*.fort.${domain}"
      ];
      dnsProvider = rootManifest.fortConfig.settings.dnsProvider;
      environmentFile = config.sops.secrets.dns-provider-env.path;
      # Real renewals happen in acme-order-renew-${domain}.service (timer-
      # driven lego), NOT in acme-${domain}.service — that unit only
      # bootstraps a self-signed cert and short-circuits once the
      # acme-success marker exists. postRun is the module's renewal hook:
      # it runs (as root) only when lego actually installed a new cert,
      # so this is what pushes fresh certs to consumers and local nginx.
      # --no-block: postRun runs inside the acme unit; blocking on units
      # that are ordered against it would deadlock.
      postRun = ''
        systemctl --no-block start fort-ssl-local-copy.service fort-provider-trigger-ssl-cert.service
      '';
    };
  };

  # Expose ssl-cert capability via agent API
  fort.host.capabilities.ssl-cert = {
    handler = sslCertHandler;
    mode = "async";  # Aggregate handler, returns same certs to all consumers
    triggers = {
      initialize = true;  # Push certs on boot
      # Bootstrap/restart path only: acme-${domain}.service is the nixpkgs
      # "ensure certificate" unit (self-signed bootstrap, marker-gated). The
      # renewal push comes from security.acme.certs.${domain}.postRun above.
      systemd = [ "acme-${domain}.service" ];
    };
    description = "Return cluster SSL certificates (ACME-managed)";
  };

  # Renewal watchdog (q-6f9d966e): the only scheduled renewal path is the
  # acme-order-renew-${domain}.timer; if it wedges or lego keeps failing,
  # the cert silently ages out while acme-${domain}.service keeps exiting 0
  # on its acme-success marker. This watchdog gates on the actual notAfter:
  # once past the threshold it force-starts the order-renew unit, and it
  # fails loudly (visible in `systemctl --failed` / host-status) if the
  # cert has expired outright and renewal did not recover it.
  systemd.services.fort-cert-renewal-watchdog = {
    description = "Force ACME renewal when the cluster cert nears expiry";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig.Type = "oneshot";
    path = [ pkgs.systemd ];
    script = ''
      cert="/var/lib/acme/${domain}/fullchain.pem"
      marker="/var/lib/acme/${domain}/acme-success"

      if ${fort-certcheck}/bin/fort-certcheck should-renew --cert "$cert" --min-days ${toString watchdogMinDays} --marker "$marker"; then
        echo "renewal overdue; starting acme-order-renew-${domain}.service"
        systemctl start "acme-order-renew-${domain}.service" || true
      fi

      # Independent of renewal outcome: an expired cluster cert is an
      # incident — fail the unit so it surfaces in systemctl --failed.
      if ! ${fort-certcheck}/bin/fort-certcheck fresh --cert "$cert" --min-days 0; then
        echo "cluster certificate for ${domain} is expired or unreadable" >&2
        exit 1
      fi
    '';
  };

  systemd.timers.fort-cert-renewal-watchdog = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "15m";
      OnUnitActiveSec = "6h";
      RandomizedDelaySec = "10m";
    };
  };

  # Copy ACME certs to standard location for local nginx
  # Triggered on ACME success (can't use postStart due to ACME sandbox)
  systemd.services.fort-ssl-local-copy = {
    description = "Copy ACME certs to fort/ssl for local nginx";
    after = [ "acme-${domain}.service" ];
    before = [ "nginx.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "copy-local-certs" ''
        set -euo pipefail
        mkdir -p /var/lib/fort/ssl/${domain}

        ssl_dir="/var/lib/fort/ssl/${domain}"
        acme_dir="/var/lib/acme/${domain}"

        # Try copying from ACME source (persisted across reboots)
        if [ -f "$acme_dir/fullchain.pem" ] && \
           ${pkgs.openssl}/bin/openssl x509 -in "$acme_dir/fullchain.pem" -noout 2>/dev/null; then
          cp -L "$acme_dir/fullchain.pem" "$ssl_dir/"
          cp -L "$acme_dir/key.pem" "$ssl_dir/"
          cp -L "$acme_dir/chain.pem" "$ssl_dir/"
        # Existing ssl certs are valid — leave them alone
        elif [ -f "$ssl_dir/fullchain.pem" ] && \
             ${pkgs.openssl}/bin/openssl x509 -in "$ssl_dir/fullchain.pem" -noout 2>/dev/null; then
          :
        # Nothing valid — generate self-signed placeholder so nginx can start
        else
          ${pkgs.openssl}/bin/openssl req -x509 -newkey ec \
            -pkeyopt ec_paramgen_curve:prime256v1 \
            -days 1 -nodes -subj "/CN=${domain}" \
            -keyout "$ssl_dir/key.pem" \
            -out "$ssl_dir/fullchain.pem" 2>/dev/null
          cp "$ssl_dir/fullchain.pem" "$ssl_dir/chain.pem"
        fi

        chown -R root:root /var/lib/fort/ssl
        chmod -R u=rwX,go=rX /var/lib/fort/ssl
        # Only reload if nginx is already running (avoid deadlock on boot —
        # this service runs before nginx via Before=, so reload would block)
        if ${pkgs.systemd}/bin/systemctl is-active --quiet nginx; then
          ${pkgs.systemd}/bin/systemctl reload nginx || true
        fi
      '';
    };
  };

  # Trigger local copy when ACME succeeds
  systemd.services."acme-${domain}".unitConfig.OnSuccess = [ "fort-ssl-local-copy.service" ];
}
