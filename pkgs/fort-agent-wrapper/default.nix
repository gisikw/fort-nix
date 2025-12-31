{ pkgs }:

pkgs.buildGoModule {
  pname = "fort-agent-wrapper";
  version = "0.1.0";

  src = ./.;

  # No external dependencies, just stdlib
  vendorHash = null;

  # Ensure ssh-keygen is available at runtime
  nativeBuildInputs = [ pkgs.makeWrapper ];

  postInstall = ''
    wrapProgram $out/bin/fort-agent-wrapper \
      --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.openssh ]}
  '';

  meta = with pkgs.lib; {
    description = "FastCGI wrapper for fort-agent control plane";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
