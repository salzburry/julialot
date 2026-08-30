# What to run, in order

> **The line-counting algorithm changed on 2026-08-30**, so the next run is not
> a refresh of the last one. Three adopted rules change what starts and ends a
> line: a drug of the PREVIOUS line's regimen never starts one
> (`lot/LOT_RULES.md` 4.3), the melphalan short course (4.7) and the returning
> earlier-line drug (4.8). 4.3 is the previous regimen only — a drug last given
> two or more lines back opens a line like any other agent. It reaches every
> patient whose current regimen has a treatment holiday. Line counts, line dates, end reasons and the 2L/3L
> cohorts all move. Run the prebuild snapshot in section 1 FIRST — the old
> numbers cannot be recovered once the tables are rebuilt — and treat every
> figure from an earlier run as superseded.

This file covers the LOT half of the delivery. The whole delivery runs in this
order, each step over the one before it:

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
10. MELP cells and readers — the comparison behind the adopted rule, on its
    own prefixes, section 4 below

Code and docs only. **No code lists** — the engine reads them from
`CODELIST_DIR`, default `/mnt/code/codelist`. **No cohort build** —
`ndmm_NDMM_COHORT` must exist already; `ndmm/README.md` covers building it.

Every path below is relative to **this folder**, so start by changing into it.
The folder is dated and gets renamed, so it is not named here:

```
cd /mnt/code/<study folder>      # the directory this file is in
```

## Environment, once per shell

```
export DATABRICKS_PWD='...'
export DOMINO_USER_NAME=usr00000
export OBJECT_PREFIX=ndmm_
export COHORT_PREFIX=ndmm_
export LOT_PREFIX=ndmm_
export INPUT_COHORT_TABLE=ndmm_NDMM_COHORT
```

`LOT_PREFIX` is the dashboard's name for the prefix the LOT run used — the same
value as `OBJECT_PREFIX`. The dashboard takes the three as arguments instead:
`Rscript reporting/dashboard/build.R ndmm_NDMM_COHORT ndmm_ ndmm_`.

A FRESH TERMINAL HAS NONE OF THESE. Every `No OBJECT_PREFIX` / `needs a cohort
table` stop means this block was not run in the shell you are in now.

Override only if prod differs: `DATABRICKS_DSN=RWDE`,
`DATABRICKS_CATALOG=hive_metastore`, `OPTUM_CDM_SCHEMA=clnprw_optum`,
`CODELIST_DIR=/mnt/code/codelist`, `OUTPUT_DIR=/mnt/artifacts/results`.

## 1. Count the current warehouse tables — FIRST, before rebuilding

Run this before step 2. The counts read the LOT tables in the warehouse now;
step 2 overwrites them and the numbers cannot be recovered afterwards.

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
builds from them, and how many real patients are in each shape by line
number.

```
SCENARIO_EXECUTE=TRUE Rscript exploration/lot/run_lot_scenarios.R
```

Writes `exploration/lot/out/lot_scenarios.xlsx` — what the numbers describe
(run id, cohort, table, settings), how a line is built, the scenarios, the
patient counts, the open questions, what the codes mean. Needs `openxlsx`;
without it the same sheets come out as CSVs. Drop `SCENARIO_EXECUTE` for the
scenarios with no connection; that preview goes to
`lot_scenarios_reference.xlsx` and never overwrites the counted workbook.

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

Each script with an EXECUTE flag prints its catalogue and then stops unless the
flag is set — a run that lists 37 checks and says `Nothing was read` did what it
was asked. The flags are not interchangeable: `AUDIT_EXECUTE` for the audit
counts, `QC_EXECUTE` for QC, `MELP_SIMPLE_EXECUTE` for the melphalan builds.
`baseline_gap_qs.R` has none and runs straight away.

QC refuses a run that recorded a contract deviation, since most of its checks
are statements about the contract algorithm. The study's own `ndmm_` run has
none. To point it at a melphalan cell, add `QC_ALLOW_DEVIATION=TRUE`; the report
then carries the deviation.

## 4. The rule cells — independent of 2 and 3, can run alongside

Reads only the cohort and its own `melp_*` prefixes. Required before any
melphalan number — the cells now in the warehouse were built by older engine
code, and the readers refuse them by fingerprint.

Two builds under `melp_simple_` prefixes — the study's rule against a build
without it — and then Julia's three questions off them:

