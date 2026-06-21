# Engine review guide — faithfulness of the local re-implementation

`engine/` is a **local, pure-R re-implementation** of the LOT algorithm, built so
the refactor can be run and checked on **synthetic** data without a warehouse. It
is **verification only** — production stays the Databricks SQL on `hive_metastore`
(`apr_30_2026/`, untouched). Every output is checked against a **hand-derived**
expected value (independent of the engine), so a passing test is a real check.

**What this proves (and does not).** The expected values are **spec-expected**
(hand-derived from the documented rules), so this proves the engine agrees with the
**specification** for the tested cases. It does **not** yet prove equivalence to the
*actual legacy execution* — that requires running the same synthetic data through
the legacy `hive_metastore` pipeline to produce **regression-expected** output and
comparing. That run is the reviewer/owner's step (it needs the warehouse).

Run it (the driver runs the full pipeline MAP → LOT1 → SCT → LOT1 end):
```
Rscript engine/run_engine.R engine/fixtures /tmp/out   # MAP_STACKED + LOT1_BASE + LOT1_END + LOT_LONG
Rscript tests/run_unit_tests.R                          # 293 pass (engine: test_engine/sct/lot_end/lot_long); also CI
```

## What to validate: each rule maps to a production source line

| engine | rule | production source (apr_30_2026) |
|---|---|---|
| `map.R` | medical day-supply hardcoded to medical_day_supply; pharmacy null/<1→28; de-dup (patient,med,date,type) keep max day-supply | `02_lot1.R:299-449` |
| `map.R` | MAP runout state machine (CASE1 open / CASE2 gap→new / CASE3 pushout·reset·medical) | `02_lot1.R:528-634` |
| `map.R` | new MAP iff `dt > max(rx_runout, med_runout)` | `02_lot1.R:550` |
| `map.R` | pharmacy pushout `rx_runout+ds`; reset `dt+ds-1`; medical never pushed out | `02_lot1.R:581-601` |
| `map.R` | `MAP_DISCON_FLG` = gap to next MAP / OBS_END `>= 90` | `02_lot1.R:654-662` |
| `lot1.R` | `LOT1_START` = min non-steroid MAP_START | `02_lot1.R:682-690` |
| `lot1.R` | induction window `[start, start+60-1]`, steroid excluded | `02_lot1.R:692-704` |
| `lot1.R` | base = induction ∪ permissible subs; discon = max base MAP_END ≤ OBS_END | `02_lot1.R:710-750` |
| `lot1.R` | first-add = earliest non-base non-steroid in coverage, date = MAP_START−1 | `02_lot1.R:781-813` |
| `sct.R` | AUTO window (datediff<=13) max date + 60-day gap merge; ALLO/CART censor + line scoping | `02_lot1.R:985-1146` |
| `sct.R` | tandem = 2nd AUTO ≤180d of 1st, no ALLO between; excess ends LOT | `02_lot1.R:1264-1306` |
| `sct.R` | tandem-boundary date selection (window straddling the 180-day mark) | `02_lot1.R:1041-1128` |
| `sct.R` | ALLO/CART censor AUTO; end date = earliest SCT−1, reason 1/2/3 | `02_lot1.R:1313-1338` |
| `lot_end.R` | end cascade SCT > CART_INIT > MED_ADD > DEATH > DISCON > STUDY_END, gated on runout | `02_lot1.R:1570-1632` |
| `lot_end.R` | CART_INIT flag (CART within 45d of the add) + post-runout death guard | `02_lot1.R:1469-1549` |
| `lot_end.R` | post-runout AUTO trigger uses the line's APPLICABLE window (ALLO 1 / CART 45 / MED·AUTO 30), not a fixed 30 | `R/lot2_5_base.R:721-727` |
| `lot_long.R` | LOT2-5: trigger candidates (d_MED/d_ALLO/d_CART/d_AUTO) + start/type | `R/lot2_5_base.R:170-321` |
| `lot_long.R` | LOT applicable window: in-line AUTO iff `datediff(AUTO_DT_1,start)<win` (1/45/30); first AUTO outside = ENDING_AUTO; ALLO/CART scoped `>start` | `R/lot2_5_base.R:477-610` |
| `sct.R` | `auto_dt_2` reported only for a valid in-line tandem (LOT_N); same-day end-reason tie order line-specific (LOT1 AUTO>ALLO>CART; LOT_N ALLO>CART>AUTO) | `02_lot1.R:1268,1327-1338` / `R/lot2_5_base.R:558-563,776-791` |
| `lot_long.R` | per-line regimen + line-scoped SCT end + CE-sensitive end | `R/lot2_5_base.R:323-657` |
| `lot_long.R` | special starts: ALLO single-day / extend-to-next (`allo_lot_span`) + CART-no-med → `SCT_CART` | `R/lot2_5_base.R:410-422,658-870` |
| `lot_long.R` | final projection: in-LOT AUTO fields clamped to `<= LOT_BASE_END_DT`, SING/TAND/MAX recomputed | `R/lot2_5_base.R:104-145,923-960` |
| `lot_long.R` | `contains_mtx_reg`: induction has a valid maintenance subset (MONO drug / DUAL pair) + an anchor outside it | `02_lot1.R:1392-1429` / `R/lot2_5_base.R:624-654` |

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
  the runout makes DISCONTINUATION win over DEATH) — including the **CART-started
  applicable window**: an AUTO inside the CART 45-day window is NOT a next-line
  trigger so DEATH wins, where a fixed 30-day window would wrongly end at runout.
