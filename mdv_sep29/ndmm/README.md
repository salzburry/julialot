# NDMM (1L newly diagnosed multiple myeloma) cohort, on MDV

Stage 1 of the MDV port. It builds the 1L NDMM cohort and its attrition from
MDV for one cohort prefix, and writes the table the MDV LOT engine reads. It is
the Optum cohort build with its extraction rewritten for MDV. `../MDV_RULES.md`
sets each rule beside its Optum form. `DECISIONS.md` holds the reasoning: the
Optum decisions, carried over whole, and the MDV ones added.

## In brief

Newly diagnosed multiple myeloma, one row per patient, indexed at the first
eligible first-line treatment act on or after 2019-01-01, over the study
period 2018-01-01 to 2026-03-31, read from `clnprw_mdv_all_use` (2026q2). The
same nine criteria as the Optum cohort, in the same order, counted in
`NDMM_ATTRITION`. Before reading a count:

- A diagnosis is dated to the **first day of its claim month**. Only
  **confirmed** diagnoses count (`utagaiflg`), and by default only those MDV
  flags as **cancer** (`cancerflg`).
- The two continuous-enrolment criteria are **observation** criteria. The
  first MDV record is at least 365 days before the index, and the patient is
  seen on the index date. `ENDDATE_CE` is the **last MDV record**.
- **Death** is an FF1 discharge with a death outcome: in-hospital deaths only,
  dated to the discharge **as recorded, never moved**. Nobody dies until
  `MDV_COL_FF1_OUTCOME` names the column. A 1L start after a recorded death
  fails criterion 5, and every act after a death is listed in
  `NDMM_DEATH_CONFLICTS` (DECISIONS M12).
- Panobinostat and elotuzumab are barred from setting the index by the
  contract, `NDMM_INDEX_EXCLUDED_ABBRS=PANO|ELOT` (protocol I3; DECISIONS 3,
  M11).
- This cohort removes belantamab before the index only. The LOT build removes
  it from the index onward (DECISIONS 2).

## Running it

```
CODELIST_DIR=/mnt/code/codelist_mdv DATABRICKS_PWD=... Rscript ndmm/build.R mdv_
```

The prefix can be given as `OBJECT_PREFIX` instead, and must end in `_`.
Every table the build reads from or writes to the work schema is named work
schema + prefix + table, so two cohorts sit side by side in one schema.

**One run per prefix at a time.** Table names carry no run id, so two runs on
one prefix would replace tables the other is reading. `check_no_active_run()`
refuses a run while `NDMM_BUILD_STATUS` has a `started` row for the prefix.
Runs on different prefixes are safe. It is a check, not a lock: two runs
starting at the same moment can both pass it. A killed process leaves its
`started` row behind; `NDMM_IGNORE_ACTIVE_RUN=TRUE` gets past it, and should be
set only once the named run is known to be dead.

**Re-running.** A re-run inside one Domino execution keeps its run id
(`DOMINO_RUN_ID`). Before the first step, this run id's rows are deleted from
`NDMM_ATTRITION`, `NDMM_RUN_METADATA` and `NDMM_CODELIST_METADATA`, so a failed
attempt cannot leave a row describing a cohort this attempt did not build.

**The run log.** Everything the run prints - log lines, QC tables, warnings and
the `ERROR:` line it stopped on - goes to the console and to one file:
`PIPELINE_LOG_FILE` if set, otherwise `OUTPUT_DIR/pipeline_run_<time>_<pid>.log`.
If a named `PIPELINE_LOG_FILE` cannot be written the run logs to the console
only; if the default location cannot be written it logs to R's temporary
folder and says so, because that folder is deleted when the process exits.

The tests need no warehouse:

```
Rscript ndmm/tests/test_runner.R      # the runner, the checks, the SQL shapes
Rscript ndmm/tests/test_mdv_build.R   # the whole build on synthetic MDV (duckdb)
```

## Settings

From `config.csv` (`name,value,description`) and the environment; the
environment wins. `DATABRICKS_PWD` is read from the environment only.

### The checks before anything is written

In this order: `check_settings` -> `pin_output_schema` -> `pin_prefix` ->
`check_contract` -> `check_choices` -> `check_constants`; then the connection,
`check_no_active_run`, and `check_upstream`, which checks that every MDV table
is readable and **every configured column exists**. Nothing is written until
all of them pass.

`check_settings` also refuses:

