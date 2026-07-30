# Review findings — validated 2026-07-28

**Verdict accepted in full. All six findings reproduced.**

**Status: all six findings are addressed in code (steps 1–6 of the corrected
sequence).**

**This folder is still NOT VALIDATED.** Step 6 fixed the comparators *and*
wrote the check that can settle equivalence — but that check has never run.
Until `tests/verify_against_legacy.R` comes back empty in both directions on the
warehouse, there is no evidence about patients, only about SQL text. Do not
treat a green `run_all_tests.R` as validation; it cannot be.

The single most useful sentence in the review: *the LOT source files being
byte-identical is valid evidence the LOT algorithms were not edited; it does not
establish equivalent results under the changed cohort/input contract.* That is
exactly the gap between what my suite tested and what "validated" means.

---

## Root cause of most of this

Two structural mistakes, each producing several findings:

1. **The engine never loads `pipeline_inputs.csv`.** ~~`load_cfg()`
   (`engine/cohort_run.R:51`) reads env vars only.~~ **FIXED — see finding 1.**
   Originally: `load_cfg()` read env vars only. The legacy stack applies the
   committed CSV via `load_pipeline_inputs()` before any config is read. So the
   engine cannot see the project's actual configuration — not the 90-day window,
   not the four disabled exclusions. My files *mention* the CSV in comments and
   never load it.

2. **Every test validates generated TEXT; none validates an execution path.**
   149 assertions, all on strings. Findings 2–5 are all runtime behaviour, and
   the suite was structurally incapable of catching them. I only ever ran
   `--dry-run`, which returns before the connection is opened — so the
   `--index-only` blocker could never have surfaced.

   **Partly addressed in step 2:** the preflight-scoping decision was extracted
   into a pure `sources_to_check()` so it *is* testable without a warehouse, and
   the temp-view qualification rule is now asserted over every `CREATE` in a
   full plan. The deeper point stands: these are still text assertions, and only
   a real run settles the row counts.

---

## Findings

### 1. [P0] The configured cohort is not what I built — ~~confirmed~~ **FIXED**

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

My `ndmm/cohort.R` applied `no_other_cancer_index` unconditionally — i.e. the
configuration the project documents as breaking NDMM. It also **defeated the
MM-adjacent override entirely**: those patients were dropped upstream before the
override could keep them. That is the same override whose labels I got wrong the
turn before; I fixed the list while leaving in place a gate that made it
irrelevant.

#### Fix (step 1)

- **`load_cfg()` calls `load_pipeline_inputs()`** before reading anything, so the
  engine sees the committed configuration. `OUTPATIENT_WINDOW` now defaults to
  **90**, matching `config_prompts.R:99` — the old 60 was wrong independently of
  the CSV.
- **Every gate carries its production `cfg_key`**, and `resolve_spec()` marks it
  active with `isTRUE(cfg[[cfg_key]])` — the same test `build_criteria_sql()`
  uses, `isTRUE()` included, so an absent toggle is OFF in both.
- **A disabled criterion stays declared and stays a PLD column.** It is simply
  not AND-ed into membership, not numbered in the funnel, and not demanded by the
  schema guard. Turning a criterion off changes the selection, not the data —
  which is the point of the flag design.
- **Overall is now the 6-gate Step-6 cohort at 90 days.** NDMM leaves the
  index-anchored other-cancer / pregnancy criteria off and applies the
  LOT1-anchored ones, so the MM-adjacent override is no longer pre-empted —
  exactly the design `pipeline_inputs.csv` documents. There is a test asserting
  the generated NDMM SQL never contains `OTHER_MALIGN_FLAG`.
- **`tests/test_equivalence.R` section 2 now CALLS** `build_criteria_catalog()`
  and `build_criteria_sql()` with the real config and compares clause-for-clause
  in order (pipeline 6, spec 6). The old version parsed the catalog and ignored
  `cfg_key`.
- **`tests/harness.R` builds `CFG` from `load_cfg()`** instead of hand-writing
  one. The hand-written CFG — 60-day window, no toggles at all, so every toggled
  criterion read as ON — is *how* the suites came to validate a configuration
  nobody runs. One source of truth now.

### 2. [P0] The documented NDMM bootstrap cannot run — ~~confirmed~~ **FIXED**

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

#### Fix (step 2)

- **Preflight is scoped to the steps about to run.** `sources_to_check()` (pure,
  therefore tested) keeps a source only if some step in the — possibly truncated
  — plan actually references its table. `--index-only` no longer demands
  `LOT1_FLAGS_ALL`, the table the *next* stage creates.
