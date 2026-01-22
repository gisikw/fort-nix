{ pkgs }:

let
  # Pre-generate icons from SVG
  icons = pkgs.runCommand "punchlist-icons" {
    nativeBuildInputs = [ pkgs.imagemagick ];
  } ''
    mkdir -p $out
    convert -background none ${./static/icon.svg} -resize 192x192 $out/icon-192.png
    convert -background none ${./static/icon.svg} -resize 512x512 $out/icon-512.png
  '';

  # Source with generated icons included
  srcWithIcons = pkgs.runCommand "punchlist-src" {} ''
    cp -r ${./.} $out
    chmod -R u+w $out
    cp ${icons}/icon-192.png $out/static/
    cp ${icons}/icon-512.png $out/static/
  '';
in
pkgs.buildGoModule {
  pname = "punchlist";
  version = "0.1.0";

  src = srcWithIcons;

  vendorHash = "sha256-iVGS9bvZ01AKuaFt1XLOKp6gW1NnPYTk0LoZzjsNmTg=";

  meta = with pkgs.lib; {
    description = "A brutally simple todo app";
    mainProgram = "punchlist";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
