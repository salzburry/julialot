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

- the **seeded random tie-break** for the first-add med (02_lot1.R:806,
  `row_number() ... ORDER BY MAP_START_DT, rand(42)`). It selects **which med** is
  the first-add among candidates sharing the earliest add date. The DATE is
  `date_sub(MAP_START_DT, 1)` — identical across a same-date tie — so
  `*_1ST_ADD_MED_DT` is **deterministic** and only `*_1ST_ADD_MED` (the med
  identity) is excluded. Pending a deterministic fix, record `seed=42` + the
  Databricks runtime versions. If the med choice ever propagates into a downstream
  field (end date/reason/flags), that field is **not** excluded, so the strict
  comparison there is what catches the propagation (fail closed);
- any **same-date token display** (`min_by`/`max_by` over date alone) in
  reporting — display-only, compared as an unordered set, not a blocker.

Excluded fields are listed per table in `tests/fixtures/expected/nondeterministic.md`.

## MAP_STACKED — one row per (patient, drug, medication-available period)

Source projection: `apr_30_2026/02_lot1.R:643-662`.

| column | key | notes |
|---|---|---|
| patient_id | ✓ | |
| med_abbr | ✓ | drug identity (per the MMA rollup) |
| med_class | | drug class (IMID / PI / STEROID / mAb / ...) |
| map_cnt | ✓ | MAP sequence within (patient, drug) |
| map_start_dt | | |
| map_rx_runout_dt | | pharmacy runout (with pushout / reset-without-pushout) |
| map_med_runout_dt | | medical runout (never pushed out) |
| map_end_dt | | max(rx_runout, med_runout) |
| map_med_type | | alias of `med_abbr` (emitted) |
| map_med_class | | alias of `med_class` (emitted) |
| map_discon_flg | | gap to next MAP / OBS_END ≥ `map_discon_gap_days` (90) |

- **Key:** (patient_id, med_abbr, map_cnt).
- **Determinism:** fully deterministic given canonical inputs + params.

## LOT1_BASE — one row per patient (LOT1 induction)

Source projection: `apr_30_2026/02_lot1.R:814-823`. Besides the LOT-derived
columns below, the physical table also carries **cohort-passthrough demographics**
(`index_date`, `enddate`, `obs_end_dt`, `death_dt`, `gdr_cd`, `yrdob`,
`age_index_yr`) and **dynamic per-drug / per-class flags** (`lot1_med_*`,
`lot1_class_*`). Those two classes are governed elsewhere (cohort/input contract;
study-specific schema) and are not part of the LOT-output contract — see below.

| column | key | notes |
|---|---|---|
| patient_id | ✓ | |
| lot1_start_dt | | min(map_start_dt) across non-STEROID classes |
| lot1_med_cnt | | |
| lot1_base_meds | | induction meds ∪ permissible substitutes (steroids excluded) |
| lot1_base_discon_dt | | capped at OBS_END_DT |
| lot1_base_1st_add_med_dt | | earliest add date − 1 (deterministic) |
| lot1_base_1st_add_med | | **nondeterministic tie-break (seed 42)** — see policy |

- **Key:** patient_id.

## LOT_LONG — one row per (patient, LOT_NUM ∈ 1..MAX_LOT)

Source projection: `apr_30_2026/R/lot2_5_base.R:76-135` (LOT1 init) and `:891-960`
(LOT≥2 append) — both emit the identical fixed column set. Plus the same dynamic
per-drug / per-class wide columns as LOT1_BASE. There is **no** `lot_end_type`
column (the end is captured by `lot_base_end_reason` + its CE-sensitive variant).

