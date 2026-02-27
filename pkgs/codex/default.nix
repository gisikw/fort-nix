{ pkgs }:

pkgs.buildNpmPackage rec {
  pname = "codex";
  version = "0.106.0";

  src = pkgs.fetchzip {
    url = "https://registry.npmjs.org/@openai/codex/-/codex-${version}.tgz";
    hash = "sha256-FwrY6BLNR6If3TLEAgYRgr+AZ1LGm2Er2daamxPiYj4=";
  };

  npmDepsHash = "sha256-bh/805OjdI87z6xFqmKJpgJhWBS8bEw7q1ds6AcqnFI=";

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
