# Silero VAD silence stripper for Whisper preprocessing.
# Strips silence from 16kHz mono WAV files using ONNX runtime (CPU-only).
# ~165x real-time on CPU — adds ~11 seconds for a 30-minute recording.
{ pkgs }:

let
  pythonEnv = pkgs.python3.withPackages (ps: [
    ps.numpy
    ps.onnxruntime
    ps.soundfile
  ]);

  # Silero VAD v5 ONNX model (~2MB)
  sileroModel = pkgs.fetchurl {
    url = "https://github.com/snakers4/silero-vad/raw/v5.1.2/src/silero_vad/data/silero_vad.onnx";
    hash = "sha256-JiOilT9v89LB5hdAxs23FoEzR5smff7xFKSjzFvdeI8=";
  };

  vadScript = pkgs.replaceVars ./vad-strip.py {
    modelPath = sileroModel;
  };
in
pkgs.writeShellScriptBin "vad-strip" ''
  exec ${pythonEnv}/bin/python3 ${vadScript} "$@"
''
