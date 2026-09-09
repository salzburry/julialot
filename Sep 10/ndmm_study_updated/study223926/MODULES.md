# study223926 — the analytical cohort, after the LOT run

An R package that turns a finished lines-of-therapy run into the analytical
cohort and variables the Aug 26 2026 protocol asks for. It builds no line and
no MM cohort of its own: `Jul 28/ndmm/` makes the population, `Sep 10/lot/`
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
Rscript tests/run_tests.R                          # 173 checks, no warehouse
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
| `R/codelists.R` | Code-list loading, the unfilled-row guard, and the preflight. |
| `R/lineage.R` | Refuses a LOT run it cannot vouch for, and reads back what the cohort build applied. |
| `R/db_utils_223926.R` | sparklyr connection, logging, table naming, the step runner. |
| `R/run_223926.R` | Resolves the plan, walks the modules, writes the run metadata. |
| `R/modules/*.R` | One file per module. Nothing else defines a clinical rule. |
| `tests/run_tests.R` | 173 checks that need no warehouse. The last sections RUN every module for every cohort, parse every statement they emit, and **execute** them against fixtures. |
| `tests/emit_sql.R` | The harness. Stubs only what touches Spark, so a module's R and its SQL are both exercised without a cluster. |
| `tests/parse_sql.py` | Parses each captured statement in the Spark dialect (sqlglot). |
| `tests/run_duckdb.py` | **Executes** them: transpiles to DuckDB, runs against `tests/fixtures/cdm`, checks 58 golden numbers, then runs the whole script again and checks nothing doubled. |
| `tests/expectations.py` | Those golden numbers. `tests/fixtures/EXPECTED.md` derives every one by hand. |
| `tests/fixtures/` | Six synthetic patients, chosen so each makes a protocol rule visible, and filled miniatures of all eleven code lists. Test data — not codes to use. |

## Modules

| key | writes | needs a code list |
|---|---|---|
| `spine` | `S_SPINE` — one row per patient per line, with the next line beside it | — |
| `cohorts` | `S_COHORT` | — |
| `attrition` | `S_ATTRITION` — the funnel, one row per criterion | — |
| `periods` | `S_PERIODS`, `S_LOT_PERIODS` — baseline, follow-up, treatment windows | — |
| `demographics` | `S_DEMOGRAPHICS` — age, sex, region, race, ethnicity, insurance | — |
| `comorbidity` | `S_COMORBIDITY` — Charlson (Quan 2011), MM-adjusted. With `FRAILTY=TRUE` also `S_FRAILTY`; with `COMORBID_SUBGROUPS=TRUE` also `S_COMORB_SUBGROUP` | `charlson_quan2011.csv`, `mm_dx.csv`; plus `frailty_kim2018.csv` (Annex 7) and `comorbid_subgroups.csv` (Annex 3) when those switches are on |
| `soc` | `S_SOC` — regimen category per line | `soc_regimen_categories.csv` (Annex 2) |
| `safety` | `S_SAFETY_EVENTS`, `S_SAFETY_COUNTED`, `S_SAFETY_RATES` — baseline prevalence and on-treatment incidence, counted the same way | `safety_events.csv` (Annex 3) |
| `hcru` | `S_HCRU_EVENTS`, `S_HCRU_RATES` | `hcru.csv`, `mm_dx.csv` |
| `malignancy` | `S_MALIGNANCY`, `S_MALIGNANCY_RATES` | `secondary_malig.csv` (Annex 3) |
| `tte` | `S_TTE` — TTNT, TTD, OS | — |
| `patterns` | `S_PATTERNS`, `S_SWITCH`, `S_TX_ATTRITION` | via `soc` |
| `release` | `S_*_RELEASE` — every rate and percentage table with cells under 25 patients suppressed | — |

**Six of the thirteen run today.** `MODULES=spine,cohorts,attrition,periods,demographics,tte`
builds all four cohorts, every window, the demographics and the time-to-event
outcomes, and needs no code list this repo does not already have. The other six
are blocked on Annexes 2 and 3 (`../CODELISTS.md`), and the preflight says so
by name **before** the connection is opened rather than after the expensive
steps.

### The MM adjustment, and why it is on the codes

Table 4 asks for the CCI *"adjusted for having received a MM diagnosis, such
that a value of 0 indicates no additional comorbidities beyond MM"*.

