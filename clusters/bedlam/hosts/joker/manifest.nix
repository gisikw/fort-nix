rec {
  hostName = "joker";
  device = "95ee0c95-b96e-ef43-8898-dc90095d6c5e";

  roles = [ ];

  apps = [ ];

  aspects = [
    "mesh"
    "observable"
    "gitops"
    "ci-runner"
    "agent-debug"
  ];

  overlays = {
    # Joker-local signer bootstrap for the standalone Wings warden. The
    # signing authority is logically fort:wings; Joker is only its temporary
    # placement while the end-to-end flight path is proven.
    coffer = {
      package = "infra/coffer";
      config.role = "daemon";
    };
    wings = {
      package = "infra/wings";
    };
  };

  module =
    { config, pkgs, ... }:
    {
      config.fort.host = {
        inherit
          roles
          apps
          aspects
          overlays
          ;
      };

      config.environment.systemPackages = [
        (import ../../../../pkgs/claude-code { inherit pkgs; })
      ];

      # The standalone warden must not run as root: Claude Code refuses
      # bypassPermissions under uid 0. Pin the uid because cofferd authorizes
      # local workloads from SO_PEERCRED.
      config.users.groups.wings.gid = 991;
      config.users.users.wings = {
        isSystemUser = true;
        uid = 991;
        group = "wings";
        extraGroups = [ "coffer" ];
        home = "/var/lib/wings";
        createHome = true;
        description = "Wings standalone warden";
      };

      # ---- Coffer client daemon (cofferd) ----
      # This requests read-only access to the temporary Joker-local signing
      # key. The key signs short-lived flight capabilities; provider credentials
      # remain exclusively on lordhenry behind Tiamat.
      config.users.users.coffer = {
        isSystemUser = true;
        group = "coffer";
        home = "/var/lib/cofferd";
      };
      config.users.groups.coffer = { };

      config.environment.etc."cofferd/server.crt".source = ../../coffer-server.crt;
      config.environment.etc."cofferd/config.toml".text = ''
        server = "https://drhorrible.fort.gisi.network:7787"
        socket = "/run/cofferd/coffer.sock"
        tls_cert = "/var/lib/cofferd/client.crt"
        tls_key = "/var/lib/cofferd/client.key"
        trust_anchors = "/etc/cofferd/server.crt"

        [[workload]]
        name = "wings"
        grant_file = "/var/lib/cofferd/grants/wings.grant"
        uid = 991
        prewarm = [
          { namespace = "fort/wings", name = "signing-key" },
        ]
        grant_shape = { }
      '';

      # Root must wrap Joker's existing ed25519 host key in the self-signed
      # client certificate. cofferd itself remains unprivileged.
      config.systemd.services.cofferd-mint-client-cert = {
        description = "Mint cofferd client certificate from the host ssh key";
        wantedBy = [ "multi-user.target" ];
        path = [
          pkgs.coreutils
          pkgs.systemd
          pkgs.gnugrep
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          bin=""
          for _ in $(seq 1 120); do
            bin=$(systemctl show -p ExecStart overlay-coffer-cofferd.service 2>/dev/null \
              | grep -o '/nix/store/[^ ;]*/bin/cofferd' | head -1 || true)
            if [ -z "$bin" ] && [ -x /run/overlays/bin/cofferd ]; then
              bin=/run/overlays/bin/cofferd
            fi
            [ -n "$bin" ] && [ -x "$bin" ] && break
            bin=""
            sleep 5
          done
          [ -n "$bin" ] || { echo "cofferd binary never appeared" >&2; exit 1; }
          "$bin" --mint-client-cert \
            --ssh-key /etc/ssh/ssh_host_ed25519_key \
            --out-cert /var/lib/cofferd/client.crt \
            --out-key /var/lib/cofferd/client.key \
            --san joker
          chown coffer:coffer /var/lib/cofferd/client.crt /var/lib/cofferd/client.key
        '';
      };

      # Manual vertical-slice acceptance. Route registration is an operator-side
      # control-plane step and completes before Warden starts; neither Warden nor
      # Claude Code receives route authority or upstream topology.
      config.systemd.services.wings-acceptance-anthropic = {
        description = "Run Wings acceptance through Tiamat (Anthropic route)";
        path = [
          pkgs.coreutils
          (import ../../../../pkgs/claude-code { inherit pkgs; })
        ];
        serviceConfig = {
          Type = "oneshot";
          User = "wings";
          Group = "wings";
          WorkingDirectory = "/var/lib/wings";
          TimeoutStartSec = "15min";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectHome = true;
          ProtectSystem = "strict";
          ReadWritePaths = [ "/var/lib/wings" ];
        };
        script = ''
          route=anthropic-opus
          flight="acceptance-anthropic-$(date +%s)"
          workdir=/var/lib/wings/acceptance-anthropic
          rm -rf "$workdir"; mkdir -p "$workdir"
          /run/overlays/bin/wings-register -grant-url http://lordhenry:8900/v1/tiamat/grants -route "$route" -flight-id "$flight" -issuer fort:wings -key-id bootstrap-2026-07-23 -ttl 15m -signing-key-path fort/wings/signing-key
          { echo wait; echo status; echo screen; echo quit; } | /run/overlays/bin/wings-warden -workdir "$workdir" -base-url http://lordhenry:8900 -model routed -claude ${
            (import ../../../../pkgs/claude-code { inherit pkgs; })
          }/bin/claude -mcp /run/overlays/bin/wings-mcp -prompt 'Create X.txt containing exactly Y followed by a newline. Verify it through Bash. Then call wings.complete with a concise Markdown summary and evidence. Do not create DONE.md.' -flight-id "$flight" -issuer fort:wings -key-id bootstrap-2026-07-23 -capability-ttl 15m -signing-key-path fort/wings/signing-key -terminal-url http://lordhenry:8900/v1/tiamat/invocations/terminal
        '';
      };

      config.systemd.services.wings-acceptance-openai = {
        description = "Run Wings acceptance through Tiamat (OpenAI route)";
        path = [
          pkgs.coreutils
          (import ../../../../pkgs/claude-code { inherit pkgs; })
        ];
        serviceConfig = {
          Type = "oneshot";
          User = "wings";
          Group = "wings";
          WorkingDirectory = "/var/lib/wings";
          TimeoutStartSec = "15min";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectHome = true;
          ProtectSystem = "strict";
          ReadWritePaths = [ "/var/lib/wings" ];
        };
        script = ''
          route=openai-sol
          flight="acceptance-openai-$(date +%s)"
          workdir=/var/lib/wings/acceptance-openai
          rm -rf "$workdir"; mkdir -p "$workdir"
          /run/overlays/bin/wings-register -grant-url http://lordhenry:8900/v1/tiamat/grants -route "$route" -flight-id "$flight" -issuer fort:wings -key-id bootstrap-2026-07-23 -ttl 15m -signing-key-path fort/wings/signing-key
          { echo wait; echo status; echo screen; echo quit; } | /run/overlays/bin/wings-warden -workdir "$workdir" -base-url http://lordhenry:8900 -model routed -claude ${
            (import ../../../../pkgs/claude-code { inherit pkgs; })
          }/bin/claude -mcp /run/overlays/bin/wings-mcp -prompt 'Inspect the workdir, create routed.txt containing exactly openai followed by a newline, verify it through Bash, then call wings.complete with a concise Markdown summary and evidence. Do not create DONE.md.' -flight-id "$flight" -issuer fort:wings -key-id bootstrap-2026-07-23 -capability-ttl 15m -signing-key-path fort/wings/signing-key -terminal-url http://lordhenry:8900/v1/tiamat/invocations/terminal
        '';
      };

      config.systemd.services.wings-acceptance-local = {
        description = "Run Wings acceptance through Tiamat (local route)";
        path = [
          pkgs.coreutils
          (import ../../../../pkgs/claude-code { inherit pkgs; })
        ];
        serviceConfig = {
          Type = "oneshot";
          User = "wings";
          Group = "wings";
          WorkingDirectory = "/var/lib/wings";
          TimeoutStartSec = "15min";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectHome = true;
          ProtectSystem = "strict";
          ReadWritePaths = [ "/var/lib/wings" ];
        };
        script = ''
          route=local-default
          flight="acceptance-local-$(date +%s)"
          workdir=/var/lib/wings/acceptance-local
          rm -rf "$workdir"; mkdir -p "$workdir"
          /run/overlays/bin/wings-register -grant-url http://lordhenry:8900/v1/tiamat/grants -route "$route" -flight-id "$flight" -issuer fort:wings -key-id bootstrap-2026-07-23 -ttl 15m -signing-key-path fort/wings/signing-key
          { echo wait; echo status; echo screen; echo quit; } | /run/overlays/bin/wings-warden -workdir "$workdir" -base-url http://lordhenry:8900 -model routed -claude ${
            (import ../../../../pkgs/claude-code { inherit pkgs; })
          }/bin/claude -mcp /run/overlays/bin/wings-mcp -prompt 'Create X.txt containing exactly Y followed by a newline. Verify it through Bash. Then call wings.complete with a concise Markdown summary and evidence. Do not create DONE.md.' -flight-id "$flight" -issuer fort:wings -key-id bootstrap-2026-07-23 -capability-ttl 15m -signing-key-path fort/wings/signing-key -terminal-url http://lordhenry:8900/v1/tiamat/invocations/terminal
        '';
      };

      # Manual bootstrap probe: run only when deriving verification material.
      # SO_PEERCRED maps this process to the narrowly scoped "wings" workload;
      # stdout contains only the base64url Ed25519 public key.
      config.systemd.services.wings-key-public = {
        description = "Derive Wings public verification key through cofferd";
        serviceConfig = {
          Type = "oneshot";
          User = "wings";
          Group = "wings";
          ExecStart = "/run/overlays/bin/wings-key-public -signing-key-path fort/wings/signing-key";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectHome = true;
          ProtectSystem = "strict";
        };
      };
      config.systemd.tmpfiles.rules = [
        "d /var/lib/wings 0750 wings wings -"
        "d /var/lib/cofferd 0750 coffer coffer -"
        "d /run/cofferd 0750 coffer coffer -"
      ];
    };
}
