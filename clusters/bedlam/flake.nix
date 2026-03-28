{
  inputs = {
    root.url = "path:./../..";
    nixpkgs.follows = "root/nixpkgs";
    disko.follows = "root/disko";
    impermanence.follows = "root/impermanence";
    agenix.follows = "root/agenix";
    deploy-rs.follows = "root/deploy-rs";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    comin.follows = "root/comin";
    nix-darwin.follows = "root/nix-darwin";

    # Cluster-specific inputs
    home-config.url = "github:gisikw/config";
  };

  outputs = { ... }: { };
}
