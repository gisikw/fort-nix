# Option types for the fort control plane (q-1f08acd9)
#
# Platform-free declarations for fort.host.needs.<capability>.<id> and
# fort.host.capabilities.<name>. Imported by common/fort/control-plane.nix,
# which declares the actual options on both NixOS and darwin.
{ lib, pkgs }:
{
  # Need option type
  needOptions = {
    from = lib.mkOption {
      type = lib.types.str;
      description = "Hostname of the capability provider to request from";
      example = "drhorrible";
    };

    request = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Request payload passed to the capability handler";
      example = { service = "grafana"; };
    };

    handler = lib.mkOption {
      type = lib.types.path;
      default = pkgs.writeShellScript "noop-handler" ''
        # Side-effect-only need - no handler action needed
        # Response payload is discarded, success is recorded
        ${pkgs.coreutils}/bin/cat > /dev/null
      '';
      description = ''
        Script invoked when the need is fulfilled.
        Receives response payload on stdin.
        Exit 0 if credential was successfully processed.
        Handler is responsible for storage, transformation, and triggering restarts.
        Defaults to a no-op handler for side-effect-only needs.
      '';
      example = "./handle-oidc-token.sh";
    };

    nag = lib.mkOption {
      type = lib.types.str;
      default = "15m";
      description = ''
        Duration after which to re-request if unsatisfied.
        Format: number + unit (s=seconds, m=minutes, h=hours).
      '';
      example = "1h";
    };

    neverSatisfied = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        If true, the need is never permanently satisfied — the consumer
        re-checks on every nag cycle. The handler should no-op when
        nothing has changed. Useful for runtime packages that may be
        updated upstream between deploys.
      '';
    };

    check = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Optional freshness probe for a satisfied need. Run by the consumer
        on every fulfill cycle while the need is marked satisfied; a
        non-zero exit marks the need unsatisfied so it is re-requested on
        the next eligible nag interval. Use for fulfillments that decay
        (e.g. the ssl-cert need re-validates the on-disk certificate's
        expiry). Unlike neverSatisfied, the need only re-requests when the
        probe actually fails.
      '';
      example = "./check-cert-freshness.sh";
    };
  };

  # Capability option type
  capabilityOptions = {
    handler = lib.mkOption {
      type = lib.types.path;
      description = "Path to handler script";
    };

    mode = lib.mkOption {
      type = lib.types.enum [ "rpc" "async" ];
      default = "async";
      description = ''
        Execution mode for this capability:
        - "rpc": Synchronous request-response. No state tracking, no GC.
        - "async": Tracks state by origin:need_id. Provider can GC when need is removed.
      '';
      example = "rpc";
    };

    cacheResponse = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to cache/persist responses for the handler to reuse.
        Useful for capabilities that need to return the same response
        to multiple callers or across restarts.
      '';
    };

    triggers = lib.mkOption {
      type = lib.types.submodule {
        options = {
          initialize = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Run this capability handler on boot";
          };

          systemd = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "List of systemd unit names that trigger re-running the handler";
            example = [ "pocket-id.service" ];
          };
        };
      };
      default = { };
      description = "Trigger configuration for automatic handler invocation";
    };

    satisfies = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        The need type this capability satisfies. Used for documentation and
        potentially for RBAC derivation (finding hosts that declare matching needs).
        If null, defaults to the capability name itself.

        Example: capability "oidc-register" might set satisfies = "oidc" to match
        fort.host.needs.oidc.* declarations.
      '';
      example = "oidc";
    };

    description = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Human-readable description of the capability";
    };

    allowed = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = null;
      description = ''
        List of principal names allowed to call this capability.
        If null (default), all hosts and principals can call it.
        If specified, only the listed principals are allowed (not hosts).
      '';
      example = [ "dev-sandbox" ];
    };

    format = lib.mkOption {
      type = lib.types.enum [ "legacy" "symmetric" ];
      default = "legacy";
      description = ''
        Handler output format:
        - "legacy": Asymmetric format - output is {key: response}
        - "symmetric": Symmetric format - output is {key: {request, response}}

        New Go handlers should use "symmetric" for consistency.
        Existing bash handlers default to "legacy" for backward compatibility.
      '';
      example = "symmetric";
    };
  };
}