Quan's seventeen conditions have no myeloma row. Myeloma is one of the codes
**under `any_malignancy`**, together with every other cancer — so dropping a
condition whose *name* matches myeloma drops nothing, and every patient in a
myeloma study scores `any_malignancy`'s weight of 2. A CCI of 0 becomes
unreachable and the adjustment is silently not made.

So it is made on the **codes**: a diagnosis whose code is in `mm_dx.csv`
supports no Charlson condition. A patient with only MM scores 0; a patient with
MM and breast cancer still scores `any_malignancy`, because the breast code
carries it. That is why `comorbidity` declares `mm_dx.csv`.

### Two switches, both off

`FRAILTY` (the Kim 2018 claims-based frailty index) and `COMORBID_SUBGROUPS`
(Table 4's neuropathy and lung-parenchymal-disease flags) are both off by
default, because both need annexes that were not delivered — Annex 7 and Annex
3. Switched on, the code-list preflight stops the run naming the annex. That is
the point of the switch: asking for frailty tells you exactly what is missing,
rather than producing a column of zeros that reads as a cohort with no frail
patients.

### The two periods are counted the same way

§7.8.1's counting rules — same-day claims are one event, a ≥ 30 day washout
between acute events, a chronic condition counted once — apply to **both**
baseline prevalence and on-treatment incidence. Baseline used to be a bare
`count(*)` over every event date in the window, so a patient with chronic
kidney disease coded at twelve visits contributed twelve events to the
background prevalence of a condition that counts once, and Objective 1 and
Objective 2 were computed under different rules. They are the same machinery
now.

Exactly one difference survives, and it is the protocol's: the baseline
denominator is the window's own person-time *"irrespective of prior event
history"*, so nobody leaves it and a chronic first occurrence counts for
everyone. On treatment, a patient with prior history is out of **both** the
numerator and the denominator, and `N_AT_RISK` on the rates table says how
many were left.

### The secondary 2L cohort stops the run

§7.4.1.1 wants 2L initiators *"irrespective of whether their 1L initiation
occurred during the primary cohort ascertainment period"*, and §7.8.1 permits a
prior malignancy. This package **cannot build that** from its own inputs: every
cohort is an inner join onto `INPUT_COHORT_TABLE`, which is the primary NDMM
cohort with the other-cancer exclusion and the 2019 index floor already
applied, and the LOT run was built over that same population.

`SEC2L_APPLY_OTHER_CANCER=FALSE` used to drop the criterion from a **list** —
which changed the funnel and changed nothing about who was in the cohort, so
the baseline malignancy prevalence that is the whole reason the cohort exists
came out zero by construction. Selecting SEC2L now stops the run and names the
two ways forward: point `INPUT_COHORT_TABLE` at a cohort and LOT run built
without those rules and set `SEC2L_INPUT_IS_WIDE=TRUE`, or set
`SEC2L_APPLY_OTHER_CANCER=TRUE` to build the nested version knowingly — the run
then records that it did.

### The statement splitter tracks all three quote characters

Spark's `sql()` takes one statement, so templates written as a `CREATE` plus an
`INSERT` are split on semicolons outside quotes and comments.

All three quote characters are tracked: `'`, `"` and backtick. Only `'` was,
and the package's own SQL already uses backticks — a `;` inside one would have
cut a statement in half. Each closes on **itself**, and doubled inside means an
escaped one, so a backtick in a string literal does not end it.

A statement that is only comments and whitespace is dropped rather than sent.
A template ending in a comment used to emit that comment as a statement, and
the warehouse would reject it — surfacing as a failed run rather than as a bug
here.

Neither shape is emitted today, which is exactly why both were worth closing
before something started to. The 565 statements a default run emits are
byte-identical across the change, and 60,000 fuzzed strings over the full
quote-and-comment alphabet agree with an independently written reference.

### A build in a session inherits nothing from the one before it

Three things outlive a build: the config, the code-list manifest, and the input
table's columns. `reset_run_state()` clears all three at the top of
`build_223926()`, so a second build cannot report an md5 for a file it never
opened, or apply an exclusion flag its own input does not carry.

The config lives in a private environment rather than a global `cfg`. The LOT
engine keeps its own config the same way under the same name, so while both
used the global, sourcing them in one session left whichever arrived second
holding the name and the other's `wrk()` reading a config that was not its own.

### An upstream reading is recorded as verified or as an assertion

Eight settings are the cohort build's rules, not this package's. Recording the
setting alone asserted a reading nothing had checked.

`NDMM_RUN_METADATA.CONTRACT_SETTINGS` is the cohort build's whole contract as
`k=v|k=v`, written by the run that made the cohort. `read_upstream_settings()`
reads it, so `STUDY_START` and `MM_DX_OUTPATIENT_WINDOW_DAYS` are recorded as
what the cohort was actually built with. The rest are fixed in that build's
code rather than its contract, so they stay marked `(upstream, unverified)`.

The two defaults disagree today: this package reads §7.1's body
(01 Jan 2018) and the cohort build reads Figures 1 and 2 (01 Jan 2016), which
is `OPEN_QUESTIONS.md` Q1. That is not fatal — the cohort is what it is — so
the run names the disagreement, records both values, and carries on.

### The input's shape is checked before its columns are used

`check_cohort_table()` runs first, before any module. It refuses a table
missing a column every cohort indexes on, and it refuses two things a column
list cannot show:

- **more rows than patients.** The package reads `INPUT_COHORT_TABLE` as one
  row per patient. A duplicate multiplies that patient through every join, so
  the cohort counts come out high and nothing downstream notices.
- **an exclusion flag that is NULL or not 0/1.** The membership predicate is
  `coalesce(flag, 1) = 1`, which reads a NULL as eligible. On a table this
  check accepted, that coalesce cannot fire.

Both are for custom inputs. The cohort build's own writer emits non-null CASE
results at patient grain, so a run against it never sees either.

### Suppression is applied in one place, and that place is tested

*"Stratifications with < 25 patients will not be performed"* (§7.2.3). The rule
lived in `R/suppression.R` from the start and **nothing called it**: every table
left the warehouse with raw cell counts, n = 1 included.

The `release` module applies it in SQL. It does not overwrite the raw tables —
each suppressed table is written beside its source as `S_*_RELEASE`, so QC can
still read the counts behind a rate while the thing that leaves the warehouse
cannot. The suppressed count is nulled along with the values, because
publishing the *n* a suppressed rate was computed from suppresses nothing. A
group left with exactly one suppressed row is reported, not silently regrouped.

`R/suppression.R` is gone. It survived the module by being loaded but never
called, and its policy had drifted: it applied §7.8's *"(unless specific to
SOC)"* exemption, which the shipped SQL does not. So the suite was green on a
rule that never ran. The tests now assert the emitted release SQL — the
threshold, the nulled count, the marking, and the absence of the exemption.
Whether the exemption should apply is `OPEN_QUESTIONS.md` Q29.

