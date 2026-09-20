# The variables package — the analytical cohort, after the LOT run

An R package that turns a finished lines-of-therapy run into the analytical
cohort and variables the Aug 26 2026 protocol asks for. It builds no line and
no MM cohort of its own: the cohort build makes the population, `lot/` makes
the lines, and this reads both.

```
                cohort build          lot/engine/build.R        build.R
raw Optum CDM ──────────────► NDMM_COHORT ──────────► LOT_LONG_FINAL ──────────► S_*
```

Connection is the **Databricks ODBC driver through DBI** - the same DSN and
`DATABRICKS_PWD` the cohort and LOT builds connect with, so one environment
serves all three:

```
DATABRICKS_PWD=... Rscript build.R                 # DSN from DATABRICKS_DSN, default RWDE
DRY_RUN=TRUE Rscript build.R                       # print the plan, touch nothing
MODULES=safety COHORTS=1L,2L Rscript build.R       # one module; 2L is nested in 1L, so 1L comes too
Rscript tests/run_tests.R                          # no warehouse
```

`SPARK_METHOD` picks the connection, and `odbc` is the default. The other
three are sparklyr sessions: `databricks` attaches to the session of the
cluster the script runs on, with no DSN and no password; `databricks_connect`
drives a named cluster from outside and is the only mode that needs
`DATABRICKS_HOST`, `DATABRICKS_TOKEN` and `SPARK_CLUSTER_ID`; `local` is a
smoke test. Every statement is SQL text, so the modes differ only in the
connection layer of `R/db_utils_223926.R`; over ODBC a code list is staged as
one VALUES statement behind a temporary view, as the cohort build stages its
own.

The schema a run writes into, and reads the cohort and LOT tables from,
resolves as the cohort and LOT builds resolve theirs: `WORK_SCHEMA`, then
`PROJECT_WORK_SCHEMA`, then `DOMINO_USER_NAME`, else the session's current
schema. Give the schema alone - `osk02156`, not `hive_metastore.osk02156` -
though the second form is accepted when the catalog is `DATABRICKS_CATALOG`.

A partial run - one module, one cohort - writes only that, and leaves every
other table and every other cohort's rows under the prefix as the previous
run left them. Its `S_RUN_METADATA` row records the modules and cohorts it
did write, and the dashboard and its snapshot job show a run only those:
a table its metadata does not claim, or rows of a cohort it did not select,
are an earlier run's whatever sits under the prefix.

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

**3. Every open question is a setting.** The twenty-six entries in
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
| `R/db_utils_223926.R` | the connection - ODBC through DBI, or a sparklyr session - logging, table naming, the step runner. |
| `R/run_223926.R` | Resolves the plan, walks the modules, writes the run metadata. |
| `R/modules/*.R` | One file per module. Nothing else defines a clinical rule. |
| `tests/run_tests.R` | The suite, needing no warehouse. The last sections RUN every module for every cohort, parse every statement they emit, and **execute** them against fixtures. |
| `tests/emit_sql.R` | The harness. Stubs only what touches Spark, so a module's R and its SQL are both exercised without a cluster. |
| `tests/parse_sql.py` | Parses each captured statement in the Spark dialect (sqlglot). |
| `tests/run_duckdb.py` | **Executes** them: transpiles to DuckDB, runs against `tests/fixtures/cdm`, checks 90 golden numbers, then runs the whole script again and checks nothing doubled. |
| `tests/expectations.py` | Those golden numbers. `tests/fixtures/EXPECTED.md` derives every one by hand. |
| `tests/fixtures/` | Six synthetic patients, chosen so each makes a protocol rule visible, and filled miniatures of all eleven code lists. Test data — not codes to use. |

## Modules

