# Reference OOS audit — 2026-08-01

## Conclusion

The published aggregates are reproducible, but this is **not a six-month test**.

The exact pinned prover regenerated all 2,987 reported engine-by-contract trade records and all
14 active summary cells without a mismatch. The underlying bar snapshots cover June 10–16 and
June 19–July 3, 2026. The held-out portions used for the reported OOS trades are shorter:

| Contract | Source bars | Full source range (UTC) | OOS bars | Actual OOS range (UTC) |
|---|---:|---|---:|---|
| CM.ESU6 | 18,906 | 2026-06-19 01:13:30 → 2026-07-03 05:37:15 | 7,563 | 2026-06-25 23:40:15 → 2026-07-03 05:37:15 |
| CM.ESM6 | 6,781 | 2026-06-10 10:14:45 → 2026-06-16 07:26:45 | 2,713 | 2026-06-15 18:04:00 → 2026-06-16 07:26:45 |

The investor copy saying “six months” is unsupported by this evidence and should not be used as
written. A genuine six-month result requires six months of immutable input bars and a new run.

## The 81.4% headline

The exact mean-reversion result on CM.ESU6 reproduced:

- 312 OOS trades from June 25 through July 3, 2026.
- 254 wins and 58 losses: 81.4103% raw win rate, shown as 81.4%.
- +292.25 gross winning points versus −334.00 gross losing points.
- −41.75 net points before commissions, exchange fees, and an explicit bid/ask-slippage charge.
- −0.0291 mean R per trade; 22.1341R maximum drawdown; one-sided edge p-value 1.0.
- Average win +1.1506 points; average loss −5.7586 points. The average loss was about five times
  the average win, which is why the high hit rate lost points.

The result supports “81.4% of these simulated outcomes were positive.” It does not support a
profitable-edge claim, and the shipped gate correctly returned `no edge`.

## Full reproduced grid

| Engine | Contract | Trades | Wins | Win rate | Expectancy R | Net points | Max DD R | pEdge |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| meanrev | CM.ESU6 | 312 | 254 | 81.41% | −0.0291 | −41.75 | 22.1341 | 1.000000 |
| meanrev | CM.ESM6 | 96 | 80 | 83.33% | +0.0539 | +38.50 | 2.8437 | 0.286522 |
| breakout | CM.ESU6 | 150 | 57 | 38.00% | +0.1904 | +52.00 | 27.5499 | 1.000000 |
| breakout | CM.ESM6 | 52 | 16 | 30.77% | −0.3767 | −54.00 | 23.1062 | 1.000000 |
| momentum | CM.ESU6 | 549 | 152 | 27.69% | +0.0612 | +11.50 | 37.2172 | 1.000000 |
| momentum | CM.ESM6 | 174 | 41 | 23.56% | −0.2265 | −32.00 | 47.0840 | 1.000000 |
| structure | CM.ESU6 | 275 | 74 | 26.91% | +0.1324 | +19.25 | 26.0834 | 1.000000 |
| structure | CM.ESM6 | 96 | 23 | 23.96% | −0.2127 | −17.00 | 24.7503 | 1.000000 |
| regime | CM.ESU6 | 770 | 224 | 29.09% | +0.0899 | +43.75 | 72.4851 | 1.000000 |
| regime | CM.ESM6 | 230 | 63 | 27.39% | −0.0970 | −18.25 | 53.3009 | 1.000000 |
| channel | CM.ESU6 | 10 | 4 | 40.00% | +0.4667 | +2.25 | 3.0000 | 1.000000 |
| channel | CM.ESM6 | 5 | 2 | 40.00% | +0.3333 | +1.25 | 3.0000 | 1.000000 |
| context_b | CM.ESU6 | 205 | 71 | 34.63% | +0.1950 | +22.50 | 13.5000 | 0.344276 |
| context_b | CM.ESM6 | 63 | 8 | 12.70% | −0.5820 | −29.75 | 37.0000 | 1.000000 |

Every cell matched `backend/reference_oos.json`. None cleared the system's corrected edge gate.

## What the large counts mean

- **2,987 trades** is a sum across 14 independent engine-by-contract test cells. It is useful as
  a test-observation count, but it is not one executable portfolio and should not be presented as
  such. Different engines can generate overlapping hypothetical positions on the same bars.
- **179,809 bars** in `client-docs/tec-full.html` is 25,687 unique source bars multiplied by seven
  active engines. The underlying dataset contains 25,687 unique bar rows, not 179,809 bars.
- The simulator applies adverse tick rounding and assumes stop-first when one OHLC bar touches
  both stop and target. It does not deduct commissions, exchange fees, or a separate spread/
  slippage charge.

## Chain of custody

- Summary artifact SHA-256: `baf3dde545384a6a699ab68260a09d3ad5380d578fa0bbb3043d47c650c230db`
- Prover SHA-256: `9c09f0a96c9e0e5e41e227ec57be14f0563d76ff65342bd4942b5423c4df1178`
- CM.ESU6 input SHA-256: `58bc710e2327655c105b13f43632b9a7d25125a22b8caf987526d43ab695e341`
- CM.ESM6 input SHA-256: `9db39b64fe0be1d546d2ffaba44962720d9a97ba17e2186cfe051ec23372eac9`

The summary artifact marks the prover working tree as uncommitted, so the prover's full content
hash—not Git commit `b9ec1b7` alone—is the durable code identity for this replay.

## Bundle contents

- `headline_meanrev_ESU6_312_trades.csv` — the human-readable per-trade log behind 81.4%.
- `full_2,987_trade_log.csv.gz` — every simulated trade in all 14 active test cells.
- `source_25,687_bars.csv.gz` — every exact input bar, source row ID, timestamp, OOS marker, and
  input hash.
- `audit_manifest.json` — source coverage, configuration, cell-by-cell reconciliation, hashes,
  and interpretation limits.
- `export_reference_oos_audit.py` in `backend/` — deterministic exporter/replay tool.

The CSV logs include signal, entry, and exit timestamps; source database row IDs; OOS indices;
direction; entry, stop, target, and exit prices; holding bars; points; R multiple; outcome; input
hash; and prover hash.