| column | key | notes |
|---|---|---|
| patient_id | ✓ | |
| lot_num | ✓ | 1..MAX_LOT (default 5) |
| lot_start_dt | | |
| lot_start_type | | MED / SCT_ALLO / SCT_AUTO / CART (the LOT trigger) |
| lot_base_meds | | |
| lot_med_cnt | | |
| lot_base_discon_dt | | |
| lot_base_1st_add_med_dt | | earliest add date − 1 (deterministic) |
| lot_base_1st_add_med | | inherits LOT1 tie-break nondeterminism for LOT1 |
| lot_base_end_dt | | |
| lot_base_end_reason | | SCT/CART/ALLO/progression/discontinuation/etc. |
| lot_base_length | | days, 2-way formula off the derived end date |
| lot_allo_lot_flg | | 1 when start_type = SCT_ALLO |
| lot_cart_lot_flg | | 1 when start_type = CART |
| contains_mtx_reg | | maintenance regimen present (descriptive) |
| lot_base_end_dt_ce_sens | | end date capped at ENDDATE_CE |
| lot_base_end_reason_ce_sens | | DISENROLLMENT when CE-capped before ENDDATE |
| lot_tx_auto_flg | | in-LOT AUTO SCT present |
| lot_tx_auto_tand_flg | | in-LOT tandem AUTO |
| lot_tx_auto_sing_flg | | in-LOT single AUTO |
| lot_tx_auto_dt_1 | | first in-LOT AUTO date |
| lot_tx_auto_dt_2 | | second in-LOT AUTO date (tandem) |
| lot_tx_auto_max_dt | | latest qualifying in-LOT AUTO date |

- **Key:** (patient_id, lot_num).
- **Determinism:** deterministic except the inherited LOT1 first-add **med** tie-break.

## Comparison keys (for `compare_run_outputs.R`)

| table | join key |
|---|---|
| MAP_STACKED | (patient_id, med_abbr, map_cnt) |
| LOT1_BASE | (patient_id) |
| LOT_LONG | (patient_id, lot_num) |

## Output contract — required columns (versioned)

The comparator enforces a **versioned output contract** (`OUTPUT_CONTRACT`,
`OUTPUT_CONTRACT_VERSION = 0.2-draft` in `compare_run_outputs.R`): every required
column below must be present on **both** sides of a comparison. This is a
fail-closed check — two *equally incomplete* outputs (both missing a required
column, e.g. both dropping `lot_start_type` or `contains_mtx_reg`) are reported as
a **mismatch** (`contract_ok = FALSE`, `missing_required` lists the columns), never
as "behaviourally equivalent". The contract is the minimum schema a run must emit;
adding columns is allowed (and is itself a schema diff the comparator reports).

The required set is the full **algorithm-derived** column set the production
builders emit (the file:line projections cited per table above). Two column classes
are intentionally **not** in the required set, because they are not LOT-equivalence
fields — both are still caught one-sided by the schema-equality check:
- **study-specific per-drug / per-class wide columns** (`lot1_med_*`,
  `lot_class_*`, ...): the set varies by cohort, so it is not a fixed contract;
- **cohort-passthrough demographics** on LOT1_BASE (`index_date`, `enddate`,
  `obs_end_dt`, `death_dt`, `gdr_cd`, `yrdob`, `age_index_yr`): governed by the
  cohort / canonical-input contract.

| table | required columns |
|---|---|
| MAP_STACKED | patient_id, med_abbr, med_class, map_cnt, map_start_dt, map_rx_runout_dt, map_med_runout_dt, map_end_dt, map_med_type, map_med_class, map_discon_flg |
| LOT1_BASE | patient_id, lot1_start_dt, lot1_med_cnt, lot1_base_meds, lot1_base_discon_dt, lot1_base_1st_add_med_dt, lot1_base_1st_add_med |
| LOT_LONG | patient_id, lot_num, lot_start_dt, lot_start_type, lot_base_meds, lot_med_cnt, lot_base_discon_dt, lot_base_1st_add_med_dt, lot_base_1st_add_med, lot_base_end_dt, lot_base_end_reason, lot_base_length, lot_allo_lot_flg, lot_cart_lot_flg, contains_mtx_reg, lot_base_end_dt_ce_sens, lot_base_end_reason_ce_sens, lot_tx_auto_flg, lot_tx_auto_tand_flg, lot_tx_auto_sing_flg, lot_tx_auto_dt_1, lot_tx_auto_dt_2, lot_tx_auto_max_dt |

The `*_1st_add_med` (med-identity) fields are **required to be present** but
excluded from the strict *value* verdict per the nondeterminism policy
(present-but-excluded): a missing column is still a contract breach, while a value
difference is surfaced as `excluded_diffs`. Their `*_1st_add_med_dt` partners are
required **and** strictly compared (deterministic).

`OUTPUT_CONTRACT_VERSION` is bumped whenever a required column is added or removed,
so a run manifest can record which contract version it was validated against.
