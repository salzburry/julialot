# NDMM (1L newly-diagnosed multiple myeloma) cohort

Stage 1 of the delivery. Builds the 1L NDMM cohort and its attrition for one
cohort prefix, and, once the LOT build has run, the 2L and 3L subset cohorts.

- `RULES.md` - the criteria in plain language, for the study team.
- `DECISIONS.md` - the decision register: each rule that decides membership,
  why it reads that way, and what it moves.
- `FILES.md` - what each file does.

## Running it

```
DATABRICKS_PWD=... Rscript ndmm/build.R <prefix_>
DATABRICKS_PWD=... Rscript ndmm/build.R ndmm_
```

The prefix can be set as `OBJECT_PREFIX` instead of passed. It must be a name
ending in `_`. Every table the build reads from or writes to the work schema is
named work schema + prefix + table, so two cohorts sit side by side in one
schema.

`build.R` builds the 1L cohort only. The 2L and 3L cohorts are
`build_subsequent_cohorts.R`, run after the LOT build - see "The 2L and 3L
cohorts" below.

The tests need no warehouse:

```
Rscript ndmm/tests/test_runner.R
Rscript ndmm/tests/test_subsequent.R
```

### One run per prefix at a time

Table names carry no run id, so two runs on one prefix would replace tables
the other is reading and both could report `complete`. `check_no_active_run()`
refuses a run while `NDMM_BUILD_STATUS` has a `started` row for the prefix.
Runs on different prefixes are safe - that is how two cohorts, or a throwaway
run, are built at once.

It is a check, not a lock: two runs starting at the same moment can both pass
it. A killed process leaves its `started` row behind; `NDMM_IGNORE_ACTIVE_RUN=TRUE`
gets past it, and should be set only once the named run is known to be dead.
A missing status table is the first run on the prefix and passes; any other
failure to read it stops the run (and `NDMM_IGNORE_ACTIVE_RUN=TRUE` gets past
that too, with the reason logged).

### Re-running

A re-run inside one Domino execution keeps its run id (`DOMINO_RUN_ID`). Before
the first step, this run id's rows are deleted from `NDMM_ATTRITION`,
`NDMM_RUN_METADATA` and `NDMM_CODELIST_METADATA`, so a failed attempt cannot
leave a row describing a cohort this attempt did not build. A delete that is
refused stops the run.

### The run log

Everything the run prints - log lines, QC tables, warnings and the `ERROR:`
line it stopped on - goes to the console and to one log file: `PIPELINE_LOG_FILE`
if set, otherwise `OUTPUT_DIR/pipeline_run_<time>_<pid>.log`. If a named
`PIPELINE_LOG_FILE` cannot be written the run says so once and logs to the
console only; if the default location cannot be written it logs to R's
temporary folder and says so, because that folder is deleted when the process
exits.

## Settings

Settings come from `config.csv` (`name,value,description`) and the
environment. The environment wins: a `config.csv` row is applied only when that
variable is unset. A blank value is skipped, and `DATABRICKS_PWD` is never read
from the file. `STUDY_START` and `STUDY_END` in the file are normalised back to
`YYYY-MM-DD` if a spreadsheet reformatted them; an ambiguous date such as
`03/04/2025` stops the run.

### The checks before anything is written

In this order: `check_settings` -> `pin_output_schema` -> `pin_prefix` ->
`check_contract` -> `check_choices` -> `check_constants`, then the connection,
then `check_no_active_run` and `check_upstream`. Nothing is written until every
one passes, so a refused run leaves the prefix as it found it.

- `check_settings` refuses malformed values: dates that are not `YYYY-MM-DD`,
  day counts, `MIN_AGE`, `OUTPATIENT_WINDOW` or `NDMM_ICD_FLAG_MAX_ROWS` that
  are not whole numbers, an unknown `NDMM_WAIVERS` name, a `DOMINO_RUN_ID` with
  characters other than letters, digits, `_ . -`, and any value in
  `NDMM_LOT1_FROM` (the setting is `LOT1_FROM`).
