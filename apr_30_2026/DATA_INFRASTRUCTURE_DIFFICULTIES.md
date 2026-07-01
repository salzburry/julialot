# Apr 30 Program — Coding Difficulties Caused by the Data Infrastructure (Slowness)

This note collects the difficulties on the Apr 30 LOT (Line-of-Therapy)
programs where the **data infrastructure caused slowness** — both slow
*pipeline runtime* and slow *development iteration*. The stack is
Databricks/Delta SQL warehouse + the Optum CDM, reached over ODBC from R on
Domino. Each item lists the symptom, the infrastructure cause, and the
workaround the code had to carry to claw the time back. File references point
at the surviving code so each point is verifiable.

---

## Part A — Slow pipeline runtime

### A1. No `CACHE TABLE` on the SQL warehouse → the same heavy view is recomputed on every read

**Symptom.** The intermediate views (`map_stacked`, `lot1_sct`, `lot1_base`,
the steroid-augmented `lot_long_aug`) are `TEMPORARY VIEW`s sitting on top of
deep CTE chains that reach all the way back to the CDM. Every downstream query
that touches one re-evaluates the *entire* chain from scratch — and they are
read many times: `map_stacked` **~17×**, `lot1_sct` **~11×**, `lot1_base`
several times, the steroid view **~7×** per cohort.

**Cause.** On a Databricks SQL warehouse `CACHE TABLE` is **not supported**, so
there is no cheap way to pin a computed result in memory. A bare temp view is
re-run in full on each reference.

**Workaround.** The heavy views had to be **materialized to physical
work-schema Delta tables once and the view repointed** at the table, so
downstream reads hit a stored table instead of re-evaluating the CTE chain.
This "materialize-and-repoint" pattern had to be hand-rolled in three separate
places because the platform gives no caching primitive.
→ `02_lot1.R:1356-1372`, `05_regimen_dashboard.R:321-344,710-712,900-928`,
`R/db_utils.R:280-283`

### A2. Giant CDM claims tables — every unrestricted scan is very slow

**Symptom.** Re-scanning the full `rx` and `medical` claims tables (e.g. for
DEXA/steroid codes) was "very slow."

**Cause.** The Optum claims tables are enormous; an unfiltered scan pays for the
whole table every time.

