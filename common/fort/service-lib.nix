# Shared helpers for the fort service-exposure modules (common/fort/*.nix).
# Pure functions only — anything here must be platform- and config-free.
{
  # A service's public subdomain: explicit svc.subdomain wins, else svc.name.
  subdomainOf = svc: if svc ? subdomain && svc.subdomain != null then svc.subdomain else svc.name;
}
