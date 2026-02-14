{
  inputs = {
    cluster.url = "path:../..";
    nixpkgs.follows = "cluster/nixpkgs";
    agenix.follows = "cluster/agenix";
    nix-darwin.follows = "cluster/nix-darwin";
  };

  outputs =
    {
      self,
      nixpkgs,
      agenix,
      nix-darwin,
      ...
    }:
    import ../../../../common/host.nix {
      inherit
        self
        nixpkgs
        agenix
        nix-darwin
        ;
      hostDir = ./.;
    };
}
