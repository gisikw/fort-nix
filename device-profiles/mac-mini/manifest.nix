{
  platform = "darwin";
  system = "aarch64-darwin";
  module =
    { config, lib, pkgs, ... }:
    {
      # Power management: headless server defaults
      power.sleep.display = "never";
      power.sleep.computer = "never";
      power.sleep.harddisk = "never";

      system.defaults = {
        # Disable auto-updates (managed by nix-darwin rebuild)
        SoftwareUpdate.AutomaticallyInstallMacOSUpdates = false;

        # Disable UI chrome irrelevant on a headless box
        dock.autohide = true;
      };

      # pmset settings nix-darwin doesn't expose natively
      system.activationScripts.postActivation.text = ''
        # Restart on power failure
        pmset -a autorestart 1
        # Restart on freeze (kernel watchdog)
        pmset -a RestartAfterFreeze 1
        # Wake on network access (remote management)
        pmset -a womp 1
      '';
    };
}
