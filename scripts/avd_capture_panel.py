#!/usr/bin/env python3
"""AVD Shell Root 端到端捕获面板。

用途：在 Mac 宿主上启动一个最小 Komari 面板，绑定 0.0.0.0（含 10.0.2.2 网关别名），
让 AVD 上运行的 agent 真实上报 BasicInfo / Report WS / 任务结果，并把收到的**原始载荷**
落盘为证据，供 docs/android-shell-root-analysis.md 与 avd-module-test-report.md 引用。

与 scripts/mock_komari_*.py 的区别：那些脚本面向 CI 内的本地子进程 agent，绑定 127.0.0.1；
本脚本专为"agent 在 AVD 内、面板在宿主上"设计，只做捕获与断言，不 spawn agent。
"""
import argparse
import base64
import gzip
import hashlib
import json
import os
import struct
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def websocket_accept(key: str) -> str:
    return base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()


class State:
    def __init__(self, token, outdir):
        self.token = token
        self.outdir = outdir
        self.lock = threading.Lock()
        self.counts = {"basic_info": 0, "v2_rpc": 0, "report": 0, "task_result": 0}
        self.ws_connected = threading.Event()
        self.errors = []

    def record(self, kind, obj):
        with self.lock:
            self.counts[kind] = self.counts.get(kind, 0) + 1
        path = os.path.join(self.outdir, f"{kind}.jsonl")
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(obj, ensure_ascii=False) + "\n")

    def fail(self, msg):
        with self.lock:
            self.errors.append(msg)
        sys.stderr.write(f"[capture] ERROR: {msg}\n")
        sys.stderr.flush()


def read_ws_frame(rfile):
    hdr = rfile.read(2)
    if len(hdr) < 2:
        return None, None
    b1, b2 = hdr[0], hdr[1]
    opcode = b1 & 0x0F
    masked = b2 & 0x80
    length = b2 & 0x7F
    if length == 126:
        length = struct.unpack(">H", rfile.read(2))[0]
    elif length == 127:
        length = struct.unpack(">Q", rfile.read(8))[0]
    mask = rfile.read(4) if masked else None
    payload = rfile.read(length) if length else b""
    if mask:
        payload = bytes(payload[i] ^ mask[i % 4] for i in range(len(payload)))
    return opcode, payload


def make_handler(state):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            return

        def _send(self, code, body=b""):
            self.send_response(code)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if body:
                self.wfile.write(body)

        def do_POST(self):
            parsed = urlparse(self.path)
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length) if length else b""
            query = parse_qs(parsed.query)
            path = parsed.path

            if path == "/api/clients/uploadBasicInfo":
                self._basic_info(query, raw, v2=False)
            elif path == "/api/clients/v2/rpc":
                self._basic_info(query, raw, v2=True)
            elif path == "/api/clients/task/result":
                self._task_result(query, raw)
            else:
                state.fail(f"unexpected POST {path}")
                self._send(404, b"not found")

        def _check_token(self, query):
            got = query.get("token", [""])[0]
            if got != state.token:
                state.fail(f"bad token: {got!r}")
                self._send(403, b"bad token")
                return False
            return True

        def _basic_info(self, query, raw, v2):
            if not self._check_token(query):
                return
            body = raw
            encoding = (self.headers.get("Content-Encoding") or "").lower()
            if "gzip" in encoding:
                body = gzip.decompress(raw)
            try:
                payload = json.loads(body.decode("utf-8"))
            except Exception as exc:
                state.fail(f"bad json: {exc}; raw={raw[:400]!r}")
                self._send(400, b"bad json")
                return
            record = {
                "received_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
                "content_encoding": self.headers.get("Content-Encoding"),
                "user_agent": self.headers.get("User-Agent"),
                "payload": payload,
            }
            state.record("v2_rpc" if v2 else "basic_info", record)
            if v2:
                # 真实 v2 面板会返回 JSON-RPC 结果；返回合法响应避免 agent 走 v1 fallback。
                resp = json.dumps({"jsonrpc": "2.0", "id": payload.get("id"), "result": None}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(resp)))
                self.end_headers()
                self.wfile.write(resp)
                return
            self._send(200, b"ok")

        def _task_result(self, query, raw):
            if not self._check_token(query):
                return
            try:
                payload = json.loads(raw.decode("utf-8"))
            except Exception as exc:
                state.fail(f"bad task json: {exc}")
                self._send(400, b"bad json")
                return
            state.record("task_result", {"received_at": time.strftime("%Y-%m-%dT%H:%M:%S"), "payload": payload})
            self._send(200, b"ok")

        def do_GET(self):
            parsed = urlparse(self.path)
            if parsed.path == "/api/clients/report":
                self._report_ws(parsed)
            else:
                state.fail(f"unexpected GET {parsed.path}")
                self._send(404, b"not found")

        def _report_ws(self, parsed):
            query = parse_qs(parsed.query)
            if not self._check_token(query):
                return
            key = self.headers.get("Sec-WebSocket-Key")
            if not key:
                state.fail("missing websocket key")
                self._send(400, b"missing key")
                return
            self.send_response(101, "Switching Protocols")
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", websocket_accept(key))
            self.end_headers()
            state.ws_connected.set()
            sys.stderr.write("[capture] report websocket connected\n")
            sys.stderr.flush()
            try:
                while True:
                    opcode, payload = read_ws_frame(self.rfile)
                    if opcode is None:
                        break
                    if opcode == 0x8:
                        break
                    if opcode in (0x1, 0x2):
                        text = payload.decode("utf-8", "replace")
                        try:
                            obj = json.loads(text)
                        except Exception:
                            obj = {"raw": text}
                        state.record("report", {
                            "received_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
                            "opcode": opcode,
                            "payload": obj,
                        })
            except Exception as exc:
                state.fail(f"ws read error: {exc}")
            finally:
                sys.stderr.write("[capture] report websocket closed\n")
                sys.stderr.flush()

    return Handler


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--token", default="avd-token")
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=25774)
    ap.add_argument("--outdir", default=".narrafork/avd-probe/evidence")
    ap.add_argument("--seconds", type=float, default=120.0)
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)
    for name in ("basic_info", "v2_rpc", "report", "task_result"):
        p = os.path.join(args.outdir, f"{name}.jsonl")
        if os.path.exists(p):
            os.remove(p)

    state = State(args.token, args.outdir)
    server = ThreadingHTTPServer((args.bind, args.port), make_handler(state))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    sys.stderr.write(f"[capture] listening on {args.bind}:{args.port} token={args.token} outdir={args.outdir}\n")
    sys.stderr.flush()

    deadline = time.monotonic() + args.seconds
    while time.monotonic() < deadline:
        time.sleep(0.5)

    server.shutdown()
    summary = {
        "listening": f"{args.bind}:{args.port}",
        "token": args.token,
        "counts": state.counts,
        "ws_connected": state.ws_connected.is_set(),
        "errors": state.errors,
    }
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
