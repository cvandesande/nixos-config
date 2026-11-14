"""OpenAI-compatible front end for openvino_genai, sized for a single NPU.

Deliberately small: one model per service and one generation in flight, because
`ov_genai.LLMPipeline` is not thread-safe and the NPU serialises anyway -- queueing
here instead of inside the pipeline keeps a second client from corrupting the first.
The Qwen3 thinking switch is handled server-side (ENABLE_THINKING, per-request
`enable_thinking` or `chat_template_kwargs`) so clients send plain OpenAI requests
and get text in `message.content` instead of an empty field with the answer hiding
in `reasoning_content`.

Env:
  MODEL_PATH        required, directory with openvino_model.xml + model_config.json
  MODEL_NAME        served name, defaults to the MODEL_PATH basename
  DEVICE            NPU (default), CPU or GPU
  MAX_PROMPT_LEN    pin the static NPU window; leave unset unless PLUGIN_CONFIG also
                    carries the NPUW_* chunk options (see below)
  CACHE_DIR         NPU compile-blob cache; bump the directory when NPUW_* change
  PLUGIN_CONFIG     extra pipeline properties as JSON, e.g. NPUW_MOE_TOKEN_CHUNK_SIZE
  ENABLE_THINKING   default thinking mode when a request does not ask (false)
  MAX_NEW_TOKENS    cap when a request sends no max_tokens (512)

openvino-genai, fastapi and pydantic come from the pinned venv under /var/lib/ovgenai,
which the host interpreter cannot see, hence the import check below staying quiet.
"""

# pyright: reportMissingImports=false

import json
import os
import queue
import threading
import time
import uuid
from collections.abc import Callable
from typing import Any

import openvino_genai as ov_genai
from fastapi import FastAPI
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel


def setting(name: str, default: Any, cast: Callable[[str], Any] = str) -> Any:
    """Read an env var, falling back to `default` on anything unparseable."""
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    if cast is bool:
        return raw.strip().lower() in ("1", "true", "yes")
    try:
        return cast(raw)
    except ValueError:
        print(f"ignoring {name}={raw!r}, using {default}", flush=True)
        return default


MODEL_PATH = os.environ["MODEL_PATH"]
MODEL_NAME = os.environ.get("MODEL_NAME") or os.path.basename(MODEL_PATH.rstrip("/"))
DEVICE = os.environ.get("DEVICE", "NPU")
MAX_PROMPT_LEN = setting("MAX_PROMPT_LEN", None, int)
CACHE_DIR = os.environ.get("CACHE_DIR") or None
ENABLE_THINKING = setting("ENABLE_THINKING", False, bool)
MAX_NEW_TOKENS = setting("MAX_NEW_TOKENS", 512, int)
# Qwen3's own non-thinking sampling settings, from the model card.
TEMPERATURE = setting("TEMPERATURE", 0.7, float)
TOP_P = setting("TOP_P", 0.8, float)
TOP_K = setting("TOP_K", 20, int)

app = FastAPI(title="ovgenai", version="1")
_pipeline = None
_gen_lock = threading.Lock()
_load_lock = threading.Lock()


def pipeline() -> ov_genai.LLMPipeline:
    """Build the pipeline on first use, so a load failure is an HTTP error not a crash loop."""
    global _pipeline
    if _pipeline is not None:
        return _pipeline
    with _load_lock:
        if _pipeline is not None:
            return _pipeline
        try:
            props = json.loads(os.environ.get("PLUGIN_CONFIG") or "{}")
        except ValueError as exc:
            raise RuntimeError(f"PLUGIN_CONFIG is not valid JSON: {exc}") from exc
        if DEVICE == "NPU" and MAX_PROMPT_LEN:
            # Pinning the window is opt-in: on this NF4 MoE export it also drags in the
            # NPUW prefill/MoE chunk options, or reshape shape inference dies with a garbage
            # dimension (`Requested output shape [1,1,1,4096] is incompatible`). Left unset,
            # GenAI picks its own window, loads in seconds and needs no NPUW options -- which
            # is why the card example works and OVMS, which must pin one, does not.
            props.setdefault("MAX_PROMPT_LEN", MAX_PROMPT_LEN)
        if CACHE_DIR:
            props.setdefault("CACHE_DIR", CACHE_DIR)
        t0 = time.time()
        pipe = ov_genai.LLMPipeline(MODEL_PATH, DEVICE, **props)
        print(f"loaded {MODEL_NAME} on {DEVICE} in {time.time() - t0:.1f}s", flush=True)
        _pipeline = pipe
    return _pipeline


