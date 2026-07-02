"""Black Label Trading — regression tests for the pluggable feed layer (pure, no network).

Locks the honest-or-nothing contracts of the new feed adapters: symbol mapping, the
zero-fabrication candle normalizer, the ProjectX/Tradovate response shaping, the SignalR JSON
framing, and the FeedManager catalogue/routing. Tradovate stays offline-tested for a possible
retail/non-prop track but is unavailable in the prop-firm picker. Every test is offline — no broker
is contacted.

Run:  python3 test_feeds.py     (or via run-tests.sh; pytest-discoverable too)
"""
from __future__ import annotations

import bltd_feeds as F
import bltd_projectx as PX
import bltd_tradovate as TV
import bltd_rithmic as R
import bltd_store as S


# --- symbol mapping --------------------------------------------------------
def test_futures_root_strips_month_year():
    assert F.futures_root("ESU5") == "ES"
    assert F.futures_root("MESM25") == "MES"
    assert F.futures_root("EPZ25") == "EP"
    assert F.futures_root("ES") == "ES"
    assert F.futures_root("NQU5") == "NQ"


def test_map_es_symbol_accepts_es_family():
    for s in ("ESU5", "CON.F.US.EP.U25", "CON.F.US.MES.U25", "MESU25", "EPZ25", "ES", "/ES",
              "E-mini S&P 500: September 2025"):
        assert F.map_es_symbol(s) == "ES", s


def test_map_es_symbol_rejects_non_es():
    for s in ("NQU5", "CLZ5", "GCZ5", "CON.F.US.ENQ.U25", "CON.F.US.NQ.U25", "", None):
        assert F.map_es_symbol(s) is None, s


def test_map_market_symbol_accepts_prop_account_instruments():
    assert F.map_market_symbol("NQU5") == "NQU5"
    assert F.map_market_symbol("CLF26") == "CLF26"
    assert F.map_market_symbol("CON.F.US.ENQ.U25") == "NQ"
    assert F.map_market_symbol("CON.F.US.EP.U25") == "ES"
    assert F.map_market_symbol("") is None


# --- candle normalizer (never fabricates) ----------------------------------
def test_make_candle_accepts_real_price():
    cd = F.make_candle("ES", 5000.25, open=4999.0, high=5001.0, low=4998.0, epoch=1782537730)
    assert cd["close"] == 5000.25 and cd["high"] == 5001.0 and cd["epoch"] == 1782537730


def test_make_candle_rejects_junk():
    assert F.make_candle("ES", None) is None
    assert F.make_candle("ES", float("nan")) is None
    assert F.make_candle("ES", float("inf")) is None
    assert F.make_candle("ES", 0) is None            # implausible price band
    assert F.make_candle("", 5000.0) is None         # no symbol
    assert F.make_candle("ES", "not-a-number") is None


def test_make_candle_ms_epoch_normalized_to_seconds():
    cd = F.make_candle("ES", 5000.0, epoch=1782537730000)   # milliseconds
    assert cd["epoch"] == 1782537730


# --- ProjectX response shaping ---------------------------------------------
def test_projectx_token_extraction():
    assert PX.token_from_login({"token": "jwt", "success": True}) == "jwt"
    assert PX.token_from_login({"success": False, "token": "x"}) is None
    assert PX.token_from_login({}) is None
    assert PX.token_from_login(None) is None


def test_projectx_pick_es_contract_prefers_emini_and_active():
    parsed = {"contracts": [
        {"id": "m", "name": "MESU5"},
        {"id": "e1", "name": "ESU5"},
        {"id": "nq", "name": "NQU5"},
        {"id": "e2", "name": "ESZ5", "activeContract": True},
    ]}
    c = PX.pick_es_contract(parsed)
    assert c["id"] == "e2", c    # active e-mini wins over inactive e-mini and over the micro


def test_projectx_pick_contract_honors_requested_symbol():
    parsed = {"contracts": [
        {"id": "es", "name": "ESU5", "activeContract": True},
        {"id": "nq", "name": "NQU5", "activeContract": True},
        {"id": "cl", "name": "CLF26"},
    ]}
    assert PX.pick_contract(parsed, "NQ")["id"] == "nq"
    assert PX.pick_contract(parsed, "CL")["id"] == "cl"
    assert PX.pick_contract(parsed, "GC") is None


