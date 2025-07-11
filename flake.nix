{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  inputs.disko.url = "github:nix-community/disko";
  inputs.disko.inputs.nixpkgs.follows = "nixpkgs";
  inputs.agenix.url = "github:ryantm/agenix";

  outputs =
    { nixpkgs, disko, agenix, ... }:
    let
      configFile = ./config.toml;
      configDefs = builtins.fromTOML (builtins.readFile configFile);

      mkDeviceConfig = uuid: { system, profile, ... }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            disko.nixosModules.disko
            agenix.nixosModules.age
            ./device-profiles/${profile}/configuration.nix
            ./devices/${uuid}/hardware-configuration.nix
            {
              _module.args.fortPubkey = configDefs.fort.pubkey;
            }
          ];
        };

      nixosConfigurations = nixpkgs.lib.mapAttrs mkDeviceConfig configDefs.devices;
    in
    {
      inherit nixosConfigurations;
    };
}
