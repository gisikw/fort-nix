{ subdomain ? null, rootManifest, ... }:
{ pkgs, lib, ... }:
let
  fort = rootManifest.fortConfig;
  yamlFormat = pkgs.formats.yaml { };
  sillyTavernConfig = {
    dataRoot = "./data";
    listen = false;
    listenAddress = {
      ipv4 = "0.0.0.0";
      ipv6 = "[::]";
    };
    protocol = {
      ipv4 = true;
      ipv6 = false;
    };
    dnsPreferIPv6 = false;
    browserLaunch = {
      enabled = false;
      browser = "default";
      hostname = "auto";
      port = -1;
      avoidLocalhost = false;
    };
    port = 8000;
    ssl = {
      enabled = false;
      certPath = "./certs/cert.pem";
      keyPath = "./certs/privkey.pem";
      keyPassphrase = "";
    };
    whitelistMode = false;
    enableForwardedWhitelist = true;
    whitelist = [
      "::1"
      "127.0.0.1"
    ];
    whitelistDockerHosts = true;
    basicAuthMode = false;
    enableCorsProxy = false;
    requestProxy = {
      enabled = false;
      url = "socks5://username:password@example.com:1080";
      bypass = [
        "localhost"
        "127.0.0.1"
      ];
    };
    enableUserAccounts = true;
    enableDiscreetLogin = false;
    autheliaAuth = true;
    perUserBasicAuth = false;
    hostWhitelist = {
      enabled = false;
      scan = true;
      hosts = [ ];
    };
    sessionTimeout = -1;
    disableCsrfProtection = false;
    securityOverride = true;  # Required: suppresses exit on passwordless users when basic auth disabled
    logging = {
      enableAccessLog = true;
      minLogLevel = 0;
    };
    rateLimiting = {
      preferRealIpHeader = false;
    };
    backups = {
      common = {
        numberOfBackups = 50;
      };
      chat = {
        enabled = true;
        checkIntegrity = true;
        maxTotalBackups = -1;
        throttleInterval = 10000;
      };
    };
    thumbnails = {
      enabled = true;
      format = "jpg";
      quality = 95;
      dimensions = {
        bg = [
          160
          90
        ];
        avatar = [
          96
          144
        ];
        persona = [
          96
          144
        ];
      };
    };
    performance = {
      lazyLoadCharacters = false;
      memoryCacheCapacity = "100mb";
      useDiskCache = true;
    };
    cacheBuster = {
      enabled = false;
      userAgentPattern = "";
    };
    allowKeysExposure = false;
    skipContentCheck = false;
    whitelistImportDomains = [
      "localhost"
      "cdn.discordapp.com"
      "files.catbox.moe"
      "raw.githubusercontent.com"
      "char-archive.evulid.cc"
    ];
    requestOverrides = [ ];
    extensions = {
      enabled = true;
      autoUpdate = true;
      models = {
        autoDownload = true;
        classification = "Cohee/distilbert-base-uncased-go-emotions-onnx";
        captioning = "Xenova/vit-gpt2-image-captioning";
        embedding = "Cohee/jina-embeddings-v2-base-en";
        speechToText = "Xenova/whisper-small";
        textToSpeech = "Xenova/speecht5_tts";
      };
    };
    enableDownloadableTokenizers = true;
    promptPlaceholder = "[Start a new chat]";
    openai = {
      randomizeUserId = false;
      captionSystemPrompt = "";
    };
    deepl = {
      formality = "default";
    };
    mistral = {
      enablePrefix = false;
    };
    ollama = {
      keepAlive = 600;
      batchSize = -1;
    };
    claude = {
      enableSystemPromptCache = false;
      cachingAtDepth = -1;
      extendedTTL = false;
    };
    gemini = {
      apiVersion = "v1beta";
    };
    enableServerPlugins = false;
    enableServerPluginsAutoUpdate = true;
  };
  configFile = yamlFormat.generate "sillytavern-config.yaml" sillyTavernConfig;
in
{
  virtualisation.oci-containers = {
    containers.sillytavern = {
      image = "containers.${fort.settings.domain}/ghcr.io/sillytavern/sillytavern:1.15.0";
      hostname = "sillytavern.${fort.settings.domain}";
      extraOptions = [ "--network=host" ];
      environment = {
        NODE_ENV = "production";
        FORCE_COLOR = "1";
      };
      volumes = [
        "/var/lib/sillytavern/config:/home/node/app/config"
        "/var/lib/sillytavern/data:/home/node/app/data"
        "/var/lib/sillytavern/plugins:/home/node/app/plugins"
        "/var/lib/sillytavern/extensions:/home/node/app/public/scripts/extensions/third-party"
      ];
    };
  };

  system.activationScripts.sillytavernConfig = ''
    install -Dm0644 ${configFile} /var/lib/sillytavern/config/config.yaml
  '';

  # Restart container when config changes
  systemd.services.podman-sillytavern.restartTriggers = [ configFile ];

  systemd.tmpfiles.rules = [
    "d /var/lib/sillytavern/config 0755 root root -"
    "d /var/lib/sillytavern/data 0755 root root -"
    "d /var/lib/sillytavern/plugins 0755 root root -"
    "d /var/lib/sillytavern/extensions 0755 root root -"
  ];

  fort.cluster.services = [
    {
      name = "sillytavern";
      subdomain = subdomain;
      port = 8000;
      sso.mode = "headers";
      health.endpoint = "/ready";
    }
  ];

  # SillyTavern's autheliaAuth mode expects Remote-User header, but oauth2-proxy sends X-Forwarded-User
  # Translate the header name so SillyTavern can consume it
  services.nginx.virtualHosts."${if subdomain != null then subdomain else "sillytavern"}.${fort.settings.domain}".locations."/".extraConfig = lib.mkAfter ''
    proxy_set_header Remote-User $http_x_forwarded_user;
  '';
}
