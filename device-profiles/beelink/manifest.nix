{
  system = "x86_64-linux";
  impermanent = true;
  module =
    { modulesPath, config, ... }:
    {
      imports = [
        (modulesPath + "/installer/scan/not-detected.nix")
        (modulesPath + "/profiles/qemu-guest.nix")
        ./disk-config.nix
      ];

      boot.loader.grub = {
        efiSupport = true;
        efiInstallAsRemovable = true;
        devices = [ "nodev" ];
      };

      services.openssh.enable = true;

      users.mutableUsers = false;
      users.users.root.initialPassword = "hunter2";
      users.users.root.openssh.authorizedKeys.keys = [ config.fort.settings.sshKey.publicKey ];

      fileSystems."/persist/system".neededForBoot = true;
      fileSystems."/" = {
        fsType = "tmpfs";
        options = [ "mode=755" ];
      };
    };
}
