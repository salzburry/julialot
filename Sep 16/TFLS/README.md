# TFLS - the requested table shells, filled

The study team asked for a set of table shells: sample selection, baseline
characteristics by line of therapy and by subgroup, safety and healthcare
resource use at 1L and 2L, secondary malignancies, and treatment outcomes by
regimen class and by subgroup.

This folder holds the shells as data and the code that fills them from a
finished study run. It computes nothing clinical of its own: every number comes
from a table the study package wrote, so a shell cell and the dashboard agree by
construction.

```bash
# list the shells and what each row would read; no connection
Rscript TFLS/run_tfls.R

# fill them from a snapshot
TFLS_SOURCE=snapshot TFLS_SNAPSHOT_DIR=/mnt/data/NDMM TFLS_PREFIX=s223926_ \
  Rscript TFLS/run_tfls.R

# or straight from the warehouse
TFLS_SOURCE=warehouse DATABRICKS_PWD=... PROJECT_WORK_SCHEMA=... \
  TFLS_PREFIX=s223926_ Rscript TFLS/run_tfls.R
```

Output lands in `out/`: one CSV per table, one markdown rendering of all of
them, and `tfls_unfilled.csv` naming every row nothing could fill and why.

`TFLS_OUT_DIR` moves it, and on a platform that captures one directory as a
run's results it has to — a file written beside the code is not an output
there. On Domino that is `/mnt/artifacts/results`, the same place the LOT
engine's `OUTPUT_DIR` points by default:

```bash
TFLS_OUT_DIR=/mnt/artifacts/results/tfls ... Rscript TFLS/run_tfls.R
```

## What it knows about the study package, and how

`contract/study223926_contract.csv` says which module writes which table, which
of them the release module publishes a suppressed copy of, and which are
written only when a switch asks for them. It is **generated**, not written by
hand: `write_study_contract()` in the study package's `R/contract.R` derives it
from the `MODULES`, `SUPPRESSION_SPEC` and `OPTIONAL_FEATURES` that drive the
run itself.

It is shipped here because a snapshot is filled where that package is not
installed and cannot be asked. Regenerate it whenever the study registry gains
a table:

```r
source("variables/R/registry.R")
source("variables/R/contract.R")
write_study_contract("TFLS/contract/study223926_contract.csv")
```

`tests/test_tfls.R` regenerates it and compares line for line whenever the
study package sits beside this folder, so a stale copy fails the suite rather
than filling a shell from a table the gate does not know to refuse. Shipped on
its own, it says the check could not run.

The run checks it too. A study run records the md5 of the contract it was
driven by on `S_RUN_METADATA.STUDY_CONTRACT_MD5`, and before anything is read
under a prefix the shipped copy is hashed the same way - over its lines, so a
checkout with other line endings is the same contract - and compared. A copy
that hashes differently is a well-formed contract from another version of the
package, which the file's own checks cannot see and which can name a table as
unsuppressed that this run suppressed; the command stops and says which
package to regenerate it from. No setting waives that. A run that predates the
column recorded nothing to compare, and the command says so and goes on.

Which study *code*, where a study team has said which: a run also records the
fingerprint of the R that produced it (`STUDY_CODE_MD5`), and
`TFLS_STUDY_CODE_MD5` pins the approved one - the same way the study package
pins the LOT engine's with `LOT_CODE_MD5`. Unset, it checks nothing; set, a
run produced by any other code is refused rather than filled under the
approved one's name.

## It fills from one run, and reads only what that run wrote

A prefix is not a run. A run writes the modules it selected, for the cohorts it
selected, and leaves every other table and every other cohort's rows under the
prefix as the previous run left them, which is what makes a partial re-run
cheap. So what binds every read here is the run's own record of what it did:
`MODULES`, `COHORTS` and the readings behind its optional outputs, all on the
`S_RUN_METADATA` row.

- A table the run's own metadata does not claim reads as absent. Its rows are
  reported in `tfls_unfilled.csv`, naming the module that writes it and the
  modules the run recorded - never as a number, and never as a zero.
- A cohort the run did not select contributes no rows, so a column asking for
  it is reported unfilled rather than filled from the partition an earlier run
  built under the same prefix.
- A `_RELEASE` table is preferred only where the run ran the release module.
- A run that recorded no modules, or no cohorts, can vouch for nothing under
  the prefix, and the command stops rather than filling the shells from it.