- **The union is a persisted table.** `coh_index_union` and the per-cohort
  `coh_<id>_index_sel` are `CREATE OR REPLACE TABLE`, so they outlive the
  connection that made them and a separately launched LOT build can read them.
  `INPUT_COHORT_TABLE` is handed the **unqualified** name, because
  `02_lot1.R:278` qualifies it itself via `wrk()`.
- **Temp views are never schema-qualified.** Split into `sql_view()` (bare) and
  `sql_table()` (catalog.schema-qualified) — the distinction the legacy code
  already draws between `db_utils.R:60` `work <- function(tbl) tbl` and
  `db_utils_lot.R:49` `wrk()`. A test walks every `CREATE` in a full plan and
  asserts no temp view carries a dot and every table does.
- **The default connection works.** `connect()` now uses `DATABRICKS_DSN` +
  `DATABRICKS_PWD` exactly as `02_lot1.R:63` does, so a real run needs only the
  password. `COHORT_CONNECT_FN` remains an override and reports a clear error
  when it names a function that is not defined, instead of being masked by a
  generic "DBI is required".
- **Index tables are reused, not silently rebuilt.** The final run consumes the
  same rows the LOT build did rather than re-deriving the cohort from whatever
  `ELIG_COH_ALLFLAGS` looks like now; `--rebuild-index` forces recomputation,
  and a partially-present set is a hard error rather than a mixed-vintage run.

### 3. [P1] Multi-index support is not implemented — ~~confirmed~~ **FIXED (by rejecting it)**

`build_lot1_starts()` (`lot1_flags.R:147`) joins `LOT_LONG` to the patient input
**on `PATID` alone**. Unchanged LOT code aggregates by `PATID` too
(`02_lot1.R:306`, `:677`). Two selected index dates for one patient therefore
fan out or conflate LOT histories.

This directly contradicts the pair-keying I claimed. Identical index gates mask
it today. The review's recommendation is right: **reject divergence until LOT
carries `INDEX_DATE` throughout**, rather than advertise support that does not
exist.

#### Fix (step 3)

Checked first, and it settles the design: **`LOT_LONG` carries no `INDEX_DATE`
at all** — `lot2_5_base.R` has zero references to it, and its grain is
`(PATID, LOT_NUM)`. A pair key is therefore *impossible* downstream without
rewriting the LOT build. Divergence is rejected, not supported:

- **A check runs immediately after the union is built** and aborts the run if
  any patient holds more than one index date, naming the count and saying what
  to do (build the cohorts in separate runs, or align their index gates). It is
  a query rather than a plan-time inference because differing gates only *might*
  diverge — two cohorts can declare different criteria and still pick the same
  index for every patient. The data decides.
- **The standalone flag stage verifies it too.** `coh_index_union` enforces the
  invariant, but `LOT1_PATIENT_INPUT` can be pointed at any table, so
  `build_lot1_flags.R` checks for duplicate PATIDs before building anything.
- **The overclaim is gone.** `PLAN.md` §3 said the union "grows and the numbers
  stay right" when cohorts diverge. That was wrong and is now corrected in
  place, along with the grain claims in `README.md` (`PATID × INDEX_DATE`
  became one row per PATID) and the header of `lot1_flags.R`, which now states the
  invariant `build_lot1_starts()` depends on rather than implying it handles
  pairs.

`INDEX_DATE` is still carried on every object — it is the anchor the LOT1 gates
measure from — but `PATID` is the key, and that is now enforced rather than
assumed.

### 4. [P1] Failed persistence is swallowed — ~~confirmed~~ **FIXED**

`.materialize_and_repoint()` (`lot1_flags.R:643`) catches and returns `FALSE`;
`build_lot1_flags.R:104` ignores the return. A failed write leaves an older
physical table in place, which the summary reads and reports as this run's
output. Fail-soft is defensible for a same-session dashboard; not for a durable
cohort-production stage. Same for unreadable exclusion sources becoming all-pass
`NO_* = 1` with no persisted record that the criterion was skipped.

#### Fix (step 4)

The fail-soft policy is kept where it is **correct** — the dashboard is a
same-session reader, its temp views remain valid, and it renders the skip as a
note — and dropped where it is not.

- **Persistence failure stops the durable stage.** `build_lot1_flags.R` checks
  both `materialize_*()` results and refuses to continue. It will not print a
  summary read from a table that an earlier run wrote.
- **A skipped criterion stops it too**, by default. Its flag passes every
  patient, which in the data is indistinguishable from a criterion that excluded
  nobody. `--allow-skipped` is the explicit opt-in for an exploratory build, and
  the run still warns at the end.
- **`LOT1_FLAGS_RUN` records what actually ran** — per criterion: the flag
  column it sets, whether it was evaluated, plus the patient input, `lot1_from`,
  `pre_lot1_days`, `study_end` and a build timestamp. Written *before* any
  summary, so the record exists even for a run that then reports skips.
