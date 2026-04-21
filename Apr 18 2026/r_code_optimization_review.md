# R Code Optimization Review — Apr 18 2026 Program

**Scope:** `Apr 18 2026/Program/` (main.R, lot_program.R, R/*.R)
**Reviewer:** Code review pass on 2026-04-21

---

## TL;DR

The pipeline is well-architected: heavy data work is pushed to Spark/Databricks, and
R-side logic avoids quadratic loops on large data. The remaining runtime cost is
dominated by **repeated warehouse scans for observability** — not by R-side inefficiency.

Two findings account for most of the avoidable wall-clock time:

1. **Per-step QC runs unconditionally**, forcing an extra full/partial scan of each
   intermediate view right after it is built. Great for debugging, expensive in prod.
2. **Descriptive reporting (`descriptives_lot.R`) issues ~50 small singleton
   aggregate queries** and rescans the same large tables (`map_stacked`,
   `lot1_sct`, `lot1_base_end`, `mma_med_processed`) many times across sections,
   even though a run-metadata/QC summary table is already persisted upstream.

Both are **reporting/observability layer** issues, not correctness problems.
Fixing them is non-invasive and should cut end-to-end runtime meaningfully on a
remote warehouse where round-trip latency is high.

---

## Finding 1 — Per-step QC adds an extra warehouse pass to many LOT steps

### Evidence

`run_step()` always executes the QC query immediately after the main SQL:

```r
# Apr 18 2026/Program/R/db_utils.R:210-220
DBI::dbExecute(conn$con, sql)

if (!is.null(qc_sql)) {
  qc <- DBI::dbGetQuery(conn$con, qc_sql)
  qc_metric <- colnames(qc)[1]
  qc_value  <- as.character(qc[[1]][1])
  ...
  log_msg("  >> Result: ", qc_metric, " = ", formatted)
}
```

There is **no flag to skip QC**. Every `qc_sql` attached to a step runs, regardless
of environment (dev vs. prod).

How much QC is attached:

| File                 | Count of `qc =` attachments |
|----------------------|------------------------------|
| `pipeline_steps.R`   | 21                           |
| `lot_program.R`      | 21                           |
| **Total**            | **42**                       |

Several QC checks are non-trivial full scans of the just-materialized view — for example:

```r
# pipeline_steps.R:226  (after mm_dx_events_all)
qc = glue("SELECT count(DISTINCT PATID) AS n_patients,
                  sum(inpatient_flg)    AS n_inpatient_events,
                  sum(conf_validated)   AS n_via_conf,
                  sum(pos_tos_inpatient) AS n_via_pos_tos
           FROM {work('mm_dx_events_all')}")

# pipeline_steps.R:985  (after ELIG_COH_ALLFLAGS)
qc = glue("SELECT count(*) AS n_total, count(DISTINCT PATID) AS n_patients
           FROM {work('ELIG_COH_ALLFLAGS')}")

# pipeline_steps.R:1011 (after final cohort table)
qc = glue("SELECT count(*) AS n_final_cohort FROM {work(cfg$final_table_name)}")
```

Each of these is effectively a second pass over the same data Spark just wrote.

### Why this matters

- **Doubles the touch count** on each intermediate view that has QC attached.
- **Serial round-trips**: every QC query is a separate ODBC call with its own
  round-trip and Spark job-submission overhead.
- `count(DISTINCT PATID)` in particular is a shuffle-heavy operation; running it
  ~40× per run adds up on a large cohort.

### Recommended fixes

Pick one; they are not mutually exclusive.

**(a) Add a config flag to disable per-step QC in prod.** Smallest change.

```r
# db_utils.R — run_step()
if (isTRUE(cfg$run_step_qc) && !is.null(qc_sql)) {
  qc <- DBI::dbGetQuery(conn$con, qc_sql)
  ...
}
```

Default `cfg$run_step_qc = TRUE` in dev, `FALSE` in prod.

**(b) Batch QC at phase boundaries.** Collect step→qc_sql pairs during a phase,
then issue one multi-CTE query at the end of the phase. For the codelist phase
(steps S00–S02), this collapses 6 singleton counts into one call.

**(c) Fold cheap QC into the main SQL.** For steps that build a small summary
table, include the count as a column in the result and read it from the persisted
metadata later, instead of re-querying.

**(d) Rely on the already-persisted `qc_summary` table** (built in
`lot_program.R:2237-2245`) rather than re-running metrics in the report layer
(see Finding 2).

---

## Finding 2 — Descriptive reporting does many small and repeated scans

### Evidence: singleton aggregates

`descriptives_lot.R:30-44` issues 8 independent aggregate queries back-to-back:

```r
# descriptives_lot.R:30-44
cohort_n   <- db_q(con, "SELECT count(DISTINCT PATID) AS n FROM lot_patient_input")$n
mma_n      <- db_q(con, "SELECT count(*) AS n FROM mma_med_processed")$n
mma_pat_n  <- db_q(con, "SELECT count(DISTINCT PATID) AS n FROM mma_med_processed")$n
map_n      <- db_q(con, "SELECT count(*) AS n FROM map_stacked")$n
map_pat_n  <- db_q(con, "SELECT count(DISTINCT PATID) AS n FROM map_stacked")$n
lot1_n     <- db_q(con, "SELECT count(*) AS n FROM lot1_base")$n
sct_n      <- db_q(con, "SELECT sum(...) AS n FROM lot1_sct")$n
censored_n <- db_q(con, "SELECT sum(...) AS n_cens, count(*) AS n_total FROM lot_patient_input")
```

The QC tab (lines 112-187) does the same again — 8 more singleton aggregate
`db_q()` calls for pass/fail checks.

In total, `descriptives_lot.R` contains **54 `db_q()` calls**, the majority of
which are small aggregate singletons.

### Evidence: repeated full scans

Across sections, the same large tables are scanned many times:

| Table                | Scan count in `descriptives_lot.R` | Example lines                              |
|----------------------|-----------------------------------:|--------------------------------------------|
| `map_stacked`        | ~17                                | 33, 34, 144, 151, 376, 398, 426, 457, 856, 882, 1046–1047, 1093, 1097, 1110, 1278, 1284, 1293 |
| `lot1_sct`           | ~11                                | 36, 173, 183, 794, 822, 864, 897, 1365, 1420, 1438, 1570 |
| `lot1_base_end`      | ~8                                 | 540, 560, 584, 636, 643, 1318, 1324, 1333  |
| `mma_med_processed`  | 5                                  | 31, 32, 238, 256, 340                      |
| `lot_patient_input`  | 3                                  | 30, 41, 164                                |

Each scan is a separate Spark job — reading the same Parquet/Delta files,
computing similar aggregates, then returning a tiny result set.

### The already-persisted data isn't reused

The pipeline already creates `run_metadata` and `qc_summary` tables:

```r
# lot_program.R:2178-2245
run_step(con, "S22a_create_metadata_table", ...)
run_step(con, "S22c_insert_run_metadata",   ...)
run_step(con, "S23a_create_qc_table",       ...)
run_step(con, "S23c_insert_qc_summary",     ...)
```

So the cohort/MMA/MAP/LOT1 counts are computed once during persistence — but the
report recomputes them from scratch on lines 30-44 instead of reading from
`run_metadata`.

### Why this matters

- **Round-trip latency**: on a remote warehouse, ~50 singleton ODBC calls in
  sequence often dominates the report's wall time, even if each individual
  aggregate is fast.
- **Redundant I/O**: scanning `map_stacked` 17 times means 17× Parquet read +
  Spark planning overhead.
- **No cache benefit in R**: `db_q()` returns immediately after the result is
  materialized; there is no caching layer, so each new call is a new job.

### Recommended fixes

**(a) Collapse singleton aggregates into one query per section.** The 8 overview
counts at lines 30-44 become:

```r
overview <- db_q(con, "
  SELECT
    (SELECT count(DISTINCT PATID) FROM lot_patient_input)     AS cohort_n,
    (SELECT count(*)              FROM mma_med_processed)     AS mma_n,
    (SELECT count(DISTINCT PATID) FROM mma_med_processed)     AS mma_pat_n,
    (SELECT count(*)              FROM map_stacked)           AS map_n,
    (SELECT count(DISTINCT PATID) FROM map_stacked)           AS map_pat_n,
    (SELECT count(*)              FROM lot1_base)             AS lot1_n,
    (SELECT sum(CASE WHEN LOT1_TX_ENDDATE IS NOT NULL THEN 1 ELSE 0 END)
                                  FROM lot1_sct)              AS sct_n,
    (SELECT sum(CASE WHEN ENDDATE_CE < ENDDATE THEN 1 ELSE 0 END)
                                  FROM lot_patient_input)     AS cens_n,
    (SELECT count(*)              FROM lot_patient_input)     AS cens_total
")
# then: overview$cohort_n, overview$mma_n, ...
```

Spark can plan these subqueries independently and they avoid 8 serial
round-trips.

**(b) Reuse `run_metadata` / `qc_summary`.** If the counts are already persisted,
`SELECT * FROM run_metadata WHERE run_id = '{run_id}'` once, then index into
the result. This eliminates the scans entirely for the overview and QC tabs.

**(c) Group scans of the same table.** For `map_stacked`, the per-patient MAP
counts, MAP length percentiles, MAP type breakdowns, and MAP start/end
statistics can all be computed in one aggregation:

```r
map_stats <- db_q(con, "
  SELECT count(*) AS n_maps,
         count(DISTINCT PATID) AS n_pats,
         percentile_approx(datediff(MAP_END_DT, MAP_START_DT) + 1, 0.5)  AS med_len,
         percentile_approx(datediff(MAP_END_DT, MAP_START_DT) + 1, 0.95) AS p95_len,
         sum(CASE WHEN MAP_END_DT < MAP_START_DT THEN 1 ELSE 0 END) AS n_bad
  FROM map_stacked
")
```

One scan, one round-trip, one result.

**(d) Cache via a temp view on the R side.** For sections that reuse the same
filter (e.g., `lot1_sct WHERE LOT1_TX_ENDDATE IS NOT NULL`), materialize once
into a temp view at the start of the section and let subsequent queries read
from it.

---

## Priority & effort

| # | Fix                                                                                | Effort  | Expected impact                                        |
|---|-------------------------------------------------------------------------------------|---------|--------------------------------------------------------|
| 1 | Add `cfg$run_step_qc` flag; default `FALSE` in prod                                 | ~15 min | Removes 42 scans per pipeline run                      |
| 2 | Collapse overview + QC tabs in `descriptives_lot.R:30-187` into 2 batched queries   | ~1 hr   | Eliminates 16 round-trips; fastest report startup       |
| 3 | Point report's overview/QC tabs at persisted `run_metadata`/`qc_summary` tables     | ~1-2 hr | Zero scans for overview; report becomes near-instant    |
| 4 | Group per-section scans of `map_stacked`/`lot1_sct`/`lot1_base_end`                 | ~2-3 hr | Cuts report's dominant I/O roughly in half              |

None of these change the analysis output — they only change how often the
warehouse is touched.

---

## What's already good

- SQL-first design: heavy work lives in Spark, not R loops.
- Reconnect-on-stale logic in `run_step()` (db_utils.R:200-208) is sensible.
- `run_metadata` / `qc_summary` tables are already persisted — the scaffolding
  for fix #3 exists; it just isn't used by the report layer.
- Retry with exponential backoff in `with_retry()` is well-scoped.

The optimization story here is not about rewriting R — it's about **touching the
warehouse fewer times**.
