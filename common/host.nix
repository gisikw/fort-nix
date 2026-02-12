args@{
  self,
  nixpkgs,
  hostDir,
  agenix,
  # NixOS-specific inputs (optional on darwin)
  disko ? null,
  impermanence ? null,
  deploy-rs ? null,
  comin ? null,
  # Darwin-specific inputs (optional on nixos)
  nix-darwin ? null,
  # Cluster-specific inputs (optional)
  home-config ? null,
  ...
}:
let
  cluster = import ../common/cluster-context.nix { };
  rootManifest = cluster.manifest;
  settings = rootManifest.fortConfig.settings;

  hostManifest = import (hostDir + "/manifest.nix");
  deviceManifest = import (cluster.devicesDir + "/${hostManifest.device}/manifest.nix");
  deviceProfileManifest = import ../device-profiles/${deviceManifest.profile}/manifest.nix;

  platform = deviceProfileManifest.platform or "nixos";

  flatMap = f: xs: builtins.concatLists (map f xs);

  # Derive SSH keys for root access from principals with "root" role
  # Only SSH keys work for authorized_keys (filter out age keys)
  isSSHKey = k: builtins.substring 0 4 k == "ssh-";
  principalsWithRoot = builtins.filter
    (p: builtins.elem "root" (p.roles or [ ]))
    (builtins.attrValues settings.principals);
  rootAuthorizedKeys = builtins.filter isSSHKey (map (p: p.publicKey) principalsWithRoot);
  roles = map (r: import ../roles/${r}.nix) hostManifest.roles;
  # Default aspects that every host gets
  defaultAspects = [ "host-status" ];
  allAspects = defaultAspects ++ hostManifest.aspects ++ flatMap (r: r.aspects or [ ]) roles;
  allApps = hostManifest.apps ++ flatMap (r: r.apps or [ ]) roles;

  # Extra inputs to pass through to apps/aspects
  extraInputs = {
    inherit home-config;
  };

  mkModule =
    type: mod:
    if builtins.isString mod then
      import ../${type}s/${mod} {
        inherit
          rootManifest
          hostManifest
          deviceManifest
          deviceProfileManifest
          cluster
          extraInputs
          ;
      }

    else if builtins.isFunction mod then
      mod {
        inherit
          rootManifest
          hostManifest
          deviceManifest
          deviceProfileManifest
          cluster
          extraInputs
          ;
      }

    else if builtins.isAttrs mod && mod ? name then
      import ../${type}s/${mod.name} (
        {
          inherit
            rootManifest
            hostManifest
            deviceManifest
            deviceProfileManifest
            cluster
            extraInputs
            ;
        }
        // (builtins.removeAttrs mod [ "name" ])
      )

    else
      throw "Invalid ${type} spec: expected string, function, or { name = ... } attrset, got ${builtins.typeOf mod}";

  # Pre-resolve app and aspect modules for the platform builder
  appModules = map (mkModule "app") allApps;
  aspectModules = map (mkModule "aspect") allAspects;

  # Shared context passed to platform builders
  sharedContext = {
    inherit
      self
      nixpkgs
      agenix
      hostManifest
      deviceManifest
      deviceProfileManifest
      rootManifest
      cluster
      rootAuthorizedKeys
      appModules
      aspectModules
      extraInputs
      ;
  };

  platformBuilder =
    if platform == "nixos" then
      import ./platforms/nixos.nix (sharedContext // {
        inherit disko impermanence deploy-rs comin;
      })
    else if platform == "darwin" then
      import ./platforms/darwin.nix (sharedContext // {
        inherit nix-darwin;
      })
    else
      throw "Unknown platform '${platform}' in device profile for ${hostManifest.hostName}. Expected 'nixos' or 'darwin'.";
in
platformBuilder