- an MDV table or column name that is not an identifier;
- a blank required column;
- an `MDV_VINTAGE` that is not a quarter;
- the Optum names `OPTUM_CDM_SCHEMA`, `OUTPATIENT_WINDOW`, `GAP_DAYS`,
  `TBL_*` and `NDMM_ICD_FLAG_MAX_ROWS`. These are refused so that a command
  carried over from the Optum build cannot look as though it set something.

### The contract

Changing one needs `NDMM_CONTRACT_OVERRIDE=TRUE` and is recorded as a
deviation, as on Optum.

| setting | default | effect |
|---|---|---|
| `DATABRICKS_CATALOG` | `hive_metastore` | |
| `MDV_SCHEMA` | `clnprw_mdv_all_use` | the MDV schema |
| `CODELIST_DIR` | `/mnt/code/codelist_mdv` | the MDV code lists (`../codelists/README.md`) |
| `USE_QUARTERLY_TABLES` | `TRUE` | read `t_<name>_<vintage>` |
| `MDV_VINTAGE` | `2026q2` | the MDV extract; blank derives it from `STUDY_END` |
| `STUDY_START`, `STUDY_END` | `2018-01-01`, `2026-03-31` | the Optum study's window |
| `LOT1_FROM` | `2019-01-01` | the eligible 1L period opens |
| `PRE_LOT1_DAYS` | `365` | lookback and baseline |
| `FU_CE_DAYS` | `0` | days after the index the patient must still be seen |
| `OUTPATIENT_WINDOW_MONTHS` | `3` | two outpatient MM months at most this far apart (Optum: 90 days) |
| `OTHER_MALIG_WINDOW_MONTHS` | `1` | the other-cancer pair (Optum: 30 days) |
| `MIN_AGE` | `18` | |
| `NDMM_BELANTAMAB_ABBR` | `BELA` | must equal lot's `BELANTAMAB_MED_ABBR` |
| `NDMM_INDEX_EXCLUDED_ABBRS` | `PANO\|ELOT` | agents barred from setting the 1L index beyond belantamab (protocol I3) |

### The MDV source

Every table, column and value code is a setting (`MDV_TBL_*`, `MDV_COL_*`,
`MDV_INPATIENT`, `MDV_CONFIRMED`, ...), read in `R/mdv_source.R`, and each is
listed with its default in `config.csv`. Five are marked **(confirm)**: the OC
rules did not name them and they have to be checked against the MDV data
dictionary. They are `MDV_COL_BIRTH`, `MDV_COL_FF1_OUTCOME`, `MDV_COL_ICD10`,
`MDV_COL_ACT_NYUGAIKBN` and `MDV_COL_ACT_DAYS`. The run records all of them in
`NDMM_RUN_METADATA.MDV_SOURCE`.

The last four are optional. A delivery that does not carry one says so with
`NONE`, in the environment or in `config.csv`: the column then leaves the
preflight and is read as absent. A blank setting means the default, not
absent, because the settings loader fills a blank variable from `config.csv`
and skips a blank value there. `NONE` on any other column is refused.

### Run choices

Validated, recorded in `NDMM_RUN_METADATA`, and not pinned.

| choice | default | may be |
|---|---|---|
| `NDMM_MDV_IP_RULE` | `none` | `none` (`nyugaikbn` alone: the Optum rule), `ff1` (and inside an FF1 episode), `ff1_chemo` (and that episode a first cancer with chemotherapy: the OC rule) |
| `NDMM_MDV_REQUIRE_CANCERFLG` | `TRUE` | `TRUE`, `FALSE` |
| `NDMM_MM_ADJACENT_STATES` | `override` | as on Optum |
| `NDMM_INDEX_EXCLUDED_CODES` | (empty) | receipt codes, `RECEIPTCODE:<code>` or bare |

### Barring agents from the 1L index

The study's I3 (protocol inclusion criterion I3, "Eligible 1L treatment") bars
panobinostat and elotuzumab from setting the 1L index. The build bars
belantamab itself, and the contract pins the other two:

```
NDMM_INDEX_EXCLUDED_ABBRS,PANO|ELOT,...
```

It is the default in `config.csv` and in the code. Any other value is a
different cohort, so it needs `NDMM_CONTRACT_OVERRIDE=TRUE` and is recorded as
a deviation. On Optum the study package refused a cohort built without it;
nothing reads the MDV cohort yet, so the cohort build holds itself to it.

