{ pkgs }:

pkgs.buildGoModule rec {
  pname = "beads";
  version = "0.47.1";

  src = pkgs.fetchFromGitHub {
    owner = "steveyegge";
    repo = "beads";
    rev = "v${version}";
    hash = "sha256-DwIR/r1TJnpVd/CT1E2OTkAjU7k9/KHbcVwg5zziFVg=";
  };

  vendorHash = "sha256-pY5m5ODRgqghyELRwwxOr+xlW41gtJWLXaW53GlLaFw=";

  subPackages = [ "cmd/bd" ];

  # Tests have flaky integration tests in sandbox
  doCheck = false;

  meta = with pkgs.lib; {
    description = "Distributed, git-backed graph issue tracker for AI agents";
    homepage = "https://github.com/steveyegge/beads";
    license = licenses.mit;
    platforms = platforms.linux ++ platforms.darwin;
  };
}
