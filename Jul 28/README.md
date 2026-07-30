# Jul 28 — cohort build codes (Overall + NDMM) on a shared flagged PLD

Standalone cohort builders, one file per cohort. `build_ndmm.R` is a complete
run: it does not build the Overall cohort and does not read `ELIG_COH_FINAL`.

> ⚠️ **NOT VALIDATED.** All six review findings are addressed in code, but the
> check that would establish equivalence — `tests/verify_against_legacy.R`,
> `EXCEPT` in both directions against the legacy cohorts — **has never been run**.
> A green `run_all_tests.R` is evidence about SQL text, not about patients.
> Read **[REVIEW_FINDINGS.md](REVIEW_FINDINGS.md)** first.

Read **[PLAN.md](PLAN.md)** for the design and the upstream changes it assumes.

## Layout

One folder per cohort. Everything for a cohort is inside its folder.

```
overall/                      ndmm/
  cohort.R      definition      cohort.R              definition
  build.R       entry point     build.R               entry point
  tests/                        build_lot1_flags.R    LOT1 flag stage
  README.md                     tests/
                                README.md

engine/          the shared SQL generator (see the note below)
build_both.R     both cohorts + one shared PLD
tests/           engine invariants + old-vs-new equivalence (PLAN.md §5)
run_all_tests.R  every suite

cohort_overall/  the Overall cohort's IE criteria, built FROM THE CDM
lib/             the shared plumbing, so this folder ships on its own
pipeline_inputs.csv   the configuration these entry points read
```

`overall/` and `ndmm/` are the **selection** layer: flags in, cohorts out. They
read `ELIG_COH_ALLFLAGS`, which the legacy pipeline produces.
**[`cohort_overall/`](cohort_overall/README.md)** is the other half — it builds
the ten index-anchored IE criteria from the raw CDM, one file per table, so
Overall can be built without `01_cohort.R` running first. It writes real tables to
your personal schema, prefixed `ovr_`.

## This folder ships on its own

`Jul 28` is what goes to production, so **nothing in it reads `apr_30_2026` at run
time**. The plumbing is in [`lib/`](lib/README.md) as a verbatim copy of
`apr_30_2026/R/`, and `pipeline_inputs.csv` is a verbatim copy too. Both are
asserted byte-identical by `tests/test_equivalence.R` §6 while `apr_30_2026` is
present; in production it is absent and the checks skip. The same suite asserts
that no run-time file here resolves a path into `apr_30_2026`.

Copying means two definitions, which can drift. The alternative was worse — the
production folder would not have been deployable. `lib/README.md` has the rule
that keeps it honest: never edit those files, layer behaviour on top in the
caller.

```sh
Rscript "Jul 28/run_all_tests.R"                    # 398 assertions, 5 suites

# The one that settles equivalence -- needs a warehouse:
Rscript "Jul 28/tests/verify_against_legacy.R" --dry-run     # see the SQL
DATABRICKS_PWD=... Rscript "Jul 28/tests/verify_against_legacy.R"


Rscript "Jul 28/cohort_overall/build_overall.R" --funnel  # Overall's IE funnel
Rscript "Jul 28/cohort_overall/build_overall.R" --dry-run # ...and its 27 statements

# The one that settles equivalence for that build -- needs a warehouse:
Rscript "Jul 28/cohort_overall/tests/verify_cohort_overall.R" --dry-run

Rscript "Jul 28/overall/build.R" --dry-run
Rscript "Jul 28/ndmm/build.R" --dry-run
Rscript "Jul 28/ndmm/build.R" --index-only --dry-run # stop at the LOT-build input
Rscript "Jul 28/build_both.R" --dry-run              # both + the shared PLD

DATABRICKS_PWD=... Rscript "Jul 28/ndmm/build.R"     # execute
```

Connects via `DATABRICKS_DSN` (from `pipeline_inputs.csv`) + `DATABRICKS_PWD`,
the same way `02_lot1.R` does — so a real run needs only the password, which
stays in the environment by design. `COHORT_CONNECT_FN=<function name>`
overrides it for a host that connects differently; the function must already be
defined in the session, and you get a clear error if it isn't.

### One thing is shared: the engine

`engine/` holds the SQL generator, the gate registry and the runner. It is
**not** copied into each cohort folder: the cohort *definitions* are separate,
the SQL is written once. That split is what keeps NDMM's CE / prior-therapy /
other-cancer definitions from drifting further than they already have.

If you need a folder to be genuinely portable on its own — zip `ndmm/` and hand
it to someone — copy `engine/` into it and set `COHORT_ENGINE_DIR`. Say the word
and I'll wire that up permanently.

## What it produces

