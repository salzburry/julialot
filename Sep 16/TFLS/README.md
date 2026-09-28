# TFLS - the study's table shells, filled

The shells cover sample selection, baseline characteristics by line of therapy
and by subgroup, safety and healthcare resource use at 1L and 2L, secondary
malignancies, and treatment outcomes by regimen class and by subgroup.

This folder holds the shells as CSV and the code that fills them from a
finished study run. It computes nothing clinical: every number comes from a
table the study package wrote, read under the same rules the dashboard reads
by (`dashboard/R/sources.R`). The dashboard's Tables tab fills these same
shells with this code (`dashboard/DASHBOARD.md` "The Tables tab";
`DASH_TFLS_DIR` names this folder where the two are not side by side), so a
shell cell and the same figure on the dashboard are one number.

## Filling them

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

| setting | what it does |
|---|---|
| `TFLS_SOURCE` | `snapshot` or `warehouse`. Unset, the shells are listed and nothing is read |
| `TFLS_PREFIX` | which run: the prefix its tables were written under. Required; letters, digits, `.`, `_` and `-` only |
| `TFLS_SNAPSHOT_DIR` | snapshot: the root whose `<prefix>/<TABLE>.csv` is read. Required there |
| `TFLS_PACKAGE_DIR` | warehouse: the study package directory, whose own connection code is used, so the fill cannot connect differently from the runs it reads. Required there |
| `TFLS_CATALOG` | warehouse catalog. Default `DATABRICKS_CATALOG`, then `hive_metastore` |
| `TFLS_COHORT_TABLE` | the input cohort table, for a row that reads it. Default `INPUT_COHORT_TABLE` |
| `TFLS_MIN_N` | raises the floor ("Disclosure"). A value that is not a whole number stops the run |
| `TFLS_OUT_DIR` | where the tables go. Default `TFLS/out/`. On Domino, point it into `/mnt/artifacts/results` (e.g. `/mnt/artifacts/results/tfls`): a file written beside the code is not a run's output there |
| `TFLS_STUDY_CODE_MD5` | the approved study build's code fingerprint (`S_RUN_METADATA.STUDY_CODE_MD5`). Unset checks nothing; set, a run produced by any other code is refused |
| `TFLS_TTE_ELIGIBLE_ONLY` | `TRUE` restricts every curve to `TTE_ELIGIBLE = 1`. Off by default: the study writes the whole cohort and leaves the restriction to the reader, and each curve row's note says which way it went |
| `TFLS_ALLOW_RECOVERABLE` | `TRUE` fills from tables the run's own release record refuses ("What is read"), and says so |

In warehouse mode the schema is the first of `WORK_SCHEMA`,
`PROJECT_WORK_SCHEMA` or the Domino user's own - the study run's order - and
`catalog.schema` is accepted where the catalog matches. `DATABRICKS_PWD` comes
from the environment.

### What it writes

| file | what it is |
|---|---|
| `tfls_<table>.csv` | one per table, one row per cell, with `REASON` saying why a cell is what it is |
| `tfls.md` | every table rendered, with the run id and the floor |
| `tfls_unfilled.csv` | every row and column nothing could fill, with `REASON_KIND` - `not_in_run` (the run did not write what it needs), `shell` (the shell does not say enough) or `not_computable` (the statistic cannot be made from what the table holds) - and `REASON` in words |

The files are replaced as one set: rendered into a staging directory, the
previous set moved aside, the new one moved in; a move that fails puts the
previous set back, and a publish that is *killed* part-way is resolved to one
whole set by the next publish, which says so. One publish at a time: a
`.tfls_publish.lock` directory in the output directory refuses a second, and
one left by a killed publish is removed by hand, as its message says. Files in
the output directory that are not the tool's own are left alone.

### What stops a fill

Nothing is written, and the command exits 1, when:

- a shell file is wrong ("The shells") - the message names the file and the
  row;
- there is no `S_RUN_METADATA` under the prefix, or it is empty, or it cannot be
  read;
- the run's newest metadata row is not `complete` - its tables may be the
  previous build's or part of this one;
