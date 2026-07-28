# Review findings — validated 2026-07-28

**Verdict accepted in full. All six findings reproduce. This folder is NOT
validated and NOT production-ready.** No fixes applied yet — this document
records the validation only.

The single most useful sentence in the review: *the LOT source files being
byte-identical is valid evidence the LOT algorithms were not edited; it does not
establish equivalent results under the changed cohort/input contract.* That is
exactly the gap between what my suite tested and what "validated" means.

---

## Root cause of most of this

Two structural mistakes, each producing several findings:

1. **The engine never loads `pipeline_inputs.csv`.** `load_cfg()`
   (`engine/cohort_run.R:51`) reads env vars only. The legacy stack applies the
   committed CSV via `load_pipeline_inputs()` before any config is read. So the
   engine cannot see the project's actual configuration — not the 90-day window,
   not the four disabled exclusions. My files *mention* the CSV in comments and
   never load it.

2. **Every test validates generated TEXT; none validates an execution path.**
   149 assertions, all on strings. Findings 2–5 are all runtime behaviour, and
   the suite is structurally incapable of catching them. I only ever ran
   `--dry-run`, which returns (`cohort_run.R:175`) before the connection is
   opened at `:186` — so the `--index-only` blocker could never have surfaced.

---

## Findings

### 1. [P0] The configured cohort is not what I built — confirmed, and worse

`build_criteria_sql()` (`criteria_attrition.R:94`) includes a criterion only
`if (isTRUE(cfg[[cr$cfg_key]]))`. My equivalence test extracted `filter_sql`
from all 9 catalog entries and **ignored `cfg_key` entirely**. Its green result
compared my spec to a configuration nothing uses.

Committed config (`pipeline_inputs.csv`):

| Setting | Legacy | `Jul 28` |
|---|---:|---:|
| `OUTPATIENT_WINDOW` | **90** | 60 |
| `APPLY_BASELINE_MM_EXCL` | **FALSE** | applied |
| `APPLY_OTHER_MALIG_EXCL` | **FALSE** | applied |
| `APPLY_PREGNANCY_EXCL` | **FALSE** | applied |
| `APPLY_CLINTRIAL_EXCL` | **FALSE** | applied |

So the configured Overall is a **6-gate Step-6 cohort**, not my 10-gate one.

The review understates the consequence. The CSV explains the design and warns
about exactly this:

> `APPLY_OTHER_MALIG_EXCL` ships FALSE by design for the NDMM workflow: the
> parent leaves other-malig OFF so `06_ndmm_dashboard.R` can re-apply it with the
> MM-adjacent override (keeps MGUS / solitary + extramedullary plasmacytoma /
> plasma-cell leukemia / secondary bone). **TRUE drops those patients upstream
> and breaks the NDMM cohort.**

My `ndmm/cohort.R` applies `no_other_cancer_index` unconditionally — i.e. the
configuration the project documents as breaking NDMM. It also **defeats the
MM-adjacent override entirely**: those patients are dropped upstream before the
override can keep them. That is the same override whose labels I got wrong last
turn; I fixed the list while leaving in place a gate that makes it irrelevant.

### 2. [P0] The documented NDMM bootstrap cannot run — confirmed, four blockers

- **Schema guard.** `assert_source_cols(con, specs, cfg)` (`cohort_run.R:189`)
  runs against the full `specs`, after the `--index-only` truncation at `:164`.
  A clean bootstrap needs `LOT1_FLAGS_ALL` before the stage meant to create it.
- **Temp view across processes.** `coh_index_union` is `CREATE OR REPLACE
  TEMPORARY VIEW` and the runner disconnects on exit. A separately launched LOT
  process cannot see it. My documented 5-step run order cannot work.
- **Qualified temp-view name.** `sql_obj()` prepends the work schema, emitting
  `CREATE OR REPLACE TEMPORARY VIEW wk.coh_index_union` — invalid on Databricks
  (temp views are session-scoped and must not be schema-qualified). The legacy
  pipeline gets this right: `db_utils.R:60` is `work <- function(tbl) tbl`,
  returning the **unqualified** name. I diverged from the working pattern.
