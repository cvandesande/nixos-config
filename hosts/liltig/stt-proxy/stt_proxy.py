#!/usr/bin/env python3
"""stt_proxy.py -- OpenAI-shaped speech to text that hands the backend a WAV.

POST /v1/audio/transcriptions here as you would to OpenAI: ffmpeg decodes the file part -- browser
webm/opus, mp3, m4a, ogg -- to the 16 kHz mono 16-bit PCM WAV Qwen3-ASR takes (halogen issue #223
asks for opus input), every other field is forwarded unchanged, and the answer comes back as it
stands. GET /v1/audio/voices exists only to fill Open WebUI's voice dropdown, which has no halogen
route to read it from; /v1/audio/speech is relayed untouched. GET /healthz checks that ffmpeg is on
PATH. Stdlib only, like ./claude-router; the upstream version of this trick,
nr23730/openai-stt-ffmpeg-proxy, is cited rather than vendored.
"""

import argparse
import http.client
import json
import logging
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import uuid
from email import policy
from email.parser import BytesParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

log = logging.getLogger("stt-proxy")

# Qwen3-ASR's shape: 16 kHz mono 16-bit PCM. An upload already in it is forwarded untouched.
TARGET_RATE = 16000
TARGET_BITS = 16

# Set from argv in main(); read at request time.
UP_PATH = "/v1/audio/transcriptions"
SPEECH_PATH = "/v1/audio/speech"
VOICES_PATH = "/v1/audio/voices"
UPSTREAM = "http://127.0.0.1:8731"
MAX_BYTES = 200 * 1024 * 1024
UP_TIMEOUT = 300
WAV_TIMEOUT = 180

# The nine speaker names Qwen3-TTS CustomVoice ships. Halogen picks the voice from the request;
# this only names what the dropdown may show.
VOICES = [
    "aiden", "dylan", "eric", "ono_anna", "ryan",
    "serena", "sohee", "uncle_fu", "vivian",
]


def wav_shape(body: bytes) -> tuple[str, int, int, int] | None:
    """Return (codec, channels, rate, bits) for a PCM WAV, else None."""
    if len(body) < 44 or body[:4] != b"RIFF" or body[8:12] != b"WAVE":
        return None
    fmt = int.from_bytes(body[20:22], "little")
    channels = int.from_bytes(body[22:24], "little")
    rate = int.from_bytes(body[24:28], "little")
    bits = int.from_bytes(body[34:36], "little")
    return ("pcm_s16le" if fmt == 1 else f"fmt{fmt}"), channels, rate, bits


def needs_conversion(body: bytes) -> bool:
    """True unless the body is already 16 kHz mono 16-bit PCM."""
    return wav_shape(body) != ("pcm_s16le", 1, TARGET_RATE, TARGET_BITS)


def parse_multipart(content_type: str, body: bytes) -> tuple[dict[str, str], bytes, str]:
    """Split a multipart body into (fields, file bytes, filename); the first file part wins.

    Bytes come from get_payload(decode=True) and the part kind from its disposition, never its
    MIME type: a client handing over a bare file object -- requests and aiohttp both do -- sends
    no Content-Type, which under RFC 2045 reads as text/plain, so get_content() would corrupt
    every byte above 0x7F. Curl sends audio/mpeg and hides this; test from a real client.
    """
    raw_head = (
        b"MIME-Version: 1.0\r\nContent-Type: "
        + content_type.encode("latin-1")
        + b"\r\n\r\n"
        + body
    )
    msg = BytesParser(policy=policy.default).parsebytes(raw_head)
    fields: dict[str, str] = {}
    file_bytes: bytes = b""
    filename: str = ""
    for part in msg.iter_parts():
        name = part.get_param("name", header="content-disposition")
        if not isinstance(name, str):
            continue
        payload = part.get_payload(decode=True)
        payload = b"" if payload is None else (payload if isinstance(payload, bytes) else str(payload).encode())
        part_name = part.get_filename()
        if part_name:
            if not file_bytes:
                file_bytes = payload
                filename = os.path.basename(part_name)  # logged and echoed back, never a path
        else:
            fields[name] = payload.decode("utf-8", "replace")
    return fields, file_bytes, filename


def build_multipart(fields: dict[str, str], file_bytes: bytes, filename: str) -> tuple[bytes, str]:
    """Rebuild the request as audio/wav, keeping every field the client sent."""
    boundary = uuid.uuid4().hex
    out: list[bytes] = []
    for key, value in fields.items():
        out.append(
            f'--{boundary}\r\nContent-Disposition: form-data; name="{key}"\r\n\r\n{value}\r\n'.encode()
        )
    out.append(
        f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{filename}"\r\n'
        "Content-Type: audio/wav\r\n\r\n".encode()
    )
    out.append(file_bytes)
    out.append(f"\r\n--{boundary}--\r\n".encode())
    return b"".join(out), boundary


