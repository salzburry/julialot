# LOT Pipeline — Optimization Review (reporting & observability)

**Scope:** active LOT flow only
- `Apr 18 2026/Program/lot_program.R`
- `Apr 18 2026/Program/R/db_utils_lot.R`
- `Apr 18 2026/Program/R/descriptives_lot.R`

The modular attrition pipeline (`main.R`, `R/db_utils.R`, `R/pipeline_steps.R`) is
a **separate codepath** and is out of scope for this review. A few repo-wide
counts are called out explicitly where useful, but the findings and fixes below
target the LOT flow.

---

## TL;DR

The LOT pipeline is well-architected: heavy work runs in Spark/Databricks and
R-side logic avoids quadratic loops on large data. The avoidable runtime cost is
dominated by **repeated warehouse scans for observability**, not R-side
inefficiency.

Two findings account for most of that cost:

1. **Per-step QC runs unconditionally in `run_step()`** (`db_utils_lot.R:78`),
   forcing an extra scan of the just-materialized view after ~21 LOT steps.
2. **`descriptives_lot.R` issues ~50 singleton aggregate queries** and rescans
   the same large LOT tables (`map_stacked`, `lot1_sct`, `lot1_base_end`,
   `mma_med_processed`) many times across sections — even though
   `run_metadata` and `qc_summary` are already persisted upstream in
   `lot_program.R`.

Both are reporting/observability layer issues, not correctness problems. Fixes
are non-invasive.

---

## Finding 1 — Per-step QC adds an extra warehouse pass to many LOT steps

### Evidence

The LOT step runner always executes the QC query immediately after the main SQL:

```r
# Apr 18 2026/Program/R/db_utils_lot.R:78-94
run_step <- function(con, name, sql, qc = NULL) {
  ...
  db_exec(con, sql)
  ...
  if (!is.null(qc) && nzchar(qc)) {
    t1 <- proc.time()
    out <- db_q(con, qc)
    qc_elapsed <- (proc.time() - t1)[["elapsed"]]
    log_msg("  QC completed in ", round(qc_elapsed, 1), "s")
    print(out)
  }
}
```

There is no flag to skip QC. Every non-null `qc =` attached to a step runs,
regardless of environment.

**LOT-only count:** `lot_program.R` attaches `qc =` to **21 steps**.
*(For context, the separate modular attrition pipeline adds another 21 in
`pipeline_steps.R` — not in scope here.)*

Several LOT QC checks are non-trivial scans of the view just written — examples:

```r
# lot_program.R:682   (after S07_map_stacked)
qc = "SELECT count(*) AS n_rows FROM map_stacked"

# lot_program.R:695   (after S08_lot1_start)
qc = "SELECT count(*) AS n_patients_with_lot1,
             min(LOT1_START_DT) AS min_lot1_start,
             max(LOT1_START_DT) AS max_lot1_start
      FROM lot1_start"

# lot_program.R:1375  (materialization loop)
qc = glue("SELECT count(*) AS n_rows FROM {wrk(mv$name)}")

# lot_program.R:2167  (persistence loop)
qc = glue("SELECT count(*) AS n_rows FROM {wrk(pt$name)}")
```

Each is effectively a second pass over data Spark just wrote.

### Why it matters

- **Doubles touches** on each intermediate view that carries QC.
- **Serial round-trips**: every QC is a separate ODBC call with its own
  job-submission overhead.
- `count(*)` on a freshly written Delta/Parquet view is usually cheap; multi-
  aggregate / `count(DISTINCT PATID)` QCs are shuffle-heavy and scale with
  cohort size.

### Recommended fixes

Non-mutually-exclusive; pick by effort.

**(a) Config flag to disable per-step QC in prod.** Smallest change.

```r
# db_utils_lot.R — run_step()
if (isTRUE(cfg$run_step_qc) && !is.null(qc) && nzchar(qc)) { ... }
```

Default `cfg$run_step_qc = TRUE` in dev, `FALSE` in prod.

**(b) Batch QC at phase boundaries.** Collect step→qc pairs during a phase,
then issue one multi-CTE/UNION ALL query at the end. The codelist phase
(S00–S02) alone collapses 3 singleton counts into one call.

**(c) Rely on the already-persisted `qc_summary` table**
(`lot_program.R:2237-2245`) for dashboard/report consumption rather than
rechecking on every step run.

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

The QC tab (lines 112-187) repeats the pattern — 8 more singleton `db_q()`
calls for pass/fail checks.

In total, `descriptives_lot.R` contains **54 `db_q()` calls**, mostly small
singleton aggregates.

### Evidence: repeated full scans of the same LOT tables

