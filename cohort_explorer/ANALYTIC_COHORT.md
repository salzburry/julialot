# The analytic cohort: build once (slow), render instantly (config-driven)

Two goals, one design:

1. **The upstream LOT pipeline should be configurable** -- one study definition
   (windows, IE params, SOC map) drives the build, so the same pipeline serves
   Overall / NDMM / a future study without editing algorithm code.
2. **The dashboard must render immediately** -- it cannot run the warehouse
   pipeline per click (minutes). It must read a **pre-computed analytic cohort**
   and do all cohort selection in memory (milliseconds).

The insight that unifies them: **the analytic cohort is the flagged superset the
pipeline already computes.** The NDMM flag build already emits every IE criterion
as a boolean COLUMN
(`CE_pre_lot1_12mo`, `NO_BELANTAMAB`, `NO_PRIOR_MM_TX`,
`NO_OTHER_CANCER_PRE_LOT1`, `NO_PREGNANCY`) -- then discards them with
`WHERE ... = 1`. We stop filtering, **keep the flags as columns, and materialize
the table once.** The dashboard then selects a cohort by AND-ing flags in
memory. Nothing is re-derived per interaction.

```
   Warehouse (slow, run once per data refresh)          Dashboard (instant)
   +------------------------------------------+         +--------------------+
   | ELIG_COH_FINAL  (cohort build)            |         | load ONE snapshot   |
   |   x LOT_LONG    (LOT build)               |  -->    | at startup          |
   |   + IE flags as COLUMNS (flag SQL,        | CREATE  | (single SELECT /    |
   |     un-filtered) + demographics + CCI +   | TABLE   |  CSV/parquet read)  |
   |     safety counts + HCRU + per-line TTE   |         |                     |
   | = ANALYTIC_COHORT  +  ANALYTIC_LOT_LONG   |         | select = AND(flags) |
   +------------------------------------------+         | in memory -> ms      |
                     study_config (one file)             +--------------------+
```

## What "configurable" means concretely

The pipeline config already reads every LOT parameter from env vars (induction
windows, MAP gap, SCT windows, CART window, `max_lot`, disenrollment sensitivity,
study end). What is **not** yet config-driven and should be:

- The NDMM build's `NDMM_PRE_LOT1_DAYS` is hard-coded `365L`. `emit_pipeline_env.R`
  emits an `NDMM_PRE_LOT1_DAYS` env var, but the build will only honour it once
  that one line is lifted to `Sys.getenv(...)` -- a deliberate one-line,
  behavior-preserving change left for the pipeline owner (this tool does not
  modify the pipeline code).
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

- **`ANALYTIC_COHORT`** -- one row per superset patient: `patient_id`,
  demographics (age, sex, region, race, ethnicity, payer), `index_date`,
  `lot1_start_dt`, `death_dt`, dx/LOT-init years, follow-up, **CCI**, baseline
  **safety** flags+counts+`baseline_py`, **HCRU**, LOT-derived
  (`soc_category`, `n_lines`, `lot1_length`), patient-level **TTE**
  (`os/ttd/ttnt/pfs` + `fu_potential_months`), and **one 0/1 column per IE
  criterion** (`incl_*` / `excl_*`).
- **`ANALYTIC_LOT_LONG`** -- one row per (patient, line): `lot_num`,
  `lot_start_dt`, `lot_soc`, `next_soc`, `payer_type`, per-line TTE,
  `fu_potential_months`.

Both are validated fail-closed on load (`validate_flagged_cohort`,
`validate_lot_long`, `load_lot_long(cohort=)` coverage) -- a malformed
materialization aborts rather than mis-rendering.

## The build step (config-driven, warehouse-gated)

`source_flagged_cohort_warehouse()` (in `build_flagged_cohort.R`) is the seam:
it `SELECT *`s the two materialized tables via DBI/odbc (DSN/catalog from the
pipeline config). The **materialization** itself -- `CREATE TABLE ANALYTIC_COHORT
AS <NDMM flag join, un-filtered, + parent flags + chars>` -- is authored as a
pipeline step to run **once per data refresh** (e.g. nightly / on new source
quarter), reusing the NDMM build's existing flag SQL verbatim (only the trailing
`WHERE = 1` is dropped and the parent `ELIG_COH_FINAL` flags + CCI/safety/HCRU
projections are joined in). It cannot be executed in this environment (no
warehouse), so `source_flagged_cohort_warehouse()` stays **fail-closed** until
pointed at a live catalog.

