{ ... }: {
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  imports = [
    ../modules/fort/announce.nix
    ../modules/fort/webstatus.nix
    ../modules/fort/reverse-proxy.nix
  ];
}
