# Cohort Explorer — flag-driven IE dashboard (Overall & NDMM)

An interactive Shiny *Oncology Real-World Data Explorer Tool* for the MM LOT
cohorts. The point is **flexibility over the inclusion/exclusion (IE)
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

This is the same design the production pipeline uses: each cohort gate emits an
`output_flag`, and the flags are exposed as IE toggles (`APPLY_AGE_INCL`,
`APPLY_CE_B_INCL`, …). The production pipeline is the validated,
authoritative algorithm; this tool is a presentation + selection layer on top of
its outputs.

- **Overall** and **NDMM** are just two default flag sets
  (`cohort_definitions()`), mirroring the pipeline's Overall and NDMM study
  definitions. The user can start from either and add/remove criteria.

## Layout (aligned to the NDMM study protocol)

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
  - *Regimen & Transitions* — regimen-frequency table per line, a
    **configurable** treatment-pattern pathway Sankey (**adjustable depth
    1L→N** and a **commercial-only / all-payers** toggle; patients who stop flow
    into an "End" node), and a per-stage transition detail table.
  - *Adjusted & Compare* — **adjusted Cox models** with a free choice of
    covariates (HRs + 95% CI), and a **KM comparison of two saved cohort
    selections** (Group A vs B — save any IE+filter combination from the
    sidebar). All computed in memory on the loaded snapshot → instant.
  - *Cohort & Attrition* — sequential attrition waterfall.
  - *Validation & Checks* — LOT structural checks, NDMM protocol conformance,
    and **protocol data-quality / analysis-readiness** (≥3-mo TTE denominator,
    missing/unknown tallies, <25 suppression flags).

**Subgroups / strata** available on the Patient-Characteristics and KM tabs:
SOC regimen category, age band, **age ≥70 vs <70**, CCI band, the two
**transplant-eligibility proxies** (age; age-or-CCI≥3), and the baseline
medical-condition flags (CV / neuro / renal) — protocol §6.2.3 / §6.3.3.

**Movable thresholds / windows** (in-memory sliders over raw measures carried on
the analytic cohort — no re-query): baseline-CE months, follow-up-CE months,
year-of-diagnosis window, year-of-1L-initiation window, KM time horizon, a
**minimum-follow-up slider** (0–24 mo), and **editable KM landmark times**
(comma-separated). What is *runtime* (any threshold/covariate/group
over materialised columns) vs *build-time* (LOT-derivation params, a new
claims-derived criterion, the SOC map, the superset window → re-materialise) is
spelled out in **`ANALYTIC_COHORT.md`**.

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
  config/study_config.R       ONE study definition; study_config_to_env() maps
                              it to the upstream LOT pipeline env vars
  config/emit_pipeline_env.R  emit that mapping as `export` lines for the build
  tests/test_engine.R         base-R unit tests (101) for the engine + checks
  tests/test_app.R            Shiny testServer tests (17): cohort reset, parity,
                              value-based landmark/safety/pathway, 2L no-crash,
                              movable thresholds/landmarks, Cox, A/B, Sankey config
```

## Reuse / extension

- **Switch tumour type** → set `INDICATION=<id>` (default `mm`). Each tumour type
  is one **indication pack** in `R/indication.R` carrying its IE criteria, cohort
  definitions, SOC/regimen vocabulary, endpoints, safety events, and labels — the
  same engine + UI render any of them. Shipped packs: `mm` (Multiple Myeloma, the
  reference), and template packs `ec` (Endometrial), `oc` (Ovarian), `crc`
  (Colorectal), `hnscc` (Head & Neck SCC), `nsclc` (NSCLC), `sclc` (SCLC). The
  templates use class-based standard-of-care labels + a generic IE core; replace
  each with the tumour's authoritative study definition + drug→category SOC map
  before real data.
- **Add a tumour type** → add a `pack_<id>()` builder and register it in
  `INDICATION_PACKS()`. Nothing else changes.
- **Add an IE criterion** → add one entry to a pack's `criteria`. The sidebar
  control, the attrition step, and the protocol check all appear automatically.
- **Add a cohort** → add an entry to a pack's `cohorts` listing its default
  active flags. It shows up in the dropdown.
- **Add a variable / endpoint** → extend `variable_dictionary()` / a pack's
  `endpoints`.

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
#
# Those two CSVs are produced by the scripts in warehouse/:
#   make_analytic_csv.R  -- ACTIVE build: reads the persisted warehouse tables and
#                           writes analytic_cohort.csv + analytic_lot_long.csv;
#                           self-validates (fail-closed) when COHORT_EXPLORER_DIR set.
#   diagnose_data.R      -- read-only: counts rows failing each contract check.
#   08_analytic_cohort.R -- generic, source-agnostic scaffold (tagged derivations).
```