- **`COHORT_CONNECT_FN=my_connect`** in the README defines nothing; `connect()`
  only looks up an existing function. The documented command cannot run.

### 3. [P1] Multi-index support is not implemented — confirmed

`build_lot1_starts()` (`lot1_flags.R:147`) joins `LOT_LONG` to the patient input
**on `PATID` alone**. Unchanged LOT code aggregates by `PATID` too
(`02_lot1.R:306`, `:677`). Two selected index dates for one patient therefore
fan out or conflate LOT histories.

This directly contradicts the pair-keying I claimed. Identical index gates mask
it today. The review's recommendation is right: **reject divergence until LOT
carries `INDEX_DATE` throughout**, rather than advertise support that does not
exist.

### 4. [P1] Failed persistence is swallowed — confirmed

`.materialize_and_repoint()` (`lot1_flags.R:643`) catches and returns `FALSE`;
`build_lot1_flags.R:104` ignores the return. A failed write leaves an older
physical table in place, which the summary reads and reports as this run's
output. Fail-soft is defensible for a same-session dashboard; not for a durable
cohort-production stage. Same for unreadable exclusion sources becoming all-pass
`NO_* = 1` with no persisted record that the criterion was skipped.

### 5. [P1] The persisted rename breaks consumers — confirmed

The `NDMM_* -> LOT1_*` aliases in the dashboard are R variables only. Real
warehouse readers of the old table name exist:
`poma_studyteam_qs.R:535` (`wrk("NDMM_FLAGS_ALL")`) and
`cohort_explorer/warehouse/08_analytic_cohort.R:86`. Old table present → they
read stale data; absent → they fail. A compatibility view is required.

### 6. [P2] Attrition claims are inaccurate — confirmed

- **Funnel order differs.** Dashboard: `CE_pre_lot1 → NO_BELANTAMAB →
  NO_PRIOR_MM_TX → NO_OTHER_CANCER → CE_lot1_3mo_fu → NO_PREGNANCY`. Mine puts
  `ce_fu_lot1_3mo` fourth. Same final AND-set, different intermediate counts.
- **`setequal()`** in the equivalence test cannot detect that by construction.
- **`has_lot1` / `lot1_from` cannot produce separate drops.** The cutoff is baked
  into `build_lot1_starts()`'s `WHERE` (`lot1_flags.R:157`), so pre-cutoff starts
  are gone before either gate is evaluated: `has_lot1` absorbs both losses and
  `lot1_from` is a no-op. **I told the user the split "gives two numbers instead
  of one". That was wrong** — the second-guessed claim about `has_lot1`, twice
  over now.
- **The lifted-SQL comparator compares token SETS**, discarding order and
  multiplicity — too permissive to prove semantic equivalence.

---

## Corrected sequence (proposed, not yet done)

Ordered so nothing is built on an unvalidated base:

1. **Load the real configuration.** Call `load_pipeline_inputs()` in the engine,
   and make gates *configurable*, not unconditional: each gate needs its
   `cfg_key`, so the spec expresses "the configured cohort", not "all criteria".
   Restore the 90-day default. Re-derive the equivalence test from
   `build_criteria_sql()` — the function that actually decides — rather than from
   `build_criteria_catalog()`.
2. **Fix the execution path**: `--index-only` preflight scoped to the truncated
   plan; unqualified temp-view names; persist the union as a real table (or run
   dependent stages on one connection); a runnable connection example.
3. **Enforce one index per PATID** until LOT is genuinely pair-keyed; fail on
   divergence rather than silently fanning out.
4. **Fail closed** on failed persistence and on missing criterion inputs; persist
   run metadata recording any skipped criterion.
5. **Compatibility view** for `NDMM_FLAGS_ALL`.
6. **Replace the static comparator** with configured SQL snapshots plus
   warehouse `EXCEPT` checks in both directions — the only thing that will
   actually establish equivalence.

Until step 1 lands, the green suite should not be cited as evidence of anything.
`tests/test_equivalence.R` carries a banner saying so.
