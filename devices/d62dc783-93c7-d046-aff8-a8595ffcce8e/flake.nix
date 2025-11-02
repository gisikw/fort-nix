{
  inputs = {
    root.url = "path:../../";
    nixpkgs.follows = "root/nixpkgs";
    disko.follows = "root/disko";
    impermanence.follows = "root/impermanence";
  };

  outputs =
    {
      self, 
      nixpkgs, 
      disko, 
      impermanence,
      ...
    }:
    import ../../common/device.nix {
      inherit self nixpkgs disko impermanence;
      deviceDir = ./.;
    };
}