```r
# (b) a warehouse projection: implement a function and pass it as the source.
#     The real builder is a thin join of the validated production pipeline outputs
#     (ELIG_COH_FINAL + LOT_LONG) with the per-criterion flags emitted as
#     COLUMNS instead of applied as row filters — see build_flagged_cohort.R.
FLAGGED <- load_flagged_cohort(source_flagged_cohort_warehouse)
```

`validate_flagged_cohort()` / `validate_lot_long()` **fail closed** on a malformed
projection: missing contract column; flag/comorbidity not strictly 0/1; negative
or non-integer safety counts; non-positive `baseline_py`; **patient-level TTE**
that isn't 0/1-eventful, is negative, or exceeds potential follow-up (`os`/`ttd`/
`ttnt`/`pfs`), and `os_event=1` without a `death_dt`; **core numeric fields** out
of contract (age / CCI / `n_lines` / HCRU counts not non-negative integers,
`n_lines<1`, non-positive `lot1_length`, negative LOS); missing `index_date` /
`lot1_start_dt` or `index_date > lot1_start_dt`; non-unique LOT-long key;
non-integer-valued `lot_num` (integer-*valued* doubles from DBI/CSV are accepted,
`1.5` is rejected); a LOT sequence that doesn't start at 1L / isn't contiguous /
has decreasing dates; a `next_soc` inconsistent with the line SOC sequence; a
safety flag that disagrees with its count (`bl_x != n_x>0`); a missing/blank
`lot_soc` or `payer_type` (which `table()` would silently drop from counts); a
TTE beyond potential follow-up; a `ttnt_event=1` on a patient's last line; and
(via `load_lot_long(cohort=)`) **any flagged patient whose LOT-long line count
≠ `n_lines`** (not just missing 1L) — so per-LOT / regimen / pathway views can't
silently undercount vs the KPI N. All KM strata the UI offers are carried onto
LOT-long (`augment_lot_long`), and the **Validation & Checks** data-quality
audit covers **every** selectable stratum (missing/unknown + <25 suppression),
not a hand-picked subset.

**Synthetic guardrails (fail-closed):** if a **real** `COHORT_EXPLORER_DATA` is
supplied **without** a real `COHORT_EXPLORER_LOTLONG`, the app **refuses to
start** (per-LOT / regimen / transition views would otherwise be fabricated)
unless you explicitly set `ALLOW_SYNTHETIC_LOTLONG=TRUE`. Whenever any source is
synthetic, a red **"SYNTHETIC DATA — not for analysis"** banner is shown. The
production `source_flagged_cohort_warehouse()` is a **fail-closed stub** — it
errors until the DBI/odbc projection of the production pipeline outputs is implemented;
there is no silent synthetic fallback on the production path.

**Filter neutrality:** IE/param filter defaults are **all-data** (all observed
levels; full age range), so the initial Overall/NDMM cohort equals the flag-only
selection — a filter only ever shrinks the cohort when the user changes it. A
unit test asserts `Overall(initial) == Overall(flag-only)`.

## Status / caveats

- **Synthetic by default.** Real figures require the production pipeline outputs
  from the data warehouse (no warehouse in this environment), so the bundled
  data is a deterministic synthetic cohort (reserved `9`-billion patient ids).
- The *Practice Type* / *Smoking* filters are EHR-only fields; the claims
  analogues here are *Region / Payer type / Race*. The accordion keeps that
  category structure (incl. an empty **Labs** bucket) so lab criteria
  can be dropped in.
- **Later-line strata** are 1L-baseline **carry-forward** (joined onto LOT-long
  by `augment_lot_long()`); if a requested stratum is not available at the chosen
  line the KM tab shows a **hard warning** rather than silently pooling.
