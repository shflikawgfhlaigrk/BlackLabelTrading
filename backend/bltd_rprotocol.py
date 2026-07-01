"""Black Label Trading — minimal R|Protocol (Rithmic) protobuf codec (STDLIB-ONLY, hand-rolled).

The backend ships stdlib-only (no pip), so we hand-roll JUST the protobuf wire format (varint +
length-delimited + 64-bit) for the handful of R|Protocol messages a market-data feed needs — NO
protobuf dependency. The wire format is the public Google Protocol Buffers encoding; the field
numbers and template ids below are the REAL Rithmic R|Protocol values, taken from the published
.proto set (igorrivin/rithmic mirror of the Rithmic protobuf files: request_login.proto,
response_login.proto, request_market_data_update.proto, last_trade.proto, best_bid_offer.proto).

Flow (TICKER_PLANT):
  connect wss gateway -> RequestLogin(10) -> ResponseLogin(11) [rp_code "0" = ok]
  -> RequestMarketDataUpdate(100) SUBSCRIBE symbol/exchange, update_bits = LAST_TRADE|BBO
  -> LastTrade(150) / BestBidOffer(151) stream  + RequestHeartbeat(18) keepalive.

Transport framing: each message on the WebSocket is [4-byte big-endian length][protobuf bytes],
sent as ONE binary frame (matches the Rithmic WebSocket samples).

ZERO FABRICATION: the decoder only reports fields actually present in the bytes; a LastTrade with
no trade_price yields no candle. Every numeric constant here is a documented protocol value, not a
guess — and the codec is unit-tested against known protobuf vectors (test_feeds.py).
"""
from __future__ import annotations

import datetime
import struct

# --- wire types ------------------------------------------------------------
WT_VARINT = 0
WT_64BIT = 1
WT_LEN = 2
WT_32BIT = 5

# --- template ids (the value carried in the template_id field) -------------
T_REQUEST_LOGIN = 10
T_RESPONSE_LOGIN = 11
T_REQUEST_LOGOUT = 12
T_REQUEST_RITHMIC_SYSTEM_INFO = 16
T_RESPONSE_RITHMIC_SYSTEM_INFO = 17
T_REQUEST_HEARTBEAT = 18
T_RESPONSE_HEARTBEAT = 19
T_REQUEST_MARKET_DATA_UPDATE = 100
T_RESPONSE_MARKET_DATA_UPDATE = 101
T_LAST_TRADE = 150
T_BEST_BID_OFFER = 151

# --- field numbers (from the real .proto set) ------------------------------
F_TEMPLATE_ID = 154467         # int32, present on every message
F_USER_MSG = 132760            # repeated string
# RequestLogin
F_LOGIN_USER = 131003
F_LOGIN_PASSWORD = 130004
F_LOGIN_APP_NAME = 130002
F_LOGIN_APP_VERSION = 131803
F_LOGIN_SYSTEM_NAME = 153628
F_LOGIN_INFRA_TYPE = 153621
INFRA_TICKER_PLANT = 1         # SysInfraType.TICKER_PLANT
INFRA_ORDER_PLANT = 2
INFRA_HISTORY_PLANT = 3
# ResponseLogin
F_RP_CODE = 132766             # repeated string; rp_code[0] == "0" means success
F_HEARTBEAT_INTERVAL = 153633  # double
# RequestMarketDataUpdate
F_MD_SYMBOL = 110100
F_MD_EXCHANGE = 110101
F_MD_REQUEST = 100000          # enum: SUBSCRIBE=1, UNSUBSCRIBE=2
MD_SUBSCRIBE = 1
MD_UNSUBSCRIBE = 2
F_MD_UPDATE_BITS = 154211      # uint32 bitmask
BIT_LAST_TRADE = 1
BIT_BBO = 2
# LastTrade / BestBidOffer
F_TRADE_PRICE = 100006         # double
F_TRADE_SIZE = 100178          # int32
F_BID_PRICE = 100022           # double
F_ASK_PRICE = 100025           # double
F_SSBOE = 150100               # int32 — seconds since beginning of epoch
F_USECS = 150101               # int32 — microseconds


