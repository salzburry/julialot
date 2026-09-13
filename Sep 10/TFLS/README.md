# TFLS — the requested table shells, filled

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
| `stat` | `n_pct`, `mean_sd`, `median_iqr`, `min_max`, `n`, `rate`, `km_median`, `km_prob`, `km_events`, `km_censored` |
| `source` | the study table it reads, e.g. `S_DEMOGRAPHICS` |
| `measure` | the column or facet value, e.g. `SEX=Female`, `AGE_YEARS`, `CONDITION=Acute hepatitis` |
| `filter` | any extra restriction, e.g. `PERIOD=FOLLOWUP`, `MONTHS=12` |
| `note` | footnote marker |

### `regimen_classes.csv`

A class is matched against the line's regimen, which is a list of drug
abbreviations. `require_all` and `require_any` are space-separated lists,
`exclude_any` likewise, and `n_agents_min` / `n_agents_max` bound the count.
`priority` breaks ties: the lowest-numbered matching class wins, so BCMA and
bispecific claim a regimen before the size-based classes do. `OVERALL` is the
column total and matches by definition.

## Disclosure

Every cell goes through the same small-cell rule the study package applies, at
the same floor, and nothing here can publish a number the package would have
withheld.

- A cell whose denominator is under the floor is suppressed, and so is the
  count it was computed from. The default floor is 25, the protocol's, and
  `TFLS_MIN_N` can only raise it.
- Where exactly one cell in a group is suppressed, a second one goes with it.
  Otherwise the withheld cell is the group total minus the published rest.
- A suppressed cell prints as `<25` (or the floor in force), never as a blank
  that could be read as zero.
- Nothing patient-level is read or written. No identifier reaches `out/`.
- Where the study package published a `_RELEASE` table, that is what is read,
  so the suppression is the package's own and not a second opinion of it.

The tables are counts over a claims database and carry its limits: a code is
evidence of a claim, not of a diagnosis, and an absence is evidence of neither.

## The dashboard

The same shells drive a tab in the dashboard, where the table, the line, the
regimen class definitions, the subgroup and the floor are controls. The
requestor can move a definition and watch the table move, which is the point of
having the classes in a CSV rather than in the code.
