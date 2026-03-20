import io
import json
import logging
import subprocess
import tempfile

import numpy as np
import soundfile as sf
import torch
import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel

logging.basicConfig(level=logging.INFO, format="[qwen-tts] %(message)s")
log = logging.getLogger("qwen-tts")

app = FastAPI()

model = None

# CustomVoice built-in speakers
SPEAKERS = {
    "vivian": ("Vivian", "Chinese"),
    "serena": ("Serena", "Chinese"),
    "uncle_fu": ("Uncle_Fu", "Chinese"),
    "dylan": ("Dylan", "Chinese"),
    "eric": ("Eric", "Chinese"),
    "ryan": ("Ryan", "English"),
    "aiden": ("Aiden", "English"),
    "ono_anna": ("Ono_Anna", "Japanese"),
    "sohee": ("Sohee", "Korean"),
}

FORMAT_CONTENT_TYPE = {
    "wav": "audio/wav",
    "mp3": "audio/mpeg",
    "opus": "audio/opus",
    "flac": "audio/flac",
}


class SpeechRequest(BaseModel):
    model: str = "qwen3-tts"
    voice: str = "ryan"
    input: str
    response_format: str = "wav"
    language: str | None = None
    instructions: str | None = None


def wav_to_format(wav_bytes: bytes, fmt: str) -> bytes:
    """Convert WAV audio to the requested format using ffmpeg."""
    if fmt == "wav":
        return wav_bytes

    fmt_args = {
        "mp3": ["-codec:a", "libmp3lame", "-q:a", "2"],
        "opus": ["-codec:a", "libopus", "-b:a", "128k"],
        "flac": ["-codec:a", "flac"],
    }
    args = fmt_args.get(fmt)
    if args is None:
        raise ValueError(f"unsupported format: {fmt}")

    result = subprocess.run(
        ["ffmpeg", "-i", "pipe:0", "-f", fmt, *args, "pipe:1"],
        input=wav_bytes,
        capture_output=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"ffmpeg failed: {result.stderr.decode()}")
    return result.stdout


@app.on_event("startup")
def load_model():
    global model
    from qwen_tts import Qwen3TTSModel

    log.info("loading Qwen3-TTS-12Hz-1.7B-CustomVoice...")
    model = Qwen3TTSModel.from_pretrained(
        "Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice",
        device_map="cuda:0",
        dtype=torch.bfloat16,
        attn_implementation="sdpa",
    )
    log.info("model loaded, ready to serve")


@app.post("/v1/audio/speech")
async def synthesize(req: SpeechRequest):
    if not req.input:
        raise HTTPException(status_code=400, detail="input is required")

    voice_key = req.voice.lower()
    speaker_info = SPEAKERS.get(voice_key)
    if speaker_info is None:
        raise HTTPException(
            status_code=400,
            detail=f"unknown voice: {req.voice}. available: {list(SPEAKERS.keys())}",
        )

    speaker, default_lang = speaker_info
    language = req.language or default_lang

    content_type = FORMAT_CONTENT_TYPE.get(req.response_format)
    if content_type is None:
        raise HTTPException(
            status_code=400,
            detail=f"unsupported format: {req.response_format}. available: {list(FORMAT_CONTENT_TYPE.keys())}",
        )

    log.info(
        "synthesizing: voice=%s lang=%s fmt=%s text=%s",
        speaker,
        language,
        req.response_format,
        repr(req.input[:80]),
    )

    wavs, sr = model.generate_custom_voice(
        text=req.input,
        language=language,
        speaker=speaker,
        instruct=req.instructions or "",
    )

    # Encode to WAV first
    buf = io.BytesIO()
    sf.write(buf, wavs[0], sr, format="WAV")
    wav_bytes = buf.getvalue()

    # Convert to requested format
    audio_bytes = wav_to_format(wav_bytes, req.response_format)

    log.info("done: %d bytes (%s)", len(audio_bytes), req.response_format)
    return Response(content=audio_bytes, media_type=content_type)


@app.get("/health")
def health():
    return {
        "status": "ok" if model is not None else "loading",
        "model": "Qwen3-TTS-12Hz-1.7B-CustomVoice",
    }


@app.get("/voices")
def voices():
    return {
        "voices": [
            {"id": k, "name": v[0], "language": v[1]} for k, v in SPEAKERS.items()
        ]
    }


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8880)
