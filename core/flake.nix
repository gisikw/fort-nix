{
  description = "Core box - cluster bootstrap authority for weyr.dev";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      # The core system (what gets installed to NVMe)
      nixosConfigurations.core = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ ./configuration.nix ];
      };

      # The installer ISO (what gets flashed to USB)
      nixosConfigurations.core-installer = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          coreSystem = self.nixosConfigurations.core.config.system.build.toplevel;
        };
        modules = [
          "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
          ./iso.nix
        ];
      };

      packages.${system} = {
        iso = self.nixosConfigurations.core-installer.config.system.build.isoImage;
      };
    };
}
