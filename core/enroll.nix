{ config, lib, pkgs, ... }:

let
  # Simple HTTP enrollment server
  enrollHttpServer = pkgs.writeText "enroll-server.py" ''
    import http.server
    import json
    import os
    import hashlib
    import time

    PENDING = "/var/lib/core-enroll/pending"

    class EnrollHandler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            if self.path != "/enroll":
                self.send_error(404)
                return

            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length)

            try:
                data = json.loads(body)
            except json.JSONDecodeError:
                self.send_error(400, "Invalid JSON")
                return

            # Generate enrollment ID from MAC + timestamp
            mac = data.get("mac", "unknown")
            eid = hashlib.sha256(f"{mac}{time.time()}".encode()).hexdigest()[:8]

            data["enrolled_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            data["id"] = eid

            path = os.path.join(PENDING, f"{eid}.json")
            with open(path, "w") as f:
                json.dump(data, f, indent=2)

            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"status": "queued", "id": eid}).encode())

        def log_message(self, format, *args):
            print(f"enroll: {args[0]}")

    os.makedirs(PENDING, exist_ok=True)
    server = http.server.HTTPServer(("0.0.0.0", 9090), EnrollHandler)
    print("Enrollment listener on :9090")
    server.serve_forever()
  '';

  # CLI for managing enrollment queue
  enrollCli = pkgs.writeShellScriptBin "core-enroll" ''
    set -eu
    PENDING="/var/lib/core-enroll/pending"

    case "''${1:-help}" in
      list|ls)
        echo "Pending enrollments:"
        for f in "$PENDING"/*.json 2>/dev/null; do
          [ -f "$f" ] || continue
          id=$(basename "$f" .json)
          info=$(${pkgs.jq}/bin/jq -r '"\(.ip // "?")\t\(.mac // "?")\t\(.ram_kb // "?")kB\t\(.enrolled_at // "")"' "$f")
          echo "  $id  $info"
        done
        ;;

      show)
        id="''${2:?Usage: core-enroll show <id>}"
        ${pkgs.jq}/bin/jq . "$PENDING/$id.json"
        ;;

      confirm)
        id="''${2:?Usage: core-enroll confirm <id> <host-manifest>}"
        manifest="''${3:?Usage: core-enroll confirm <id> <host-manifest>}"
        file="$PENDING/$id.json"
        [ -f "$file" ] || { echo "No pending enrollment: $id"; exit 1; }

        ip=$(${pkgs.jq}/bin/jq -r '.ip' "$file")
        echo "Provisioning $id ($ip) with manifest: $manifest"

        # TODO: invoke nixos-anywhere
        # nixos-anywhere --flake /var/lib/core-git/fort-nix#$manifest \
        #   --target-host root@$ip \
        #   -i /var/lib/core/master-key

        mv "$file" "$PENDING/$id.provisioned"
        echo "Done."
        ;;

      reject)
        id="''${2:?Usage: core-enroll reject <id>}"
        rm -f "$PENDING/$id.json"
        echo "Rejected: $id"
        ;;

      help|*)
        echo "core-enroll — manage host enrollment queue"
        echo ""
        echo "  list                       Show pending enrollments"
        echo "  show <id>                  Show enrollment details"
        echo "  confirm <id> <manifest>    Provision host with manifest"
        echo "  reject <id>                Remove from queue"
        ;;
    esac
  '';
in
{
  environment.systemPackages = [ enrollCli ];

  systemd.services.core-enroll = {
    description = "Host enrollment listener";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.python3}/bin/python3 ${enrollHttpServer}";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/core-enroll 0750 root root -"
    "d /var/lib/core-enroll/pending 0750 root root -"
  ];
}
