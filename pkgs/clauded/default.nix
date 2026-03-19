{ pkgs }:

pkgs.buildGoModule {
  pname = "ccd";
  version = "0.1.0";
  src = ./.;
  vendorHash = null; # stdlib only

  # Binary must not contain "claude" in its name or nix store path —
  # Claude Code's Bash tool suppresses output for any command containing
  # that substring.
  postInstall = ''
    mv $out/bin/clauded $out/bin/ccd
  '';
}
