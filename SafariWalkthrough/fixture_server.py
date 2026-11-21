#!/usr/bin/env python3
"""Loopback-only disposable website and vault fixture. Never accepts real credentials."""
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOCK = threading.Lock()
STATE = {"mode": "save", "savedURIs": ["https://old.example.invalid"], "events": []}
PAGE = b"""<!doctype html><html lang="en"><meta name="viewport" content="width=device-width">
<title>Disposable Safari AutoFill</title><h1>Disposable Safari AutoFill</h1>
<form onsubmit="return false">
<label for="username">Username</label><input id="username" name="username" autocomplete="username">
<label for="password">Password</label><input id="password" name="password" type="password" autocomplete="current-password">
<button type="button" onclick="report()">Show result</button>
</form><output id="result" aria-live="polite">Form empty</output>
<script>
let last = '';
function report() {
  const user = document.getElementById('username').value;
  const pass = document.getElementById('password').value;
  const key = user + '|' + pass;
  if (key === last) return;
  last = key;
  const filled = user === 'safari-fixture@example.invalid' && pass === 'Disposable-Only-42!';
  document.getElementById('result').textContent = filled ? 'Disposable login filled' : (user || pass ? 'Unexpected form values' : 'Form empty');
  if (user || pass) fetch('/filled', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({valid:filled})});
}
setInterval(report, 200);
</script></html>"""

STATE = {"mode": "save", "savedURIs": ["https://old.example.invalid"], "events": []}

STATE = {"mode": "save", "savedURIs": ["https://old.example.invalid"], "events": []}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass  # No credential values or request bodies in CI logs.

    def reply(self, value, status=200):
        payload = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path.startswith("/login"):
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(PAGE)
        elif self.path == "/state":
            with LOCK:
                self.reply(STATE)
        else:
            self.reply({"error": "not found"}, 404)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")
        with LOCK:
            if self.path == "/reset":
                STATE.clear()
                STATE.update(mode=body.get("mode", "save"), savedURIs=["https://old.example.invalid"], events=[])
                if STATE["mode"] == "matching":
                    STATE["savedURIs"].append("http://127.0.0.1:8765/login")
                self.reply(STATE)
            elif self.path == "/save":
                STATE["events"].append({"type": "save-start"})
                if STATE["mode"] == "failure":
                    STATE["events"].append({"type": "save-failed"})
                    self.reply({"error": "Intentional disposable save failure"}, 500)
                else:
                    STATE["savedURIs"] = body["uris"]
                    STATE["events"].append({"type": "save-success"})
                    self.reply(STATE)
            elif self.path == "/handoff":
                STATE["events"].append({"type": "handoff"})
                self.reply(STATE)
            elif self.path == "/filled":
                STATE["events"].append({"type": "filled", "valid": body.get("valid", False)})
                self.reply(STATE)
            else:
                self.reply({"error": "not found"}, 404)

if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 8765), Handler).serve_forever()
