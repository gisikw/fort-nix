{
  inputs = {
    cluster.url = "path:../..";
    nixpkgs.follows = "cluster/nixpkgs";
    disko.follows = "cluster/disko";
    impermanence.follows = "cluster/impermanence";
    deploy-rs.follows = "cluster/deploy-rs";
    agenix.follows = "cluster/agenix";
    sops-nix.follows = "cluster/sops-nix";
    comin.follows = "cluster/comin";
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
      impermanence,
      deploy-rs,
      agenix,
      sops-nix,
      comin,
      ...
    }:
    import ../../../../common/host.nix {
      inherit
        self
        nixpkgs
        disko
        impermanence
        deploy-rs
        agenix
        sops-nix
        comin
        ;
      hostDir = ./.;
    };
}
