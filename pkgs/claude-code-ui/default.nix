{ pkgs }:

pkgs.buildNpmPackage rec {
  pname = "claude-code-ui";
  version = "1.12.0";

  src = pkgs.fetchFromGitHub {
    owner = "siteboon";
    repo = "claudecodeui";
    rev = "v${version}";
    hash = "sha256-/fN3MWNR5SenwI/JZFHh2+oKSuKUCLaHf4+rVX7SV5A=";
  };

  npmDepsHash = "sha256-lH2P+2C8zeJLdkSFLZlfDrppuSV7Lf7nKW2by0GFGrg=";

  # Build the frontend
  npmBuildScript = "build";

  # Install server and built frontend
  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib/claude-code-ui
    cp -r server $out/lib/claude-code-ui/
    cp -r dist $out/lib/claude-code-ui/
    cp -r node_modules $out/lib/claude-code-ui/
    cp package.json $out/lib/claude-code-ui/

    mkdir -p $out/bin
    cat > $out/bin/claude-code-ui <<EOF
#!${pkgs.bash}/bin/bash
cd $out/lib/claude-code-ui
exec ${pkgs.nodejs}/bin/node server/index.js "\$@"
EOF
    chmod +x $out/bin/claude-code-ui

    runHook postInstall
  '';

  meta = with pkgs.lib; {
    description = "Web UI for Claude Code";
    homepage = "https://github.com/siteboon/claudecodeui";
    license = licenses.gpl3;
    platforms = platforms.linux;
  };
}
