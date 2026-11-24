"""Panda Engine unified API.

One public port (8080) in front of whichever backend is active. The backend
target is read from panda/state/route.json on every request, so a model switch
is visible immediately without restarting this process.

Uses only the Python standard library. Run with:
    python panda/core/router.py [listen_port]
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
PANDA = os.path.dirname(HERE)
REPO = os.path.dirname(PANDA)
ROUTE = os.path.join(PANDA, "state", "route.json")
LOG = os.path.join(REPO, "logs", "panda-router.log")

HOP_BY_HOP = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailer", "transfer-encoding", "upgrade", "host",
}


def log(message):
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        if os.path.exists(LOG) and os.path.getsize(LOG) > 5 * 1024 * 1024:
            os.replace(LOG, LOG[:-4] + ".old.log")
        with open(LOG, "a", encoding="utf-8") as fh:
            fh.write("[%s] %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), message))
    except OSError:
        pass


def read_route():
    """Return (listen_port, target_port, name). target_port 0 means no backend."""
    listen, target, name = 8080, 0, ""
    try:
        # PowerShell 5.1 writes UTF-8 with a BOM; utf-8-sig accepts both forms.
        with open(ROUTE, "r", encoding="utf-8-sig") as fh:
            data = json.load(fh)
        listen = int(data.get("listen", listen))
        target = int(data.get("port", 0))
        name = str(data.get("name", ""))
    except FileNotFoundError:
        pass
    except (ValueError, TypeError, OSError) as exc:
        log("bad route file: %s" % exc)
    return listen, target, name


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "PandaEngine/1.0"

    def log_message(self, fmt, *args):
        pass

    def _json(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def _status(self, target, name):
        up = False
        if target:
            try:
                with urllib.request.urlopen("http://127.0.0.1:%d/health" % target, timeout=2) as resp:
                    up = resp.status == 200
            except Exception:
                pass
        self._json(200, {
            "engine": "Panda Engine",
            "api": "http://127.0.0.1:%d" % self.server.listen_port,
            "active": name,
            "upstream_port": target,
            "upstream_up": up,
        })

    def _read_body(self):
        if "chunked" in self.headers.get("Transfer-Encoding", "").lower():
            data = bytearray()
            while True:
                line = self.rfile.readline().strip()
                if not line:
                    break
                size = int(line.split(b";", 1)[0], 16)
                if size == 0:
                    while True:
                        trailer = self.rfile.readline()
                        if trailer in (b"\r\n", b"\n", b""):
                            break
                    break
                data.extend(self.rfile.read(size))
                self.rfile.read(2)
            return bytes(data) or None
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else None

    def _handle(self):
        _, target, name = read_route()
        if self.path.split("?", 1)[0] == "/_panda/status":
            self._status(target, name)
            return
        if not target:
            self._json(503, {"error": "no active backend", "hint": "press S in Panda Engine"})
            return
        # BaseHTTPRequestHandler already answers Expect: 100-continue in HTTP/1.1.
        body = self._read_body()
        headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP_BY_HOP}
        req = urllib.request.Request(
            "http://127.0.0.1:%d%s" % (target, self.path),
            data=body, method=self.command, headers=headers,
        )
        started = time.time()
        try:
            upstream = urllib.request.urlopen(req, timeout=600)
        except urllib.error.HTTPError as exc:
            payload = exc.read()
            self.send_response(exc.code)
            for key, value in exc.headers.items():
                if key.lower() not in HOP_BY_HOP:
                    self.send_header(key, value)
            self.send_header("Connection", "close")
            self.end_headers()
            if self.command != "HEAD" and payload:
                self.wfile.write(payload)
            log("%s %s -> %d %d %dms" % (
                self.command, self.path, target, exc.code, int((time.time() - started) * 1000)))
            return
        except Exception as exc:
            log("%s %s -> %d FAILED: %s" % (self.command, self.path, target, exc))
            self._json(502, {"error": "upstream unreachable", "port": target, "detail": str(exc)})
            return

        status = upstream.status
        try:
            self.send_response(status)
            for key, value in upstream.headers.items():
                if key.lower() not in HOP_BY_HOP:
                    self.send_header(key, value)
            # No chunked encoding on the way out: the connection closes at the end,
            # which also lets token streams (no Content-Length) reach the client live.
            self.send_header("Connection", "close")
            self.end_headers()
            if self.command != "HEAD":
                while True:
                    chunk = upstream.read1(65536)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            upstream.close()
        log("%s %s -> %d %d %dms" % (
            self.command, self.path, target, status, int((time.time() - started) * 1000)))

    do_GET = _handle
    do_POST = _handle
    do_PUT = _handle
    do_PATCH = _handle
    do_DELETE = _handle
    do_HEAD = _handle
    do_OPTIONS = _handle


def main():
    # The public port is fixed by design; route.json only holds the backend target.
    listen = 8080
    if len(sys.argv) > 1:
        try:
            listen = int(sys.argv[1])
        except ValueError:
            pass
    try:
        server = ThreadingHTTPServer(("127.0.0.1", listen), Handler)
    except OSError as exc:
        log("cannot bind 127.0.0.1:%d: %s" % (listen, exc))
        print("Panda API: cannot bind 127.0.0.1:%d (%s)" % (listen, exc))
        return 1
    server.daemon_threads = True
    server.listen_port = listen
    log("Panda API listening on 127.0.0.1:%d" % listen)
    print("Panda API listening on http://127.0.0.1:%d/v1" % listen, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
