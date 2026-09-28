# How the package works

The modules, how a run is selected, what the package reads and refuses, and
what it records. How to run it and every setting's precedence are
`README.md`; the criteria are `IE_CRITERIA.md`; variable definitions, counting
rules and strata are `VARIABLES.md`.

## Selecting modules and cohorts

**Modules are declared, not called.** `R/registry.R` holds one entry per
module: what it needs, what it writes, which code lists it cannot run without.
The runner works out the order. `MODULES=all` is the default; `MODULES=safety`
pulls in `eligibility`, `spine`, `cohorts` and `periods` because safety needs
them, and says so. A module in `SKIP_MODULES` that a selected module needs
stops the run naming both (`SKIP_MODULES=soc` with `MODULES=patterns`).

**Cohorts are declared too.** `COHORTS` takes any of `1L`, `2L`, `3L`, `SEC2L`
(default `1L,2L,3L`; `SEC2L` is opt-in). A cohort's entry names the line it
indexes on, the cohort it is nested in, its index floor and its criteria.
`COHORT_NESTED=TRUE`, the default, is §7.2.1 read literally: 2L is the subset
of 1L who initiate a second line, and 3L the subset of 2L, so a 1L index outside
the index window costs the patient their 2L and 3L rows too. With nesting on,
`COHORTS=2L` without `1L` is refused (a nested cohort built without its parent
is a different population under the same name) and the refusal names the
setting; `COHORT_NESTED=FALSE` lets each line stand on its own index, and
`COHORTS=2L` then builds alone. Every `S_COHORT` row carries `NESTED`.

**A partial run** - one module, one cohort - writes only that, and leaves every
other table and every other cohort's rows under the prefix as an earlier run
left them. Its `S_RUN_METADATA` row records the modules and cohorts it wrote,
and the dashboard and its snapshot job show a run only those.

## Modules

| key | writes | needs a code list |
|---|---|---|
| `eligibility` | `S_ELIGIBILITY` - one row per patient, the cohort build's verdict. No line of therapy | - |
| `spine` | `S_SPINE` - one row per patient per line, with the next line beside it | - |
| `cohorts` | `S_COHORT` - a patient combined with a line | - |
| `attrition` | `S_ATTRITION` - the funnel (`IE_CRITERIA.md` "8. The order to apply them, and the funnel") | - |
| `periods` | `S_PERIODS`, `S_LOT_PERIODS` - baseline, follow-up and treatment windows, the diagnosis date and what hangs on it | `mm_dx.csv` only under `DX_DATE_SOURCE=baseline_first_claim` |
| `demographics` | `S_DEMOGRAPHICS` | - |
| `comorbidity` | `S_COMORBIDITY` (Charlson); with `FRAILTY=TRUE` also `S_FRAILTY`, with `COMORBID_SUBGROUPS=TRUE` also `S_COMORB_SUBGROUP` | `charlson_quan2011.csv`, `mm_dx.csv`; plus `frailty_kim2018.csv` (Annex 7) and `comorbid_subgroups.csv` (Annex 3) under those switches |
| `soc` | `S_SOC` - regimen category per line, with the line's start year and the engine's transplant flags | `soc_regimen_categories.csv` (Annex 2) |
| `safety` | `S_SAFETY_EVENTS`, `S_SAFETY_COUNTED`, `S_SAFETY_RATES` | `safety_events.csv` (Annex 3) |
| `hcru` | `S_HCRU_EVENTS`, `S_HCRU_RATES` | `hcru.csv`, `mm_dx.csv` |
| `malignancy` | `S_MALIGNANCY`, `S_MALIGNANCY_DATES`, `S_MALIGNANCY_RATES`, and `S_MALIGNANCY_SEQUENCES` where `soc` ran | `secondary_malig.csv` (Annex 3); `mm_dx.csv`, read only to refuse a myeloma code |
| `tte` | `S_TTE` - TTNT, TTD, OS | - |
| `patterns` | `S_PATTERNS`, `S_SWITCH`, `S_TX_ATTRITION` | via `soc` |
| `release` | `S_*_RELEASE` - every rate and percentage table with cells under 25 patients suppressed | - |

