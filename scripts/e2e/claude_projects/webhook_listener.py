"""Notification sink for the acceptance harness: appends every POSTed JSON body to a file.

usage: webhook_listener.py <port> <capture.jsonl>
"""
import datetime
import http.server
import json
import sys

PORT = int(sys.argv[1])
CAPTURE = sys.argv[2]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("content-length", 0))
        raw = self.rfile.read(length).decode()
        try:
            body = json.loads(raw)
        except ValueError:
            body = {"unparsed": raw}
        with open(CAPTURE, "a") as f:
            f.write(json.dumps({"at": datetime.datetime.now(datetime.timezone.utc).isoformat(), "body": body}) + "\n")
        self.send_response(200)
        self.end_headers()

    def log_message(self, *args):
        pass


http.server.HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
