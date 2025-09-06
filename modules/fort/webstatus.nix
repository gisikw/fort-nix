{ config, pkgs, lib, fort, ... }:

let
  html = pkgs.writeText "index.html" ''
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8" />
      <title>Device Status</title>
      <meta name="viewport" content="width=device-width, initial-scale=1.0" />
      <link rel="icon" type="image/svg+xml" href="data:image/svg+xml;base64,PHN2ZyB3aWR0aD0iMzIiIGhlaWdodD0iMzIiIHZpZXdCb3g9IjAgMCAzMiAzMiIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIj4KICA8cmVjdCB3aWR0aD0iMzIiIGhlaWdodD0iMzIiIGZpbGw9IiNmZmYiLz4KICA8cmVjdCB4PSIxIiB5PSIxOSIgd2lkdGg9IjMwIiBoZWlnaHQ9IjEyIiBmaWxsPSIjY2NjIi8+CiAgPHJlY3QgeD0iNiIgeT0iMTIiIHdpZHRoPSI0IiBoZWlnaHQ9IjciIGZpbGw9IiM2NjYiLz4KICA8cmVjdCB4PSIxMiIgeT0iOCIgd2lkdGg9IjgiIGhlaWdodD0iMTEiIGZpbGw9IiM2NjYiLz4KICA8cmVjdCB4PSIyNCIgeT0iMTIiIHdpZHRoPSI0IiBoZWlnaHQ9IjciIGZpbGw9IiM2NjYiLz4KICA8cmVjdCB4PSIxMiIgeT0iMiIgd2lkdGg9IjMiIGhlaWdodD0iNiIgZmlsbD0iIzQ0NCIvPgogIDxyZWN0IHg9IjE3IiB5PSIyIiB3aWR0aD0iMyIgaGVpZ2h0PSI2IiBmaWxsPSIjNDQ0Ii8+Cjwvc3ZnPg==">
      <style>
        * { box-sizing: border-box; }
        body {
          margin: 0;
          font-family: system-ui, sans-serif;
          background: #111;
          color: #eee;
          display: flex;
          align-items: center;
          justify-content: center;
          min-height: 100vh;
          flex-direction: column;
        }
        h1 {
          font-size: 2rem;
          margin-bottom: 1rem;
          color: #0ff;
        }
        pre {
          background: #222;
          padding: 1rem;
          border-radius: 8px;
          max-width: 90vw;
          overflow-x: auto;
          font-family: monospace;
          font-size: 0.9rem;
          line-height: 1.4;
        }
      </style>
    </head>
    <body>
      <h1 id="hostname">Device</h1>
      <pre id="info">Loading...</pre>
      <script>
        const elInfo = document.getElementById('info');
        const elHost = document.getElementById('hostname');

        async function refresh() {
          try {
            const res = await fetch('/status.json');
            const data = await res.json();
            elInfo.textContent = JSON.stringify(data, null, 2);
            elHost.textContent = data.host || 'Device';
          } catch {
            elInfo.textContent = 'Failed to load status.';
          }
        }

        let raf;
        function loop() {
          refresh();
          raf = requestAnimationFrame(() => setTimeout(loop, 2000));
        }

        window.addEventListener('focus', loop);
        window.addEventListener('blur', () => cancelAnimationFrame(raf));

        loop();
      </script>
    </body>
    </html>
  '';

  statusScript = pkgs.writeShellScript "generate-status" ''
    set -eo pipefail

    uptime=$(${pkgs.procps}/bin/uptime -p)
    load=$(cut -d ' ' -f 1-3 /proc/loadavg)
    mem=$(${pkgs.procps}/bin/free -h | ${pkgs.gawk}/bin/awk '/Mem:/ { print $3 "/" $2 }')
    disk=$(${pkgs.coreutils}/bin/df -h / | ${pkgs.gawk}/bin/awk 'END { print $3 "/" $2 }')

    echo "{ \"host\": \"${fort.host}\", \"uuid\": \"${fort.device}\", \"loadavg\": \"$load\", \"uptime\": \"$uptime\", \"mem\": \"$mem\", \"disk\": \"$disk\" }" > /var/www/webstatus/status.json
  '';
in {
  config = {
    fort.routes.webstatus = {
      subdomain = [ "${fort.device}.devices" "${fort.host}.hosts" ];
      port = 48484;
    };

    systemd.services.webstatus-generate = {
      description = "Generate webstatus.json";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${statusScript}";
      };
    };

    systemd.timers.webstatus-generate = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5s";
        OnUnitActiveSec = "1s";
        Unit = "webstatus-generate.service";
      };
    };

    systemd.services.webstatus-server = {
      description = "Serve basic webstatus dashboard";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        WorkingDirectory = "/var/www/webstatus";
        ExecStart = "${pkgs.python3}/bin/python3 -m http.server 48484 --bind 0.0.0.0";
        Restart = "always";
        User = "nobody";
        Group = "nogroup";
      };
    };

    system.activationScripts.installWebstatusHtml = ''
      mkdir -p /var/www/webstatus
      cp ${html} /var/www/webstatus/index.html
      chown nobody:nogroup /var/www/webstatus/index.html
      chmod 0644 /var/www/webstatus/index.html
    '';
  };
}
