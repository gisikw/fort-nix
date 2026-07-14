{
  description = "Fort unattended provisioning boot image";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      secretFile = builtins.getEnv "FORT_BOOTSTRAP_SECRET_FILE";
      bootstrapSecret =
        if secretFile == "" then
          throw "Set FORT_BOOTSTRAP_SECRET_FILE to a file containing the USB fleet credential"
        else builtins.readFile secretFile;
      provisionURL = let value = builtins.getEnv "FORT_PROVISION_URL"; in
        if value == "" then "https://provision.gisi.network" else value;
    in {
      nixosConfigurations.fort-autoprovision = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit bootstrapSecret provisionURL; };
        modules = [
          "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
          ./iso.nix
        ];
      };

      packages.${system}.default =
        self.nixosConfigurations.fort-autoprovision.config.system.build.isoImage;
    };
}
