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
```

```sh
Rscript "Jul 28/run_all_tests.R"                    # 229 assertions, 4 suites

# The one that settles equivalence -- needs a warehouse:
Rscript "Jul 28/tests/verify_against_legacy.R" --dry-run     # see the SQL
DATABRICKS_PWD=... Rscript "Jul 28/tests/verify_against_legacy.R"


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

**This folder is no longer self-contained.** It was through Phase 1; Phase 2
(review finding 2 / PLAN §6a) changed that, and this line used to say otherwise.
Exactly two files in `apr_30_2026/` are touched:

| | |
|---|---|
| `R/lot1_flags.R` | **new** — the LOT1-anchored flag stage, lifted out of the dashboard so the criteria have one definition instead of being private to a 1,400-line render script |
| `06_ndmm_dashboard.R` | **−640 lines** — those definitions removed and sourced from the module instead, plus back-compat `NDMM_*` aliases so its remaining ~20 references still resolve |

Everything else is byte-identical to the branch point, asserted per file by
`tests/test_equivalence.R` §1 — including `01_cohort.R`, `02_lot1.R`,
`03_lot2_5.R`, `pipeline_steps.R`, `criteria_attrition.R` and both config files.
The LOT build reads a different input table, but that was already the
`INPUT_COHORT_TABLE` knob, not an edit.

Generated objects are prefixed `coh_` (`COHORT_VIEW_PREFIX`) so they cannot
collide with the existing pipeline.
Generated views are prefixed `coh_` (`COHORT_VIEW_PREFIX`) so they cannot
collide with the existing pipeline.

R escapes spaces in script paths as `~+~`, so the path helpers here un-escape
before `normalizePath()`. Keep that if you copy the pattern into a folder whose
name has a space.
