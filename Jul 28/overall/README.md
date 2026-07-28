# `overall/` — the Overall MM cohort

Everything for the Overall cohort lives here.

| | |
|---|---|
| `cohort.R` | **The definition.** Gate list in funnel order. No SQL. |
| `build.R` | Entry point |
| `tests/test_overall.R` | This cohort's contract |

```sh
Rscript "Jul 28/overall/build.R" --dry-run   # print the SQL, touch nothing
Rscript "Jul 28/overall/build.R"             # execute
Rscript "Jul 28/overall/tests/test_overall.R"
```

## What it needs

**Only `ELIG_COH_ALLFLAGS`** (`pipeline_steps.R` step 23). Overall has no
LOT1-anchored gates, so this folder never touches the LOT build, the LOT1 flag
tables, or `ndmm/`. There is a test for that.

## Definition

The step-1 index gate (`pipeline_steps.R:1062`) plus the ten criteria in
`build_criteria_catalog()` (`criteria_attrition.R:38`), applied in that order,
then earliest-qualifying index per patient. Byte-identical to today's step 24 —
see `../PLAN.md` §5.

Note `fu_mm_agents`: "any MM agent claim in follow-up, **any drug class**"
(`pipeline_steps.R:723`). It does *not* require a LOT1 regimen start, which
excludes steroids (`02_lot1.R:678`). A patient whose only follow-up MM agents
are steroids **belongs to Overall** — see `../PLAN.md` §4a.

## Changing it

Edit `cohort.R`. `ndmm/` is unaffected — the two gate lists share no constant.
If you change an index gate that is meant to stay in step with NDMM's, the
drift report on every `build_both.R` run will say so.

The engine (`../engine/`) is shared, not copied — see the note in `../README.md`.
