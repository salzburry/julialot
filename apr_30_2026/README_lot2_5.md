# LOT 2-5 — How to run

This directory ships an additional, **standalone** module that builds LOT2
through LOT5 on top of the existing LOT1 outputs. It does not modify
`lot_program.R` or any LOT1 code.

## Files

- `R/lot2_5_inputs.R` — `prepare_lot_inputs(con, ...)`: rebuilds the
  session-scoped views the builder needs (`lot_patient_input`, `mma_rollup`,
  `permissible_subs`, `sct_codelist`, `sct_claims_raw`, `tx_auto_dates`,
  `tx_allo_cart_dates`) from CSVs + persisted CDM/cohort tables.
- `R/lot2_5_base.R` — module: `build_lot2_5(con, ...)` and helpers.
- `lot2_5_program.R` — entry script.
- Spec: `../Apr 18 2026/Program Spec and Scenarios/lot2to5_spec_DRAFT_apr30.xlsx`.

## Order of operations

There are two ways to run the full pipeline.

### Option A — top-level orchestrator (recommended)

`run_pipeline.R` runs all three stages (cohort attrition → LOT1 → LOT2-5)
in sequence, skipping any stage whose output table already exists. Each
stage is probed at the schema it actually writes to, using the same
fallback chains as the stage configs:

- Cohort attrition (`config_prompts.R`): `personal_schema` = `DOMINO_USER_NAME`
  → `DOMINO_STARTING_USERNAME`. Table = `FINAL_TABLE_NAME`
  (default `ELIG_COH_FINAL`).
- LOT1 / LOT2-5 (`config_lot.R`): `work_schema` = `PROJECT_WORK_SCHEMA`
  → `DOMINO_USER_NAME` → `gsk_mm_lot_work`.

Defaults: `DATABRICKS_DSN=RWDE`, `DATABRICKS_CATALOG=hive_metastore` (both
match the stage configs).

```
Rscript run_pipeline.R
```

Skip flags:
- `FORCE_RERUN=TRUE Rscript run_pipeline.R` — re-run every stage even
  if outputs already exist.
- `SKIP_COHORT=TRUE SKIP_LOT1=TRUE Rscript run_pipeline.R` — LOT2-5 only.
- `SKIP_LOT2_5=TRUE Rscript run_pipeline.R` — cohort attrition + LOT1
  only.

Rebuilding `LOT_LONG` (e.g. after a code change): prefer
`FORCE_RERUN=TRUE` over manually dropping the table —

```
SKIP_COHORT=TRUE SKIP_LOT1=TRUE FORCE_RERUN=TRUE Rscript run_pipeline.R
```

Because the LOT2-5 build is atomic (writes `LOT_LONG_STAGE`, swaps to
`LOT_LONG` only on full success), `FORCE_RERUN` keeps the existing
`LOT_LONG` intact until a complete rebuild lands. A manual
`DROP TABLE LOT_LONG` is strictly riskier: if the rebuild then fails
mid-loop you are left with no `LOT_LONG` at all. (`SKIP_*` still take
precedence over `FORCE_RERUN`, so the command above re-runs only
LOT2-5.)

After every stage the orchestrator verifies its primary output table
(`FINAL_TABLE_NAME` / cohort output, `LOT1_BASE_END`, `LOT_LONG`)
actually landed in the
schema that stage writes to. If a stage exits 0 but its output is
missing — usually because `materialize_to_personal_schema()` warned but
did not write — the orchestrator **halts immediately with `stop()`**
rather than continuing. This catches silent persistence failures at
the offending stage instead of letting them cascade into a cryptic
`TABLE_OR_VIEW_NOT_FOUND` two stages later.

Before each stage runs, the orchestrator also probes that **every
required input table** is visible at the schema the stage will read
from:

- LOT1 needs `<lot_work_schema>.<INPUT_COHORT_TABLE>`.
- LOT2-5 needs every persisted LOT1 table that `lot2_5_inputs.R`
  rebinds AS the temp views `lot2_5_base.R` reads — `MAP_STACKED`,
  `LOT1_SCT`, `LOT1_BASE_END` — **plus** `<INPUT_COHORT_TABLE>` (used
  to rebuild `lot_patient_input`). All four are probed at
  `<lot_work_schema>`. A LOT2-5-only run
  (`SKIP_COHORT=TRUE SKIP_LOT1=TRUE`) therefore needs every one of
  them already present in the LOT work schema.

This is what catches the case where cohort attrition persisted to a
different schema and no bridging view exists — the orchestrator stops
with a clear message instead of letting LOT1 / LOT2-5 hit
`TABLE_OR_VIEW_NOT_FOUND`.

Two pre-flight checks at startup are warnings only (the per-stage
input probe above is the source of truth for whether the pipeline
proceeds):

- Table-name divergence (`FINAL_TABLE_NAME` != `INPUT_COHORT_TABLE`):
  warns; a bridging alias/view can still let LOT find the cohort.
- Schema divergence (`DOMINO_USER_NAME` vs `PROJECT_WORK_SCHEMA`):
  warns; a bridging view can still let LOT find the cohort.