```
Rscript lot/melphalan/run_melp_simple.R                          # plan only
MELP_SIMPLE_EXECUTE=TRUE Rscript lot/melphalan/run_melp_simple.R # build + read
Rscript lot/melphalan/read_melp_asks.R                           # Julia's Q1-Q3
```

Its console output and four `melp_simple_*.csv` files compare the study's rule
against a build with no melphalan rule at all. Both cells are built at the
contract's 28-day course cap: the package varies the rule, not the threshold.

Each prefix is emptied before it is rebuilt and every cell writes to its own, so
the study's run is untouched by all of this.

**Which cell deviates changed when the rule was adopted.** `APPLY_MELP_RULE` is
`simplified` in `CONTRACT`, so the simplified cell IS the study's algorithm and
records no deviation; the cell without the rule is built with
`APPLY_MELP_RULE=off` under `LOT_CONTRACT_OVERRIDE=TRUE`. Use the word `off`,
never a blank — the settings loader fills a variable that is unset **or empty**
from `config.csv`, so `APPLY_MELP_RULE=` builds the contract and compares the
study's build with itself.

## 4b. The MAP fold-in — the study's rule, and the build without it

A prior line's agent returning after the current line's regimen window joins
that line instead of splitting it, when exactly one agent advanced the line
between that drug's two doses. Two builds under `foldin_` prefixes — one without
the rule, one the contract's — differenced:

```
Rscript exploration/lot/run_foldin_cells.R                        # plan only
FOLDIN_EXECUTE=TRUE Rscript exploration/lot/run_foldin_cells.R    # build + read
```

`APPLY_MAP_FOLDIN` is TRUE in `CONTRACT`, so the folded cell IS the study's
algorithm and records no deviation; the reference cell is built with
`APPLY_MAP_FOLDIN=FALSE` under the override, and no reader accepts it as the
study's. Read its three `foldin_*.csv` files next to the sizing screen's counts
from step 8 — that screen was written against a build without the rule, so it
sizes what the rule has already done.

In the melphalan output read **melphalan doses in no line** first. No row with
`AFTER_THE_CAP = no` should be there, `PRIOR_LINE_TYPE` of `CART` or
`SCT_ALLO` included: a single-day ALLO line and a CAR-T line with no
consolidation drug end on their own start date, before any run-out is read, but
`melp_line_type_guard` lets the melphalan hold override that so those lines
reach the dose too. Investigate any pre-cap row, whatever the prior line type.

`AFTER_THE_CAP = yes` is treatment past the five-line cap. It is outside every
line by construction and no ownership decision can move it, so it is a
reconciliation number rather than a defect.

Question 1 writes three files, not one:

| file | what it holds |
|---|---|
| `melp_ask1_line_duration.csv` | each cell's own median at each line. Change columns marked UNPAIRED — the rule moves who has a second line at all |
| `melp_ask1_paired_line_change.csv` | the same patient's line across the two cells |
| `melp_ask1_line_count_change.csv` | the change in how many lines a patient ends up with. The one no renumbering can explain |

## When something stops

Each message below is a check stopping the run, not a crash.

| message | meaning |
|---|---|
| `code fingerprint ... Rebuild the cells` | step 4's build was skipped or half-ran |
| `The last run under melp_... is 'failed'` | a cell died; see `lot/melphalan/out/build_<cell>.log` |
| `No LOT_BUILD_STATUS row` | nothing has ever been built under that prefix |
| `No work schema` / `No OBJECT_PREFIX` | an environment variable above is missing |
| codelist errors in step 2 or 4 | `CODELIST_DIR` is not pointing at the populated folder |

A single count failing in step 1 does not stop the others: the CSV is still
written and the run reports how many failed.

## Read before quoting anything

- `lot/LOT_RULES.md` — the rules the build applies
- the scenario workbook's Open questions sheet — open study-team questions
- `STUDY_TEAM_ASKS.md` — what the study team asked for, what was adopted, and what is still open

## Do not present these as settled

- What "2L MELP mono" means: melphalan as the only agent in the line's regimen
  (what is built), or the only therapy exposure anywhere in the line. Steroids
  are not the ambiguity — they are excluded from every line decision, so
  melphalan with a steroid is melphalan mono here as it is everywhere else. The
  gap has narrowed since the fold-in was adopted: a returning previous-line
  drug now joins the regimen, so a line that spans two drugs no longer reads as
  mono.
