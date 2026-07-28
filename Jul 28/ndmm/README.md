# `ndmm/` — the NDMM (newly diagnosed, 1L) cohort

Everything for the NDMM cohort lives here.

| | |
|---|---|
| `cohort.R` | **The definition.** Gate list in funnel order. No SQL. |
| `build.R` | Entry point |
| `build_lot1_flags.R` | The LOT1-anchored flag stage (only NDMM needs it) |
| `tests/test_ndmm.R` | This cohort's contract |

```sh
Rscript "Jul 28/ndmm/build.R" --dry-run      # print the SQL, touch nothing
Rscript "Jul 28/ndmm/build.R" --index-only   # stop at the LOT-build input
Rscript "Jul 28/ndmm/build.R"                # execute
Rscript "Jul 28/ndmm/tests/test_ndmm.R"
```

## Independence

**This folder never builds the Overall cohort and never reads
`ELIG_COH_FINAL`.** It reads `ELIG_COH_ALLFLAGS` directly, selects its own index
dates, and applies its LOT1-anchored gates against `LOT1_STARTS` /
`LOT1_FLAGS_ALL`. Tests assert that its definition and its generated SQL name
nothing belonging to Overall.

It *does* need the **LOT build** to have run — every NDMM gate is anchored at
`LOT1_START_DT`, so with no 1L regimen there is nothing to measure. That runs on
the union view, not on Overall.

## Run order

`--index-only` breaks the bootstrap: the LOT build consumes the union view, but
the membership view consumes flags that only exist after the LOT build has run.

```
1. cohort pipeline through step 23               -> ELIG_COH_ALLFLAGS
2. ndmm/build.R --index-only                     -> coh_index_union  (a TABLE)
3. LOT build, INPUT_COHORT_TABLE=coh_index_union -> LOT_LONG, MAP_STACKED
4. ndmm/build_lot1_flags.R                       -> LOT1_STARTS, LOT1_FLAGS_ALL
5. ndmm/build.R                                  -> the cohort + PLD
```

Each step is a separate process, so `coh_index_union` is a **persisted table**,
not a session-scoped temp view. Step 5 **reuses** the index tables rather than
recomputing them, so the cohort is selected from the same rows the LOT build
consumed; pass `--rebuild-index` to recompute, which means redoing steps 3–4.
Step 2 preflights only what it reads, so it does not demand the `LOT1_FLAGS_ALL`
that step 4 creates.

Steps 1–3 are shared with Overall: run them once and both cohorts select from
the result.

## Definition

The same ten index-anchored gates as Overall (written out separately here, so
editing them changes NDMM only), plus `has_lot1`, the 1L cutoff, and the six
criteria documented in `06_ndmm_dashboard.R`'s header.

`has_lot1` is strictly stronger than `fu_mm_agents`: that one counts any MM
agent including steroids, this one requires a non-steroid regimen start. The
existing build already applies and reports this correctly — declaring it as a
gate only splits it from the cutoff into two funnel rows. See `../PLAN.md` §4a.

The criteria SQL lives in `apr_30_2026/R/lot1_flags.R`, shared with
`06_ndmm_dashboard.R` so there is exactly one definition of each (`../PLAN.md` §6a).

## Changing it

Edit `cohort.R`. `overall/` is unaffected — the two gate lists share no constant.
