{ rootManifest, ... }:
{ pkgs, ... }:
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
    basicAuthMode = true;
    basicAuthUser = {
      username = "user";
      password = "password";
    };
    enableCorsProxy = false;
    requestProxy = {
      enabled = false;
      url = "socks5://username:password@example.com:1080";
      bypass = [
        "localhost"
        "127.0.0.1"
      ];
    };
    enableUserAccounts = false;
    enableDiscreetLogin = false;
    autheliaAuth = false;
    perUserBasicAuth = false;
    hostWhitelist = {
      enabled = false;
      scan = true;
      hosts = [ ];
    };
    sessionTimeout = -1;
    disableCsrfProtection = false;
    securityOverride = false;
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
      image = "containers.${fort.settings.domain}/ghcr.io/sillytavern/sillytavern:latest";
      hostname = "sillytavern.${fort.settings.domain}";
      ports = [ "8000:8000" ];
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
    install -Dm0640 ${configFile} /var/lib/sillytavern/config/config.yaml
  '';

  systemd.tmpfiles.rules = [
    "d /var/lib/sillytavern/config 0755 root root -"
    "d /var/lib/sillytavern/data 0755 root root -"
    "d /var/lib/sillytavern/plugins 0755 root root -"
    "d /var/lib/sillytavern/extensions 0755 root root -"
  ];

  fortCluster.exposedServices = [
    {
      name = "sillytavern";
      port = 8000;
    }
  ];
}
