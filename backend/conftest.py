"""Backend test shim: make closed-port CDP probes fail fast on Windows. No-op elsewhere.

Windows-port root cause (first Windows CI run 31295824699 — two socket.timeout
failures in test_api.py): Windows' TCP stack retransmits the SYN before giving up
on a CLOSED loopback port, so a connect() that macOS refuses instantly burns ~2s
on Windows (measured 2.04-2.10s on Win11, any port, both 127.0.0.1 and [::1]).
bltd_capture.cdp_pages() probes BOTH loopback hosts (4s timeout each) and
/api/capture runs it TWICE (cdp_reachable + discover_feed_pages), so with no
Chrome running one /api/capture request stalls ~8s server-side — past the 5s
per-request client timeout test_api._req uses.

Windows-only fix, no product code touched and nothing monkeypatched: bind an
accept-then-close-immediately listener on one ephemeral loopback port (both
stacks) and point BLTD_CDP_PORT — an env knob bltd_capture already reads at
import — at it BEFORE any test module imports bltd_capture (pytest loads
conftest first). The TCP handshake then completes instantly and the connection
dies before any HTTP response is sent, so cdp_pages() still HONESTLY returns
None ("CDP unreachable"); no CDP JSON is ever fabricated. It just fails at the
speed macOS does.

The durable product fix (a sub-second raw-socket preflight inside
bltd_capture.cdp_pages) needs a default-branch edit, so it is recorded in the
Windows-lane report instead of being made here.
"""
from __future__ import annotations

import sys

if sys.platform == "win32":                     # never alters mac/Linux behavior
    import os
    import socket
    import threading

    def _refuse_forever(srv):
        while True:
            try:
                conn, _ = srv.accept()
                conn.close()                    # immediate close => client read fails now
            except OSError:                     # listener torn down at interpreter exit
                return

    def _ipv6_loopback_usable():
        try:
            probe = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        except OSError:
            return False
        try:
            probe.bind(("::1", 0))
            return True
        except OSError:
            return False
        finally:
            probe.close()

    def _bind_refusers():
        """One ephemeral port held on BOTH loopback stacks (cdp_pages probes both).

        If ::1 cannot take the same port number, retry with a fresh v4 port; if
        IPv6 loopback is absent entirely, v4-only is enough (a v6-less stack
        already fails ::1 connects instantly)."""
        for _ in range(10):
            v4 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            v4.bind(("127.0.0.1", 0))
            port = v4.getsockname()[1]
            try:
                v6 = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
            except OSError:
                return port, [v4]               # AF_INET6 unsupported on this host
            try:
                v6.bind(("::1", port))
                return port, [v4, v6]
            except OSError:
                v6.close()
                if not _ipv6_loopback_usable():
                    return port, [v4]           # no ::1 at all => v4-only suffices
            v4.close()                          # ::1 port collision => fresh attempt
        v4 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        v4.bind(("127.0.0.1", 0))
        return v4.getsockname()[1], [v4]

    if not os.environ.get("BLTD_CDP_PORT"):     # an explicit override always wins
        _port, _socks = _bind_refusers()
        for _s in _socks:
            _s.listen(8)
            threading.Thread(target=_refuse_forever, args=(_s,), daemon=True).start()
        os.environ["BLTD_CDP_PORT"] = str(_port)