### Option B — run each stage manually

1. Run `lot_program.R` first. LOT2-5 reads
   `MAP_STACKED`, `LOT1_SCT`, and `LOT1_BASE_END` (all persisted by
   LOT1), plus `cfg$input_cohort_table`. LOT1 also persists
   `LOT1_BASE` and `MMA_MED_PROCESSED` for downstream descriptives,
   but the LOT2-5 builder itself does not read them.
2. Run `lot2_5_program.R`. It loads codelists from CSV, rebuilds the
   session-scoped temp views, and produces `LOT_LONG` with one row per
   `(PATID, LOT_NUM)` for `LOT_NUM = 1..max_lot`.

```
Rscript lot_program.R
Rscript lot2_5_program.R
```

## LOT 1-5 dashboard

`lot_program.R`'s dashboard (`lot_dashboard.html`) is LOT1-only — its
`descriptives_lot.R` has a `LOT1` section but no LOT2-5 sections, and
`lot2_5_program.R` does not build a dashboard at all.

`lot_long_dashboard.R` is a **standalone** entry script that reads
`work_schema.LOT_LONG` and writes a **separate** interactive HTML
(`lot_long_dashboard.html` in `cfg$output_dir`). It does not modify or
overwrite `lot_dashboard.html`. Sections (all by `LOT_NUM`):

- **Overview / Funnel** — patients per LOT + retention table
- **Start Type / End Reason** — composition per LOT
- **Length** — median + IQR per LOT
- **Regimens** — top 10 per LOT
- **Progression** — how far patients get (furthest LOT reached)
- **Gaps** — days between consecutive LOTs (median + IQR)
- **Transitions** — start-type N -> start-type N+1
- **Sankey** — three interactive flow diagrams: start-type flow
  across LOTs; LOT end reason -> next LOT start type (or terminal);
  drop-off funnel (continue vs stop per LOT)
- **Med count** — mean/median `LOT_MED_CNT` per LOT
- **MTX** — `contains_mtx_reg` rate per LOT
- **Trend** — LOT starts over calendar time, by quarter and LOT_NUM
- **Patient Journeys** — per-patient LOT timeline Gantts (like the
  LOT1 dashboard's Patient Journey, but each bar is a LOT spanning
  `LOT_START_DT -> LOT_BASE_END_DT`, colored by start type, with
  hover showing reason/length/regimen). A spread of example patients
  is auto-selected (deepest progressors + one per terminal reason).
- **Drilldown** — type/paste a `PATID` (native autocomplete over the
  embedded patients) and the card renders that patient's LOT timeline
  client-side. For targeted debugging, not just the auto-picked
  examples. Embeds up to `DRILLDOWN_MAX_PATIENTS` patients (default
  8000; raise via env var). When the cap is hit the card is titled
  "Patient drilldown (embedded sample)".
- **Debug/QC** — reads the persisted work-schema tables (NOT temp
  views, so no LOT1-session dependency): table inventory with row
  counts (`INPUT_COHORT_TABLE` shown as the cohort input,
  `MMA_MED_PROCESSED`, `MAP_STACKED`,
  `LOT1_BASE`, `LOT1_SCT`, `LOT1_BASE_END`, `LOT_LONG`),
  `LOT_RUN_METADATA`, `LOT_QC_SUMMARY`, and a LOT1 cross-check
  (`LOT1_BASE_END` end-reason vs `LOT_LONG` LOT1). Missing tables are
  reported, never fatal.

Navigation is a **collapsible left sidebar** (GSK-styled): categories
as expandable groups, views as a clickable list, content in a main
panel. Built-in:

- **Search box** — filter views by title across all categories (`/`
  focuses it; `Esc` clears).
- **Keyboard nav** — `Left`/`Right` arrows step prev/next view, `F`
  toggles fullscreen.
- **Shareable links** — the URL hash tracks the current view, so a
  specific chart can be bookmarked/shared and reopens there.
- **Fullscreen** — expand any chart/table to the full window.

The colour theme is a GSK-style palette defined as CSS variables in a
`:root` block at the top of the generated HTML — these approximate the
GSK brand; drop the exact brand hexes into `:root` to retune the
whole dashboard centrally. The LOT1 `lot_dashboard.html` gets the same
sidebar UI, since both share `build_dashboard()`.

```
Rscript lot_long_dashboard.R
```

Prerequisite: `LOT_LONG` must already be built. The LOT2-5 build is
now **atomic**: every LOT writes a `LOT_LONG_STAGE` table and
`build_lot2_5()` only promotes it to `LOT_LONG` after all LOTs append
successfully. A mid-loop failure therefore leaves `LOT_LONG_STAGE`
partial while `LOT_LONG` is either absent (first run — orchestrator
correctly reports the stage failed) or still the previous complete
build. So `LOT_LONG` should never again contain only `LOT_NUM = 1`
from a half-finished run; if it ever does, the dashboard's OVERVIEW
card flags it explicitly.

## Output: LOT_LONG

Long-format table; one row per patient per LOT.

