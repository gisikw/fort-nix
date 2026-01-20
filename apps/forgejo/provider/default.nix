{ pkgs, forgejoPackage }:

pkgs.buildGoModule {
  pname = "git-token-provider";
  version = "0.1.0";

  src = ./.;

  # No external dependencies, just stdlib
  vendorHash = null;

  # Inject paths at build time via ldflags
  ldflags = [
    "-X main.defaultForgejoPackage=${forgejoPackage}"
    "-X main.defaultSuPath=${pkgs.su}/bin/su"
    "-X main.defaultSqlite3Path=${pkgs.sqlite}/bin/sqlite3"
  ];

  # Go names binary after directory (provider), rename to match capability
  postInstall = ''
    mv $out/bin/provider $out/bin/git-token-provider
  '';

  meta = with pkgs.lib; {
    description = "Git token generation handler for Forgejo";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
