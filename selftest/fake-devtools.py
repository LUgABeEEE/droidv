#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""selftest/fake-devtools.py —— 假 devtools HTTP + WebSocket 端点（供 dv selftest 用，无第三方依赖）

  GET /json/version  → {"Android-Package": $DV_FAKE_PKG, ...}
  GET /json/list     → 一个 page target
  WS  /devtools/page/<id> → 收 Runtime.evaluate，回 {"id":1,"result":{"result":{"type":"string","value":"fake-ok"}}}
"""
import base64
import hashlib
import json
import os
import socket
import socketserver
import struct
import sys
import threading

PKG = os.environ.get("DV_FAKE_PKG", "com.example.app")
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = self.rfile.read(1)
            if not chunk:
                return
            data += chunk
        head = data.decode("latin1")
        lines = head.split("\r\n")
        req = lines[0].split()
        path = req[1] if len(req) > 1 else "/"
        headers = {}
        for ln in lines[1:]:
            if ":" in ln:
                k, v = ln.split(":", 1)
                headers[k.strip().lower()] = v.strip()

        if headers.get("upgrade", "").lower() == "websocket":
            self._ws(headers)
            return

        if path.startswith("/json/version"):
            body = json.dumps({
                "Android-Package": PKG,
                "Browser": "Chrome/150.0.0-fake",
                "Protocol-Version": "1.3",
                "webSocketDebuggerUrl": f"ws://127.0.0.1:{self.server.server_address[1]}/devtools/browser",
            })
        elif path.startswith("/json/list"):
            port = self.server.server_address[1]
            body = json.dumps([{
                "id": "FAKEPAGE", "type": "page", "url": "https://fake.local/", "title": "fake",
                "webSocketDebuggerUrl": f"ws://127.0.0.1:{port}/devtools/page/FAKEPAGE",
            }])
        else:
            self.wfile.write(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
            return
        raw = body.encode()
        self.wfile.write(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
                         + str(len(raw)).encode() + b"\r\n\r\n" + raw)

    # --- 最小 WebSocket：握手 + 读一个帧 + 回一个帧 ---
    def _ws(self, headers):
        key = headers.get("sec-websocket-key", "")
        accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        self.wfile.write(("HTTP/1.1 101 Switching Protocols\r\n"
                          "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                          f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode())
        self.wfile.flush()
        payload = self._read_frame()
        if payload is None:
            return
        try:
            msg = json.loads(payload)
            mid = msg.get("id", 1)
        except Exception:
            mid = 1
        resp = json.dumps({"id": mid, "result": {"result": {"type": "string", "value": "fake-ok"}}})
        self._write_frame(resp.encode())

    def _read_frame(self):
        hdr = self.rfile.read(2)
        if len(hdr) < 2:
            return None
        b1, b2 = hdr[0], hdr[1]
        opcode = b1 & 0x0F
        masked = b2 & 0x80
        ln = b2 & 0x7F
        if ln == 126:
            ln = struct.unpack(">H", self.rfile.read(2))[0]
        elif ln == 127:
            ln = struct.unpack(">Q", self.rfile.read(8))[0]
        mask = self.rfile.read(4) if masked else b"\x00\x00\x00\x00"
        data = bytearray(self.rfile.read(ln))
        for i in range(len(data)):
            data[i] ^= mask[i % 4]
        if opcode == 0x8:   # close
            return None
        return bytes(data)

    def _write_frame(self, payload):
        header = bytearray([0x81])
        n = len(payload)
        if n < 126:
            header.append(n)
        elif n < 65536:
            header.append(126); header += struct.pack(">H", n)
        else:
            header.append(127); header += struct.pack(">Q", n)
        self.wfile.write(bytes(header) + payload)
        self.wfile.flush()


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 19333
    srv = Server(("127.0.0.1", port), Handler)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    print(f"fake-devtools listening on {port}", flush=True)
    try:
        while True:
            import time
            time.sleep(1)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