def test_projectx_quote_and_trade_candles():
    assert PX.quote_candle("ESU5", {"lastPrice": 5000.5,
                                    "timestamp": "2026-06-27T12:00:00Z"})["close"] == 5000.5
    assert PX.trade_candle("ESU5", {"price": 5001.0})["close"] == 5001.0
    nq = PX.quote_candle("NQU5", {"lastPrice": 17000.25})
    assert nq["symbol"] == "NQU5" and nq["close"] == 17000.25
    assert PX.quote_candle("ESU5", {"bestBid": 1, "bestAsk": 2}) is None  # no last -> no candle


# --- Tradovate response shaping --------------------------------------------
def test_tradovate_token_and_auth_errors():
    assert TV.tokens_from_auth({"accessToken": "a", "mdAccessToken": "m"}) == ("a", "m")
    assert TV.auth_error_text({"accessToken": "a"}) is None
    assert TV.auth_error_text({"errorText": "Incorrect username or password."}) == \
        "Incorrect username or password."
    assert TV.auth_error_text({"p-ticket": "x"}).startswith("Tradovate is rate")
    assert TV.auth_error_text(None) is not None


def test_tradovate_pick_es_contract_name():
    assert TV.pick_es_contract_name([{"name": "NQU5"}, {"name": "MESU5"}, {"name": "ESU5"}]) == "ESU5"
    assert TV.pick_es_contract_name([{"name": "NQU5"}]) is None


def test_tradovate_md_frame_candles_real_trade():
    frame = ('a[{"e":"md","d":{"quotes":[{"contractId":1,"entries":'
             '{"Trade":{"price":5000.25,"size":2},"HighPrice":{"price":5010.0},'
             '"LowPrice":{"price":4990.0},"OpeningPrice":{"price":5000.0}}}]}}]')
    cds = TV.md_frame_candles(frame, "ES")
    assert len(cds) == 1
    assert cds[0]["close"] == 5000.25 and cds[0]["high"] == 5010.0 and cds[0]["low"] == 4990.0


def test_tradovate_md_frame_drops_bid_ask_only_and_control_frames():
    assert TV.md_frame_candles('a[{"e":"md","d":{"quotes":[{"entries":{"Bid":{"price":1}}}]}}]', "ES") == []
    assert TV.md_frame_candles("o", "ES") == []      # SockJS open
    assert TV.md_frame_candles("h", "ES") == []      # heartbeat
    assert TV.md_frame_candles("", "ES") == []


# --- Rithmic R|Protocol codec (PURE, no network) ---------------------------
import bltd_rprotocol as RP


def test_rprotocol_varint_known_vectors():
    # canonical protobuf varint encodings
    assert RP.encode_varint(0) == b"\x00"
    assert RP.encode_varint(1) == b"\x01"
    assert RP.encode_varint(150) == b"\x96\x01"
    assert RP.encode_varint(300) == b"\xac\x02"
    for n in (0, 1, 127, 128, 300, 16384, 154467, 1235736):
        v, pos = RP.decode_varint(RP.encode_varint(n), 0)
        assert v == n and pos == len(RP.encode_varint(n)), n


def test_rprotocol_message_roundtrip():
    # encode a login-like message, decode it back, confirm strings + varint + the template id field
    msg = RP.encode_message(RP.T_REQUEST_LOGIN, [
        (RP.F_LOGIN_USER, "string", "trader1"),
        (RP.F_LOGIN_PASSWORD, "string", "secret"),
        (RP.F_LOGIN_INFRA_TYPE, "varint", RP.INFRA_TICKER_PLANT),
    ])
    dec = RP.decode_message(msg)
    assert RP.field_int(dec, RP.F_TEMPLATE_ID) == RP.T_REQUEST_LOGIN
    assert RP.field_str(dec, RP.F_LOGIN_USER) == "trader1"
    assert RP.field_str(dec, RP.F_LOGIN_PASSWORD) == "secret"
    assert RP.field_int(dec, RP.F_LOGIN_INFRA_TYPE) == 1


