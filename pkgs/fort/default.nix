{ pkgs, domain }:

let
  script = pkgs.writeShellScript "fort" ''
    set -euo pipefail

    # Usage: fort <host> <capability> [request-json]
    # Exit codes: 0=success, 1=http error, 2=auth error
    #
    # Output (stdout): JSON envelope with body, handle, ttl, status
    # {
    #   "body": <response body as JSON or string>,
    #   "handle": "sha256:..." or null,
    #   "ttl": 86400 or null,
    #   "status": 200
    # }

    usage() {
      echo "Usage: fort <host> <capability> [request-json]" >&2
      echo "  host: target hostname" >&2
      echo "  capability: agent endpoint (e.g., status, ssl-cert)" >&2
      echo "  request-json: optional JSON body (default: {})" >&2
      exit 1
    }

    [ $# -lt 2 ] && usage

    HOST="$1"
    CAPABILITY="$2"
    BODY="''${3:-"{}"}"

    # Domain injected at build time
    DOMAIN="${domain}"

    # Configuration (can override via env for testing)
    SSH_KEY="''${FORT_SSH_KEY:-/etc/ssh/ssh_host_ed25519_key}"
    ORIGIN="''${FORT_ORIGIN:-$(${pkgs.nettools}/bin/hostname -s)}"

    # Validate SSH key exists
    if [ ! -f "$SSH_KEY" ]; then
      echo "Error: SSH key not found: $SSH_KEY" >&2
      exit 2
    fi

    # Build request components
    METHOD="POST"
    REQ_PATH="/agent/$CAPABILITY"
    TIMESTAMP="$(${pkgs.coreutils}/bin/date +%s)"
    BODY_HASH="$(echo -n "$BODY" | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d' ' -f1)"

    # Build canonical string for signing (newline-separated)
    CANONICAL="$(printf '%s\n%s\n%s\n%s' "$METHOD" "$REQ_PATH" "$TIMESTAMP" "$BODY_HASH")"

    # Sign with SSH key
    # ssh-keygen -Y sign outputs armored signature to stdout
    SIGNATURE="$(printf '%s' "$CANONICAL" | ${pkgs.openssh}/bin/ssh-keygen -Y sign -f "$SSH_KEY" -n fort-agent -q 2>/dev/null)" || {
      echo "Error: Failed to sign request" >&2
      exit 2
    }

    # Base64 encode signature (remove armor, join lines)
    SIG_B64="$(echo "$SIGNATURE" | ${pkgs.gnugrep}/bin/grep -v '^-----' | ${pkgs.coreutils}/bin/tr -d '\n')"

    # Build URL
    URL="https://''${HOST}.fort.''${DOMAIN}''${REQ_PATH}"

    # Make request, capture response headers and body separately
    HEADER_FILE="$(${pkgs.coreutils}/bin/mktemp)"
    BODY_FILE="$(${pkgs.coreutils}/bin/mktemp)"
    trap "${pkgs.coreutils}/bin/rm -f '$HEADER_FILE' '$BODY_FILE'" EXIT

    HTTP_CODE="$(${pkgs.curl}/bin/curl -s -w '%{http_code}' -o "$BODY_FILE" \
      --max-time 30 \
      -X POST \
      -H "Content-Type: application/json" \
      -H "X-Fort-Origin: $ORIGIN" \
      -H "X-Fort-Timestamp: $TIMESTAMP" \
      -H "X-Fort-Signature: $SIG_B64" \
      -D "$HEADER_FILE" \
      -d "$BODY" \
      "$URL" 2>/dev/null)" || {
      echo "Error: Failed to connect to $URL" >&2
      exit 1
    }

    RESPONSE_BODY="$(${pkgs.coreutils}/bin/cat "$BODY_FILE")"

    # Parse response headers for handle and TTL
    FORT_HANDLE="$(${pkgs.gnugrep}/bin/grep -i '^X-Fort-Handle:' "$HEADER_FILE" | ${pkgs.gnused}/bin/sed 's/^[^:]*: *//' | ${pkgs.coreutils}/bin/tr -d '\r' || true)"
    FORT_TTL="$(${pkgs.gnugrep}/bin/grep -i '^X-Fort-TTL:' "$HEADER_FILE" | ${pkgs.gnused}/bin/sed 's/^[^:]*: *//' | ${pkgs.coreutils}/bin/tr -d '\r' || true)"

    # Build JSON envelope output
    output_json() {
      local status="$1"
      local body="$2"
      local handle="$3"
      local ttl="$4"

      # Try to parse body as JSON, fall back to string
      if echo "$body" | ${pkgs.jq}/bin/jq -e . >/dev/null 2>&1; then
        body_json="$body"
      else
        body_json="$(echo "$body" | ${pkgs.jq}/bin/jq -Rs .)"
      fi

      ${pkgs.jq}/bin/jq -n \
        --argjson body "$body_json" \
        --argjson status "$status" \
        --arg handle "$handle" \
        --arg ttl "$ttl" \
        '{
          body: $body,
          status: $status,
          handle: (if $handle == "" then null else $handle end),
          ttl: (if $ttl == "" then null else ($ttl | tonumber) end)
        }'
    }

    # Check HTTP status
    case "$HTTP_CODE" in
      2*)
        output_json "$HTTP_CODE" "$RESPONSE_BODY" "$FORT_HANDLE" "$FORT_TTL"
        exit 0
        ;;
      401|403)
        echo "Error: Authentication/authorization failed ($HTTP_CODE)" >&2
        output_json "$HTTP_CODE" "$RESPONSE_BODY" "" ""
        exit 2
        ;;
      *)
        echo "Error: HTTP $HTTP_CODE" >&2
        output_json "$HTTP_CODE" "$RESPONSE_BODY" "" ""
        exit 1
        ;;
    esac
  '';
in
pkgs.stdenv.mkDerivation {
  pname = "fort";
  version = "0.1.0";

  dontUnpack = true;

  nativeBuildInputs = [ pkgs.makeWrapper ];

  buildInputs = [
    pkgs.curl
    pkgs.coreutils
    pkgs.openssh
    pkgs.gnugrep
    pkgs.gnused
    pkgs.jq
    pkgs.nettools
  ];

  installPhase = ''
    install -Dm755 ${script} $out/bin/fort
    wrapProgram $out/bin/fort \
      --prefix PATH : ${pkgs.lib.makeBinPath [
        pkgs.curl
        pkgs.coreutils
        pkgs.openssh
        pkgs.gnugrep
        pkgs.gnused
        pkgs.jq
        pkgs.nettools
      ]}
  '';

  meta = with pkgs.lib; {
    description = "Fort control plane CLI";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
