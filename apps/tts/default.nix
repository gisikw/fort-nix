{ rootManifest, ... }:
{ config, pkgs, lib, ... }:

let
  domain = rootManifest.fortConfig.settings.domain;

  # Go handler for tts capability (RPC-based, uploads result to target host)
  ttsProvider = import ./provider {
    inherit pkgs domain;
  };

  containerPort = 8880;
  httpPort = 8788;

  # HTTP service for direct "text in, audio out" access
  ttsHttp = pkgs.buildGoModule {
    pname = "tts-http";
    version = "0.1.0";
    src = ./http;
    vendorHash = null;

    ldflags = [
      "-X main.backendURL=http://127.0.0.1:${toString containerPort}/v1/audio/speech"
      "-X main.listenAddr=127.0.0.1:${toString httpPort}"
    ];

    meta = with pkgs.lib; {
      description = "Text-to-speech HTTP service";
      license = licenses.mit;
      platforms = platforms.linux;
    };
  };

in
{
  # Exo voice — trained via unkork, decrypted at activation
  sops.secrets.exo-kokoro-voice = {
    sopsFile = ./exo-voice.pt.sops;
    format = "binary";
    mode = "0444";
    path = "/var/lib/kokoro-tts/voices/af_exo.pt";
  };

  virtualisation.oci-containers.containers.kokoro-tts = {
    image = "ghcr.io/remsky/kokoro-fastapi-cpu:v0.2.4";
    ports = [ "127.0.0.1:${toString containerPort}:${toString containerPort}" ];
    environment = {
      DEFAULT_VOICE = "af_exo";
    };
    volumes = [
      "/var/lib/kokoro-tts/voices/af_exo.pt:/app/api/src/voices/v1_0/af_exo.pt:ro"
    ];
  };

  # Expose tts capability for cluster-wide text-to-speech (RPC, upload-to-host)
  fort.host.capabilities.tts = {
    handler = "${ttsProvider}/bin/tts-provider";
    mode = "rpc";
    allowed = [ "dev-sandbox" ];
    description = "Synthesize speech from text and upload result to target host";
  };

  # HTTP endpoint: tts.gisi.network
  systemd.services.tts-http = {
    description = "Text-to-Speech HTTP Service";
    after = [ "network.target" "podman-kokoro-tts.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      ExecStart = "${ttsHttp}/bin/tts-http";
      Restart = "always";
      RestartSec = "5s";
      DynamicUser = true;
    };
  };

  # Proxy /v1/ directly to Kokoro's OpenAI-compatible API
  services.nginx.virtualHosts."tts.${domain}".locations."/v1/" = {
    proxyPass = "http://127.0.0.1:${toString containerPort}/v1/";
    extraConfig = "proxy_read_timeout 120s;";
  };

  fort.cluster.services = [{
    name = "tts";
    port = httpPort;
    visibility = "public";
    sso = {
      mode = "token";
      vpnBypass = true;
    };
  }];
}
