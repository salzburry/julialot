# study223926 — the analytical cohort, after the LOT run

An R package that turns a finished lines-of-therapy run into the analytical
cohort and variables the Aug 26 2026 protocol asks for. It builds no line and
no MM cohort of its own: `Jul 28/ndmm/` makes the population, `Jul 28/lot/`
makes the lines, and this reads both.

```
                ndmm/build.R          lot/engine/build.R        study223926/build.R
raw Optum CDM ──────────────► NDMM_COHORT ──────────► LOT_LONG_FINAL ──────────► S_*
```

Connection is **sparklyr**. On a Databricks cluster the Spark session already
exists and sparklyr attaches to it, so there is no DSN and no password:

```
Rscript build.R                                    # on the cluster
DRY_RUN=TRUE Rscript build.R                       # print the plan, touch nothing
MODULES=safety COHORTS=2L Rscript build.R          # one module, one cohort
Rscript tests/run_tests.R                          # 118 checks, no warehouse
```

`SPARK_METHOD=databricks_connect` drives a named cluster from outside and is
the only mode that needs `DATABRICKS_HOST`, `DATABRICKS_TOKEN` and
`SPARK_CLUSTER_ID`.

---

## The three things that make it selectable

**1. Every module is declared, not called.** `R/registry.R` holds one entry per
module: what it needs, what it writes, which code lists it cannot run without.
The runner works out the order. `MODULES=safety` pulls in `spine`, `cohorts`
and `periods` because safety needs them, and says so. `SKIP_MODULES=soc`
together with `MODULES=patterns` stops the run naming both, rather than
quietly producing a patterns table with no categories.

**2. Every cohort is declared too.** `COHORTS=1L,2L,3L,SEC2L`. A nested cohort
without its parent stops the run — 2L is *the subset of the 1L cohort*, so a 2L
built alone is a different population under the same name. The secondary 2L
cohort drops the other-cancer exclusion, because §7.8.1 says prior malignancy
is permitted there; `SEC2L_APPLY_OTHER_CANCER=TRUE` puts it back.

**3. Every open question is a setting.** The twenty-four entries in
`../OPEN_QUESTIONS.md` that change a number are config keys, defaulting to the
protocol's reading, and **every run records which reading it used** in
`S_RUN_METADATA.OPEN_QUESTION_READINGS`. A table that cannot say which reading
produced it cannot be reproduced from the table alone.