def to_wav(body: bytes) -> bytes:
    """Run ffmpeg over the upload and return the WAV bytes. Raises on any failure.

    One TemporaryDirectory per request, gone when the block ends either way, so no path built from
    a client's bytes is ever a filesystem argument.
    """
    with tempfile.TemporaryDirectory(prefix="stt-") as work:
        src = pathlib.Path(work, "upload")
        dst = pathlib.Path(work, "out.wav")
        try:
            with src.open("wb") as sink:
                sink.write(body)
        except OSError as exc:
            raise RuntimeError(f"cannot stage the upload for ffmpeg: {exc}") from exc
        cmd = [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
            "-i", str(src), "-vn", "-dn", "-sn",
            "-ac", "1", "-ar", str(TARGET_RATE), "-c:a", "pcm_s16le", str(dst),
        ]
        proc = subprocess.run(cmd, capture_output=True, timeout=WAV_TIMEOUT, check=False)
        if proc.returncode != 0:
            tail = proc.stderr.decode("utf-8", "replace").strip().splitlines()[-3:]
            raise RuntimeError("ffmpeg could not decode the upload: " + " | ".join(tail))
        try:
            with dst.open("rb") as wav:
                return wav.read()
        except OSError as exc:
            raise RuntimeError(f"ffmpeg left no readable WAV behind: {exc}") from exc


def post(url: str, body: bytes, ctype: str) -> tuple[int, bytes, str]:
    """Forward the request and relay (status, body, content type) untouched."""
    target = urlsplit(url)
    if target.scheme not in ("http", "https"):
        raise ValueError(f"upstream scheme must be http or https, not {target.scheme or 'none'}")
    if target.hostname is None:
        raise ValueError(f"upstream {url} names no host")
    conn_cls = http.client.HTTPSConnection if target.scheme == "https" else http.client.HTTPConnection
    conn = conn_cls(target.netloc, timeout=UP_TIMEOUT)
    try:
        conn.request(
            "POST",
            target.path or "/",
            body=body,
            headers={
                "Content-Type": ctype,
                "Content-Length": str(len(body)),
                "Host": target.netloc,
            },
        )
        reply = conn.getresponse()
        return reply.status, reply.read(), reply.getheader("Content-Type", "application/json")
    finally:
        conn.close()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, status: int, body: bytes, ctype: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _fail(self, status: int, message: str) -> None:
        payload = json.dumps({"error": {"message": message, "type": "invalid_request_error"}}).encode()
        self._send(status, payload, "application/json")

    def _reject(self, status: int, message: str) -> None:
        """Refuse and hang up. Answering a POST while its body is still in flight would leave
        those bytes to be read as the next request line on a kept-alive connection."""
        log.info("refused with %d: %s", status, message)
        self.close_connection = True
        self._fail(status, message)

    def read_body(self) -> bytes:
        """The request body, whether the sender stated a Content-Length or used chunked encoding.

        Open WebUI posts with aiohttp, which streams a file part as chunked with no Content-Length
        at all, while curl and requests always state one. Raises ValueError on a body it will not
        take, so the caller can answer 400 with the reason.
        """
        if "chunked" in (self.headers.get("Transfer-Encoding") or "").lower():
            return self._read_chunked()
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError as exc:
            raise ValueError("Content-Length is not a number") from exc
        if length <= 0:
            raise ValueError("expected a multipart body")
        if length > MAX_BYTES:
            raise ValueError(f"upload of {length} bytes is over the {MAX_BYTES} byte limit")
        return self.rfile.read(length)

    def _read_chunked(self) -> bytes:
        """Decode a chunked body, refusing one that grows past MAX_BYTES."""
        parts: list[bytes] = []
        total = 0
        while True:
            line = self.rfile.readline(64)
            if not line:
                raise ValueError("chunked body ended mid-transfer")
            size = line.split(b";")[0].strip()
            try:
                n = int(size, 16)
            except ValueError as exc:
                raise ValueError(f"bad chunk size {size[:16]!r}") from exc
            if n == 0:
                while True:  # chunk extensions and trailers, if any were sent
                    trailer = self.rfile.readline(1024)
                    if trailer in (b"\r\n", b"\n", b""):
                        break
                break
            total += n
            if total > MAX_BYTES:
                raise ValueError(f"upload is over the {MAX_BYTES} byte limit")
            parts.append(self.rfile.read(n))
            self.rfile.read(2)  # the CRLF closing each chunk
        return b"".join(parts)

    def do_GET(self) -> None:  # noqa: N802 -- http.server's own name
        if self.path.split("?")[0].rstrip("/") == VOICES_PATH.rstrip("/"):
            # The shape Open WebUI reads at routers/audio/__init__.py:1650: {id, name} per voice.
            payload = json.dumps({"voices": [{"id": v, "name": v} for v in VOICES]}).encode()
            log.info("served %d voice names", len(VOICES))
            self._send(200, payload, "application/json")
        elif self.path.rstrip("/") == "/healthz":
            if shutil.which("ffmpeg"):
                self._send(200, b'{"status":"ok"}\n', "application/json")
            else:
                self._send(503, b'{"status":"no ffmpeg on PATH"}\n', "application/json")
        else:
            self._fail(404, f"no route {self.path}")

    def do_POST(self) -> None:  # noqa: N802 -- http.server's own name
        route = self.path.split("?")[0]
        if route not in (UP_PATH, SPEECH_PATH):
            self._reject(404, f"no route {self.path}; this proxy serves {UP_PATH} and {SPEECH_PATH}")
            return

        try:
            body = self.read_body()
        except ValueError as exc:
            self._reject(400, str(exc))
            return

        if route == SPEECH_PATH:
            self._relay_speech(body)
            return

        ctype = self.headers.get("Content-Type", "")
        if "multipart/form-data" not in ctype:
            self._reject(400, f"expected multipart/form-data, got {ctype or 'nothing'}")
            return

        try:
            fields, file_bytes, filename = parse_multipart(ctype, body)
            if not file_bytes:
                self._reject(400, "no file part in the request")
                return
            if "model" not in fields:
                self._reject(400, "no model named in the request")
                return

            locale = fields.get("language", "")
            if "-" in locale:
                # Qwen3-ASR knows bare subtags and answers 400 for "en-US", so cut the locale down.
                fields["language"] = locale.split("-", 1)[0].lower()
                log.info("language %r forwarded as %r", locale, fields["language"])

            arrived = wav_shape(file_bytes) or ("not a wav", 0, 0, 0)
            if needs_conversion(file_bytes):
                before = len(file_bytes)
                file_bytes = to_wav(file_bytes)
                log.info("%s: %s -> wav %d B from %d B, model %s",
                         filename, ",".join(map(str, arrived)), len(file_bytes), before, fields["model"])
            else:
                log.info("%s: already the target wav, passed through", filename)

            body, boundary = build_multipart(fields, file_bytes, filename or "clip.wav")
            status, reply, rctype = post(
                UPSTREAM.rstrip("/") + UP_PATH, body, f"multipart/form-data; boundary={boundary}"
            )
            log.info("%s -> upstream %d (%d B out, %d B back)", fields["model"], status, len(body), len(reply))
            self._send(status, reply, rctype)
        except Exception as exc:  # the client gets the reason, the journal gets the traceback
            log.exception("request failed")
            self._reject(502, f"{type(exc).__name__}: {exc}")

    def _relay_speech(self, body: bytes) -> None:
        """Hand a speech request to halogen as it stands and send its audio straight back.

        No work on the JSON: halogen takes the same voice names Open WebUI sent and checks no key.
        """
        try:
            status, reply, rctype = post(
                UPSTREAM.rstrip("/") + SPEECH_PATH,
                body,
                self.headers.get("Content-Type", "application/json"),
            )
            log.info("speech -> upstream %d (%d B out, %d B back)", status, len(body), len(reply))
            self._send(status, reply, rctype)
        except Exception as exc:  # same rule as the transcription path above
            log.exception("speech relay failed")
            self._reject(502, f"{type(exc).__name__}: {exc}")

    def log_message(self, format: str, *args: object) -> None:  # noqa: A002 -- base signature
        """Quiet http.server's access log; the log.info calls above carry the request."""


