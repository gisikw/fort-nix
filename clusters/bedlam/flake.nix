{
  inputs = {
    root.url = "path:./../..";
    nixpkgs.follows = "root/nixpkgs";
    disko.follows = "root/disko";
    impermanence.follows = "root/impermanence";
    agenix.follows = "root/agenix";
    deploy-rs.follows = "root/deploy-rs";
    comin.follows = "root/comin";

    # Cluster-specific inputs
    home-config.url = "github:gisikw/config";
  };

  outputs = { ... }: { };
}
