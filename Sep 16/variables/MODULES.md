# The variables package — how it works

An R package that turns a finished lines-of-therapy run into the analytical
cohorts and variables the 26 August 2026 protocol asks for. It builds no line
and no MM cohort of its own: the cohort build makes the population, `lot/`
makes the lines, and this reads both and writes only its own `S_*` tables.

```
                cohort build          lot/engine/build.R        build.R
raw Optum CDM ──────────────► NDMM_COHORT ──────────► LOT_LONG_FINAL ──────────► S_*
```

How to run it, the connection modes and the schema a run writes into are in
`CONTENTS.md`. Every setting is in `config.csv` with what it does, except
`MM_HOSP_POSITION` (Q27), which is read from the environment only and
defaults to `confinement`.

A partial run - one module, one cohort - writes only that, and leaves every
other table and every other cohort's rows under the prefix as the previous
run left them. Its `S_RUN_METADATA` row records the modules and cohorts it
did write, and the dashboard and its snapshot job show a run only those: a
table its metadata does not claim, or rows of a cohort it did not select,
are whatever an earlier run left under the prefix.

---

## The three things that make it selectable

**1. Every module is declared, not called.** `R/registry.R` holds one entry per
module: what it needs, what it writes, which code lists it cannot run without.
The runner works out the order. `MODULES=safety` pulls in `eligibility`,
`spine`, `cohorts` and `periods` because safety needs them, and says so.
`SKIP_MODULES=soc` together with `MODULES=patterns` stops the run naming both,
rather than quietly producing a patterns table with no categories.

**2. Every cohort is declared too.** `COHORTS=1L,2L,3L,SEC2L` (the config
default is `1L,2L,3L`; `SEC2L` is opt-in). A cohort's entry names the line it
indexes on, the cohort it is nested in, its index floor and its criteria.

**Nesting is a setting, not structure.** `COHORT_NESTED=TRUE`, the default, is
§7.2.1 read literally: 2L is the subset of 1L who initiate a second line, and
3L the subset of 2L. That requirement is what makes a 1L index outside the
index window cost the patient their 2L and 3L rows too, and an analysis of
second-line initiators does not always want it. `COHORT_NESTED=FALSE` lets
each line stand on its own index. Every `S_COHORT` row carries `NESTED`
saying which way the run went. The selection follows the setting: with
nesting on, `COHORTS=2L` without `1L` is refused, because a nested cohort built
without its parent is a different population under the same name; with it
off, `COHORTS=2L` builds on its own. The refusal names the setting that would
allow it.

**3. Every open question is a setting.** Each reading the protocol leaves open
is a config key defaulting to the protocol's reading, and **every run records
which reading it used** in `S_RUN_METADATA.OPEN_QUESTION_READINGS`. A table
that cannot say which reading produced it cannot be reproduced from the table
alone. `OPEN_QUESTIONS.md` lists each question with its setting.

What the protocol states outright is **pinned** in `CONTRACT`
(`R/config_223926.R`): the 12-month baseline and 12-month pre-index
enrolment, the 30-day gap allowance, the 30-day post-discontinuation window,
the 30-day acute washout, the 3-month analysis-set rule, the 25-patient
suppression floor, the two index floors (1L from 2019-01-01, secondary 2L from
2020-01-01) and the study end. Changing one needs `SETTINGS_OVERRIDE=TRUE`,
and the deviation lands on the run's own metadata row
(`CONTRACT_DEVIATIONS`) where no reader can miss it.

---

## Modules