- the run recorded no `MODULES` or no `COHORTS`, so nothing under the prefix can
  be shown to be its own;
- the bundled contract is not the one the run was driven by ("The study
  contract");
- `TFLS_STUDY_CODE_MD5` is set and the run's `STUDY_CODE_MD5` differs or is
  missing;
- the run's `RATE_MULTIPLIER` is not 100,000: every rate row is labelled **per
  100,000 person-years** and a rate is read off the table as written;
- the run changed while its tables were being read.

A run that recorded no `STUDY_CONTRACT_MD5` or no `RATE_MULTIPLIER` has
nothing to compare; the fill warns and goes on.

## The study contract

`contract/study223926_contract.csv` says which module writes which table,
which of them the release module publishes a suppressed copy of, and which are
written only when a switch asks for them. It is **generated** by
`write_study_contract()` in `variables/R/contract.R` from the `MODULES`,
`SUPPRESSION_SPEC` and `OPTIONAL_FEATURES` that drive the run, and bundled here
because a snapshot is filled where the study package is not installed.
Regenerate it whenever the study registry gains a table, from the folder
holding `TFLS/` and `variables/`:

```r
source("variables/R/registry.R")
source("variables/R/contract.R")
write_study_contract("TFLS/contract/study223926_contract.csv")
```

`tests/test_tfls.R` regenerates it and compares line for line whenever the
study package sits beside this folder.

A run records the md5 of the contract it was driven by in
`S_RUN_METADATA.STUDY_CONTRACT_MD5`. Before anything is read the bundled copy
is hashed the same way - over its lines, so other line endings are the same
contract - and a difference stops the fill. No setting waives it: a contract
from another version of the package can name a table as unsuppressed that this
run suppressed.

## It reads only what the run wrote

A prefix is not a run. A run writes the modules it selected, for the cohorts it
selected, and leaves every other table and cohort's rows under the prefix as
the previous run left them. So every read is bound to the run's own
`S_RUN_METADATA` row - `MODULES`, `COHORTS` and the readings behind its
optional outputs:

- A table the run's metadata does not claim reads as absent. Its rows are
  reported in `tfls_unfilled.csv`, naming the module that writes it and the
  modules the run recorded - never as a number, and never as a zero.
- A cohort the run did not select contributes no rows.

## The shells

Five CSV files in `shells/`, edited without touching code:

| file | one row per | what it decides |
|---|---|---|
| `tables.csv` | table | which tables exist, their titles and objectives |
| `columns.csv` | column | the column groups and what each column selects: cohort, line, regimen class, subgroup, period |
| `rows.csv` | row | the row labels in order, and what each one reads: which study table, which measure, which statistic |
| `regimen_classes.csv` | class | what counts as a quad, a triplet, a doublet, BCMA, bispecific |
| `footnotes.csv` | footnote | the markers under each table (`table_id`, `marker`, `text`) |

Every file is checked when it is loaded. A mistake the code could carry into a
published table - an unknown table id, a statistic nothing implements, a
measure or subgroup that cannot be read, two rows or columns at one position, a
table with no rows or no columns - stops the run. A row asking for a column the
study table does not have is reported in `tfls_unfilled.csv` rather than
dropped. Column names are matched without case, and common alternative
spellings are accepted (`line` for `lot_num`, `column_id` for `col_id`; the
full list is `TFLS_SHELL_SCHEMA` in `R/shells.R`).

### `columns.csv`

| column | meaning |
|---|---|
| `table_id` | which table the column belongs to. Required |
| `col_id` | the column's id within the table. Blank gives `<table>_C<order>` |
| `group` | the spanning header over a group of columns |
| `label` | the column heading, exactly as it should print. Required |
| `order` | position within the table, a whole number. Blank throughout keeps the file's order |
| `cohort` | `1L`, `2L`, `3L`, `SEC2L`; several with `\|` |
| `lot_num` | the line, a whole number from 1; several with `\|` |
| `class` | a `class_id` from `regimen_classes.csv`, a SOC category written out, or several of either with `\|`. Blank or `OVERALL` is the column total |
| `subgroup` | a restriction on the column's patients ("Subgroups") |
| `period` | the period a table is written by, e.g. `FOLLOWUP` |

A line is a whole number, so `1` and `01` are one line and `2|1` is `1|2`; a
line that is not a number stops the load. A cohort or a period is a name, taken
without regard to case or order.

### `rows.csv`

| column | meaning |
|---|---|
| `table_id` | which table the row belongs to |
| `order` | position within the table |
| `section` | `TRUE` for a heading that spans the table |
| `label` | the row label, exactly as it should print |
| `indent` | 0, 1 or 2, for nesting under a heading or a subtotal ("Disclosure" reads the nesting as a sum) |
| `stat` | `n_pct`, `mean_sd`, `median_iqr`, `min_max`, `n`, `n_distinct`, `rate`, `km_median`, `km_prob`, `km_events`, `km_censored`. `n` counts patients; `n_distinct` counts the different values a column holds |
| `source` | the study table it reads, e.g. `S_DEMOGRAPHICS` |
| `measure` | the column, or the column and a value, e.g. `SEX=Female`, `AGE_YEARS`, `CONDITION=Acute hepatitis`. A comparison may be `=`, `!=`, `<`, `<=`, `>` or `>=`, and a value may be a list with `\|` |
| `filter` | any extra restriction, terms joined with `&` or `;`, e.g. `PERIOD=FOLLOWUP`, `MONTHS=12` |
| `note` | footnote marker |

A row that reads a `source` has to name a `stat`. A curve row's `measure` is
its endpoint and nothing else; a comparison goes in the filter. A `km_prob` row
needs exactly one `MONTHS=<n>` in its filter, `n` at or after the index, and
`MONTHS` on any other row stops the load rather than being ignored.

`mean_sd`, `median_iqr` and `min_max` print values of their column, so none of
them may summarise an identifier (`PATID`, `PAT_PLANID`, `PATIENT_ID`,
`MEMBER_ID`, `CLMID`, `PERSON_ID`, `MRN`) - such a row stops the load.
Counting patients (`n`, `n_distinct`) is what an identifier is for.

### `regimen_classes.csv`

Nothing here classifies a regimen: the study package assigns each line a
`SOC_CATEGORY`, and this file maps those categories to column headings, so a
column is changed by editing one line here.

| column | meaning |
|---|---|
| `class_id` | the id a column's `class` names |
| `label` | the heading it prints under |
| `order` | the order the classes are listed in |
| `soc_categories` | the study categories that roll into the class, separated by `\|` (or `;`, never a comma - a category name may hold one). A category the study does not write stops the load, naming the ones it does |
| `requires_drug` | optional: one drug abbreviation that narrows the categories to the lines whose regimen holds it, where the study's vocabulary does not separate a heading. It needs a category to narrow |
| `note` | what the class holds, for a reader |

`OVERALL` is the column total, every line, and maps no category. A class mapped
to no category is not an empty column: every cell in it is reported unfilled,
since a zero would claim nobody is in it (`POM_TRIP` is one: the study has no
pomalidomide category). `BCMA` holds the cell therapies and `Bi-specific` both
bispecific categories, so the columns are disjoint and a patient is counted
once. The transplant-only lines belong to no class, so the class columns do not
sum to `Overall`.

## What a column can be cut by

A row can only be cut the way the table it reads is cut. Columns that cannot be
filled are left in place - they state what the shell specifies - and
`tfls_unfilled.csv` names the table that cannot answer them.

**Tables of totals.** `S_SAFETY_RATES`, `S_HCRU_RATES`, `S_MALIGNANCY_RATES`
and `S_TX_ATTRITION` are written once for each line as a whole, once per SOC
category and once per `AGE_GROUP` (`<75`, `75+`, the protocol's two groups -
not `S_DEMOGRAPHICS.AGE_BAND`'s four descriptive bands). An Overall column reads
the line's own row and a class column reads its categories; a class over two
categories is the two counts added, which is exact because the categories
partition the line. A **rate** over more than one stratum is refused rather than
invented. The two stratifications are **margins**, not a cross: a column names
a class or an age, and the other stays at the line's own row. Nothing else cuts
these tables, so a neuropathy or frailty column against one reads as not
filled.

**Per-patient tables** - demographics, comorbidity, frailty, periods, SOC and
the time-to-event outcomes - take any class and subgroup. That is the whole of
T1, T1b, T4, T5c and most of T3. A class column has to name a line, since the
study assigns a category to a line. A per-patient table that names no line of
its own learns which patients are on the column's line from `S_SOC`, or, in a
run that skipped the SOC module, from `S_LOT_PERIODS` (the same lines, dropping
one whose period is empty), so an Overall column fills either way. A class
column still needs `S_SOC`.

### Subgroups

**Syntax.** `[TABLE:]CONDITION[&CONDITION...]`, with `&` or `;` between
conditions, all of which apply. A condition compares a column with a value
(`=`, `!=`, a list with `|`) or with one number or date (`<`, `<=`, `>`, `>=`).
A date is compared as its day number, so `INDEX_DATE>=2020-01-01` and
`INDEX_DATE>=18262` are the same. Two conditions on one column must make one
list or one range (`AGE_YEARS>=65&AGE_YEARS<75`). A condition with nothing to
compare, or a range against a word or a list, stops the load.

**Which table a condition is read on.** A subgroup that names its table is read
on that table. Left unqualified, each condition is read on the one per-patient
table that carries its column, among `S_DEMOGRAPHICS`, `S_COMORBIDITY`,
`S_COMORB_SUBGROUP`, `S_FRAILTY`, `S_SOC`, `S_PERIODS` and `S_TTE` -
`AGE_YEARS<65` is `S_DEMOGRAPHICS:AGE_YEARS<65` whatever row it sits under. A
column two of them carry (`TTE_ELIGIBLE`, on `S_PERIODS` and `S_TTE`) or none
does has to be qualified, and the load says so.

**Registered tables.** A subgroup may be read only on the tables
`TFLS_TABLE_GRAIN` in `R/fill.R` lists - those seven, `S_LOT_PERIODS`,
`S_MALIGNANCY`, `S_ELIGIBILITY`, `S_COHORT`, and the input cohort table as
`COHORT_TABLE`, `INPUT_COHORT` or `INPUT_COHORT_TABLE` - and only on the columns
listed there for each. Any other table or column stops the load, because what
its cells add up to beside the other columns could not be told.

**One row, one cohort.** Conditions that land on the same table are met by the
same row of it: `S_COMORB_SUBGROUP:CONCEPT=neuropathy&HAS_HISTORY=1` is a
history of neuropathy, not a neuropathy row beside some other concept's
history. That table is read for the column's own cohort - demographics are
taken at each cohort's index, so a 2L column's under-75 are the patients under
75 at 2L - and a condition read off another cohort-specific table is carried
back with its cohort.

**A named table selects patients.** `S_LOT_PERIODS:LOT_NUM=3` is the patients
who went on to a third line, whatever `LOT_NUM` means in the table the row
reads. Two exceptions answer from the rows being summarised instead:

- rows of the named table itself are filtered as rows - T3's columns
  (`S_MALIGNANCY:LOT_AFTER_WHICH=1`) are the interval each malignancy fell in,
  not the patients who had one there;
- a table of totals has no patient to look up, so it answers only the subgroup
  it is written by: `S_DEMOGRAPHICS:AGE_GROUP=<75` (or `AGE_GROUP=<75`) is read
  off its own `AGE_GROUP` column, and any other table or column named against a
  table of totals is refused.

To select patients by something kept in the table a row reads, use a named
subgroup, which is always patients: T1b's neuropathy columns are
`NEUROPATHY=YES` and `NEUROPATHY=NO`, because its comorbidity rows read
`S_COMORB_SUBGROUP` too.

**Named subgroups.** `NEUROPATHY` and `FRAILTY` take `=YES` or `=NO` (`Y`/`N`,
`TRUE`/`FALSE`, `1`/`0`), `AGE` takes `=LT75` or `=GE75` (`<75`, `75+`); anything
else stops the load. Each is its own table's conditions and nothing else:
`NEUROPATHY=YES` is `S_COMORB_SUBGROUP:CONCEPT=neuropathy&HAS_HISTORY=1`,
`FRAILTY=YES` is `S_FRAILTY:FRAIL=1`, `AGE=LT75` is
`S_DEMOGRAPHICS:AGE_YEARS<75`. Written beside other conditions they are one
set: `NEUROPATHY=YES&HAS_HISTORY=0` is one row with a history of 1 and of 0,
which is nobody.

**Classes are `S_SOC` conditions on one line.** A class is the `S_SOC` row of
the column's line in the class's categories (holding its drug, where it names
one), so `ACD38_TRIP` on line 1 and `S_SOC:LOT_NUM=1&SOC_CATEGORY=Triplet with
anti-CD38 backbone` are one population. `S_SOC` conditions in a subgroup beside
a class are that same row only where they fix `LOT_NUM` to the class's own
line; on another line, or on any line, they are a second row of the patient,
and the column stops the load. A column may join classes with `|`, but not a
class a drug refines with one no drug refines, nor two refined by different
drugs.

### The overlap contract

Over one population - the columns of one cohort, line and period - two columns
that constrain a common quantity must either be unable to share a patient, or
constrain the same quantities with one inside the other. A quantity is a
column, or one of the groups `TFLS_DIMENSIONS` in `R/fill.R` lists: an age
(`AGE_YEARS`, `AGE_GROUP`, `AGE_BAND`, year of birth), a sex (`SEX`, `GDR_CD`),
a regimen class (a class, or `SOC_CATEGORY`, `REGIMEN`, `N_AGENTS` on `S_SOC`),
and so on. Anything else stops the load, because the patients in both columns
are the two less what they cover together: under 75 and 65 or over, 60 each of
100, give away the 20 aged 65 to 74. The same holds for 65 or over "of any sex"
beside under 75, and for quadruplets-or-triplets beside triplets-or-doublets,
whether each is a class or its categories written out on `S_SOC`. Columns on
different quantities - age beside frailty, a class beside a subgroup - are not
held to it.

A set of columns that overlaps in more than 256 ways over one population is
more splits than the suppression closes, and stops the load.

## Disclosure

Every cell goes through the study package's small-cell rule, and nothing here
can publish a number the package would have withheld.

**The floor.**

- The floor is 25, the protocol's. `TFLS_MIN_N` can only raise it; a lower
  value leaves it at 25.
- A cell whose denominator is under the floor, or cannot be counted, is
  withheld, and so is the count it was computed from.
- Where the cell is itself a count of patients - `n`, `n_pct`, and the patients
  a mean, median or minimum and maximum was taken over - that count reaches the
  floor too. A *rate* keeps the package's own rule: it is suppressed on its
  at-risk count, and the events inside a large population are published.
  `n_distinct` counts values, not patients, and goes with its population.
- **A survival curve publishes two counts, whatever the row prints**: the
  patients with the event, in `N`, and the patients censored, `DENOM` less `N`.
  Both reach the floor for every statistic read off the curve. A median over 30
  patients of whom 3 had the event is withheld.
- **A row whose own filter narrows its column's population** (`TTE_ELIGIBLE=1`)
  leaves out patients that every unfiltered row of the same population still
  counts; those left out reach the floor or the row is withheld.
- A withheld cell prints as `<25` (or the floor in force), never as a blank
  that could be read as zero.

**Relations.** A withheld cell is no secret when it is the last unknown in a
sum whose other terms are printed. The sums are read off the shells:

- a subtotal and the rows indented one step under it;
- the levels in one column and section against the column's denominator;
- a population against the columns that split it - `Overall` against its
  regimen classes and against its subgroups - in one table **or across tables**:
  T5c has no `Overall` of its own, and its age columns for a line split T4's
  `Overall` for that line, row for row. Between tables rows are matched on what
  they read (statistic, source, measure, filter), not on spelling: `s_tte` or
  `S_TTE`, `TTNT` or `TTNT_MONTHS`.

Columns are matched on what they select, not how they are written. The levels
of a split are the subgroups that cannot share a patient (`AGE_YEARS<75` and
`AGE_YEARS>=75`, `FRAIL=1` and `FRAIL=0`) and, for one line of one cohort, the
classes with no category in common. That is decided in patients: two values of
a column are two sets of patients only on a table with one row per patient in
the column's cohort, so a history of lung disease and a history of neuropathy,
two rows of `S_COMORB_SUBGROUP`, are not a split, while yes and no within one
concept are. A table or column the code does not describe is never taken for
one. A part inside another part is a sum too, with the rest of the larger part
as its unknown - under 65 inside under 75, T3's "after 2L but before 3L" inside
"after 2L+ anytime", a lone subgroup inside its `Overall` - and every population
is closed over every part inside it on its own. Every statistic takes part in a
split, not only the counts, because every printed cell carries its population in
`DENOM` and populations add up.

**A number printed twice is one number.** The same row over the same population
counts once in every sum and is withheld in every place it appears or in none:
a shell that repeats a row, T1b's `Overall` columns and rows (which are T1's),
a class named once by its id and once by its categories, a subgroup spelled two
ways (`NEUROPATHY=YES` and `=Y`, `AGE=LT75` and `S_DEMOGRAPHICS:AGE_YEARS<75`).

**Closure.** What a sum's printed terms leave out has to reach the floor: one
withheld cell, two withheld cells that add up to 12, or patients no term counts
at all. A split is exact - one withheld level is the total less the rest - only
where its levels cover their column: every value it can take (`NEUROPATHY=YES`
and `=NO`), a value and its complement (`X=a` and `X!=a`), or ranges with no
gap. Patients with no value - a NULL, the study's `Unknown` age or sex - are
left out of that, so `<75` and `75+` are the whole of `AGE_GROUP`. A nested
part, or a split that leaves a gap (`AGE_BAND` 65-74 and 75+ leave the younger
bands out), withholds only when what it leaves out is under the floor. Where a
sum needs one more cell withheld it takes its smallest printed term, preferring
a cell whose curve is already going.

**A curve goes whole.** When any cell of one column's curve is withheld - by the
floor, or to protect another cell - its events, censored, median and
probabilities all are: events and censored add up to the curve's population, so
either one printed gives the other away.

The closing repeats until no sum is short, then runs once more over all the
tables together. Because the regimen classes do not exhaust a line
(transplant-only lines belong to none), `Overall` less the classes is a count
of those patients and is floored like any other: on a full run, expect the
smallest class column of a line to be withheld on many rows. The `REASON`
column of each `tfls_<table>.csv` says which withheld cell was the small one
and which went only to protect it.

**Left to a person checking disclosure**, because the shells draw no sum that
would close them: consecutive steps of the sample-selection funnel (F1) differ
by the patients one step removes; `min`/`max` rows print single patients'
values; a curve cell refused as "past the observed follow-up" says that
population's longest follow-up is shorter than the month the row names.

### What is read

- Nothing patient-level is read into a cell or written; every file is checked
  for identifier columns on the way out.
- Where the run published a `_RELEASE` table, that is what is read, so the
  suppression is the package's own - and only where the run ran the release
  module, so a released table left by an earlier run is not preferred. Where
  the run says it published one and it is missing or empty, nothing is read at
  all - the raw table is not a substitute for the copy meant to replace it -
  and the unfilled list says which.
- **Where the run's own release record says a withheld cell is recoverable**
  (`S_RUN_METADATA.RELEASE_RECOVERABLE`, with the tables in
  `RELEASE_RECOVERABLE_TABLES`), the tables it names are not read: a higher
  floor here does not close a subtraction inside the released copy, and the raw
  table holds everything the release was run to remove. The rows resting on
  them are reported unfilled in the run's own words, and the fill says which
  case applies before a shell is filled. The fill decides the four cases as the
  dashboard does (`dashboard/DASHBOARD.md` "Deployment controls");
  `TFLS_ALLOW_RECOVERABLE=TRUE` fills from them anyway and prints that it did.

The tables are counts over a claims database and carry its limits: a code is
evidence of a claim, not of a diagnosis, and an absence is evidence of neither.
