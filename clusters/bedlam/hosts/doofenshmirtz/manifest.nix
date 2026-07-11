rec {
  hostName = "doofenshmirtz";
  device = "32d93323-a88f-d543-a0b7-08b4d2e63f07";

  roles = [ ];

  apps = [ ];

  aspects = [
    "mesh"
    "observable"
    { name = "gitops"; manualDeploy = true; }
    {
      # TV boots into the Chore Galaxy kiosk; jellyfin is a planet app the
      # galaxy backend launches (and the session falls back to directly if
      # the galaxy is down). Parent admin surface over the mesh:
      # http://doofenshmirtz.fort.<domain>:8600/admin/. Seeds are one-time
      # copies; live state in /var/lib/chore-galaxy stays hand-editable
      # (the backend hot-reloads edits).
      name = "media-kiosk";
      galaxy = {
        port = 8600;
        stateSeed = ./galaxy-seed/state.json;
        launchersSeed = ./galaxy-seed/launchers.json;
      };
    }
    "agent-debug"
  ];

  overlays = {
    # Backend + launcher for the media-kiosk galaxy session. Published by
    # infra/chore-galaxy CI (attic + overlay-registry); overlay.nix in that
    # repo defines the service (runs as kids with the cage session's Wayland
    # env) and an http health check. Keep port in sync with the media-kiosk
    # galaxy.port above; dataDir must match the aspect's seed rules.
    chore-galaxy = {
      package = "infra/chore-galaxy";
      config = {
        port = "8600";
        # Second listener serving the parent admin UI at / — what the
        # choregalaxy vhost below proxies to (the URL lands on admin
        # directly, no /admin prefix to strip).
        adminPort = "8601";
        dataDir = "/var/lib/chore-galaxy";
        user = "kids";
        group = "users";
        runtimeDir = "/run/user/1000";
        waylandDisplay = "wayland-0";
      };
      # https://choregalaxy.<domain> on the mesh (visibility defaults to
      # "vpn"; the admin surface has no auth of its own, so keep it there).
      expose = {
        subdomain = "choregalaxy";
        port = 8601;
      };
    };
  };

  module =
    { config, ... }:
    {
      config.fort.host = { inherit roles apps aspects; };
    };
}
