{ pkgs }:

pkgs.buildNpmPackage rec {
  pname = "pi-coding-agent";
  version = "0.84.2";

  src = pkgs.fetchzip {
    url = "https://registry.npmjs.org/@earendil-works/pi-coding-agent/-/pi-coding-agent-${version}.tgz";
    hash = "sha256-9dv6prGh2inmg4pEFkC8OsU/Eh18L3wCvcUde5rOMdc=";
  };

  npmDepsHash = "sha256-bqq2urTpODdRQ1vKY1Gkf4KkQcMP1mStU6xjblI8V2k=";

  postPatch = ''
    rm npm-shrinkwrap.json
    cp ${./package-lock.json} package-lock.json
  '';

  npmFlags = [ "--legacy-peer-deps" ];

  dontNpmBuild = true;

  meta = with pkgs.lib; {
    description = "pi - a coding agent for your terminal";
    homepage = "https://github.com/mariozechner/pi-coding-agent";
    license = licenses.mit;
    platforms = platforms.linux;
    mainProgram = "pi";
  };
}
