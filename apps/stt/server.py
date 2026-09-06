"""HTTP speech-to-text service backed by NVIDIA Parakeet TDT."""

import logging
import os
import subprocess
import tempfile
import wave
from pathlib import Path

import numpy as np
import torch
from flask import Flask, jsonify, request
from transformers import pipeline
from werkzeug.exceptions import HTTPException, RequestEntityTooLarge

MODEL_ID = os.environ.get("PARAKEET_MODEL", "nvidia/parakeet-tdt-0.6b-v3")
MODEL_REVISION = os.environ.get(
    "PARAKEET_REVISION", "541d1f99c6b0c3cd0b11a95167540bb8edefd82b"
)
FFMPEG = os.environ.get("FFMPEG", "/usr/bin/ffmpeg")

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("stt")

# The CDI mapping exposes only the selected physical GPU, as cuda:0 in the
# container. Fail instead of silently falling back to a very slow CPU path if
# the host's CDI/driver setup is broken. Loading once avoids model churn.
if not torch.cuda.is_available():
    raise RuntimeError("CUDA is required but unavailable; check the NVIDIA CDI mapping")
device = 0
dtype = torch.float16
log.info("loading %s at revision %s on cuda:0", MODEL_ID, MODEL_REVISION)
transcriber = pipeline(
    "automatic-speech-recognition",
    model=MODEL_ID,
    revision=MODEL_REVISION,
    device=device,
    dtype=dtype,
)
log.info("Parakeet model ready")

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 256 * 1024 * 1024


@app.errorhandler(RequestEntityTooLarge)
def too_large(_error):
    return jsonify(error="upload exceeds 256 MiB limit"), 413


@app.errorhandler(Exception)
def failed(error):
    if isinstance(error, HTTPException):
        return jsonify(error=error.description), error.code
    log.exception("transcription request failed")
    return jsonify(error=str(error)), 500


@app.get("/health")
def health():
    return jsonify(status="ok", model=MODEL_ID, backend="parakeet-tdt")


def decode_pcm16(path: Path) -> tuple[np.ndarray, int]:
    with wave.open(str(path), "rb") as audio:
        if audio.getnchannels() != 1 or audio.getsampwidth() != 2:
            raise ValueError("normalized audio is not mono PCM16")
        sample_rate = audio.getframerate()
        samples = np.frombuffer(audio.readframes(audio.getnframes()), dtype="<i2")
    return samples.astype(np.float32) / 32768.0, sample_rate


@app.post("/transcribe")
def transcribe():
    upload = request.files.get("file")
    if upload is None:
        return jsonify(error="missing 'file' field"), 400

    safe_name = Path(upload.filename or "audio").name
    with tempfile.TemporaryDirectory(prefix="stt-") as temp:
        temp_dir = Path(temp)
        source = temp_dir / f"input-{safe_name}"
        wav = temp_dir / "normalized.wav"
        upload.save(source)
        log.info("received %s (%d bytes)", safe_name, source.stat().st_size)

        converted = subprocess.run(
            [
                FFMPEG,
                "-nostdin",
                "-hide_banner",
                "-loglevel",
                "error",
                "-i",
                str(source),
                "-ar",
                "16000",
                "-ac",
                "1",
                "-c:a",
                "pcm_s16le",
                "-y",
                str(wav),
            ],
            capture_output=True,
            text=True,
            timeout=300,
        )
        if converted.returncode != 0:
            detail = converted.stderr.strip()[-1000:]
            log.warning("ffmpeg rejected %s: %s", safe_name, detail)
            return jsonify(error=f"ffmpeg conversion failed: {detail}"), 422

        samples, sample_rate = decode_pcm16(wav)
        result = transcriber({"array": samples, "sampling_rate": sample_rate})
        text = result["text"].strip()
        log.info("completed %s (%d chars)", safe_name, len(text))
        return jsonify(text=text)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8787")), threaded=False)
