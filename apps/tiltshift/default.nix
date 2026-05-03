{ rootManifest, ... }:
{ pkgs, ... }:
let
  domain = "tiltshift.ai";

  site = pkgs.stdenv.mkDerivation {
    name = "tiltshift-site";
    src = ./.;
    installPhase = ''
      mkdir -p $out
      cp $src/index.html $out/
    '';
  };
in
{
  services.nginx.virtualHosts.${domain} = {
    forceSSL = true;
    enableACME = true;
    root = site;
  };

  security.acme = {
    acceptTerms = true;
    defaults.email = "admin@${rootManifest.fortConfig.settings.domain}";
  };
}
