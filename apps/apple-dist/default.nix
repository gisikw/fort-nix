{ ... }:
{ pkgs, config, lib, ... }:
let
  domain = config.fort.cluster.settings.domain;
  dataDir = "/var/lib/apple-dist";
  port = 8710;

  indexHtml = pkgs.writeText "index.html" ''
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>App Distribution</title>
      <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
          font-family: -apple-system, BlinkMacSystemFont, sans-serif;
          background: #1a1a2e;
          color: #e0e0e0;
          padding: 2rem;
          min-height: 100vh;
        }
        h1 { color: #ff6188; margin-bottom: 1.5rem; }
        .apps { display: flex; flex-direction: column; gap: 1rem; max-width: 600px; }
        .app {
          background: #2d2a2e;
          border-radius: 12px;
          padding: 1.25rem;
          display: flex;
          align-items: center;
          gap: 1rem;
        }
        .app-name { font-size: 1.1rem; font-weight: 600; flex: 1; }
        .app-meta { font-size: 0.8rem; color: #888; }
        .install-btn {
          background: #ff6188;
          color: #fff;
          border: none;
          border-radius: 8px;
          padding: 0.6rem 1.2rem;
          font-size: 1rem;
          font-weight: 600;
          text-decoration: none;
          cursor: pointer;
          white-space: nowrap;
        }
        .install-btn:hover { background: #ff7e9a; }
        .empty { color: #888; font-style: italic; }
      </style>
    </head>
    <body>
      <h1>App Distribution</h1>
      <div class="apps" id="apps">
        <div class="empty">Loading...</div>
      </div>
      <script>
        const base = location.origin;
        fetch('./ipas/')
          .then(r => r.json())
          .then(files => {
            const plists = files.filter(f => f.name.endsWith('.plist'));
            const container = document.getElementById('apps');
            if (plists.length === 0) {
              container.innerHTML = '<div class="empty">No apps available yet.</div>';
              return;
            }
            container.innerHTML = plists.map(f => {
              const name = f.name.replace(".plist", "");
              const plistUrl = base + '/ipas/' + f.name;
              const itmsUrl = 'itms-services://?action=download-manifest&url=' + encodeURIComponent(plistUrl);
              const date = new Date(f.mtime);
              const dateStr = date.toLocaleDateString() + ' ' + date.toLocaleTimeString();
              return '<div class="app">' +
                '<div><div class="app-name">' + name + '</div>' +
                '<div class="app-meta">' + dateStr + '</div></div>' +
                '<a class="install-btn" href="' + itmsUrl + '">Install</a>' +
                '</div>';
            }).join("");
          })
          .catch(() => {
            document.getElementById('apps').innerHTML =
              '<div class="empty">Failed to load apps.</div>';
          });
      </script>
    </body>
    </html>
  '';

  staticRoot = pkgs.runCommand "apple-dist-static" {} ''
    mkdir -p $out
    cp ${indexHtml} $out/index.html
  '';
in
{
  systemd.tmpfiles.rules = [
    "d ${dataDir} 0755 dev users -"
    "d ${dataDir}/ipas 0755 dev users -"
  ];

  # Internal nginx server block as the backend for the gatekeeper proxy.
  # Serves static index.html at / and autoindex JSON at /ipas/.
  services.nginx.appendHttpConfig = ''
    server {
      listen 127.0.0.1:${toString port};
      root ${staticRoot};

      location / {
        try_files $uri $uri/ =404;
      }

      location /ipas/ {
        alias ${dataDir}/ipas/;
        autoindex on;
        autoindex_format json;
        types {
          application/octet-stream ipa;
          text/xml plist;
        }
      }
    }
  '';

  fort.cluster.services = [
    {
      name = "apple-dist";
      subdomain = "apple";
      port = port;
      visibility = "public";
      sso = {
        mode = "gatekeeper";
        vpnBypass = true;
        groups = [ "admin" ];
      };
      health.enabled = false;
    }
  ];
}