| setting | default | the alternative | question |
|---|---|---|---|
| `STUDY_START` | `2018-01-01` (§7.1 text) | `2016-01-01` (Figures 1 and 2) | Q1 |
| `MM_DX_OUTPATIENT_CODES` | `listed` | `strict` | Q2 |
| `MM_DX_OUTPATIENT_WINDOW_DAYS` | `90` | 30, 60 | Q3 |
| `FU_EVIDENCE_RULE` | `claim_from_index` | `claim_after_index`, `enrolled_on_index` | Q5 |
| `PRIOR_TX_DROP_STEROIDS` | `TRUE` | `FALSE` | Q6 |
| `SEC2L_APPLY_OTHER_CANCER` | `FALSE` | `TRUE` | Q7 |
| `REGION_SOURCE` | `state_crosswalk` | `region_column` | Q9 |
| `ED_DEFINITION` | `revenue,pos` | any of `revenue`, `pos`, `cpt` | Q11 |
| `CENSOR_AT_DISENROLLMENT` | `TRUE` (§7.1) | `FALSE` (the LOT engine's reading) | Q13 |
| `BASELINE_INCLUDES_INDEX` | `FALSE` (§7.1) | `TRUE` | Q14 |
| `COMORBIDITY_BASELINE_INCLUDES_INDEX` | `TRUE` (§7.8.1) | `FALSE` | Q14 |
| `ENROL_ATTR_AT` | `index_span` | `latest_span` | Q16 |
| `MONTHS_AS` | `days` | `calendar` | Q21 |
| `PREGNANCY_WINDOW` | `study_period` | `patient_period` | Q23 |

What the protocol states outright is **pinned** in `CONTRACT`
(`R/config_223926.R`): the 12-month baseline, the 30-day gap allowance, the
30-day post-discontinuation window, the 30-day acute washout, the 3-month
analysis-set rule, the 25-patient suppression floor, the two index floors and
the study end. Changing one needs `SETTINGS_OVERRIDE=TRUE`, and the deviation
lands on the run's own metadata row where no reader can miss it.

---

## Files

| path | what it does |
|---|---|
| `build.R` | Entry point. Loads `config.csv`, sources `R/`, calls `build_223926()`. |
| `config.csv` | Every setting as `name,value,description`. The environment beats the file. |
| `R/config_223926.R` | Settings, their validation, `CONTRACT`, and the readings a run records. |
| `R/registry.R` | The cohort and module registries, and the selection logic. |
| `R/windows.R` | The period algebra — every window and every boundary convention, once. |
| `R/person_time.R` | The counting rules: same-day collapse, chronic-once, the acute washout chain. |
| `R/suppression.R` | The 25-patient rule, and the complementary-disclosure check. |
| `R/codelists.R` | Code-list loading, the unfilled-row guard, and the preflight. |
| `R/lineage.R` | Refuses a LOT run it cannot vouch for. |
| `R/db_utils_223926.R` | sparklyr connection, logging, table naming, the step runner. |
| `R/run_223926.R` | Resolves the plan, walks the modules, writes the run metadata. |
| `R/modules/*.R` | One file per module. Nothing else defines a clinical rule. |
| `tests/run_tests.R` | 118 checks that need no warehouse, 40 of them regressions from the review below. |

## Modules

| key | writes | needs a code list |
|---|---|---|
| `spine` | `S_SPINE` — one row per patient per line, with the next line beside it | — |
| `cohorts` | `S_COHORT` | — |
| `attrition` | `S_ATTRITION` — the funnel, one row per criterion | — |
| `periods` | `S_PERIODS`, `S_LOT_PERIODS` — baseline, follow-up, treatment windows | — |
| `demographics` | `S_DEMOGRAPHICS` — age, sex, region, race, ethnicity, insurance | — |
| `comorbidity` | `S_COMORBIDITY` — Charlson (Quan 2011), MM-adjusted | `charlson_quan2011.csv` |
| `soc` | `S_SOC` — regimen category per line | `soc_regimen_categories.csv` (Annex 2) |
| `safety` | `S_SAFETY_EVENTS`, `S_SAFETY_RATES` | `safety_events.csv` (Annex 3) |
| `hcru` | `S_HCRU_EVENTS`, `S_HCRU_RATES` | `hcru.csv` |
| `malignancy` | `S_MALIGNANCY`, `S_MALIGNANCY_RATES` | `secondary_malig.csv` (Annex 3) |
| `tte` | `S_TTE` — TTNT, TTD, OS | — |
| `patterns` | `S_PATTERNS`, `S_SWITCH`, `S_TX_ATTRITION` | via `soc` |

**Six of the twelve run today.** `MODULES=spine,cohorts,attrition,periods,demographics,tte`
builds all four cohorts, every window, the demographics and the time-to-event
outcomes, and needs no code list this repo does not already have. The other six
are blocked on Annexes 2 and 3 (`../CODELISTS.md`), and the preflight says so
by name **before** the connection is opened rather than after the expensive
steps.

## What it refuses to do

A module that is asked for and cannot run **stops the run**. It never returns an
empty table.

- a code list with an unfilled row → stops, naming the concepts, because *"a
  rate for them would be zero for want of a code list rather than for want of
  events"* and nothing downstream can tell those apart;
- a code list whose `icd_family` is spelled something unrecognised → stops,
  because such a row joins to nothing and silently stops excluding anyone;
- a code list that types one of §7.8.1's named chronic conditions as acute →
  stops, because every recurrence would then be counted and no patient would
  ever leave the denominator;
- a LOT run that is not `complete`, was built over a different cohort, carries
  contract deviations, disagrees about `STUDY_END`, or predates the 2026-08-30
  rule change (`LOT_RULES.md`: *"LOT numbers produced before that date are
  superseded"*) → stops;
- a step that produces zero rows → stops;
- attrition categories that stop partitioning their denominator → stops.

## Three protocol readings worth knowing about

**TTD's event is a union.** The protocol's footnote defines discontinuation as
*all MM agents stopped **or** a new agent **or** a qualifying SCT*. The engine
spells those as three different `LOT_BASE_END_REASON` values, so
`IS_PROTOCOL_DISCON` on the spine unions `DISCONTINUATION`, `MED_ADD`,
`CART_INIT` and the `SCT_*` reasons. Reading the column literally would
undercount TTD badly.

**The washout is between counted events, not observed ones.** Events on days 0,
20 and 40 with a 30-day washout are **two** counted events, not one — `lag()`
gives one, because it compares each event with its predecessor rather than with
the last one that counted. `R/person_time.R` runs a greedy chain; both readings
are implemented and the tests hold them apart.

**Prevalence and incidence have different denominators.** Baseline prevalence
divides by the baseline window's person-time *"irrespective of prior event
history"*; on-treatment incidence drops a chronic condition's prior-history
patients from **both** the numerator and the denominator. A module that
computed one denominator and used it twice would be wrong in a way no total
would reveal.

## What the adversarial review changed

The first version of this package was reviewed at max effort, and **19 defects
were confirmed**. All are fixed, and each has a regression test — the review's
own observation stands: the 78-check suite that passed at the time covered none
of them. The ones worth knowing about, because they would have produced numbers
rather than errors:

| what | what it would have done |
|---|---|
| No module cleared its rows before writing | a second run **doubled every count, person-year and rate** with no error, against a header promising "re-run as often as needed" |
| The lineage guard's `checkable` flag was always `FALSE` | a LOT run that was incomplete, built over another cohort, contract-deviating or **superseded by the 2026-08-30 rule change** was read and logged as accepted |
| `LIKE '%acute%'` and `LIKE '%chronic%'` both match "Acute or chronic" | the two conditions Table 3 types that way were counted **through both counting rules at once** |
| The nested-cohort join did not require the parent's `IN_COHORT` | 2L contained patients **absent from the 1L cohort it is nested in** |
| `OS_DT` was not clipped to `FU_END` | a patient who disenrolled in 2020 and died in 2022 contributed **two unobserved years as followed time**, and a death outside the window as an observed event |
| `S_TTE` was joined on `LOT_NUM` for per-line death | everyone who died after line 2 or 3 was drawn on the Sankey as having **stopped therapy alive** |
| Malignancy's denominator was the cohort total | every per-line incidence was understated **roughly fourfold** |
| Malignancy never applied the chronic rule its own comment stated | prior-malignancy patients stayed in the at-risk denominator for **Primary Objective 3** |
| SOC used `max()` over category names | a CAR-T line was categorised **alphabetically** — `Doublet/monotherapy` sorts above `CAR-T` |
| The code-list view chunked itself into `SELECT * FROM v UNION ALL …` | any list over 500 rows defined a **view in terms of itself** |
| `X2_other_cancer` was tested against the cohort's own criteria only | 2L and 3L were treated as **permitting a prior malignancy** |
| `INDEX_EXCLUDED_ABBRS` was recorded on every run and read by nothing | the panobinostat and elotuzumab bars were **reported as applied while applying nothing** |

Four of those twelve the review did not find — the self-referencing view, the
acute/chronic double count, the dead index setting, and a non-equality
correlated subquery Spark rejects. The rest are its findings.

Six further defects are fixed the same way: an undeclared code list defeating
the preflight, a QC whose first column was a string so `run_step`'s zero-row
guard was skipped, a blank `icd_family` silently read as ICD-10, `S_ATTRITION`
promised in the plan and never written, an unconditional full CDM scan under a
setting that never reads it, and the missing ninth condition in the §7.8.1
chronic cross-check.

Two things are deliberately left as they are: `MEDIAN_LOS` uses
`percentile_approx`, and Quan's hierarchy is applied only where
`charlson_quan2011.csv` carries a `supersedes` column — without it the run
**says so** rather than silently summing mild and severe liver disease together.

## What this is not

It is not wired into `validation/run_gate.R`, and it has never been run against
the warehouse — no code lists, and several settings still want the study team's
answer (`../OPEN_QUESTIONS.md`). The 118 tests check the selection logic, the
boundary conventions, the counting rules and the SQL each module emits. They
check no number, because a number needs the CDM.
