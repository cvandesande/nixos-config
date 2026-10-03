#!/usr/bin/env python3
"""Tests for router.py: fake upstreams for deterministic cases, plus the real
llama-server on :8080 when it is up (skipped otherwise)."""
import gzip
import http.client
import json
import socket
import subprocess
import sys
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).parent


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Fake(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, name):
        super().__init__(("127.0.0.1", 0), FakeHandler)
        self.name = name
        self.seen = []
        self.aborted = threading.Event()
        threading.Thread(target=self.serve_forever, daemon=True).start()


class FakeHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_GET(self):
        self.do_POST()

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n)
        self.server.seen.append((self.command, self.path, dict(self.headers), body))
        if self.path.endswith("/stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            try:
                for i in range(40):
                    ev = f"event: e\ndata: {i}\n\n".encode()
                    self.wfile.write(b"%x\r\n%s\r\n" % (len(ev), ev))
                    self.wfile.flush()
                    time.sleep(0.25)
                self.wfile.write(b"0\r\n\r\n")
            except (BrokenPipeError, ConnectionResetError):
                self.server.aborted.set()
            return
        if self.path.endswith("/gzip"):
            payload = gzip.compress(json.dumps({"from": self.server.name}).encode())
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Encoding", "gzip")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        payload = json.dumps({"from": self.server.name, "len": len(body)}).encode()
        self.send_response(int(self.headers.get("X-Want-Status", 200)))
        self.send_header("Content-Type", "application/json")
        self.send_header("X-Upstream-Host", self.headers.get("Host", ""))
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def request(port, method, path, body=None, headers=None, raw_body=None):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
    if raw_body is None and body is not None:
        raw_body = json.dumps(body).encode()
    c.request(method, path, raw_body, headers or {})
    return c, c.getresponse()


class RouterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.local, cls.default = Fake("local"), Fake("default")
        cls.port = free_port()
        cls.proc = subprocess.Popen(
            [sys.executable, str(HERE / "router.py"),
             "--listen", f"127.0.0.1:{cls.port}",
             "--local", f"http://127.0.0.1:{cls.local.server_port}",
             "--default", f"http://127.0.0.1:{cls.default.server_port}"],
            stderr=subprocess.PIPE)
        for _ in range(50):
            try:
                socket.create_connection(("127.0.0.1", cls.port), 0.2).close()
                break
            except OSError:
                time.sleep(0.1)

    @classmethod
    def tearDownClass(cls):
        cls.proc.terminate()
        cls.proc.wait()

    def setUp(self):
        self.local.seen.clear()
        self.default.seen.clear()
        self.local.aborted.clear()
        self.default.aborted.clear()

    def post(self, path, body=None, headers=None, **kw):
        c, r = request(self.port, "POST", path, body, headers, **kw)
        data = r.read()
        c.close()
        return r, data

    def test_routes_by_model(self):
        r, d = self.post("/v1/messages", {"model": "qwen3.8-flash-next-coding"})
        self.assertEqual(json.loads(d)["from"], "local")
        r, d = self.post("/v1/messages", {"model": "claude-sonnet-5-5"})
        self.assertEqual(json.loads(d)["from"], "default")

    def test_unknown_unparsable_and_bodyless_go_default(self):
        for kw in ({"raw_body": b"not json"}, {"body": {"no": "model"}},
                   {"body": {"model": 7}}, {"raw_body": b"[1,2]"}):
            r, d = self.post("/v1/messages", kw.get("body"), raw_body=kw.get("raw_body"))
            self.assertEqual(json.loads(d)["from"], "default", kw)
        c, r = request(self.port, "GET", "/v1/models")
        self.assertEqual(json.loads(r.read())["from"], "default")
        c.close()

    def test_headers_passthrough_and_host_rewrite(self):
        h = {"x-api-key": "sk-test", "anthropic-version": "2023-06-01",
             "anthropic-beta": "a,b", "Authorization": "Bearer tok",
             "Connection": "keep-alive", "Content-Type": "application/json"}
        r, d = self.post("/v1/messages?beta=true", {"model": "claude-x"}, h)
        method, path, seen, body = self.default.seen[0]
        self.assertEqual(path, "/v1/messages?beta=true")
        lower = {a.lower(): b for a, b in seen.items()}
        for k in ("x-api-key", "anthropic-version", "anthropic-beta", "authorization"):
            self.assertEqual(lower[k], h[k] if k != "authorization" else h["Authorization"])
        self.assertEqual(seen["Host"], f"127.0.0.1:{self.default.server_port}")
        self.assertEqual(r.getheader("X-Upstream-Host"), seen["Host"])

    def test_system_messages_hoisted_for_local_only(self):
        body = {"model": "qwen-x", "system": [{"type": "text", "text": "S0"}],
                "messages": [{"role": "user", "content": "hi"},
                             {"role": "system", "content": [{"type": "text", "text": "S1"}]},
                             {"role": "system", "content": "S2"}]}
        self.post("/v1/messages", body)
        sent = json.loads(self.local.seen[0][3])
        self.assertEqual([m["role"] for m in sent["messages"]], ["user"])
        self.assertEqual([b["text"] for b in sent["system"]], ["S0", "S1", "S2"])
        body["model"] = "claude-x"
        raw = json.dumps(body).encode()
        self.post("/v1/messages", None, raw_body=raw)
        self.assertEqual(self.default.seen[0][3], raw)  # byte-identical

    def test_local_body_without_system_messages_untouched(self):
        raw = b'{"model":  "qwen-x",   "messages":[{"role":"user","content":"hi"}]}'
        self.post("/v1/messages", None, raw_body=raw)
        self.assertEqual(self.local.seen[0][3], raw)

    def test_large_body_exact(self):
        big = {"model": "qwen-x", "pad": "x" * 5_000_000}
        r, d = self.post("/v1/messages", big)
        self.assertEqual(json.loads(d)["len"], len(json.dumps(big)))

    def test_chunked_request_body(self):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=30)
        payload = json.dumps({"model": "qwen-x", "pad": "y" * 70000}).encode()

        def gen():
            for i in range(0, len(payload), 10000):
                yield payload[i:i + 10000]
        c.request("POST", "/v1/messages", gen(),
                  {"Transfer-Encoding": "chunked", "Content-Type": "application/json"},
                  encode_chunked=True)
        r = c.getresponse()
        d = json.loads(r.read())
        self.assertEqual(d["from"], "local")
        self.assertEqual(d["len"], len(payload))

    def test_status_codes_forwarded(self):
        for code in (400, 404, 429, 529):
            r, d = self.post("/v1/messages", {"model": "claude-x"},
                             {"X-Want-Status": str(code)})
            self.assertEqual(r.status, code)

    def test_streaming_is_incremental(self):
        c, r = request(self.port, "POST", "/stream", {"model": "qwen-x"})
        t0 = time.time()
        first = r.fp.readline()  # first SSE line must arrive long before the end
        t_first = time.time() - t0
        self.assertIn(b"event: e", first)
        self.assertLess(t_first, 1.0)
        self.assertEqual(r.getheader("Content-Type"), "text/event-stream")
        c.close()

    def test_streaming_full_content(self):
        c, r = request(self.port, "POST", "/stream", {"model": "claude-x"})
        got = b""
        t0 = time.time()
        stamps = []
        while True:
            line = r.fp.readline()
            if not line:
                break
            got += line
            if line.startswith(b"data:"):
                stamps.append(time.time() - t0)
        c.close()
        self.assertEqual(got.count(b"data:"), 40)
        self.assertGreater(stamps[-1] - stamps[0], 5)  # spread over time, not one burst

    def test_gzip_passthrough_untouched(self):
        c, r = request(self.port, "POST", "/gzip", {"model": "claude-x"},
                       {"Accept-Encoding": "gzip"})
        raw = r.read()
        c.close()
        self.assertEqual(r.getheader("Content-Encoding"), "gzip")
        self.assertEqual(json.loads(gzip.decompress(raw))["from"], "default")

    def test_hop_by_hop_not_forwarded(self):
        self.post("/v1/messages", {"model": "claude-x"},
                  {"Keep-Alive": "timeout=5", "TE": "trailers",
                   "Proxy-Authorization": "x"})
        seen = {k.lower() for k in self.default.seen[0][2]}
        for k in ("keep-alive", "te", "proxy-authorization", "transfer-encoding"):
            self.assertNotIn(k, seen)

    def test_client_disconnect_aborts_upstream(self):
        sock = socket.create_connection(("127.0.0.1", self.port))
        body = json.dumps({"model": "qwen-x"}).encode()
        sock.sendall(b"POST /stream HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n%s"
                     % (len(body), body))
        while b"data:" not in sock.recv(4096):
            pass
        sock.close()  # client vanishes mid-stream
        self.assertTrue(self.local.aborted.wait(10), "upstream stream was not aborted")

    def test_negative_content_length_rejected(self):
        for n in (-5, -1):  # -1 would block forever in rfile.read(-1) if unchecked
            sock = socket.create_connection(("127.0.0.1", self.port), 5)
            try:
                sock.sendall(b"POST /v1/messages HTTP/1.1\r\nHost: x\r\n"
                             b"Content-Length: %d\r\n\r\n" % n)
                line = sock.recv(64).split(b"\r\n")[0]
                # router speaks HTTP/1.0; assert only the status code
                self.assertEqual(line.split(b" ")[1], b"400", (n, line))
            finally:
                sock.close()

    def test_upstream_down_gives_502(self):
        port = free_port()
        p2 = free_port()
        proc = subprocess.Popen([sys.executable, str(HERE / "router.py"),
                                 "--listen", f"127.0.0.1:{p2}",
                                 "--local", f"http://127.0.0.1:{port}"],
                                stderr=subprocess.DEVNULL)
        try:
            for _ in range(50):
                try:
                    socket.create_connection(("127.0.0.1", p2), 0.2).close()
                    break
                except OSError:
                    time.sleep(0.1)
            c, r = request(p2, "POST", "/v1/messages", {"model": "qwen-x"})
            self.assertEqual(r.status, 502)
            self.assertEqual(json.loads(r.read())["type"], "error")
        finally:
            proc.terminate()
            proc.wait()

    def test_concurrent_streams(self):
        out = []

        def one():
            c, r = request(self.port, "POST", "/stream", {"model": "qwen-x"})
            r.fp.readline()
            out.append(True)
            c.close()
        ts = [threading.Thread(target=one) for _ in range(8)]
        t0 = time.time()
        [t.start() for t in ts]
        [t.join() for t in ts]
        self.assertEqual(len(out), 8)
        self.assertLess(time.time() - t0, 3)


