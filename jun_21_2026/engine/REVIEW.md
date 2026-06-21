# Engine review guide — faithfulness of the local re-implementation

`engine/` is a **local, pure-R re-implementation** of the LOT algorithm, built so
the refactor can be run and checked on **synthetic** data without a warehouse. It
is **verification only** — production stays the Databricks SQL on `hive_metastore`
(`apr_30_2026/`, untouched). Every output is checked against a **hand-derived**
expected value (independent of the engine), so a passing test is a real check.

Run it (the driver runs the full pipeline MAP → LOT1 → SCT → LOT1 end):
```
Rscript engine/run_engine.R engine/fixtures /tmp/out   # MAP_STACKED + LOT1_BASE + LOT1_END
Rscript tests/run_unit_tests.R                          # 196 pass (engine: test_engine/sct/lot_end)
```

## What to validate: each rule maps to a production source line

| engine | rule | production source (apr_30_2026) |
|---|---|---|
| `map.R` | pharmacy/medical day-supply imputation (null/<1 → 28); de-dup (patient,med,date,type) keep max day-supply | `02_lot1.R:426-449` |
| `map.R` | MAP runout state machine (CASE1 open / CASE2 gap→new / CASE3 pushout·reset·medical) | `02_lot1.R:528-634` |
| `map.R` | new MAP iff `dt > max(rx_runout, med_runout)` | `02_lot1.R:550` |
| `map.R` | pharmacy pushout `rx_runout+ds`; reset `dt+ds-1`; medical never pushed out | `02_lot1.R:581-601` |
| `map.R` | `MAP_DISCON_FLG` = gap to next MAP / OBS_END `>= 90` | `02_lot1.R:654-662` |
| `lot1.R` | `LOT1_START` = min non-steroid MAP_START | `02_lot1.R:682-690` |
| `lot1.R` | induction window `[start, start+60-1]`, steroid excluded | `02_lot1.R:692-704` |
| `lot1.R` | base = induction ∪ permissible subs; discon = max base MAP_END ≤ OBS_END | `02_lot1.R:710-750` |
| `lot1.R` | first-add = earliest non-base non-steroid in coverage, date = MAP_START−1 | `02_lot1.R:781-813` |
| `sct.R` | AUTO 14-day window (max date) + 60-day gap merge | `02_lot1.R:985-1146` |
| `sct.R` | tandem = 2nd AUTO ≤180d of 1st, no ALLO between; excess ends LOT | `02_lot1.R:1264-1306` |
| `sct.R` | tandem-boundary date selection (window straddling the 180-day mark) | `02_lot1.R:1041-1128` |
| `sct.R` | ALLO/CART censor AUTO; end date = earliest SCT−1, reason 1/2/3 | `02_lot1.R:1313-1338` |
| `lot_end.R` | end cascade SCT > CART_INIT > MED_ADD > DEATH > DISCON > STUDY_END, gated on runout | `02_lot1.R:1570-1632` |
| `lot_end.R` | CART_INIT flag (CART within 45d of the add) + post-runout death guard | `02_lot1.R:1469-1549` |

## Verified coverage (hand-derived expected)

- **MAP** (`tests/unit/test_engine.R`, `engine/fixtures/expected/MAP_STACKED.csv` +
  `TRACE.md`): pushout, reset, gap→new MAP, medical no-pushout, same-day
  pharmacy-first tie, single claim, discon flag = 1 (gap) and = 0 (near OBS_END).
- **LOT1** (`test_engine.R`, `LOT1_BASE.csv`): steroid exclusion, induction-window
  cutoff, multi-drug regimen, first-add med+date, steroid-only → no LOT1.
- **SCT** (`test_sct.R`, inline): single / in-window / tandem / excess AUTO, 60-day
  merge, ALLO, CART, ALLO-censors-AUTO, end reason 1/2/3, **tandem-boundary date
  selection** (`02_lot1.R:1041-1128`; a window straddling the 180-day mark picks
  the boundary-closest date — verified to flip a non-tandem into a tandem).
- **LOT1 end** (`test_lot_end.R`, inline): every cascade branch + runout gating,
  **CART_INIT** (MED_ADD then CART within 45d ends at `FIRST_CART-1`, vs `SCT_CART`
  with no prior add), and the **post-runout death guard** (a LOT2 trigger after
  the runout makes DISCONTINUATION win over DEATH).
- **End-to-end** (`test_engine.R`): the driver's `LOT1_END` (MAP→LOT1→SCT→end) vs
  hand-derived expected, including an `SCT_ALLO` end for one patient.
- **Production parity** (`test_engine.R`/`test_sct.R`): pharmacy day-supply
  imputation, same-day max-day-supply de-dup, AUTO window = 13.

## NOT yet ported (next stage)

- **LOT2-5** (`LOT_LONG`): trigger the next line from the LOT1 end event, re-derive
  the regimen, repeat to MAX_LOT — `apr_30_2026/R/lot2_5_base.R`.

## Constraints to confirm

- `apr_30_2026/` is byte-for-byte untouched (`git status` clean).
- `engine/` is outside the prod allowlist; `engine/fixtures/` use reserved
  synthetic PATIDs (`9000000000`-`9999999999`) and are denied by
  `verify_no_synthetic.R`. Nothing synthetic or engine-side ships to production.
