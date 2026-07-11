# Fort service exposure — thin aggregator (q-d9cba37c)
#
# NixOS-only (imported by common/platforms/nixos.nix). Everything that turns
# fort.cluster.services declarations into running infrastructure lives in
# common/fort/, split by concern:
#
#   fort/services.nix — host-manifest generation + discovery needs (proxy, dns)
#   fort/nginx.nix    — realip/geo plumbing + per-service virtual hosts
#   fort/auth.nix     — oauth2-proxy, identity-proxy, token secret, oidc needs
#   fort/ssl.nix      — placeholder certs + ssl-cert need with freshness probe
#
# The concern modules are composed functionally (their configs merged inside
# this single module) rather than via `imports`: the module system expands
# imports breadth-first, which would move these definitions AFTER the host's
# aspect/app modules and reorder list-typed option merges (observed:
# nginx ReadWritePaths flipping with aspects/host-status). Keeping one module
# preserves the exact pre-split definition order, byte-for-byte.
#
# The fort.cluster options themselves are declared in fort-options.nix
# (shared with the darwin builder); the control plane is fort/control-plane.nix.
{ rootManifest, cluster, ... }:
{
  config,
  lib,
  pkgs,
  ...
}@moduleArgs:
let
  ctx = { inherit rootManifest cluster; };
  concernConfig = path: ((import path ctx) moduleArgs).config;
in
{
  config = lib.mkMerge (map concernConfig [
    ./fort/services.nix
    ./fort/nginx.nix
    ./fort/auth.nix
    ./fort/ssl.nix
  ]);
}
