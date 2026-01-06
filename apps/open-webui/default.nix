{ subdomain ? null, ... }:
{ ... }:
{
  services.open-webui = {
    enable = true;
    environment = {
      ANONYMIZED_TELEMETRY = "False";
      DO_NOT_TRACK = "True";
      SCARF_NO_ANALYTICS = "True";
      OLLAMA_API_BASE_URL = "http://127.0.0.1:11434/api";
      OLLAMA_BASE_URL = "http://127.0.0.1:11434";
      HOME = "/var/lib/open-webui";
    };
  };

  fort.cluster.services = [
    {
      name = "ai";
      subdomain = subdomain;
      port = 8080;
    }
  ];
}
