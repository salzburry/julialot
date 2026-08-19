# What to run, in order

This file walks the LOT half of the delivery. The complete delivery runs in
this order, each step over the one before it:

1. Prebuild snapshot: audit counts on the CURRENT tables — section 1 below,
   before anything is rebuilt (the numbers cannot be recovered afterwards)
2. NDMM cohort build (`ndmm/`) — writes `ndmm_NDMM_COHORT` with `MM_DX_DT`
3. LOT build over that exact cohort attempt — section 2 below
4. LOT QC and confirmation — section 3 below
5. Dashboard (`reporting/dashboard/build.R`) — includes the complete
   all-regimens CSV, which the build refuses to ship without
6. 2L/3L cohorts (`ndmm/build_subsequent_cohorts.R`) — after EVERY LOT rebuild
7. Outcomes (`analysis/outcomes/build.R`)
8. Study-question programs (`analysis/questions/`)
9. The scenario workbook on the finished run — section 1b below
10. MELP cells and readers — separate sensitivity prefixes only, section 4 below

Code and docs only — **no code lists** (the engine reads
them from `CODELIST_DIR`, default `/mnt/code/codelist`) and **no cohort build**
(`ndmm_NDMM_COHORT` has to exist already; `ndmm/README.md` covers building it).

Every path below is relative to **this folder** — the one holding this file —
so start by changing into it. The folder is dated and gets renamed, so it is
not named here:

```
cd /mnt/code/<study folder>      # the directory this file is in
```

## Environment, once per shell

```
export DATABRICKS_PWD='...'
export DOMINO_USER_NAME=usr00000
export OBJECT_PREFIX=ndmm_
export COHORT_PREFIX=ndmm_
export INPUT_COHORT_TABLE=ndmm_NDMM_COHORT
```

Override only if prod differs: `DATABRICKS_DSN=RWDE`,
`DATABRICKS_CATALOG=hive_metastore`, `OPTUM_CDM_SCHEMA=clnprw_optum`,
`CODELIST_DIR=/mnt/code/codelist`, `OUTPUT_DIR=/mnt/artifacts/results`.

## 1. Count the current warehouse tables — FIRST, before rebuilding

Run this before step 2. The counts read the LOT tables that are in the
warehouse now. Step 2 overwrites them, and these numbers cannot be recovered
afterwards.

Each count reads a patient SHAPE, not a verdict, so the same query runs against
any build.

```
AUDIT_EXECUTE=TRUE Rscript exploration/lot/run_lot_audit_counts.R
cp exploration/lot/out/lot_audit_counts.csv exploration/lot/out/before_fix.csv
```

Expect `12 counts. Running them now.` then twelve tables. The three to keep:

- `transplant-belonging-to-no-line` — shape **b** is the one to watch: a
  transplant in no line while a line was still available
- `tandem-pair-whose-first-transplant-is-out-of-window`
- `runout-unconfirmed-by-a-tandem-no-line-held`

Drop `AUDIT_EXECUTE` to list what it would count; needs no connection.

## 1b. The scenario workbook for the study team

How a line is created, thirty-one worked patients with the lines the engine
builds from them, and how many real patients are in each shape by line number.

```
SCENARIO_EXECUTE=TRUE Rscript exploration/lot/run_lot_scenarios.R
```

Writes `exploration/lot/out/lot_scenarios.xlsx`: what the numbers describe
(run id, cohort, table, settings), how a line is built, the scenarios, the
patient counts, the open questions, and what the codes mean. Needs `openxlsx`;
without it the same sheets come out as CSVs. Drop `SCENARIO_EXECUTE` to see
the scenarios with no connection — that preview goes to
`lot_scenarios_reference.xlsx`, so it never overwrites the counted workbook.

Run it before step 2 as well if you want the counts on the current tables.

## 2. Rebuild the study LOT

```
Rscript lot/engine/build.R ndmm_NDMM_COHORT ndmm_
```

## 3. Confirm, and answer the baseline question

```
AUDIT_EXECUTE=TRUE Rscript exploration/lot/run_lot_audit_counts.R   # shape b -> 0
QC_EXECUTE=TRUE    Rscript lot/qc/run_lot_qc.R
Rscript analysis/questions/baseline_gap_qs.R                        # BASELINE_DAYS=365
```

