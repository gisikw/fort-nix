# SSL certificate consumption (q-d9cba37c)
#
# Cert handling for every nginx host that is NOT the ACME/broker host:
# bootstrap placeholder certs so nginx can start on a fresh box, the
# ssl-cert need that pulls real certs from the certificate broker, and the
# freshness probe that re-requests them as expiry approaches. The broker
# (provider) side lives in aspects/certificate-broker/.
{ rootManifest, cluster, ... }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  domain = rootManifest.fortConfig.settings.domain;

  fort-certcheck = import ../../pkgs/fort-certcheck { inherit pkgs; };

  # Consumers demand this many days of remaining validity before the
  # ssl-cert need re-requests. Must sit below the broker's renewal
  # thresholds (lego renews at 30 days remaining, the broker watchdog
  # force-renews at 25) or consumers would go stale-and-nagging before
  # the broker is even willing to renew.
  sslCertFreshMinDays = 21;

  # SSL cert consumer handler - validates and installs pushed certs.
  # Resilience rules (q-b0530f9b): never let a bad payload clobber working
  # certs. Decode to a scratch dir, validate the pair, refuse downgrades
  # (fort-certcheck should-install), install atomically, and only reload
  # nginx when something actually changed.
  sslCertConsumerHandler = pkgs.writeShellScript "ssl-cert-handler" ''
    set -euo pipefail

    ssl_dir="/var/lib/fort/ssl/${domain}"

    # Read payload once
    payload=$(${pkgs.coreutils}/bin/cat)

    # Refuse malformed payloads (e.g. an empty revocation "{}") before
    # touching disk. Exit 1 keeps the need unsatisfied so delivery retries.
    if ! echo "$payload" | ${pkgs.jq}/bin/jq -e '.cert and .key and .chain' >/dev/null 2>&1; then
      echo "ssl-cert handler: payload missing cert/key/chain, refusing" >&2
      exit 1
    fi

    mkdir -p "$ssl_dir"

    # Scratch dir on the same filesystem so the final mv is a rename
    workdir=$(${pkgs.coreutils}/bin/mktemp -d "$ssl_dir/.incoming.XXXXXX")
    trap 'rm -rf "$workdir"' EXIT

    echo "$payload" | ${pkgs.jq}/bin/jq -r '.cert' | ${pkgs.coreutils}/bin/base64 -d > "$workdir/fullchain.pem"
    echo "$payload" | ${pkgs.jq}/bin/jq -r '.key' | ${pkgs.coreutils}/bin/base64 -d > "$workdir/key.pem"
    echo "$payload" | ${pkgs.jq}/bin/jq -r '.chain' | ${pkgs.coreutils}/bin/base64 -d > "$workdir/chain.pem"

    # should-install: 0 = install, 1 = valid but no improvement (no-op),
    # 3 = candidate unusable (unreadable / key mismatch) -> fail so we retry
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
      # Valid pair but not an improvement (identical, or ours is better).
      # Treat as satisfied - we hold a cert at least as good as offered.
      exit 0
    fi

    chown root:root "$workdir"/*.pem
    chmod u=rw,go=r "$workdir"/*.pem
    mv -f "$workdir/fullchain.pem" "$ssl_dir/fullchain.pem"
    mv -f "$workdir/key.pem" "$ssl_dir/key.pem"
    mv -f "$workdir/chain.pem" "$ssl_dir/chain.pem"

    # Reload nginx if running (only on actual change)
    ${pkgs.systemd}/bin/systemctl reload nginx 2>/dev/null || true
  '';

  # Freshness probe for the ssl-cert need: passes while the installed cert
  # has more than sslCertFreshMinDays of validity left. When it fails, the
  # fulfill loop re-requests from the broker once per nag interval - this is
  # the pull-side backstop for renewals whose push callback never arrived
  # (q-5118c7ed).
  sslCertFreshnessCheck = pkgs.writeShellScript "ssl-cert-fresh" ''
    exec ${fort-certcheck}/bin/fort-certcheck fresh \
      --cert /var/lib/fort/ssl/${domain}/fullchain.pem \
      --min-days ${toString sslCertFreshMinDays}
  '';

  # Check if this host is the certificate provider (has ACME certs configured)
  isCertProvider = config.security.acme.certs ? ${domain};
in
{
  config = lib.mkMerge [
    # Generate self-signed placeholder certs so nginx can start on fresh hosts.
    # Real certs arrive via ssl-cert need and trigger an nginx reload.
    (lib.mkIf (config.services.nginx.enable && !isCertProvider) {
      # nginx runs with ProtectSystem=strict — need write access for cert bootstrap.
      # tmpfiles ensures the dir exists before systemd sets up the namespace mount.
      systemd.tmpfiles.rules = [ "d /var/lib/fort/ssl/${domain} 0755 nginx nginx -" ];
      systemd.services.nginx.serviceConfig.ReadWritePaths = [ "/var/lib/fort/ssl" ];
      # Regenerate the placeholder when the cert is missing OR unreadable —
      # a corrupt/truncated cert file would otherwise wedge nginx at boot
      # with no recovery path (q-b0530f9b). An expired-but-parseable cert is
      # left alone: serving stale beats serving self-signed.
      systemd.services.nginx.preStart = lib.mkBefore ''
        if [ ! -f /var/lib/fort/ssl/${domain}/fullchain.pem ] \
           || [ ! -f /var/lib/fort/ssl/${domain}/key.pem ] \
           || ! ${pkgs.openssl}/bin/openssl x509 -in /var/lib/fort/ssl/${domain}/fullchain.pem -noout 2>/dev/null; then
          mkdir -p /var/lib/fort/ssl/${domain}
          ${pkgs.openssl}/bin/openssl req -x509 -newkey ec \
            -pkeyopt ec_paramgen_curve:prime256v1 \
            -days 1 -nodes -subj "/CN=${domain}" \
            -keyout /var/lib/fort/ssl/${domain}/key.pem \
            -out /var/lib/fort/ssl/${domain}/fullchain.pem 2>/dev/null
          cp /var/lib/fort/ssl/${domain}/fullchain.pem /var/lib/fort/ssl/${domain}/chain.pem
        fi
      '';
    })

    # SSL certificate need - all hosts with nginx that aren't the cert provider
    (lib.mkIf (config.services.nginx.enable && !isCertProvider) {
      fort.host.needs.ssl-cert.default = {
        from = "drhorrible";  # certificate-broker host
        request = {};
        handler = sslCertConsumerHandler;
        nag = "1h";  # Re-request if certs not received within 1h
        # Pull-side staleness backstop: re-request when the installed cert
        # drops below the freshness threshold, so renewals propagate even
        # if the broker's push callback was missed (q-5118c7ed).
        check = sslCertFreshnessCheck;
      };
    })
  ];
}
