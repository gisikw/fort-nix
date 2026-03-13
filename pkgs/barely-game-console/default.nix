{ pkgs }:

pkgs.rustPlatform.buildRustPackage rec {
  pname = "barely-game-console";
  version = "0.1.0-unstable-2026-03-13";

  src = pkgs.fetchFromGitHub {
    owner = "gisikw";
    repo = "barely-game-console";
    rev = "6323fd83f01ef13ab2b22cd716038a98700292e5";
    hash = "sha256-SlWEftIFVeU4Mor8PvxX84c2yuZVYXjnMDR1jCV2yTc=";
  };

  cargoHash = "sha256-9q3Jm3T9nyLuBSPuhmffaiGRqeRIbU6M62NuxYSvFus=";

  nativeBuildInputs = with pkgs; [
    pkg-config
    makeWrapper
  ];

  buildInputs = with pkgs; [
    wayland
    wayland-protocols
    libxkbcommon
    libGL
    vulkan-loader
    xorg.libX11
    xorg.libXcursor
    xorg.libXrandr
    xorg.libXi
  ];

  postInstall = ''
    wrapProgram $out/bin/barely-game-console \
      --prefix LD_LIBRARY_PATH : ${pkgs.lib.makeLibraryPath [
        pkgs.wayland
        pkgs.libxkbcommon
        pkgs.libGL
        pkgs.vulkan-loader
      ]}
  '';

  meta = with pkgs.lib; {
    description = "RFID-powered retro game console launcher";
    homepage = "https://github.com/gisikw/barely-game-console";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
