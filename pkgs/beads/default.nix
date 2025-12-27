{ pkgs }:

pkgs.buildGoModule rec {
  pname = "beads";
  version = "0.33.2";

  src = pkgs.fetchFromGitHub {
    owner = "steveyegge";
    repo = "beads";
    rev = "v${version}";
    hash = "sha256-BBsTiq+sSJXqPbdAJ9IugI+IlurEg5rNbHCv2oM0e+M=";
  };

  vendorHash = "sha256-IsHU7IkLK22YTv2DE8lMJ2oEOc9nsFBTW36i81Z58eQ=";

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