### A recorded reading is either applied here or labelled

`S_RUN_METADATA.OPEN_QUESTION_READINGS` records every open question's reading.
Nine of them were settings this package applied **nowhere** — the exact failure
this document lists as fixed for `INDEX_EXCLUDED_ABBRS`. They are split now:
`OPEN_QUESTION_SOURCE` marks each `here` or `upstream`, an upstream reading is
written with that word beside it, and a test emits the whole run twice for
every `here` setting — once at its default, once at an alternative — and
**requires the SQL to differ**. A setting that stops being applied fails the
suite rather than being recorded forever as the reading that produced the
numbers.

`BRIDGED_GAP_IS_PERSON_TIME` is gone rather than relabelled: it named a
person-time rule, and `BASELINE_PY` and `PERIOD_PY` are window lengths
whichever way it was set. `../OPEN_QUESTIONS.md` Q19 is still open.

## The output prefix, and why a reused one now stops the run

`OBJECT_PREFIX` selects the namespace this package writes into. Before writing
any table it compares the declared schema — ordered column names and types —
against what is already there, and **stops if they differ, before clearing a
single row**. There is no automatic migration.

That matters right now: `S_COHORT` gained `MET_X1`–`MET_X4`, `S_HCRU_RATES` and
`S_MALIGNANCY_RATES` gained `N_AT_RISK`, `S_LOT_PERIODS` renamed
`LOT_BASE_DISCON_DT` to `PROTOCOL_DISCON_DT`, and `S_MALIGNANCY_DATES` is new.
**A prefix written by an earlier version of this package will therefore stop
this one.** Drop those tables, or run against a fresh prefix.

The check is strict on purpose, because the inserts are positional:

* a table that gained a column fails on the count — *after* the delete, if the
  check did not run first;
* a table whose column was renamed accepts the insert and keeps the old name
  with the new meaning, which is worse, because nothing fails;
