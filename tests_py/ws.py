"""A minimal RFC 6455 WebSocket client (stdlib only) for poking enactd's protocol directly."""
from __future__ import annotations

import base64
import json
import os
import socket
import struct


class WS:
    def __init__(self, port: int, timeout: float = 10.0) -> None:
        self.s = socket.create_connection(("127.0.0.1", port), timeout=timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        self.s.sendall((f"GET / HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                        f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        resp = b""
        while b"\r\n\r\n" not in resp:
            resp += self.s.recv(1)
        assert resp.startswith(b"HTTP/1.1 101"), resp

    def send_text(self, text: str) -> None:
        data = text.encode()
        mask = os.urandom(4)
        n = len(data)
        head = bytes([0x81]) + (bytes([0x80 | n]) if n < 126 else bytes([0x80 | 126]) + struct.pack(">H", n))
        self.s.sendall(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def send_json(self, obj: dict) -> None:
        self.send_text(json.dumps(obj))

    def _read(self, n: int) -> bytes:
        buf = b""
        while len(buf) < n:
            part = self.s.recv(n - len(buf))
            if not part:
                raise ConnectionError("closed")
            buf += part
        return buf

    def recv(self) -> tuple[int, bytes]:
        b0, b1 = self._read(2)
        n = b1 & 0x7F
        if n == 126:
            n = struct.unpack(">H", self._read(2))[0]
        elif n == 127:
            n = struct.unpack(">Q", self._read(8))[0]
        return b0 & 0x0F, self._read(n)

    def recv_chunk(self) -> tuple[dict, bytes]:
        while True:
            op, data = self.recv()
            if op == 2:
                hlen = struct.unpack(">I", data[:4])[0]
                return json.loads(data[4:4 + hlen]), data[4 + hlen:]

    def close(self) -> None:
        self.s.close()
