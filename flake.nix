{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  inputs.disko.url = "github:nix-community/disko";
  inputs.disko.inputs.nixpkgs.follows = "nixpkgs";
  inputs.agenix.url = "github:ryantm/agenix";
  inputs.deploy-rs.url = "github:serokell/deploy-rs";

  outputs =
    { nixpkgs, disko, agenix, deploy-rs, ... }:
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

      mkHostConfig = host: { device, services, ... }:
        let
          deviceDef = configDefs.devices.${device};
          system = deviceDef.system;
          profile = deviceDef.profile;
        in
          nixpkgs.lib.nixosSystem {
            inherit system;
            modules = ([
              disko.nixosModules.disko
              agenix.nixosModules.age
              ./device-profiles/${profile}/configuration.nix
              ./devices/${device}/hardware-configuration.nix
              {
                _module.args.fortPubkey = configDefs.fort.pubkey;
                networking.hostName = host;
              }
            ]) ++ (map (name: ./services/${name}.nix) services);
          };

      nixosConfigurations =
        (nixpkgs.lib.mapAttrs mkDeviceConfig configDefs.devices) //
        (nixpkgs.lib.mapAttrs mkHostConfig configDefs.hosts);

      deploy.nodes = nixpkgs.lib.mapAttrs (host: def: {
        hostname = "<dynamic>";
        sshUser = "root";
        sshOpts = [ "-i" "~/.ssh/fort" ];
        profiles.system = {
          user = "root";
          path = deploy-rs.lib.x86_64-linux.activate.nixos nixosConfigurations.${host};
        };
      }) configDefs.hosts;
    in
    {
      inherit nixosConfigurations;
      inherit deploy;
    };
}