Separate entries with `|`. The code splits on `,` as well, but in `config.csv`
a comma survives only while the value stays quoted, and an editor that drops
the quotes splits the row so that only the first entry is applied.

- Each entry is trimmed, upper-cased and matched as a SQL `LIKE` pattern
  against the code list's `CL_MED_ABBR` (also trimmed and upper-cased). With no
  wildcard it is a whole-abbreviation match; `%` matches any run of characters
  (`PANO%`), and `_` matches any one.
- The abbreviations must be the ones on the production `cl_mma_codelist.csv`.
  An entry matching no row stops the build.
- `NDMM_INDEX_EXCLUDED_CODES` bars by receipt code: `RECEIPTCODE:<code>`, or a
  bare code, compared with the resolved receipt codes after punctuation is
  stripped. Any other type stops the build; bar an agent the list names by
  `NAME_ENG` pattern by its abbreviation instead.
- A barred agent's acts cannot set the index; the next eligible act does. It
  does not exclude the patient, and its acts still count as MM therapy for
  criterion 6.

The run records what it barred: `NDMM_RUN_METADATA.INDEX_EXCLUDED` and
`INDEX_EXCLUDED_CODES`, the log line `Barred from setting the index, beyond
belantamab: ...`, and `ELIGIBLE = 0` on each barred agent's row of
`NDMM_INDEX_AGENTS`.

### Waivers

`NDMM_WAIVERS=mdv_values` lets a run past `check_mdv_values()` when a
configured value code matches no record, once someone has read the profile.
It is the one waivable condition. The Optum waivers are refused as unknown
names.

## What it reads

The five MDV tables (`diseasedata`, `patientdata`, `ff1data`, `m_drug`,
`actdata`) and the five code lists (`mm_dx.csv`, `cl_mma_codelist.csv`,
`other_malig.csv`, `pregnancy.csv`, `clintrial.csv`). It reads no table
another build makes.

## What it writes

All prefixed. The Optum build's tables, with the same columns where the
column still means something:

| table | |
|---|---|
| `NDMM_COHORT` | the cohort. `PATID, INDEX_DATE, MM_DX_DT, ENDDATE, ENDDATE_CE, DEATH_DT, GDR_CD, YRDOB, AGE_INDEX_YR, FU_DAYS, FU_DAYS_CE`: the columns LOT reads |
| `NDMM_ATTRITION` | the nine-step funnel |
| `NDMM_FLAGS_ALL`, `NDMM_CLINTRIAL_FLAGS` | per-candidate flags; trial evidence (descriptive) |
| `NDMM_MM_DX_RULES` | **new**: criterion 1 under each reading (`../MDV_RULES.md`, section 2) |
| `NDMM_MMA_RECEIPTS` | **new**: every receipt code the drug list resolved to, with its name. Read it before believing a count |
| `NDMM_MDV_SOURCE_PROFILE` | **new**: MDV's value codes on the records the cohort reads |
| `NDMM_DEATH_CONFLICTS` | **new**: every act after a recorded death (DECISIONS M12) |
| `NDMM_INDEX_AGENTS`, `NDMM_FU_CE_COUNTS`, `NDMM_PREG_WINDOW_COUNTS`, `NDMM_OTHER_MALIG_GROUPS`, `_GRAIN`, `_CODES`, `NDMM_MM_ADJACENT_GROUPS`, `_CODES`, `NDMM_BELANTAMAB_RECONCILE` | the Optum build's review tables |
| `NDMM_RUN_METADATA` | adds `MDV_VINTAGE`, `MDV_IP_RULE`, `MDV_REQUIRE_CANCERFLG`, `MDV_SOURCE` |
| `NDMM_CODELIST_METADATA`, `NDMM_BUILD_STATUS` | as on Optum; LOT reads the status row |

### The sensitivity tables

None of them changes the cohort. Each prices a rule that is still open, or
shows what a code list actually did, so a decision is made on a number.

