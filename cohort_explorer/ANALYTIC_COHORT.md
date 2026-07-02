# The analytic cohort: build once (slow), render instantly (config-driven)

Two goals, one design:

1. **`apr_30_2026` should be configurable** — one study definition (windows, IE
   params, SOC map) drives the build, so the same pipeline serves Overall /
   NDMM / a future study without editing algorithm code.
2. **The dashboard must render immediately** — it cannot run the Databricks
   pipeline per click (minutes). It must read a **pre-computed analytic cohort**
   and do all cohort selection in memory (milliseconds).

The insight that unifies them: **the analytic cohort is the flagged superset the
pipeline already computes.** `06_ndmm_dashboard.R` (lines 666–697) already emits
every IE criterion as a boolean COLUMN
(`CE_pre_lot1_12mo`, `NO_BELANTAMAB`, `NO_PRIOR_MM_TX`,
`NO_OTHER_CANCER_PRE_LOT1`, `NO_PREGNANCY`) — then discards them with
`WHERE ... = 1`. We stop filtering, **keep the flags as columns, and materialize
the table once.** The dashboard then selects a cohort by AND-ing flags in
memory. Nothing is re-derived per interaction.

```
   Databricks (slow, run once per data refresh)          Dashboard (instant)
   ┌──────────────────────────────────────────┐         ┌────────────────────┐
   │ ELIG_COH_FINAL  (01_cohort.R)             │         │ load ONE snapshot   │
   │   × LOT_LONG    (02_lot1 / lot2_5_base)   │  ──▶    │ at startup          │
   │   + IE flags as COLUMNS (06 flag SQL,     │ CREATE  │ (single SELECT /    │
   │     un-filtered) + demographics + CCI +   │ TABLE   │  CSV/parquet read)  │
   │     safety counts + HCRU + per-line TTE   │         │                     │
   │ = ANALYTIC_COHORT  +  ANALYTIC_LOT_LONG   │         │ select = AND(flags) │
   └──────────────────────────────────────────┘         │ in memory → ms      │
                     study_config (one file)             └────────────────────┘
```

## What "configurable" means concretely

`config_lot.R` already reads every LOT parameter from env vars (induction
windows, MAP gap, SCT windows, CART window, `max_lot`, disenrollment sensitivity,
study end). What is **not** yet config-driven and should be:

- `06`'s `NDMM_PRE_LOT1_DAYS` is hard-coded `365L`. `emit_pipeline_env.R` emits an
  `NDMM_PRE_LOT1_DAYS` env var, but `06` will only honour it once that one line is
  lifted to `Sys.getenv(...)` — a deliberate one-line, behavior-preserving change
  left for the apr_30 owner (this branch does not modify apr_30 code).
- The six NDMM filters auto-skip only when a **source is unavailable**; they are
  not individually **includable/excludable by study choice**. The analytic-cohort
  build makes this moot: it *always computes every flag as a column*, and which
  flags define a given cohort becomes a **dashboard/config decision**
  (`cohort_definitions()` / `study_config`), not a pipeline edit.

`study_config.R` (added here) is the single source of the study-level knobs the
build and the dashboard share: study/ID window, `lot1_from`, `pre_lot1_days`,
per-cohort baseline/follow-up CE months, age minimum, and the SOC category map.

## The two materialized tables (the dashboard's existing contract)

The dashboard already validates these exact schemas
(`FLAGGED_COHORT_BASE_COLS` + `registry_flag_ids()`; `LOT_LONG_REQUIRED_COLS`),
so the build just has to emit them:

- **`ANALYTIC_COHORT`** — one row per superset patient: `patient_id`,
  demographics (age, sex, region, race, ethnicity, payer), `index_date`,
  `lot1_start_dt`, `death_dt`, dx/LOT-init years, follow-up, **CCI**, baseline
  **safety** flags+counts+`baseline_py`, **HCRU**, LOT-derived
  (`soc_category`, `n_lines`, `lot1_length`), patient-level **TTE**
  (`os/ttd/ttnt/pfs` + `fu_potential_months`), and **one 0/1 column per IE
  criterion** (`incl_*` / `excl_*`).
- **`ANALYTIC_LOT_LONG`** — one row per (patient, line): `lot_num`,
  `lot_start_dt`, `lot_soc`, `next_soc`, `payer_type`, per-line TTE,
  `fu_potential_months`.

Both are validated fail-closed on load (`validate_flagged_cohort`,
`validate_lot_long`, `load_lot_long(cohort=)` coverage) — a malformed
materialization aborts rather than mis-rendering.

## The build step (config-driven, warehouse-gated)

`source_flagged_cohort_warehouse()` (in `build_flagged_cohort.R`) is the seam:
it `SELECT *`s the two materialized tables via DBI/odbc (DSN/catalog from
`config_lot.R`). The **materialization** itself — `CREATE TABLE ANALYTIC_COHORT
AS <06 flag join, un-filtered, + parent flags + chars>` — is authored as a
pipeline step to run **once per data refresh** (e.g. nightly / on new Optum
quarter), reusing `06`'s existing flag SQL verbatim (only the trailing
`WHERE = 1` is dropped and the parent `ELIG_COH_FINAL` flags + CCI/safety/HCRU
projections are joined in). It cannot be executed in this environment (no
warehouse), so `source_flagged_cohort_warehouse()` stays **fail-closed** until
pointed at a live catalog.

**The concrete script: `warehouse/08_analytic_cohort.R`** (DRAFT /
unvalidated). It is **fully decoupled from apr_30 — it does not source or modify
any apr_30 code.** It connects via DBI (env-var config) and **reads the
PERSISTED tables a prior apr_30 pipeline + `06` run already wrote** —
`ELIG_COH_FINAL`, broad `LOT_LONG`, and `NDMM_FLAGS_ALL` (the validated NDMM flag
table) — then projects `ELIG_COH_FINAL ⋈ NDMM_FLAGS_ALL ⋈ LOT_LONG` into the two
contract tables + CSV exports. Cross-checked to emit **all 57 contract
columns**. Every
new derivation is tagged inline: `[A]` Overall flags = 1 on the filtered base
(toggle needs `ELIG_COH_ALLFLAGS`), `[B]` race/region/payer/ethnicity join from
Optum member tables, `[C]` OS/TTD/TTNT derivation (clinical sign-off), `[D]`
continuous CE months + safety counts/PY + HCRU, `[E]` SOC via `06`'s
regimen→category lookup.

## How the dashboard consumes it (instant)

At startup `global.R` loads the snapshot **once** from
`COHORT_EXPLORER_DATA` — which is either `"synthetic"` (default) or a path to an
exported CSV (`COHORT_EXPLORER_DATA=/path/analytic_cohort.csv`), the wired path
that `08_analytic_cohort.R` produces. A direct materialized-table read is also
available but is called **programmatically**, not via the env var:
`FLAGGED <- load_flagged_cohort(source_flagged_cohort_warehouse)` (that seam
stays fail-closed until pointed at a live catalog). It holds the snapshot in
memory, and every cohort switch / IE toggle / filter is an in-memory flag-AND
(`select_cohort`). No query runs on interaction. `export_analytic_cohort()`
writes the snapshot artifacts the offline path reads.

**Refresh model:** the analytic cohort is a *snapshot*. Re-materialize when the
data (new Optum quarter) or the study definition changes; the dashboard picks up
the new snapshot on restart. The snapshot carries a build stamp so the UI can
show "data as of …".
