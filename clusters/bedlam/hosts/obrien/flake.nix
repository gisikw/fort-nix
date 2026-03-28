{
  inputs = {
    cluster.url = "path:../..";
    nixpkgs.follows = "cluster/nixpkgs";
    agenix.follows = "cluster/agenix";
    sops-nix.follows = "cluster/sops-nix";
    nix-darwin.follows = "cluster/nix-darwin";
  };

  outputs =
    {
      self,
      nixpkgs,
      agenix,
      sops-nix,
      nix-darwin,
      ...
    }:
    import ../../../../common/host.nix {
      inherit
        self
        nixpkgs
        agenix
        sops-nix
        nix-darwin
        ;
      hostDir = ./.;
    };
}