| Column                          | Notes                                          |
|---------------------------------|------------------------------------------------|
| `PATID`, `LOT_NUM`              | 1..max_lot                                     |
| `LOT_START_DT`, `LOT_START_TYPE`| `MED` / `SCT_AUTO` / `SCT_ALLO` / `CART`       |
| `LOT_BASE_MEDS`, `LOT_MED_CNT`  | 30d induction window (LOT1 was 60d)            |
| `LOT_BASE_DISCON_DT`            | run-out date if regimen ran out                |
| `LOT_BASE_1ST_ADD_MED_DT/_MED`  | first non-induction agent during LOT           |
| `LOT_BASE_END_DT/_REASON/_LENGTH`| primary analysis (disenrollment ignored)      |
| `LOT_ALLO_LOT_FLG`, `LOT_CART_LOT_FLG` | start-type indicators                   |
| `contains_mtx_reg`              | descriptive maintenance flag (LOT1 logic)      |
| `LOT_BASE_END_DT_CE_SENS`       | sensitivity end date (capped at ENDDATE_CE)    |
| `LOT_BASE_END_REASON_CE_SENS`   | `DISENROLLMENT` only when ELIGEND binds        |

## Configuration overrides

### `pipeline_inputs.csv` (edit inputs in one place)

Instead of juggling `Sys.setenv()` / shell exports, edit
`apr_30_2026/pipeline_inputs.csv` (open it in Excel or any editor).
Columns: `name,value,description`. Set the `value` you want; leave it
blank to keep the default. `run_pipeline.R`, `lot2_5_program.R`, and
`lot_long_dashboard.R` all load this file **before** reading any
config, and a non-empty value overrides the environment — so this is
your single "change / reset inputs" file.

Notes:
- `DATABRICKS_PWD` is intentionally **not** in the file and is never
  read from it — the password stays in the environment / Domino
  secret store.
- Rows whose `name` is blank or starts with `#` are comment rows.
- The orchestrator applies the file in the parent R process, so the
  overrides propagate to every per-stage `Rscript` subprocess too.
- Anything not listed can still be added as a new row — any env var
  the pipeline reads works.

The file ships pre-filled with the current defaults so it doubles as
a documented reference. It includes the cohort **inclusion** criteria
(`APPLY_AGE_INCL`, `MIN_AGE`, `APPLY_CE_B_INCL`, `APPLY_CE_F_INCL`,
`APPLY_NO_BL_AGENTS_INCL`, `APPLY_FU_AGENTS_INCL`) **and exclusion**
criteria (`APPLY_PREGNANCY_EXCL`, `APPLY_CLINTRIAL_EXCL`,
`APPLY_OTHER_MALIG_EXCL`, `APPLY_BASELINE_MM_EXCL`) — set any to
`FALSE` to drop that rule from the attrition build. (Inclusion
criteria were previously hardcoded; they are now env/CSV-driven with
the same defaults, so existing builds are unaffected.)

Example — rebuild only LOT2-5: set `SKIP_COHORT=TRUE`,
`SKIP_LOT1=TRUE`, `FORCE_RERUN=TRUE` in the CSV, then
`Rscript run_pipeline.R`.

### Environment variables

Environment variables (in addition to the LOT1 set):

| Env var                       | Default         | Spec ref       |
|-------------------------------|-----------------|----------------|
| `INDUCTION_WINDOW_DAYS_LOT_N` | `30`            | study-team decision |
| `CART_CONSOLIDATION_DAYS`     | `45`            | study-team decision |
| `SCT_TANDEM_DAYS`             | `180`           | inherited LOT1 |
| `ALLO_LOT_SPAN`               | `single_day`    | Q2 (resolved)  |
| `MAX_LOT`                     | `5`             | Q6 (open)      |

Note: there is only ONE 90-day discontinuation rule in the pipeline — the per-drug
MAP-level `MAP_DISCON_GAP_DAYS` parameter. No additional LOT-level wait exists
(Q1 06-May, confirmed Julia 13-May).

`ALLO_LOT_SPAN=extend_to_next` switches the ALLO-singleton LOT to span
through the day before the next qualifying agent.

## Open questions still pending sign-off

Resolved as of 13-May: Q1 (90-day LOT-level buffer — removed; the only
90-day rule is the per-drug MAP-level `MAP_DISCON_GAP_DAYS`), Q2 (ALLO
LOT spans a single day), Q9 (tandem AUTO uses `<= sct_tandem_days`
upper bound only; `tx_auto_dates` already groups < 60 d events upstream),
Q11 (CAR-T 45 d consolidation), Q12 (disenrollment in sensitivity only),
Q14 (same-day START priority `SCT_ALLO > CART > SCT_AUTO > MED` using
the LOT_START_TYPE labels), Q15
(CAR-T LOT runout = `DISCONTINUATION`), Q16 (AUTO trigger broadening
LOT2-5 only).

Still open and shipping with the draft defaults above: Q3, Q4, Q5, Q6,
Q10, Q13 (mostly draft confirmations; none behaviorally significant
under common histories), Q7, Q8 (Onkar — pipeline-output verifications).
