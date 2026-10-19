#!/usr/bin/env python3
"""AVD 全功能验证面板（Features API 真实实现验收）。

与 scripts/mock_komari_business_e2e.py 的区别：
  那个脚本在 CI 内 spawn 本地 agent 子进程并绑定 127.0.0.1；
  本脚本面向"agent 跑在 AVD 里、面板跑在宿主上"，因此：
    - 不 spawn agent，等外部 agent 连上来
    - 主动下发 exec / terminal / ping 任务，逐项断言设备端真实执行结果
    - 所有断言证据落盘为 jsonl，供 docs/avd-module-test-report.md 引用

用法（宿主）：
  python3 scripts/avd_features_e2e.py --token avd-token --port 25774 --seconds 180
"""
import argparse
import base64
import gzip
import hashlib
import json
import os
import select
import socket
import socketserver
import struct
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def websocket_accept(key: str) -> str:
    return base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()


def wait_readable(sock, timeout):
    """等待 socket 可读。

    必须在整帧可读后再调用 read_ws_frame：直接对 buffered rfile 设超时会在
    帧中途超时并丢弃已读字节，导致流错位、连接被迫重连。
    """
    try:
        ready, _, _ = select.select([sock], [], [], timeout)
        return bool(ready)
    except (OSError, ValueError):
        return False


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


def write_ws_frame(out, opcode, payload):
    header = bytearray([0x80 | opcode])
    n = len(payload)
    if n < 126:
        header.append(n)
    elif n <= 0xFFFF:
        header.append(126)
        header.extend(n.to_bytes(2, "big"))
    else:
        header.append(127)
        header.extend(n.to_bytes(8, "big"))
    out.write(bytes(header) + payload)
    out.flush()