**Workaround.** Scans had to be **cohort-restricted up front** (limited to the
cohort's `PATID`s + the relevant date window) and the result materialized once,
so the expensive claims scan touches only the patients the outputs actually
need instead of the full table on each read.
→ `02_lot1.R:1680`, `05_regimen_dashboard.R:900-928,710-712`

### A3. Multi-minute Delta writes + retry backoff add dead time

**Symptom.** A single `CREATE OR REPLACE TABLE` over a large source runs for
**many minutes**, and when it hit a transient Delta concurrency error the run
then *slept* through exponential backoff (15s → 30s → 60s) before retrying.

**Cause.** Delta commits on large writes are slow, and the platform's
optimistic-concurrency aborts on long writes force a retry-with-wait strategy —
both are pure runtime cost.

**Workaround.** The write was split into a fast staging-table build + a
seconds-long atomic publish to shrink the slow window, and QC was **deferred
until after materialization** so the check scans the cheap persisted table
rather than recomputing the heavy view a second time.
→ `R/db_utils.R:166-278,280-283`

### A4. Connection staleness on long queries → reconnect overhead

**Symptom.** Long-running steps intermittently lost the ODBC connection
mid-pipeline.

**Cause.** Warehouse connections drop across the multi-minute queries this
pipeline runs; the driver doesn't transparently recover.

**Workaround.** Every step has to `db_ping()` and **reconnect with backoff**
before running — necessary, but it adds latency and makes long runs slower and
less predictable.
→ `R/db_utils.R:295-339`

---

## Part B — Slow development iteration

### B1. The warehouse is the *only* feedback loop — no fast/local/sample path

**Symptom.** There is no way to test a change quickly. Every iteration runs
against the live Databricks warehouse over ODBC; there is no local or sampled
dataset to develop against.

**Cause.** All data lives in the CDM on Databricks and is only reachable
through the warehouse. A one-line logic change can only be validated by a full
warehouse round-trip.

**Impact.** Turnaround on any change is gated by warehouse runtime (see Part A),
not by how small the code edit was.

### B2. Testing one LOT-logic change means rebuilding `LOT_LONG` — a full heavy re-run

**Symptom.** To see the effect of a change in the LOT2-5 derivation you must
rebuild `LOT_LONG` end-to-end (`FORCE_RERUN=TRUE`), which re-runs the entire
per-LOT loop over the heavy inputs.

**Cause.** The output is an atomic staged build (staging table → swap on full
success), and the inputs are the heavy materialized views — there is no partial
or incremental rebuild, so any change re-pays the full build cost.

**Workaround / cost.** The documented rebuild command exists precisely because
this is a heavyweight operation, and the atomic build is kept specifically so a
long rebuild doesn't destroy the previous good table if it fails mid-loop — i.e.
the slowness is a known constraint the tooling is designed around.
→ `README_lot2_5.md:63-76,228-236`

### B3. A whole checkpoint / skip-detection layer had to be built just to avoid recomputing on every run

**Symptom.** Without intervention, each run would recompute every heavy stage
from scratch — unworkable for iteration.

**Cause.** The warehouse has no memoization of prior work across runs; a fresh
`Rscript` invocation starts cold.

**Workaround.** A **checkpoint/materialize + skip-detection** layer had to be
written: stages persist their outputs, the orchestrator probes whether an
output already exists and **skips** stages whose tables are present, and QC runs
against the cheap persisted table instead of recomputing the heavy view. The
existence of this machinery is itself the evidence — it only exists because
re-running from cold is too slow to iterate on.
→ `01_cohort.R:118-140`, `run_pipeline.R:340-375`, `R/db_utils.R:280-283`

### B4. Multi-stage subprocess pipeline — downstream work needs upstream tables materialized first

**Symptom.** Each stage runs as its own `Rscript` subprocess and reads the
previous stage's **persisted** tables, so you cannot iterate on a late stage
(LOT2-5, dashboards) without the upstream tables already built and present in
the right schema.

**Cause.** State is passed between stages only through persisted warehouse
tables (there is no shared in-memory session across stages), so every
downstream experiment is gated on a prior heavy build existing.

**Impact.** Iterating on the tail of the pipeline still requires paying (or
having previously paid) for the head of it — again the warehouse runtime, not
the code change, sets the pace.
→ `run_pipeline.R:340-375`, `README_lot2_5.md:110-136`

---

## Summary

The slowness on the Apr 30 programs was driven by the data platform, in two
compounding ways:

- **Runtime:** the SQL warehouse offers **no `CACHE TABLE`**, so deeply-nested
  views over the huge Optum CDM were recomputed on every read (up to ~17× for
  one view); large Delta writes run for minutes and force retry-with-backoff
  waits; and connection drops add reconnect latency. Substantial workaround code
  (materialize-and-repoint, cohort-restricted scans, staging/atomic publishes,
  deferred QC) exists only to reduce this cost.
- **Development:** the warehouse is the **only** feedback loop — no local or
  sampled data — so every change is validated by a full round-trip; testing a
  LOT-logic change means an end-to-end `LOT_LONG` rebuild; and a whole
  checkpoint/skip-detection layer had to be built just to avoid recomputing
  finished stages on each iteration.

Net effect: iteration speed and pipeline runtime were both set by warehouse
latency over the CDM rather than by the size of the code change, and a large
share of the engineering went into caching/checkpointing workarounds to claw
that time back.

*(Separately, the infrastructure also forced a set of **correctness/robustness**
workarounds — Delta OCC, schema divergence, the Spark driver/executor
filesystem split, ODBC BIGINT ID corruption, etc. Those are tracked as a
distinct class of difficulty and are not repeated here since they are not
primarily about slowness.)*
