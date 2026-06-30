# Cohort Explorer — flag-driven IE dashboard (Overall & NDMM)

A Shiny re-creation of the sample *Oncology Real-World Data Explorer Tool*
(`../sample dashboard/dashboard sample.pdf`), built for the MM LOT cohorts in
this repo. The point is **flexibility over the inclusion/exclusion (IE)
criteria**: pick a cohort, freely toggle the IE rules, tune the filters, and
every output re-selects from one pre-built **flagged superset cohort** — nothing
is re-derived per change.

```
shiny::runApp("cohort_explorer")          # runs on synthetic data, no warehouse
```

## The core idea: one cohort, many flags

Instead of re-running the cohort pipeline every time a criterion changes, the
pipeline builds the **broadest** 1L-treated MM cohort **once** and stamps **one
boolean column per IE criterion** onto it (`incl_qualifying_mm`, `incl_adult`,
`incl_baseline_ce_12m`, `excl_belantamab`, …). "Selecting a cohort" is then just
**AND-ing a chosen set of flags** — instant, and reusable across any cohort
definition.

This is the same design already sketched in
`../jun_21_2026/cohort/gates/registry.yml` (each gate emits an `output_flag`)
and exposed as IE toggles in `../apr_30_2026/pipeline_inputs.csv`
(`APPLY_AGE_INCL`, `APPLY_CE_B_INCL`, …). `apr_30_2026` is the validated,
authoritative algorithm; this tool is a presentation + selection layer on top of
its outputs.

- **Overall** and **NDMM** are just two default flag sets
  (`cohort_definitions()`), mirroring `studies/overall.yml` and
  `studies/ndmm.yml`. The user can start from either and add/remove criteria.

## Layout (mirrors the sample)

- **Sidebar** — *Cohort Selection* dropdown + *Apply Cohort*; an
  *Inclusion / Exclusion Criteria* accordion grouped by **Demographics /
  Clinical / Labs / Treatments / Other**, where each IE flag is a checkbox and
  each live filter (age slider, gender/region/payer/SOC multiselects) is a
  control; *Apply Filters*.
- **Tabs** — *Patient Characteristics* (categorical N/% + continuous
  mean/median by strata), *rwOS / rwPFS / rwTTD / rwTTNT* (KM curves with a time
  horizon slider, strata, median + number-at-risk tables), *Cohort & Attrition*
  (sequential attrition waterfall), and *Validation & Checks*.

## Files

```
cohort_explorer/
  app.R                       Shiny UI + server
  global.R                    startup: source engine, load flagged cohort
  R/
    criteria_registry.R       IE criteria + cohort definitions (single source)
    build_flagged_cohort.R    flagged-cohort contract + loader + synthetic gen
    cohort_select.R           flags + filters -> sub-cohort + attrition (pure)
    summaries.R               Patient Characteristics summary stats
    km.R                      time-to-event KM (survival) + base-graphics plot
    checks.R                  LOT structural + NDMM protocol conformance checks
    ui_helpers.R              theme + registry-driven control builders
  tests/test_engine.R         base-R unit tests for the engine + checks
```

## Reuse / extension

- **Add an IE criterion** → add one entry to `criteria_registry()`. The sidebar
  control, the attrition step, and the protocol check all appear automatically.
- **Add a cohort** → add an entry to `cohort_definitions()` listing its default
  active flags. It shows up in the dropdown.
- **Add a variable / endpoint** → extend `variable_dictionary()` /
  `endpoint_dictionary()`.

## Wiring real data (replaces the synthetic source)

The dashboard reads a **flagged-cohort table** with the schema in
`FLAGGED_COHORT_BASE_COLS` + `registry_flag_ids()`. Two ways to supply it:

```bash
# (a) a CSV projection
COHORT_EXPLORER_DATA=/path/to/flagged_cohort.csv  Rscript -e 'shiny::runApp("cohort_explorer")'
```

```r
# (b) a warehouse projection: implement a function and pass it as the source.
#     The real builder is a thin join of the validated apr_30_2026 outputs
#     (ELIG_COH_FINAL + LOT_LONG) with the per-criterion flags emitted as
#     COLUMNS instead of applied as row filters — see build_flagged_cohort.R.
FLAGGED <- load_flagged_cohort(source_flagged_cohort_warehouse)
```

`validate_flagged_cohort()` **fails closed** if a contract column is missing or a
flag is not strictly 0/1, so a malformed projection never silently mis-selects.

## Status / caveats

- **Synthetic by default.** Real figures require the `apr_30_2026` outputs from
  Databricks `hive_metastore` (no warehouse in this environment), so the bundled
  data is a deterministic synthetic cohort (reserved `9`-billion PATIDs).
- The sample's *Practice Type* / *Smoking* filters are Flatiron EHR fields; the
  Optum analogues here are *Region / Payer type / Race*. The accordion keeps the
  sample's category structure (incl. an empty **Labs** bucket) so lab criteria
  can be dropped in.
- Dependencies: `shiny` (required), `survival` (enables the KM tabs; the app
  degrades gracefully without it). Tables use base `renderTable` — no `DT`
  dependency.
