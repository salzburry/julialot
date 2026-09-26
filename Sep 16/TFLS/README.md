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

# or straight from the warehouse - from the folder holding TFLS/ and variables/
TFLS_SOURCE=warehouse DATABRICKS_PWD=... PROJECT_WORK_SCHEMA=... \
  TFLS_PREFIX=s223926_ TFLS_PACKAGE_DIR=variables Rscript TFLS/run_tfls.R
```

`TFLS_PACKAGE_DIR` is required in warehouse mode, and the run stops without it:
it names the study package whose own connection code is used, so this cannot
connect differently from the runs it reads. The catalog defaults to
`hive_metastore` (`TFLS_CATALOG` or `DATABRICKS_CATALOG` move it), and the schema
is the first of `WORK_SCHEMA`, `PROJECT_WORK_SCHEMA` or the Domino user's own.

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

A subgroup names its table (`S_DEMOGRAPHICS:AGE_GROUP=<75&SEX=Male`) or
leaves each condition to find the table that carries it
(`AGE_GROUP=<75&SEX=Male`). Either way every condition applies: the men under
75, whichever order they are written in. Conditions that land on the same table
are met by the same row of it - `CONCEPT=neuropathy&HAS_HISTORY=1` is a history
of neuropathy, not a neuropathy row beside some other concept's history - and
that table is read for the column's own cohort, since demographics are taken at
each cohort's index: a 2L column's under-75 are the patients under 75 at 2L.

A subgroup that names its table is read off that table, for the column's
cohort, and selects patients: `S_LOT_PERIODS:LOT_NUM=3` is the patients who
went on to a third line, whatever `LOT_NUM` means in the table the row reads.
Two exceptions answer it from the rows being summarised: a table of totals,
which has no patient to look up, answers the one subgroup it is written by -
the rate tables are cut by the protocol's age group, so
`S_DEMOGRAPHICS:AGE_GROUP=<75` is read off their own `AGE_GROUP`, and any
other table or column named on a table of totals is refused - and rows of
the named table itself, which are filtered as rows - T3's columns are the
interval each malignancy fell in, not the patients who had one there. So to
select patients by something kept in the table a row reads, use the named
subgroup: T1b's neuropathy columns are `NEUROPATHY=YES` and `NEUROPATHY=NO`,
because its comorbidity rows read `S_COMORB_SUBGROUP` too.

A named subgroup - `NEUROPATHY`, `FRAILTY`, `AGE` - is asked for with `=` and
one of its values (`YES`/`NO`, or `LT75`/`GE75`); anything else stops the
load. It is read off its own table and nothing else, so `NEUROPATHY=YES`,
`NEUROPATHY=Y` and `S_COMORB_SUBGROUP:CONCEPT=neuropathy&HAS_HISTORY=1` are
one population. A subgroup condition compares with a value (`=`, `!=`, a list
with `|`) or with one number (`<`, `<=`, `>`, `>=`); two conditions on one
column must make one list or one range (`AGE_YEARS>=65&AGE_YEARS<75`). A
condition with nothing to compare, or a range against a word or a list, stops
the load, because the suppression could not tell what its cells add up to.
A regimen-class column may join classes, but not a class a drug refines
with one no drug refines: the drug would be required of both.

A column's cohort, line and period are each read one way, by selection, by
the suppression and everywhere else: a line is a whole number from 1, so `1`
and `01` are one line and `2|1` is `1|2`, and a cohort or a period is a name
taken without regard to case or order. A line that is not a number stops the
load.

A mean, a median or a minimum and maximum prints values of its column, so
none of them may summarise an identifier (`PATID` and the rest of the
identifier list): the smallest and largest `PATID` of thirty patients are two
patients' ids. Such a row stops the load, and is refused if it reaches a fill
another way. Counting patients (`n`, `n_distinct`) is what an identifier is
for, and stays.

Everything reading a per-patient table - demographics, comorbidity, frailty,
periods, SOC and the time-to-event outcomes - takes both. That is the whole of
T1, T1b, T4, T5c and most of T3.

A per-patient table that names no line of its own - the baseline
characteristics - learns which patients are on a line from `S_SOC`. A run that
skipped the SOC module wrote no `S_SOC`, and there the line comes from
`S_LOT_PERIODS` instead: the same lines, bounded the same way, a line that
starts after the cohort's follow-up ended being the one whose period is empty.
So an Overall column fills either way. A class column still needs `S_SOC`,
because only that table says which class a line is, and says so in
`tfls_unfilled.csv` when it is missing.

The columns that cannot be filled are left in place: they state what was asked
for, and `tfls_unfilled.csv` names the table that cannot answer it.

## Disclosure

Every cell goes through the same small-cell rule the study package applies, at
the same floor, and nothing here can publish a number the package would have
withheld.

- A cell whose denominator is under the floor is suppressed, and so is the
  count it was computed from. The default floor is 25, the protocol's, and
  `TFLS_MIN_N` can only raise it.
- **A survival curve publishes two counts, whatever the row prints**: the
  patients with the event, in `N`, and the patients censored, which is `DENOM`
  less `N`. Both have to reach the floor, for every statistic read off the
  curve - the events and censored rows, and the median and the probabilities
  too, whose `N` is the curve's events. A median over 30 patients of whom 3 had
  the event is withheld. (A *rate* is not a curve and keeps the package's own
  rule: it is suppressed on its at-risk count, and the events inside a large
  population are published.)
- **A curve goes whole.** When any cell of one column's curve is withheld —
  by the floor, or to protect another cell — its events, censored, median and
  probabilities are all withheld. Events and censored add up to the curve's
  population. So a withheld events count printed beside its censored count
  (and the `DENOM` that carries the population) is simply the one less the
  other, and the sum across the classes then gives up the class the floor
  withheld in the first place. For the same reason, where a sum needs one
  more cell withheld, it takes a class whose curve is already going, so the
  events row and the censored row give up the same class.
- **A number printed twice is one number.** The same row over the same
  population - a shell that repeats a row, or T1b, whose `Overall` columns and
  rows are T1's, or a class named once by its id and once by the category it
  maps to, or a subgroup spelled two ways (`NEUROPATHY=YES` and `=Y`, or the
  named subgroup and the rows it is read from) - counts once in every sum and
  is withheld in every place it appears or in none. Counted twice, two printed
  copies summed past their total and the sum was taken for no sum at all, and
  a copy printed in one table printed what the other withheld.
- **A row whose own filter narrows its column's population** -
  `TTE_ELIGIBLE=1` - leaves out patients that every unfiltered row of the same
  population still counts. The ones it leaves out are a number a reader can
  take, so they reach the floor or the row is withheld.
- **A sum gives away whatever its printed terms leave out**, so what they leave
  out has to reach the floor: one withheld cell, two withheld cells that add up
  to 12, or patients no term counts at all. The sums are read off the shells:
  a subtotal and the rows indented under it; the column's denominator against
  the rows that divide it; and a population against the columns that split it
  - `Overall` against its regimen classes, and against its subgroups. That
  last kind is read **across tables** as well as within one: T5c has no
  `Overall` of its own, and its age columns for a line split T4's `Overall` for
  that line, row for row, and a split whose levels sit in two tables is still
  one split. Rows are matched on what they read, not on how a
  shell spells it: `s_tte` or `S_TTE`, `TTNT` or `TTNT_MONTHS`, spaces or none.
  Columns are matched on what they select, not how they are written: the
  levels of a split are the subgroups that cannot share a patient -
  `AGE_YEARS<75` and `AGE_YEARS>=75`, `FRAIL=1` and `FRAIL=0` - and, for one
  line of one cohort, the classes with no category in common. That is
  decided at the level a cell counts, patients: two values of a column are
  two sets of patients only on a table with one row per patient in the
  column's cohort, so a history of lung disease and a history of
  neuropathy, two rows of `S_COMORB_SUBGROUP`, are not a split, while yes and
  no within one concept are. A table or column the code does not describe is
  never taken for one. A part inside another part is a sum too, with the rest
  of the larger part as its unknown - under 65 inside under 75, T3's "after 2L
  but before 3L" inside "after 2L+ anytime", a lone subgroup inside its
  `Overall` - and every population is closed over every part inside it on
  its own, so a column added beside them never takes that away. Such a sum,
  and a split whose levels leave a gap (under 65 and 85 and over), need not
  add up exactly, so it withholds only when what it leaves out is under the
  floor. Every split is found - the search is complete, and does not depend
  on the order of the columns - and a shell whose columns overlap in more
  ways than the search closes (256 over one population) stops at load.
  Every statistic takes part in a split, not only the
  counts, because every printed cell carries its population in `DENOM` and
  populations add up. The closing repeats until no sum is short, then runs
  once more over all the tables together.
- **This withholds more than the rule it replaced, on purpose.** The old rule
  published two withheld levels beside a third - White 30 of 40, with the two
  levels of 5 withheld - on the ground that nothing isolated either one; but
  40 - 30 put the ten non-White patients on the page, which is the disclosure
  the same rule refused for "ten men" one section up. And the regimen classes
  do not exhaust a line - transplant-only lines belong to no class - so
  `Overall` less the classes is a count of those patients, and it is floored
  like any other. On a full run, where that remainder is small, expect the
  smallest class column of the line to be withheld on many rows.
- **Still for the disclosure reviewer**, because the shells draw no sum that
  would close them: consecutive steps of the sample-selection funnel (F1)
  differ by the patients one step removes; `min`/`max` rows print single
  patients' values; the `REASON` column says which withheld cell was the small
  one and which went only to protect it; and a curve cell refused as "past the
  observed follow-up" names that population's longest follow-up.
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
  | a finding | fill from everything except the tables `RELEASE_RECOVERABLE_TABLES` names — or, where that list is absent or names anything that is not one of the seven released tables, except all seven |
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
