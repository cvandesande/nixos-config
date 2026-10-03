#!/usr/bin/env python3
"""Model-name router for Claude Code.

Point ANTHROPIC_BASE_URL at this proxy. Requests whose JSON body has a "model"
starting with one of the --local-prefix values go to the local llama-server;
everything else (including unparsable bodies and body-less requests) goes to
Anthropic. Bodies and responses are forwarded as raw bytes, so SSE streaming
and compression pass through untouched. Standard library only.
"""
import argparse
import http.client
import json
import socket
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

# RFC 7230 hop-by-hop headers, never forwarded in either direction.
HOP_BY_HOP = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailer", "transfer-encoding", "upgrade", "proxy-connection",
}
CHUNK = 16 * 1024
MAX_BODY = 256 * 1024 * 1024


class Backend:
    def __init__(self, url):
        u = urlsplit(url)
        self.url = url.rstrip("/")
        self.tls = u.scheme == "https"
        self.host = u.hostname
        self.port = u.port or (443 if self.tls else 80)
        self.host_header = u.netloc
        self.prefix = u.path.rstrip("/")

    def connect(self, timeout):
        cls = http.client.HTTPSConnection if self.tls else http.client.HTTPConnection
        return cls(self.host, self.port, timeout=timeout)


class Handler(BaseHTTPRequestHandler):
    # Close after every request: no keep-alive state to get wrong, and a
    # close-delimited body is valid for streaming responses of unknown length.
    protocol_version = "HTTP/1.0"
    server_version = "claude-router/1.0"

    def log_message(self, fmt, *args):
        pass  # replaced by explicit route logging

    # -- request body ------------------------------------------------------
    def read_body(self):
        te = self.headers.get("Transfer-Encoding", "").lower()
        if "chunked" in te:
            buf = bytearray()
            while True:
                line = self.rfile.readline(1024).split(b";")[0].strip()
                size = int(line or b"0", 16)
                if size == 0:
                    while self.rfile.readline(1024) not in (b"\r\n", b"\n", b""):
                        pass  # trailers
                    return bytes(buf)
                buf += self.rfile.read(size)
                self.rfile.readline(8)  # CRLF after chunk
                if len(buf) > MAX_BODY:
                    raise ValueError("body too large")
        length = int(self.headers.get("Content-Length") or 0)
        if length > MAX_BODY:
            raise ValueError("body too large")
        return self.rfile.read(length) if length else b""

    # -- routing -----------------------------------------------------------
    def pick(self, body):
        cfg = self.server.cfg
        model = None
        if body:
            try:
                data = json.loads(body)
                if isinstance(data, dict) and isinstance(data.get("model"), str):
                    model = data["model"]
            except (ValueError, UnicodeDecodeError):
                pass  # unparsable -> default backend
        local = model is not None and model.startswith(tuple(cfg.local_prefix))
        return (cfg.local if local else cfg.default), model

    # -- local-only request fixups ----------------------------------------
    @staticmethod
    def adapt_local(body):
        """Claude Code puts role="system" messages inside `messages`, which the
        Anthropic API accepts but many chat templates (Qwen's included) reject
        unless the system message comes first. Hoist them into the top-level
        `system` field. Untouched when there is nothing to hoist."""
        try:
            data = json.loads(body)
            msgs = data["messages"]
            hoisted = [m for m in msgs if isinstance(m, dict) and m.get("role") == "system"]
        except (ValueError, KeyError, TypeError):
            return body
        if not hoisted:
            return body
        blocks = []
        for m in hoisted:
            c = m.get("content")
            if isinstance(c, str):
                blocks.append({"type": "text", "text": c})
            elif isinstance(c, list):
                blocks.extend(c)
        sysf = data.get("system")
        if isinstance(sysf, str):
            sysf = [{"type": "text", "text": sysf}]
        data["system"] = (sysf or []) + blocks
        data["messages"] = [m for m in msgs if m not in hoisted]
        return json.dumps(data).encode()

    # -- proxying ----------------------------------------------------------
    def proxy(self):
        try:
            body = self.read_body()
        except (ValueError, OSError) as e:
            return self.fail(400, f"bad request body: {e}")

        backend, model = self.pick(body)
        is_local = backend is self.server.cfg.local
        sys.stderr.write(f"{self.command} {self.path} model={model!r} -> "
                         f"{'LOCAL' if is_local else 'DEFAULT'} {backend.url}\n")

        if is_local:
            body = self.adapt_local(body)

        headers = {}
        for k, v in self.headers.items():
            lk = k.lower()
            if lk in HOP_BY_HOP or lk in ("host", "content-length"):
                continue
            headers[k] = v
        headers["Host"] = backend.host_header
        if body or self.command in ("POST", "PUT", "PATCH"):
            headers["Content-Length"] = str(len(body))

        conn = backend.connect(self.server.cfg.timeout)
        try:
            conn.request(self.command, backend.prefix + self.path, body or None, headers)
            resp = conn.getresponse()
        except (OSError, http.client.HTTPException) as e:
            conn.close()
            return self.fail(502, f"upstream {backend.url} unreachable: {e}")

        try:
            self.send_response_only(resp.status, resp.reason)
            for k, v in resp.getheaders():
                if k.lower() in HOP_BY_HOP:
                    continue
                self.send_header(k, v)
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.flush()
            # read1 returns whatever is available, so SSE events are relayed
            # as they arrive. Raw bytes: Content-Encoding is left untouched.
            while True:
                chunk = resp.read1(CHUNK)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass  # client went away; closing upstream below aborts generation
        except (OSError, http.client.HTTPException) as e:
            sys.stderr.write(f"stream error from {backend.url}: {e}\n")
        finally:
            conn.close()
            self.close_connection = True

    def fail(self, status, msg):
        payload = json.dumps({"type": "error",
                              "error": {"type": "api_error", "message": msg}}).encode()
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(payload)
        except OSError:
            pass
        self.close_connection = True

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_OPTIONS = do_HEAD = proxy


class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 64


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--listen", default="127.0.0.1:8090")
    p.add_argument("--local", default="http://127.0.0.1:8080")
    p.add_argument("--default", default="https://api.anthropic.com")
    p.add_argument("--local-prefix", action="append", default=None,
                   help="model-name prefix routed to --local (repeatable; default: qwen)")
    p.add_argument("--timeout", type=float, default=3600,
                   help="upstream socket timeout in seconds (local generation can be slow)")
    cfg = p.parse_args()
    cfg.local_prefix = cfg.local_prefix or ["qwen"]
    cfg.local, cfg.default = Backend(cfg.local), Backend(cfg.default)
    host, _, port = cfg.listen.rpartition(":")
    srv = Server((host or "127.0.0.1", int(port)), Handler)
    srv.cfg = cfg
    sys.stderr.write(f"listening on {cfg.listen}; prefixes {cfg.local_prefix} -> "
                     f"{cfg.local.url}, else {cfg.default.url}\n")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
