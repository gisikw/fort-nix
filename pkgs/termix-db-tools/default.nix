{ pkgs }:

# Tools for manipulating termix's encrypted SQLite database
# Provides: termix-db-decrypt, termix-db-encrypt

let
  decryptScript = ./decrypt.mjs;
  encryptScript = ./encrypt.mjs;
in
pkgs.runCommand "termix-db-tools" {
  nativeBuildInputs = [ pkgs.makeWrapper ];
} ''
  mkdir -p $out/bin $out/lib

  # Copy scripts
  cp ${decryptScript} $out/lib/decrypt.mjs
  cp ${encryptScript} $out/lib/encrypt.mjs

  # Create wrapper scripts that invoke node
  makeWrapper ${pkgs.nodejs}/bin/node $out/bin/termix-db-decrypt \
    --add-flags "$out/lib/decrypt.mjs"

  makeWrapper ${pkgs.nodejs}/bin/node $out/bin/termix-db-encrypt \
    --add-flags "$out/lib/encrypt.mjs"
''
