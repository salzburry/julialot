# Canonical output contracts (DRAFT)

Output schemas the core produces. Columns are drawn from the current pipeline and
**must be parity-checked against the live tables** during Increment 0A (baseline
inventory). These are the tables the golden comparison (`compare_run_outputs.R`)
checks patient-by-patient.

Status: **draft.** Treat the column lists as a starting inventory, not final.

## Nondeterminism policy (applies to all outputs)

Only **display-only** fields may be nondeterministic and excluded from the strict
compare. Any field that influences downstream MAP/LOT state must be
deterministic. Currently known nondeterministic points (to be removed or pinned):

- the **seeded random tie-break** for `LOT1_BASE_1ST_ADD_MED_DT` (fixed `seed=42`
  today — record the seed + Spark/runtime versions; plan a deterministic fix);
- any **same-date token display** (`min_by`/`max_by` over date alone) in
  reporting — display-only, compared as an unordered set, not a blocker.

Excluded fields are listed per table in `tests/fixtures/expected/nondeterministic.md`.

## MAP_STACKED — one row per (patient, drug, medication-available period)

| column | key | notes |
|---|---|---|
| patient_id | ✓ | |
| med_abbr / med_class | ✓ | drug identity (per the MMA rollup) |
| map_cnt | ✓ | MAP sequence within (patient, drug) |
| map_start_dt | | |
| map_rx_runout_dt | | pharmacy runout (with pushout / reset-without-pushout) |
| map_med_runout_dt | | medical runout (never pushed out) |
| map_end_dt | | max(rx_runout, med_runout) |
| map_discon_flg | | gap to next MAP / OBS_END ≥ `map_discon_gap_days` (90) |

- **Key:** (patient_id, med_abbr, map_cnt).
- **Determinism:** fully deterministic given canonical inputs + params.

## LOT1_BASE — one row per patient (LOT1 induction)

| column | key | notes |
|---|---|---|
| patient_id | ✓ | |
| lot1_start_dt | | min(map_start_dt) across non-STEROID classes |
| lot1_base_meds | | induction meds ∪ permissible substitutes (steroids excluded) |
| lot1_med_cnt | | |
| lot1_base_discon_dt | | capped at OBS_END_DT |
| lot1_base_1st_add_med_dt | | **nondeterministic tie-break (seed 42)** — see policy |
| per-drug / per-class flags | | |

- **Key:** patient_id.

## LOT_LONG — one row per (patient, LOT_NUM ∈ 1..MAX_LOT)

| column | key | notes |
|---|---|---|
| patient_id | ✓ | |
| lot_num | ✓ | 1..MAX_LOT (default 5) |
| lot_start_dt | | |
| lot_base_meds | | |
| lot_med_cnt | | |
| lot_base_discon_dt | | |
| lot_base_1st_add_med_dt | | inherits LOT1 nondeterminism for LOT1 |
| lot_base_end_dt | | |
| lot_base_end_reason | | SCT/CART/ALLO/progression/etc. |
| contains_mtx_reg | | |
| lot_start_type / lot_end_type | | SCT family tags where applicable |

- **Key:** (patient_id, lot_num).
- **Determinism:** deterministic except the inherited LOT1 tie-break field.

## Comparison keys (for `compare_run_outputs.R`)

| table | join key |
|---|---|
| MAP_STACKED | (patient_id, med_abbr, map_cnt) |
| LOT1_BASE | (patient_id) |
| LOT_LONG | (patient_id, lot_num) |

## Output contract — required columns (versioned)

The comparator enforces a **versioned output contract** (`OUTPUT_CONTRACT`,
`OUTPUT_CONTRACT_VERSION` in `compare_run_outputs.R`): every required column below
must be present on **both** sides of a comparison. This is a fail-closed check —
two *equally incomplete* outputs (both missing a required column) are reported as
a **mismatch** (`contract_ok = FALSE`, `missing_required` lists the columns), never
as "behaviourally equivalent". The contract is the minimum schema a run must emit;
adding columns is allowed (and is itself a schema diff the comparator reports).

| table | required columns |
|---|---|
| MAP_STACKED | patient_id, med_abbr, map_cnt, map_start_dt, map_rx_runout_dt, map_med_runout_dt, map_end_dt, map_discon_flg |
| LOT1_BASE | patient_id, lot1_start_dt, lot1_base_meds, lot1_med_cnt, lot1_base_discon_dt, lot1_base_1st_add_med_dt |
| LOT_LONG | patient_id, lot_num, lot_start_dt, lot_base_meds, lot_med_cnt, lot_base_discon_dt, lot_base_1st_add_med_dt, lot_base_end_dt, lot_base_end_reason |

The two `*_1st_add_med_dt` fields are **required to be present** but are excluded
from the strict *value* verdict per the nondeterminism policy — present-but-excluded,
so a missing column is still a contract breach while a value difference is surfaced
as `excluded_diffs`.

`OUTPUT_CONTRACT_VERSION` is bumped whenever a required column is added or removed,
so a run manifest can record which contract version it was validated against.