# ===========================================================================
# Protobuf primitive codec (PURE, unit-tested).
# ===========================================================================
def encode_varint(n: int) -> bytes:
    if n < 0:
        n += 1 << 64                       # 2's-complement for negative int (not used here, but correct)
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def decode_varint(buf: bytes, pos: int):
    shift = 0
    result = 0
    while True:
        b = buf[pos]
        pos += 1
        result |= (b & 0x7F) << shift
        if not (b & 0x80):
            return result, pos
        shift += 7


def _tag(field: int, wire: int) -> bytes:
    return encode_varint((field << 3) | wire)


def enc_varint(field: int, value: int) -> bytes:
    return _tag(field, WT_VARINT) + encode_varint(int(value))


def enc_string(field: int, value) -> bytes:
    b = value.encode("utf-8") if isinstance(value, str) else bytes(value)
    return _tag(field, WT_LEN) + encode_varint(len(b)) + b


def enc_double(field: int, value: float) -> bytes:
    return _tag(field, WT_64BIT) + struct.pack("<d", float(value))


def encode_message(template_id: int, fields) -> bytes:
    """Serialize one protobuf message. `fields` is a list of (field_num, kind, value) where kind is
    'varint' | 'string' | 'double'. The template_id is always emitted first (field 154467)."""
    out = bytearray(enc_varint(F_TEMPLATE_ID, template_id))
    for fnum, kind, val in fields:
        if kind == "varint":
            out += enc_varint(fnum, val)
        elif kind == "string":
            out += enc_string(fnum, val)
        elif kind == "double":
            out += enc_double(fnum, val)
        else:
            raise ValueError(f"unknown field kind {kind!r}")
    return bytes(out)


def decode_message(buf: bytes) -> dict:
    """Decode protobuf bytes -> {field_num: [values]}. varint->int, 64bit->float(double),
    len-delim->bytes, 32bit->int. Repeated fields accumulate. Stops cleanly on a truncated/unknown
    frame (never raises on junk) so a bad frame yields no fabricated values."""
    out: dict = {}
    pos = 0
    n = len(buf)
    try:
        while pos < n:
            tag, pos = decode_varint(buf, pos)
            fnum, wire = tag >> 3, tag & 7
            if wire == WT_VARINT:
                v, pos = decode_varint(buf, pos)
            elif wire == WT_64BIT:
                v = struct.unpack_from("<d", buf, pos)[0]
                pos += 8
            elif wire == WT_LEN:
                ln, pos = decode_varint(buf, pos)
                v = bytes(buf[pos:pos + ln])
                pos += ln
            elif wire == WT_32BIT:
                v = struct.unpack_from("<i", buf, pos)[0]
                pos += 4
            else:
                break                      # group/unknown wire type -> stop (can't safely skip)
            out.setdefault(fnum, []).append(v)
    except (IndexError, struct.error):
        pass                               # truncated frame -> return what parsed (never fabricate)
    return out


def field_int(dec: dict, fnum: int, default=None):
    vs = dec.get(fnum)
    return int(vs[0]) if vs else default


def field_double(dec: dict, fnum: int, default=None):
    vs = dec.get(fnum)
    return float(vs[0]) if vs else default


def field_str(dec: dict, fnum: int, default=None):
    vs = dec.get(fnum)
    if not vs:
        return default
    v = vs[0]
    return v.decode("utf-8", "replace") if isinstance(v, (bytes, bytearray)) else str(v)


def field_strs(dec: dict, fnum: int):
    return [v.decode("utf-8", "replace") if isinstance(v, (bytes, bytearray)) else str(v)
            for v in dec.get(fnum, [])]


# ===========================================================================
# WebSocket message framing: [4-byte big-endian length][protobuf bytes].
# ===========================================================================
def frame(payload: bytes) -> bytes:
    return struct.pack(">I", len(payload)) + payload