| key | writes | needs a code list |
|---|---|---|
| `eligibility` | `S_ELIGIBILITY` — one row per patient, the cohort build's verdict. **No line of therapy.** | — |
| `spine` | `S_SPINE` — one row per patient per line, with the next line beside it | — |
| `cohorts` | `S_COHORT` — a patient combined with a line | — |
| `attrition` | `S_ATTRITION` — the funnel: one row per criterion, under the one or two rows that say where the cohort's population came from | — |
| `periods` | `S_PERIODS`, `S_LOT_PERIODS` — baseline, follow-up, treatment windows; the diagnosis date (`DX_DT`, chosen by `DX_DATE_SOURCE` and recorded in `DX_DT_SOURCE`, Q30) and what hangs on it — `DX_YEAR`, `INDEX_YEAR`, diagnosis→index and diagnosis→follow-up-end, prior LOT→next LOT | `mm_dx.csv` only under `DX_DATE_SOURCE=baseline_first_claim` |
| `demographics` | `S_DEMOGRAPHICS` — age (at index and at diagnosis), sex, region, race, ethnicity, insurance, from the enrolment row covering the index or else the baseline row nearest it (`ATTR_SOURCE`) | — |
| `comorbidity` | `S_COMORBIDITY` — Charlson (Quan 2011), MM-adjusted. With `FRAILTY=TRUE` also `S_FRAILTY`; with `COMORBID_SUBGROUPS=TRUE` also `S_COMORB_SUBGROUP` | `charlson_quan2011.csv`, `mm_dx.csv`; plus `frailty_kim2018.csv` (Annex 7) and `comorbid_subgroups.csv` (Annex 3) when those switches are on |
| `soc` | `S_SOC` — regimen category per line, with the line's start year and the engine's transplant flags and transplant year (Table 6's SCT by year by SOC is a count over it) | `soc_regimen_categories.csv` (Annex 2) |
| `safety` | `S_SAFETY_EVENTS`, `S_SAFETY_COUNTED`, `S_SAFETY_RATES` — baseline prevalence and on-treatment incidence, counted the same way: one acute washout chain per cohort over the whole timeline (kept under `PERIOD = TIMELINE`, Q34), inpatient-defined conditions from admissions, a `(hospitalisation)` series per chronic condition, and an `(any in domain)` aggregate row per domain | `safety_events.csv` (Annex 3) |
| `hcru` | `S_HCRU_EVENTS`, `S_HCRU_RATES` — all-cause and MM-related hospitalisation, length of stay, emergency visits | `hcru.csv`, `mm_dx.csv` |
| `malignancy` | `S_MALIGNANCY` (with `AFTER_INDEX`), `S_MALIGNANCY_DATES` — every qualifying date, not only the first — `S_MALIGNANCY_RATES` with its interval and an `(any malignancy)` aggregate category, and `S_MALIGNANCY_SEQUENCES` (three readings on `LINES`, Q32) where `soc` ran | `secondary_malig.csv` (Annex 3); `mm_dx.csv`, read only to refuse a myeloma code |
| `tte` | `S_TTE` — TTNT, TTD, OS | — |
| `patterns` | `S_PATTERNS`, `S_SWITCH`, `S_TX_ATTRITION` | via `soc` |
| `release` | `S_*_RELEASE` — every rate and percentage table with cells under 25 patients suppressed | — |

`CODELISTS.md` §4 has every code list's columns and checks.

### What runs today

`MODULES=all`, the default, runs everything that has a usable code list.
`eligibility`, `spine`, `cohorts`, `attrition`, `periods`, `demographics` and
`tte` need none, so they always run: the cohorts `COHORTS` names, every
window, the demographics and the time-to-event outcomes. The other seven are
blocked on Annexes 2 and 3 (`CODELISTS.md`) and are **left out by name** - in
the plan, in the log and in `S_RUN_METADATA`, so the dashboard reports them as
not run - rather than stopping the run. Naming a module in `MODULES` asks for
it: then its list is required, and the run stops before the connection is
opened, saying which file and which annex.

The preflight **loads** each list the selected modules need rather than
checking that its path exists, and runs each list-driven module's own check of
its list against the settings - an ED definition the HCRU list has no rows
for, a SOC category the protocol does not name, a safety condition defined by
an admission but not typed `inpatient`, a myeloma code on the malignancy list.
So a list a module would refuse is found before the connection is opened, not
after the modules before it have run.

### The rate tables are stratified

`S_SAFETY_RATES`, `S_HCRU_RATES`, `S_MALIGNANCY_RATES` and `S_TX_ATTRITION`
carry a `SOC_CATEGORY` and an `AGE_GROUP` column. Each table is written once for
the line as a whole — `(all categories)` and `(all ages)` — then once per
regimen category where the `soc` module ran, and once per age group. Every pass
is the same query with one more column in the `GROUP BY`, so the washout, the
person-time, the at-risk rule and the confidence intervals are unchanged and
each stratification is a partition of the line. `mod_patterns()` checks that
both sum back to it and stops if either does not.

**Margins, not a cross.** A row is cut by regimen category or by age, never by
both: no table the protocol asks for crosses them, and every cell of the cross
would fall under the floor. A query naming a real value in both columns finds
no row.

**Anything reading these tables must say which grouping it wants**, or it sees
the line and its parts together and double counts. `WHERE SOC_CATEGORY =
'(all categories)' AND AGE_GROUP = '(all ages)'` selects the line as a whole.

**`AGE_GROUP` is not `AGE_BAND`.** `S_DEMOGRAPHICS` carries both: `AGE_BAND` is
Table 1's descriptive distribution, four bands wide, and `AGE_GROUP` is the
protocol's stratification — `<75` and `75+`, stratification 2 in
`VARIABLES.md`. The rate tables are grouped by the second, because a rate is
not the sum of its strata's rates.

Two labels distinguish a gap from a value. `(uncategorised)` is a line the
`soc` module wrote no row for; `(no demographics row)` is a patient the
`demographics` module wrote none for. Neither is `Unknown`, which that module
writes as a real age group for a patient whose age it could not read.

### Suppression is applied in one place

*"Stratifications with < 25 patients will not be performed"* (§7.2.3).

The `release` module applies it in SQL, testing each row's population
(`N_AT_RISK` on the rate tables). It does not overwrite the raw tables — each
suppressed table is written beside its source as `S_*_RELEASE`, so QC can still
read the counts behind a rate while the thing that leaves the warehouse cannot.
The suppressed count is nulled along with the values, because publishing the
*n* a suppressed rate was computed from suppresses nothing. The rule exists
only in that SQL, and it carries no exemption for §7.8's *"(unless specific to
SOC)"* - `OPEN_QUESTIONS.md` Q29.

