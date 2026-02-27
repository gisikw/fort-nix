{ pkgs }:

pkgs.buildNpmPackage rec {
  pname = "pi-coding-agent";
  version = "0.55.1";

  src = pkgs.fetchzip {
    url = "https://registry.npmjs.org/@mariozechner/pi-coding-agent/-/pi-coding-agent-${version}.tgz";
    hash = "sha256-Qjuv8GzMdENnNwX5xo/Yfh4aRhn7N7pIlXrkeoHGJMk=";
  };

  npmDepsHash = "sha256-OpN1d6OA5x0m+38YVSMTSdiFvUAtlFtRGJ/6eSaKcYw=";

  postPatch = ''
    cp ${./package-lock.json} package-lock.json
  '';

  dontNpmBuild = true;

  meta = with pkgs.lib; {
    description = "pi - a coding agent for your terminal";
    homepage = "https://github.com/mariozechner/pi-coding-agent";
    license = licenses.mit;
    platforms = platforms.linux;
    mainProgram = "pi";
  };
}
