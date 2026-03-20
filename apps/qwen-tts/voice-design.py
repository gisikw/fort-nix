"""Standalone Voice Design server — calls qwen_tts VoiceDesign model directly.

Runs alongside the main TTS API on a separate port. Lazy-loads the model
on first request to avoid VRAM usage when not in use.
"""

import io
import logging
import subprocess

import soundfile as sf
import torch
import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse, Response
from pydantic import BaseModel

logging.basicConfig(level=logging.INFO, format="[voice-design] %(message)s")
log = logging.getLogger("voice-design")

app = FastAPI()

model = None


class DesignRequest(BaseModel):
    instruct: str
    text: str = "Hi! This is a reference clip for my custom voice design."
    language: str = "English"
    response_format: str = "mp3"


def load_model():
    global model
    if model is not None:
        return
    from qwen_tts import Qwen3TTSModel

    log.info("loading Qwen3-TTS-12Hz-0.6B-VoiceDesign...")
    model = Qwen3TTSModel.from_pretrained(
        "Qwen/Qwen3-TTS-12Hz-0.6B-VoiceDesign",
        device_map="cuda:0",
        dtype=torch.bfloat16,
        attn_implementation="sdpa",
    )
    log.info("VoiceDesign model loaded")


def wav_to_format(wav_bytes: bytes, fmt: str) -> bytes:
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


@app.post("/generate")
async def generate(req: DesignRequest):
    if not req.instruct.strip():
        raise HTTPException(status_code=400, detail="voice description is required")

    load_model()

    log.info("generating: instruct=%s lang=%s text=%s",
             repr(req.instruct[:80]), req.language, repr(req.text[:60]))

    wavs, sr = model.generate_voice_design(
        text=req.text,
        language=req.language,
        instruct=req.instruct,
    )

    buf = io.BytesIO()
    sf.write(buf, wavs[0], sr, format="WAV")
    wav_bytes = buf.getvalue()

    audio_bytes = wav_to_format(wav_bytes, req.response_format)
    content_type = {
        "wav": "audio/wav", "mp3": "audio/mpeg",
        "opus": "audio/opus", "flac": "audio/flac",
    }[req.response_format]

    log.info("done: %d bytes (%s)", len(audio_bytes), req.response_format)
    return Response(content=audio_bytes, media_type=content_type)


@app.get("/health")
def health():
    return {"status": "ok" if model is not None else "not_loaded",
            "model": "Qwen3-TTS-12Hz-0.6B-VoiceDesign"}


