{ pkgs }:

pkgs.buildNpmPackage rec {
  pname = "claude-code";
  version = "2.1.89";

  src = pkgs.fetchzip {
    url = "https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-${version}.tgz";
    hash = "sha256-FoTm6KDr+8Dzhk4ibZUlU1QLPFdPm/OriUUWqAaFswg=";
  };

  npmDepsHash = "sha256-NI4F5bq0lEuMjLUdkGrml2aOzGbGkdyUckgfeVFEe8o=";

  postPatch = ''
    cp ${./package-lock.json} package-lock.json
  '';

  dontNpmBuild = true;

  env.AUTHORIZED = "1";

  # Disable auto-update and unset DEV (causes WebSocket crash).
  # Patch Claude Code's auto-resume nudges so promptless tool-result resumes use
  # neutral tool-result semantics instead of generic user-demand semantics.
  postInstall = ''
    substituteInPlace $out/lib/node_modules/@anthropic-ai/claude-code/cli.js \
      --replace-fail \
        'value:"Continue from where you left off.",uuid:zP(),isMeta:!0' \
        'value:"<tool-result>Tool call complete. Results are above.</tool-result>",uuid:zP(),isMeta:!0'

    substituteInPlace $out/lib/node_modules/@anthropic-ai/claude-code/cli.js \
      --replace-fail \
        'if(!q&&!f&&!X&&!W){process.stderr.write' \
        'if(!q&&!f&&!X&&!W&&!(D&&process.env.CLAUDE_CODE_PROMPTLESS_TOOL_RESULT_RESUME)){process.stderr.write'

    substituteInPlace $out/lib/node_modules/@anthropic-ai/claude-code/cli.js \
      --replace-fail \
        'if(M)N(`[print.ts] Auto-resuming deferred tool: ''${M.toolName} (''${M.toolUseID})`),TJ({mode:"prompt",value:"<tool-result>Tool call complete. Results are above.</tool-result>",uuid:zP(),isMeta:!0}),V6();let y6=null;' \
        'if(M)N(`[print.ts] Auto-resuming deferred tool: ''${M.toolName} (''${M.toolUseID})`),TJ({mode:"prompt",value:"<tool-result>Tool call complete. Results are above.</tool-result>",uuid:zP(),isMeta:!0}),V6();if(!M&&process.env.CLAUDE_CODE_PROMPTLESS_TOOL_RESULT_RESUME)N("[print.ts] Auto-resuming non-deferred tool result"),TJ({mode:"prompt",value:"<tool-result>Tool call complete. Results are above.</tool-result>",uuid:zP(),isMeta:!0}),V6();let y6=null;'

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
