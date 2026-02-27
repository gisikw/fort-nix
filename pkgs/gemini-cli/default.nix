{ pkgs }:

pkgs.buildNpmPackage rec {
  pname = "gemini-cli";
  version = "0.30.0";

  src = pkgs.fetchzip {
    url = "https://registry.npmjs.org/@google/gemini-cli/-/gemini-cli-${version}.tgz";
    hash = "sha256-1z73UYj+m+lzd1hRJh6X0pl7iP6zgt3TTlU825Xsrbw=";
  };

  npmDepsHash = "sha256-lNftuq0hsUoE2nVXcOhM+qZyUV8gYLM1/F4RzyvgdhA=";

  postPatch = ''
    cp ${./package-lock.json} package-lock.json
  '';

  nativeBuildInputs = with pkgs; [ pkg-config python3 ];
  buildInputs = with pkgs; [ libsecret ];

  dontNpmBuild = true;

  meta = with pkgs.lib; {
    description = "Google Gemini CLI - AI agent in your terminal";
    homepage = "https://github.com/google/gemini-cli";
    license = licenses.asl20;
    platforms = platforms.linux;
    mainProgram = "gemini";
  };
}
