{ pkgs }:

pkgs.buildNpmPackage rec {
  pname = "claude-code";
  version = "2.1.37";

  src = pkgs.fetchzip {
    url = "https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-${version}.tgz";
    hash = "sha256-ijyZCT4LEEtXWOBds8WzizcfED9hVgaJByygJ4P4Yss=";
  };

  npmDepsHash = "sha256-2if3LsTEnC2OQjEgojqgzs8YOXdpoqJijEmVlxmEfzw=";

  postPatch = ''
    cp ${./package-lock.json} package-lock.json
  '';

  dontNpmBuild = true;

  env.AUTHORIZED = "1";

  # Disable auto-update and unset DEV (causes WebSocket crash)
  postInstall = ''
    wrapProgram $out/bin/claude \
      --set DISABLE_AUTOUPDATER 1 \
      --unset DEV
  '';

  meta = with pkgs.lib; {
    description = "Agentic coding tool that lives in your terminal";
    homepage = "https://github.com/anthropics/claude-code";
    license = licenses.unfree;
    platforms = platforms.linux;
    mainProgram = "claude";
  };
}
