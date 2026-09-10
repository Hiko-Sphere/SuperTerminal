"""A small HTTP service for a port forward to point at.

Real, and deliberately dull: the forward screenshot is about the forward, not about this.
It listens only on the loopback address inside the container, so reaching it from the
device genuinely requires the tunnel — which is the property being photographed.
"""
import http.server, json, socketserver

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"service": "api", "status": "ok", "path": self.path}, indent=2)
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body.encode())

    def log_message(self, *args):
        pass

with socketserver.TCPServer(("127.0.0.1", 8080), Handler) as httpd:
    httpd.serve_forever()
