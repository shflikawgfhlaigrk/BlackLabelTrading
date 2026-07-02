"""Regression: instrument scope must support WealthCharts-wide default plus legacy ES-only mode.

2026-07-01 audit: `BLTD_SCOPE=es` default + `^ES[month]\\d{1,2}$` regex silently dropped
MESU6. WealthCharts then widened the product default to every sane buyer-streamed symbol while
keeping `BLTD_SCOPE=es` available for the old Topstep-only lane.
"""
import importlib
import os
import sys


def _fresh_store(scope=None):
    """Import bltd_store exactly as a buyer's process does, optionally forcing BLTD_SCOPE."""
    if scope is None:
        os.environ.pop("BLTD_SCOPE", None)
    else:
        os.environ["BLTD_SCOPE"] = scope
    sys.modules.pop("bltd_store", None)
    import bltd_store
    return importlib.reload(bltd_store)


def test_wealthcharts_symbols_in_default_scope():
    st = _fresh_store()
    for sym in ("MESU6", "NQU6", "MNQU6", "AAPL", "EURUSD", "CM.ESU6", "US.SPY"):
        assert st.in_scope(sym), f"{sym} must be in the default WealthCharts scope"


def test_mes_variants_in_legacy_es_scope():
    st = _fresh_store("es")
    for sym in ("MES", "MESZ5", "CM.MESU6", "MESM25"):
        assert st.in_scope(sym), f"{sym} must be in the legacy ES-family scope"


def test_es_family_still_in_legacy_es_scope():
    st = _fresh_store("es")
    for sym in ("ES", "ESU6", "CM.ESU6", "ESZ25"):
        assert st.in_scope(sym), f"{sym} regression: must stay in scope"


def test_non_family_symbols_stay_out_of_legacy_es_scope():
    st = _fresh_store("es")
    for sym in ("NQU6", "MNQU6", "AAPL", "EURUSD", "", None, "MESSY"):
        assert not st.in_scope(sym), f"{sym!r} must stay OUT of legacy ES scope"


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
