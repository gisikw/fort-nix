{
  domain,
  contentDir,
  title ? domain,
  description ? "",
  copyright ? "All rights reserved",
  rootManifest,
  ...
}:
{ pkgs, ... }:
let
  currentYear = "2026"; # TODO: could derive from builtins.currentTime

  bearcub = pkgs.fetchFromGitHub {
    owner = "clente";
    repo = "hugo-bearcub";
    rev = "1d12a76549445b767fa02902caf30cec7ceaecf9";
    hash = "sha256-tQrs4asWNf13nO+3ms0+11w8WoLNK9aKGZcw79eEUCQ=";
  };

  # Light mode CSS - colors from hugo-bearblog
  lightModeCss = pkgs.writeText "light.css" ''
    :root {
      --background-color: #fff;
      --heading-color: #222;
      --text-color: #444;
      --link-color: #3273dc;
      --visited-color: #8b6fcb;
      --blockquote-color: #222;
    }
    body {
      background-color: var(--background-color);
      color: var(--text-color);
    }
    h1, h2, h3, h4, h5, h6, strong, b {
      color: var(--heading-color);
    }
    a { color: var(--link-color); }
    a:visited { color: var(--visited-color); }
    blockquote {
      color: var(--blockquote-color);
      border-left-color: #999;
    }
    code {
      background-color: #f5f5f5;
    }
    pre {
      background-color: #f5f5f5;
    }
  '';

  hugoConfig = pkgs.writeText "hugo.toml" ''
    baseURL = "https://${domain}"
    theme = "hugo-bearcub"
    title = "${title}"
    copyright = "${copyright} ${currentYear}"

    enableRobotsTXT = true

    [markup]
      [markup.highlight]
        lineNos = true
        lineNumbersInTable = false
        noClasses = false

    [params]
      description = "${description}"
      dateFormat = "2006-01-02"
      madeWith = "Made with [Bear Cub](https://github.com/clente/hugo-bearcub)"
  '';

  site = pkgs.stdenv.mkDerivation {
    name = "hugo-site-${domain}";
    src = contentDir;
    nativeBuildInputs = [ pkgs.hugo ];
    buildPhase = ''
      # Set up Hugo structure in temp build dir
      mkdir -p build/content build/themes/hugo-bearcub build/static build/layouts/partials

      # Copy user content (from src root) to content/
      cp -r ./* build/content/ || true

      # Theme
      cp -r ${bearcub}/* build/themes/hugo-bearcub/

      # Generated config
      cp ${hugoConfig} build/hugo.toml

      # Light mode CSS
      cp ${lightModeCss} build/static/light.css

      # Custom head to include light mode CSS
      echo '<link rel="stylesheet" href="/light.css">' > build/layouts/partials/custom_head.html

      cd build
      hugo --minify
      cd ..
    '';
    installPhase = ''
      cp -r build/public $out
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