**What runs without code lists.** `eligibility`, `spine`, `cohorts`,
`attrition`, `periods`, `demographics` and `tte` need none, so they always run.
Under `MODULES=all` a module whose list is unusable - and anything that needs
it - is **left out by name** in the plan, the log and `S_RUN_METADATA`, so the
dashboard reports it as not run; the rest run. Naming a module in `MODULES`
asks for it: its list is then required, and the run stops before the
connection is opened, saying which file and which annex. The same holds for a
switch: `FRAILTY=TRUE` or `COMORBID_SUBGROUPS=TRUE` adds its list to what
`comorbidity` needs, so asking for frailty says what is missing rather than
producing a column of zeros.

The preflight **loads** each list the selected modules need rather than
checking that its path exists, and runs each list-driven module's own check of
its list against the settings (`DATA_MAPPING.md` "The files this package
reads"). A list a module would refuse is found before the connection is
opened, not after the modules before it have run.

## Two roots, and what combines them

`eligibility` and `spine` are independent. `eligibility` reads the cohort
build's verdicts into `S_ELIGIBILITY` and **is the only module that reads
`INPUT_COHORT_TABLE`**; everything downstream reads `S_ELIGIBILITY`.
`S_ELIGIBILITY.EVIDENCE` says whether the exclusion verdicts came from flags on
the input or from a pre-filtered input that carried none. `spine` is the LOT
engine's `LOT_LONG_FINAL` lines (after the engine's own line criteria), with no
cohort join and no date filter; `MAX_LOT` (default 4, the engine builds 5) is
applied after the next line has been looked up, so the top line still sees the
line after it. `cohorts` is the first module that needs both, and is where the
line-relative criteria are applied (`IE_CRITERIA.md` "9. Who applies each
criterion").

**A run builds only what its own modules read.** The LOT lineage proof follows
`spine`; the enrolment spans follow `cohorts` or `periods`; the medical and
pharmacy claim scan runs only under `FU_EVIDENCE_RULE=claim_after_index`. So
`MODULES=eligibility` proves no lineage and runs where no LOT status table
exists.

## The input cohort table

`check_cohort_table()` runs before the first module whenever `eligibility`
runs. It refuses:

- a table missing a column the package reads: `PATID`, `INDEX_DATE`,
  `ENDDATE`, `ENDDATE_CE`, `DEATH_DT`, `MM_DX_DT`, `YRDOB`, `GDR_CD`;
- **more rows than patients**, or a NULL `PATID` - a duplicate multiplies that
  patient through every join;
- **an exclusion flag that is NULL or not 0/1** - membership reads
  `coalesce(flag, 1) = 1`, so a NULL would read as eligible.

It accepts two shapes. A **pre-filtered** table has had X1-X4 applied and may
carry no flag: a criterion whose flag is absent was applied upstream, and its
funnel step shows no loss. A **wide** table keeps the patients who fail an
exclusion and carries each verdict as a flag, which each cohort applies for
itself. The cohort build's `NDMM_COHORT` is the pre-filtered shape.

| criterion | flag |
|---|---|
| X1 prior MM therapy | `NO_PRIOR_MM_TX` |
| X2 other cancer | `NO_OTHER_CANCER_PRE_LOT1` |
| X3 pregnancy | `NO_PREGNANCY` |
| X4 belantamab before the 1L index | `NO_BELANTAMAB_PRE_LOT1` |

### The secondary 2L cohort's wide input

§7.4.1.1 wants every 2L initiator from 01 Jan 2020 whenever their 1L fell, and
prior malignancy is permitted (Q7). Every cohort here is an inner join onto
`INPUT_COHORT_TABLE`, and `NDMM_COHORT` has the other-cancer exclusion and the
1L index floor applied, with the LOT run built over that same population.
Built from it, SEC2L would be nested in the primary cohort and its baseline
malignancy prevalence - the number the cohort exists to produce - would be
zero by construction.

So SEC2L needs a **wide cohort input**: a cohort table, and a LOT run over it,
built without the other-cancer exclusion and without the 1L index floor, that
still carries the full cohort schema above (the LOT engine's own input check
also asks for `AGE_INDEX_YR`, `FU_DAYS` and `FU_DAYS_CE`), one row per patient,
and all four exclusion flags as 0/1. The primary 1L cohort still excludes on
the flags, 2L and 3L inherit that through nesting, and SEC2L drops X2. No stage
of the pipeline builds that table; it is a cohort build to write. The cohort
build's `NDMM_FLAGS_ALL` cannot stand in: it carries `PATID` and seven flags
but none of the dates or demographics, and its candidates already meet the 1L
index floor, so `check_cohort_table()` and the LOT engine's input check both
refuse it.

Selecting `SEC2L` stops the run before the connection is opened unless one of
two settings says how to proceed, and both are recorded among the run's
readings:

- `SEC2L_INPUT_IS_WIDE=TRUE` **asserts** that `INPUT_COHORT_TABLE` and its LOT
  run were built without the other-cancer exclusion and the 1L index floor. The
  package cannot see what an upstream build left out; what it checks is that
  the table carries all four exclusion flags, and a wide table missing any
  stops the run. SEC2L is then built without X2.
- `SEC2L_APPLY_OTHER_CANCER=TRUE` builds the nested version knowingly, with X2.

## What a run records

`S_RUN_METADATA` holds one row per run, keyed by `RUN_ID` (`DOMINO_RUN_ID`, else
a timestamp), written `started`, then `complete` or `failed` under the same id.
It carries the cohorts and modules the run wrote; the package code and study
contract fingerprints (`STUDY_CODE_MD5`, `STUDY_CONTRACT_MD5`); the LOT run,
its code (`LOT_CODE_MD5`), the `LOT_RULES_EPOCH` it was accepted against and the
cohort attempt behind it; the study period; `RATE_MULTIPLIER`;
`CONTRACT_DEVIATIONS` (`IE_CRITERIA.md` "What stops a changed run");
`CODELISTS`, each list read with its md5 and row count; the release findings
below; and `OPEN_QUESTION_READINGS`.

**Every open question is a setting**, defaulting to the protocol's reading, and
`OPEN_QUESTION_READINGS` records the reading each run took. `OPEN_QUESTION_SOURCE`
marks each one `here` (this package's SQL changes with it) or `upstream` (the
cohort build's rule, `IE_CRITERIA.md` "Settings the cohort build owns").
`read_upstream_settings()` reads the cohort build's whole contract from
`NDMM_RUN_METADATA.CONTRACT_SETTINGS`, so `STUDY_START` and
`MM_DX_OUTPATIENT_WINDOW_DAYS` are recorded as `(upstream, verified)` - the
value the cohort was built with, and this run's own value beside it where they
differ. The upstream settings fixed in that build's code rather than its
contract stay `(upstream, unverified)`. The test suite emits the whole run at
each `here` setting's default and at an alternative and requires the SQL to
differ, so no setting is recorded as a reading while applying nothing.

## Suppression and release

*"Stratifications with < 25 patients will not be performed"* (§7.2.3). The
`release` module applies it in SQL, the only place the rule exists, testing
each row's population - `N_AT_RISK` on the rate tables, `N_PATIENTS` on the
count tables (`SUPPRESSION_SPEC` in `R/registry.R`); a NULL population
suppresses too. It does not overwrite the raw tables: each suppressed table is
written beside its source as `S_*_RELEASE`, so QC can read the counts behind a
rate while what leaves the warehouse cannot. The suppressed count is nulled
with the values. No exemption is made for §7.8's *"(unless specific to SOC)"*
(Q29).

The raw `S_*` tables leave the warehouse in two places, both controlled outputs
rather than releases: the QC report, and the dashboard's snapshot job, which
exports every `S_*` table and the LOT tables to a directory the app reads. That
directory is patient-level data and is handled as such; the app shows the
`_RELEASE` form where one exists.

Where exactly one stratum of a group is suppressed, the total less the
published rest gives it away, so `mod_release()` warns and the run records it
twice:

- `S_RUN_METADATA.RELEASE_RECOVERABLE`, in words - the table and grouping, or
  `none`, or `release module did not run` (which is not `none`: a run without
  the module has not looked);
- `S_RUN_METADATA.RELEASE_RECOVERABLE_TABLES`, the same finding as a
  semicolon-separated list of table names, which TFLS and the dashboard refuse
  on. It is empty both where there is nothing to name and where the module did
  not run, so an empty list never narrows a refusal: a reader that sees none
  falls back to the sentence.

Whether to regroup or withhold a second stratum is the analyst's call.

**What the package writes, as data.** `R/contract.R` emits one row per table the
package can write - the module, whether `release` publishes a suppressed copy,
and the switch that must be on for it. TFLS holds the generated copy and reads
it instead of restating the registry; its suite regenerates from here and
compares whenever this package is beside it. Regenerate with
`write_study_contract(path)` after adding a table to `MODULES` or
`SUPPRESSION_SPEC`.

## The output prefix

`OBJECT_PREFIX` is the namespace this package writes into. The root tables
(`S_ELIGIBILITY`, `S_SPINE`), the working tables and the `_RELEASE` tables are
rebuilt whole; every other table is cleared only for the cohort being written,
and before that the package compares the declared schema - ordered column
names and types - with what is already there and **stops if they differ,
before clearing a row**. There is no
migration: drop the prefix's `S_*` tables or use a fresh `OBJECT_PREFIX`.

The check is strict because the inserts are positional: a gained column fails
on the count, a renamed one inserts cleanly under the old name with the new
meaning, and a narrower stored type silently truncates (`float` is not
`double`; a bounded `varchar(n)` is not `string`). Only spellings of one type
match (`varchar`/`string`, `integer`/`int`, `double precision`/`double`), and a
`DESCRIBE` that returns no type column stops rather than comparing names alone.

## What it refuses

A module that is asked for and cannot run **stops the run**; it never returns
an empty table. The run stops on:

- a code list with an unfilled row (naming the concepts), a blank or
  unrecognised `icd_family`, or a list its module's own check refuses
  (`DATA_MAPPING.md` "The files this package reads");
- an input cohort table of the wrong shape, or `SEC2L` selected without a wide
  input or `SEC2L_APPLY_OTHER_CANCER=TRUE` (above);
- a changed contract number without `SETTINGS_OVERRIDE=TRUE`, or a cohort whose
  study period or 1L index floor disagrees with this run's
  (`IE_CRITERIA.md` "What stops a changed run");
- a cohort build that barred fewer of the agents in `COHORT_INDEX_EXCLUSIONS`
  from setting the 1L index than §7.2.1.1 names (`IE_CRITERIA.md` "I3. Eligible
  1L treatment"); where `cl_mma_rollup.csv` or the build's `INDEX_EXCLUDED`
  record is unavailable, the check is logged as unverified rather than failed;
- a LOT run that is not `complete`; was built over a different cohort table or
  a different attempt of it; carries contract deviations; has a different
  `STUDY_END`; was built by code other than `LOT_CODE_MD5` where that is set
  (blank by default); or finished on or before `LOT_RULES_EPOCH` (default
  `2026-09-22`, moved whenever the LOT rules change; compared by calendar date,
  so a run finished on that date is also refused). The suite fingerprints the
  engine's R and bundled settings and checks both against the pin the date sits
  with. The lineage is checked again before the run is recorded complete, so a
  LOT rebuild landing mid-run fails it;
- a step that produces zero rows, attrition categories that stop partitioning
  their denominator, or strata that stop summing to their line.

`LOT_ALLOW_UNPROVEN_LINEAGE=TRUE` lets a run go on over a lineage it could not
read; a lineage it read and found wrong is never waived.

## Inside the runner

Spark's `sql()` takes one statement, so templates are split on semicolons
outside quotes and comments - `'`, `"` and backtick, each closing on itself,
doubled meaning escaped; a statement of only comments is dropped. A statement
that is safe to run twice is retried up to `MAX_RETRIES` times (default 4),
waiting `BASE_SLEEP` seconds (default 5), doubling each time; an `INSERT` or
`MERGE` is sent once, and a missing table, a parse error or a missing grant
stops at once. `reset_run_state()` clears the
config, the code-list manifest and the input table's columns at the top of
`build_223926()`, so a second build in one R session inherits nothing from the
first. The config lives in a private environment rather than a global `cfg`,
because the LOT engine keeps its own config under that name.
