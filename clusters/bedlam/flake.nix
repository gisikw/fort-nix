{
  inputs = {
    root.url = "path:./../..";
    nixpkgs.follows = "root/nixpkgs";
    disko.follows = "root/disko";
    impermanence.follows = "root/impermanence";
    deploy-rs.follows = "root/deploy-rs";
    sops-nix.follows = "root/sops-nix";
    nix-darwin.follows = "root/nix-darwin";

    # Cluster-specific inputs
    home-config.url = "github:gisikw/config";
  };

  outputs = { ... }: { };
}