| key | writes | needs a code list |
|---|---|---|
| `eligibility` | `S_ELIGIBILITY` — one row per patient, the cohort build's verdict. **No line of therapy.** | — |
| `spine` | `S_SPINE` — one row per patient per line, with the next line beside it | — |
| `cohorts` | `S_COHORT` — a patient combined with a line | — |
| `attrition` | `S_ATTRITION` — the funnel: one row per criterion, under the one or two rows that say where the cohort's population came from | — |
| `periods` | `S_PERIODS`, `S_LOT_PERIODS` — baseline, follow-up, treatment windows; the diagnosis date (`DX_DT`, `DX_DATE_SOURCE` says which, Q30) and what hangs on it — `DX_YEAR`, `INDEX_YEAR`, diagnosis→index and diagnosis→follow-up-end, prior LOT→next LOT | `mm_dx.csv` only under `DX_DATE_SOURCE=baseline_first_claim` |
| `demographics` | `S_DEMOGRAPHICS` — age (at index and at diagnosis), sex, region, race, ethnicity, insurance, from the enrolment row covering the index or else the baseline row nearest it (`ATTR_SOURCE`) | — |
| `comorbidity` | `S_COMORBIDITY` — Charlson (Quan 2011), MM-adjusted. With `FRAILTY=TRUE` also `S_FRAILTY`; with `COMORBID_SUBGROUPS=TRUE` also `S_COMORB_SUBGROUP` | `charlson_quan2011.csv`, `mm_dx.csv`; plus `frailty_kim2018.csv` (Annex 7) and `comorbid_subgroups.csv` (Annex 3) when those switches are on |
| `soc` | `S_SOC` — regimen category per line, with the line's start year and the engine's transplant flags and transplant year (Table 6's SCT by year by SOC is a count over it) | `soc_regimen_categories.csv` (Annex 2) |
| `safety` | `S_SAFETY_EVENTS`, `S_SAFETY_COUNTED`, `S_SAFETY_RATES` — baseline prevalence and on-treatment incidence, counted the same way: one acute washout chain per cohort over the whole timeline (kept under `PERIOD = TIMELINE`, Q34), inpatient-defined conditions from admissions, a `(hospitalisation)` series per chronic condition, and an `(any in domain)` aggregate row per domain | `safety_events.csv` (Annex 3) |
| `hcru` | `S_HCRU_EVENTS`, `S_HCRU_RATES` | `hcru.csv`, `mm_dx.csv` |
| `malignancy` | `S_MALIGNANCY` (with `AFTER_INDEX`), `S_MALIGNANCY_DATES` — every qualifying date, not only the first — `S_MALIGNANCY_RATES` with its interval and an `(any malignancy)` aggregate category, and `S_MALIGNANCY_SEQUENCES` (three readings on `LINES`, Q32) where `soc` ran | `secondary_malig.csv` (Annex 3); `mm_dx.csv`, read only to refuse a myeloma code |
| `tte` | `S_TTE` — TTNT, TTD, OS | — |
| `patterns` | `S_PATTERNS`, `S_SWITCH`, `S_TX_ATTRITION` | via `soc` |
| `release` | `S_*_RELEASE` — every rate and percentage table with cells under 25 patients suppressed | — |

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
no row — the honest answer rather than a zero.

**Anything reading these tables must say which grouping it wants.** A query
written before these columns existed now sees the line and its parts together
and will double count. `WHERE SOC_CATEGORY = '(all categories)' AND AGE_GROUP =
'(all ages)'` is the old behaviour.

**`AGE_GROUP` is not `AGE_BAND`.** `S_DEMOGRAPHICS` carries both: `AGE_BAND` is
Table 1's descriptive distribution, four bands wide, and `AGE_GROUP` is the
protocol's stratification — `<75` and `75+`, stratification 2 in
`../VARIABLES.md`. The rate tables are grouped by the second, because a rate is
not the sum of its strata's rates: a grouping that spread `<75` over three
bands could report a count for it but never a rate.

Two labels distinguish a gap from a value. `(uncategorised)` is a line the
`soc` module wrote no row for; `(no demographics row)` is a patient the
`demographics` module wrote none for. Neither is `Unknown`, which that module
writes as a real age group for a patient whose age it could not read.

Suppression is unchanged in kind and tighter in effect: a stratum is smaller
than the line, so more of them fall under the floor. `mod_release()` warns
where exactly one stratum of a group is suppressed, because the total less the
published rest gives it away.

That finding is also two columns. `S_RUN_METADATA.RELEASE_RECOVERABLE` records
it in words — the table and the grouping, or `none`, or `release module did not
run`, which is a third answer and not the second: a run without the module has
not been shown to have no recoverable cell, it has not looked.
`S_RUN_METADATA.RELEASE_RECOVERABLE_TABLES` records the same finding as a
semicolon-separated list of table names. The sentence is for a person; the list
is what a gate refuses on, because finding table names inside a sentence is a
guess that fails in both directions — reword the warning and it names none, and
a blanket refusal then follows from a change of wording rather than a change of
risk. The list is empty where there is nothing to name **and** where the module
did not run, so an empty list never narrows a refusal: a reader that sees none
falls back to the sentence. Whether to regroup or withhold a second stratum
stays the analyst's call; a publication gate reads the columns and refuses
rather than relying on someone having read a log.

**What this package writes, as data.** `R/contract.R` emits one row per table
the package can write — the module that writes it, whether the release module
publishes a suppressed copy, and the switch that has to be on for it. TFLS
ships the generated copy and reads it instead of restating the registry, and
its suite regenerates from here and compares line for line whenever this
package is beside it. Regenerate with `write_study_contract(path)` after adding
a table to `MODULES` or `SUPPRESSION_SPEC`.

**Seven of the fourteen run today.** `MODULES=all`, the default, runs everything
that has a usable code list. `spine`, `cohorts`, `attrition`, `periods`,
`demographics` and `tte` need none, so they always run: the cohorts `COHORTS`
names (the config default is `1L,2L,3L`; `SEC2L` is opt-in), every window, the
demographics and the time-to-event outcomes. The other seven are blocked on
Annexes 2 and 3 (`../CODELISTS.md`) and are **left out by name** - in the plan,
in the log and in `S_RUN_METADATA`, so the dashboard reports them as not run -
rather than stopping the run. Naming a module in `MODULES` asks for it: then
its list is required, and the run stops in its first second, **before** the
connection is opened, saying which file and which annex.

The preflight also runs each list-driven module's own check of its list
against the settings - an ED definition the HCRU list has no rows for, a SOC
category the protocol does not name, a safety condition defined by an
admission - so a list a module would refuse is found before the connection is
opened, not after the modules before it have run. The frailty and subgroup
lists, behind their switches, are still checked as the module starts.

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
default, because both need code lists that carry no codes yet — Annex 7's and
Annex 3's. Switched on, the code-list preflight names the annex: `comorbidity`
is left out with the reason under `MODULES=all`, and a run that named it stops.
That is the point of the switch: asking for frailty says exactly what is
missing, rather than producing a column of zeros that reads as a cohort with no
frail patients.

### The two periods are counted the same way

§7.8.1's counting rules — same-day claims are one event, a ≥ 30 day washout
between acute events, a chronic condition counted once — apply to **both**
baseline prevalence and on-treatment incidence, through the same machinery. So
a patient with chronic kidney disease coded at twelve visits contributes one
event to the background prevalence and not twelve, and Objectives 1 and 2 are
computed under one set of rules rather than two.

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

All three quote characters are tracked: `'`, `"` and backtick. The package's
own SQL uses backticks, and a `;` inside one would cut a statement in half.
Each closes on **itself**, and doubled inside means an escaped one, so a
backtick in a string literal does not end it.

A statement that is only comments and whitespace is dropped rather than sent:
a template ending in a comment would otherwise emit that comment as a statement
of its own, which the warehouse rejects.

### A build in a session inherits nothing from the one before it

Three things outlive a build: the config, the code-list manifest, and the input
table's columns. `reset_run_state()` clears all three at the top of
`build_223926()`, so a second build cannot report an md5 for a file it never
opened, or apply an exclusion flag its own input does not carry.

The config lives in a private environment rather than a global `cfg`. The LOT
engine keeps its own config under the same name, so a global would leave
whichever was sourced second holding the name, and the other's `wrk()` reading
a config that was not its own.

### An upstream reading is recorded as verified or as an assertion

Eight settings are the cohort build's rules, not this package's, so recording
this package's own value alone would assert a reading nothing had checked.

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

### Suppression is applied in one place

*"Stratifications with < 25 patients will not be performed"* (§7.2.3).

The `release` module applies it in SQL. It does not overwrite the raw tables —
each suppressed table is written beside its source as `S_*_RELEASE`, so QC can
still read the counts behind a rate while the thing that leaves the warehouse
cannot. The suppressed count is nulled along with the values, because
publishing the *n* a suppressed rate was computed from suppresses nothing. A
group left with exactly one suppressed row is reported, not silently regrouped.

That SQL is the only place the rule exists, and the tests assert what it emits
— the threshold, the nulled count, the marking, and the absence of §7.8's
*"(unless specific to SOC)"* exemption. Whether that exemption should apply is
`OPEN_QUESTIONS.md` Q29.

### A recorded reading is either applied here or labelled

`S_RUN_METADATA.OPEN_QUESTION_READINGS` records every open question's reading,
and a reading recorded but applied nowhere is worse than none.
`OPEN_QUESTION_SOURCE` marks each one `here` or `upstream`, an upstream reading
is written with that word beside it, and a test emits the whole run twice for
every `here` setting — once at its default, once at an alternative — and
**requires the SQL to differ**. A setting that stops being applied fails the
suite rather than being recorded forever as the reading that produced the
numbers.

`BRIDGED_GAP_IS_PERSON_TIME` is gone rather than relabelled: it named a
person-time rule, and `BASELINE_PY` and `PERIOD_PY` are window lengths
whichever way it was set. `../OPEN_QUESTIONS.md` Q19 is still open.

## The output prefix, and why a reused one stops the run

`OBJECT_PREFIX` selects the namespace this package writes into. Before writing
any table it compares the declared schema — ordered column names and types —
against what is already there, and **stops if they differ, before clearing a
single row**. There is no automatic migration.

## Two roots, and what combines them

`eligibility` and `spine` share a number because neither needs the other.

Eight of the eleven criteria are settled before this package runs — I1 to I4 and
X1 to X4 — and arrive as flags on `INPUT_COHORT_TABLE`. None of them needs a
line, an index date from LOT, or anything the engine produces. `eligibility`
reads them into `S_ELIGIBILITY`, one row per patient, and **it is the only
module that reads `INPUT_COHORT_TABLE`.** Everything downstream reads the
eligibility layer instead, so the upstream table is touched in one place and a
change to its shape reaches the run through a table this package declares.

`spine` is the LOT engine's lines, with no cohort join and no date filter.

**And the run builds only what its own modules read.** Declaring
`needs = character(0)` is not enough on its own: the controller used to prove
LOT lineage and build enrolment spans on every run, so `MODULES=eligibility`
still failed in an environment with no `LOT_BUILD_STATUS` table — before the
module it selected ever ran. The lineage proof now follows `spine`'s presence
in the resolved set (it is the one module that reads the LOT tables, and
everything needing lines needs it), the enrolment spans follow `cohorts` or
`periods`, and the claim counts follow `cohorts`. An eligibility-only run
prepares none of them and proves no lineage, because it reads none of them.

Only three criteria are line-relative by definition — I5 (follow-up from the
line's index), N1 (received *this* line) and N2 (enrolment before *this* line's
index) — and they live in `cohorts`, which is where a patient and a line are
combined. That is the first module needing both roots, and the only one that
needs a LOT run to exist at all.

**Nesting is a setting, not structure.** `COHORT_NESTED=TRUE`, the default, is
s7.2.1 read literally: 2L is the subset of 1L who initiate a second line. But
that requirement is what makes a 1L index outside the index window cost the
patient their 2L and 3L rows too, and an analysis of second-line initiators does
not always want it. `COHORT_NESTED=FALSE` lets each line stand on its own index.
Every `S_COHORT` row carries `NESTED` saying which way the run went.

The **selection** follows the setting too. With nesting on, `COHORTS=2L`
without `1L` is refused — a nested cohort built without its parent is a
different population under the same name. With it off, `COHORTS=2L` is exactly
the analysis the setting exists for, and builds on its own. The refusal names
the setting that would allow it.

**And every row says what its own verdict is over.** `CRITERIA_ASKED` is the
list the cohort is **judged on** — which is not quite the list `IN_COHORT` is
*computed* from, and the difference matters. `I1`–`I3` are on the 1L list and
have no predicate here: the cohort build applied them, and a patient on the
input passed them by being there. So 1L's `CRITERIA_ASKED` names nine while
`IN_COHORT` is the AND of six. `S_ELIGIBILITY.EVIDENCE` says where the upstream
verdicts came from, and `S_ATTRITION.APPLIED_BY` says it step by step.

It has to be on the row because it differs:
1L and SEC2L are judged on nine criteria, 2L and 3L on three — `N1`, `N2`, `I5`
— so `MET_X1`–`MET_X4` sit on a 2L row *without being part of its verdict*, and
SEC2L drops `X2` under the shipped default. An analyst ANDing the `MET_*` flags
would reproduce 1L and get a different cohort at 2L, 3L and SEC2L. Use
`IN_COHORT`; `CRITERIA_ASKED` says what it means.

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
  contract deviations, or finished on or before `LOT_RULES_EPOCH` — the date
  the LOT rules last changed, shipped as `2026-09-19`, after which numbers
  built earlier are superseded — → stops. The shipped date is held to the
  engine beside this package: the suite fingerprints its R and its shipped
  settings and checks both against the pin the date belongs to, so neither
  can move without the other. Code lists live off the folder and are caught
  per run in `LOT_CODELIST` instead;
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

## Two things left as they are

`MEDIAN_LOS` uses `percentile_approx`, and Quan's hierarchy is applied only
where `charlson_quan2011.csv` carries a `supersedes` column — without it the
run **says so** rather than silently summing mild and severe liver disease
together.

## What this is not

It has never been run against the warehouse — no code lists, and several
settings still want the study team's answer (`../OPEN_QUESTIONS.md`). The
tests check the selection logic, the boundary conventions and the counting
rules; run every module for every cohort against recorders, so that each
module's R reaches the end of the function and every statement it emits parses
as Spark SQL; and, where duckdb is installed, execute those statements against
fixtures and check the numbers that come back. What they cannot check is a
number from the CDM itself: a fixture that agrees with the code is not the
warehouse agreeing with it.
