{ pkgs }:

pkgs.buildNpmPackage rec {
  pname = "codex";
  version = "0.144.0";

  src = pkgs.fetchzip {
    url = "https://registry.npmjs.org/@openai/codex/-/codex-${version}.tgz";
    hash = "sha256-RJDXSUlR0cB5haLgD0ICAZV5NTGVvaGusPvLi2LqoLU=";
  };

  npmDepsHash = "sha256-G3d1qOjq0S0/MR+/BHwmErevQ/JovV+gf9WsyiLfeKA=";

  postPatch = ''
    cp ${./package-lock.json} package-lock.json
  '';

  dontNpmBuild = true;

  meta = with pkgs.lib; {
    description = "Lightweight coding agent that runs in your terminal";
    homepage = "https://github.com/openai/codex";
    license = licenses.asl20;
    platforms = platforms.linux;
    mainProgram = "codex";
  };
}