def main() -> int:
    global UP_PATH, UPSTREAM, MAX_BYTES, UP_TIMEOUT, WAV_TIMEOUT, VOICES

    ap = argparse.ArgumentParser(description="OpenAI-shaped STT proxy that hands the backend WAV")
    ap.add_argument("--listen", default="127.0.0.1:8765")
    ap.add_argument("--upstream", default=UPSTREAM, help="base URL of the OpenAI-compatible backend")
    ap.add_argument("--path", default=UP_PATH, help="transcription path, on the client and upstream")
    ap.add_argument("--max-mb", type=int, default=200, help="largest upload accepted")
    ap.add_argument("--upstream-timeout", type=int, default=300, help="seconds to wait on the backend")
    ap.add_argument("--ffmpeg-timeout", type=int, default=180, help="seconds to wait on ffmpeg")
    ap.add_argument("--voices", default=",".join(VOICES), help="comma list of TTS voice names to offer")
    cfg = ap.parse_args()

    UPSTREAM, UP_PATH = cfg.upstream, cfg.path
    VOICES = [v.strip() for v in cfg.voices.split(",") if v.strip()]
    MAX_BYTES, UP_TIMEOUT, WAV_TIMEOUT = cfg.max_mb * 1024 * 1024, cfg.upstream_timeout, cfg.ffmpeg_timeout

    logging.basicConfig(stream=sys.stderr, level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        log.error("no ffmpeg on PATH; refusing to start")
        return 1

    host, _, port = cfg.listen.rpartition(":")
    try:
        server = ThreadingHTTPServer((host or "127.0.0.1", int(port)), Handler)
    except ValueError as exc:
        log.error("--listen %s wants HOST:PORT: %s", cfg.listen, exc)
        return 1
    log.info("listening on %s; %s -> %s%s with %s", cfg.listen, UP_PATH, UPSTREAM, UP_PATH, ffmpeg)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("shutting down")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
