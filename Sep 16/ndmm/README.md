# NDMM (1L newly diagnosed multiple myeloma) cohort

Stage 1 of the study pipeline. Builds the 1L NDMM cohort and its attrition for
one cohort prefix and, once the LOT build has run, the 2L and 3L subset
cohorts. Why each rule reads the way it does, what it moves and whether it is
signed off is `DECISIONS.md`, cited below as "DECISIONS" and a section
number.

## In brief

Newly diagnosed multiple myeloma, one row per patient, indexed at the first
eligible first-line treatment on or after 2019-01-01, over the study period
2018-01-01 to 2026-03-31. Nine criteria, applied in order and counted in
`NDMM_ATTRITION` ("The criteria as applied"). Before reading a count:

- Panobinostat and elotuzumab must be barred from setting the index in
  `config.csv` ("Barring agents from the 1L index"); the study package refuses
  a cohort that did not bar them (DECISIONS 3).
- Follow-up enrolment is one day - enrolled on the index date. The 2L and 3L
  cohorts use 90 days (DECISIONS 1).
- This cohort removes belantamab before the index only; the LOT build removes
  it from the index onward, so this cohort's count is not the study's final N
  (DECISIONS 2).
- Several rules are still open; each is priced on every run ("The sensitivity
  tables").

## Running it

```
DATABRICKS_PWD=... Rscript ndmm/build.R <prefix_>
DATABRICKS_PWD=... Rscript ndmm/build.R ndmm_
```

The prefix can be set as `OBJECT_PREFIX` instead. It must be a name ending in
`_`. Every table the build reads from or writes to the work schema is named
work schema + prefix + table, so two cohorts sit side by side in one schema.
`build.R` builds the 1L cohort only; the 2L and 3L cohorts are
`build_subsequent_cohorts.R`, run after the LOT build ("The 2L and 3L
cohorts").

The tests need no warehouse:

```
Rscript ndmm/tests/test_runner.R
Rscript ndmm/tests/test_subsequent.R
```

**One run per prefix at a time.** Table names carry no run id, so two runs on
one prefix would replace tables the other is reading. `check_no_active_run()`
refuses a run while `NDMM_BUILD_STATUS` has a `started` row for the prefix.
Runs on different prefixes are safe. It is a check, not a lock: two runs
starting at the same moment can both pass it. A killed process leaves its
`started` row behind; `NDMM_IGNORE_ACTIVE_RUN=TRUE` gets past it, and should be
set only once the named run is known to be dead. A missing status table is the
first run on the prefix and passes; any other failure to read it stops the run
unless `NDMM_IGNORE_ACTIVE_RUN=TRUE`.

**Re-running.** A re-run inside one Domino execution keeps its run id
(`DOMINO_RUN_ID`). Before the first step, this run id's rows are deleted from
`NDMM_ATTRITION`, `NDMM_RUN_METADATA` and `NDMM_CODELIST_METADATA`, so a failed
attempt cannot leave a row describing a cohort this attempt did not build. A
delete that is refused stops the run.

**The run log.** Everything the run prints - log lines, QC tables, warnings and
the `ERROR:` line it stopped on - goes to the console and to one file:
`PIPELINE_LOG_FILE` if set, otherwise `OUTPUT_DIR/pipeline_run_<time>_<pid>.log`.
If a named `PIPELINE_LOG_FILE` cannot be written the run logs to the console
only; if the default location cannot be written it logs to R's temporary
folder and says so, because that folder is deleted when the process exits.

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
then `check_no_active_run` and `check_upstream` (every raw CDM table readable).
Nothing is written until every one passes, so a refused run leaves the prefix
as it found it.

- `check_settings` refuses malformed values: dates that are not `YYYY-MM-DD`;
  `PRE_LOT1_DAYS`, `FU_CE_DAYS`, `GAP_DAYS`, `MIN_AGE`, `OUTPATIENT_WINDOW` or
  `NDMM_ICD_FLAG_MAX_ROWS` that are not whole numbers; an unknown
  `NDMM_WAIVERS` name; a `DOMINO_RUN_ID` with characters other than letters,
  digits, `_ . -`; and any value in `NDMM_LOT1_FROM` (the setting is
  `LOT1_FROM`).
- `check_contract` compares the resolved settings with `CONTRACT` in
  `R/build_ndmm.R` and stops on any difference, because a different value there
  is a different cohort. `NDMM_CONTRACT_OVERRIDE=TRUE` says the difference is
  meant: the run goes through, logs a warning, and records each difference as
  `contract deviation: ...` in `NDMM_BUILD_STATUS.FINDINGS` and
  `NDMM_RUN_METADATA.FINDINGS`. `NDMM_RUN_METADATA.CONTRACT_SETTINGS`
  (`key=value|key=value`) carries the values the run used.
- `check_choices` holds each run choice to the values it may take.
- `check_constants` compares the `NDMM_*` constants the SQL interpolates
  (`R/ndmm_constants.R`, `R/standalone_constants.R`) with the resolved settings
  and stops if they differ. Each constant reads the same variable as its
  setting, so one entry in `config.csv` or the environment moves both.

The study package (`variables/`) reads `CONTRACT_SETTINGS` back and stops if
its own `STUDY_START`, `STUDY_END` or `LOT1_INDEX_FROM` differ from the
cohort's `study_start`, `study_end` or `lot1_from` (its `SETTINGS_OVERRIDE=TRUE`
proceeds and records the disagreement). A moved window has to be moved in both.

### To run at all

| setting | default | |
|---|---|---|
| `DATABRICKS_PWD` | (none) | required, environment only |
| `DATABRICKS_DSN` | `RWDE` | ODBC data source |
| `PROJECT_WORK_SCHEMA` | (none) | where tables go. Falls back to `DOMINO_USER_NAME`, then `DOMINO_STARTING_USERNAME`; with none of the three the run stops rather than writing somewhere shared |
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
| `NDMM_BELANTAMAB_ABBR` | `BELA` | the `CL_MED_ABBR` that is belantamab. Must equal `lot`'s `BELANTAMAB_MED_ABBR`; confirm it against the production code list before the first run |
| `TBL_CONFINEMENT` | `confinement` | inpatient stays |
| `TBL_MEMBER_ENROLLMENT` | `member_enrollment` | enrolment spans |
| `TBL_MEMBER_ELIG` | `member_cont_enrollment` | sex and birth year |
| `TBL_DOD` | `dod` | date of death |

### Run choices

Validated against what they may take, recorded in `NDMM_RUN_METADATA`, and not
pinned.

| choice | default | may be |
|---|---|---|
| `NDMM_MM_ADJACENT_STATES` | `override` | `override`, `exclude`, `mgus_only`, `none` - which plasma-cell labels do not count as another cancer (DECISIONS 4) |
| `NDMM_INDEX_EXCLUDED_ABBRS` | (empty) | `CL_MED_ABBR` patterns barred from setting the 1L index, separated by `\|` - below |
| `NDMM_INDEX_EXCLUDED_CODES` | (empty) | the same by code, `TYPE:CODE` or a bare code, separated by `\|` |

The two exclusion settings may hold only letters, digits, space and
`_ , : | % . -`; anything else stops the run.

### Barring agents from the 1L index

The study's I3 bars panobinostat and elotuzumab from setting the 1L index
(`variables/IE_CRITERIA.md` "I3. Eligible 1L treatment"). The build bars
belantamab itself; name the others in `config.csv`:

```
NDMM_INDEX_EXCLUDED_ABBRS,PANO|ELOT,Exclude panobinostat and elotuzumab from eligible 1L index treatment
```

Separate entries with `|`. The code splits on `,` as well, but in `config.csv`
a comma survives only while the value stays quoted, and an editor that drops
the quotes splits the row so that only the first entry is applied.

- Each entry is trimmed, upper-cased and matched as a SQL `LIKE` pattern
  against the code list's `CL_MED_ABBR` (also trimmed and upper-cased). With no
  wildcard it is a whole-abbreviation match; `%` matches any run of characters
  (`PANO%`), and `_` matches any one.
- The abbreviations must be the ones on the production `cl_mma_codelist.csv`.
  An entry matching no row stops the build.
- `NDMM_INDEX_EXCLUDED_CODES` works the same way for a code
  (`HCPCS:J9999|NDC:12345678901`, or a bare code for every type), compared
  exactly with the code list's code after punctuation is stripped and letters
  are upper-cased.
- A barred agent's claims cannot set the index; the next eligible claim does.
  It does not exclude the patient, and its claims still count as MM therapy for
  criterion 6.

The run records what it barred: `NDMM_RUN_METADATA.INDEX_EXCLUDED` and
`INDEX_EXCLUDED_CODES`, the log line `Barred from setting the index, beyond
belantamab: ...`, and `ELIGIBLE = 0` on each barred agent's row of
`NDMM_INDEX_AGENTS`. The study package's `check_cohort_index_exclusions()`
(`variables/R/lineage.R`) reads `INDEX_EXCLUDED`, resolves each agent in its
`COHORT_INDEX_EXCLUSIONS` setting (default `panobinostat,elotuzumab`) to
abbreviations through `cl_mma_rollup.csv`, and stops unless a recorded pattern
matches every one. So a cohort built without the row above is refused wherever
the rollup carries those agents.

### Checks, waivers and ceilings

| setting | default | |
|---|---|---|
| `NDMM_WAIVERS` | (empty) | `codelist_ndc_shape`, `codelist_ndc_short`, `raw_icd_flag`, separated by `\|` (or `,` in the environment). The first two let a code-list NDC problem through; `raw_icd_flag` is accepted and does nothing. Requested and applied waivers are recorded apart in `NDMM_RUN_METADATA` |
| `NDMM_ICD_FLAG_MAX_ROWS` | (empty) | a whole number: stop if more claims than this name neither ICD family on a code this cohort reads. Empty reports and continues (DECISIONS 11) |
| `NDMM_CONTRACT_OVERRIDE` | (unset) | `TRUE` builds under settings that differ from `CONTRACT`, recorded as a deviation |
| `NDMM_IGNORE_ACTIVE_RUN` | (unset) | `TRUE` gets past a `started` row a killed process left behind |

Run the first production build with no waivers and read the NDC profile it
prints.

## What it reads

The raw Optum CDM and the production code lists, and no table another build
makes. With `USE_QUARTERLY_TABLES=TRUE` each CDM table is read as its
cumulative quarterly table for the study end.

| input | used for |
|---|---|
| `med_diagnosis` | the MM diagnosis, other cancer, pregnancy and trial diagnoses |
| `medical` | claim headers (inpatient status); therapy by `PROC_CD`, `BILL_PROC_CD` and `NDC`; pregnancy and trial procedure and revenue codes |
| `med_procedure` | therapy by `PROC`; pregnancy and trial ICD procedures |
| `rx` | therapy by `NDC` |
| `confinement` | inpatient stays |
| `member_enrollment` | continuous-enrolment spans (not the rollup; DECISIONS 6) |
| `member_cont_enrollment` | sex and birth year |
| `dod` | date of death |

Code lists, all from `CODELIST_DIR`, each required; the md5 and row count of
each go to `NDMM_CODELIST_METADATA`:

| file | used for |
|---|---|
| `mm_dx.csv` | the diagnosis that defines the population |
| `cl_mma_codelist.csv` | MM therapy - the 1L index, prior therapy, belantamab |
| `other_malig.csv` | the other-cancer exclusion |
| `pregnancy.csv` | the pregnancy exclusion |
| `clintrial.csv` | the descriptive clinical-trial flag |

## What it writes

All prefixed.

| table | what it is |
|---|---|
| `NDMM_COHORT` | the cohort, one row per patient - below |
| `NDMM_ATTRITION` | the nine-step funnel ("The attrition") |
| `NDMM_FLAGS_ALL` | one row per 1L candidate with each criterion's flag, and the advisory `NO_BELANTAMAB` |
| `NDMM_CLINTRIAL_FLAGS` | clinical-trial evidence around the 1L index - below |
| `NDMM_RUN_METADATA` | per run: prefix, belantamab abbreviation, index exclusions, MM-adjacent mode and labels, one md5 over the R code, `CONTRACT_SETTINGS`, waivers requested and applied, `FINDINGS`, `N_NDMM` |
| `NDMM_CODELIST_METADATA` | the md5 and row count of each code list read |
| `NDMM_BUILD_STATUS` | `started` / `complete` / `failed` per run and prefix, with `FINDINGS` and the prefixed cohort table name. Read by `check_no_active_run()` and the LOT build |

The full list is `OUTPUTS` in `R/build_ndmm.R`: the tables above and below,
plus working tables. Every view read more than once (`CHECKPOINTS`) is written
to the work schema under its own name and the view repointed at it, because
Spark re-runs a view on every read. A checkpoint that cannot be written stops
the build.

### `NDMM_COHORT` is a LOT input

```
DATABRICKS_PWD=... Rscript lot/engine/build.R ndmm_NDMM_COHORT ndmm_
```

Pass the prefixed name: `lot` reads the cohort table exactly as named, and must
use the same study window (DECISIONS 5).

| column | |
|---|---|
| `PATID` | |
| `INDEX_DATE` | the 1L start - the NDMM index |
| `MM_DX_DT` | the qualifying diagnosis date |
| `ENDDATE` | the earlier of the study end and death |
| `ENDDATE_CE` | the earlier of `ENDDATE` and the end of the enrolment span (gaps of `GAP_DAYS` bridged) covering the index |
| `DEATH_DT` | constructed from month and year (DECISIONS 8); a date before the index is set to the index |
| `GDR_CD`, `YRDOB` | sex and birth year |
| `AGE_INDEX_YR` | `year(INDEX_DATE) - YRDOB` |
| `FU_DAYS`, `FU_DAYS_CE` | days from the index to `ENDDATE`, and to `ENDDATE_CE` |

`check_ndmm_cohort()` verifies the ten columns `lot` requires (all but
`MM_DX_DT`), one row per patient, no missing `INDEX_DATE`, no `ENDDATE` before
`INDEX_DATE`, no `FU_DAYS` below `FU_CE_DAYS`, and a patient count equal to the
last attrition step.

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
the first two and cannot. It is not a criterion: it is built after the flags
and joins nothing into them. A trial code names neither the drug nor the
condition, so a positive flag is a patient to look at rather than a proven
prior line, and a zero is not proof that none occurred. The diagnosis-to-1L
interval varies from days to years, so `CLINTRIAL_PRE_LOT1_12MO` is the more
comparable figure between groups.

### The sensitivity tables

None of them changes the cohort. Each prices a rule that is still open, or
shows what a code list actually did, so a decision is made on a number.

| table | what it is for | DECISIONS |
|---|---|---|
| `NDMM_INDEX_AGENTS` | every `CL_MED_ABBR` on the code list: `ELIGIBLE` (0 = barred from setting the index) and `N_PATIENTS`, the patients whose index claim was that agent. Read it before barring an agent | 3 |
| `NDMM_FU_CE_COUNTS` | criterion 5 at 0, 30, 60 and 90 days and at three calendar months (`add_months`): `N_PASSING_CRITERION_5`, and `N_COHORT`, the whole cohort at that window. `IS_THIS_RUN` marks the applied row; carries `RUN_ID` | 1, 7 |
| `NDMM_PREG_WINDOW_COUNTS` | criterion 8 over the study period (applied) and over the patient's own baseline plus follow-up: `N_WITH_PREG_CLAIM`, `N_EXCL_INCREMENTAL` and `N_COHORT` | 9 |
| `NDMM_OTHER_MALIG_GROUPS` | every pairing group the other-cancer list resolves to (ICD category, or `MET`), with its code and label counts. A group holding one code can only confirm itself | 4 |
| `NDMM_OTHER_MALIG_GRAIN` | criterion 7 (`N_EXCLUDED` among 1L candidates) at six pairing grains: `same code-list label`, `as configured`, `mets kept apart by prefix`, `collapse without C77/196`, `collapse without C800/1990`, `any label at all` | 4 |
| `NDMM_OTHER_MALIG_CODES` | the other-cancer code list as this run applied it: each code with its label, ICD family, override flag and pairing groups | 4 |
| `NDMM_MM_ADJACENT_GROUPS` | every label containing `PLASMACYTOMA`, `PLASMA CELL`, `GAMMOPATHY` or `MYELOMA`, and every overridden label, with `OVERRIDDEN` and its code count. A plasma-cell label still excluding is named in the log | 4 |
| `NDMM_MM_ADJACENT_CODES` | every code kept as the index disease rather than another cancer, with the label that kept it | 4 |
| `NDMM_BELANTAMAB_RECONCILE` | every belantamab claim of a cohort member up to that patient's `ENDDATE`, with `DAYS_FROM_INDEX`. All are on or after the index, so `lot`'s `no_belantamab` removes every patient listed. Under `lot`'s `CENSOR_AT_DISENROLLMENT=TRUE` the count is an upper bound | 2 |

`NDMM_PREG_WINDOW_COUNTS` is checked as it is written: both rows must
partition the same population, the narrower window can only leave a larger
cohort, and the applied row must equal the cohort. A failure stops the run.

## The criteria as applied

In the order the attrition applies them.

| # | criterion | as applied | source |
|---|---|---|---|
| 1 | MM diagnosis | one inpatient claim with a strict MM code (ICD-9-CM `203.0x`, ICD-10-CM `C90.0x`) that is on `mm_dx.csv`, or two outpatient claims with any `mm_dx.csv` code on separate days within `OUTPATIENT_WINDOW` (90) days. Any diagnosis position. Inpatient means a claim line with place of service 21, 51 or 61 or an inpatient type of service, or a valid confinement. Claims inside the study period. The diagnosis date is the earliest qualifying date | `00_mm_cohort.R` |
| 2 | Adult | `year(diagnosis) - YRDOB >= 18`, tested at the earliest qualifying date, so it can drop a patient but never move the date (DECISIONS 12). No birth year, no entry | `00_mm_cohort.R` |
| 3 | Eligible 1L treatment | the first claim for an agent on `cl_mma_codelist.csv`, on or after the patient's diagnosis, on or after `LOT1_FROM` (2019-01-01) and on or before the study end. Five arms: `PROC_CD` (HCPCS, CPT), `BILL_PROC_CD` (HCPCS) and `NDC` in `medical`, `NDC` in `rx`, `PROC` in `med_procedure` (HCPCS, CPT). Steroids are dropped from the code list; belantamab and anything barred by `NDMM_INDEX_EXCLUDED_ABBRS` / `_CODES` cannot set it. That date is the index (DECISIONS 3) | `00b_lot1_index.R` |
| 4 | 12 months CE before the index | one enrolment span covering `[index - 365, index - 1]`, gaps of 30 days or fewer bridged | `01_enrollment.R`, `06_flags.R` |
| 5 | Follow-up CE | one no-gap span covering `[index, index + FU_CE_DAYS]`, cut at death and the study end but never before the index. `FU_CE_DAYS = 0`: enrolled on the index date (DECISIONS 1) | `06_flags.R` |
| 6 | No MM therapy in the baseline | no claim for an agent on `cl_mma_codelist.csv` in `[index - 365, index - 1]`, over the same five arms. Steroids (`DEX`, `DEXA`, `DEXAMETHASONE`, `PRED`, `PREDNISONE`) do not count | `03_prior_therapy.R` |
| 7 | No other cancer in the baseline | one inpatient claim, or two outpatient claims within 30 days in the same pairing group, all inside `[index - 365, index - 1]`. Inpatient as in criterion 1. The pairing group is the three-character ICD category, except that metastatic codes form one group. Codes on `mm_dx.csv` and the overridden plasma-cell labels do not count (DECISIONS 4) | `04_other_malig.R` |
| 8 | No pregnancy | no pregnancy or childbirth diagnosis, procedure (`PROC_CD`, `BILL_PROC_CD`, ICD procedure) or revenue code anywhere in the study period (DECISIONS 9) | `05_pregnancy.R` |
| 9 | No belantamab before the index | no belantamab claim (`NDMM_BELANTAMAB_ABBR`) in the five arms, inside the study period and strictly before the index. The index-onward half is `lot`'s `no_belantamab` (DECISIONS 2) | `00b_lot1_index.R`, `06_flags.R` |

The flag criteria (4 to 9) are one list, `NDMM_CRITERIA` in `R/build_ndmm.R`:
the cohort is their conjunction, each attrition row is a prefix of it, and each
sensitivity table drops the one criterion it varies.

## The attrition

`NDMM_ATTRITION`, one row per step: the inclusions, then the four exclusions in
the study's order, belantamab last. The final cohort is the same conjunction in
any order; the per-step counts are not.

| `STEP_NUM` | `CRITERION` |
|---|---|
| 1 | Patients with a qualifying MM diagnosis |
| 2 | + aged 18 or over at diagnosis |
| 3 | + eligible 1L treatment on or after LOT1_FROM |
| 4 | + 12-month CE before index |
| 5 | + CE during follow-up |
| 6 | + no MM oncology therapy in 12-month baseline |
| 7 | + no other cancer in 12-month baseline |
| 8 | + no pregnancy in study period |
| 9 | + no belantamab before the 1L index |

Columns: `RUN_ID` (a run's rows are replaced as one unit), `STEP_NUM`,
`CRITERION`, `N_PATIENTS` (distinct patients still in), `PCT_OF_START`
(percentage of step 1, two decimals), `RECORDED_AT`. From step 4 each row is
one more `AND` on the same `NDMM_FLAGS_ALL` row, so the funnel can only narrow.

**The last row is not the study's N.** The final study population is the
patients in `LOT_LONG_FINAL`, and the final count is the last row of
`LOT_ATTRITION` (DECISIONS 2). `NDMM_BELANTAMAB_RECONCILE` lists who `lot`
will remove.

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
- **ICD_FLAG.** The claims whose `ICD_FLAG` names neither family exceed
  `NDMM_ICD_FLAG_MAX_ROWS`, or either count cannot be read. Otherwise they are
  reported in the log and `FINDINGS` and the run continues (DECISIONS 11).
- **Its own tables.** A checkpoint that cannot be written; a trial-flag row
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
cohort. The 1L follow-up rule is one day and these cohorts' is 90, so the
cohorts are not comparable on that axis. A patient outside the 2L cohort still
has a 2L line in the LOT tables; these are cohorts, not flags on lines.

| setting | default | |
|---|---|---|
| `SUBSEQ_PRE_DAYS` | `365` | days of CE before the line's start |
| `SUBSEQ_FU_CE_DAYS` | `90` | days of CE after it, or death |
| `NDMM_SUBSEQ_OVERRIDE` | (unset) | `TRUE` builds under other windows, logged as a sensitivity |
| `NDMM_SUBSEQ_IGNORE_ACTIVE_RUN` | (unset) | `TRUE` gets past another attempt marked `started` |
| `NDMM_SUBSEQ_ALLOW_UNPROVEN` | (unset) | `TRUE` accepts a lineage that cannot be proven, logged |

`subseq_check_windows()` stops on any pair other than 365 and 90 unless
`NDMM_SUBSEQ_OVERRIDE=TRUE`, because a different pair is a different cohort
under the same table names (DECISIONS 7). It runs first, then the same
preflight as the 1L build. The gap allowance is the 1L build's, baked into its
span tables.

It refuses to run unless the newest `LOT_BUILD_STATUS` row is `complete`, was
built from `<prefix>NDMM_COHORT`, carries no `CONTRACT_DEVIATIONS`, and names
(in `LOT_RUN_METADATA.COHORT_RUN_ID` and `COHORT_STAMP`) the cohort attempt
that `NDMM_BUILD_STATUS` holds, because a re-run of the 1L build replaces the
cohort and both span tables in place. A proven mismatch always stops. Missing
proof (no `NDMM_BUILD_STATUS` row, no recorded cohort attempt or stamp, no
`INPUT_COHORT_TABLE`, no `CONTRACT_DEVIATIONS` column) stops unless
`NDMM_SUBSEQ_ALLOW_UNPROVEN=TRUE`.

Writes `NDMM_COHORT_2L`, `NDMM_COHORT_3L` and `NDMM_SUBSEQUENT_ATTRITION` (per
cohort: `N_FROM`, `N_REACHED_LOT`, `N_CE_PRE`, `N_FINAL`,
`N_EXCLUDED_BY_PRIOR`). All three carry `CE_PRE_DAYS`, `CE_FU_DAYS`,
`SUBSEQ_RUN_ID` and `SUBSEQ_ATTEMPT`, minted per call; the cohorts also carry
the LOT run and cohort attempt they came from. The three are replaced one at a
time, so a run that died part-way leaves them with different
`SUBSEQ_ATTEMPT`s. `NDMM_SUBSEQ_BUILD_STATUS` records each attempt as
`started`, `complete` or `failed`. Nothing else in the pipeline reads these
three tables.

## Files

| path | what it does |
|---|---|
| `build.R` | entry point for the 1L cohort, one prefix per run |
| `build_subsequent_cohorts.R` | entry point for the 2L and 3L cohorts |
| `config.csv` | every default setting; the prefix and the password are not here |
| `R/build_ndmm.R` | the runner: `CONTRACT`, `CHOICES`, `CHECKPOINTS`, `OUTPUTS`, the preflight checks, `NDMM_CRITERIA` and the attrition, the NDC and `ICD_FLAG` checks, the cohort table, metadata and status |
| `R/build_subsequent.R` | the 2L and 3L cohorts: window check, lineage checks, attrition |
| `R/load_inputs.R` | reads `config.csv` into the environment as defaults |
| `R/config.R` | the settings, read from the environment |
| `R/codelists.R` | loads the five code lists, checks columns and `icd_family`, records each md5 |
| `R/db_utils.R` | the run log, naming (the prefix is added here), quarterly CDM table names, NDC keys, retries, the step runner |
| `R/ndmm_constants.R`, `R/standalone_constants.R` | view names, windows the SQL reads, belantamab abbreviation, index exclusions, MM-adjacent labels and modes, steroid list, metastatic prefixes |
| `R/steps/00_mm_cohort.R` | criteria 1 and 2, demographics, constructed death dates |
| `R/steps/00b_lot1_index.R` | criterion 3 and the belantamab claims for criterion 9; writes `NDMM_INDEX_AGENTS`, `NDMM_OTHER_MALIG_GROUPS`, `NDMM_OTHER_MALIG_GRAIN`, `NDMM_FU_CE_COUNTS`, `NDMM_BELANTAMAB_RECONCILE`, `NDMM_MM_ADJACENT_GROUPS`, `NDMM_MM_ADJACENT_CODES` |
| `R/steps/01_enrollment.R` | enrolment spans, gap-bridged and no-gap |
| `R/steps/02_lot1_starts.R` | a comment only |
| `R/steps/03_prior_therapy.R` | the MM therapy code list (steroids dropped), its checks, criterion 6 |
| `R/steps/04_other_malig.R` | criterion 7 |
| `R/steps/05_pregnancy.R`, `R/steps/05b_preg_window.R` | criterion 8; `NDMM_PREG_WINDOW_COUNTS` and its checks |
| `R/steps/06_flags.R` | `NDMM_FLAGS_ALL` and the cohort defined over it |
| `R/steps/07_cohort.R` | the attrition counts |
| `R/steps/08_clintrial.R` | `NDMM_CLINTRIAL_FLAGS` |
| `tests/test_runner.R`, `tests/test_subsequent.R`, `tests/testutil.R` | tests of the 1L and the 2L/3L builds, and shared helpers |
