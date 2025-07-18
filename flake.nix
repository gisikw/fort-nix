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
            { _module.args.fort = fortConfig; }
          ];
        };

      mkHostConfig = host: hostCfg:
        let
          device = hostCfg.device;
          deviceCfg = fortConfig.devices.${device};
          system = deviceCfg.system;
          current = hostCfg // {
            roles = (hostCfg.roles or []) ++ [ "fort-host" ];
            drivers = hostCfg.drivers or [];
            features = hostCfg.features or [];
            services = hostCfg.services or [];
            device = device;
            host = host;
          };
        in
          nixpkgs.lib.nixosSystem {
            inherit system;
            modules = ([
              disko.nixosModules.disko
              agenix.nixosModules.age
              ./device-profiles/${deviceCfg.profile}/configuration.nix
              ./devices/${device}/hardware-configuration.nix
              {
                _module.args.fort = {
                  config = fortConfig;
                  settings = fortConfig.settings;
                  current = current;
                  host = host;
                  device = device;
                  routes = {};
                };
                networking = {
                  hostName = host;
                  nameservers = [ "ns.${fortConfig.settings.domain}" "1.1.1.1" ];
                };
              }
            ]) ++ (map (name: ./roles/${name}.nix) current.roles)
               ++ (map (name: ./modules/drivers/${name}.nix) current.drivers)
               ++ (map (name: ./modules/features/${name}.nix) current.features)
               ++ (map (name: ./modules/services/${name}.nix) current.services);
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