- **The engine refuses to apply a gate whose criterion was skipped.** Each of the
  four source-dependent gates carries a `criterion` key; `unevaluated_gates()`
  (pure, therefore tested) maps the record back to gates, and the run stops
  rather than building a cohort that silently omits a criterion. Absent metadata
  is a **warning**, not an error: dashboard-built flags predate the record, and
  unknown provenance is not the same as known-bad.

### 5. [P1] The persisted rename breaks consumers — ~~confirmed~~ **FIXED**

The `NDMM_* -> LOT1_*` aliases in the dashboard are R variables only. Real
warehouse readers of the old table name exist:
`poma_studyteam_qs.R:535` (`wrk("NDMM_FLAGS_ALL")`) and
`cohort_explorer/warehouse/08_analytic_cohort.R:86`. Old table present → they
read stale data; absent → they fail. A compatibility view is required.

#### Fix (step 5)

`write_lot1_compat_view()` republishes `NDMM_FLAGS_ALL` as a **view** over the
current `LOT1_FLAGS_ALL`, so the existing readers keep working *and* stay
current.

- **Both producers publish it.** The dashboard writes `LOT1_FLAGS_ALL` too since
  the rename, so a dashboard run would otherwise leave the old name stale. It
  does so best-effort (a dashboard must still render); the standalone stage
  treats the same failure as fatal.
- **The column contract is checked before publishing.** Both consumers select
  named columns — `PATID`, `CE_pre_lot1_12mo`, `CE_lot1_3mo_fu`, `NO_BELANTAMAB`,
  `NO_PRIOR_MM_TX`, `NO_OTHER_CANCER_PRE_LOT1`, `NO_PREGNANCY` — so the extra
  `INDEX_DATE` / `LOT1_START_DT` are harmless, and a missing one fails here
  rather than in their queries. A test reads the consumer files and asserts
  every column they select is in the required list, so it stays true if they
  change.
- **It never drops a physical table by default.** If the legacy name still
  exists as a real table from a pre-rename run, that is somebody's data. The
  function reports what is there — including the row count — and stops, because
  leaving it silently means consumers read pre-rename numbers.
  `LOT1_REPLACE_LEGACY_TABLE=TRUE` is the explicit opt-in after you have
  looked.

### 6. [P2] Attrition claims are inaccurate — ~~confirmed~~ **FIXED (static half); empirical half now RUNNABLE but UNRUN**

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

#### Fix (step 6)

**The funnel order is now the dashboard's.** `ce_fu_lot1_3mo` moved from fourth
to fifth in `ndmm/cohort.R`, matching `ndmm_counts()`. The final AND-set is
order-independent so the cohort is unchanged, but the intermediate attrition
counts are not — and this folder is meant to reproduce the legacy *report*, not
merely the legacy cohort.

**Section 3 compares in order**, not with `setequal()`, and additionally asserts
the generated funnel emits them in that order.

**Section 4 compares token SEQUENCES with multiplicity.** The allowed additions
are removed from both sides and the remainder must be identical
element-for-element, with the first divergence reported.

> This immediately caught something the set comparison had hidden: the flag
> table gained `LOT1_START_DT` as an output column in step 2, and I had
> documented only *two* generalizations. It is now a third, stated in
> `lot1_flags.R`'s header and **pinned** by assertions that it is present in the
> new SELECT list, absent from the old, and occurs exactly once more than before
> — so it is allowed as a known addition rather than tolerated as noise.

**`tests/verify_against_legacy.R` is the empirical check.** `EXCEPT` in both
directions, never counts — two different cohorts of the same size pass a count
check. It compares:

