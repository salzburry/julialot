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

## Layout (mirrors the sample, aligned to GSK 223926 protocol)

- **Sidebar** — *Cohort Selection* dropdown + *Apply Cohort*; *Analysis options*
  (**Line of therapy** 1L/2L/3L for the outcome tabs, and a **≥3-mo follow-up
  restriction** toggle per protocol §6.7.2); an *Inclusion / Exclusion Criteria*
  accordion grouped by **Demographics / Clinical / Labs / Treatments / Other**,
  where each IE flag is a checkbox and each live filter (age slider,
  gender/region/payer/SOC multiselects) is a control; *Apply Filters*.
- **Tabs**
  - *Patient Characteristics* — protocol Table 1: demographics (sex, region,
    race, **ethnicity**, insurance), **age bands + ≥70**, **Charlson CCI**,
    **dx/1L-initiation years**, **follow-up from dx**, **baseline comorbidities
    of interest** (hepatic/renal/infection/ocular/CV/neuro) and **baseline
    HCRU** (hospitalisations, ER, LOS). Categorical N/% (with a `(Missing)`
    category) + continuous mean/SD/median/IQR/min/max + missing counts, by
    strata, with **<25-patient suppression** (§6.5).
  - *OS / TTD / TTNT / Attrition* — protocol time-to-event endpoints (KM curve,
    **landmark survival at 6/9/12/18/24 mo with 95% CI**, median, number-at-risk),
    plus *PFS\** clearly labelled **exploratory, non-protocol** (§6.9 states PFS
    could not be ascertained in claims). Outcomes recompute per selected
    **line of therapy**.
  - *Regimen & Transitions* — regimen-frequency table per line, the full
    **1L→2L→3L→4L treatment-pattern pathway Sankey** (commercial-insured only,
    Exploratory Obj 3; patients who stop flow into an "End" node), and a
    per-stage transition detail table.
  - *Cohort & Attrition* — sequential attrition waterfall.
  - *Validation & Checks* — LOT structural checks, NDMM protocol conformance,
    and **protocol data-quality / analysis-readiness** (≥3-mo TTE denominator,
    missing/unknown tallies, <25 suppression flags).

**Subgroups / strata** available on the Patient-Characteristics and KM tabs:
SOC regimen category, age band, **age ≥70 vs <70**, CCI band, the two
**transplant-eligibility proxies** (age; age-or-CCI≥3), and the baseline
medical-condition flags (CV / neuro / renal) — protocol §6.2.3 / §6.3.3.

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
    km.R                      protocol endpoints + landmark tables + >=3mo cut
    lot_views.R               per-LOT slicing, regimen freq, SOC transitions/Sankey
    checks.R                  LOT structural + NDMM conformance + protocol DQ checks
    ui_helpers.R              theme + registry-driven control builders
  tests/test_engine.R         base-R unit tests (51) for the engine + checks
  tests/test_app.R            Shiny testServer tests (cohort reset, parity, ...)
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
# (a) CSV projections (patient-level flagged cohort + LOT-long for per-LOT views)
COHORT_EXPLORER_DATA=/path/flagged_cohort.csv \
COHORT_EXPLORER_LOTLONG=/path/lot_long.csv \
  Rscript -e 'shiny::runApp("cohort_explorer")'
# With a REAL cohort, COHORT_EXPLORER_LOTLONG is REQUIRED (the app fails closed
# otherwise; set ALLOW_SYNTHETIC_LOTLONG=TRUE only to intentionally demo with a
# synthetic LOT-long). With the default synthetic cohort, LOT-long is synthesised.
```

```r
# (b) a warehouse projection: implement a function and pass it as the source.
#     The real builder is a thin join of the validated apr_30_2026 outputs
#     (ELIG_COH_FINAL + LOT_LONG) with the per-criterion flags emitted as
#     COLUMNS instead of applied as row filters — see build_flagged_cohort.R.
FLAGGED <- load_flagged_cohort(source_flagged_cohort_warehouse)
```

`validate_flagged_cohort()` / `validate_lot_long()` **fail closed** if a contract
column is missing, a flag is not strictly 0/1, or the LOT-long key is not unique,
so a malformed projection never silently mis-selects.

**Synthetic guardrails (fail-closed):** if a **real** `COHORT_EXPLORER_DATA` is
supplied **without** a real `COHORT_EXPLORER_LOTLONG`, the app **refuses to
start** (per-LOT / regimen / transition views would otherwise be fabricated)
unless you explicitly set `ALLOW_SYNTHETIC_LOTLONG=TRUE`. Whenever any source is
synthetic, a red **"SYNTHETIC DATA — not for analysis"** banner is shown. The
production `source_flagged_cohort_warehouse()` is a **fail-closed stub** — it
errors until the DBI/odbc projection of the `apr_30_2026` outputs is implemented;
there is no silent synthetic fallback on the production path.

**Filter neutrality:** IE/param filter defaults are **all-data** (all observed
levels; full age range), so the initial Overall/NDMM cohort equals the flag-only
selection — a filter only ever shrinks the cohort when the user changes it. A
unit test asserts `Overall(initial) == Overall(flag-only)`.

## Status / caveats

- **Synthetic by default.** Real figures require the `apr_30_2026` outputs from
  Databricks `hive_metastore` (no warehouse in this environment), so the bundled
  data is a deterministic synthetic cohort (reserved `9`-billion PATIDs).
- The sample's *Practice Type* / *Smoking* filters are Flatiron EHR fields; the
  Optum analogues here are *Region / Payer type / Race*. The accordion keeps the
  sample's category structure (incl. an empty **Labs** bucket) so lab criteria
  can be dropped in.
- **Later-line strata** are 1L-baseline **carry-forward** (joined onto LOT-long
  by `augment_lot_long()`); if a requested stratum is not available at the chosen
  line the KM tab shows a **hard warning** rather than silently pooling.
- **Suppression** is applied at the **stratum** level (protocol §6.5: "do not
  report a stratum with <25 patients"), surfaced for categorical *and*
  continuous selections. Cell-level suppression (small counts inside a
  reportable stratum) is **not** applied pending confirmation of the exact
  GSK/Optum output rule.
- **≥3-mo follow-up** uses `fu_potential_months`, which the synthetic generator
  builds as **administrative** potential follow-up (independent of death), so an
  early death still counts as having ≥3-mo potential follow-up. The real
  projection must define `fu_potential_months` the same way (index → min(study
  end, disenrollment), not time-to-death).
- **Transitions** cover **1L→2L→3L→4L** via the from-line selector; **4L is
  start-only** (no 4L cohort, per protocol), so per-LOT *outcome* lines stop at 3L.
- **Protocol alignment / known deferrals:** lab-value-defined comorbidity arms
  (hepatic/renal/ocular) use the ICD-code arm only — Optum lab values are
  sparse. The **SOC drug→category mappings and code lists** (protocol Annexes
  2/5) are placeholder/scanned pages in the source PDF, so the real builder must
  take them from the referenced GSK LoT-algorithm doc; the synthetic SOC labels
  here follow the §6.2.2 category *scheme*. Patient Characteristics are computed
  at the **1L baseline**; when a later line is selected only the **outcomes**
  re-anchor to that line (per-line baseline re-derivation is a warehouse step).
- Dependencies: `shiny` (required), `survival` (enables the KM tabs; the app
  degrades gracefully without it). Tables use base `renderTable` — no `DT`
  dependency.