- Every rate row of the shells is labelled **per 100,000 person-years** and a
  rate is read off the table as written, so a run whose `RATE_MULTIPLIER` says
  otherwise is refused; a run that predates the column binds with a warning.

The output is replaced as one set. The tables are rendered into a staging
directory first, the previous run's files are set aside, the new ones moved
in, and the set-aside discarded; a move that fails puts the previous run
back. A publish that is *killed* part-way leaves the set-aside directory with
a marker saying how far it got, and the next publish resolves that to a whole
set - the previous run's where the new one had not landed, the new one's where
it had - before it starts, saying so. One publish at a time: a
`.tfls_publish.lock` directory in the output directory refuses a second, and
one left by a killed publish is removed by hand, as its message says.

These are the rules the dashboard applies in `dashboard/R/sources.R`, applied
here rather than a second set invented beside them, so a shell cell and the
same figure on a page cannot rest on different rows. Which module writes which
table is the study package's own registry (`R/registry.R`), read here from the
contract that package generates — see **What it knows about the study package**
above — because a snapshot is filled where the package is not installed and
cannot be asked.

## The shells are CSV, so they can be edited without touching code

| file | one row per | what it decides |
|---|---|---|
| `shells/tables.csv` | table | which tables exist, their titles and objectives |
| `shells/columns.csv` | column | the column groups and what each column selects: cohort, line, regimen class, subgroup, period |
| `shells/rows.csv` | row | the row labels in order, and what each one reads: which study table, which measure, which statistic |
| `shells/regimen_classes.csv` | class | what counts as a quad, a triplet, a doublet, BCMA, bispecific |
| `shells/footnotes.csv` | footnote | the markers under each table |

Add a row, delete a row, reorder, change a class definition, add a whole table:
it is all CSV. Nothing is hard-coded. A row naming a measure that does not
exist is reported in `tfls_unfilled.csv` rather than silently dropped, so an
edit that asks for something the study does not produce says so.

### `rows.csv`

| column | meaning |
|---|---|
| `table_id` | which table the row belongs to |
| `order` | position within the table |
| `section` | `TRUE` for a heading that spans the table |
| `label` | the row label, exactly as it should print |
| `indent` | 0, 1 or 2, for nesting under a heading |
| `stat` | `n_pct`, `mean_sd`, `median_iqr`, `min_max`, `n`, `n_distinct`, `rate`, `km_median`, `km_prob`, `km_events`, `km_censored`. `n` counts patients; `n_distinct` counts the different values a column holds |
| `source` | the study table it reads, e.g. `S_DEMOGRAPHICS` |
| `measure` | the column or facet value, e.g. `SEX=Female`, `AGE_YEARS`, `CONDITION=Acute hepatitis` |
| `filter` | any extra restriction, e.g. `PERIOD=FOLLOWUP`, `MONTHS=12` |
| `note` | footnote marker |

### `regimen_classes.csv`

Nothing here classifies a regimen. The study package already does that, and a
second classifier over the drug list would be a second opinion of the same
question. This file is a MAPPING: `soc_categories` names the study categories
that roll into a column, separated by `|`, and `requires_drug` narrows a
category further where a column asks for something the study's vocabulary does
not separate.

So a column is changed by editing one line here, and a category the study does
not produce is refused by name rather than quietly emptying the column.

Two consequences the tables state rather than hide. `BCMA` holds the cell
therapies and `Bi-specific` holds both bispecific categories, so the columns are
disjoint and a patient is counted once. And the transplant-only lines belong to
no column at all, so the class columns do not sum to `Overall`.

## What a column can be cut by

A row can only be cut the way the table it reads is cut.

**By regimen class: yes.** `S_SAFETY_RATES`, `S_HCRU_RATES`,
`S_MALIGNANCY_RATES` and `S_TX_ATTRITION` are written once for each line as a
whole and once per SOC category, so an Overall column reads the line's own row
and a class column reads its categories. A class mapped to one category is that
category; a class mapped to two - `Bi-specific`, `Other` - is the two counts
added, which is exact because the categories partition the line and the package
checks that they do. A **rate** over more than one category is refused rather
than invented: a rate is not the sum of its strata's rates.

