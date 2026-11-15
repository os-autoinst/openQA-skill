"""A stand-in model that speaks the OpenAI chat API: on a turn's first request it
answers with one tool call read from CALL_FILE (JSON: {"name": ..., "args": {...}}),
and on the request that carries the tool's result it writes that result to RESULT_FILE
and ends the turn. It lets a real opencode server judge one tool call per turn."""

import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CALL_FILE, RESULT_FILE = sys.argv[1], sys.argv[2]


def chunk(delta=None, finish=None, usage=None):
    body = {
        "id": "c",
        "object": "chat.completion.chunk",
        "created": 0,
        "model": "m",
        "choices": []
        if usage
        else [{"index": 0, "delta": delta or {}, "finish_reason": finish}],
    }
    if usage:
        body["usage"] = usage
    return ("data: " + json.dumps(body) + "\n\n").encode()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        raw = json.dumps(
            {"object": "list", "data": [{"id": "m", "object": "model"}]}
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_POST(self):
        size = int(self.headers.get("Content-Length") or 0)
        request = json.loads(self.rfile.read(size) or b"{}")
        tools = [t["function"]["name"] for t in request.get("tools", [])]
        results = [m for m in request.get("messages", []) if m.get("role") == "tool"]
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        if results:
            with open(RESULT_FILE, "w") as f:
                json.dump(results[-1].get("content"), f)
            parts = [chunk({"role": "assistant", "content": "done"}), chunk({}, "stop")]
        elif not tools:
            parts = [
                chunk({"role": "assistant", "content": "title"}),
                chunk({}, "stop"),
            ]
        else:
            with open(CALL_FILE) as f:
                call = json.load(f)
            name = call["name"]
            if name == "shell" and "shell" not in tools and "bash" in tools:
                name = "bash"
            parts = [
                chunk(
                    {
                        "role": "assistant",
                        "content": None,
                        "tool_calls": [
                            {
                                "index": 0,
                                "id": "call_1",
                                "type": "function",
                                "function": {
                                    "name": name,
                                    "arguments": json.dumps(call["args"]),
                                },
                            }
                        ],
                    }
                ),
                chunk({}, "tool_calls"),
            ]
        parts.append(
            chunk(usage={"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2})
        )
        parts.append(b"data: [DONE]\n\n")
        for part in parts:
            self.wfile.write(part)
        self.wfile.flush()
        self.close_connection = True


ThreadingHTTPServer(("127.0.0.1", 8085), Handler).serve_forever()
