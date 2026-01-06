{ subdomain ? null, rootManifest, ... }:
{ pkgs, ... }:
let
  domain = rootManifest.fortConfig.settings.domain;
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
    "d /var/lib/fort-authy/outline 0755 outline outline -"
    "f /var/lib/fort-auth/outline/client-id 0600 outline outline -"
    "f /var/lib/fort-auth/outline/client-secret 0600 outline outline -"
  ];

  services.outline = {
    enable = true;
    package = wrappedOutline;
    port = 4654;
    publicUrl = "https://outline.${domain}";
    storage.storageType = "local";
    oidcAuthentication = {
      authUrl = "https://id.${domain}/authorize";
      tokenUrl = "https://id.${domain}/api/oidc/token";
      userinfoUrl = "https://id.${domain}/api/oidc/userinfo";
      scopes = [ "openid" "email" "profile" ];
      usernameClaim = "preferred_username";
      displayName = "Pocket ID";

      # OVERRIDDEN AT RUNTIME
      clientId = "outline";
      clientSecretFile = "/var/lib/fort-auth/outline/client-secret";
    };
  };

  fort.cluster.services = [
    {
      name = "outline";
      subdomain = subdomain;
      port = 4654;
      visibility = "public";
      sso = {
        mode = "oidc";
        restart = "outline.service";
      };
    }
  ];
}
