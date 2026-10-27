# Serves /data/jai.zip to a GET /jai.zip whose "Authorization: Bearer <password>" matches JAI_PASSWORD.
# A PUT /jai.zip with UPLOAD_PASSWORD replaces it; CI only holds the download password, so it can't swap the compiler.
# Fly's edge terminates TLS (and HTTP/2) for <app>.fly.dev; this listens on plain HTTP inside the VM.
import hmac, os, shutil
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PASSWORD = os.environ["JAI_PASSWORD"].encode()
UPLOAD_PASSWORD = os.environ.get("UPLOAD_PASSWORD", "").encode()
ZIP = "/data/jai.zip"

class Handler(BaseHTTPRequestHandler):
    def authorized(self, password):
        got = self.headers.get("Authorization", "").encode()
        return self.path == "/jai.zip" and password and hmac.compare_digest(got, b"Bearer " + password)

    def reply(self, code):
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        if not self.authorized(PASSWORD): return self.reply(404)
        with open(ZIP, "rb") as f:
            self.send_response(200)
            self.send_header("Content-Type", "application/zip")
            self.send_header("Content-Length", str(os.fstat(f.fileno()).st_size))
            self.end_headers()
            shutil.copyfileobj(f, self.wfile, 1 << 20)

    def do_PUT(self):
        if not self.authorized(UPLOAD_PASSWORD): return self.reply(404)
        n = int(self.headers["Content-Length"])
        tmp = ZIP + ".upload"
        with open(tmp, "wb") as f:
            while n:
                chunk = self.rfile.read(min(n, 1 << 20))
                if not chunk: break
                f.write(chunk)
                n -= len(chunk)
            f.flush()
            os.fsync(f.fileno())
        if n: os.remove(tmp); return self.reply(400)
        os.replace(tmp, ZIP)
        self.reply(204)

    def log_message(self, fmt, *args):
        print(self.address_string(), self.command, self.path.split("?")[0], args[1] if len(args) > 1 else "", flush=True)

ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
