{ pkgs }:

let
  version = "2.0.1";

  sqliteWithExtensions = pkgs.sqlite.overrideAttrs (old: {
    configureFlags = (old.configureFlags or []) ++ [
      "--enable-load-extension"
    ];
  });
in
pkgs.buildNpmPackage {
  pname = "qmd";
  inherit version;

  src = pkgs.fetchFromGitHub {
    owner = "tobi";
    repo = "qmd";
    rev = "v${version}";
    hash = "sha256-UoR9iyxqbjwAbEmiC/kxS10lvdBJmDuQigS/aEgEzDs=";
  };

  postPatch = ''
    cp ${./package-lock.json} package-lock.json
  '';

  npmDepsHash = "sha256-kkf9kRsH8lDpQ8tDyMKBCLb4hnqRY92bwWK8yc2hne4=";

  nativeBuildInputs = with pkgs; [
    python3
    nodePackages.node-gyp
    pkg-config
    makeWrapper
    typescript
    autoPatchelfHook
  ];

  buildInputs = [
    sqliteWithExtensions
    pkgs.vulkan-loader
    pkgs.stdenv.cc.cc.lib
  ];

  nodejs = pkgs.nodejs_22;

  # Prebuilt binaries include CUDA and musl variants we don't need — ignore their missing deps
  autoPatchelfIgnoreMissingDeps = [
    "libcudart.so.*"
    "libcublas.so.*"
    "libcuda.so.*"
    "libc.musl-*"
  ];

  # Build TypeScript to dist/
  npmBuildScript = "build";

  postInstall = ''
    rm -f $out/bin/qmd
    makeWrapper ${pkgs.nodejs_22}/bin/node $out/bin/qmd \
      --add-flags "$out/lib/node_modules/@tobilu/qmd/dist/cli/qmd.js" \
      --set LD_LIBRARY_PATH "${pkgs.lib.makeLibraryPath [
        sqliteWithExtensions.out
        pkgs.vulkan-loader
        pkgs.stdenv.cc.cc.lib
      ]}"
  '';

  meta = with pkgs.lib; {
    description = "On-device search engine for markdown notes";
    homepage = "https://github.com/tobi/qmd";
    license = licenses.mit;
    platforms = platforms.unix;
  };
}
