{ pkgs }:

pkgs.buildGoModule {
  pname = "fort-overlay-manager";
  version = "0.1.0";
  src = ./.;
  vendorHash = null;

  nativeBuildInputs = [ pkgs.makeWrapper ];

  postInstall = ''
    wrapProgram $out/bin/fort-overlay-manager \
      --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.nix pkgs.systemd ]}
  '';
}
