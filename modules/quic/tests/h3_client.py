#!/usr/bin/env python3
"""Interop client for the zquic example server (aioquic).

usage: h3_client.py HOST PORT [--requests N] [--path /] [--size BYTES]
Sends N concurrent GET requests over one connection and checks status
and body length. Exits non-zero on any mismatch.
"""
import argparse
import asyncio
import ssl
import sys

from aioquic.asyncio.client import connect
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration


class Client(QuicConnectionProtocol):
    def __init__(self, *a, **kw):
        super().__init__(*a, **kw)
        self.h3 = H3Connection(self._quic)
        self.waiters = {}
        self.results = {}

    def quic_event_received(self, event):
        for ev in self.h3.handle_event(event):
            if isinstance(ev, (HeadersReceived, DataReceived)):
                r = self.results.setdefault(ev.stream_id, {"status": None, "body": b""})
                if isinstance(ev, HeadersReceived):
                    r["status"] = dict(ev.headers).get(b":status")
                else:
                    r["body"] += ev.data
                if ev.stream_ended:
                    w = self.waiters.pop(ev.stream_id, None)
                    if w:
                        w.set_result(r)

    async def get(self, authority, path):
        sid = self._quic.get_next_available_stream_id()
        self.h3.send_headers(sid, [
            (b":method", b"GET"), (b":scheme", b"https"),
            (b":authority", authority.encode()), (b":path", path.encode()),
            (b"user-agent", b"zquic-interop"),
        ], end_stream=True)
        fut = asyncio.get_running_loop().create_future()
        self.waiters[sid] = fut
        self.transmit()
        return await asyncio.wait_for(fut, 10)


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("host")
    ap.add_argument("port", type=int)
    ap.add_argument("--requests", type=int, default=4)
    ap.add_argument("--path", default="/")
    ap.add_argument("--size", type=int, default=612)
    args = ap.parse_args()
    cfg = QuicConfiguration(is_client=True, alpn_protocols=H3_ALPN)
    cfg.verify_mode = ssl.CERT_NONE
    async with connect(args.host, args.port, configuration=cfg, create_protocol=Client) as c:
        res = await asyncio.gather(*(c.get(f"{args.host}:{args.port}", args.path) for _ in range(args.requests)))
        bad = [r for r in res if r["status"] != b"200" or len(r["body"]) != args.size]
        print(f"{len(res)} responses, {len(bad)} bad, status={res[0]['status']}, body={len(res[0]['body'])}")
        c.close()
        await c.wait_closed()
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