- `check_contract` compares the resolved settings with `CONTRACT` in
  `R/build_ndmm.R` - what the cohort is - and stops on any difference, because
  a different value there is a different cohort. `NDMM_CONTRACT_OVERRIDE=TRUE`
  says the difference is meant: the run goes through, logs a warning, and
  records each difference as `contract deviation: ...` in
  `NDMM_BUILD_STATUS.FINDINGS` and `NDMM_RUN_METADATA.FINDINGS`.
  `NDMM_RUN_METADATA.CONTRACT_SETTINGS` (`key=value|key=value`) then carries
  the values the run used, not the ones `CONTRACT` pins.
- `check_choices` holds each run choice to the values it may take.
- `check_constants` compares the `NDMM_*` constants the SQL interpolates
  (`R/ndmm_constants.R`, `R/standalone_constants.R`) with the resolved
  settings and stops if they differ. Each constant reads the same variable as
  its setting, so one entry in `config.csv` or the environment moves both.

The study package (`variables/`) reads `CONTRACT_SETTINGS` back and stops if
its own `STUDY_START`, `STUDY_END` or `LOT1_INDEX_FROM` differ from the
cohort's `study_start`, `study_end` or `lot1_from` (its `SETTINGS_OVERRIDE=TRUE`
proceeds and records the disagreement). A moved window has to be moved in both
packages.

### To run at all

| setting | default | |
|---|---|---|
| `DATABRICKS_PWD` | (none) | required, environment only |
| `DATABRICKS_DSN` | `RWDE` | ODBC data source |
| `PROJECT_WORK_SCHEMA` | (none) | where output goes. Falls back to `DOMINO_USER_NAME`, then `DOMINO_STARTING_USERNAME`; with none of the three the run stops rather than writing somewhere shared |
| `OBJECT_PREFIX` | (none) | the cohort prefix, or pass it to `build.R` |
| `DOMINO_RUN_ID` | a timestamp | identifies the run in every metadata table |
| `OUTPUT_DIR` | `/mnt/artifacts/results` | where the run log goes |
| `PIPELINE_LOG_FILE` | (unset) | an exact log path, so several stages can share one file |

### The contract

Changing one of these needs `NDMM_CONTRACT_OVERRIDE=TRUE` and is recorded
against the run, as above.

| setting | default | effect |
|---|---|---|
| `DATABRICKS_CATALOG` | `hive_metastore` | catalog for all reads and writes |
| `OPTUM_CDM_SCHEMA` | `clnprw_optum` | where the raw CDM lives |
| `CODELIST_DIR` | `/mnt/code/codelist` | the five code lists |
| `USE_QUARTERLY_TABLES` | `TRUE` | read the cumulative quarterly CDM tables for the study end (`2026q1`) |
| `STUDY_START` | `2018-01-01` | study period start: the diagnosis, pregnancy, belantamab and trial scans |
| `STUDY_END` | `2026-03-31` | study period end; picks the quarterly tables |
| `LOT1_FROM` | `2019-01-01` | the eligible 1L treatment period opens |
| `PRE_LOT1_DAYS` | `365` | CE and baseline window before the index |
| `FU_CE_DAYS` | `0` | days after the index the follow-up CE must cover; 0 is the index date itself |
| `GAP_DAYS` | `30` | enrolment gaps this long or shorter are still continuous |
| `OUTPATIENT_WINDOW` | `90` | two outpatient MM claims within this many days confirm a diagnosis |
| `MIN_AGE` | `18` | minimum age in the diagnosis year |
| `NDMM_BELANTAMAB_ABBR` | `BELA` | the `CL_MED_ABBR` that is belantamab. Must equal `lot`'s `BELANTAMAB_MED_ABBR` |
| `TBL_CONFINEMENT` | `confinement` | inpatient stays |
| `TBL_MEMBER_ENROLLMENT` | `member_enrollment` | enrolment spans |
| `TBL_MEMBER_ELIG` | `member_cont_enrollment` | sex and birth year |
| `TBL_DOD` | `dod` | date of death |

### Run choices

Validated against what they may take, recorded in `NDMM_RUN_METADATA`, and not
pinned - the review tables exist to be acted on.

| choice | default | may be |
|---|---|---|
| `NDMM_MM_ADJACENT_STATES` | `override` | `override`, `exclude`, `mgus_only`, `none` - which plasma-cell labels do not count as another cancer; `DECISIONS.md` section 4 |
| `NDMM_INDEX_EXCLUDED_ABBRS` | (empty) | `CL_MED_ABBR` patterns barred from setting the 1L index, separated by `\|` - below |
| `NDMM_INDEX_EXCLUDED_CODES` | (empty) | the same by code, `TYPE:CODE` or a bare code, separated by `\|` |

