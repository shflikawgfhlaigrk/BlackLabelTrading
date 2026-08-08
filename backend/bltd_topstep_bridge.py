"""Black Label Trading — bundled browser-to-webhook bridge (stdlib-only).

This is the no-setup sender side for browser chart feeds. The app already owns the local webhook
receiver; this bridge opens/attaches to the product Chrome profile, waits for the buyer to sign
into TopstepX or WealthCharts, parses observed market-data WebSocket frames, and POSTs normalized
ticks/bars into the local webhook endpoint. It stores no platform credentials and never places
orders.
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

log = logging.getLogger("bltd.browser.bridge")

TOPSTEP_URLS = ("https://www.topstepx.com/",)


def webhook_url() -> str:
    return os.environ.get("BLTD_WEBHOOK_URL") or \
        f"http://127.0.0.1:{os.environ.get('BLTD_PORT', '8793')}/webhook/feed"


def webhook_token() -> str:
    token_file = os.environ.get("BLTD_TOKEN_FILE")
    if token_file:
        try:
            with open(token_file, encoding="utf-8") as handle:
                token = handle.read(4097).strip()
            if token and len(token) <= 4096:
                return token
        except OSError:
            pass
    return os.environ.get("BLTD_TOKEN", "")


def topstep_pages():
    return [(name, page) for name, page in C.discover_feed_pages("topstepx")]


def browser_pages():
    return C.discover_feed_pages()


def open_topstep_tabs() -> bool:
    """Open TopstepX in the product-owned debug Chrome profile. Never raises."""
    return C.open_feed_login_tabs("topstepx")


def open_platform_tabs(source="topstepx") -> bool:
    """Open a supported browser platform in the product-owned debug Chrome profile. Never raises."""
    return C.open_feed_login_tabs(source)


class WebhookSink:
    """`Capture`-shaped sink for `bltd_capture.stream_tab`: on_candle -> POST /webhook/feed."""

    def __init__(self, endpoint=None, token=None, opener=urllib.request.urlopen, source="topstepx"):
        self.endpoint = endpoint or webhook_url()
        self.token = token if token is not None else webhook_token()
        self._opener = opener
        self.source = source
        self.sent = 0
        self.failed = 0
        self.last_symbol = None

    def on_candle(self, cd: dict, arrival: float = None):
        if not cd:
            return
        body = {
            "source": f"{self.source}-bridge",
            "symbol": cd.get("symbol"),
            "price": cd.get("close"),
            "open": cd.get("open"),
            "high": cd.get("high"),
            "low": cd.get("low"),
            "close": cd.get("close"),
            "ts": cd.get("epoch") or int(arrival or time.time()),
        }
        if cd.get("volume") is not None:
            body["volume"] = cd.get("volume")
        if cd.get("delta") is not None:
            body["delta"] = cd.get("delta")
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
    source = C._source_for_url(page.get("url") or "") or "browser"
    return C.stream_tab(source, page, sink or WebhookSink(source=source), idle_stall=idle_stall)


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    if not webhook_token():
        log.error("topstep bridge: local webhook token missing; cannot authenticate")
        return 2
    log.info("browser bridge: webhook -> %s", webhook_url())
    readers = {}
    while True:
        pages = browser_pages()
        if not pages:
            log.info("browser bridge: waiting for TopstepX/WealthCharts sign-in/data page")
            time.sleep(5)
            continue
        for name, page in pages:
            url = page["webSocketDebuggerUrl"]
            cur = readers.get(url)
            if cur is None or not cur.is_alive():
                import threading
                t = threading.Thread(target=run_once, args=(page,), daemon=True)
                t.start()
                readers[url] = t
                log.info("browser bridge[%s]: attached -> %s", name, (page.get("url") or "")[:80])
        for url in [u for u, t in readers.items() if not t.is_alive()]:
            readers.pop(url, None)
        time.sleep(3)


if __name__ == "__main__":
    raise SystemExit(main())
