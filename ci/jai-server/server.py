# Serves /data/jai.zip to a GET /jai.zip whose "Authorization: Bearer <password>" matches JAI_PASSWORD.
# Fly's edge terminates TLS (and HTTP/2) for <app>.fly.dev; this listens on plain HTTP inside the VM.
import hmac, os, shutil
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PASSWORD = os.environ["JAI_PASSWORD"].encode()
ZIP = "/data/jai.zip"

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        got = self.headers.get("Authorization", "").encode()
        if self.path != "/jai.zip" or not hmac.compare_digest(got, b"Bearer " + PASSWORD):
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        with open(ZIP, "rb") as f:
            self.send_response(200)
            self.send_header("Content-Type", "application/zip")
            self.send_header("Content-Length", str(os.fstat(f.fileno()).st_size))
            self.end_headers()
            shutil.copyfileobj(f, self.wfile, 1 << 20)

    def log_message(self, fmt, *args):
        print(self.address_string(), self.command, self.path.split("?")[0], args[1] if len(args) > 1 else "", flush=True)

ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