| table | what it is for | DECISIONS |
|---|---|---|
| `NDMM_MM_DX_RULES` | criterion 1 under each MDV reading: the inpatient rule, confirmed only, the cancer flag (`../MDV_RULES.md`, section 2) | M |
| `NDMM_MDV_SOURCE_PROFILE` | MDV's value codes on the records the cohort reads, so a wrong code is seen before a count is believed | M |
| `NDMM_INDEX_AGENTS` | every `CL_MED_ABBR` on the code list: `ELIGIBLE` (0 = barred from setting the index) and `N_PATIENTS`, the patients whose index act was that agent. Read it before barring an agent | 3 |
| `NDMM_FU_CE_COUNTS` | criterion 5 at 0, 30, 60 and 90 days and at three calendar months (`add_months`): `N_PASSING_CRITERION_5`, and `N_COHORT`, the whole cohort at that window. `IS_THIS_RUN` marks the applied row; carries `RUN_ID` | 1, 7 |
| `NDMM_PREG_WINDOW_COUNTS` | criterion 8 over the study period (applied) and over the patient's own baseline plus follow-up: `N_WITH_PREG_CLAIM`, `N_EXCL_INCREMENTAL` and `N_COHORT` | 9 |
| `NDMM_OTHER_MALIG_GROUPS` | every pairing group the other-cancer list resolves to (ICD-10 category, or `MET`), with its code and label counts. A group holding one code can only confirm itself | 4 |
| `NDMM_OTHER_MALIG_GRAIN` | criterion 7 (`N_EXCLUDED` among 1L candidates) at six pairing grains: `same code-list label`, `as configured`, `mets kept apart by prefix`, `collapse without C77`, `collapse without C800`, `any label at all` | 4 |
| `NDMM_OTHER_MALIG_CODES` | the other-cancer code list as this run applied it: each code with its label, override flag and pairing groups | 4 |
| `NDMM_MM_ADJACENT_GROUPS` | every label containing `PLASMACYTOMA`, `PLASMA CELL`, `GAMMOPATHY` or `MYELOMA`, and every overridden label, with `OVERRIDDEN` and its code count. A plasma-cell label still excluding is named in the log | 4 |
| `NDMM_MM_ADJACENT_CODES` | every code kept as the index disease rather than another cancer, with the label that kept it | 4 |
| `NDMM_BELANTAMAB_RECONCILE` | every belantamab act of a cohort member up to that patient's `ENDDATE_CE`, the last MDV record, with `DAYS_FROM_INDEX`. All are on or after the index, so `lot`'s `no_belantamab` removes every patient listed | 2 |
| `NDMM_DEATH_CONFLICTS` | every patient with an MDV act after their recorded death: `DEATH_DT` as recorded, `FIRST_ACT_AFTER_DEATH`, `LAST_ACT_AFTER_DEATH`, `N_ACTS_AFTER_DEATH`, `N_MM_TX_AFTER_DEATH`, and `DEATH_BEFORE_INDEX` (1 = the 1L start fell after the death, so the patient fails criterion 5). Any row also puts `death_conflicts` on the run's `FINDINGS` | M12 |

`NDMM_PREG_WINDOW_COUNTS` is checked as it is written: both rows must
partition the same population, the narrower window can only leave a larger
cohort, and the applied row must equal the cohort. A failure stops the run.

## The criteria as applied

| # | criterion | on MDV | source |
|---|---|---|---|
| 1 | MM diagnosis | confirmed, `cancerflg` by default, code on `mm_dx.csv`, dated to the first of the claim month. One inpatient record (`NDMM_MDV_IP_RULE`) with a strict C90.0x code, or two outpatient months at most 3 months apart | `00_mm_cohort.R` |
| 2 | Adult | `year(diagnosis) - YRDOB >= 18` at the earliest qualifying date | `00_mm_cohort.R` |
| 3 | Eligible 1L treatment | the first MM therapy act on or after the diagnosis month and 2019-01-01, excluding steroids, belantamab and barred agents | `00b_lot1_index.R`, `03_prior_therapy.R` |
| 4 | 12 months of records before the index | first MDV record <= `index - 365` | `01_observation.R`, `06_flags.R` |
| 5 | Observed during follow-up | last MDV record >= `index + FU_CE_DAYS` (cut at death and the study end), and not recorded dead before the index | `06_flags.R` |
| 6 | No MM therapy in the baseline | no MM therapy act in `[index - 365, index - 1]` | `03_prior_therapy.R` |
| 7 | No other cancer in the baseline | one inpatient record, or two outpatient records in adjacent months in one ICD-10 group; confirmed; MM codes and plasma-cell labels do not count | `04_other_malig.R` |
| 8 | No pregnancy | no confirmed pregnancy diagnosis or delivery act in the study period | `05_pregnancy.R` |
| 9 | No belantamab before the index | no belantamab act before the index | `00b_lot1_index.R`, `06_flags.R` |

