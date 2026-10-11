"""Run fake PCO and ProPresenter servers locally to try the CLI without either.

    python tools/mock_servers.py            # PCO on :8765, ProPresenter on :50001
    # in another terminal:
    export PCO_BASE_URL=http://127.0.0.1:8765 PCO_APP_ID=x PCO_SECRET=y
    python -m pcosync --service-type 111 --plan 222 run --armed

Type a ProPresenter item name (or its number) into this terminal to "fire" it.
`live` shows where fake LIVE is; `grab` makes someone else take control.
"""

from __future__ import annotations

import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import httpx

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from tests.fakes import FakePCO, FakeProPresenter  # noqa: E402


def serve(fake_handle, port: int, host_url: str) -> ThreadingHTTPServer:
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def _do(self):
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length else b""
            req = httpx.Request(self.command, host_url + self.path, content=body)
            with lock:
                try:
                    resp = fake_handle(req)
                except httpx.TransportError:
                    self.send_response(503)
                    self.end_headers()
                    return
            self.send_response(resp.status_code)
            for k, v in resp.headers.items():
                if k.lower() not in ("content-length", "transfer-encoding"):
                    self.send_header(k, v)
            data = resp.content
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        do_GET = do_POST = _do

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def main() -> None:
    pco, pp = FakePCO(), FakeProPresenter()
    serve(pco.handle, 8765, "http://127.0.0.1:8765")
    serve(pp.handle, 50001, "http://127.0.0.1:50001")
    print("Fake PCO on http://127.0.0.1:8765 (service type 111, plan 222); fake ProPresenter on :50001")
    for n, e in enumerate(pp.playlist):
        print(f"  {n}: {e.name} ({e.type}{', pco' if e.is_pco else ''})")
    for line in sys.stdin:
        cmd = line.strip()
        if cmd == "live":
            cur = pco.current()
            print(f"LIVE: {cur[0] + ' ' + cur[1].title if cur else '(not started)'}; controller={pco.controller}")
        elif cmd == "grab":
            pco.controller = "555"
            print("Someone else took LIVE control")
        elif cmd.isdigit():
            pp.active_index = int(cmd)
            print(f"fired {pp.playlist[pp.active_index].name}")
        elif cmd:
            try:
                pp.fire(cmd)
                print(f"fired {cmd}")
            except StopIteration:
                print("no such item")


if __name__ == "__main__":
    main()