class ChatMessage(BaseModel):
    role: str = "user"
    content: Any = ""

    def text(self) -> str:
        """OpenAI clients may send a string or a list of content parts; pi sends parts."""
        if isinstance(self.content, str):
            return self.content
        if isinstance(self.content, list):
            out = []
            for part in self.content:
                if isinstance(part, dict) and part.get("type") in ("text", "input_text"):
                    out.append(str(part.get("text", "")))
                elif isinstance(part, dict) and part.get("image"):
                    out.append("[image ignored: text-only model]")
            return "\n".join(out)
        return str(self.content)


class ChatRequest(BaseModel):
    model: str | None = None
    messages: list[ChatMessage]
    max_tokens: int | None = None
    temperature: float | None = None
    top_p: float | None = None
    top_k: int | None = None
    stream: bool = False
    enable_thinking: bool | None = None
    chat_template_kwargs: dict | None = None


class CompletionRequest(BaseModel):
    model: str | None = None
    prompt: str = ""
    max_tokens: int | None = None
    stream: bool = False
    temperature: float | None = None
    top_p: float | None = None
    top_k: int | None = None


def wants_thinking(req) -> bool:
    return ENABLE_THINKING if req.enable_thinking is None else req.enable_thinking


def gen_config(req) -> ov_genai.GenerationConfig:
    gc = ov_genai.GenerationConfig()
    gc.max_new_tokens = min(req.max_tokens or MAX_NEW_TOKENS, MAX_NEW_TOKENS)
    gc.temperature = TEMPERATURE if req.temperature is None else req.temperature
    gc.top_p = TOP_P if req.top_p is None else req.top_p
    gc.top_k = TOP_K if req.top_k is None else req.top_k
    gc.do_sample = (gc.temperature or 0) > 0
    return gc


def render(req, thinking: bool) -> str:
    extra = dict(req.chat_template_kwargs or {})
    # The Qwen template only emits <|im_end|> when thinking is on, so asking for
    # reasoning costs tokens that never reach `content`.
    extra.setdefault("enable_thinking", thinking)
    msgs = [{"role": m.role, "content": m.text()} for m in req.messages]
    prompt = pipeline().get_tokenizer().apply_chat_template(
        msgs, add_generation_prompt=True, extra_context=extra
    )
    if not thinking:
        # This export's thinking-off branch closes the block with the turn-end token instead
        # of the thinking-close token, so the model keeps thinking. Repair the tail.
        bad = THINK_OPEN + chr(10) * 2 + TURN_END + chr(10) * 2
        good = THINK_OPEN + chr(10) * 2 + THINK_CLOSE + chr(10) * 2
        if prompt.endswith(bad):
            prompt = prompt[: -len(bad)] + good
    return prompt


# This export's thinking block is <|im_start|>...<|im_end|> (not the chat template's
# <|im_start|>/<|im_end|> turn markers), and `enable_thinking: false` does not suppress it
# because the template injects an empty *thinking* block instead of closing one -- so the
# generation prompt lands inside an open think block. Splitting the reply is what works.
THINK_OPEN = chr(60) + "think" + chr(62)
THINK_CLOSE = chr(60) + chr(47) + "think" + chr(62)
TURN_END = chr(60) + "|im_end|" + ">"



def split_reasoning(text: str) -> tuple[str, str]:
    if THINK_CLOSE in text:
        head, tail = text.split(THINK_CLOSE, 1)
        return tail.strip("\n"), head.replace(THINK_OPEN, "").strip()
    return text.replace(THINK_OPEN, "").lstrip("\n"), ""


class Sink:
    """Stream lines out of generate(); returns RUNNING so generation continues.

    GenAI reads the callback's return as a StreamingStatus, where RUNNING is 0 --
    a plain `return True` means STOP and truncates the answer after one chunk.

    This export thinks whatever the request asks and closes the block with `<|im_end|>`
    only after the monologue is over, so every token before the first marker is reasoning:
    hold the whole stream in the buffer until that marker arrives (emitting nothing), then
    pass text through as content. A budget that dies before the marker leaves the buffer to
    drain() at stream end, same as before -- truncated content, never leaked reasoning.
    """

    def __init__(self, q: queue.Queue):
        self.q = q
        self.buf = ""
        self.in_think = True

    def __call__(self, *args):
        for a in args:
            if not (isinstance(a, str) and a):
                continue
            if self.in_think:
                self.buf += a
                if THINK_CLOSE in self.buf:
                    head, self.buf = self.buf.split(THINK_CLOSE, 1)
                    self.q.put(("reasoning", head.replace(THINK_OPEN, "")))
                    self.buf = self.buf.lstrip("\n")
                    self.in_think = False
                    if self.buf:
                        self.q.put(("content", self.buf))
                        self.buf = ""
            else:
                self.q.put(("content", a))
        return ov_genai.StreamingStatus.RUNNING


def drain(stream: Sink, q: queue.Queue):
    if stream.buf:
        q.put(("content", stream.buf))
        stream.buf = ""
    q.put(("done", None))


