{
  inputs = {
    cluster.url = "path:../..";
    nixpkgs.follows = "cluster/nixpkgs";
    disko.follows = "cluster/disko";
    impermanence.follows = "cluster/impermanence";
  };

  outputs =
    {
      self, 
      nixpkgs, 
      disko, 
      impermanence,
      ...
    }:
    import ../../../../common/device.nix {
      inherit self nixpkgs disko impermanence;
      deviceDir = ./.;
    };
}
