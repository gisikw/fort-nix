{ pkgs, gitPath ? "${pkgs.git}/bin/git", cominPath ? "${pkgs.comin}/bin/comin" }:

pkgs.buildGoModule {
  pname = "deploy-provider";
  version = "0.1.0";

  src = ./.;

  # No external dependencies, just stdlib
  vendorHash = null;

  # Inject paths at build time
  ldflags = [
    "-X main.gitPath=${gitPath}"
    "-X main.cominPath=${cominPath}"
  ];

  meta = with pkgs.lib; {
    description = "Deploy handler for fort control plane";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
