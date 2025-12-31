# OIDC Mode

**Status**: Working, has examples

Use `oidc` mode when the service supports OpenID Connect natively. The service-registry aspect automatically provisions credentials in pocket-id and delivers them to the target host.

## How It Works

1. You declare `sso.mode = "oidc"` in `fortCluster.exposedServices`
2. service-registry (on the forge host) runs every 10 minutes
3. It creates an OIDC client in pocket-id using the service's FQDN as the client name
4. Credentials are SSHed to `/var/lib/fort-auth/<service-name>/`:
   - `client-id` - the OIDC client ID
   - `client-secret` - the OIDC client secret
5. The service specified in `sso.restart` is restarted

## App Responsibilities

```nix
# 1. Declare exposure with restart target
fortCluster.exposedServices = [{
  name = "myapp";
  port = 8080;
  visibility = "public";  # or vpn, local
  sso = {
    mode = "oidc";
    restart = "myapp.service";  # Service to restart after creds delivered
  };
}];

# 2. Create tmpfiles for credential directory
systemd.tmpfiles.rules = [
  "d /var/lib/fort-auth/myapp 0700 myapp myapp -"
  "f /var/lib/fort-auth/myapp/client-id 0600 myapp myapp -"
  "f /var/lib/fort-auth/myapp/client-secret 0600 myapp myapp -"
];

# 3. Configure the app to use pocket-id OIDC endpoints
# (see example below for credential injection pattern)
```

## Pocket ID OIDC Endpoints

```
Issuer URL:    https://id.${domain}
Auth URL:      https://id.${domain}/authorize
Token URL:     https://id.${domain}/api/oidc/token
Userinfo URL:  https://id.${domain}/api/oidc/userinfo
```

## Working Example: Outline

From `apps/outline/default.nix`:

```nix
{ rootManifest, ... }:
{ pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;

  # Wrap the binary to inject credentials at runtime
  wrappedOutline = pkgs.symlinkJoin {
    name = "outline-wrapped";
    paths = [ pkgs.outline ];
    buildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/outline-server \
        --run 'export OIDC_CLIENT_ID=$(cat /var/lib/fort-auth/outline/client-id)' \
        --run 'export OIDC_CLIENT_SECRET=$(cat /var/lib/fort-auth/outline/client-secret)'
    '';
  };
in
{
  systemd.tmpfiles.rules = [
    "d /var/lib/fort-auth/outline 0755 outline outline -"
    "f /var/lib/fort-auth/outline/client-id 0600 outline outline -"
    "f /var/lib/fort-auth/outline/client-secret 0600 outline outline -"
  ];

  services.outline = {
    enable = true;
    package = wrappedOutline;
    port = 4654;
    publicUrl = "https://outline.${domain}";
    oidcAuthentication = {
      authUrl = "https://id.${domain}/authorize";
      tokenUrl = "https://id.${domain}/api/oidc/token";
      userinfoUrl = "https://id.${domain}/api/oidc/userinfo";
      scopes = [ "openid" "email" "profile" ];
      usernameClaim = "preferred_username";
      displayName = "Pocket ID";

      # Placeholder - overridden at runtime by wrapper
      clientId = "outline";
      clientSecretFile = "/var/lib/fort-auth/outline/client-secret";
    };
  };

  fortCluster.exposedServices = [{
    name = "outline";
    port = 4654;
    visibility = "public";
    sso = {
      mode = "oidc";
      restart = "outline.service";
    };
  }];
}
```

## Credential Injection Patterns

### Pattern 1: wrapProgram (environment variables)

Best when the app reads credentials from environment variables:

```nix
wrappedApp = pkgs.symlinkJoin {
  name = "app-wrapped";
  paths = [ pkgs.myapp ];
  buildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    wrapProgram $out/bin/myapp \
      --run 'export CLIENT_ID=$(cat /var/lib/fort-auth/myapp/client-id)' \
      --run 'export CLIENT_SECRET=$(cat /var/lib/fort-auth/myapp/client-secret)'
  '';
};
```

### Pattern 2: clientSecretFile (if supported)

Best when the NixOS module supports file-based secrets:

```nix
services.myapp.oidc = {
  clientId = "myapp";  # Will be wrong until first sync, but required
  clientSecretFile = "/var/lib/fort-auth/myapp/client-secret";
};
```

### Pattern 3: ExecStartPre script

For services that need secrets in config files:

```nix
systemd.services.myapp.serviceConfig.ExecStartPre = pkgs.writeShellScript "inject-oidc" ''
  CLIENT_ID=$(cat /var/lib/fort-auth/myapp/client-id)
  CLIENT_SECRET=$(cat /var/lib/fort-auth/myapp/client-secret)
  sed -i "s/CLIENT_ID_PLACEHOLDER/$CLIENT_ID/" /var/lib/myapp/config.json
  sed -i "s/CLIENT_SECRET_PLACEHOLDER/$CLIENT_SECRET/" /var/lib/myapp/config.json
'';
```

## Initial Deployment Timing

On first deployment, credentials don't exist yet:

1. Service starts with dummy/placeholder credentials
2. service-registry runs (within 10 minutes)
3. Real credentials are delivered
4. Service is restarted with valid credentials

This means the service may fail auth for up to 10 minutes on initial deployment. This is expected.

## See Also

- `apps/outline/default.nix` - Full OIDC example
- `apps/forgejo/default.nix` - OIDC with custom setup service
- `aspects/service-registry/registry.rb` - The provisioning logic