| Table                | Scans in `descriptives_lot.R` | Example lines                                                |
|----------------------|------------------------------:|--------------------------------------------------------------|
| `map_stacked`        | ~17                           | 33, 34, 144, 151, 376, 398, 426, 457, 856, 882, 1046–1047, 1093, 1097, 1110, 1278, 1284, 1293 |
| `lot1_sct`           | ~11                           | 36, 173, 183, 794, 822, 864, 897, 1365, 1420, 1438, 1570     |
| `lot1_base_end`      | ~8                            | 540, 560, 584, 636, 643, 1318, 1324, 1333                    |
| `mma_med_processed`  | 5                             | 31, 32, 238, 256, 340                                        |
| `lot_patient_input`  | 3                             | 30, 41, 164                                                  |

Each scan is a separate Spark job reading the same Delta files and returning a
tiny result set.

### The already-persisted data isn't reused

The LOT pipeline already creates `run_metadata` and `qc_summary` tables:

```r
# lot_program.R:2178-2245
run_step(con, "S22a_create_metadata_table", ...)
run_step(con, "S22c_insert_run_metadata",   ...)
run_step(con, "S23a_create_qc_table",       ...)
run_step(con, "S23c_insert_qc_summary",     ...)
```

So the overview counts and QC metrics are computed once during persistence — but
`descriptives_lot.R:30-44` recomputes them from source tables instead of
reading `run_metadata`.

### Why it matters

- **Round-trip latency**: on a remote warehouse, ~50 singleton ODBC calls in
  sequence often dominates report wall time even when each aggregate is fast.
- **Redundant I/O**: scanning `map_stacked` 17 times means 17× Delta read +
  Spark planning overhead.
- **No cache layer**: `db_q()` does not memoize; each call is a new job.

### Recommended fixes

**(a) Reuse `run_metadata` / `qc_summary`.** Strongest win and cleanest change:
since these tables are already built by the LOT pipeline, the overview and QC
tabs should read from them once instead of recomputing:

```r
meta <- db_q(con, glue("SELECT * FROM run_metadata WHERE run_id = '{run_id}'"))
qc   <- db_q(con, glue("SELECT * FROM qc_summary   WHERE run_id = '{run_id}'"))
# then: meta$cohort_n, meta$mma_n, ... ; qc rows drive the QC tab
```

This eliminates the 16 scans in `:30-187` entirely and produces identical
results.

**(b) Collapse singleton aggregates into one query per section.** If a metric
isn't in `run_metadata`, batch it:

```r
overview <- db_q(con, "
  SELECT
    (SELECT count(DISTINCT PATID) FROM lot_patient_input)     AS cohort_n,
    (SELECT count(*)              FROM mma_med_processed)     AS mma_n,
    (SELECT count(DISTINCT PATID) FROM mma_med_processed)     AS mma_pat_n,
    (SELECT count(*)              FROM map_stacked)           AS map_n,
    ...
")
```

One round-trip instead of eight.

**(c) Group per-table scans inside a section.** For `map_stacked`, the
per-patient MAP counts, length percentiles, type breakdowns, and validity
checks can combine into a single aggregation:

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

---

## Priority & effort (LOT flow only)

| # | Fix                                                                                          | Effort   | Expected impact                                      |
|---|----------------------------------------------------------------------------------------------|----------|------------------------------------------------------|
| 1 | Add `cfg$run_step_qc` flag in `db_utils_lot.R:78`; default `FALSE` in prod                   | ~15 min  | Removes 21 scans per LOT run                         |
| 2 | Point overview + QC tabs at persisted `run_metadata` / `qc_summary`                          | ~1–2 hr  | Near-zero scans for those tabs; big report speedup   |
| 3 | Collapse remaining singleton aggregates in `descriptives_lot.R` into per-section batches     | ~1 hr    | Cuts 8+ round-trips                                  |
| 4 | Group per-section scans of `map_stacked` / `lot1_sct` / `lot1_base_end`                      | ~2–3 hr  | Cuts report's dominant I/O roughly in half           |

None of these change report output — they only change how often the warehouse
is touched.

---

## What's already good

- SQL-first design: heavy work lives in Spark, not R loops.
- `run_metadata` / `qc_summary` are already persisted (`lot_program.R:2178-2245`)
  — scaffolding for fix #2 exists; it just isn't used by the report layer.
- `with_retry()` / `db_exec()` / `db_q()` wrappers in `db_utils_lot.R` are
  well-scoped with sensible backoff and permanent-error classification.

The optimization story here is not about rewriting R — it's about **touching the
warehouse fewer times**.