class Results:
    """逐项记录 Features API 的验证结论。"""

    def __init__(self, outdir):
        self.outdir = outdir
        self.lock = threading.Lock()
        self.items = []

    def add(self, name, ok, detail, evidence=None):
        rec = {
            "feature": name,
            "ok": bool(ok),
            "detail": detail,
            "evidence": evidence or {},
            "at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        }
        with self.lock:
            self.items.append(rec)
        with open(os.path.join(self.outdir, "features.jsonl"), "a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
        mark = "PASS" if ok else "FAIL"
        sys.stderr.write(f"[{mark}] {name}: {detail}\n")
        sys.stderr.flush()

    def summary(self):
        with self.lock:
            return {
                "total": len(self.items),
                "passed": sum(1 for i in self.items if i["ok"]),
                "failed": sum(1 for i in self.items if not i["ok"]),
                "features": self.items,
            }


class State:
    def __init__(self, token, outdir):
        self.token = token
        self.outdir = outdir
        self.results = Results(outdir)
        self.basic_info = None
        self.reports = 0
        self.v2_rpc_seen = threading.Event()
        self.report_ws_seen = threading.Event()
        self.exec_done = threading.Event()
        self.exec_recorded = threading.Event()
        self.pull_tasks_sent = threading.Event()
        self.ping_seen = set()
        self.terminal_done = threading.Event()
        self.ping_done = threading.Event()
        self.lock = threading.Lock()

    def record(self, kind, obj):
        path = os.path.join(self.outdir, f"{kind}.jsonl")
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(obj, ensure_ascii=False) + "\n")


def make_handler(state):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            return

        def _plain(self, code, body=b""):
            self.send_response(code)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if body:
                self.wfile.write(body)

        def _check_token(self, query):
            if query.get("token", [""])[0] != state.token:
                state.results.add("auth", False, f"bad token: {query.get('token')!r}")
                self._plain(403, b"bad token")
                return False
            return True

        # ---------- BasicInfo ----------
        def do_POST(self):
            parsed = urlparse(self.path)
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length) if length else b""
            query = parse_qs(parsed.query)
            if parsed.path in ("/api/clients/uploadBasicInfo", "/api/clients/v2/rpc"):
                self._basic_info(query, raw, v2=parsed.path.endswith("/v2/rpc"))
            elif parsed.path == "/api/clients/task/result":
                self._task_result(query, raw)
            else:
                self._plain(404, b"not found")

        def _basic_info(self, query, raw, v2):
            if not self._check_token(query):
                return
            body = raw
            enc = (self.headers.get("Content-Encoding") or "").lower()
            if "gzip" in enc:
                body = gzip.decompress(raw)
            try:
                payload = json.loads(body.decode("utf-8"))
            except Exception as exc:
                state.results.add("basic_info", False, f"bad json: {exc}")
                self._plain(400, b"bad json")
                return

            # v2 下同一个 /api/clients/v2/rpc 端点承载多种 method：
            #   agent.basicInfo / agent.pull / agent.pingResult / agent.taskResult / agent.report
            # 必须按 method 分发，否则会把结果上报误判成 BasicInfo。
            method = payload.get("method") if isinstance(payload, dict) else None
            if v2:
                if method == "agent.pull":
                    self._handle_pull(payload)
                    return
                if method == "agent.pingResult":
                    self._handle_ping_result(payload)
                    return
                if method == "agent.taskResult":
                    self._handle_task_result_rpc(payload)
                    return
                if method == "agent.report":
                    self._handle_report_rpc(payload)
                    return

            info = payload.get("params", {}).get("info") if v2 else payload
            if not isinstance(info, dict):
                state.results.add("basic_info", False, f"unexpected payload shape: {payload!r}"[:300])
                self._plain(400, b"bad shape")
                return

            with state.lock:
                state.basic_info = info
            state.record("v2_rpc" if v2 else "basic_info", {
                "received_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
                "content_encoding": self.headers.get("Content-Encoding"),
                "payload": payload,
            })

            required = ["cpu_name", "cpu_cores", "arch", "os", "mem_total", "version"]
            missing = [k for k in required if k not in info]
            if missing:
                state.results.add("basic_info", False, f"missing fields: {missing}")
            else:
                # 真实性断言：数值必须非零，os 必须识别为 Android
                checks = {
                    "cpu_cores>0": info.get("cpu_cores", 0) > 0,
                    "mem_total>0": info.get("mem_total", 0) > 0,
                    "arch==arm64": info.get("arch") == "arm64",
                    "os_is_android": "Android" in str(info.get("os", "")),
                    "version_nonempty": bool(info.get("version")),
                    "ipv4_set": bool(info.get("ipv4")),
                }
                ok = all(checks.values())
                state.results.add(
                    "basic_info",
                    ok,
                    f"{'all real values' if ok else 'value assertions failed'}: {checks}",
                    {"checks": checks, "info": info},
                )
                if v2:
                    state.v2_rpc_seen.set()

            if v2:
                resp = json.dumps({"jsonrpc": "2.0", "id": payload.get("id"), "result": None}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(resp)))
                self.end_headers()
                self.wfile.write(resp)
                return
            self._plain(200, b"ok")

        # ---------- exec 任务结果 ----------
        def _handle_pull(self, payload):
            """v2 任务下发：agent.pull 的响应里带 events 数组。

            agent 收到后按 event.method 分发到 exec/ping/terminal 处理
            （见 src/protocol/report_ws.zig 与 v2.parseEventResult）。
            """
            req_id = payload.get("id")
            events = []
            if not state.pull_tasks_sent.is_set():
                events.append({
                    "id": "ev-exec-1",
                    "method": "agent.exec",
                    "params": {
                        "task_id": "exec-real",
                        "command": "echo AVD_EXEC_MARKER; id -u; uname -m",
                    },
                })
                for idx, (ptype, target) in enumerate(
                    (("tcp", "10.0.2.2:25774"),
                     ("icmp", "127.0.0.1"),
                     ("http", "http://127.0.0.1:25774/health")),
                    start=101,
                ):
                    events.append({
                        "id": f"ev-ping-{idx}",
                        "method": "agent.ping",
                        "params": {
                            "ping_task_id": idx,
                            "ping_type": ptype,
                            "ping_target": target,
                        },
                    })
                state.pull_tasks_sent.set()
                state.record("pull_tasks_sent", {
                    "at": time.strftime("%Y-%m-%dT%H:%M:%S"),
                    "count": len(events),
                    "methods": [e["method"] for e in events],
                })
                sys.stderr.write(f"[pull] dispatched {len(events)} tasks\n")
                sys.stderr.flush()

            resp = json.dumps({
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {"status": "ok", "events": events},
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(resp)))
            self.end_headers()
            self.wfile.write(resp)

        def _ack(self, payload):
            """JSON-RPC notification 的确认响应（无 id 时也要回 200）。"""
            resp = json.dumps({"jsonrpc": "2.0", "id": payload.get("id"), "result": None}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(resp)))
            self.end_headers()
            self.wfile.write(resp)

        def _handle_ping_result(self, payload):
            params = payload.get("params") or {}
            ptype = params.get("ping_type", "?")
            value = params.get("value", -1)
            state.record("ping_result", {
                "at": time.strftime("%Y-%m-%dT%H:%M:%S"),
                "payload": payload,
            })
            with state.lock:
                if ptype in state.ping_seen:
                    self._ack(payload)
                    return
                state.ping_seen.add(ptype)
            state.results.add(
                f"ping_{ptype}",
                isinstance(value, int) and value >= 0,
                f"value={value}",
                {"ping_type": ptype, "task_id": params.get("task_id")},
            )
            self._ack(payload)

        def _handle_task_result_rpc(self, payload):
            params = payload.get("params") or {}
            result = params.get("result", "")
            task_id = params.get("task_id")
            ok = (
                params.get("exit_code") == 0
                and "AVD_EXEC_MARKER" in str(result)
                and task_id == "exec-real"
            )
            state.record("task_result", {
                "at": time.strftime("%Y-%m-%dT%H:%M:%S"),
                "payload": payload,
            })
            with state.lock:
                if state.exec_recorded.is_set():
                    self._ack(payload)
                    return
                state.exec_recorded.set()
            state.results.add(
                "exec",
                ok,
                f"exit={params.get('exit_code')} marker={'yes' if 'AVD_EXEC_MARKER' in str(result) else 'no'}",
                {"task_id": task_id, "result": str(result)[:500]},
            )
            self._ack(payload)

        def _handle_report_rpc(self, payload):
            params = payload.get("params") or {}
            state.record("report", {"at": time.strftime("%Y-%m-%dT%H:%M:%S"), "payload": params})
            with state.lock:
                state.reports += 1
                count = state.reports
            if count == 3:
                state.results.add(
                    "report_rpc",
                    True,
                    f"received {count} agent.report notifications",
                    {"sample": params},
                )
            self._ack(payload)

        def _task_result(self, query, raw):
            if not self._check_token(query):
                return
            try:
                payload = json.loads(raw.decode("utf-8"))
            except Exception as exc:
                state.results.add("exec", False, f"bad json: {exc}")
                self._plain(400, b"bad json")
                return
            state.record("task_result", {
                "received_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
                "payload": payload,
            })
            result = payload.get("result", "")
            # 设备端真实执行：命令回显的机器标识必须出现
            ok = (
                payload.get("exit_code") == 0
                and "AVD_EXEC_MARKER" in result
                and payload.get("task_id") == "exec-real"
            )
            # 面板重连时会重发任务，同一个 task_id 只记一次结论
            if state.exec_recorded.is_set():
                self._plain(200, b"ok")
                return
            state.exec_recorded.set()
            state.results.add(
                "exec",
                ok,
                f"exit={payload.get('exit_code')} marker={'yes' if 'AVD_EXEC_MARKER' in result else 'no'}",
                {"task_id": payload.get("task_id"), "result": result[:500]},
            )
            state.exec_done.set()
            self._plain(200, b"ok")

        # ---------- Report WebSocket ----------
        def do_GET(self):
            parsed = urlparse(self.path)
            # v2 协议下 Report WS 与 BasicInfo RPC 共用 /api/clients/v2/rpc
            # （见 src/protocol/http.zig reportWsUrlForProtocol），v1 才是 /api/clients/report。
            if parsed.path in ("/api/clients/report", "/api/clients/v2/rpc"):
                self._report_ws(parsed)
            elif parsed.path == "/api/clients/terminal":
                self._terminal_ws(parsed)
            else:
                self._plain(404, b"not found")

        def _upgrade(self):
            key = self.headers.get("Sec-WebSocket-Key")
            if not key:
                self._plain(400, b"missing ws key")
                return False
            self.send_response(101, "Switching Protocols")
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", websocket_accept(key))
            self.end_headers()
            self.wfile.flush()
            self.close_connection = True
            return True

        def _report_ws(self, parsed):
            if not self._check_token(parse_qs(parsed.query)):
                return
            if not self._upgrade():
                return
            state.report_ws_seen.set()
            state.record("report_ws", {"event": "connected", "at": time.strftime("%Y-%m-%dT%H:%M:%S")})
            sys.stderr.write("[report ws] connected\n")
            sys.stderr.flush()

            tasks_sent = False
            deadline = time.monotonic() + 150
            report_shapes = []
            while time.monotonic() < deadline:
                if not tasks_sent:
                    # v2 下 exec/ping 走 agent.pull 的 HTTP 响应下发（见 _handle_pull），
                    # WS 只用于接收上报。这里仅触发 terminal：agent 会另开一条
                    # /api/clients/terminal WS 回来。
                    write_ws_frame(self.wfile, 0x1, json.dumps({
                        "message": "terminal",
                        "request_id": "avd-terminal",
                    }).encode())
                    tasks_sent = True
                    state.record("ws_terminal_requested", {
                        "at": time.strftime("%Y-%m-%dT%H:%M:%S"),
                        "request_id": "avd-terminal",
                    })

                if not wait_readable(self.connection, 1.0):
                    continue
                try:
                    opcode, payload = read_ws_frame(self.rfile)
                except Exception as exc:
                    state.record("report_ws", {"event": "read_error", "error": str(exc)})
                    break
                if opcode is None or opcode == 0x8:
                    break
                if opcode == 0x9:
                    write_ws_frame(self.wfile, 0xA, payload)
                    continue
                if opcode not in (0x1, 0x2):
                    continue
                try:
                    data = json.loads(payload.decode("utf-8", "replace"))
                except Exception:
                    continue

                # 上报载荷
                if "cpu" in data and "ram" in data and "load" in data:
                    with state.lock:
                        state.reports += 1
                    report_shapes.append(data)
                    state.record("report", {"at": time.strftime("%Y-%m-%dT%H:%M:%S"), "payload": data})
                    if state.reports == 3:
                        state.results.add(
                            "report_ws",
                            True,
                            f"received {state.reports} real reports",
                            {"sample": report_shapes[-1]},
                        )

                # ping 结果在 v2 下走 agent.pingResult 的 RPC 上报，
                # 由 _handle_ping_result 处理；WS 上只接收周期上报。
                if data.get("type") not in (None, "ping_result") and "cpu" not in data:
                    state.record("ws_other", {"at": time.strftime("%Y-%m-%dT%H:%M:%S"), "payload": data})

            state.record("report_ws", {"event": "closed", "reports": state.reports})

        # ---------- Terminal (Web SSH) ----------
        def _terminal_ws(self, parsed):
            q = parse_qs(parsed.query)
            if not self._check_token(q):
                return
            term_id = q.get("id", [""])[0]
            if term_id != "avd-terminal":
                self._plain(404, b"unexpected terminal id")
                return
            if not self._upgrade():
                return
            state.record("terminal", {"event": "connected", "id": term_id,
                                      "at": time.strftime("%Y-%m-%dT%H:%M:%S")})
            sys.stderr.write(f"[terminal ws] connected id={term_id}\n")
            sys.stderr.flush()

            # 真实交互：设置尺寸 -> 输入命令 -> 读回显
            write_ws_frame(self.wfile, 0x1, json.dumps({"type": "resize", "cols": 100, "rows": 30}).encode())
            time.sleep(1.0)
            write_ws_frame(self.wfile, 0x1, json.dumps({
                "type": "input",
                "input": "echo AVD_TERMINAL_MARKER; id -u; tty; exit\r\n",
            }).encode())

            seen = bytearray()
            deadline = time.monotonic() + 40
            while time.monotonic() < deadline:
                if not wait_readable(self.connection, 1.0):
                    continue
                try:
                    opcode, payload = read_ws_frame(self.rfile)
                except Exception as exc:
                    state.record("terminal", {"event": "read_error", "error": str(exc)})
                    break
                if opcode is None or opcode == 0x8:
                    break
                if opcode in (0x1, 0x2):
                    seen.extend(payload)
                    if b"AVD_TERMINAL_MARKER" in seen and b"/dev/pts/" in seen:
                        break

            text = seen.decode("utf-8", "replace")
            has_marker = "AVD_TERMINAL_MARKER" in text
            has_pty = "/dev/pts/" in text
            state.results.add(
                "terminal",
                has_marker and has_pty,
                f"pty_marker={'yes' if has_pty else 'no'} output_marker={'yes' if has_marker else 'no'}",
                {"output_tail": text[-600:]},
            )
            state.record("terminal", {
                "event": "output",
                "at": time.strftime("%Y-%m-%dT%H:%M:%S"),
                "output": text,
            })
            state.terminal_done.set()
            try:
                write_ws_frame(self.wfile, 0x8, b"")
            except Exception:
                pass

    return Handler


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--token", default="avd-token")
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=25774)
    ap.add_argument("--outdir", default=".narrafork/avd-probe/features")
    ap.add_argument("--seconds", type=float, default=180.0)
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)
    for name in ("basic_info", "v2_rpc", "report", "report_ws", "task_result",
                 "ping_result", "terminal", "ws_tasks_sent", "features"):
        p = os.path.join(args.outdir, f"{name}.jsonl")
        if os.path.exists(p):
            os.remove(p)

    state = State(args.token, args.outdir)
    server = ThreadingHTTPServer((args.bind, args.port), make_handler(state))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    sys.stderr.write(f"[features] listening on {args.bind}:{args.port} token={args.token}\n")
    sys.stderr.flush()

    deadline = time.monotonic() + args.seconds
    while time.monotonic() < deadline:
        time.sleep(0.5)

    server.shutdown()
    summary = state.results.summary()
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0 if summary["failed"] == 0 and summary["passed"] > 0 else 1


if __name__ == "__main__":
    sys.exit(main())
