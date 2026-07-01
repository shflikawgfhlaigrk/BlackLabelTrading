"""Black Label Trading — bundled TopstepX browser-to-webhook bridge (stdlib-only).

This is the no-setup sender side for Topstep buyers. The app already owns the local webhook
receiver; this bridge opens/attaches to the product Chrome profile, waits for the buyer to sign
into TopstepX, parses observed market-data WebSocket frames, and POSTs normalized ticks/bars into
the local webhook endpoint. It stores no Topstep credentials and never places orders.
"""
from __future__ import annotations

import json
import logging
import os
import time
import urllib.request
from urllib.parse import quote

import bltd_capture as C
import bltd_parsers as P

log = logging.getLogger("bltd.topstep.bridge")

TOPSTEP_URLS = ("https://www.topstepx.com/",)


def webhook_url() -> str:
    return os.environ.get("BLTD_WEBHOOK_URL") or \
        f"http://127.0.0.1:{os.environ.get('BLTD_PORT', '8787')}/webhook/feed"


def webhook_token() -> str:
    return os.environ.get("BLTD_TOKEN", "")


def topstep_pages():
    pages = C.cdp_pages() or []
    out = []
    for p in pages:
        url = (p.get("url") or "").lower()
        if (p.get("type") == "page" and p.get("webSocketDebuggerUrl")
                and "topstepx.com" in url):
            out.append(("topstepx", p))
    return out


def open_topstep_tabs() -> bool:
    """Open TopstepX in the product-owned debug Chrome profile. Never raises."""
    return C.open_feed_login_tabs()


class WebhookSink:
    """`Capture`-shaped sink for `bltd_capture.stream_tab`: on_candle -> POST /webhook/feed."""

    def __init__(self, endpoint=None, token=None, opener=urllib.request.urlopen):
        self.endpoint = endpoint or webhook_url()
        self.token = token if token is not None else webhook_token()
        self._opener = opener
        self.sent = 0
        self.failed = 0
        self.last_symbol = None

    def on_candle(self, cd: dict, arrival: float = None):
        if not cd:
            return
        body = {
            "source": "topstepx-bridge",
            "symbol": cd.get("symbol"),
            "price": cd.get("close"),
            "open": cd.get("open"),
            "high": cd.get("high"),
            "low": cd.get("low"),
            "close": cd.get("close"),
            "ts": cd.get("epoch") or int(arrival or time.time()),
        }
        data = json.dumps(body).encode("utf-8")
        req = urllib.request.Request(self.endpoint, data=data, method="POST",
                                     headers={"Content-Type": "application/json",
                                              "Authorization": f"Bearer {self.token}"})
        try:
            self._opener(req, timeout=3).read()
            self.sent += 1
            self.last_symbol = body["symbol"]
        except Exception as exc:  # noqa: BLE001
            self.failed += 1
            log.info("topstep bridge: webhook post failed: %s", exc)


def run_once(page, sink=None, idle_stall=45.0):
    return C.stream_tab("topstepx", page, sink or WebhookSink(), idle_stall=idle_stall)


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    if not webhook_token():
        log.error("topstep bridge: BLTD_TOKEN missing; cannot authenticate to local webhook")
        return 2
    log.info("topstep bridge: webhook -> %s", webhook_url())
    sink = WebhookSink()
    readers = {}
    while True:
        pages = topstep_pages()
        if not pages:
            log.info("topstep bridge: waiting for TopstepX sign-in/data page")
            time.sleep(5)
            continue
        for name, page in pages:
            url = page["webSocketDebuggerUrl"]
            cur = readers.get(url)
            if cur is None or not cur.is_alive():
                import threading
                t = threading.Thread(target=run_once, args=(page, sink), daemon=True)
                t.start()
                readers[url] = t
                log.info("topstep bridge: attached -> %s", (page.get("url") or "")[:80])
        for url in [u for u, t in readers.items() if not t.is_alive()]:
            readers.pop(url, None)
        time.sleep(3)


if __name__ == "__main__":
    raise SystemExit(main())
