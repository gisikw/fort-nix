{ pkgs }:

let
  script = pkgs.writeShellScript "fort-agent-call" ''
    set -euo pipefail

    # Usage: fort-agent-call <host> <capability> [request-json]
    # Exit codes: 0=success, 1=http error, 2=auth error

    usage() {
      echo "Usage: fort-agent-call <host> <capability> [request-json]" >&2
      echo "  host: target hostname (e.g., drhorrible)" >&2
      echo "  capability: agent endpoint (e.g., oidc-register)" >&2
      echo "  request-json: optional JSON body (default: {})" >&2
      exit 1
    }

    [ $# -lt 2 ] && usage

    HOST="$1"
    CAPABILITY="$2"
    BODY="''${3:-{}}"

    # Configuration
    DOMAIN="''${FORT_DOMAIN:-gisi.network}"
    SSH_KEY="''${FORT_SSH_KEY:-/etc/ssh/ssh_host_ed25519_key}"
    ORIGIN="''${FORT_ORIGIN:-$(hostname -s)}"

    # Validate SSH key exists
    if [ ! -f "$SSH_KEY" ]; then
      echo "Error: SSH key not found: $SSH_KEY" >&2
      exit 2
    fi

    # Build request components
    METHOD="POST"
    PATH="/agent/$CAPABILITY"
    TIMESTAMP="$(date +%s)"
    BODY_HASH="$(echo -n "$BODY" | sha256sum | cut -d' ' -f1)"

    # Build canonical string for signing (newline-separated)
    CANONICAL="$(printf '%s\n%s\n%s\n%s' "$METHOD" "$PATH" "$TIMESTAMP" "$BODY_HASH")"

    # Sign with SSH key
    # ssh-keygen -Y sign outputs armored signature to stdout
    SIGNATURE="$(printf '%s' "$CANONICAL" | ssh-keygen -Y sign -f "$SSH_KEY" -n fort-agent -q 2>/dev/null)" || {
      echo "Error: Failed to sign request" >&2
      exit 2
    }

    # Base64 encode signature (remove armor, join lines)
    SIG_B64="$(echo "$SIGNATURE" | grep -v '^-----' | tr -d '\n')"

    # Build URL
    URL="https://''${HOST}.fort.''${DOMAIN}''${PATH}"

    # Make request, capture response headers and body separately
    HEADER_FILE="$(mktemp)"
    BODY_FILE="$(mktemp)"
    trap "rm -f '$HEADER_FILE' '$BODY_FILE'" EXIT

    HTTP_CODE="$(curl -s -w '%{http_code}' -o "$BODY_FILE" \
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

    RESPONSE_BODY="$(cat "$BODY_FILE")"

    # Parse response headers for handle and TTL
    FORT_HANDLE="$(grep -i '^X-Fort-Handle:' "$HEADER_FILE" | sed 's/^[^:]*: *//' | tr -d '\r' || true)"
    FORT_TTL="$(grep -i '^X-Fort-TTL:' "$HEADER_FILE" | sed 's/^[^:]*: *//' | tr -d '\r' || true)"

    # Check HTTP status
    case "$HTTP_CODE" in
      2*)
        # Success - output response body
        echo "$RESPONSE_BODY"

        # Output handle info as markers (can be parsed by caller)
        if [ -n "$FORT_HANDLE" ]; then
          echo "FORT_HANDLE=$FORT_HANDLE" >&2
        fi
        if [ -n "$FORT_TTL" ]; then
          echo "FORT_TTL=$FORT_TTL" >&2
        fi
        exit 0
        ;;
      401|403)
        echo "Error: Authentication/authorization failed ($HTTP_CODE)" >&2
        echo "$RESPONSE_BODY" >&2
        exit 2
        ;;
      *)
        echo "Error: HTTP $HTTP_CODE" >&2
        echo "$RESPONSE_BODY" >&2
        exit 1
        ;;
    esac
  '';
in
pkgs.stdenv.mkDerivation {
  pname = "fort-agent-call";
  version = "0.1.0";

  dontUnpack = true;

  nativeBuildInputs = [ pkgs.makeWrapper ];

  buildInputs = [
    pkgs.curl
    pkgs.coreutils
    pkgs.openssh
    pkgs.gnugrep
    pkgs.gnused
  ];

  installPhase = ''
    install -Dm755 ${script} $out/bin/fort-agent-call
    wrapProgram $out/bin/fort-agent-call \
      --prefix PATH : ${pkgs.lib.makeBinPath [
        pkgs.curl
        pkgs.coreutils
        pkgs.openssh
        pkgs.gnugrep
        pkgs.gnused
      ]}
  '';

  meta = with pkgs.lib; {
    description = "CLI client for fort agent protocol";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
