# Apr 30 Program — Coding Difficulties Caused by the Data Infrastructure

This note collects the coding difficulties on the Apr 30 LOT (Line-of-Therapy)
programs that were driven **by the underlying data infrastructure** —
Databricks/Delta + the Optum CDM, accessed over ODBC from R running on Domino —
rather than by the analytic logic itself. Each item lists the symptom, the
infrastructure cause, and the workaround that had to be written into the code.
File references point at the surviving workarounds so each point is verifiable.

---

## 1. Delta concurrency (OCC) failures on long table writes

**Symptom.** A `CREATE OR REPLACE TABLE` over a large Delta source would fail
partway through with `DELTA_METADATA_CHANGED` / `MetadataChangedException` /
`CONCURRENT_*` (ConcurrentAppend, ConcurrentModification, "could not be
committed").

**Cause.** The heavy `SELECT` behind the replace takes many minutes. During
that long write window, any concurrent metadata touch on the target table —
another run, Delta auto-optimize, an overlapping session — trips Delta's
optimistic-concurrency check and aborts the commit. This is purely a property
of writing in place to a live Delta table; nothing in the analytics changes it.

**Workaround.** `materialize_to_personal_schema()` had to be rewritten into a
**staging + atomic-publish** pattern: write the heavy `SELECT` into a
brand-new staging table (no existing metadata → minimal OCC surface during the
long scan), then do a fast `CREATE OR REPLACE` from that materialized staging
table to publish the final name in seconds. On top of that, transient Delta
errors are retried with exponential backoff (15s/30s/60s, `MATERIALIZE_RETRIES`),
while permanent errors fail fast.
→ `R/db_utils.R:166-278`, `README_lot2_5.md:86-99`

---

## 2. Schema divergence between Domino and the project (cascading `TABLE_OR_VIEW_NOT_FOUND`)

**Symptom.** A stage would exit 0, but a later stage died with
`TABLE_OR_VIEW_NOT_FOUND` two steps downstream — a cryptic failure far from its
real cause.

**Cause.** The write schema is resolved through an environment-dependent
fallback chain (`PROJECT_WORK_SCHEMA` → `DOMINO_USER_NAME` → hardcoded default),
and Domino injects its own user schema. When cohort attrition persisted to one
schema and LOT read from another, nothing failed at write time — it only
surfaced as a missing table later. The same fallback logic is duplicated across
`config_lot.R`, `config_prompts.R`, and the orchestrator, and all three must be
kept in lockstep or skip-detection silently corrupts.

**Workaround.** The orchestrator (`run_pipeline.R`) had to gain explicit
**pre-flight input probes** — before each stage it checks every required input
table is visible at the schema that stage will actually read from — plus
**post-stage output verification** that the primary output table really landed,
halting with `stop()` on a silent persistence failure instead of cascading.
Comments there explicitly warn that every default "MUST match the corresponding
fallback in config_lot.R / config_prompts.R."
→ `R/config_lot.R:19-20`, `run_pipeline.R:119-138,228,293,364-365`,
`README_lot2_5.md:110-136`

---

## 3. Spark driver/executor filesystem split (code lists couldn't be read directly)

**Symptom.** Code-list CSVs sit on the Domino filesystem (`/mnt/code/codelist/`)
and R can read them fine, but you cannot simply point Spark SQL at them.

**Cause.** R runs on the driver and can see the driver-local filesystem; Spark
executors cannot. A file that is trivially readable from R is invisible to the
warehouse that has to join against it.

**Workaround.** Every code list has to be read in R and then pushed into Spark
as a temporary view built from a generated SQL `VALUES` clause (with escaping,
NULL handling, and an empty-frame special case). That is a whole loader
(`load_csv_codelists()`) that exists only to bridge the driver/executor gap.
→ `R/db_utils.R:80-137`

---

## 4. ODBC BIGINT → R numeric silently corrupts patient IDs

**Symptom.** Patient IDs (`PATID`) came back wrong — large IDs lost precision;
small IDs came back as subnormal floats (~1e-313) after byte
misinterpretation.

**Cause.** `PATID` is stored as BIGINT in the CDM. Some ODBC drivers hand
BIGINT back to R as a double, which cannot hold the full integer range — a
pure driver/type-mapping issue, invisible until IDs silently mismatch on join.

**Workaround.** Every place `PATID` is `SELECT`ed it has to be `CAST … AS STRING`
at the warehouse to force the driver to keep it honest, rather than trusting the
default type mapping.
→ `R/descriptives_lot.R:1055-1075`

---

## 5. Quarterly-vintaged CDM tables + Excel-mangled dates

**Symptom.** CDM tables are not stable names — they are versioned per quarter
(`t_<table>_YYYYqQ`), so the code must compute which vintage to read from a
study-end date. And that date, when edited in `pipeline_inputs.csv` via Excel,
kept getting reformatted (e.g. `30-06-2025`) into something R's `as.Date`
misparsed as year 0030.

**Cause.** The Optum CDM ships quarterly-suffixed tables, and the config is
plumbed through a CSV that non-engineers open in Excel, which silently rewrites
date formatting.

**Workaround.** `get_quarter_suffix()` / `cdm_src()` resolve the quarterly
table name from the date, and the date parser had to be hardened to try
multiple non-ISO layouts and reject implausible years with an actionable error
message telling the user to re-enter the date as `YYYY-MM-DD`.
→ `R/db_utils_lot.R:51-81`, `R/codelists.R`

---

## 6. Silent data-quality failures in claim matching

**Symptom.** Whole medications or claim matches could vanish with no error —
e.g. NDC codes in the code list not overlapping NDC lengths in the RX table, a
code-list drug absent from the rollup, or a steroid scan returning zero.

**Cause.** The CDM's coding (NDC padding/length, med rollups) does not always
line up with the curated code lists, and a mismatched join just returns fewer
rows — a data-shape problem that never raises an exception.

**Workaround.** Defensive QC probes had to be written throughout to turn these
silent gaps into visible warnings: reverse code-list/rollup checks ("silent drop
of an entire medication"), NDC-length overlap checks ("silent misses in pharmacy
claim matching"), and zero-result guards.
→ `02_lot1.R:150-165,1690-1705`, `VALIDATION_QS_JUN29.md:59`

---

## 7. Connection staleness on long warehouse queries

**Symptom.** Long-running steps would fail because the ODBC connection had gone
stale mid-pipeline.

**Cause.** Warehouse connections drop over the multi-minute queries this
pipeline runs; the driver does not transparently recover.

**Workaround.** Every step runner has to `db_ping()` before executing and
transparently **reconnect with retry** if the connection is dead, so a dropped
connection doesn't kill a long run.
→ `R/db_utils.R:295-339`

---

## 8. Retryable-vs-permanent error classification (wasted backoff)

**Symptom.** Retry backoff was being burned on errors that could never succeed
— e.g. a missing-table probe ate ~35s of retry sleep before giving up.

**Cause.** The ODBC driver surfaces the *same* underlying error in different
textual forms depending on the path (Spark class names like
`TABLE_OR_VIEW_NOT_FOUND` vs. user-facing "Table or view not found", underscore
vs. space forms). Without knowing which errors are permanent, generic retry
logic waits on hopeless calls.

**Workaround.** A hand-maintained list of permanent-error patterns (in both
underscore and spaced forms) had to be built so `with_retry()` fails fast on
permanent errors and only backs off on genuinely transient ones. The comment
records that the spaced forms were added specifically after observing the wasted
35s.
→ `R/db_utils_lot.R:83-116`

---

## 9. Unreliable enrollment/business tables

**Symptom.** The Medicare-vs-Commercial payer split sometimes could not be
built because `member_enrollment.BUS` was unreadable.

**Cause.** Not every CDM table/column is dependably available across
environments and vintages.

**Workaround.** The section had to be made **fail-safe** — probe the table
first and degrade to an explanatory note instead of erroring out the whole
dashboard when the infrastructure can't serve the field.
→ `05_regimen_dashboard.R:565-585`

---

## 10. No native atomic builds → partial-build corruption

**Symptom.** A mid-loop failure could leave the main output (`LOT_LONG`)
containing only `LOT_NUM = 1` from a half-finished run — a silently wrong table
that looks complete.

**Cause.** The warehouse does not give you an atomic multi-step build; a loop
that appends per-LOT can be interrupted and leave a partial table under the
final name.

**Workaround.** The LOT2-5 build was made **atomic**: every LOT writes to a
`LOT_LONG_STAGE` table and is promoted to `LOT_LONG` only after all LOTs append
successfully, so `LOT_LONG` is never a half-finished build. The dashboard also
flags the degenerate case if it ever recurs.
→ `README_lot2_5.md:69-76,228-236`, `run_pipeline.R:364-365`

---

## Summary

Across the Apr 30 programs, a large share of the engineering effort went not
into the LOT/regimen analytics but into **defending against the data
infrastructure**: Delta optimistic-concurrency failures, environment-dependent
schema resolution on Domino, the Spark driver/executor filesystem split, ODBC
type-mapping that corrupts BIGINT IDs, quarterly-vintaged CDM tables, connection
staleness, driver-inconsistent error text, and the absence of atomic
multi-step writes. Each required bespoke workaround code — staging/atomic
publishes, retry/backoff with error classification, pre-flight and post-stage
table probes, CSV-to-temp-view loaders, string-casting of IDs, reconnection
logic, and defensive QC — that would be unnecessary against a more forgiving
data platform.