- **Suppression** is applied at the **stratum** level (protocol §6.5: "do not
  report a stratum with <25 patients"), surfaced for categorical *and*
  continuous selections. Cell-level suppression (small counts inside a
  reportable stratum) is **not** applied pending confirmation of the exact
  source small-count output rule.
- **≥3-mo follow-up** uses `fu_potential_months`, which the synthetic generator
  builds as **administrative** potential follow-up (independent of death), so an
  early death still counts as having ≥3-mo potential follow-up. The real
  projection must define `fu_potential_months` death-independently: under the
  pipeline's **primary** horizon (`ENDDATE = min(study end, death)` for TTE) that
  is simply index → **study end**; under the optional disenrollment-sensitivity
  horizon (`CENSOR_HORIZON_COL=ENDDATE_CE`) it is index → **min(study end,
  disenrollment)** — but that exact value requires a death-independent
  disenrollment date supplied via **`DISENROLL_END_COL=<column>`**. Without that
  column the sensitivity build approximates: it un-caps death-bound rows to the
  study end but otherwise keeps `ENDDATE_CE`, so follow-up can be over-estimated
  only for early deaths who would have disenrolled before study end (a warning is
  logged only when `DISENROLL_END_COL` is set but not found in the table). Never
  time-to-death. See `warehouse/make_analytic_csv.R`.
- **Transitions** cover **1L→2L→3L→4L** via the from-line selector; **4L is
  start-only** (no 4L cohort, per protocol), so per-LOT *outcome* lines stop at 3L.
- **Protocol alignment / known deferrals:** lab-value-defined comorbidity arms
  (hepatic/renal/ocular) use the ICD-code arm only — claims lab values are
  sparse. The **SOC drug→category mappings and code lists** (protocol Annexes
  2/5) are placeholders here, so the real builder must take them from the
  authoritative LoT-algorithm specification; the synthetic SOC labels
  here follow the §6.2.2 category *scheme*. Patient Characteristics are computed
  at the **1L baseline**; when a later line is selected only the **outcomes**
  re-anchor to that line (per-line baseline re-derivation is a warehouse step).
- Dependencies: `shiny` (required), `survival` (enables the KM tabs; the app
  degrades gracefully without it). Tables use base `renderTable` — no `DT`
  dependency.

## Production-readiness checklist (data/policy, outside the dashboard code)

The dashboard shell and the active materialization mechanics
(`warehouse/make_analytic_csv.R`) are complete and validator-gated. The items
below are **data-source and policy decisions** for the data owner — the code is
ready to consume them, but they cannot be closed from within this repo. Each is
marked in code/docs today (placeholders or opt-in flags) so nothing ships
silently wrong.

- [ ] **Real demographics / payer** — region, race, ethnicity, `payer_type` are
  emitted as `'Unknown'`; join the source member tables. Until `payer_type` is
  real, the **commercial-only pathway/Sankey** is structural only, not analytic.
- [ ] **CCI** — emitted as `0`; wire the Charlson comorbidity derivation (also
  gates any CCI-based subgroup / transplant-eligibility view).
- [ ] **Safety flags/counts + `baseline_py`** — emitted as `0` / `1.0`; wire the
  baseline safety-event derivation before any safety-rate output.
- [ ] **HCRU** — `ip_hosp_count` / `er_visit_count` / `ip_los_days` emitted as
  `0`; wire the HCRU source.
- [ ] **SOC drug→category map** — the class/count rule here follows the §6.2.2
  *scheme* but is a placeholder; swap in the authoritative LoT-algorithm map.
- [ ] **Sensitivity disenrollment source** — only if you run
  `CENSOR_HORIZON_COL=ENDDATE_CE`: expose a death-independent disenrollment
  date and pass `DISENROLL_END_COL=<column>` for exact potential follow-up.
- [ ] **Cell-level suppression** — stratum-level `<25` suppression is applied;
  confirm whether cell-level masking inside reportable strata is required for
  external reporting.
- [ ] **Run-time strictness** — set `STRICT_LOT_DEDUP=TRUE` for production runs
  (unless the source LOT table is already unique per `(patient, LOT_NUM)`), and
  set `COHORT_EXPLORER_DIR` so the export self-validates (promotion is
  fail-closed without it).
