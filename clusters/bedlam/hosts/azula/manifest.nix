rec {
  hostName = "azula";
  device = "166401ec-95f9-6543-854d-a8595f97cd63";

  roles = [ ];

  apps = [ ];

  aspects = [ "observable" ];

  module =
    { config, pkgs, ... }:
    {
      config.fort.host = { inherit roles apps aspects; };

      # Office captive-portal survival kit. Azula may need to register on
      # unfamiliar networks before it can fetch anything else, so keep both a
      # graphical browser path and text-mode/debug tools available locally.
      config.services.xserver.enable = true;
      config.services.xserver.displayManager.lightdm.enable = true;
      config.services.xserver.desktopManager.xfce.enable = true;

      config.environment.systemPackages = with pkgs; [
        firefox
        w3m
        lynx
        curl
        wget
        dnsutils
        openssl
        xterm
      ];
    };
}
