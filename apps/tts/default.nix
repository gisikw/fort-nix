{ rootManifest, ... }:
{ config, pkgs, lib, ... }:

let
  domain = rootManifest.fortConfig.settings.domain;

  # Go handler for tts capability
  ttsProvider = import ./provider {
    inherit pkgs domain;
  };

  containerPort = 8880;

in
{
  virtualisation.oci-containers.containers.kokoro-tts = {
    image = "ghcr.io/remsky/kokoro-fastapi-cpu:v0.1.4";
    ports = [ "127.0.0.1:${toString containerPort}:${toString containerPort}" ];
  };

  # Expose tts capability for cluster-wide text-to-speech
  fort.host.capabilities.tts = {
    handler = "${ttsProvider}/bin/tts-provider";
    mode = "rpc";
    allowed = [ "dev-sandbox" ];
    description = "Synthesize speech from text and upload result to target host";
  };
}