The two exclusion settings may hold only letters, digits, space and
`_ , : | % . -`; anything else stops the run.

### Barring agents from the 1L index

`NDMM_INDEX_EXCLUDED_ABBRS` names agents, beyond belantamab, that may not set
the 1L index. The study's I3 names two, panobinostat and elotuzumab
(`variables/IE_CRITERIA.md`, I3). In `config.csv`:

```
NDMM_INDEX_EXCLUDED_ABBRS,PANO|ELOT,Exclude panobinostat and elotuzumab from eligible 1L index treatment
```

Separate entries with `|`. The code splits on `,` as well, but in `config.csv`
a comma survives only while the value stays quoted, and an editor that drops
the quotes splits the row so that only the first entry is applied.

- Each entry is trimmed, upper-cased and matched as a SQL `LIKE` pattern
  against the code list's `CL_MED_ABBR` (also trimmed and upper-cased). With no
  wildcard it is a whole-abbreviation match; `%` matches any run of characters
  (`PANO%`), and `_`, being a `LIKE` wildcard, matches any one.
- The abbreviations must be the ones on the production `cl_mma_codelist.csv`.
  An entry matching no row stops the build, so a misspelt name cannot read as a
  restriction that applies to nothing.
- `NDMM_INDEX_EXCLUDED_CODES` works the same way for a code (`HCPCS:J9999|NDC:12345678901`,
  or a bare code for every type), compared exactly with the code list's code
  after punctuation is stripped and letters are upper-cased.
- A barred agent's claims cannot set the index; the next eligible claim does.
  It does not exclude the patient, and its claims still count as MM therapy
  for criterion 6.

The run records what it barred: the settings as given in
`NDMM_RUN_METADATA.INDEX_EXCLUDED` and `INDEX_EXCLUDED_CODES`, the log line
`Barred from setting the index, beyond belantamab: ...`, and `ELIGIBLE = 0` on
each barred agent's row of `NDMM_INDEX_AGENTS`.

The study package checks it. `check_cohort_index_exclusions()`
(`variables/R/lineage.R`) reads `INDEX_EXCLUDED` for the cohort attempt the LOT
run used, resolves each agent in its `COHORT_INDEX_EXCLUSIONS` setting (default
`panobinostat,elotuzumab`, in `variables/config.csv`) to abbreviations through
`cl_mma_rollup.csv`, and stops unless every one of those abbreviations is
matched by a recorded pattern (with the same `LIKE` rules).
`COHORT_INDEX_EXCLUSIONS=none` checks nothing. So a cohort built without the
row above is refused by the study package wherever the rollup carries those
agents.

### Checks, waivers and ceilings

| setting | default | |
|---|---|---|
| `NDMM_WAIVERS` | (empty) | `codelist_ndc_shape`, `codelist_ndc_short`, `raw_icd_flag`, separated by `\|` (or `,` in the environment). The first two let a code-list NDC problem through; `raw_icd_flag` is accepted and does nothing. Asked-for and applied waivers are recorded apart in `NDMM_RUN_METADATA` |
| `NDMM_ICD_FLAG_MAX_ROWS` | (empty) | a whole number: stop if more claims than this name neither ICD family on a code this cohort reads. Empty reports and continues - `DECISIONS.md` section 11 |
| `NDMM_CONTRACT_OVERRIDE` | (unset) | `TRUE` builds under settings that differ from `CONTRACT`, recorded as a deviation |
| `NDMM_IGNORE_ACTIVE_RUN` | (unset) | `TRUE` gets past a `started` row a killed process left behind |

Run the first production build with no waivers and read the NDC profile it
prints.

## What it reads

Standalone: the raw Optum CDM and the production code lists, and no table
another build makes. Every raw table is checked before anything is written,
and a missing one is named.

| input | used for |
|---|---|
| `med_diagnosis` | the MM diagnosis, other cancer, pregnancy and trial diagnoses |
| `medical` | claim headers (inpatient status); therapy by `PROC_CD`, `BILL_PROC_CD` and `NDC`; pregnancy and trial procedure and revenue codes |
| `med_procedure` | therapy by `PROC`; pregnancy and trial ICD procedures |
| `rx` | therapy by `NDC` |
| `confinement` | inpatient stays |
| `member_enrollment` | continuous-enrolment spans (not the rollup; `DECISIONS.md` section 6) |
| `member_cont_enrollment` | sex and birth year |
| `dod` | date of death |