def llama_up():
    try:
        socket.create_connection(("127.0.0.1", 8080), 0.5).close()
        return True
    except OSError:
        return False


@unittest.skipUnless(llama_up(), "llama-server not running on :8080")
class RealLlamaTests(unittest.TestCase):
    """Real llama-server as 'local', fake Anthropic as default."""

    @classmethod
    def setUpClass(cls):
        cls.default = Fake("default")
        cls.port = free_port()
        cls.proc = subprocess.Popen(
            [sys.executable, str(HERE / "router.py"),
             "--listen", f"127.0.0.1:{cls.port}",
             "--default", f"http://127.0.0.1:{cls.default.server_port}"],
            stderr=subprocess.DEVNULL)
        for _ in range(50):
            try:
                socket.create_connection(("127.0.0.1", cls.port), 0.2).close()
                break
            except OSError:
                time.sleep(0.1)

    @classmethod
    def tearDownClass(cls):
        cls.proc.terminate()
        cls.proc.wait()

    H = {"content-type": "application/json", "anthropic-version": "2023-06-01",
         "x-api-key": "dummy"}

    def test_nonstreaming(self):
        c, r = request(self.port, "POST", "/v1/messages",
                       {"model": "qwen3.8-flash-next-coding", "max_tokens": 200,
                        "messages": [{"role": "user", "content": "Say hi"}]}, self.H)
        d = json.loads(r.read())
        self.assertEqual(r.status, 200)
        self.assertEqual(d["type"], "message")
        self.assertTrue(any(b["type"] == "text" for b in d["content"]))

    def test_streaming_sse(self):
        c, r = request(self.port, "POST", "/v1/messages",
                       {"model": "qwen3.8-flash-next-coding", "max_tokens": 200,
                        "stream": True,
                        "messages": [{"role": "user", "content": "Count to five"}]},
                       self.H)
        self.assertEqual(r.status, 200)
        self.assertIn("text/event-stream", r.getheader("Content-Type"))
        body = r.read().decode()
        self.assertIn("event: message_start", body)
        self.assertIn("event: message_stop", body)

    def test_tool_call(self):
        tools = [{"name": "get_weather", "description": "Get weather for a city",
                  "input_schema": {"type": "object",
                                   "properties": {"city": {"type": "string"}},
                                   "required": ["city"]}}]
        c, r = request(self.port, "POST", "/v1/messages",
                       {"model": "qwen3.8-flash-next-coding", "max_tokens": 1000,
                        "tools": tools, "tool_choice": {"type": "any"},
                        "messages": [{"role": "user",
                                      "content": "What's the weather in Paris?"}]},
                       self.H)
        d = json.loads(r.read())
        self.assertEqual(d["stop_reason"], "tool_use", d)
        tu = [b for b in d["content"] if b["type"] == "tool_use"][0]
        self.assertEqual(tu["name"], "get_weather")

    def test_count_tokens(self):
        c, r = request(self.port, "POST", "/v1/messages/count_tokens",
                       {"model": "qwen3.8-flash-next-coding",
                        "messages": [{"role": "user", "content": "hello"}]}, self.H)
        self.assertGreater(json.loads(r.read())["input_tokens"], 0)

    def test_claude_code_style_midconversation_system(self):
        c, r = request(self.port, "POST", "/v1/messages",
                       {"model": "qwen3.8-flash-next-coding", "max_tokens": 100,
                        "system": [{"type": "text", "text": "You are terse."}],
                        "messages": [{"role": "user", "content": "Say pong"},
                                     {"role": "system", "content": [
                                         {"type": "text", "text": "Env: linux"}]}]},
                       self.H)
        d = json.loads(r.read())
        self.assertEqual(r.status, 200, d)
        self.assertEqual(d["type"], "message")

    def test_claude_model_not_sent_to_llama(self):
        c, r = request(self.port, "POST", "/v1/messages",
                       {"model": "claude-haiku-4-5-20251001", "max_tokens": 5,
                        "messages": [{"role": "user", "content": "x"}]}, self.H)
        self.assertEqual(json.loads(r.read())["from"], "default")


if __name__ == "__main__":
    unittest.main(verbosity=2)
