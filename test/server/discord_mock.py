#!/usr/bin/env python3
import http.server
import socketserver

LOGFILE = "/var/log/discord-mock/requests.log"


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        with open(LOGFILE, "ab") as f:
            f.write(body)
            if not body.endswith(b"\n"):
                f.write(b"\n")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    with socketserver.TCPServer(("0.0.0.0", 8080), Handler) as httpd:
        httpd.serve_forever()
