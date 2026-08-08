# Strategy Optimization Audit

Date: 2026-07-23

## Decision

No strategy is enabled, promoted, or live-adopted from this audit or from an optimizer result.
The parameter sweep is a selection-only research screen. A selected setting must pass the separate
anchored nested-confirmation protocol and later forward evidence; the screen itself never changes
the live configuration.

## Quantified reference audit

The checked-in `backend/reference_oos.json` artifact records:

- 9 historical engine ids × 2 ES contracts = 18 hypotheses.
- Benjamini–Hochberg correction across all 18 cells at q = 0.10.
- Per-test alpha = 0.05 and minimum OOS trade count = 30.
- `candidateCount = 0`; all 9 historical engine rows have `status = no_edge`.
- The only raw per-test result below 0.05, `context_b` on `CM.ESU6`
  (`pEdge = 0.049508`), is correctly marked FDR-rejected and is not a candidate.

This quantifies the checked-in historical artifact only. It is not current release evidence:
the artifact pins prover SHA `e8895a5b9fca4a8d`, which does not match the audited `bltd_store.py`,
and the artifact does not yet contain the required `source_inputs` snapshot digests. It must be
regenerated from frozen inputs after the causal-fill corrections. Staleness cannot support a more
favorable decision: the only available audited artifact has zero candidates, current release
evidence is unavailable, and there is no adoption.

These are historical reference hypotheses, not nine distinct live implementations. The active
runtime/picker roster contains exactly seven canonical engines:

1. `meanrev`
2. `breakout`
3. `momentum`
4. `structure`
5. `regime`
6. `channel`
7. `context_b`

Two retired duplicate ids remain in the historical correction family and decode to their canonical
implementations:

- `research` → `breakout`
- `context_a` → `momentum`

Keeping those aliases in the 18-cell reference family preserves already-spent multiplicity while
removing duplicate live/picker entries.

## Research priorities

This order is for further nested research, not activation:

1. **Mean reversion.** Both reference contracts have positive expectancy and net points, but neither
   is significant (`pEdge = 0.720863` and `0.698945`). It is the first robustness and cost-sensitivity
   target, not a selected strategy.
2. **Regime.** It has the deepest samples among the next group (666 and 200 OOS trades), but the
   second contract is slightly negative and neither cell clears the gate. Prioritize cross-contract
   stability, not parameter maximization.
3. **Channel.** Both contract point/expectancy signs are positive, but the samples are only 9 and 5
   trades, below the 30-trade floor. Its next requirement is more untouched evidence, not tuning.

No other engine advances while these three fail nested confirmation, and this priority list grants
no live eligibility.

## Corrections present in source and regression coverage

### Causal fills

The research trade generators now separate signal observation from execution:

- A close-based signal can enter only at the next observable bar open.
- A final-bar signal with no next open is discarded.
- ES-family research fills are rounded adversely to the legal tick.
- Gaps fill at the observable open; when one OHLC bar touches both stop and target and order is
  unknowable, the simulation resolves stop-first.
- Breakout holding time is bounded from the entry bar so a later session gap cannot leak backward.

These changes remove close-to-close look-ahead and favorable bracket-fill assumptions. Prior results
that depended on the old fill path are not adoption evidence.

### Multiplicity and FDR

The reference generator now applies Benjamini–Hochberg to the complete 18-cell engine × contract
family at q = 0.10 and labels raw-significant/BH-rejected cells. The live gate consumes the corrected
grid verdict rather than bypassing it with a single-cell p-value.

The nested optimizer is more conservative still: its immutable prior-family floor is 350 tests
(the 18 reference cells plus 332 cells from the historical two-contract farm), and current inner and
outer tests are added rather than resetting multiplicity on restart. The old `candidate`/`proven`
wire keys are treated only as research-screen selections in the Swift UI.

### Restart and state continuity

The live evaluator now reads the newest bounded 5,000-bar window in chronological order instead of
freezing on the oldest 5,000 rows. Research/backtest reads use their separate larger bounded path.
Signal transition state and the originating closed-bar timestamp are durable, so restarting the
daemon over an unchanged endpoint cannot emit the same signal again. Fire insertion is bar-deduped,
and a state/fire write is atomic and fail-closed.

## Required confirmation before any release decision

Run one canonical engine per reserved hypothesis family using:

- two independent, timestamped contract snapshots with content hashes;
- the fixed predeclared parameter grid;
- three anchored untouched outer folds;
- at least an 80-bar purge/embargo;
- fixed round-trip cost bands of 0.25, 0.50, and 1.00 points;
- global BH-FDR plus the prior-family count;
- positive cost-adjusted expectancy, positive bootstrap lower bound, and sufficient trades in every
  contract, cost band, and outer fold;
- the same selected parameter index in every fold.

Even a unanimous nested-confirmation result remains research evidence. It is never live-adopted by
the optimizer, and it requires separate forward evidence and an explicit release decision.

## Verification status

- Headless Swift suite: 998 passed, 0 failed.
- Full `Sources/*.swift` macOS type-check, including SwiftUI: passed.
- Backend engine regressions covering causal fills, FDR-gated capture, newest-window reads, and
  restart deduplication: 103 passed.
- The combined optimizer/reference check currently has 117 passes and 4 failures. Two optimizer
  assertions still expect the retired `candidate` summary key after the source moved to
  `statisticalPass`; two reference checks reject the stale artifact SHA/missing input digests
  described above.

Those four failures are release blockers for refreshed evidence, not reasons to enable a strategy.
