{ pkgs }:

pkgs.buildNpmPackage rec {
  pname = "slidev";
  version = "52.14.2";

  src = pkgs.fetchzip {
    url = "https://registry.npmjs.org/@slidev/cli/-/cli-${version}.tgz";
    hash = "sha256-WjGz0fnxrkP1Nm/cRpIsCxix18EB8XR5NGVw7PUbW+w=";
  };

  npmDepsHash = "sha256-PhWPzQsEWF7RP9HeTSHKchl4hM2VwmLElW7SN/FWo7o=";

  postPatch = ''
    cp ${./package-lock.json} package-lock.json
  '';

  npmFlags = [ "--legacy-peer-deps" ];

  dontNpmBuild = true;

  meta = with pkgs.lib; {
    description = "Presentation slides for developers";
    homepage = "https://sli.dev";
    license = licenses.mit;
    platforms = platforms.linux;
    mainProgram = "slidev";
  };
}
