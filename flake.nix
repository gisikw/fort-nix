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
      fortConfig = builtins.fromTOML (builtins.readFile configFile);

      mkDeviceConfig = uuid: { system, profile, ... }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            disko.nixosModules.disko
            agenix.nixosModules.age
            ./device-profiles/${profile}/configuration.nix
            ./devices/${uuid}/hardware-configuration.nix
            { _module.args.fortConfig = fortConfig; }
          ];
        };

      mkHostConfig = fortHost: { 
        device, 
        roles ? [], 
        drivers ? [], 
        features ? [],
        services ? [], 
        ... 
      }:
        let
          deviceDef = fortConfig.devices.${device};
          system = deviceDef.system;
          profile = deviceDef.profile;
          hostRoles = roles ++ [ "fort-host" ];
        in
          nixpkgs.lib.nixosSystem {
            inherit system;
            modules = ([
              disko.nixosModules.disko
              agenix.nixosModules.age
              ./device-profiles/${profile}/configuration.nix
              ./devices/${device}/hardware-configuration.nix
              {
                _module.args = {
                  fortConfig = fortConfig;
                  fortHost = fortHost;
                  fortDevice = fortConfig.hosts.${fortHost}.device;
                };
                networking = {
                  hostName = fortHost;
                  nameservers = [ "ns.${fortConfig.fort.domain}" "1.1.1.1" ];
                };
              }
            ]) ++ (map (name: ./roles/${name}.nix) hostRoles)
               ++ (map (name: ./modules/drivers/${name}.nix) drivers)
               ++ (map (name: ./modules/features/${name}.nix) features)
               ++ (map (name: ./modules/services/${name}.nix) services);
          };

      nixosConfigurations =
        (nixpkgs.lib.mapAttrs mkDeviceConfig fortConfig.devices) //
        (nixpkgs.lib.mapAttrs mkHostConfig fortConfig.hosts);

      deploy.nodes = nixpkgs.lib.mapAttrs (host: def: {
        hostname = "<dynamic>";
        sshUser = "root";
        sshOpts = [ "-i" "~/.ssh/fort" ];
        profiles.system = {
          user = "root";
          path = deploy-rs.lib.x86_64-linux.activate.nixos nixosConfigurations.${host};
        };
      }) fortConfig.hosts;
    in
    {
      inherit nixosConfigurations;
      inherit deploy;
    };
}
