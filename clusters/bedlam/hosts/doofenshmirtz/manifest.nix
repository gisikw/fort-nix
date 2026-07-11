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

  overlays = { };

  module =
    { config, ... }:
    {
      config.fort.host = { inherit roles apps aspects; };
    };
}
