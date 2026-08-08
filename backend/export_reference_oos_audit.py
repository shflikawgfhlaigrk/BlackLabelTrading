#!/usr/bin/env python3
"""Export the complete, reproducible trade log behind ``reference_oos.json``.

The reference artifact stores only aggregate cells.  This exporter reruns the exact pinned
engine code over the exact Postgres bar rows, attaches timestamps to every simulated trade,
and writes a compact evidence bundle for independent review.
"""
from __future__ import annotations

import csv
import gzip
import hashlib
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bltd_store as S  # noqa: E402


BACKEND = Path(__file__).resolve().parent
REFERENCE_PATH = BACKEND / "reference_oos.json"
DEFAULT_DSN = os.environ.get("BLTD_REF_DSN", "host=/tmp port=5433 dbname=utah")
DEFAULT_OUT = BACKEND.parent / "audit" / "reference_oos_2026-08-01"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def iso_utc(epoch: float) -> str:
    return datetime.fromtimestamp(epoch, tz=timezone.utc).isoformat(timespec="milliseconds").replace(
        "+00:00", "Z"
    )


def load_rows(connection, symbol: str) -> tuple[list[dict], str]:
    rows = list(
        connection.execute(
            "SELECT id,o::float8,h::float8,l::float8,c::float8,"
            "extract(epoch from ts)::float8 "
            "FROM bars WHERE symbol=%s ORDER BY ts ASC, id ASC",
            (symbol,),
        )
    )
    valid = [row for row in rows if None not in (row[1], row[2], row[3], row[4], row[5])]
    digest = hashlib.sha256()
    output = []
    for row_id, op, high, low, close, epoch in valid:
        digest.update(
            (
                f"{symbol}|{float(epoch):.6f}|{float(op):.17g}|{float(high):.17g}|"
                f"{float(low):.17g}|{float(close):.17g}\n"
            ).encode("utf-8")
        )
        output.append(
            {
                "source_row_id": int(row_id),
                "open": float(op),
                "high": float(high),
                "low": float(low),
                "close": float(close),
                "epoch": float(epoch),
            }
        )
    return output, digest.hexdigest()


def write_csv_gz(path: Path, fieldnames: list[str], rows: list[dict]) -> None:
    with gzip.open(path, "wt", encoding="utf-8", newline="", compresslevel=9) as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def stable_cell(cell: dict) -> dict:
    return {
        key: cell.get(key)
        for key in (
            "symbol",
            "bars",
            "from",
            "to",
            "proven",
            "trades",
            "winRate",
            "expectancyR",
            "netPts",
            "maxDrawdownR",
            "pEdge",
            "input_sha256",
            "verdict",
        )
    }


