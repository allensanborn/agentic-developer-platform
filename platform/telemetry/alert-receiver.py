"""Alertmanager's webhook receiver (platform/telemetry/alert-receiver.yaml).

Logs each alert Alertmanager delivers as one JSON line on stdout, which `kubectl logs`
shows and a log shipper can collect. Pointing alertmanager.yml at a real endpoint (n8n,
a ticketing hook) replaces this. Standard library only.
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


class Receiver(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        for alert in body.get("alerts", []):
            print(json.dumps({"status": alert.get("status"), "labels": alert.get("labels"),
                              "summary": alert.get("annotations", {}).get("summary"),
                              "startsAt": alert.get("startsAt")}), flush=True)
        self.send_response(200)
        self.end_headers()

    def log_message(self, *args):  # one line per alert, not per request
        pass


if __name__ == "__main__":
    print("alert receiver listening on :8080", file=sys.stderr, flush=True)
    HTTPServer(("", 8080), Receiver).serve_forever()
