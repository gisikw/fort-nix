{
  inputs = {
    root.url = "path:../../../..";
    nixpkgs.follows = "root/nixpkgs";
    disko.follows = "root/disko";
    impermanence.follows = "root/impermanence";
    deploy-rs.follows = "root/deploy-rs";
    agenix.follows = "root/agenix";
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
      impermanence,
      deploy-rs,
      agenix,
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
        ;
      hostDir = ./.;
    };
}