def test_rprotocol_double_roundtrip_and_lasttrade_frame():
    # a double (trade price) must survive the wire exactly; a framed LastTrade parses to 150 + price
    frame = RP.frame(RP.encode_message(RP.T_LAST_TRADE, [
        (RP.F_TRADE_PRICE, "double", 5000.25),
        (RP.F_TRADE_SIZE, "varint", 3),
        (RP.F_SSBOE, "varint", 1782539000),
    ]))
    tid, dec = RP.parse_frame(frame)
    assert tid == RP.T_LAST_TRADE
    assert RP.field_double(dec, RP.F_TRADE_PRICE) == 5000.25
    assert RP.field_int(dec, RP.F_TRADE_SIZE) == 3
    assert RP.field_int(dec, RP.F_SSBOE) == 1782539000


def test_rprotocol_login_result_codes():
    ok, detail = RP.rp_result(RP.decode_message(RP.encode_message(RP.T_RESPONSE_LOGIN, [
        (RP.F_RP_CODE, "string", "0"), (RP.F_RP_CODE, "string", "login successful")])))
    assert ok and "successful" in detail
    ok, detail = RP.rp_result(RP.decode_message(RP.encode_message(RP.T_RESPONSE_LOGIN, [
        (RP.F_RP_CODE, "string", "3"), (RP.F_RP_CODE, "string", "invalid user/password")])))
    assert not ok and "invalid user/password" in detail
    assert RP.rp_result({}) == (True, "")          # no rp_code -> treated OK


def test_rprotocol_es_front_month():
    import datetime
    # June 2026: the June contract has rolled, so the front month is September -> ESU6
    assert RP.es_front_month(datetime.date(2026, 6, 27)) == "ESU6"
    # January 2026: front month is March -> ESH6
    assert RP.es_front_month(datetime.date(2026, 1, 5)) == "ESH6"
    assert F.map_es_symbol(RP.es_front_month(datetime.date(2026, 6, 27))) == "ES"


# --- Rithmic adapter flow (stub binary WS, no network) ---------------------
class _StubBinWS:
    """A fake WSConn for the binary R|Protocol path: replays canned binary frames (raw bytes as
    recv_bytes would return them) and records sent bytes. raise_on_empty ends a stream loop."""
    def __init__(self, frames, raise_on_empty=True):
        self._frames = list(frames)
        self.sent = []
        self._raise = raise_on_empty

    def send_binary(self, data):
        self.sent.append(data)

    def recv_bytes(self, max_wait=1.0):
        if self._frames:
            return self._frames.pop(0)
        if self._raise:
            raise ConnectionError("stub: no more frames")
        return None

    def close(self):
        pass


def _login_ok_frame(hb=30.0):
    return RP.frame(RP.encode_message(RP.T_RESPONSE_LOGIN, [
        (RP.F_RP_CODE, "string", "0"), (RP.F_RP_CODE, "string", "OK"),
        (RP.F_HEARTBEAT_INTERVAL, "double", hb)]))


def _login_denied_frame():
    return RP.frame(RP.encode_message(RP.T_RESPONSE_LOGIN, [
        (RP.F_RP_CODE, "string", "1"), (RP.F_RP_CODE, "string", "Access denied")]))


def _last_trade_frame(price):
    return RP.frame(RP.encode_message(RP.T_LAST_TRADE, [
        (RP.F_TRADE_PRICE, "double", price), (RP.F_SSBOE, "varint", 1782539000)]))


def _full_rithmic_creds(**over):
    c = {"system": "Rithmic Test", "gateway": "wss://gw:443", "username": "u", "password": "p",
         "symbol": "ESU6", "exchange": "CME"}
    c.update(over)
    return c


def test_rithmic_requires_full_creds():
    rs = R.RithmicSource({"system": "s"}, lambda cd: None)
    assert rs.start()["state"] == "auth_error"      # missing gateway/user/password


def test_rithmic_accepts_non_es_contract():
    rs = R.RithmicSource(_full_rithmic_creds(symbol="NQU6"), lambda cd: None)
    rs._authenticate()
    assert rs.status()["symbol"] == "NQU6"


def test_rithmic_login_denied_surfaces_auth_error():
    """A denied R|Protocol login must surface the gateway's rp_code reason — not stall silently."""
    emitted = []
    rs = R.RithmicSource(_full_rithmic_creds(), emitted.append)
    rs._authenticate()                               # input validation only (no network)
    ws = _StubBinWS([_login_denied_frame()])
    raised = None
    try:
        rs._stream_once(_ws=ws)
    except Exception as e:  # noqa: BLE001
        raised = e
    assert isinstance(raised, F.AuthError), f"denied login must raise AuthError (got {type(raised).__name__})"
    assert "access denied" in str(raised).lower()
    # never subscribed (only the login was sent), emitted nothing
    sent_tids = [RP.parse_frame(b)[0] for b in ws.sent]
    assert RP.T_REQUEST_LOGIN in sent_tids
    assert RP.T_REQUEST_MARKET_DATA_UPDATE not in sent_tids
    assert emitted == []


