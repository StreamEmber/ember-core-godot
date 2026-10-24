"""Fake Falcon auth for the in-game sign-in end-to-end test (POST needs a plain HTTP server).

python fake_falcon.py <port> <eventfabric-port> <report.json>
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CUSTOMER = "11111111-2222-4333-8444-555555555555"
APP = "b68b5dcc-090e-48a9-bb38-e8c16886aab7"
PORT, EF_PORT, REPORT = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
report = {"requests": []}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, status, body=None):
        data = b"" if body is None else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _record(self, body):
        auth = self.headers.get("Authorization", "")
        report["requests"].append({"method": self.command, "path": self.path, "auth": auth, "body": body})
        with open(REPORT, "w") as f:
            json.dump(report, f, indent=1)
        return auth

    def do_GET(self):
        self._record(None)
        if self.path == f"/public/customers/{CUSTOMER}/region":
            return self._send(200, {"code": "tr", "eventFabricUrl": f"http://127.0.0.1:{EF_PORT}"})
        if self.path == f"/public/customers/{CUSTOMER}/applications/{APP}/config":
            return self._send(200, {"revision": "r8", "settings": {"boxes": {"maxAlive": 88}}})
        self._send(404, {"status": 404, "code": "not_found"})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        auth = self._record(body)
        if self.path == "/api/auth/login":
            if body.get("client", {}).get("app"):
                return self._send(400, {"status": 400, "code": "app_unknown", "message": "Unknown or disabled app"})
            if body.get("email") != "ali@example.com" or body.get("password") != "correct horse":
                return self._send(401, {"status": 401, "code": "invalid_credentials", "message": "Username or password is wrong."})
            return self._send(200, {"token": "ses_e2e", "customerUuid": CUSTOMER})
        if self.path == "/api/me/device-keys":
            if auth != "Bearer ses_e2e":
                return self._send(401, {"status": 401, "code": "unauthorized"})
            return self._send(200, {"customerUuid": CUSTOMER, "applicationUuid": APP, "deviceKey": "dek_e2e",
                                    "region": {"code": "tr", "eventFabricUrl": f"http://127.0.0.1:{EF_PORT}"},
                                    "targets": [{"platform": "tiktok", "username": "yayinci"}]})
        if self.path == "/api/auth/logout":
            return self._send(204)
        self._send(404, {"status": 404, "code": "not_found"})


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
