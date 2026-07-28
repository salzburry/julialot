# Jul 28 — cohort build codes (Overall + NDMM) on a shared flagged PLD

Standalone cohort builders, one file per cohort. `build_ndmm.R` is a complete
run: it does not build the Overall cohort and does not read `ELIG_COH_FINAL`.

Read **[PLAN.md](PLAN.md)** for the design, the equivalence argument, and the two
upstream changes this assumes.

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
Rscript "Jul 28/run_all_tests.R"                    # 149 assertions, 4 suites

Rscript "Jul 28/overall/build.R" --dry-run
Rscript "Jul 28/ndmm/build.R" --dry-run
Rscript "Jul 28/ndmm/build.R" --index-only --dry-run # stop at the LOT-build input
Rscript "Jul 28/build_both.R" --dry-run              # both + the shared PLD

COHORT_CONNECT_FN=my_connect Rscript "Jul 28/ndmm/build.R"   # execute
```

Without `COHORT_CONNECT_FN` a build refuses to run outside `--dry-run` — it
never opens a connection or writes a table by accident.

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
| `coh_<id>_index_sel` | PATID × INDEX_DATE | index-anchored IE funnel, then earliest qualifying index |
| `coh_index_union` | PATID × INDEX_DATE | distinct union across requested cohorts — **the LOT build's input** |
| `coh_<id>_cohort` | PATID × INDEX_DATE | final membership (adds LOT1-anchored gates) |
| `coh_pld` / `COHORT_PLD` | PATID × INDEX_DATE | **the shared PLD**: every criterion a column, plus `COHORT_OVERALL` / `COHORT_NDMM` |

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
| `LOT1_STARTS_TABLE` | `LOT1_STARTS` | 1L starts keyed by (PATID, INDEX_DATE) |
| `PLD_TABLE` | `COHORT_PLD` | persisted PLD |
| `MIN_AGE` | `18` | |
| `OUTPATIENT_WINDOW` | `60` | must be 30, 60 or 90 |
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

This folder adds objects; it renames and modifies nothing in `apr_30_2026/`.
Generated views are prefixed `coh_` (`COHORT_VIEW_PREFIX`) so they cannot
collide with the existing pipeline.

R escapes spaces in script paths as `~+~`, so the path helpers here un-escape
before `normalizePath()`. Keep that if you copy the pattern into a folder whose
name has a space.
