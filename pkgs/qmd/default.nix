{ pkgs }:

let
  version = "2.0.1";

  src = pkgs.fetchFromGitHub {
    owner = "tobi";
    repo = "qmd";
    rev = "v${version}";
    hash = "sha256-UoR9iyxqbjwAbEmiC/kxS10lvdBJmDuQigS/aEgEzDs=";
  };

  sqliteWithExtensions = pkgs.sqlite.overrideAttrs (old: {
    configureFlags = (old.configureFlags or []) ++ [
      "--enable-load-extension"
    ];
  });
in
pkgs.stdenv.mkDerivation {
  pname = "qmd";
  inherit version src;

  nativeBuildInputs = [
    pkgs.bun
    pkgs.makeWrapper
    pkgs.python3
  ];

  buildInputs = [ sqliteWithExtensions ];

  buildPhase = ''
    export HOME=$(mktemp -d)
    bun install --frozen-lockfile
  '';

  installPhase = ''
    mkdir -p $out/lib/qmd $out/bin

    cp -r node_modules $out/lib/qmd/
    cp -r src $out/lib/qmd/
    cp package.json $out/lib/qmd/

    makeWrapper ${pkgs.bun}/bin/bun $out/bin/qmd \
      --add-flags "$out/lib/qmd/src/qmd.ts" \
      --set LD_LIBRARY_PATH "${sqliteWithExtensions.out}/lib"
  '';

  meta = with pkgs.lib; {
    description = "On-device search engine for markdown notes";
    homepage = "https://github.com/tobi/qmd";
    license = licenses.mit;
    platforms = platforms.unix;
  };
}
