# Root CAs distrusted fleet-wide (Oct 2026 intermediate CA compromise).
# Labels must match nixpkgs' cacert bundle exactly. Used by both platforms:
# NixOS -> system bundle; nix-darwin -> /etc/ssl/certs + NIX_SSL_CERT_FILE
# (Nix-side TLS only; macOS Keychain trust comes from Apple's OS updates).
[
  "Comodo AAA Services root"
  "emSign ECC Root CA - G3"
]
