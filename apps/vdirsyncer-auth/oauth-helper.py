#!/usr/bin/env python3
"""
OAuth helper for vdirsyncer Google Calendar integration.

Handles the OAuth flow and writes a token file compatible with vdirsyncer.
"""

import json
import os
import time
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlencode, parse_qs, urlparse
import requests

# Configuration from environment
CLIENT_ID = os.environ.get("OAUTH_CLIENT_ID", "")
CLIENT_SECRET = os.environ.get("OAUTH_CLIENT_SECRET", "")
REDIRECT_URI = os.environ.get("OAUTH_REDIRECT_URI", "")
TOKEN_FILE = os.environ.get("TOKEN_FILE", "/var/lib/vdirsyncer/token")
PORT = int(os.environ.get("PORT", "8088"))

GOOGLE_AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token"
SCOPES = ["https://www.googleapis.com/auth/calendar"]


class OAuthHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Log to stdout for journald
        print(f"{self.address_string()} - {format % args}")

    def do_GET(self):
        parsed = urlparse(self.path)

        if parsed.path == "/":
            self.handle_index()
        elif parsed.path == "/start":
            self.handle_start()
        elif parsed.path == "/callback":
            self.handle_callback(parsed.query)
        elif parsed.path == "/status":
            self.handle_status()
        else:
            self.send_error(404)

    def handle_index(self):
        token_exists = os.path.exists(TOKEN_FILE)
        token_status = self.get_token_status() if token_exists else None

        html = f"""<!DOCTYPE html>
<html>
<head>
    <title>vdirsyncer OAuth</title>
    <style>
        body {{ font-family: system-ui, sans-serif; max-width: 600px; margin: 50px auto; padding: 20px; }}
        .btn {{ display: inline-block; padding: 12px 24px; background: #4285f4; color: white;
                text-decoration: none; border-radius: 4px; font-size: 16px; }}
        .btn:hover {{ background: #357abd; }}
        .status {{ padding: 16px; border-radius: 4px; margin: 20px 0; }}
        .status.ok {{ background: #e6f4ea; border: 1px solid #34a853; }}
        .status.warn {{ background: #fef7e0; border: 1px solid #fbbc04; }}
        .status.none {{ background: #f1f3f4; border: 1px solid #dadce0; }}
    </style>
</head>
<body>
    <h1>vdirsyncer OAuth</h1>
    {"<div class='status ok'><strong>Token exists</strong><br>" + token_status + "</div>" if token_status else
     "<div class='status none'>No token configured yet.</div>"}
    <p><a href="/start" class="btn">{"Re-authorize" if token_exists else "Authorize"} Google Calendar</a></p>
    <p style="color: #666; font-size: 14px;">
        This will request read/write access to your Google Calendar for vdirsyncer sync.
    </p>
</body>
</html>"""
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(html.encode())

    def handle_start(self):
        params = {
            "client_id": CLIENT_ID,
            "redirect_uri": REDIRECT_URI,
            "response_type": "code",
            "scope": " ".join(SCOPES),
            "access_type": "offline",
            "prompt": "consent",  # Force consent to get refresh token
        }
        auth_url = f"{GOOGLE_AUTH_URL}?{urlencode(params)}"
        self.send_response(302)
        self.send_header("Location", auth_url)
        self.end_headers()

    def handle_callback(self, query_string):
        params = parse_qs(query_string)

        if "error" in params:
            self.send_error(400, f"OAuth error: {params['error'][0]}")
            return

        if "code" not in params:
            self.send_error(400, "Missing authorization code")
            return

        code = params["code"][0]

        # Exchange code for tokens
        try:
            response = requests.post(GOOGLE_TOKEN_URL, data={
                "client_id": CLIENT_ID,
                "client_secret": CLIENT_SECRET,
                "code": code,
                "grant_type": "authorization_code",
                "redirect_uri": REDIRECT_URI,
            })
            response.raise_for_status()
            token_data = response.json()
        except Exception as e:
            self.send_error(500, f"Token exchange failed: {e}")
            return

        # Add expires_at for vdirsyncer compatibility
        if "expires_in" in token_data:
            token_data["expires_at"] = time.time() + token_data["expires_in"]

        # Write token file
        try:
            os.makedirs(os.path.dirname(TOKEN_FILE), exist_ok=True)
            with open(TOKEN_FILE, "w") as f:
                json.dump(token_data, f, indent=2)
            os.chmod(TOKEN_FILE, 0o640)  # Group-readable for dev user
            print(f"Token written to {TOKEN_FILE}")
        except Exception as e:
            self.send_error(500, f"Failed to write token: {e}")
            return

        html = """<!DOCTYPE html>
<html>
<head>
    <title>Authorization Complete</title>
    <style>
        body { font-family: system-ui, sans-serif; max-width: 600px; margin: 50px auto; padding: 20px; }
        .success { padding: 16px; background: #e6f4ea; border: 1px solid #34a853; border-radius: 4px; }
    </style>
</head>
<body>
    <h1>Authorization Complete</h1>
    <div class="success">
        <strong>Success!</strong> Token has been saved. vdirsyncer can now sync your calendar.
    </div>
    <p><a href="/">Back to status</a></p>
</body>
</html>"""
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(html.encode())

    def handle_status(self):
        """JSON endpoint for programmatic status checks."""
        status = {"token_exists": os.path.exists(TOKEN_FILE)}
        if status["token_exists"]:
            try:
                with open(TOKEN_FILE) as f:
                    token = json.load(f)
                status["has_refresh_token"] = "refresh_token" in token
                if "expires_at" in token:
                    status["expires_at"] = token["expires_at"]
                    status["expired"] = time.time() > token["expires_at"]
            except Exception:
                status["error"] = "Failed to read token"

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(status, indent=2).encode())

    def get_token_status(self):
        try:
            with open(TOKEN_FILE) as f:
                token = json.load(f)
            has_refresh = "refresh_token" in token
            if "expires_at" in token:
                remaining = token["expires_at"] - time.time()
                if remaining > 0:
                    hours = int(remaining / 3600)
                    return f"Access token expires in {hours}h. Refresh token: {'yes' if has_refresh else 'no'}"
                else:
                    return f"Access token expired. Refresh token: {'yes' if has_refresh else 'no'}"
            return f"Refresh token: {'yes' if has_refresh else 'no'}"
        except Exception:
            return "Unable to read token details"


def main():
    if not all([CLIENT_ID, CLIENT_SECRET, REDIRECT_URI]):
        print("ERROR: Missing required environment variables:")
        print(f"  OAUTH_CLIENT_ID: {'set' if CLIENT_ID else 'MISSING'}")
        print(f"  OAUTH_CLIENT_SECRET: {'set' if CLIENT_SECRET else 'MISSING'}")
        print(f"  OAUTH_REDIRECT_URI: {'set' if REDIRECT_URI else 'MISSING'}")
        exit(1)

    print(f"Starting OAuth helper on port {PORT}")
    print(f"Redirect URI: {REDIRECT_URI}")
    print(f"Token file: {TOKEN_FILE}")

    server = HTTPServer(("0.0.0.0", PORT), OAuthHandler)
    server.serve_forever()


if __name__ == "__main__":
    main()
