{ rootManifest, ... }:
{ config, lib, pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
in
{
  services.atticd = {
    enable = true;

    # Environment file containing ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64
    environmentFile = config.age.secrets.attic-server-token.path;

    settings = {
      listen = "[::]:8080";

      # Use local SQLite database (persisted via /var/lib)
      database.url = "sqlite:///var/lib/atticd/server.db?mode=rwc";

      # Local storage backend
      storage = {
        type = "local";
        path = "/var/lib/atticd/storage";
      };

      # Chunking settings for deduplication
      chunking = {
        nar-size-threshold = 65536; # 64 KiB
        min-size = 16384; # 16 KiB
        avg-size = 65536; # 64 KiB
        max-size = 262144; # 256 KiB
      };

      # Garbage collection
      garbage-collection = {
        interval = "24h";
        default-retention-period = "30d";
      };

      # Use zstd compression
      compression = {
        type = "zstd";
      };
    };
  };

  # Declare the secret
  age.secrets.attic-server-token = {
    file = ./attic-server-token.age;
    owner = "atticd";
    group = "atticd";
  };

  # Expose via reverse proxy
  fortCluster.exposedServices = [
    {
      name = "attic";
      subdomain = "cache";
      port = 8080;
      visibility = "vpn"; # Cache access is token-based, VPN-only for now
    }
  ];
}
