#!/usr/bin/env python3
"""Ollama GPU dashboard — lists loaded models, offers evict/restart."""

import http.server
import json
import subprocess
import urllib.request
import os

OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434")
PORT = int(os.environ.get("DASHBOARD_PORT", "11435"))

HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ollama</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    background: #f5f5f5; color: #1a1a1a;
    padding: 1rem; max-width: 600px; margin: 0 auto;
  }
  h1 { font-size: 1.25rem; font-weight: 600; margin-bottom: 1rem; }
  .section { background: #fff; border-radius: 8px; padding: 1rem; margin-bottom: 1rem; box-shadow: 0 1px 3px rgba(0,0,0,0.08); }
  .section h2 { font-size: 0.875rem; font-weight: 600; color: #666; text-transform: uppercase; letter-spacing: 0.05em; margin-bottom: 0.75rem; }
  .model { padding: 0.5rem 0; border-bottom: 1px solid #eee; }
  .model:last-child { border-bottom: none; }
  .model-name { font-weight: 600; font-size: 0.95rem; }
  .model-meta { font-size: 0.8rem; color: #888; margin-top: 0.15rem; }
  .empty { color: #999; font-style: italic; font-size: 0.9rem; }
  .error { color: #c00; font-size: 0.9rem; }
  .evict-btn {
    display: block; width: 100%; padding: 0.75rem;
    background: #d32f2f; color: #fff; border: none; border-radius: 8px;
    font-size: 1rem; font-weight: 600; cursor: pointer;
    transition: background 0.15s;
  }
  .evict-btn:hover { background: #b71c1c; }
  .evict-btn:disabled { background: #999; cursor: not-allowed; }
  .status { text-align: center; font-size: 0.85rem; color: #666; margin-top: 0.5rem; min-height: 1.2em; }
</style>
</head>
<body>
<h1>ollama</h1>

<div class="section" id="loaded-section">
  <h2>Loaded Models</h2>
  <div id="loaded">Loading&hellip;</div>
</div>

<div class="section" id="available-section">
  <h2>Available Models</h2>
  <div id="available">Loading&hellip;</div>
</div>

<button class="evict-btn" onclick="evict()">Evict</button>
<div class="status" id="status"></div>

<script>
function fmt(bytes) {
  if (!bytes) return '?';
  const gb = bytes / (1024**3);
  return gb >= 1 ? gb.toFixed(1) + ' GB' : (bytes / (1024**2)).toFixed(0) + ' MB';
}

function timeAgo(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  if (d.getFullYear() > 9000) return 'persistent';
  const s = (Date.now() - d) / 1000;
  if (s < 0) return 'persistent';
  if (s < 60) return Math.floor(s) + 's ago';
  if (s < 3600) return Math.floor(s / 60) + 'm ago';
  if (s < 86400) return Math.floor(s / 3600) + 'h ago';
  return Math.floor(s / 86400) + 'd ago';
}

async function refresh() {
  try {
    const ps = await fetch('/api/ps').then(r => r.json());
    const el = document.getElementById('loaded');
    if (!ps.models || ps.models.length === 0) {
      el.innerHTML = '<div class="empty">No models loaded</div>';
    } else {
      el.innerHTML = ps.models.map(m => `
        <div class="model">
          <div class="model-name">${m.name}</div>
          <div class="model-meta">
            VRAM: ${fmt(m.size_vram)} &middot; RAM: ${fmt(m.size - m.size_vram)}
            &middot; Expires: ${timeAgo(m.expires_at)}
          </div>
        </div>
      `).join('');
    }
  } catch(e) {
    document.getElementById('loaded').innerHTML = '<div class="error">Cannot reach ollama</div>';
  }

  try {
    const tags = await fetch('/api/tags').then(r => r.json());
    const el = document.getElementById('available');
    if (!tags.models || tags.models.length === 0) {
      el.innerHTML = '<div class="empty">No models available</div>';
    } else {
      el.innerHTML = tags.models.map(m => `
        <div class="model">
          <div class="model-name">${m.name}</div>
          <div class="model-meta">${fmt(m.size)} &middot; ${m.details?.parameter_size || ''} &middot; ${m.details?.quantization_level || ''}</div>
        </div>
      `).join('');
    }
  } catch(e) {
    document.getElementById('available').innerHTML = '<div class="error">Cannot reach ollama</div>';
  }
}

async function evict() {
  const btn = document.querySelector('.evict-btn');
  const status = document.getElementById('status');
  btn.disabled = true;
  btn.textContent = 'Restarting\u2026';
  status.textContent = '';
  try {
    const r = await fetch('/evict', { method: 'POST' });
    if (r.ok) {
      status.textContent = 'Restart triggered. Waiting for ollama\u2026';
      await poll();
    } else {
      status.textContent = 'Failed: ' + (await r.text());
    }
  } catch(e) {
    status.textContent = 'Error: ' + e.message;
  }
  btn.disabled = false;
  btn.textContent = 'Evict';
}

async function poll() {
  for (let i = 0; i < 30; i++) {
    await new Promise(r => setTimeout(r, 2000));
    try {
      const r = await fetch('/api/tags');
      if (r.ok) { refresh(); return; }
    } catch {}
  }
  document.getElementById('status').textContent = 'Timed out waiting for ollama';
}

refresh();
setInterval(refresh, 10000);
</script>
</body>
</html>"""


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/" or self.path == "":
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(HTML.encode())
        elif self.path.startswith("/api/"):
            self._proxy_ollama()
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path == "/evict":
            try:
                subprocess.Popen(["systemctl", "restart", "ollama"])
                self.send_response(200)
                self.send_header("Content-Type", "text/plain")
                self.end_headers()
                self.wfile.write(b"ok")
            except Exception as e:
                self.send_response(500)
                self.end_headers()
                self.wfile.write(str(e).encode())
        else:
            self.send_error(404)

    def _proxy_ollama(self):
        try:
            url = OLLAMA_URL + self.path
            req = urllib.request.Request(url)
            with urllib.request.urlopen(req, timeout=5) as resp:
                body = resp.read()
                self.send_response(resp.status)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(body)
        except Exception as e:
            self.send_response(502)
            self.end_headers()
            self.wfile.write(str(e).encode())

    def log_message(self, fmt, *args):
        pass  # quiet


if __name__ == "__main__":
    server = http.server.HTTPServer(("127.0.0.1", PORT), Handler)
    print(f"ollama dashboard on :{PORT}")
    server.serve_forever()
