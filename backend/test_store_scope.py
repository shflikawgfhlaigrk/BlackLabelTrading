"""Regression: the RELEASE-DEFAULT instrument scope must accept CME micros (MES).

2026-07-01 audit: `BLTD_SCOPE=es` default + `^ES[month]\\d{1,2}$` regex silently dropped
MESU6 — the single most common TopStep instrument — so a buyer's feed captured nothing.
The ES *family* means ES + MES (micro E-mini S&P): both store, chart, and count as live.
"""
import importlib
import os
import sys


def _fresh_store():
    """Import bltd_store exactly as a buyer's process does: no BLTD_SCOPE in the env."""
    os.environ.pop("BLTD_SCOPE", None)
    sys.modules.pop("bltd_store", None)
    import bltd_store
    return importlib.reload(bltd_store)


def test_mes_contract_in_default_scope():
    st = _fresh_store()
    assert st.in_scope("MESU6"), "MESU6 (micro E-mini) must be in the release-default scope"


def test_mes_variants_in_default_scope():
    st = _fresh_store()
    for sym in ("MES", "MESZ5", "CM.MESU6", "MESM25"):
        assert st.in_scope(sym), f"{sym} must be in the release-default scope"


def test_es_family_still_in_scope():
    st = _fresh_store()
    for sym in ("ES", "ESU6", "CM.ESU6", "ESZ25"):
        assert st.in_scope(sym), f"{sym} regression: must stay in scope"


def test_non_family_symbols_stay_out_of_default_scope():
    st = _fresh_store()
    for sym in ("NQU6", "MNQU6", "AAPL", "EURUSD", "", None, "MESSY"):
        assert not st.in_scope(sym), f"{sym!r} must stay OUT of the release-default scope"


def test_futures_root_any_mes():
    st = _fresh_store()
    assert st.futures_root_any("MESU6") == "MES"
    assert st.futures_root_any("ESU6") == "ES"


if __name__ == "__main__":
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    passed = failed = 0
    for fn in fns:
        try:
            fn()
            passed += 1
        except AssertionError as e:
            failed += 1
            print(f"FAIL {fn.__name__}: {e}")
    print(f"{passed} passed, {failed} failed")
    sys.exit(1 if failed else 0)