The raw `S_*` tables are read outside the warehouse in two places, both
controlled outputs rather than releases: the QC report, and the dashboard's
snapshot job, which exports every `S_*` table and the LOT tables to a
directory the app reads. That directory is patient-level data and is handled
as such; the app shows the `_RELEASE` form where one exists.

Stratification makes more cells fall under the floor. Where exactly one
stratum of a group is suppressed, the total less the published rest gives it
away, so `mod_release()` warns and the run records the finding twice:

- `S_RUN_METADATA.RELEASE_RECOVERABLE`, in words — the table and the grouping,
  or `none`, or `release module did not run`, which is a third answer and not
  the second: a run without the module has not looked.
- `S_RUN_METADATA.RELEASE_RECOVERABLE_TABLES`, the same finding as a
  semicolon-separated list of table names, which TFLS and the dashboard
  refuse on. It is empty both where there is nothing to name and where the
  module did not run, so an empty list never narrows a refusal: a reader that
  sees none falls back to the sentence.

Whether to regroup or withhold a second stratum stays the analyst's call.

### What this package writes, as data

`R/contract.R` emits one row per table the package can write — the module that
writes it, whether the release module publishes a suppressed copy, and the
switch that has to be on for it. TFLS ships the generated copy and reads it
instead of restating the registry, and its suite regenerates from here and
compares line for line whenever this package is beside it. Regenerate with
`write_study_contract(path)` after adding a table to `MODULES` or
`SUPPRESSION_SPEC`. `S_RUN_METADATA.STUDY_CONTRACT_MD5` records the contract a
run was written under.

### The MM adjustment is made on the codes