def test_rithmic_login_success_subscribes_and_emits_real_trade():
    emitted = []
    rs = R.RithmicSource(_full_rithmic_creds(symbol="NQU6"), emitted.append)
    rs._authenticate()
    ws = _StubBinWS([_login_ok_frame(), _last_trade_frame(5001.50)])
    try:
        rs._stream_once(_ws=ws)
    except ConnectionError:
        pass                                         # stub end-of-frames
    sent_tids = [RP.parse_frame(b)[0] for b in ws.sent]
    assert RP.T_REQUEST_LOGIN in sent_tids and RP.T_REQUEST_MARKET_DATA_UPDATE in sent_tids
    assert len(emitted) == 1 and emitted[0]["close"] == 5001.50 and emitted[0]["symbol"] == "NQU6"


def test_rithmic_market_data_denied_surfaces_auth_error():
    """A denied market-data subscribe (e.g. no data entitlement) must surface, not stall."""
    emitted = []
    rs = R.RithmicSource(_full_rithmic_creds(), emitted.append)
    rs._authenticate()
    denied_md = RP.frame(RP.encode_message(RP.T_RESPONSE_MARKET_DATA_UPDATE, [
        (RP.F_RP_CODE, "string", "2"), (RP.F_RP_CODE, "string", "not entitled")]))
    ws = _StubBinWS([_login_ok_frame(), denied_md])
    raised = None
    try:
        rs._stream_once(_ws=ws)
    except Exception as e:  # noqa: BLE001
        raised = e
    assert isinstance(raised, F.AuthError) and "not entitled" in str(raised).lower()
    assert emitted == []


# --- SignalR JSON framing (stub socket, no network) ------------------------
class _StubWS:
    """A fake WSConn that replays canned text frames and records what was sent. When frames run
    out it returns None (default) or, if raise_on_empty, raises ConnectionError to end a stream loop."""
    def __init__(self, frames, raise_on_empty=False):
        self._frames = list(frames)
        self.sent = []
        self._raise = raise_on_empty

    def send_text(self, t):
        self.sent.append(t)

    def recv_text(self, max_wait=1.0):
        if self._frames:
            return self._frames.pop(0)
        if self._raise:
            raise ConnectionError("stub: no more frames")
        return None

    def close(self):
        pass


def test_signalr_handshake_and_record_split():
    RS = "\x1e"
    # handshake ack ({}), then two records in one frame: a server ping (type 6) and a GatewayQuote.
    quote = '{"type":1,"target":"GatewayQuote","arguments":["CON.F.US.EP.U25",{"lastPrice":5000.5}]}'
    ws = _StubWS(["{}" + RS, '{"type":6}' + RS + quote + RS])
    hub = F.SignalRJson(ws)
    hub.handshake()
    # handshake message sent first (json.dumps spacing-tolerant)
    assert ws.sent and ws.sent[0].replace(" ", "").startswith('{"protocol":"json"')
    recs = list(hub.records(max_wait=0.0))
    # the ping is consumed (auto-pong) and NOT yielded; only the real invocation is yielded
    assert len(recs) == 1 and recs[0]["target"] == "GatewayQuote"
    assert any(s.replace(" ", "") == '{"type":6}' + RS for s in ws.sent)   # auto-pong was sent


# --- Tradovate authorize-denial honesty (the QA-found bug) -----------------
def test_tradovate_authorize_response_reads_status():
    # a present-but-UNENTITLED md token returns a 401 'Access is denied' for the authorize id
    st, detail = TV.authorize_response('a[{"s":401,"i":1,"d":"\\"Access is denied\\""}]', 1)
    assert st == 401 and detail == "Access is denied"
    st, detail = TV.authorize_response('a[{"s":200,"i":1}]', 1)
    assert st == 200 and detail is None
    # frames with no response for request id 1 -> (None, None) (lenient fall-through)
    assert TV.authorize_response('a[{"e":"md","d":{}}]', 1) == (None, None)
    assert TV.authorize_response("o", 1) == (None, None)