- **End-to-end** (`test_engine.R`): the driver's `LOT1_END` (MAP→LOT1→SCT→end) vs
  hand-derived expected, including an `SCT_ALLO` end for one patient; PLUS the **full
  23-column `LOT_LONG`** vs a hand-derived golden (`expected/LOT_LONG.csv`) — ALL 23
  columns compared exactly (verdict `match`; `contains_mtx_reg` now computed).
- **contains_mtx_reg** (`test_lot_long.R`): `.maint_maps` parsing + the mono/dual +
  anchor logic (mono+anchor→1, mono-only→0, dual-pair-only→0, dual+anchor→1, none→0)
  and the `build_lot_long` rollup wiring.
- **Production parity** (`test_engine.R`/`test_sct.R`): pharmacy day-supply
  imputation, same-day max-day-supply de-dup, AUTO window = 13.
- **LOT2-5** (`test_lot_long.R`): a 3-line cohort (LENA→DARA→CARF) run through the
  full chain MAP→LOT1→LOT_LONG — each line triggered from the prior line's end,
  MED_ADD→MED_ADD→DISCONTINUATION, loop stops at line 3; the start-type tie-break
  (SCT_ALLO > MED on a same-day candidate); the **LOT applicable window** (the same
  AUTO ends a MED LOT2 when *outside* the 30-day window but is an in-line transplant
  when *inside* it); the **final projection clamp** (an in-window AUTO *after* the
  line ended by an early runout is dropped from FLG/DT_1/SING); **CART-no-
  consolidation → `SCT_CART`** single-day; and both **`allo_lot_span`** modes
  (single-day; extend-to-next ending at the later CART *and* via a later MM agent's
  MED_ADD).
- **SCT window unit** (`test_sct.R`): `build_sct_summary` with `lot_window_days`
  flips an AUTO between in-line transplant and ENDING_AUTO; `allo_cart_strict`
  (`>start`) makes a start-date ALLO the line's start under LOT_N but its end under
  LOT1 (`>=`, faithful to `02_lot1.R:1209-1247` vs `lot2_5_base.R:498-535`); a
  non-tandem 2nd AUTO is NOT reported as `auto_dt_2` for LOT_N (it is for LOT1);
  the same-day AUTO tie is censored away (so LOT1/LOT_N orderings agree on all
  reachable inputs — the LOT_N order is mirrored for faithfulness).
- **Comparator** (`test_gate_and_compare.R`): the cross-convention id bridge
  (`sql_normalize_view`) aliases a legacy `PATID` side to canonical `patient_id`
  so a `PATID`-vs-`patient_id` warehouse compare no longer fails on the id name.

## NOT yet ported (the decisive owner-side / warehouse gates)

- The **regression-expected** baseline (legacy execution on the same synthetic data,
  the owner's hive_metastore step) — the decisive parity gate — plus the live
  comparator smoke run and golden-fixture approval/pinning.
- The full **canonical input ROW** validator (`validate_canonical`) in `run_engine`:
  it now derives defaults from + validates the resolved config against `CONFIG_SPEC`
  and checks filenames/members/codelist columns, but not yet lineage / dates / dedup
  uniqueness of the input rows (that needs the canonical adapter, since the engine
  consumes POST-cohort inputs). `apr_30_2026` production also does not yet consume
  `CONFIG_SPEC` (still env vars).
- **Now handled (LOT_LONG is fully derived):** `contains_mtx_reg` COMPUTED (mono/dual
  + anchor from rollup metadata) → `UNIMPLEMENTED_FIELDS` empty, golden is a full
  `match`; ALL tunables propagate into LOT1 end logic; defaults derived from + resolved
  config validated against the one `CONFIG_SPEC`; caller-scoped gap mechanism retained;
  single-join value compare with double counts + `bigint="numeric"` (BIGINT-safe) +
  case-insensitive key exclusion; checksum AND sample failures isolated + SURFACED;
  null-vs-dup key counts (`KEYS{...}`); patient-level sample OFF by default, governed
  via validated `--sample-into` (deterministic `ORDER BY`) or explicit `--sample-inprocess`,
  never logged; `PATID` name+STRING bridge; membership short-circuit; CART death-guard.
  Checksum aggregation **bucketing** remains a deferred warehouse-scale optimization.

## Constraints to confirm

- `apr_30_2026/` is byte-for-byte untouched (`git status` clean).
- `engine/` is outside the prod allowlist; `engine/fixtures/` use reserved
  synthetic PATIDs (`9000000000`-`9999999999`) and are denied by
  `verify_no_synthetic.R`. Nothing synthetic or engine-side ships to production.
