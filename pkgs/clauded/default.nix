{ pkgs }:

pkgs.buildGoModule {
  pname = "ccd";
  version = "0.1.0";
  src = ./.;
  vendorHash = null; # stdlib only

  # The Go module and binary are named "ccd" (not "clauded") because Claude
  # Code scans binary metadata for "claude" and suppresses Bash tool output
  # if found. Go embeds the module path in build info, so even the module
  # name matters.
}