| Object | Grain | |
|---|---|---|
| `coh_<id>_index_sel` | one row per PATID | **table** — index-anchored IE funnel, then earliest qualifying index |
| `coh_index_union` | one row per PATID | **table** — union across cohorts; **the LOT build's input**, so it must outlive the connection that made it |
| `coh_<id>_cohort` | one row per PATID | temp view — final membership (adds LOT1-anchored gates) |
| `coh_pld` / `COHORT_PLD` | one row per PATID | **the shared PLD**: every criterion a column, plus `COHORT_OVERALL` / `COHORT_NDMM` |

`INDEX_DATE` is carried on every one of these as the anchor, but **`PATID` is the
key**. `LOT_LONG` is keyed by `(PATID, LOT_NUM)` and has no `INDEX_DATE`, so two
index dates for one patient cannot be represented downstream. If the requested
cohorts ever select different indexes for the same patient, the run is
**rejected** right after the union is built rather than fanning out silently.

Plus a per-cohort attrition funnel (cumulative distinct patients, one row per
gate, terminal check row).

```sql
SELECT * FROM COHORT_PLD WHERE COHORT_NDMM = 1;
SELECT * FROM COHORT_PLD WHERE COHORT_OVERALL = 1;
SELECT * FROM COHORT_PLD WHERE COHORT_NDMM = 1 AND NO_BELANTAMAB = 0;  -- sensitivity
```

## Configuration

Env vars, matching the existing pipeline convention (`pipeline_inputs.csv` still
applies upstream).

| Var | Default | |
|---|---|---|
| `PROJECT_WORK_SCHEMA` / `WORK_SCHEMA` | — | schema qualifier for all objects |
| `INDEX_FLAGS_TABLE` | `ELIG_COH_ALLFLAGS` | index-anchored flags (step 23) |
| `LOT1_FLAGS_TABLE` | `LOT1_FLAGS_ALL` | LOT1-anchored flags (see PLAN §6a) |
| `LOT1_STARTS_TABLE` | `LOT1_STARTS` | 1L starts, one row per PATID, carrying INDEX_DATE |
| `PLD_TABLE` | `COHORT_PLD` | persisted PLD |
| `MIN_AGE` | `18` | |
| `OUTPATIENT_WINDOW` | `90` | must be 30, 60 or 90; from `pipeline_inputs.csv` |
| `NDMM_LOT1_FROM` | `2017-01-01` | 1L start cutoff |

## Adding or changing a cohort

**Changing one:** edit its file in `cohorts/`. Nothing else moves, and the other
cohort is untouched — the two files share no constant.

**Adding one:** drop a new file in `cohorts/`. Its last expression must be a spec
list (`id`, `label`, `flag_col`, `gates`, optional `order`/`params`). SQL,
attrition funnel, PLD column and schema guard all follow automatically; no
engine file needs an edit. `build_cohort.R --cohort=<id>` picks it up.

A cohort file contains **no SQL** — only a gate list in funnel order. The gate
ids resolve against the registry in `R/cohort_specs.R`, which holds the SQL.

Because the files are independent, two gate lists that are *meant* to agree can
drift. Every multi-cohort run prints an index-gate diff, and the tests assert
the current agreement, so drift shows up at review rather than in the numbers.

Validation fails closed on unknown gates, duplicates, unknown parameters, and on
attempts to override a window that is baked into an upstream flag (see PLAN §3).

## Note

**`apr_30_2026/` is not modified, and is no longer read at run time.** Its
helpers were COPIED into `lib/` (verbatim, byte-identity asserted) so this folder
ships alone. The **entire** `apr_30_2026` directory is still asserted
byte-identical to the branch point by `tests/test_equivalence.R` §1 (one
`git diff --quiet` over the whole directory, not a chosen file list).

Generated objects are prefixed `coh_` (`COHORT_VIEW_PREFIX`) so they cannot
collide with the existing pipeline.

### The cost of that, stated plainly

An earlier revision lifted the LOT1-anchored criteria out of
`06_ndmm_dashboard.R` into a shared module, so there was one definition. That is
reverted. The criteria now live in **`ndmm/lot1_flags.R`**, and
`06_ndmm_dashboard.R` keeps its own inline copy — so **there are two definitions
of each criterion**.

They are identical today: `ndmm/lot1_flags.R` was lifted verbatim, and
`tests/test_equivalence.R` §4 still compares it token-for-token against the
dashboard's version, §5 compares every constant by evaluation. But nothing
*prevents* them diverging — an edit to one will not touch the other, and only
the test will notice. That is the same failure mode that let NDMM's CE and
prior-therapy definitions drift from Overall's in the first place.
Generated views are prefixed `coh_` (`COHORT_VIEW_PREFIX`) so they cannot
collide with the existing pipeline.

R escapes spaces in script paths as `~+~`, so the path helpers here un-escape
before `normalizePath()`. Keep that if you copy the pattern into a folder whose
name has a space.