def main() -> int:
    import psycopg

    output_dir = Path(sys.argv[1]).expanduser().resolve() if len(sys.argv) > 1 else DEFAULT_OUT
    output_dir.mkdir(parents=True, exist_ok=True)
    reference = json.loads(REFERENCE_PATH.read_text(encoding="utf-8"))
    by_symbol = {item["symbol"]: item for item in reference["source_inputs"]}
    active_engines = [engine for engine in reference["engines"] if not engine.get("retired")]
    pinned_prover_sha = hashlib.sha256(Path(S.__file__).read_bytes()).hexdigest()

    connection = psycopg.connect(DEFAULT_DSN, autocommit=True, connect_timeout=5)
    all_trades: list[dict] = []
    all_bars: list[dict] = []
    reproduced_cells: list[dict] = []
    source_audit: list[dict] = []

    for symbol, expected in by_symbol.items():
        rows, input_sha = load_rows(connection, symbol)
        if input_sha != expected["input_sha256"]:
            raise RuntimeError(
                f"{symbol}: input hash changed: expected {expected['input_sha256']}, got {input_sha}"
            )
        if len(rows) != expected["bars"]:
            raise RuntimeError(
                f"{symbol}: bar count changed: expected {expected['bars']}, got {len(rows)}"
            )

        ohlc = [(r["open"], r["high"], r["low"], r["close"]) for r in rows]
        split = int(len(rows) * (1.0 - S.CONFIG_DEFAULTS.get("oosFrac", S.OOS_FRAC)))
        oos_rows = rows[split:]
        oos_ohlc = ohlc[split:]
        unique_utc_dates = sorted({iso_utc(r["epoch"])[:10] for r in rows})
        unique_oos_dates = sorted({iso_utc(r["epoch"])[:10] for r in oos_rows})
        source_audit.append(
            {
                "symbol": symbol,
                "bars": len(rows),
                "input_sha256": input_sha,
                "first_ts_utc": iso_utc(rows[0]["epoch"]),
                "last_ts_utc": iso_utc(rows[-1]["epoch"]),
                "unique_utc_dates": len(unique_utc_dates),
                "oos_split_index": split,
                "oos_bars": len(oos_rows),
                "oos_first_ts_utc": iso_utc(oos_rows[0]["epoch"]),
                "oos_last_ts_utc": iso_utc(oos_rows[-1]["epoch"]),
                "oos_unique_utc_dates": len(unique_oos_dates),
            }
        )

        for idx, row in enumerate(rows):
            all_bars.append(
                {
                    "symbol": symbol,
                    "source_row_id": row["source_row_id"],
                    "timestamp_utc": iso_utc(row["epoch"]),
                    "epoch_seconds": f"{row['epoch']:.6f}",
                    "open": format(row["open"], ".17g"),
                    "high": format(row["high"], ".17g"),
                    "low": format(row["low"], ".17g"),
                    "close": format(row["close"], ".17g"),
                    "source_index": idx,
                    "is_oos": idx >= split,
                    "oos_index": idx - split if idx >= split else "",
                    "input_sha256": input_sha,
                }
            )

        for engine_item in active_engines:
            engine = engine_item["engine"]
            expected_cell = next(cell for cell in engine_item["contracts"] if cell["symbol"] == symbol)
            trades = S.engine_trades(
                engine,
                oos_ohlc,
                S.CONFIG_DEFAULTS.get("lookback", S.LOOKBACK),
                S.CONFIG_DEFAULTS,
            )
            summary = S.PROVERS[engine](ohlc, S.CONFIG_DEFAULTS)
            reproduced = {
                "engine": engine,
                "symbol": symbol,
                "trades": len(trades),
                "wins": sum(1 for trade in trades if trade["r"] > 0),
                "winRate": summary["winRate"],
                "expectancyR": summary["expectancyR"],
                "netPts": summary["netPts"],
                "maxDrawdownR": summary["maxDrawdownR"],
                "pEdge": summary["pEdge"],
                "matches_reference": (
                    len(trades) == expected_cell["trades"]
                    and summary["winRate"] == expected_cell["winRate"]
                    and summary["expectancyR"] == expected_cell["expectancyR"]
                    and summary["netPts"] == expected_cell["netPts"]
                    and summary["maxDrawdownR"] == expected_cell["maxDrawdownR"]
                    and summary["pEdge"] == expected_cell["pEdge"]
                ),
                "reference_cell": stable_cell(expected_cell),
            }
            reproduced_cells.append(reproduced)
            if not reproduced["matches_reference"]:
                raise RuntimeError(f"aggregate mismatch for {engine}/{symbol}: {reproduced}")

            for trade_number, trade in enumerate(trades, start=1):
                signal_row = oos_rows[trade["signalIndex"]]
                entry_row = oos_rows[trade["entryIndex"]]
                exit_row = oos_rows[trade["exitIndex"]]
                pnl_points = (
                    trade["exit"] - trade["entry"]
                    if trade["dir"] == "long"
                    else trade["entry"] - trade["exit"]
                )
                all_trades.append(
                    {
                        "engine": engine,
                        "symbol": symbol,
                        "trade_number": trade_number,
                        "signal_ts_utc": iso_utc(signal_row["epoch"]),
                        "entry_ts_utc": iso_utc(entry_row["epoch"]),
                        "exit_ts_utc": iso_utc(exit_row["epoch"]),
                        "signal_source_row_id": signal_row["source_row_id"],
                        "entry_source_row_id": entry_row["source_row_id"],
                        "exit_source_row_id": exit_row["source_row_id"],
                        "signal_index_oos": trade["signalIndex"],
                        "entry_index_oos": trade["entryIndex"],
                        "exit_index_oos": trade["exitIndex"],
                        "direction": trade["dir"],
                        "entry_price": trade["entry"],
                        "stop_price": trade["stop"],
                        "target_price": trade["target"],
                        "exit_price": trade["exit"],
                        "held_bars": trade["held"],
                        "pnl_points": round(pnl_points, 8),
                        "r_multiple": trade["r"],
                        "outcome": "win" if trade["r"] > 0 else ("loss" if trade["r"] < 0 else "scratch"),
                        "source_bars": len(rows),
                        "oos_bars": len(oos_rows),
                        "input_sha256": input_sha,
                        "prover_sha256": pinned_prover_sha,
                    }
                )

    connection.close()
    all_trades.sort(key=lambda row: (row["symbol"], row["engine"], row["trade_number"]))
    all_bars.sort(key=lambda row: (row["symbol"], row["source_index"]))

    trade_fields = list(all_trades[0].keys())
    bar_fields = list(all_bars[0].keys())
    full_log_path = output_dir / "full_2,987_trade_log.csv.gz"
    bars_path = output_dir / "source_25,687_bars.csv.gz"
    headline_path = output_dir / "headline_meanrev_ESU6_312_trades.csv"
    write_csv_gz(full_log_path, trade_fields, all_trades)
    write_csv_gz(bars_path, bar_fields, all_bars)
    with headline_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=trade_fields)
        writer.writeheader()
        writer.writerows(
            row for row in all_trades if row["engine"] == "meanrev" and row["symbol"] == "CM.ESU6"
        )

    meanrev_esu6 = next(
        cell for cell in reproduced_cells if cell["engine"] == "meanrev" and cell["symbol"] == "CM.ESU6"
    )
    manifest = {
        "audit_status": "REPRODUCED_BUT_MISLABELED",
        "reference_artifact": str(REFERENCE_PATH),
        "reference_artifact_sha256": sha256_file(REFERENCE_PATH),
        "reference_generated_utc": reference["generated_utc"],
        "reference_claimed_label": "six-month out-of-sample results",
        "finding": (
            "All 2,987 aggregate trade results reproduce exactly from the pinned inputs and prover, "
            "but the available source bars span only 2026-06-10 through 2026-07-03 and the held-out "
            "OOS tails are shorter still. This evidence does not support calling the run six months."
        ),
        "headline": {
            "claim": "meanrev / CM.ESU6: 81.41% wins on 312 OOS trades",
            "reproduced_wins": meanrev_esu6["wins"],
            "reproduced_trades": meanrev_esu6["trades"],
            "reproduced_win_rate": meanrev_esu6["winRate"],
            "expectancy_r": meanrev_esu6["expectancyR"],
            "net_points_before_costs": meanrev_esu6["netPts"],
            "verdict": "no edge",
        },
        "interpretation_limits": [
            "The 2,987 count is the sum of independent engine-by-contract hypothesis cells, not a portfolio trade log.",
            "No commissions, exchange fees, or explicit bid/ask slippage charge is deducted.",
            "The simulator uses adverse tick rounding and stop-first handling for ambiguous same-bar touches.",
            "The reference artifact identifies the prover as uncommitted; the full content hash pins the exact code used.",
        ],
        "prover_file": str(Path(S.__file__).resolve()),
        "prover_sha256": pinned_prover_sha,
        "prover_sha_matches_reference": pinned_prover_sha.startswith(reference["prover_sha"]),
        "config": dict(S.CONFIG_DEFAULTS),
        "source_audit": source_audit,
        "reproduced_cells": reproduced_cells,
        "totals": {
            "source_bars": len(all_bars),
            "active_engine_contract_cells": len(reproduced_cells),
            "trades": len(all_trades),
            "all_cells_match_reference": all(cell["matches_reference"] for cell in reproduced_cells),
        },
        "files": {},
    }
    for path in (full_log_path, headline_path, bars_path):
        manifest["files"][path.name] = {
            "bytes": path.stat().st_size,
            "sha256": sha256_file(path),
        }
    manifest_path = output_dir / "audit_manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=False) + "\n", encoding="utf-8")
    print(json.dumps({"output_dir": str(output_dir), **manifest["totals"]}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