def unframe(buf: bytes) -> bytes:
    """Strip the 4-byte length prefix; return the protobuf body. Tolerant of a frame whose declared
    length disagrees with the actual bytes (returns what's present)."""
    if len(buf) < 4:
        return b""
    ln = struct.unpack_from(">I", buf, 0)[0]
    end = 4 + ln
    return bytes(buf[4:end]) if end <= len(buf) else bytes(buf[4:])


def parse_frame(buf: bytes):
    """One WS binary frame -> (template_id:int|None, decoded:dict)."""
    body = unframe(buf)
    if not body:
        return None, {}
    dec = decode_message(body)
    return field_int(dec, F_TEMPLATE_ID), dec


# ===========================================================================
# High-level R|Protocol message builders + result parsers.
# ===========================================================================
def build_login(user, password, system_name, app_name, app_version,
                infra_type=INFRA_TICKER_PLANT) -> bytes:
    return frame(encode_message(T_REQUEST_LOGIN, [
        (F_LOGIN_USER, "string", user),
        (F_LOGIN_PASSWORD, "string", password),
        (F_LOGIN_APP_NAME, "string", app_name),
        (F_LOGIN_APP_VERSION, "string", app_version),
        (F_LOGIN_SYSTEM_NAME, "string", system_name),
        (F_LOGIN_INFRA_TYPE, "varint", infra_type),
    ]))


def build_heartbeat() -> bytes:
    return frame(encode_message(T_REQUEST_HEARTBEAT, []))


def build_logout() -> bytes:
    return frame(encode_message(T_REQUEST_LOGOUT, []))


def build_market_data_subscribe(symbol, exchange,
                                bits=BIT_LAST_TRADE | BIT_BBO) -> bytes:
    return frame(encode_message(T_REQUEST_MARKET_DATA_UPDATE, [
        (F_MD_SYMBOL, "string", symbol),
        (F_MD_EXCHANGE, "string", exchange),
        (F_MD_REQUEST, "varint", MD_SUBSCRIBE),
        (F_MD_UPDATE_BITS, "varint", bits),
    ]))


def rp_result(dec: dict):
    """(ok:bool, detail:str) from an rp_code-bearing response (ResponseLogin / ResponseMarketData...).
    In R|Protocol rp_code is a repeated string where rp_code[0] is a numeric code ('0' == success)
    and the rest is human text. No rp_code present -> treated as OK (some gateways omit it on
    success)."""
    codes = field_strs(dec, F_RP_CODE)
    if not codes:
        return True, ""
    if codes[0] == "0":
        return True, " ".join(codes[1:]).strip()
    return False, " ".join(codes).strip()


# ===========================================================================
# ES front-month helper (a best-effort DEFAULT contract symbol the user can override).
# ===========================================================================
_Q_MONTHS = (3, 6, 9, 12)
_MONTH_CODE = {3: "H", 6: "M", 9: "U", 12: "Z"}


def _third_friday(year: int, month: int) -> datetime.date:
    d = datetime.date(year, month, 1)
    first_friday = 1 + ((4 - d.weekday()) % 7)     # weekday: Mon=0..Fri=4
    return datetime.date(year, month, first_friday + 14)


def es_front_month(today: datetime.date | None = None) -> str:
    """Best-effort ES front-month contract symbol (e.g. 'ESU6'). Picks the nearest CME quarterly
    (Mar/Jun/Sep/Dec, 3rd-Friday expiry) that hasn't rolled (>5 days out). It's a DEFAULT only — the
    exact active contract near roll is the buyer's to confirm, so the adapter exposes it as editable."""
    today = today or datetime.date.today()
    for year in (today.year, today.year + 1):
        for month in _Q_MONTHS:
            if _third_friday(year, month) - datetime.timedelta(days=5) > today:
                return f"ES{_MONTH_CODE[month]}{year % 10}"
    return f"ES{_MONTH_CODE[12]}{today.year % 10}"