## What stops a run

On any stop after the run is marked `started`, its `NDMM_BUILD_STATUS` row is
set to `failed`, carrying whatever `FINDINGS` it had.

Before anything is written - the checks under "Settings": a malformed setting,
an Optum setting name (`OPTUM_CDM_SCHEMA`, `TBL_*` and the rest), no output
schema or prefix, a contract difference without the override, a run choice
outside its values, constants that disagree with the settings, no
`DATABRICKS_PWD`, another run `started` on the prefix, an unreadable MDV table,
or a missing MDV column, named with its table.

While running:

- **Code lists.** A missing directory or file, a file not among the five, a
  missing column, no rows, or a file that changed while it was read. A code
  type a list may not carry (`codelists/README.md` gives each list's types);
  an `ICD10` row where the delivery has no ICD-10 column; a `DISEASECODE` row
  on `mm_dx.csv` or `other_malig.csv` with no `icd10`. In
  `cl_mma_codelist.csv`: a blank `CL_MED_ABBR`, a receipt code the list gives
  to two agents, or a list that resolves to no receipt code at all. In
  `pregnancy.csv` or `clintrial.csv`: no usable codes.
- **MDV values.** A configured value code matching no MM diagnosis record, or
  a date column no record could be read from (`check_mdv_values`, waivable as
  `mdv_values`).
- **Names that match nothing.** `NDMM_BELANTAMAB_ABBR` matching no row, or
  another `BEL*` abbreviation on the list; an `NDMM_INDEX_EXCLUDED_ABBRS` or
  `_CODES` entry matching no row; an MM-adjacent label the current
  `NDMM_MM_ADJACENT_STATES` mode requires missing from `other_malig.csv`.
- **Its own tables.** A checkpoint that cannot be written; a trial-flag row
  with no diagnosis date; an inconsistent `NDMM_PREG_WINDOW_COUNTS`; an
  attrition step larger than the one above it; an empty cohort; any failure of
  `check_ndmm_cohort()`; a code list with no recorded hash; a column that
  cannot be added to an existing metadata table.

The Optum build's NDC-shape and `ICD_FLAG` stops have no MDV counterpart: MDV
has neither column.

New against the Optum build: the refusal of an Optum setting name, the MDV
column and value checks, the code types by MDV type, and the receipt-code
checks on the drug list.

## Not here

The 2L and 3L cohorts are not ported (`../MDV_RULES.md`, section 5). The Optum
build derives them from the lines, after the LOT build.

## Files

| path | what it does |
|---|---|
| `build.R` | entry point, one prefix per run |
| `config.csv` | every default setting, the MDV names among them |
| `R/build_ndmm.R` | the runner: `CONTRACT`, `CHOICES`, `CHECKPOINTS`, `SOURCE_VIEWS`, the preflight, `check_mdv_values`, `NDMM_CRITERIA` and the attrition, the cohort table, metadata and status |
| `R/mdv_source.R` | every MDV table, column and value code, and the staged selects the steps read. The same file as `../lot/engine/R/mdv_source.R` |
| `R/config.R`, `R/load_inputs.R`, `R/db_utils.R` | settings, `config.csv`, the run log and SQL helpers |
| `R/codelists.R` | loads the five code lists, checks their code types, records each md5 |
| `R/ndmm_constants.R`, `R/standalone_constants.R` | view names, windows, the inpatient reading, the plasma-cell labels, metastatic prefixes |
| `R/steps/00_mm_cohort.R` | the staged MDV views; criteria 1 and 2; demographics and death; `NDMM_MM_DX_RULES` |
| `R/steps/00b_lot1_index.R` | criterion 3, belantamab, the review tables |
| `R/steps/01_observation.R` | first and last MDV record per candidate |
| `R/steps/03_prior_therapy.R` | the drug code list, its resolution to receipt codes, every MM therapy act, criterion 6 |
| `R/steps/04_other_malig.R` | criterion 7 |
| `R/steps/05_pregnancy.R`, `05b_preg_window.R` | criterion 8 and its window table |
| `R/steps/06_flags.R`, `07_cohort.R` | the flags and the attrition counts |
| `R/steps/08_clintrial.R` | the descriptive trial flag |
| `tests/` | the runner suite, the MDV build suite, shared helpers |