* a narrower stored type silently truncates. `float` is not `double` — single
  precision turns 16,777,217 into 16,777,216 — and a bounded `varchar(n)` is
  not an unbounded `string`, because it rejects an over-length write once the
  scope has already been cleared.

Genuine spellings of one type still match: `varchar` and `string`, `integer`
and `int`, `double precision` and `double`. A type the check does not recognise
is treated as a mismatch rather than folded into a neighbouring family, and a
`DESCRIBE` that returns no type column stops rather than comparing names alone.

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

## What the second adversarial review changed

The package was reviewed a second time, and its headline was not a defect but a
gap in the tests: **four of the twelve modules could not run at all**, and the
suite passed anyway, because every check read the package's source text and none
parsed a statement or executed a module.

So the first fix is `tests/emit_sql.R`: it loads the package into a private
environment, replaces the four functions that touch Spark with recorders, and
runs **every module for every cohort**. What comes back is every statement the
run would have issued — 407 of them — each parsed in the Spark dialect. The four
blockers were then visible in seconds:

| what | what it did |
|---|---|
| `split_statements()` split on `;` inside a SQL `--` comment | three modules' SQL was **chopped in half** by a semicolon in a comment explaining what the step did — `demographics`, `soc`, `hcru`, two of them in the "runs today" selection |
| `08_malignancy.R` and `04_comorbidity.R` were missing a comma between two CTEs | both statements were a **parse error**, so neither module could run |
| `here_pred[[st$criterion]]` on a named character vector | `[[` on an absent name **throws** rather than returning `NULL`, so the `is.null()` branch below it was unreachable and `attrition` died for 1L and SEC2L |

Eleven correctness findings came with them. The ones that would have produced
numbers rather than errors:

| what | what it would have done |
|---|---|
| `BEST_CATEGORY LIKE '%anti-CD38%'` | `Other triplet (non-anti-CD38)` **contains that substring**, so every non-anti-CD38 triplet was relabelled as an anti-CD38 one and the category never appeared at all |
| `WHEN N_AGENTS >= 4 THEN 'Quadruplet with anti-CD38 backbone'`, unconditionally | a four-agent regimen with **no anti-CD38 agent** was reported as having an anti-CD38 backbone |
| The attrition funnel reset `N_REMAINING` on every criterion applied upstream, and never applied `MET_N2` for 1L or SEC2L | **N_REMAINING went back up mid-funnel**, and the continuous-enrolment step showed no loss |
| Quan's `myocardial_infarction` weighted 1 | Quan 2011 gives it **0** — the weight 1 is the original 1987 Charlson |
| The MM adjustment dropped a condition whose NAME matched myeloma | Quan has **no myeloma row**: myeloma sits under `any_malignancy`, so the adjustment dropped nothing and **a CCI of 0 was unreachable** for every patient in a myeloma study |
| HCRU rates were driven from the aggregate | a line with person-time and **no events produced no row**, which downstream is indistinguishable from the module not having run |
| The MM-related hospitalisation subquery joined `DIAG1 = code OR DIAG2 = code` with no family test and no cohort restriction | an ICD-9 myeloma code could match an ICD-10 claim, over a **nested loop on the whole of CONFINEMENT** |
| `preflight_codelists()` only stat-ed each path | the eleven blank templates this package ships **satisfied it**, so the run failed at the module instead of in its first second |
| `FRAILTY=TRUE` was documented and did not exist; `frailty_kim2018.csv` and `comorbid_subgroups.csv` were read by nothing | two of Table 4's variables were **silently not produced** |
| `S_SAFETY_COUNTED` was written and not declared | a table nothing downstream knew to look for |
| `SOC_SIZE_CATEGORIES`' agent counts were never read | the numbers in the table were dead data, and the CASE beside them was the real rule |

The last two of those are now covered by tests that read what the run **emits**
rather than what the source says: every declared output has to appear in the
emitted SQL, and every table the SQL writes has to be declared.

## What the first adversarial review changed

The first version of this package was reviewed at max effort, and **19 defects
were confirmed**. All are fixed, and each has a regression test — the review's
own observation stood then too: the 78-check suite that passed at the time
covered none of them. The ones worth knowing about, because they would have produced numbers
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
answer (`../OPEN_QUESTIONS.md`). The 173 tests check the selection logic, the
boundary conventions, the counting rules, and — running every module for every
cohort against recorders — that each module's R reaches the end of the function
and every statement it emits parses as Spark SQL. They check no number, because
a number needs the CDM, and a statement that parses is not a statement that is
right.