**By age: yes, on the same four tables.** They carry an `AGE_GROUP` column
written the same way - `<75` and `75+`, the protocol's own stratification, and
not the four descriptive bands `S_DEMOGRAPHICS.AGE_BAND` carries for Table 1.
The grouping is the point: a column covering several strata is their counts
added, which is exact, but a RATE is not the sum of its strata's rates, so an
age group spread over three bands could report a count and never a rate.
Neuropathy and frailty are not there: those stay a set of patients, so a column
naming one against an aggregated table reads as not filled and says so.

The two stratifications are **margins**, not a cross. A column names a regimen
class or an age, and the other stratification stays at the line's own row, so
the categories add up to the line and so do the age groups.

Everything reading a per-patient table - demographics, comorbidity, frailty,
periods, SOC and the time-to-event outcomes - takes both. That is the whole of
T1, T1b, T4, T5c and most of T3.

The columns that cannot be filled are left in place: they state what was asked
for, and `tfls_unfilled.csv` names the table that cannot answer it.

## Disclosure

Every cell goes through the same small-cell rule the study package applies, at
the same floor, and nothing here can publish a number the package would have
withheld.

- A cell whose denominator is under the floor is suppressed, and so is the
  count it was computed from. The default floor is 25, the protocol's, and
  `TFLS_MIN_N` can only raise it.
- A withheld cell must not be recoverable by subtraction, so the sums the
  table itself draws are closed: a subtotal and the rows indented under it, a
  total column and the columns it splits into, and the column's denominator
  against the rows that divide it. Where one of those sums has exactly one
  withheld term, its smallest published term goes too, and the closing repeats
  until no sum has a lone unknown left.
- Two things the table cannot close, and states rather than hides. The regimen
  class columns do not exhaust a line - the transplant-only lines belong to no
  class - so `Overall` less the classes bounds a withheld class from above
  rather than fixing it. And the sums are drawn inside one table: two tables
  from the same run share populations, and a reader holding both can subtract
  across them.
- A suppressed cell prints as `<25` (or the floor in force), never as a blank
  that could be read as zero.
- Nothing patient-level is read or written. No identifier reaches `out/`.
- Where the run published a `_RELEASE` table, that is what is read, so the
  suppression is the package's own and not a second opinion of it. A released
  table left by an earlier run is not preferred, because a run that did not run
  the release module did not publish one. And where the run says it published
  one and it is not there, or is there with no rows, nothing is read at all:
  the raw table is not a substitute for the copy meant to replace it, and the
  unfilled list says which of the two it was.
- **And where the run's own record says its release left a cell recoverable,
  that table is not read here either.** `mod_release()` withholds every cell
  under the floor and then records what it could not close — the groups where
  one withheld cell is still the group's total less the published rest — in
  `S_RUN_METADATA.RELEASE_RECOVERABLE`, with the tables it is about in
  `RELEASE_RECOVERABLE_TABLES`. Filling a shell at a higher floor does **not**
  close that: the subtraction is inside the released copy this reads *from*,
  and it happened before anything here looked. Nor is the raw table a way
  round it — that holds everything the release was run to remove. So the rows
  resting on such a table are reported unfilled, in the run's own words.

  Four answers, and the run says which on screen before a shell is filled:

  | the run's record says | these shells |
  |---|---|
  | `none` | fill from everything |
  | a finding | fill from everything except the tables `RELEASE_RECOVERABLE_TABLES` names — or, where that list is absent or names anything that is not one of the six released tables, except all six |
  | `release module did not run` | fill from nothing that would have had a released copy: that run has not been shown to have no recoverable cell, it has not looked |
  | nothing at all | fill from everything, and say so: that is the snapshot job's gate, and re-exporting through it is what settles it |

  `TFLS_ALLOW_RECOVERABLE=TRUE` fills them anyway and prints that it did. The
  dashboard and the snapshot job each carry the same switch under their own
  name, because each is a separate way a run reaches people and none of them
  has been through the others.

The tables are counts over a claims database and carry its limits: a code is
evidence of a claim, not of a diagnosis, and an absence is evidence of neither.

## The same shells in the dashboard

The dashboard's **Tables** tab fills these shells from whichever scenario is
selected, so the table, the scenario and the floor are controls and a shell can
be watched to move as a definition moves. It reads this folder - `DASH_TFLS_DIR`
names it where the two are not side by side - and nothing is duplicated there:
the loader, the statistics and the suppression are the ones in `R/`. A toggle
lists the rows nothing could fill under the table, with the same reason
`tfls_unfilled.csv` gives, so a gap is visible rather than blank.
