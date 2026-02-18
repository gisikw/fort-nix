rec {
  hostName = "ratched";
  device = "d62dc783-93c7-d046-aff8-a8595ffcce8e";

  roles = [ ];

  apps = [
    {
      name = "flatnotes";
      subdomain = "exocortex";
      dataDir = "/home/dev/Projects/exocortex/notes";
      dataUser = "dev";
      dataGroup = "users";
    }
    "vdirsyncer-auth"
    "radicale"
    "punchlist"
    "apple-dist"
    "conduit"
  ];

  aspects = [
    "mesh"
    "observable"
    {
      name = "dev-sandbox";
      accessKeys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGBsPj4lG8wP2gfgU5akZ05GrMy55syzvI0MEpiNFQ8t dev-sandbox-ssh"
      ];
    }
    "gitops"
  ];

  module =
    { config, pkgs, ... }:
    {
      config.fort.host = {
        inherit roles apps aspects;
        runtimePackages = [
          { repo = "infra/bz"; }
          { repo = "infra/unum"; }
        ];
      };

      config.systemd.tmpfiles.rules = [
        "d /home/dev/Projects/exocortex 0755 dev users -"
        # notes subdir owned by flatnotes app via dataUser/dataGroup params
      ];
    };
}