Each of the three scripts with an EXECUTE flag prints its catalogue first and
then stops unless the flag is set - so a run that lists 37 checks and says
`Nothing was read` did exactly what it was asked to. The flags are not
interchangeable: `AUDIT_EXECUTE` for the audit counts, `QC_EXECUTE` for QC,
`AUG1_EXECUTE` for the melphalan builds. `baseline_gap_qs.R` has none and runs
straight away.

QC also refuses a run that recorded a contract deviation, since most of its
checks are statements about the contract algorithm. The study's own `ndmm_`
run has none. To point it at a melphalan cell instead, add
`QC_ALLOW_DEVIATION=TRUE` and the report will carry the deviation.

## 4. Melphalan — independent of 2 and 3, can run alongside

Reads only the cohort and its own `melp_*` prefixes. Required before any
melphalan number: the cells now in the warehouse were built by older engine
code and the readers refuse them by fingerprint.

```
Rscript exploration/melphalan/run_aug1_melp.R                       # plan only
AUG1_EXECUTE=TRUE Rscript exploration/melphalan/run_aug1_melp.R     # three full builds
Rscript exploration/melphalan/read_melp_asks.R                      # Julia's Q1-Q3
Rscript exploration/melphalan/read_melp_decisions.R                 # what each decision was worth
```

The SIMPLIFIED fallback from the later note is a separate package with its own
two builds, under `melp_simple_` prefixes:

```
Rscript exploration/melphalan/run_melp_simple.R                          # plan only
MELP_SIMPLE_EXECUTE=TRUE Rscript exploration/melphalan/run_melp_simple.R # build + read
```

Its console output and four `melp_simple_*.csv` files compare the simplified
rule to the contract build. The 28-day course cap is an open question: rebuild
with `MELP_SIMPLE_COURSE_DAYS=30` to see the other reading.

Each prefix is emptied before it is rebuilt. `APPLY_MELP_RULE` stays blank in
`CONTRACT`, so the study's own run is untouched by all of this.

In the decisions output read **block 2 first** — melphalan doses in no line.
Every row with `AFTER_THE_CAP = no` should be absent, `PRIOR_LINE_TYPE` of
`CART` or `SCT_ALLO` included. A single-day ALLO line and a CAR-T line with no
consolidation drug end on their own start date, before any run-out is read.
`melp_line_type_guard` lets the melphalan hold override that, so those lines
reach the dose too. Investigate any pre-cap row, whatever the prior line type.

`AFTER_THE_CAP = yes` is treatment past the five-line cap. It is outside every
line by construction and no ownership decision can move it, so it is a
reconciliation number rather than a defect.

Question 1 writes three files, not one. `melp_ask1_line_duration.csv` is each
cell's own median at each line, and its change columns are marked UNPAIRED
because the rule moves who has a second line at all.
`melp_ask1_paired_line_change.csv` pairs the same patient's line across the
cells, and `melp_ask1_line_count_change.csv` counts the change in how many
lines a patient ends up with. The last of those is the one no renumbering can
explain.

## When something stops

Each message below is a check stopping the run, not a crash.

| message | meaning |
|---|---|
| `code fingerprint ... Rebuild the cells` | step 4's build was skipped or half-ran |
| `The last run under melp_... is 'failed'` | a cell died; see `exploration/melphalan/out/build_<cell>.log` |
| `No LOT_BUILD_STATUS row` | nothing has ever been built under that prefix |
| `No work schema` / `No OBJECT_PREFIX` | an environment variable above is missing |
| codelist errors in step 2 or 4 | `CODELIST_DIR` is not pointing at the populated folder |

A single count failing in step 1 does not stop the others: the CSV is still
written and the run reports how many failed.

## Read before quoting anything

- `lot/LOT_RULES.md` — the rules the build applies
- the scenario workbook's Open questions sheet — open study-team questions
- `exploration/FILES.md` — the melphalan proposal and what is unsettled

## Do not present these as settled

- `yield_to_sct` vs `as_asked`: what wins when a melphalan exposure and an AUTO
  code describe the same event. The request does not cover it, which is why
  both cells are built.
- What "2L MELP mono" means: melphalan as the only induction-regimen agent
  (what is built), or the only therapy exposure anywhere in the line.
