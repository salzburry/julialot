# NDMM (1L newly diagnosed multiple myeloma) cohort, on MDV

Stage 1 of the MDV port. It builds the 1L NDMM cohort and its attrition from
MDV for one cohort prefix, and writes the table the MDV LOT engine reads. It is
the Sep 16 build (`../../Sep 16/ndmm/`) with its extraction rewritten for MDV.
`../MDV_RULES.md` sets each rule beside its Optum form. `DECISIONS.md` holds
the reasoning, the Sep 16 decisions carried over, and the MDV ones added.

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
- **Death** is an FF1 discharge with a death outcome: in-hospital deaths only.
  Nobody dies until `MDV_COL_FF1_OUTCOME` is set.
- Panobinostat and elotuzumab must be barred from setting the index in
  `config.csv`, as on Optum (DECISIONS 3).
- This cohort removes belantamab before the index only. The LOT build removes
  it from the index onward (DECISIONS 2).

## Running it

```
CODELIST_DIR=/mnt/code/codelist_mdv DATABRICKS_PWD=... Rscript ndmm/build.R mdv_
```

The prefix can be given as `OBJECT_PREFIX` instead, and must end in `_`.
Everything else behaves as it does in the Sep 16 build: one run per prefix, a
re-run in one Domino execution keeping its run id, and the run log
(`PIPELINE_LOG_FILE`, or `OUTPUT_DIR/pipeline_run_<time>_<pid>.log`). The
tests need no warehouse:

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

### The MDV source

Every table, column and value code is a setting (`MDV_TBL_*`, `MDV_COL_*`,
`MDV_INPATIENT`, `MDV_CONFIRMED`, ...), read in `R/mdv_source.R`, and each is
listed with its default in `config.csv`. Five are marked **(confirm)**: the OC
rules did not name them and they have to be checked against the MDV data
dictionary. They are `MDV_COL_BIRTH`, `MDV_COL_FF1_OUTCOME`, `MDV_COL_ICD10`,
`MDV_COL_ACT_NYUGAIKBN` and `MDV_COL_ACT_DAYS`. The run records all of them in
`NDMM_RUN_METADATA.MDV_SOURCE`.

### Run choices

Validated, recorded in `NDMM_RUN_METADATA`, and not pinned.

| choice | default | may be |
|---|---|---|
| `NDMM_MDV_IP_RULE` | `none` | `none` (`nyugaikbn` alone: the Optum rule), `ff1` (and inside an FF1 episode), `ff1_chemo` (and that episode a first cancer with chemotherapy: the OC rule) |
| `NDMM_MDV_REQUIRE_CANCERFLG` | `TRUE` | `TRUE`, `FALSE` |
| `NDMM_MM_ADJACENT_STATES` | `override` | as on Optum |
| `NDMM_INDEX_EXCLUDED_ABBRS` | (empty) | `CL_MED_ABBR` patterns, separated by `\|`. Set `PANO\|ELOT` |
| `NDMM_INDEX_EXCLUDED_CODES` | (empty) | receipt codes, `RECEIPTCODE:<code>` or bare |

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
| `NDMM_INDEX_AGENTS`, `NDMM_FU_CE_COUNTS`, `NDMM_PREG_WINDOW_COUNTS`, `NDMM_OTHER_MALIG_GROUPS`, `_GRAIN`, `_CODES`, `NDMM_MM_ADJACENT_GROUPS`, `_CODES`, `NDMM_BELANTAMAB_RECONCILE` | the Optum build's review tables |
| `NDMM_RUN_METADATA` | adds `MDV_VINTAGE`, `MDV_IP_RULE`, `MDV_REQUIRE_CANCERFLG`, `MDV_SOURCE` |
| `NDMM_CODELIST_METADATA`, `NDMM_BUILD_STATUS` | as on Optum; LOT reads the status row |

## The criteria as applied

| # | criterion | on MDV | source |
|---|---|---|---|
| 1 | MM diagnosis | confirmed, `cancerflg` by default, code on `mm_dx.csv`, dated to the first of the claim month. One inpatient record (`NDMM_MDV_IP_RULE`) with a strict C90.0x code, or two outpatient months at most 3 months apart | `00_mm_cohort.R` |
| 2 | Adult | `year(diagnosis) - YRDOB >= 18` at the earliest qualifying date | `00_mm_cohort.R` |
| 3 | Eligible 1L treatment | the first MM therapy act on or after the diagnosis month and 2019-01-01, excluding steroids, belantamab and barred agents | `00b_lot1_index.R`, `03_prior_therapy.R` |
| 4 | 12 months of records before the index | first MDV record <= `index - 365` | `01_observation.R`, `06_flags.R` |
| 5 | Observed during follow-up | last MDV record >= `index + FU_CE_DAYS` (or death) | `06_flags.R` |
| 6 | No MM therapy in the baseline | no MM therapy act in `[index - 365, index - 1]` | `03_prior_therapy.R` |
| 7 | No other cancer in the baseline | one inpatient record, or two outpatient records in adjacent months in one ICD-10 group; confirmed; MM codes and plasma-cell labels do not count | `04_other_malig.R` |
| 8 | No pregnancy | no confirmed pregnancy diagnosis or delivery act in the study period | `05_pregnancy.R` |
| 9 | No belantamab before the index | no belantamab act before the index | `00b_lot1_index.R`, `06_flags.R` |

## What stops a run

Everything that stops the Sep 16 build, less the NDC and ICD_FLAG conditions,
plus:

- a missing MDV column, named with its table;
- a configured value code matching no MM diagnosis record, or a date column
  no record could be read from (`check_mdv_values`, waivable as
  `mdv_values`);
- a code-list row of a type no MDV scan reads;
- an ICD10 row where the delivery has no ICD-10 column;
- a `DISEASECODE` row on `mm_dx.csv` or `other_malig.csv` with no `icd10`;
- a receipt code the drug list gives to two agents;
- a drug list that resolves to no receipt code at all.

## Not here

The 2L and 3L cohorts (`../../Sep 16/ndmm/build_subsequent_cohorts.R`) are not
ported (`../MDV_RULES.md`, section 5).

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
