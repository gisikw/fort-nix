{
  inputs = {
    cluster.url = "path:../..";
    nixpkgs.follows = "cluster/nixpkgs";
    sops-nix.follows = "cluster/sops-nix";
    nix-darwin.follows = "cluster/nix-darwin";
  };

  outputs =
    {
      self,
      nixpkgs,
      sops-nix,
      nix-darwin,
      ...
    }:
    import ../../../../common/host.nix {
      inherit
        self
        nixpkgs
        sops-nix
        nix-darwin
        ;
      hostDir = ./.;
    };
}
