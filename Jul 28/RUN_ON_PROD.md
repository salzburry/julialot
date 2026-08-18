# What to run, in order

Built from `9504e04`. Code and docs only — **no code lists** (the engine reads
them from `CODELIST_DIR`, default `/mnt/code/codelist`) and **no cohort build**
(`ndmm_NDMM_COHORT` has to exist already).

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

## 1. Size the AUTO defect on the CURRENT build — FIRST, before rebuilding

The AUTO fixes change the contract build, so the LOT tables in the warehouse
still carry the defect. These counts read a patient SHAPE rather than a
verdict, so the same query runs either side of the fix — but once you rebuild,
the "before" number is gone for good.

```
AUDIT_EXECUTE=TRUE Rscript exploration/lot/run_lot_audit_counts.R
cp exploration/lot/out/lot_audit_counts.csv exploration/lot/out/before_fix.csv
```

Expect `12 counts. Running them now.` then twelve tables. The three to keep:

- `transplant-belonging-to-no-line` — shape **b** is the defect
- `tandem-pair-whose-first-transplant-is-out-of-window`
- `runout-unconfirmed-by-a-tandem-no-line-held`

Drop `AUDIT_EXECUTE` to list what it would count; needs no connection.

## 2. Rebuild the study LOT on the fixed engine

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

Each prefix is emptied before it is rebuilt. `APPLY_MELP_RULE` stays blank in
`CONTRACT`, so the study's own run is untouched by all of this.

In the decisions output read **block 2 first** — melphalan doses in no line.
Every row with `AFTER_THE_CAP = no` should be absent, `PRIOR_LINE_TYPE` of
`CART` or `SCT_ALLO` included. Those two used to be an expected exception,
because a single-day ALLO line and a CAR-T line with no consolidation drug end
on their own start date before any run-out is consulted. `melp_line_type_guard`
closed it: the hold overrides both short-circuits now. So do not accept a
pre-cap row of any prior line type — investigate it.

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

Every stop below is deliberate, not a crash.

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
- `KNOWN_ISSUES.md` — open study-team questions
- `exploration/FILES.md` — the melphalan proposal and what is unsettled

## Do not present these as settled

- `yield_to_sct` vs `as_asked`: what wins when a melphalan exposure and an AUTO
  code describe the same event. The request does not cover it, which is why
  both cells are built.
- A B.2 pair after a CAR-T-only or single-day ALLO line. Those lines end on
  their own start date before any run-out is consulted, so the hold cannot
  reach the doses. Block 2 of the decisions reader counts what it costs.
- What "2L MELP mono" means: melphalan as the only induction-regimen agent
  (what is built), or the only therapy exposure anywhere in the line.