With `USE_QUARTERLY_TABLES=TRUE` each is read as its cumulative quarterly table
for the study end (`2026q1`).

Code lists, all from `CODELIST_DIR`, each required:

| file | used for |
|---|---|
| `mm_dx.csv` | the diagnosis that defines the population |
| `cl_mma_codelist.csv` | MM therapy - the 1L index, prior therapy, belantamab |
| `other_malig.csv` | the other-cancer exclusion |
| `pregnancy.csv` | the pregnancy exclusion |
| `clintrial.csv` | the descriptive clinical-trial flag |

The md5 and row count of each go to `NDMM_CODELIST_METADATA`.

The study period is 01 Jan 2018 through 31 Mar 2026.

## What it writes

All prefixed.

### The cohort, and what made it

| table | what it is |
|---|---|
| `NDMM_COHORT` | the cohort, one row per patient |
| `NDMM_ATTRITION` | the nine-step funnel - "The attrition" below |
| `NDMM_FLAGS_ALL` | one row per 1L candidate with each criterion's flag, and the advisory `NO_BELANTAMAB` |
| `NDMM_CLINTRIAL_FLAGS` | clinical-trial evidence around the 1L index - descriptive, not a filter |
| `NDMM_RUN_METADATA` | per run: prefix, belantamab abbreviation, index exclusions, MM-adjacent mode and labels, one md5 over the R code, `CONTRACT_SETTINGS`, waivers requested and applied, `FINDINGS`, `N_NDMM` |
| `NDMM_CODELIST_METADATA` | the md5 and row count of each code list read |
| `NDMM_BUILD_STATUS` | `started` / `complete` / `failed` per run and prefix, with `FINDINGS` and the prefixed cohort table name. What `check_no_active_run()` and the LOT build read |

The build's own list of what it writes is `OUTPUTS` in `R/build_ndmm.R`:
the deliverables, plus working tables. Every view read more than once
(`CHECKPOINTS`) is written to the work schema under its own name and the view
repointed at it, because Spark re-runs a view on every read. A checkpoint that
cannot be written stops the build.

### `NDMM_COHORT` is a LOT input

The LOT build can be pointed at it directly:

```
DATABRICKS_PWD=... Rscript lot/engine/build.R ndmm_NDMM_COHORT ndmm_
```

Pass the prefixed name: `lot` reads the cohort table exactly as named.

| column | |
|---|---|
| `PATID` | |
| `INDEX_DATE` | the 1L start - the NDMM index |
| `MM_DX_DT` | the qualifying diagnosis date |
| `ENDDATE` | the earlier of the study end and death |
| `ENDDATE_CE` | the earlier of `ENDDATE` and the end of the enrolment span (gaps of `GAP_DAYS` bridged) covering the index |
| `DEATH_DT` | constructed from month and year (`DECISIONS.md` section 8); a date before the index is set to the index |
| `GDR_CD`, `YRDOB` | sex and birth year |
| `AGE_INDEX_YR` | `year(INDEX_DATE) - YRDOB` |
| `FU_DAYS`, `FU_DAYS_CE` | days from the index to `ENDDATE`, and to `ENDDATE_CE` |

Everything that depends on the anchor is computed from `INDEX_DATE`; sex, birth
year and death are carried unchanged. `check_ndmm_cohort()` verifies the ten
columns `lot` requires (all but `MM_DX_DT`), one row per patient, no missing
`INDEX_DATE`, no `ENDDATE` before `INDEX_DATE`, no `FU_DAYS` below `FU_CE_DAYS`,
and a patient count equal to the last attrition step.

`followup_days.sql` is the follow-up distribution on both definitions, what
ended follow-up, and the same by index year, paste-and-run over this table;
only its last statement needs a LOT run.

### Clinical trial

`NDMM_CLINTRIAL_FLAGS` asks whether trial therapy came before the recorded 1L.
One row per patient with a 1L index, windows cut at the index:

