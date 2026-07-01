"""TopstepX bridge tests: no real Chrome, no Topstep network."""
from __future__ import annotations

import json

import bltd_topstep_bridge as B


class _Resp:
    def read(self): return b'{"ok":true}'


def test_webhook_sink_posts_normalized_candle():
    seen = []

    def opener(req, timeout=0):
        seen.append((req.full_url, dict(req.header_items()), json.loads(req.data.decode()), timeout))
        return _Resp()

    sink = B.WebhookSink(endpoint="http://127.0.0.1:8787/webhook/feed", token="tok", opener=opener)
    sink.on_candle({"symbol": "ESU6", "open": 1, "high": 3, "low": 0.5, "close": 2, "epoch": 123})

    assert sink.sent == 1 and sink.failed == 0
    url, headers, body, timeout = seen[0]
    assert url.endswith("/webhook/feed")
    assert headers["Authorization"] == "Bearer tok"
    assert headers["Content-type"] == "application/json"
    assert body == {"source": "topstepx-bridge", "symbol": "ESU6", "price": 2,
                    "open": 1, "high": 3, "low": 0.5, "close": 2, "ts": 123}
    assert timeout == 3


def test_topstep_pages_filters_debug_targets():
    saved = B.C.cdp_pages
    try:
        B.C.cdp_pages = lambda: [
            {"type": "page", "url": "https://topstepx.com/trade", "webSocketDebuggerUrl": "ws://a"},
            {"type": "page", "url": "https://example.com", "webSocketDebuggerUrl": "ws://b"},
            {"type": "iframe", "url": "https://topstepx.com/trade", "webSocketDebuggerUrl": "ws://c"},
        ]
        pages = B.topstep_pages()
        assert len(pages) == 1
        assert pages[0][0] == "topstepx"
        assert pages[0][1]["webSocketDebuggerUrl"] == "ws://a"
    finally:
        B.C.cdp_pages = saved


def test_connect_reuses_existing_topstep_tab_without_opening_another():
    saved = (B.C.cdp_pages, B.C.urllib.request.urlopen, B.C._launch_chrome_multi,
             B.C._topstep_opened_recently)
    try:
        B.C.cdp_pages = lambda: [
            {"type": "page", "url": "https://www.topstepx.com/trade",
             "webSocketDebuggerUrl": "ws://a"},
        ]
        B.C.urllib.request.urlopen = lambda *a, **k: (_ for _ in ()).throw(AssertionError("opened duplicate tab"))
        B.C._launch_chrome_multi = lambda: (_ for _ in ()).throw(AssertionError("launched duplicate chrome"))
        B.C._topstep_opened_recently = lambda seconds=B.C.TOPSTEP_OPEN_DEBOUNCE_SECONDS: False

        assert B.C.open_feed_login_tabs() is True
    finally:
        (B.C.cdp_pages, B.C.urllib.request.urlopen, B.C._launch_chrome_multi,
         B.C._topstep_opened_recently) = saved


if __name__ == "__main__":
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
            print(f"ok {name}")