def chunk(cid, created, model, delta, finish=None):
    return {
        "id": cid,
        "object": "chat.completion.chunk",
        "created": created,
        "model": model,
        "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
    }


def sse(payload) -> str:
    return f"data: {json.dumps(payload, ensure_ascii=False)}\n\n"


def stream_reply(req, prompt, gc, cid, created):
    if os.environ.get("OV_DEBUG"):
        print(f"STREAM max_new={gc.max_new_tokens} thinking={req.enable_thinking}", flush=True)
    q: queue.Queue = queue.Queue()

    def worker():
        with _gen_lock:
            pipe = pipeline()
            sink = Sink(q)
            try:
                pipe.generate([prompt], gc, streamer=sink)
            except Exception as exc:  # surfaced as an in-stream error event
                q.put(("error", f"{type(exc).__name__}: {exc}"))
            else:
                drain(sink, q)
            finally:
                _ = pipe

    threading.Thread(target=worker, daemon=True).start()
    content_len = 0

    def gen():
        nonlocal content_len
        yield sse(chunk(cid, created, req.model or MODEL_NAME, {"role": "assistant", "content": ""}))
        while True:
            kind, payload = q.get()
            if kind == "done":
                yield sse(chunk(cid, created, req.model or MODEL_NAME, {}, "stop"))
                yield "data: [DONE]\n\n"
                return
            if kind == "error":
                yield "event: error\ndata: " + json.dumps({"error": {"message": payload}}) + "\n\n"
                yield "data: [DONE]\n\n"
                return
            key = "reasoning_content" if kind == "reasoning" else "content"
            if key == "content":
                content_len += len(payload)
            yield sse(chunk(cid, created, req.model or MODEL_NAME, {key: payload}))

    return StreamingResponse(gen(), media_type="text/event-stream")


@app.get("/health")
def health():
    return {
        "status": "ok",
        "model": MODEL_NAME,
        "device": DEVICE,
        "loaded": _pipeline is not None,
        "thinking": ENABLE_THINKING,
        "max_prompt_len": MAX_PROMPT_LEN,
    }


@app.get("/v1/models")
def models():
    return {
        "object": "list",
        "data": [
            {
                "id": MODEL_NAME,
                "object": "model",
                "created": int(time.time()),
                "owned_by": "openvino-genai",
                "root": MODEL_PATH,
            }
        ],
    }


@app.post("/v1/embeddings")
def embeddings():
    return JSONResponse(
        status_code=501,
        content={"error": {"message": "embeddings need a separate embedding model"}},
    )


@app.post("/v1/chat/completions")
def chat(req: ChatRequest):
    if os.environ.get("OV_DEBUG"):
        small = req.model_dump(exclude={"messages"})
        small["n_messages"] = len(req.messages)
        small["msg_chars"] = [len(m.text()) for m in req.messages]
        print("REQ " + json.dumps(small, ensure_ascii=False)[:400], flush=True)
    cid = f"chatcmpl-{uuid.uuid4().hex[:24]}"
    created = int(time.time())
    gc = gen_config(req)
    thinking = wants_thinking(req)
    prompt = render(req, thinking)
    if req.stream:
        return stream_reply(req, prompt, gc, cid, created)
    with _gen_lock:
        # The list form is what carries perf metrics; a bare string prompt returns a plain str.
        result = pipeline().generate([prompt], gc)
    text = result.texts[0]
    usage = result.perf_metrics
    tps = usage.get_throughput().mean
    content, reasoning = split_reasoning(text)
    if os.environ.get("OV_DEBUG"):
        print(f"RES gen_tokens={len(text)} content={len(content)} reasoning={len(reasoning)}", flush=True)
    n_prompt = usage.get_num_input_tokens() or 0
    try:
        n_new = usage.get_num_generated_tokens() or 0
    except AttributeError:  # older GenAI bindings
        n_new = 0
    body = {
        "id": cid,
        "object": "chat.completion",
        "created": created,
        "model": req.model or MODEL_NAME,
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": content, **({"reasoning_content": reasoning} if reasoning else {})},
                "finish_reason": "stop",
            }
        ],
        "usage": {
            "prompt_tokens": n_prompt,
            "completion_tokens": n_new,
            "total_tokens": n_prompt + n_new,
        },
    }
    return {**body, "metrics": {"decode_tps": tps or None}}


@app.post("/v1/completions")
def completions(req: CompletionRequest):
    chat_req = ChatRequest(model=req.model, messages=[ChatMessage(role="user", content=req.prompt)],
                           max_tokens=req.max_tokens, temperature=req.temperature,
                           top_p=req.top_p, top_k=req.top_k, stream=req.stream)
    return chat(chat_req)
