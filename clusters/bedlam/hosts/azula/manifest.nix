rec {
  hostName = "azula";
  device = "166401ec-95f9-6543-854d-a8595f97cd63";

  roles = [ ];

  apps = [
    {
      name = "llama-server";
      accelerator = "cpu";
      subdomain = "llama2";
      serviceName = "llama2";
      contextSize = 131072;
      enableMtp = true;
      model = {
        repo = "unsloth/Qwen3.6-35B-A3B-MTP-GGUF";
        file = "Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf";
        sha256 = "55983c5a75a1ab969824077b3bb3de4146e82a9234072b48ad4e8f92ad3fe9f1";
      };
    }
  ];

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