| column | window |
|---|---|
| `CLINTRIAL_PRE_DX` | before the MM diagnosis |
| `CLINTRIAL_DX_TO_LOT1` | diagnosis to the day before 1L |
| `CLINTRIAL_POST_LOT1` | 1L onward - context, never evidence of a prior line |
| `CLINTRIAL_PRE_LOT1_12MO` | the 365 days before 1L - the window criterion 6 uses for prior therapy |
| `CLINTRIAL_FIRST_PRE_LOT1_DT`, `CLINTRIAL_DAYS_BEFORE_LOT1` | the earliest trial claim before 1L, and how many days before |
| `CLINTRIAL_FIRST_DX_TO_LOT1_DT`, `CLINTRIAL_DX_TO_LOT1_DAYS` | the same over diagnosis-to-1L only; NULL unless `CLINTRIAL_DX_TO_LOT1 = 1` |

The first three partition the study period and can be added; the fourth spans
the first two and cannot. The two timing pairs cover different windows so that
each matches the count it sits beside.

It is not a criterion. It is built after the flags and joins nothing into
them, so the cohort is the same with it and without it. A trial code names
neither the drug nor the condition, so a positive flag is a patient to review
rather than a proven prior line, and a zero is not proof that none occurred.
The diagnosis-to-1L interval varies from days to years, so
`CLINTRIAL_PRE_LOT1_12MO` is the more comparable figure between groups.

### The review tables

None of them changes the cohort. Each prices a rule that is still open, or
shows what a code list actually did, so a decision is made on a number.

| table | what it is for | decision |
|---|---|---|
| `NDMM_INDEX_AGENTS` | every `CL_MED_ABBR` on the code list: `ELIGIBLE` (0 = barred from setting the index) and `N_PATIENTS`, the patients whose index claim was that agent. Read it before barring an agent - it says what barring each costs | `DECISIONS.md` 3 |
| `NDMM_FU_CE_COUNTS` | criterion 5 at 0, 30, 60 and 90 days and at three calendar months (`add_months`): `N_PASSING_CRITERION_5`, and `N_COHORT`, the whole cohort at that window. `IS_THIS_RUN` marks the applied row; the gap to the 90-day row is what the one-day rule adds | `DECISIONS.md` 1, 7 |
| `NDMM_PREG_WINDOW_COUNTS` | criterion 8 over the study period (applied) and over the patient's own baseline plus follow-up: `N_WITH_PREG_CLAIM`, `N_EXCL_INCREMENTAL` (removed by this criterion alone) and `N_COHORT` | `DECISIONS.md` 9 |
| `NDMM_OTHER_MALIG_GROUPS` | every pairing group the other-cancer list resolves to (ICD category, or `MET`), with its code and label counts. A group holding one code can only confirm itself | `DECISIONS.md` 4 |
| `NDMM_OTHER_MALIG_GRAIN` | criterion 7 (`N_EXCLUDED` among 1L candidates) at six pairing grains: same label, as configured, metastatic codes kept apart by prefix, the collapse without `C77`/`196`, the collapse without `C800`/`1990`, and any label at all | `DECISIONS.md` 4 |
| `NDMM_OTHER_MALIG_CODES` | the other-cancer code list as this run applied it: each code with its label, ICD family, override flag and pairing groups | `DECISIONS.md` 4 |
| `NDMM_MM_ADJACENT_GROUPS` | every label containing `PLASMACYTOMA`, `PLASMA CELL`, `GAMMOPATHY` or `MYELOMA`, and every overridden label, with `OVERRIDDEN` and its code count. A plasma-cell label still excluding is named in the log | `DECISIONS.md` 4 |
| `NDMM_MM_ADJACENT_CODES` | every code kept as the index disease rather than another cancer, with the label that kept it | `DECISIONS.md` 4 |
| `NDMM_BELANTAMAB_RECONCILE` | every belantamab claim of a cohort member up to that patient's `ENDDATE`, with `DAYS_FROM_INDEX`. All are on or after the index (criterion 9 removed the rest), so `lot`'s `no_belantamab` removes every patient listed. Under `lot`'s `CENSOR_AT_DISENROLLMENT=TRUE` the count is an upper bound | `DECISIONS.md` 2 |

