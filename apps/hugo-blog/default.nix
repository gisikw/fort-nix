{
  domain,
  contentDir,
  rootManifest,
  ...
}:
{ pkgs, ... }:
let
  bearcub = pkgs.fetchFromGitHub {
    owner = "clente";
    repo = "hugo-bearcub";
    rev = "1d12a76549445b767fa02902caf30cec7ceaecf9";
    hash = "sha256-tQrs4asWNf13nO+3ms0+11w8WoLNK9aKGZcw79eEUCQ=";
  };

  site = pkgs.stdenv.mkDerivation {
    name = "hugo-site-${domain}";
    src = contentDir;
    nativeBuildInputs = [ pkgs.hugo ];
    buildPhase = ''
      mkdir -p themes/hugo-bearcub
      cp -r ${bearcub}/* themes/hugo-bearcub/
      hugo --minify
    '';
    installPhase = ''
      cp -r public $out
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
