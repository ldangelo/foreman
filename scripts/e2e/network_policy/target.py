"""Local HTTP target of scripts/e2e/network_policy_flow.sh.

Answers every GET with `TARGET-ANSWERED path=<path> host=<Host header>` and appends one JSON line per
request that REACHES it to the capture file: the independent witness of what got through the policy
(a blocked request must leave no line). Bound to 127.0.0.1 only; a container reaches it as
host.docker.internal (OrbStack and Docker Desktop forward that to the host's loopback).

usage: target.py <port> <capture.jsonl>
"""
import datetime
import http.server
import json
import sys

PORT = int(sys.argv[1])
CAPTURE = sys.argv[2]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        host = self.headers.get("Host", "")
        with open(CAPTURE, "a") as f:
            f.write(json.dumps({
                "at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "path": self.path,
                "host": host,
            }) + "\n")
        body = ("TARGET-ANSWERED path=%s host=%s\n" % (self.path, host)).encode()
        self.send_response(200)
        self.send_header("content-type", "text/plain")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
