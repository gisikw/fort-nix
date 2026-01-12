{
  inputs = {
    cluster.url = "path:../..";
    nixpkgs.follows = "cluster/nixpkgs";
    disko.follows = "cluster/disko";
    impermanence.follows = "cluster/impermanence";
    deploy-rs.follows = "cluster/deploy-rs";
    agenix.follows = "cluster/agenix";
    comin.follows = "cluster/comin";
    home-config.follows = "cluster/home-config";
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
      impermanence,
      deploy-rs,
      agenix,
      comin,
      home-config,
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
        comin
        home-config
        ;
      hostDir = ./.;
    };
}