`NDMM_FU_CE_COUNTS` carries `RUN_ID`. `NDMM_PREG_WINDOW_COUNTS` is checked as
it is written: both rows must partition the same population, the narrower
window can only leave a larger cohort, and the applied row must equal the
cohort. A failure stops the run.

## The criteria as applied

In the order the attrition applies them. The reasoning for each is in
`DECISIONS.md`.

| # | criterion | as applied | source |
|---|---|---|---|
| 1 | MM diagnosis | one inpatient claim with a strict MM code (ICD-9-CM `203.0x`, ICD-10-CM `C90.0x`) that is on `mm_dx.csv`, or two outpatient claims with any `mm_dx.csv` code on separate days within `OUTPATIENT_WINDOW` (90) days. Any diagnosis position. Inpatient means a claim line with place of service 21, 51 or 61 or an inpatient type of service, or a valid confinement. Claims inside the study period. The diagnosis date is the earliest qualifying date | `00_mm_cohort.R` |
| 2 | Adult | `year(diagnosis) - YRDOB >= 18`, tested at the earliest qualifying date, so it can drop a patient but never move the date (`DECISIONS.md` section 12). No birth year, no entry | `00_mm_cohort.R` |
| 3 | Eligible 1L treatment | the first claim for an agent on `cl_mma_codelist.csv`, on or after the patient's diagnosis, on or after `LOT1_FROM` (2019-01-01) and on or before the study end. Five arms: `PROC_CD` (HCPCS, CPT), `BILL_PROC_CD` (HCPCS) and `NDC` in `medical`, `NDC` in `rx`, `PROC` in `med_procedure` (HCPCS, CPT). Steroids are dropped from the code list; belantamab and anything barred by `NDMM_INDEX_EXCLUDED_ABBRS` / `_CODES` cannot set it. That date is the index | `00b_lot1_index.R` |
| 4 | 12 months CE before the index | one enrolment span covering `[index - 365, index - 1]`, gaps of 30 days or fewer bridged | `01_enrollment.R`, `06_flags.R` |
| 5 | Follow-up CE | one no-gap span covering `[index, index + FU_CE_DAYS]`, cut at death and the study end but never before the index. `FU_CE_DAYS = 0`: enrolled on the index date | `06_flags.R` |
| 6 | No MM therapy in the baseline | no claim for an agent on `cl_mma_codelist.csv` in `[index - 365, index - 1]`, over the same five arms. Steroids (`DEX`, `DEXA`, `DEXAMETHASONE`, `PRED`, `PREDNISONE`) do not count | `03_prior_therapy.R` |
| 7 | No other cancer in the baseline | one inpatient claim, or two outpatient claims within 30 days in the same pairing group, all inside `[index - 365, index - 1]`. Inpatient as in criterion 1. The pairing group is the three-character ICD category, except that metastatic codes form one group. Codes on `mm_dx.csv` and the overridden plasma-cell labels do not count. `DECISIONS.md` section 4 | `04_other_malig.R` |
| 8 | No pregnancy | no pregnancy or childbirth diagnosis, procedure (`PROC_CD`, `BILL_PROC_CD`, ICD procedure) or revenue code anywhere in the study period, 2018-01-01 to 2026-03-31. `DECISIONS.md` section 9 | `05_pregnancy.R` |
| 9 | No belantamab before the index | no belantamab claim (`NDMM_BELANTAMAB_ABBR`) in the five arms, inside the study period and strictly before the index. The index-onward half is `lot`'s `no_belantamab`. `DECISIONS.md` section 2 | `00b_lot1_index.R`, `06_flags.R` |

The flag criteria (4 to 9) are one list, `NDMM_CRITERIA` in `R/build_ndmm.R`:
the cohort is their conjunction, each attrition row is a prefix of it, and each
review table drops the one criterion it varies. They cannot disagree about what
the criteria are.

Belantamab is matched by drug, as one whole `CL_MED_ABBR`, the same way `lot`
matches it. The build stops if that abbreviation matches no row of the code
list, or if the list carries another `BEL*` abbreviation it does not name.
Confirm `NDMM_BELANTAMAB_ABBR` against the production code list before the
first run.

Clinical-trial participation is not a criterion of this cohort.

### Thresholds to confirm

These have been written with different comparison signs in different places.
The build applies the right-hand column.

