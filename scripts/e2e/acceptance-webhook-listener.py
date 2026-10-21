import http.server, json, sys, datetime
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('content-length', 0)); b = self.rfile.read(n).decode()
        with open('/Users/ldangelo/Development/Fortium/foreman-wt/accept-scratch/webhook-capture.jsonl', 'a') as f:
            f.write(json.dumps({"at": datetime.datetime.utcnow().isoformat(), "body": json.loads(b)}) + "\n")
        self.send_response(200); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', 47662), H).serve_forever()
