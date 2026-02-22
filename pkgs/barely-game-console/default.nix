{ pkgs }:

pkgs.rustPlatform.buildRustPackage rec {
  pname = "barely-game-console";
  version = "0.1.0-unstable-2026-02-22";

  src = pkgs.fetchFromGitHub {
    owner = "gisikw";
    repo = "barely-game-console";
    rev = "b8a8d5770f4c6508a5fff82da1a45101f0f8bda6";
    hash = "sha256-XpBjTCiCWOu7GaRWBiqhJ0ATXdgkGHYTDsD06gOofpQ=";
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