def test_tradovate_denied_auth_surfaces_auth_error_not_connecting():
    """REGRESSION: a denied authorize ('a[{"s":401,"i":1,...}]') must drive the adapter to
    auth_error with the server detail — NOT a perpetual 'connecting / awaiting ticks'. Fails on the
    pre-fix code (which blindly treated the first 'a' frame as the ack and subscribed anyway)."""
    emitted = []
    src = TV.TradovateSource({"name": "u", "password": "p"}, emitted.append)
    src._symbol = "ESU5"
    src._md = "present-but-unentitled-token"
    # raise_on_empty=True: if the adapter (wrongly) fell through instead of raising AuthError, the
    # loop would exhaust frames and raise ConnectionError — so the pre-fix bug surfaces as a FAILED
    # assertion below, never an infinite hang.
    ws = _StubWS(["o", 'a[{"s":401,"i":1,"d":"\\"Access is denied\\""}]'], raise_on_empty=True)
    raised = None
    try:
        src._stream_once(_ws=ws)
    except Exception as e:  # noqa: BLE001
        raised = e
    assert isinstance(raised, F.AuthError), \
        f"denied authorize must raise AuthError, not proceed/loop (got {type(raised).__name__})"
    assert "access is denied" in str(raised).lower()            # server detail surfaced
    assert any(s.startswith("authorize") for s in ws.sent)      # it DID authorize
    assert not any("subscribeQuote" in s for s in ws.sent)      # but NEVER subscribed
    assert src._state != F.ST_CONNECTING                        # not the misleading "connecting"
    assert emitted == []                                        # zero fabrication preserved


def test_tradovate_denied_auth_drives_state_to_auth_error():
    """End-to-end through the guarded runner: ST_AUTH_ERROR with the detail (what the user sees)."""
    src = TV.TradovateSource({"name": "u", "password": "p"}, lambda cd: None)
    src._symbol = "ESU5"
    src._md = "tok"
    frames = ["o", 'a[{"s":401,"i":1,"d":"\\"Access is denied\\""}]']
    orig = src._stream_once
    src._stream_once = lambda: orig(_ws=_StubWS(frames, raise_on_empty=True))  # stub into _run
    src._run_guarded()                                          # _run -> AuthError -> ST_AUTH_ERROR
    st = src.status()
    assert st["state"] == "auth_error", st
    assert "access is denied" in st["detail"].lower()


def test_tradovate_authorize_success_still_subscribes_and_emits():
    """Guard against over-correction: a successful authorize (s==200) must still subscribe and a
    following quote must still emit a candle."""
    emitted = []
    src = TV.TradovateSource({"name": "u", "password": "p"}, emitted.append)
    src._symbol = "ESU5"
    src._md = "tok"
    quote = 'a[{"e":"md","d":{"quotes":[{"entries":{"Trade":{"price":5000.25}}}]}}]'
    ws = _StubWS(["o", 'a[{"s":200,"i":1}]', quote], raise_on_empty=True)
    try:
        src._stream_once(_ws=ws)
    except ConnectionError:
        pass                                                   # stub signals end-of-frames
    assert any("subscribeQuote" in s for s in ws.sent)
    assert len(emitted) == 1 and emitted[0]["close"] == 5000.25


def test_projectx_handle_emits_only_es_quotes():
    # Drive ProjectXSource._handle with a GatewayQuote record -> a candle is emitted via _emit.
    emitted = []
    src = PX.ProjectXSource({"username": "u", "apiKey": "k"}, emitted.append)
    src._contract_name = "ESU5"
    src._handle({"type": 1, "target": "GatewayQuote",
                 "arguments": ["CON.F.US.EP.U25", {"lastPrice": 5000.75}]})
    assert len(emitted) == 1 and emitted[0]["close"] == 5000.75
    # a non-invocation / non-quote record emits nothing
    src._handle({"type": 6})
    assert len(emitted) == 1


# --- FeedManager catalogue + routing ---------------------------------------
def _temp_store():
    """A real file-backed store. The Store opens a fresh sqlite connection per op, so an
    in-memory (':memory:') DB would be a different empty database each call — use a temp file."""
    import os
    import tempfile
    return S.Store(os.path.join(tempfile.mkdtemp(), "t.sqlite3"))