| new | legacy |
|---|---|
| `coh_overall_cohort` | `ELIG_COH_FINAL` |
| `coh_index_union` | `ELIG_COH_FINAL` (the LOT build's input) |
| `coh_ndmm_cohort` | the six-flag filter over `LOT1_FLAGS_ALL` |

`_ndmm_patids` is a temp view and never persisted, so the legacy NDMM set is
reconstructed — **derived from the spec's own LOT1 gates**, so it cannot drift
into comparing the cohort with itself. Non-empty either way reports the count
and sample PATIDs and exits non-zero, so it works as a release gate. It is named
`verify_*` so `run_all_tests.R`'s `test_*` glob cannot run it without a
warehouse and cannot silently skip it either.

**It has not been run.** That is the whole of what is left.

---

## Corrected sequence

Ordered so nothing is built on an unvalidated base:

1. ~~**Load the real configuration.**~~ **DONE** — see the fix under finding 1.
2. ~~**Fix the execution path.**~~ **DONE** — see the fix under finding 2.
3. ~~**Enforce one index per PATID.**~~ **DONE** — see the fix under finding 3.
4. ~~**Fail closed** on failed persistence and on missing criterion inputs.~~
   **DONE** — see the fix under finding 4.
5. ~~**Compatibility view** for `NDMM_FLAGS_ALL`.~~ **DONE** — see the fix
   under finding 5.
6. ~~**Replace the static comparator**~~ **DONE** — see the fix under finding 6.
   The `EXCEPT` checks exist and are runnable; **running them is the remaining
   work, and it needs a warehouse.**

Step 1 has landed, so section 2 of `tests/test_equivalence.R` is now sound.
Sections 3 and 4 are not: `setequal()` cannot see funnel-order changes and the
token-SET comparator discards order and multiplicity (finding 6). The suite
carries a banner saying exactly which parts to trust.

**Nothing here changes the fact that no code has run against the warehouse.**
Step 1 makes the static comparison meaningful; it does not make it empirical.

---

# Second review round — `cohort_overall`

Nine findings, all reproduced, all addressed. Two were release blockers.

| # | Finding | Status |
|---|---|---|
| 1 | **P0** Checkpoint materialisation used the unprefixed name, so a clean run died at the first checkpoint | fixed structurally |
| 2 | **P0** `verify_against_legacy.R` never reads this build's output, so the README pointed at a gate that could pass while the build had failed | new gate written |
| 3 | **P1** `--no-persist` still wrote tables | flag removed |
| 4 | **P1** README claimed the study window comes from the CSV; `cfg_defaults` hardcodes it | fixed, working override added |
| 5 | **P1** Invalid `OUTPATIENT_WINDOW` silently became 90; a malformed `APPLY_*` silently disabled a gate | both rejected |
| 6 | **P1** `--views` ran nothing silently on a typo; `--attrition-only` could never work from a fresh session | flags removed |
| 7 | **P1** Inpatient/outpatient are not exhaustive (`NOT(NULL)` is NULL), and step 8 treats the same claim as outpatient | comments fixed, diagnostic added, SQL unchanged |
| 8 | **P2** The attrition terminal row never read the cohort table | `ie_reconcile()` added |
| 9 | **P2** "1L-treated" contradicted step 6's own definition | relabelled |

## Finding 1

A step used to carry its own `CREATE ... {work('x')} AS`, so the object name
existed twice: in the step's SQL, and again in what the runner handed the
materialiser. They disagreed.

Now a step carries only `name` and a `SELECT`. `work()` is the only place a name
is built, `ie_stmt()` the only place a `CREATE` is built, and `ie_view()` rejects a
`select` containing a `CREATE`. There is no second place for a name to come from.

This also carried out the request to drop temp views — a Databricks SQL warehouse
re-runs a view's definition on every read. All 27 objects are tables, which
removed checkpoints, the materialiser and the persist step along with the bug.

## Finding 2

`tests/verify_cohort_overall.R`: `ovr_ELIG_COH_FINAL` vs the legacy
`ELIG_COH_FINAL`, `EXCEPT` both ways on PATID **and** `(PATID, INDEX_DATE)`, grain
on both sides, 15 key fields over shared pairs, and the funnel reconciliation.

`(PATID, INDEX_DATE)` matters because criteria are applied before the index date
is ranked, so the same patient can legitimately survive on a different date — and
every LOT number is computed from that date. A PATID-only check would report
agreement while the exposure dates had moved.

Not run yet. It needs a warehouse.

## Finding 7

`NOT (POS IN (...) OR TOS_CD IN (...) OR CONF_ID IS NOT NULL)` is NULL when the
first two are NULL and there is no confinement, so both flags come out 0 and the
claim cannot produce an index date. Step 8 writes the inpatient flag with `ELSE 0`
and treats everything else as outpatient, so it classifies the same claim
differently.

Both are inherited, so the legacy comparison cannot show either. Changing them
would change the cohort, which is the study team's call — so the SQL is untouched,
the comments say what actually happens, and `mm_dx_events_all` carries a
diagnostic counting the affected claims and the strict subset.

## On "token for token"

The offline comparison is normalised text: whitespace collapsed, `CREATE` dropped,
object qualifier removed, both checked safe first. Earlier wording said "token for
token", which overstated it.

## On overengineering

Dropped: the checkpoint layer, the materialiser, the persist step, the
`mat_tables` environment, four CLI modes, the attrition CSV export and the
`IE_CREATE_TABLE_FN` hook. Kept: the criterion object model, which drives the
filter, the attrition table, the reconciliation and the validation from one
declaration, and `fmt()`, which exists so the SQL stays a literal copy of the
templates it is compared against.

The suggestion to reuse `build_steps()` instead of a second copy was not taken:
`Jul 28` is the deployable folder and must not read `apr_30_2026` at run time. The
copy is the price, and it is drift-tested while both are present.