@app.get("/", response_class=HTMLResponse)
def ui():
    return """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Voice Design</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: system-ui, sans-serif; background: #111; color: #e0e0e0;
         max-width: 640px; margin: 0 auto; padding: 24px 16px; }
  h1 { font-size: 1.4rem; margin-bottom: 4px; }
  .sub { color: #888; font-size: 0.85rem; margin-bottom: 24px; }
  label { display: block; font-size: 0.85rem; color: #aaa; margin-bottom: 4px; margin-top: 16px; }
  textarea, select { width: 100%; background: #1a1a1a; color: #e0e0e0; border: 1px solid #333;
                     border-radius: 6px; padding: 10px; font-size: 0.95rem; font-family: inherit; }
  textarea { resize: vertical; min-height: 80px; }
  select { height: 40px; }
  .row { display: flex; gap: 12px; align-items: end; }
  .row > * { flex: 1; }
  button { margin-top: 20px; width: 100%; padding: 12px; font-size: 1rem; font-weight: 600;
           background: #c47a2a; color: #fff; border: none; border-radius: 6px; cursor: pointer; }
  button:hover { background: #d68a3a; }
  button:disabled { opacity: 0.5; cursor: wait; }
  #status { margin-top: 12px; font-size: 0.85rem; color: #888; min-height: 20px; }
  #result { margin-top: 20px; }
  audio { width: 100%; margin-top: 8px; }
  .history { margin-top: 32px; }
  .history h2 { font-size: 1rem; color: #888; margin-bottom: 12px; }
  .clip { background: #1a1a1a; border-radius: 8px; padding: 12px; margin-bottom: 12px; }
  .clip .desc { font-size: 0.85rem; color: #c47a2a; margin-bottom: 6px; }
  .clip audio { margin-top: 4px; }
</style>
</head>
<body>
<h1>Voice Design</h1>
<p class="sub">Describe a voice in natural language. The model will generate speech matching that description.</p>

<label for="instruct">Voice Description</label>
<textarea id="instruct" rows="3" placeholder="e.g., A deep, warm male voice with a slight rasp. Speaks slowly and deliberately, like a late-night radio host."></textarea>

<label for="text">Sample Text</label>
<textarea id="text" rows="2">Hi! This is a reference clip for my custom voice design. I hope you enjoy the way I sound.</textarea>

<div class="row">
  <div>
    <label for="language">Language</label>
    <select id="language">
      <option value="English" selected>English</option>
      <option value="Chinese">Chinese</option>
      <option value="Japanese">Japanese</option>
      <option value="Korean">Korean</option>
      <option value="German">German</option>
      <option value="French">French</option>
      <option value="Russian">Russian</option>
      <option value="Portuguese">Portuguese</option>
      <option value="Spanish">Spanish</option>
      <option value="Italian">Italian</option>
    </select>
  </div>
  <div>
    <label for="format">Format</label>
    <select id="format">
      <option value="mp3" selected>MP3</option>
      <option value="wav">WAV</option>
      <option value="opus">Opus</option>
      <option value="flac">FLAC</option>
    </select>
  </div>
</div>

<button id="btn" onclick="generate()">Generate Voice</button>
<div id="status"></div>
<div id="result"></div>

<div class="history" id="history-section" style="display:none">
  <h2>Previous Generations</h2>
  <div id="history"></div>
</div>

<script>
const history = [];

async function generate() {
  const btn = document.getElementById('btn');
  const status = document.getElementById('status');
  const result = document.getElementById('result');
  const instruct = document.getElementById('instruct').value.trim();

  if (!instruct) { status.textContent = 'Please enter a voice description.'; return; }

  btn.disabled = true;
  status.textContent = 'Generating... (first request loads the model, may take ~30s)';
  result.innerHTML = '';

  const start = performance.now();
  try {
    const resp = await fetch('generate', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        instruct,
        text: document.getElementById('text').value,
        language: document.getElementById('language').value,
        response_format: document.getElementById('format').value,
      }),
    });

    if (!resp.ok) {
      const err = await resp.json().catch(() => ({ detail: resp.statusText }));
      throw new Error(err.detail || resp.statusText);
    }

    const elapsed = ((performance.now() - start) / 1000).toFixed(1);
    const blob = await resp.blob();
    const url = URL.createObjectURL(blob);
    const fmt = document.getElementById('format').value;

    result.innerHTML = `<audio controls autoplay src="${url}"></audio>`;
    status.textContent = `Generated in ${elapsed}s`;

    // Add to history
    history.unshift({ instruct, url, elapsed, fmt });
    renderHistory();
  } catch (e) {
    status.textContent = `Error: ${e.message}`;
  } finally {
    btn.disabled = false;
  }
}

function renderHistory() {
  if (history.length <= 1) return;
  const section = document.getElementById('history-section');
  const container = document.getElementById('history');
  section.style.display = 'block';
  container.innerHTML = history.slice(1).map(h => `
    <div class="clip">
      <div class="desc">${escHtml(h.instruct)} (${h.elapsed}s)</div>
      <audio controls src="${h.url}"></audio>
    </div>
  `).join('');
}

function escHtml(s) {
  const d = document.createElement('div');
  d.textContent = s;
  return d.innerHTML;
}

// Enter key in instruct textarea triggers generate
document.getElementById('instruct').addEventListener('keydown', e => {
  if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); generate(); }
});
</script>
</body>
</html>"""


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8881)
