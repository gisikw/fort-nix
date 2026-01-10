{ pkgs }:

pkgs.buildGoModule {
  pname = "fort-provider";
  version = "0.1.0";

  src = ./.;

  # No external dependencies, just stdlib
  vendorHash = null;

  # Ensure ssh-keygen is available at runtime
  nativeBuildInputs = [ pkgs.makeWrapper ];

  postInstall = ''
    wrapProgram $out/bin/fort-provider \
      --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.openssh ]}
  '';

  meta = with pkgs.lib; {
    description = "Fort control plane provider (FastCGI)";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