Table 4 asks for the CCI *"adjusted for having received a MM diagnosis, such
that a value of 0 indicates no additional comorbidities beyond MM"*.

Quan's seventeen conditions have no myeloma row: myeloma is one of the codes
under `any_malignancy`, together with every other cancer. So the adjustment is
made on the **codes**: a diagnosis whose code is in `mm_dx.csv` supports no
Charlson condition. A patient with only MM scores 0; a patient with MM and
breast cancer still scores `any_malignancy`, because the breast code carries
it. That is why `comorbidity` declares `mm_dx.csv`.

Quan's hierarchy (severe over mild liver disease, diabetes with over without
complications, metastatic solid tumour over any malignancy) is applied from the
`supersedes` column of `charlson_quan2011.csv`. A file without that column is
summed flat, and the run logs that it did.

### Two switches, both off

`FRAILTY` (the Kim 2018 claims-based frailty index) and `COMORBID_SUBGROUPS`
(Table 4's neuropathy and lung-parenchymal-disease flags) are off by default,
because both need code lists that carry no codes yet — Annex 7's and Annex 3's.
Switched on, the switch adds its list to what `comorbidity` needs: under
`MODULES=all` the module is left out naming the annex, and a run that named it
stops. Asking for frailty therefore says exactly what is missing, rather than
producing a column of zeros that reads as a cohort with no frail patients.

### Counting rules, as implemented

§7.8.1's rules — same-day claims are one event, a ≥ 30 day washout between
acute events, a chronic condition counted once — apply to **both** baseline
prevalence and on-treatment incidence, through the same machinery
(`R/person_time.R`). The protocol's wording is quoted in `VARIABLES.md`
"Counting rules".

- **The washout is between counted events, not observed ones.** Events on days
  0, 20 and 40 with a 30-day washout are **two** counted events — `lag()` would
  give one, because it compares each event with its predecessor rather than
  with the last one that counted. `R/person_time.R` runs a greedy chain, once
  per cohort over the patient's timeline (Q34).
- **Prevalence and incidence have different denominators.** Baseline
  prevalence divides by the baseline window's person-time *"irrespective of
  prior event history"*, so nobody leaves it and a chronic first occurrence
  counts for everyone. On treatment, a patient with prior history of a chronic
  condition is out of **both** the numerator and the denominator, and
  `N_AT_RISK` on the rates table says how many were left.
- **TTD's event is a union.** The protocol's footnote defines discontinuation
  as *all MM agents stopped **or** a new agent **or** a qualifying SCT*. The
  engine spells those as different `LOT_BASE_END_REASON` values, so
  `IS_PROTOCOL_DISCON` on the spine unions `DISCONTINUATION`, `MED_ADD`,
  `CART_INIT` and the `SCT_*` reasons; the date that goes with each is Q33.
  Reading the column literally would undercount TTD badly.

---

## Two roots, and what combines them

`eligibility` and `spine` are independent: neither needs the other.

Eight of the eleven criteria are settled before this package runs — I1 to I4
and X1 to X4 — and arrive as flags on `INPUT_COHORT_TABLE`. None of them needs
a line, an index date from LOT, or anything the engine produces. `eligibility`
reads them into `S_ELIGIBILITY`, one row per patient, and **it is the only
module that reads `INPUT_COHORT_TABLE`.** Everything downstream reads the
eligibility layer instead, so the upstream table is touched in one place.
`S_ELIGIBILITY.EVIDENCE` says whether the exclusion verdicts came from flags on
the input or from a pre-filtered input that carried none.

`spine` is the LOT engine's lines, with no cohort join and no date filter.

**The run builds only what its own modules read.** The LOT lineage proof
follows `spine` (the one module that reads the LOT tables, and everything
needing lines needs it); the enrolment spans follow `cohorts` or `periods`;
the medical and pharmacy claim scan runs only under
`FU_EVIDENCE_RULE=claim_after_index`. So `MODULES=eligibility` prepares none of
them and proves no lineage, and runs where no LOT status table exists.

Only three criteria are line-relative by definition — I5 (follow-up from the
line's index), N1 (received *this* line) and N2 (enrolment before *this* line's
index) — and they live in `cohorts`, which is where a patient and a line are
combined. That is the first module needing both roots. Who applies each
criterion, and how to change one, is `IE_CRITERIA_APPLIED.md`.

**Every row says what its own verdict is over.** `CRITERIA_ASKED` is the
list the cohort is **judged on**, which is not quite the list `IN_COHORT` is
*computed* from: `I1`–`I3` are on the 1L list and have no predicate here,
because the cohort build applied them and a patient on the input passed them
by being there. So 1L's `CRITERIA_ASKED` names nine while `IN_COHORT` is the
AND of the rest. `S_ATTRITION.APPLIED_BY` says where each step's verdict came
from.

It has to be on the row because it differs by cohort: 1L and SEC2L are judged
on nine criteria, 2L and 3L on three — `N1`, `N2`, `I5` — so `MET_X1`–`MET_X4`
sit on a 2L row *without being part of its verdict*, and SEC2L drops `X2`
under the shipped default. An analyst ANDing the `MET_*` flags would reproduce
1L and get a different cohort at 2L, 3L and SEC2L. Use `IN_COHORT`;
`CRITERIA_ASKED` says what it means.

### The input cohort table

`check_cohort_table()` runs before the first module whenever `eligibility`
runs. It refuses:

- a table missing a column the package reads: `PATID`, `INDEX_DATE`,
  `ENDDATE`, `ENDDATE_CE`, `DEATH_DT`, `MM_DX_DT`, `YRDOB`, `GDR_CD`. A table of
  patient ids and eligibility flags carries none of them and cannot drive the
  run;
- **more rows than patients**, or a NULL `PATID`. The package reads the table as
  one row per patient; a duplicate multiplies that patient through every join,
  so the cohort counts come out high and nothing downstream notices;
- **an exclusion flag that is NULL or not 0/1.** The membership predicate is
  `coalesce(flag, 1) = 1`, which reads a NULL as eligible. On a table this check
  accepted, that coalesce cannot fire.

It accepts two shapes. A **pre-filtered** table has already had X1–X4 applied
and may carry no flag at all: a criterion whose flag is absent was applied
upstream, its funnel step shows no loss, and `APPLIED_BY` says so. A **wide**
table keeps the patients who fail an exclusion and carries each verdict as a
flag, which each cohort then applies for itself:

| criterion | flag |
|---|---|
| X1 prior MM therapy | `NO_PRIOR_MM_TX` |
| X2 other cancer | `NO_OTHER_CANCER_PRE_LOT1` |
| X3 pregnancy | `NO_PREGNANCY` |
| X4 belantamab before the 1L index | `NO_BELANTAMAB_PRE_LOT1` |

The cohort build's own `NDMM_COHORT` is the pre-filtered shape.

### The secondary 2L cohort needs a wide input

§7.4.1.1 wants every 2L initiator from 01 Jan 2020 *"irrespective of whether
their 1L initiation occurred during the primary cohort ascertainment period"*,
and §7.8.1 permits a prior malignancy (Q7). Every cohort here is an inner join
onto `INPUT_COHORT_TABLE`, and the cohort build's `NDMM_COHORT` has the
other-cancer exclusion and the 1L index floor already applied, with the LOT
run built over that same population. Built from it, SEC2L would be nested in
the primary cohort, and its baseline malignancy prevalence — the number the
cohort exists to produce — would be zero by construction.

So SEC2L needs a **wide cohort input**: a cohort table, and a LOT run over it,
built without the other-cancer exclusion and without the 1L index floor, that
still carries

- the full cohort schema this package reads — `INDEX_DATE`, `ENDDATE`,
  `ENDDATE_CE`, `DEATH_DT`, `MM_DX_DT` and the demographics (`YRDOB`,
  `GDR_CD`), one row per patient (the LOT engine's own input check asks for
  `AGE_INDEX_YR`, `FU_DAYS` and `FU_DAYS_CE` as well);
- the eligibility evidence retained per patient: all four flags in the table
  above, as 0/1, so each cohort applies its own criteria. The primary 1L cohort
  still excludes on `NO_OTHER_CANCER_PRE_LOT1` and the others, 2L and 3L inherit
  that through nesting, and SEC2L drops X2.

No stage of the pipeline builds that table; it is a cohort build to write, not
a setting to flip.

**`NDMM_FLAGS_ALL` cannot stand in.** The cohort build's flag table is one row
per 1L candidate with `PATID` and seven flags — the four above,
`NO_BELANTAMAB`, and two enrolment checks — and none of the dates or
demographics the modules read; its candidates already meet the 1L index floor
as well. Pointed at it,
`check_cohort_table()` stops at the first step naming the missing columns,
rather than a module failing later on an unresolved column, and the LOT
engine's input check refuses it too.

**What the package refuses.** Selecting `SEC2L` stops the run, before the
connection is opened, unless one of two settings says how to proceed:

- `SEC2L_INPUT_IS_WIDE=TRUE` **asserts** that `INPUT_COHORT_TABLE` and its LOT
  run were built without the other-cancer exclusion and without the 1L index
  floor. Only whoever built the table knows that, so it is an assertion, not a
  test: the package cannot see what an upstream build left out. What it does
  check is that the table carries all four exclusion flags — a wide table
  missing any of them stops the run, because the patients it kept would
  otherwise enter every cohort, the primary 1L cohort included. SEC2L is then
  built without X2.
- `SEC2L_APPLY_OTHER_CANCER=TRUE` builds the nested version knowingly, with X2
  applied; the run records the setting among its readings.

Both settings are recorded in `S_RUN_METADATA.OPEN_QUESTION_READINGS`.

### An upstream reading is recorded as verified or as an assertion

Eight settings are the cohort build's rules, not this package's: `STUDY_START`,
`MM_DX_OUTPATIENT_CODES`, `MM_DX_OUTPATIENT_WINDOW_DAYS`,
`PRIOR_TX_DROP_STEROIDS`, the three `OTHER_CANCER_*` settings and
`PREGNANCY_WINDOW`. Recording this package's own value alone would assert a
reading nothing had checked, so `OPEN_QUESTION_SOURCE` marks each reading
`here` or `upstream`.

`NDMM_RUN_METADATA.CONTRACT_SETTINGS` is the cohort build's whole contract as
`k=v|k=v`, written by the run that made the cohort. `read_upstream_settings()`
reads it, so `STUDY_START` and `MM_DX_OUTPATIENT_WINDOW_DAYS` are recorded as
what the cohort was actually built with (`upstream, verified`). The rest are
fixed in that build's code rather than its contract, so they stay marked
`(upstream, unverified)`.

What happens on a disagreement depends on the setting. The study period — both
ends — and the 1L index floor are `BINDING_UPSTREAM_SETTINGS`: they are what the
cohort IS, so a disagreement **stops the run** unless `SETTINGS_OVERRIDE` says
to go on, and then it is a recorded deviation. The rest, the outpatient window
among them, only shape a criterion's reading: the run names the disagreement,
records both values, and carries on. How a cohort setting is changed on the
cohort side is `../ndmm/README.md` "Settings".

Each `here` setting is held to its SQL by the suite, which emits the whole run
at its default and at an alternative and requires the SQL to differ, so a
setting cannot be recorded as a reading while applying nothing.

---

## The output prefix, and why a reused one stops the run

`OBJECT_PREFIX` selects the namespace this package writes into. Before writing
any table it compares the declared schema — ordered column names and types —
against what is already there, and **stops if they differ, before clearing a
single row**. There is no automatic migration: a prefix written by a different
version of this package stops the run, and the answer is to drop its `S_*`
tables or run against a fresh prefix.

The check is strict because the inserts are positional:

* a table that gained a column would fail on the count, after the delete;
* a table whose column was renamed accepts the insert and keeps the old name
  with the new meaning, and nothing fails;
* a narrower stored type silently truncates. `float` is not `double` — single
  precision turns 16,777,217 into 16,777,216 — and a bounded `varchar(n)` is
  not an unbounded `string`, because it rejects an over-length write once the
  scope has already been cleared.

Genuine spellings of one type still match: `varchar` and `string`, `integer`
and `int`, `double precision` and `double`. A type the check does not recognise
is treated as a mismatch, and a `DESCRIBE` that returns no type column stops
rather than comparing names alone.

## What it refuses to do

A module that is asked for and cannot run **stops the run**. It never returns an
empty table.

- a code list with an unfilled row → stops, naming the concepts, because *"a
  rate for them would be zero for want of a code list rather than for want of
  events"* and nothing downstream can tell those apart;
- a code list whose `icd_family` is blank or spelled something unrecognised →
  stops, because such a row joins to nothing and silently stops counting
  anyone;
- a code list that types one of §7.8.1's named chronic conditions as acute, or
  a condition typed both ways → stops, because every recurrence would then be
  counted and no patient would ever leave the denominator;
- an input cohort table of the wrong shape, or `SEC2L` selected without a wide
  input or `SEC2L_APPLY_OTHER_CANCER=TRUE` → stops (above);
- a cohort whose study period or 1L index floor disagrees with this run's →
  stops unless `SETTINGS_OVERRIDE=TRUE` (above);
- a cohort build that barred fewer of the agents in `COHORT_INDEX_EXCLUSIONS`
  (default panobinostat and elotuzumab) from setting the 1L index than §7.2.1.1
  names → stops. The names are resolved to abbreviations through
  `cl_mma_rollup.csv`; where that list or the build's `INDEX_EXCLUDED` record is
  unavailable, the check is logged as unverified rather than failed;
- a LOT run that is not `complete`, was built over a different cohort or a
  different attempt of it, carries contract deviations, was built by code other
  than `LOT_CODE_MD5` where that is set, or finished on or before
  `LOT_RULES_EPOCH` (shipped as `2026-09-22`, the date the LOT rules last
  changed; a run finished on that date itself is refused too) → stops. The
  suite fingerprints the engine's R and shipped settings beside this package
  and checks both against the pin the date sits with, so a rule change cannot
  pass without the date being moved. The lineage is checked again before the
  run is recorded complete, so a LOT rebuild landing mid-run fails it;
- a step that produces zero rows → stops;
- attrition categories that stop partitioning their denominator, or strata that
  stop summing to their line → stops.

`LOT_ALLOW_UNPROVEN_LINEAGE=TRUE` lets a run go on over a lineage it could not
read; a lineage it read and found wrong is never waived.

## Inside the runner

**The statement splitter tracks all three quote characters.** Spark's `sql()`
takes one statement, so templates written as a `CREATE` plus an `INSERT` are
split on semicolons outside quotes and comments — `'`, `"` and backtick, each
closing on itself, doubled meaning escaped. A statement that is only comments
and whitespace is dropped rather than sent.

**A build in a session inherits nothing from the one before it.** The config,
the code-list manifest and the input table's columns are cleared by
`reset_run_state()` at the top of `build_223926()`, so a second build cannot
report an md5 for a file it never opened, or apply an exclusion flag its own
input does not carry. The config lives in a private environment rather than a
global `cfg`, because the LOT engine keeps its own config under that name.

## What the tests cannot check

The list-driven modules have not run against the warehouse, because their code
lists do not exist yet, and several settings still want the study team's
answer (`OPEN_QUESTIONS.md`). The suite (`CONTENTS.md` "Running it") runs every
module for every cohort, parses every statement, and executes them against
fixtures. What it cannot check is a number from the CDM itself: a fixture that
agrees with the code is not the warehouse agreeing with it.
