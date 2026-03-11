#!/usr/bin/env python3
"""Treeline - Shelly relay control panel."""

import json
import urllib.request
import urllib.error
from http.server import HTTPServer, BaseHTTPRequestHandler
import os

SHELLY_HOST = os.environ.get("SHELLY_HOST", "192.168.68.68")
PORT = int(os.environ.get("PORT", "8090"))

HTML = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Treeline</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    background: #f5f5f5;
    color: #333;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    height: 100dvh;
    -webkit-tap-highlight-color: transparent;
    user-select: none;
  }
  h1 { font-size: 1.2rem; font-weight: 500; color: #888; margin-bottom: 2rem; }
  #btn {
    width: 160px;
    height: 160px;
    border-radius: 50%;
    border: none;
    cursor: pointer;
    background: #ccc;
    box-shadow: 0 4px 20px rgba(0,0,0,0.15);
    transition: background 0.3s, box-shadow 0.3s, transform 0.1s;
    display: flex;
    align-items: center;
    justify-content: center;
  }
  #btn:active { transform: scale(0.95); }
  #btn.on {
    background: #4caf50;
    box-shadow: 0 4px 30px rgba(76,175,80,0.4);
  }
  #btn.error {
    background: #e57373;
    box-shadow: 0 4px 30px rgba(229,115,115,0.4);
  }
  #btn svg { width: 48px; height: 48px; fill: white; }
  #status {
    margin-top: 1.5rem;
    font-size: 0.9rem;
    color: #aaa;
    height: 1.2em;
  }
</style>
</head>
<body>
<h1>Treeline</h1>
<button id="btn" onclick="toggle()">
  <svg viewBox="0 0 24 24"><path d="M13 3h-2v10h2V3zm4.83 2.17l-1.42 1.42A6.92 6.92 0 0 1 19 12c0 3.87-3.13 7-7 7s-7-3.13-7-7c0-2.05.88-3.89 2.29-5.17L5.88 5.46A8.93 8.93 0 0 0 3 12a9 9 0 1 0 18 0c0-2.74-1.23-5.18-3.17-6.83z"/></svg>
</button>
<div id="status"></div>
<script>
const btn = document.getElementById('btn');
const status = document.getElementById('status');

async function refresh() {
  try {
    const r = await fetch('/api/status');
    const d = await r.json();
    btn.className = d.on ? 'on' : '';
    status.textContent = d.on ? 'On' : 'Off';
  } catch {
    btn.className = 'error';
    status.textContent = 'Unreachable';
  }
}

async function toggle() {
  btn.style.pointerEvents = 'none';
  try {
    const r = await fetch('/api/toggle', { method: 'POST' });
    const d = await r.json();
    btn.className = d.on ? 'on' : '';
    status.textContent = d.on ? 'On' : 'Off';
  } catch {
    btn.className = 'error';
    status.textContent = 'Unreachable';
  }
  btn.style.pointerEvents = '';
}

refresh();
setInterval(refresh, 10000);
</script>
</body>
</html>"""


def shelly_rpc(method, params=None):
    url = f"http://{SHELLY_HOST}/rpc/{method}"
    data = json.dumps(params or {}).encode()
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=5) as resp:
        return json.loads(resp.read())


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/api/status":
            try:
                result = shelly_rpc("Switch.GetStatus", {"id": 0})
                self.json_response({"on": result.get("output", False)})
            except Exception:
                self.json_response({"on": False, "error": "unreachable"}, 502)
        elif self.path == "/healthz":
            self.json_response({"ok": True})
        else:
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(HTML.encode())

    def do_POST(self):
        if self.path == "/api/toggle":
            try:
                shelly_rpc("Switch.Toggle", {"id": 0})
                result = shelly_rpc("Switch.GetStatus", {"id": 0})
                self.json_response({"on": result.get("output", False)})
            except Exception:
                self.json_response({"on": False, "error": "unreachable"}, 502)
        else:
            self.send_response(404)
            self.end_headers()

    def json_response(self, data, code=200):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def log_message(self, fmt, *args):
        pass  # quiet


if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", PORT), Handler)
    print(f"treeline listening on :{PORT}")
    server.serve_forever()