**The concrete script: `warehouse/08_analytic_cohort.R`** (DRAFT /
unvalidated). It is **fully decoupled from the upstream pipeline -- it does not
source or modify any pipeline code.** It connects via DBI (env-var config) and
**reads the PERSISTED tables a prior pipeline run already wrote** --
`ELIG_COH_FINAL`, broad `LOT_LONG`, and `NDMM_FLAGS_ALL` (the validated NDMM flag
table) -- then projects `ELIG_COH_FINAL  JOIN  NDMM_FLAGS_ALL  JOIN  LOT_LONG` into the two
contract tables + CSV exports. Cross-checked to emit **all 57 contract
columns**. Every
new derivation is tagged inline: `[A]` Overall flags = 1 on the filtered base
(toggle needs `ELIG_COH_ALLFLAGS`), `[B]` race/region/payer/ethnicity join from
the source member tables, `[C]` OS/TTD/TTNT derivation (clinical sign-off), `[D]`
continuous CE months + safety counts/PY + HCRU, `[E]` SOC via a **placeholder**
start-type/med-count rule (production swaps in the authoritative
regimen->category map).

**The active build for this deployment: `warehouse/make_analytic_csv.R`.**
`08_analytic_cohort.R` is the generic, source-agnostic **scaffold** (tagged
derivations for whoever wires a new warehouse). `make_analytic_csv.R` is the
**project-local adapter actually run here**: it reads the persisted tables
(`elig_coh_final`, `lot1_base_end`, `ndmm_flags_all`, `lot_long`) and writes the
two CSVs. It uses the same datasource contract as `config/warehouse_config.R`
(`WAREHOUSE_DSN/PWD/CATALOG` + `PROJECT_WORK_SCHEMA`) and, when
`COHORT_EXPLORER_DIR` is set, **self-validates** the output with the real
`validate_flagged_cohort` + `load_lot_long` before promoting the temp files --
**fail-closed by default** (it refuses to write un-validated CSVs unless
`ALLOW_UNVALIDATED_EXPORT=TRUE`). `warehouse/diagnose_data.R` is a read-only
companion that reports how many rows fail each contract check.

Its follow-up model separates the two horizons the contract distinguishes.
**TTE (OS/TTD/TTNT) is censored at the pipeline's PRIMARY horizon
`ENDDATE = min(study end, death)`** by default; disenrollment censoring
(`ENDDATE_CE = min(study end, disenrollment, death)`) is the pipeline's
*optional sensitivity* variant, opt-in via `CENSOR_HORIZON_COL=ENDDATE_CE`.
**`fu_potential` is administrative and death-independent** -- under the primary
horizon it is exactly the study end (no disenrollment), so patients who die
early keep the potential follow-up they had and are **not** dropped from the
`>=3`-month denominators. (Under the sensitivity horizon the exact
death-independent value is `min(study end, disenrollment)`; supply
`DISENROLL_END_COL` to use a real disenrollment date, else it falls back to the
study end.) Only LOT lines starting on/before the horizon are "observable"; they
are renumbered `1..n` (contiguous) so the LOT-long line count equals `n_lines`
and the 1L row **is** the patient-level 1L outcome. Both `elig_coh_final` (by
`rn` when present, else earliest `INDEX_DATE`) and raw `lot_long` (one row per
`(patient, LOT_NUM)`) are de-duplicated before any join or renumbering; the run
logs how many duplicate line-rows were collapsed and whether any disagreed on
key fields.

## How the dashboard consumes it (instant)

At startup `global.R` loads the snapshot **once** from
`COHORT_EXPLORER_DATA` -- which is either `"synthetic"` (default) or a path to an
exported CSV (`COHORT_EXPLORER_DATA=/path/analytic_cohort.csv`), the wired path
that `make_analytic_csv.R` produces for this deployment (`08_analytic_cohort.R`
is the generic scaffold). A direct materialized-table read is also
available but is called **programmatically**, not via the env var:
`FLAGGED <- load_flagged_cohort(source_flagged_cohort_warehouse)` (that seam
stays fail-closed until pointed at a live catalog). It holds the snapshot in
memory, and every cohort switch / IE toggle / filter is an in-memory flag-AND
(`select_cohort`). No query runs on interaction. `export_analytic_cohort()`
writes the snapshot artifacts the offline path reads.

**Refresh model:** the analytic cohort is a *snapshot*. Re-materialize when the
data (new source quarter) or the study definition changes; the dashboard picks up
the new snapshot on restart. The snapshot carries a build stamp so the UI can
show "data as of ...".