| criterion | also written as | this build |
|---|---|---|
| enrolment gaps | `< 30 days` | `<= 30 days` |
| other cancer | `>1 IP or >2 OP` | `>=1 IP or >=2 OP` |
| adult age | `> 18` | `>=18` |
| outpatient MM diagnosis | `> 2 claims` | `>=2 claims` |

## The attrition

`NDMM_ATTRITION`, one row per step: the inclusions, then the four exclusions in
the study's order, belantamab last. The final cohort is the same conjunction in
any order; the per-step counts are not.

| # | `CRITERION` | criterion |
|---|---|---|
| 1 | Patients with a qualifying MM diagnosis | 1 |
| 2 | + aged 18 or over at diagnosis | 2 |
| 3 | + eligible 1L treatment on or after LOT1_FROM | 3 |
| 4 | + 12-month CE before index | 4 |
| 5 | + CE during follow-up | 5 |
| 6 | + no MM oncology therapy in 12-month baseline | 6 |
| 7 | + no other cancer in 12-month baseline | 7 |
| 8 | + no pregnancy in study period | 8 |
| 9 | + no belantamab before the 1L index | 9 |

| column | |
|---|---|
| `RUN_ID` | which run wrote the row; a run's rows are replaced as one unit |
| `STEP_NUM` | 1-9 |
| `CRITERION` | the label above |
| `N_PATIENTS` | distinct patients still in at that step |
| `PCT_OF_START` | percentage of step 1, two decimals |
| `RECORDED_AT` | when |

From step 4 each row is one more `AND` on the same `NDMM_FLAGS_ALL` row, so the
funnel can only narrow.

**The last row is not the study's N.** Step 9 removes belantamab before the
index only; `lot` removes belantamab from the index onward. The final study
population is the patients in `LOT_LONG_FINAL`, and the final count is the last
row of `LOT_ATTRITION` - `DECISIONS.md` section 2. `NDMM_BELANTAMAB_RECONCILE`
lists who `lot` will remove.

## What stops a run

On any stop after the run is marked `started`, its `NDMM_BUILD_STATUS` row is
set to `failed`, carrying whatever `FINDINGS` it had.

Before anything is written - the checks under "Settings": a malformed setting,
no output schema or prefix, a contract difference without the override, a run
choice outside its values, constants that disagree with the settings, no
`DATABRICKS_PWD`, another run `started` on the prefix, or an unreadable raw
CDM table.

While running:

- **Code lists.** A missing directory or file, a file not among the five, a
  missing column, no rows, or a file that changed while it was read. An
  `icd_family` value other than `9`, `ICD9`, `ICD-9`, `ICD9DIAG`, `10`,
  `ICD10`, `ICD-10`, `ICD10DIAG`. In `cl_mma_codelist.csv`: a code type other
  than HCPCS, CPT or NDC, a code naming more than one medication, a blank
  `CL_MED_ABBR`. In `pregnancy.csv` or `clintrial.csv`: no usable codes, or a
  code type the scan does not produce (it produces `ICD9DIAG`, `ICD10DIAG`,
  `ICD9PROC`, `ICD10PROC`, `HCPCS`, `REV`).
- **NDC shape.** `check_ndc_shape()` profiles NDCs on both sides of the join
  before the therapy scans. A code-list NDC that cannot be an NDC
  (`codelist_ndc_shape`) or has ten digits (`codelist_ndc_short` - write it as
  NDC11) stops the build unless waived. Claim-side problems are reported only:
  a claim NDC is keyed only when it has ten digits (padded on the 4-4-2
  layout) or eleven, so anything else matches nothing.
- **Names that match nothing.** `NDMM_BELANTAMAB_ABBR` matching no row, or
  another `BEL*` abbreviation on the list; an `NDMM_INDEX_EXCLUDED_ABBRS` or
  `_CODES` entry matching no row; an MM-adjacent label the current
  `NDMM_MM_ADJACENT_STATES` mode requires missing from `other_malig.csv`.
- **ICD_FLAG.** Claims whose `ICD_FLAG` names neither family, on a code this
  cohort reads, are reported, not stopped on: the log and `FINDINGS` carry
  `raw_icd_flag(<rows>, <patient-hits>, <codes>; ...)` with each code and its
  list, and every run records `icd_ceiling(...)`. The run stops if either
  count cannot be read, or if the rows exceed `NDMM_ICD_FLAG_MAX_ROWS`.
  Because a stopped run never writes `NDMM_RUN_METADATA`, the findings are also
  on its `NDMM_BUILD_STATUS` row. `DECISIONS.md` section 11.
