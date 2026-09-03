#!/usr/bin/env python3
"""
Per-minute admission stub (docs/tpm_admission_plan.md).

Plays a Groq-style free plan: any chat request whose prompt estimate + max_tokens
exceeds LIMIT is refused with Groq's exact HTTP 413 wording and rate-limit headers;
anything that fits gets a normal chat.completions answer (SSE when stream=true) and
the same headers. No credentials, no network beyond localhost.

Usage:
    python3 tests/tools/tpm_stub_server.py            # port 8765, limit 8000
    python3 tests/tools/tpm_stub_server.py 8765 8000 --no-headers   # refusal text only

Then in KOAssistant (desktop build): Settings -> Provider -> Add custom provider,
base URL http://127.0.0.1:8765/v1/chat/completions, no API key, any model name.
Expected: the first request is refused once, the resend fits, later requests are
capped up front (log: "answer budget capped to N"). With --no-headers the plan is
learned from the refusal text instead. The log prints every request's max_tokens.
"""
import json, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].isdigit() else 8765
LIMIT = int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2].isdigit() else 8000
SEND_HEADERS = "--no-headers" not in sys.argv
BYTES_PER_TOKEN = 4


def prompt_tokens(body):
    n = 0
    for m in body.get("messages", []):
        c = m.get("content")
        if isinstance(c, str):
            n += len(c.encode("utf-8"))
        elif isinstance(c, list):
            for part in c:
                if isinstance(part, dict) and isinstance(part.get("text"), str):
                    n += len(part["text"].encode("utf-8"))
    return max(1, n // BYTES_PER_TOKEN)


class Handler(BaseHTTPRequestHandler):
    def _headers(self, requested):
        if not SEND_HEADERS:
            return
        self.send_header("x-ratelimit-limit-tokens", str(LIMIT))
        self.send_header("x-ratelimit-remaining-tokens", str(max(0, LIMIT - requested)))
        self.send_header("x-ratelimit-reset-tokens", "1m0s")
        self.send_header("x-ratelimit-limit-requests", "1000")
        self.send_header("x-ratelimit-remaining-requests", "999")

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        try:
            body = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            body = {}
        model = body.get("model", "stub-model")
        budget = body.get("max_tokens") or body.get("max_completion_tokens")
        est = prompt_tokens(body)
        requested = est + (int(budget) if budget else 65536)
        print(f"[stub] prompt~{est} max_tokens={budget} requested={requested} limit={LIMIT} "
              f"-> {'REFUSE' if requested > LIMIT else 'ok'}", flush=True)

        if requested > LIMIT:
            msg = (f"Request too large for model `{model}` in organization `org_stub` service tier "
                   f"`on_demand` on tokens per minute (TPM): Limit {LIMIT}, Requested {requested}, "
                   f"please reduce your message size and try again.")
            payload = json.dumps({"error": {"message": msg, "type": "tokens", "code": "rate_limit_exceeded"}}).encode()
            self.send_response(413)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self._headers(requested)
            self.end_headers()
            self.wfile.write(payload)
            return

        answer = f"ok (budget {budget}, prompt about {est} tokens, plan {LIMIT}/min)"
        if body.get("stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self._headers(requested)
            self.end_headers()
            for i, word in enumerate(answer.split(" ")):
                chunk = {"id": "stub", "object": "chat.completion.chunk", "model": model,
                         "choices": [{"index": 0, "delta": {"content": ("" if i == 0 else " ") + word},
                                      "finish_reason": None}]}
                self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
                self.wfile.flush()
                time.sleep(0.02)
            done = {"id": "stub", "object": "chat.completion.chunk", "model": model,
                    "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                    "usage": {"prompt_tokens": est, "completion_tokens": 12, "total_tokens": est + 12}}
            self.wfile.write(f"data: {json.dumps(done)}\n\ndata: [DONE]\n\n".encode())
            return

        payload = json.dumps({"id": "stub", "object": "chat.completion", "model": model,
                              "choices": [{"index": 0, "message": {"role": "assistant", "content": answer},
                                           "finish_reason": "stop"}],
                              "usage": {"prompt_tokens": est, "completion_tokens": 12,
                                        "total_tokens": est + 12}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self._headers(requested)
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        payload = json.dumps({"object": "list", "data": [{"id": "stub-model", "object": "model"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self._headers(0)
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    print(f"[stub] listening on http://127.0.0.1:{PORT}  limit={LIMIT} tokens/min  "
          f"headers={'on' if SEND_HEADERS else 'off'}", flush=True)
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