def test_feed_manager_catalogue_and_routing():
    mgr = F.FeedManager(_temp_store())
    srcs = mgr.sources()["sources"]
    keys = {s["key"] for s in srcs}
    # This release exposes TopstepX and WealthCharts browser capture alongside webhook ingestion.
    assert {"topstepx", "wealthcharts", "webhook"} <= keys
    webhook = next(s for s in srcs if s["key"] == "webhook")
    assert webhook["kind"] == "webhook"
    assert webhook["credFields"] == []
    assert "No prop-firm credentials" in webhook["note"]
    topstepx = next(s for s in srcs if s["key"] == "topstepx")
    assert topstepx["kind"] == "browser" and topstepx["credFields"] == []
    wealthcharts = next(s for s in srcs if s["key"] == "wealthcharts")
    assert wealthcharts["kind"] == "browser" and wealthcharts["credFields"] == []
    assert mgr.sources()["active"] is None
    assert mgr.connect("bogus", {})["state"] == "error"
    projectx = mgr.connect("projectx", {"apiKey": "must-not-be-used"})
    assert projectx["state"] == "error"
    assert "webhook ingestion only" in projectx["detail"]
    assert mgr.connect("webhook", {})["state"] == "webhook"
    # Browser sources route to the capture-browser state (pure — no Chrome is spawned from here).
    assert mgr.connect("browser", {})["state"] == "browser"
    assert mgr.connect("topstepx", {})["state"] == "browser"
    assert mgr.connect("wealthcharts", {})["state"] == "browser"


def test_feed_manager_ingest_wires_to_store():
    """A source's normalized candles land as REAL bars/ticks in the store (the unified path)."""
    import time
    store = _temp_store()
    mgr = F.FeedManager(store)
    base = int(time.time()) // 15 * 15
    for i in range(40):
        ep = base + i * 15 + 1
        mgr._cap.on_candle(F.make_candle("ES", 5000 + i * 0.25, open=5000 + i * 0.25, epoch=ep),
                           arrival=ep)
    mgr._cap.flush()
    assert "ES" in store.symbols().get("liveTicks", [])
    assert store.live_price("ES").get("price") is not None
    assert len(store.ohlc("ES")) > 0


def test_store_written_bars_are_evaluated_cross_process():
    """The REAL bridge between the API process and the evaluator process: bars one Capture writes
    to the shared store are seen by a SEPARATE Capture's evaluate_all() reading the SAME store path.
    This is the link the prop-API path depends on (FeedManager writes; the capture daemon's
    evaluator fires) — isolate it from engine internals by stubbing _signal so the test proves the
    cross-process WRITE->read->fire path, not a specific engine's math."""
    import time
    import bltd_capture as C
    store = _temp_store()
    # WRITER: stand in for the FeedManager/API side — push >lookback ES bars into the shared store.
    writer = C.Capture(store, edge_gate=False)
    base = int(time.time()) // 15 * 15 - 130 * 15
    for i in range(130):
        ep = base + i * 15 + 1
        writer.on_candle({"symbol": "ESU5", "open": 5000.0, "high": 5001.0, "low": 4999.0,
                          "close": 5000.0 + (i % 7) * 0.5, "epoch": ep}, arrival=ep)
    writer.flush()
    assert len(store.ohlc("ESU5")) >= 21          # enough closed bars for _evaluate
    # READER: a DIFFERENT Capture instance (the evaluator process) on the SAME store path.
    reader = C.Capture(store, edge_gate=False)
    reader._signal = lambda eng, ohlc: {"direction": "long", "stop": None,
                                        "target": None, "rationale": "bridge-test"}
    reader.evaluate_all()
    assert len(store.fires(10).get("fires", [])) >= 1   # evaluator saw the writer's bars and fired


if __name__ == "__main__":
    import sys
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    failed = 0
    for fn in fns:
        try:
            fn()
            print(f"  ok   {fn.__name__}")
        except AssertionError as e:
            failed += 1
            print(f"  FAIL {fn.__name__}: {e}")
        except Exception as e:  # noqa: BLE001
            failed += 1
            print(f"  ERR  {fn.__name__}: {type(e).__name__}: {e}")
    print(f"\n{len(fns) - failed} passed, {failed} failed")
    sys.exit(1 if failed else 0)