- **Its own output.** A checkpoint that cannot be written; a trial-flag row
  with no diagnosis date; an inconsistent `NDMM_PREG_WINDOW_COUNTS`; an
  attrition step larger than the one above it; an empty cohort; any failure of
  `check_ndmm_cohort()`; a code list with no recorded hash; a column that
  cannot be added to an existing metadata table.

## The 2L and 3L cohorts

Run after the LOT build over the same prefix, because their index dates are
line starts:

```
DATABRICKS_PWD=... Rscript ndmm/build_subsequent_cohorts.R ndmm_
```

2L is drawn from the 1L cohort and 3L from the 2L cohort. Three criteria, each
at that line's start (the patient's `LOT_NUM` 2 or 3 row in `LOT_LONG_FINAL`):

1. received that line;
2. CE for `SUBSEQ_PRE_DAYS` (365) days before it, over the same gap-bridged
   spans as the 1L cohort (`NDMM_ENROLL_SPANS`);
3. CE for `SUBSEQ_FU_CE_DAYS` (90) days from it with no gaps
   (`NDMM_ENROLL_SPANS_STRICT`), or death inside that window. The study end
   does not shorten it: a living patient whose window runs past the data has
   not shown the enrolment.

Receiving the lines in order is guaranteed anyway; what the chain adds is that
the earlier cohort's windows were met too. `N_EXCLUDED_BY_PRIOR` counts the
patients who meet 3L's own criteria off the 1L cohort but are not in the 2L
cohort.

| setting | default | |
|---|---|---|
| `SUBSEQ_PRE_DAYS` | `365` | days of CE before the line's start |
| `SUBSEQ_FU_CE_DAYS` | `90` | days of CE after it, or death |
| `NDMM_SUBSEQ_OVERRIDE` | (unset) | `TRUE` builds under other windows, logged as a sensitivity |
| `NDMM_SUBSEQ_IGNORE_ACTIVE_RUN` | (unset) | `TRUE` gets past another attempt marked `started` |
| `NDMM_SUBSEQ_ALLOW_UNPROVEN` | (unset) | `TRUE` accepts a lineage that cannot be proven, logged |

`subseq_check_windows()` stops on any pair other than 365 and 90 unless
`NDMM_SUBSEQ_OVERRIDE=TRUE`, because a different pair is a different cohort
under the same table names. It runs first, then the same preflight as the 1L
build. The gap allowance is the 1L build's, baked into its span tables.
`DECISIONS.md` section 7 records why months are day counts.

It refuses to run unless the newest `LOT_BUILD_STATUS` row is `complete`, was
built from `<prefix>NDMM_COHORT`, carries no `CONTRACT_DEVIATIONS`, and names
(in `LOT_RUN_METADATA.COHORT_RUN_ID` and `COHORT_STAMP`) the cohort attempt
`NDMM_BUILD_STATUS` holds now - a re-run of the 1L build replaces the cohort
and both span tables in place. A proven mismatch always stops. Missing proof
(no `NDMM_BUILD_STATUS` row, no recorded cohort attempt or stamp, no
`INPUT_COHORT_TABLE`, no `CONTRACT_DEVIATIONS` column) stops unless
`NDMM_SUBSEQ_ALLOW_UNPROVEN=TRUE`.

Writes `NDMM_COHORT_2L`, `NDMM_COHORT_3L` and `NDMM_SUBSEQUENT_ATTRITION` (per
cohort: `N_FROM`, `N_REACHED_LOT`, `N_CE_PRE`, `N_FINAL`,
`N_EXCLUDED_BY_PRIOR`). All three carry `CE_PRE_DAYS`, `CE_FU_DAYS`,
`SUBSEQ_RUN_ID` and `SUBSEQ_ATTEMPT`, minted per call; the cohorts also carry
the LOT run and cohort attempt they came from. The three are replaced one at a
time, so a run that died part-way leaves them with different
`SUBSEQ_ATTEMPT`s. `NDMM_SUBSEQ_BUILD_STATUS` records each attempt as
`started`, `complete` or `failed`. Nothing else in this delivery reads these
three tables.
