# Shared helpers for the fort service-exposure modules (common/fort/*.nix).
# Pure functions only — anything here must be platform- and config-free.
{
  # A service's public subdomain: explicit svc.subdomain wins, else svc.name.
  subdomainOf = svc: if svc ? subdomain && svc.subdomain != null then svc.subdomain else svc.name;

  # JSON body of /var/lib/fort/host-manifest.json — shared by the NixOS
  # activation script (fort/services.nix) and the darwin install script
  # (fort/control-plane.nix) so both platforms publish the same shape.
  hostManifestContentFor = config: builtins.toJSON {
    apps = config.fort.host.apps or [];
    # Extract aspect names (handle both string and {name=...} forms)
    aspects = map (a: if builtins.isString a then a else a.name or "unknown") (config.fort.host.aspects or []);
    roles = config.fort.host.roles or [];
    services = config.fort.cluster.services;
  };
}
