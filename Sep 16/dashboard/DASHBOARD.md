# The dashboard

An R Shiny app over finished study runs: what the study package and the LOT
engine produced, with controls a viewer can change without anyone re-running
anything. The app **reads**: it creates, replaces and drops nothing. The one
thing in this folder that writes is the snapshot Job that feeds it ("Deploying
on Domino" below).

`dashboard/` sits beside `variables/`, `lot/` and `TFLS/`, and they have to
stay siblings. The app loads the study package's registries from
`../variables` (`DASH_PACKAGE_DIR` moves it) and, on first use, the shells'
code from `../TFLS` (`DASH_TFLS_DIR` moves it); without the shells only the
Tables tab is lost. It does not load the LOT engine's code: LOT results reach
it as tables, and the test suite reads `../lot/engine` only to hold the two
table lists to each other.

---

## The page

A header with the title and how many scenarios were found where; a left
sidebar; a row of tabs; panels stacked down each tab. A synthetic source says
so in a banner on every page.

| sidebar control | what it does |
|---|---|
| **Scenario** | the run to show. A run that is not `complete`, or was driven by another study contract, is listed with its state or `[other contract]` beside it |
| (under it) | the readings that differ between scenarios, and any notice about this run - not complete, or tables its own release record refuses |
| **Selection** | cohort, line and period, and the two strata the rate tables are written by (SOC category and age group), offered from what the scenario's own tables carry. Cohort starts at `DASH_DEFAULT_COHORT`, a stratum at the line's own row |
| **Suppress cells below N** | the floor. The slider starts at `DASH_SUPPRESS_MIN_N` (25 or more); its upper bound is 200, or that floor when it is higher. It can be raised, never lowered below that |
| **Against** | a second scenario, for the Compare tab |

| tab | what is on it |
|---|---|
| **Overview** | what produced these numbers; cohort sizes as headline counts; the attrition funnel, criterion by criterion |
| **Cohort** | baseline demographics; Charlson comorbidity; baseline and follow-up periods |
| **Safety** | key safety events as rates per the run's `RATE_MULTIPLIER` (100,000 person-years by default), as a chart and as a table |
| **HCRU** | hospitalisation, length of stay and ED visits |
| **Malignancy** | secondary malignancies |
| **Outcomes** | TTNT, TTD and overall survival as Kaplan-Meier curves, and the endpoints as a table |
| **Patterns** | regimen categories by line; what happened on each line; regimen transitions |
| **Tables** | the study's table shells, filled from this scenario; and the class mapping behind their columns |
| **Compare** | one scenario against another, stratum by stratum; and every open question with where it is answered |
| **LOT engine** | the LOT run these lines came from; the LOT funnel; lines by line number; how a line ended against how the next one opened; the commonest line sequences; the regimen of a line against the next; what opened each line; how each line ended |
| **LOT validation** | face-validity checks; the QC checks; build status; before and after the line criteria |

A panel whose module did not run is **reported, not hidden**: "the safety
module did not run" is something a viewer needs to know.

### Which run a number comes from

Every number is read **bound to the build the sidebar describes**: the run id,
and its state and timestamp, since a re-run inside one Domino run keeps its
id. The binding is checked around each read, so a snapshot rebuilt after the
page was opened shows a notice in place of each panel until the page is
reloaded.

- A run that is `started` or `failed` is listed, with its settings and the LOT
  run it read, and none of its tables is shown: the producer writes the
  metadata row before it replaces a table, so its tables are the previous
  build's, or part of this one.
- A run driven by a different study contract (`S_RUN_METADATA.STUDY_CONTRACT_MD5`
  against the registry loaded at startup) is listed as `[other contract]` and
  none of its tables is shown: which tables it wrote and released cannot be
  decided from this registry. A run that recorded no hash is used.
- A run shows only what it built. A table whose module the run did not select
  is not shown, drawn, offered to select on or compared (Compare says which
  side lacks it); rows of cohorts the run did not select are left out; and the
  released copy of a table is preferred only where the run ran the release
  module.

### The line-to-line panels

These check that the lines make sense together. Each pairs a patient's
consecutive lines and counts distinct patients per pair: the reason line n
ended against what opened line n+1, the agents of line n against those of line
n+1, and each patient's whole sequence of line openings. A line that ran out of
treatment followed by a transplant-opened line, a CAR-T consolidation end with
no CAR-T start behind it, or a regimen returning in full one line later shows
up here and nowhere else. Picking a line in the sidebar narrows the pairs to
those from that line.

A pair under the floor is not shown on its own, and neither is any pair whose
count could be read off a published total (what opened line n+1, the pairs
from a line, how line n ended) once the others are known; those are grouped
into one row per line whose count is their sum, and the grouped row does not
say how many pairs it holds. Each total is held on its own - the subtraction a
reader makes - not every total taken together. No patient is ever listed.

### The LOT tabs describe the lineage, not the scenario

The LOT tables were written by a different build, under its own prefix, and a
study scenario records which run - and which build of it - it read
(`S_RUN_METADATA.LOT_RUN_ID`, `LOT_RUN_VERSION`). None of the study's open
questions changes how a line is counted, so scenarios normally share one LOT
run, and two scenarios sharing one show identical numbers on these tabs.

`LOT_LONG` is only on the validation tab. It is the same table *before* the
line criteria, and a truncate criterion makes the two hold different patients,
so a panel drawn on it would describe people the study excluded.

### The Tables tab

The shells are the sibling `TFLS/` folder (`TFLS/README.md`). The tab loads
that code and hands it **this dashboard's own reader**, bound to the run the
sidebar names like every other panel, so a shell cell and the same figure on
another tab are one table, read one way.

| control | what it does |
|---|---|
| **Table** | which shell to show, by the title `shells/tables.csv` gives it |
| **Apply the study's time-to-event eligibility flag** | off by default. The study writes the whole cohort into its time-to-event table and marks the restricted analysis with `TTE_ELIGIBLE`, so applying it is a decision, and the table says which way it went |
| **Show the rows nothing could fill** | lists them with the reason, grouped by whose gap it is: the run did not write it, the shell does not say enough, or the statistic cannot be made from what the table holds |

The floor is the sidebar's, raised by `DASH_SUPPRESS_MIN_N` and then by the
shell engine's own 25, so on this tab it is never below 25. A withheld cell
prints as `<25` (or the floor in force), never as a blank; the line under each
table says how many cells were withheld and at what floor. A row nothing could
fill reads as *not filled*, never as a zero.

**Every table is filled and suppressed together**, as the written outputs are,
though the tab shows one at a time: some sums only exist across tables (T5c's
age columns split T4's `Overall`). The joint fill is kept per scenario, run and
setting, so picking another table costs nothing; a fill during which the run
moved is not kept.

The second panel is the **class mapping** from `shells/regimen_classes.csv`:
each class heading and the study categories it rolls up. If the shells are not
beside the dashboard, this tab says so and the rest of the page is unaffected;
a shell file with a mistake in it shows the loader's own message, naming the
file and the row.

---

## What a control can and cannot change

**Live - answered instantly.** The Selection keys filter numbers that are
already computed, and the floor raises the suppression threshold.

**Scenario - needs a run.** An open question changes the SQL, so it cannot be
applied to a finished table: `S_SAFETY_RATES` was computed under **one**
reading of the washout, and no filter recovers another. So the scenario picker
lists the runs that **exist**, and a scenario nobody has run does not appear.
The settings panel says, for every open question, whether it is applied by this
package or upstream, what this run answered, which environment variable sets
it, and that it is **not** a live control.

To produce a scenario, add a row to `scenarios.csv` and run the snapshot Job
("The snapshot Job" below). `scenario_command()` in `R/scenarios.R` turns a set
of readings into the shell lines such a run needs, every value shell-quoted; it
is a tested helper, not wired to the page, because running one writes to the
warehouse.

## Compare

Pick a second scenario in **Against**, and every rate table (safety, HCRU,
malignancy) is shown stratum by stratum: A, B, the difference and the
percentage change, sorted by how far apart they are, under the settings that
differ. Both sides have to be complete runs, and still the builds the page
opened on.

Before it draws anything it answers one question: **do these two rest on the
same lines?** Two scenarios sharing a LOT run - the same run *and the same
build of it* - differ only in what the study package did. Two reading
different runs, or two builds of one run, differ in the lines as well, and a
difference between them carries both; a banner above the numbers says which
case it is, or that it cannot be said.

## Suppression

1. The study package suppressed every cell under **25 patients** into its
   `S_*_RELEASE` tables before the dashboard saw anything.
2. The app applies its own floor on top, on every table it draws: the larger
   of the sidebar's value and `DASH_SUPPRESS_MIN_N`, which can raise the
   study's 25 and never lower it - a value under 25 stops the App at
   start-up. Raising it hides more.

The rule is applied **after aggregation, on the thing being drawn** - headline
counts, tables, charts, survival curves, captions and comparisons all go
through one release check. A withheld cell reads as withheld, never as a zero.

A patient-level table is **never** rendered as a grid. It is summarised -
counts and percentages per level, mean and median for continuous columns - and
every identifier column is dropped whatever the spec says. Where one level of a
variable is withheld, a second goes with it, because otherwise the hidden one
is the difference between the total and the rest. A table with no declared
denominator is still suppressed: the floor finds a count column when the spec
names none.

A run whose own release record says a withheld cell is recoverable has those
tables refused on every read, and the sidebar says which ("Deployment
controls" below).

---

## Where the numbers come from

| `DASH_SOURCE` | reads | for |
|---|---|---|
| `snapshot` | the CSVs the snapshot Job wrote under `DASH_SNAPSHOT_DIR` | **the normal deployment.** No warehouse session per viewer |
| `warehouse` | the tables directly, over the study package's own connection ("Reading the warehouse directly" below) | a live check by one analyst |
| `synthetic` | rows generated in-process | a demo with no data behind it, and the default for the tests |

### Settings

Read in `config/dashboard_config.R`, except `DASH_ALLOW_RECOVERABLE`
(`R/sources.R`) and `SHOW_<PANEL>` (`R/panels.R`).

| setting | default | |
|---|---|---|
| `DASH_SOURCE` | `synthetic` | `snapshot`, `warehouse` or `synthetic`; anything else stops startup |
| `DASH_SNAPSHOT_DIR` | `/mnt/data/NDMM` | the snapshot root |
| `DASH_ALLOW_SYNTHETIC` | `TRUE` | `FALSE` refuses to start on synthetic data |
| `DASH_PREFIXES` | (discover) | the scenario prefixes to offer, `,` or `\|` between. In a snapshot, a name that is not letters, digits, `.`, `_` or `-`, starting with a letter or digit, matches no directory and is not offered |
| `DASH_PREFIX_PATTERN` | `^s223926` | warehouse: which discovered prefixes to offer |
| `DASH_CATALOG` | `DATABRICKS_CATALOG`, then `hive_metastore` | warehouse catalog |
| `DASH_WORK_SCHEMA` | `WORK_SCHEMA`, then `PROJECT_WORK_SCHEMA`, then the Domino user's own | warehouse schema, in the study run's order; `catalog.schema` accepted where the catalog matches |
| `DASH_LOT_PREFIX` | (none) | warehouse: where the LOT build wrote, for the LOT tabs |
| `DASH_SUPPRESS_MIN_N` | `25` | the lowest floor the page applies, and the slider's lowest value. It can raise the study's 25, never lower it: a value under 25, or not a whole number, stops the App at start-up |
| `DASH_PREFER_RELEASE` | `TRUE` | read the `_RELEASE` copy where the run released one. `FALSE` reads the working table instead, under the page's floor alone |
| `DASH_ALLOW_RECOVERABLE` | `FALSE` | show tables the run's own release record refuses ("Deployment controls") |
| `DASH_DEFAULT_COHORT` | `1L` | the cohort the Selection starts at |
| `DASH_MAX_ROWS` | `5000` | the most rows a table on the page prints |
| `DASH_PACKAGE_DIR` | `../variables` (`app.sh`: `variables`) | the study package |
| `DASH_TFLS_DIR` | `../TFLS` | the shells |
| `DASH_TITLE` | `GSK 223926 - NDMM / RRMM explorer` | the page title |
| `DASH_RUN_CMD` | `Rscript build.R` | the command `scenario_command()` writes |
| `SHOW_<PANEL>` | shown | `FALSE` drops a panel; anything other than `TRUE` or `FALSE` stops startup |

---

## Deploying on Domino

Two pieces: a **Job** builds the scenarios and exports them to a snapshot; an
**App** serves the snapshot.

### Compute environment

R plus `shiny` is all the App needs: the plots are base graphics and the
Kaplan-Meier estimator is written out. Bake these into the environment's
Dockerfile so the App starts fast:

```r
install.packages("shiny")
install.packages("survival")          # optional: only the test cross-check uses it
install.packages(c("DBI", "odbc"))    # the Job, and DASH_SOURCE=warehouse
install.packages("sparklyr")          # only where SPARK_METHOD names a Spark session instead of the ODBC DSN
```

### Smoke test with no data

Deploy the App with nothing set. It comes up on synthetic scenarios and says so
on every page, which proves the environment, the launcher and the port before
any warehouse question is involved.

### The snapshot Job

Run the cohort build and the LOT build first (the study folder's `README.md`,
"Running it"), then, as a Domino **Job**:

```bash
export DATABRICKS_PWD=...                      # a Domino secret, never a config file
export PROJECT_WORK_SCHEMA=...
export INPUT_COHORT_TABLE=ndmm_NDMM_COHORT     # what the study run reads -
export LOT_PREFIX=ndmm_                        #   the same three step 3
export COHORT_PREFIX=ndmm_                     #   was given
export CODELIST_DIR=/mnt/code/codelist
export DASH_SNAPSHOT_DIR=/mnt/data/NDMM        # a Domino Dataset, mounted under /mnt/data
Rscript dashboard/jobs/build_scenarios.R       # from wherever the folders sit
```

`build_scenarios.R [scenarios.csv] [out_dir]` takes the grid and the snapshot
root as optional arguments; they default to `dashboard/scenarios.csv` and
`DASH_SNAPSHOT_DIR`.

**One row of `scenarios.csv` is one full study run.** `prefix` is the
`OBJECT_PREFIX` it writes under - unique, compared without case, and letters,
digits, `.`, `_` and `-` only, starting with a letter or digit, since it also
names a directory. Every other upper-case column is set as an environment
variable for that run and nothing else, so **the column name is the variable
name** and a new open question is available the moment the package reads it. A
value that is itself a list, such as `ED_DEFINITION`'s `revenue,pos`, is quoted
in the file. The test suite runs every bundled row through the package's
config, so a value the package would refuse fails there rather than on the
cluster.

**What every row reads is the Job's own.** `INPUT_COHORT_TABLE`, `LOT_PREFIX`
and `COHORT_PREFIX` come from the Job's environment, the study package's
`config.csv`, or a column of the same name; without any of them the Job stops
before the first build and names what is missing, since a read prefix left
blank would be each scenario's own. Without `CODELIST_DIR`, every module whose
code list is still the bundled blank template is left out of every scenario.
Anything else step 3 was given - `LOT_CODE_MD5`, `MODULES`, `SKIP_MODULES` -
is set on the Job too.

The Job connects as the study run does - the study package's own
`connect_db()`, on `DATABRICKS_DSN` and `DATABRICKS_PWD` - and reads where it
wrote: `WORK_SCHEMA`, else `PROJECT_WORK_SCHEMA`, else the Domino user's own
schema, in `DATABRICKS_CATALOG`. `DASH_WORK_SCHEMA` and `DASH_CATALOG` are the
App's, not the Job's.

**Each scenario runs in its own R process**, and one that fails does not stop
the others. Its full output is kept at `<DASH_SNAPSHOT_DIR>/<prefix>build.log`.
The summary at the end lists each scenario as built or failed and exported or
not, and the Job exits non-zero if any failed.

**What is exported.** Each scenario's tables go to
`<DASH_SNAPSHOT_DIR>/<prefix>/<TABLE>.csv`, and the LOT build's to
`<DASH_SNAPSHOT_DIR>/lot/<LOT_RUN_ID>.<build>/<TABLE>.csv` - filed by run and
build, not by scenario, because scenarios normally share one LOT run and the
engine can build one run id more than once. A build already exported is
reused, and the LOT prefix is copied only while its newest status row is the
build the scenario read.

- A scenario is exported only from a `complete` run driven by this study
  contract, pinned before its first table is read and checked again after its
  last; a rebuild in between stops the export.
- Only the tables that run's own metadata says it wrote, with only the rows of
  the cohorts it selected. A run that recorded no modules or no cohorts
  exports nothing.
- A run whose release record is not `none` is not exported ("Deployment
  controls").
- The tables are staged and the scenario's directory swapped whole, so a
  refresh that fails leaves the previous snapshot in place. A refresh *killed*
  mid-swap leaves the previous snapshot set aside under a name no reader
  lists, and the next export into that directory puts it back, or discards it
  where the swap had completed, before it swaps.
- One export at a time into a root: an `.export.lock` directory refuses a
  second Job, and one left by a killed Job is removed by hand, as its message
  says.

Re-run the Job on each data refresh; the App reads the new snapshot on
restart. Cost: one full study run per scenario - start with two or three rows.

### The App

Domino launches the App command from the **project root** and expects the
process on `0.0.0.0:8888`; `app.sh` does that. Set the App command to `bash
<folders>/dashboard/app.sh`, giving the path from the project root to wherever
the four folders sit; `app.sh` changes to the folder above `dashboard/`
itself. Set the App's environment variables:

```
DASH_SOURCE=snapshot
DASH_SNAPSHOT_DIR=/mnt/data/NDMM
DASH_ALLOW_SYNTHETIC=FALSE
```

`DASH_ALLOW_SYNTHETIC=FALSE` makes an App left on synthetic numbers refuse to
start and say why, so nobody quotes generated data because a default was left
in place. A snapshot directory that is missing or empty lists no scenarios; it
never falls back to synthetic data.

**The snapshot lives in a Domino Dataset**, because an App reads a Dataset it
has attached and does not see another run's artifacts. Create the Dataset
first: the Job writes into whatever is mounted at `DASH_SNAPSHOT_DIR`, so with
no writable Dataset there it writes into the run's own scratch space, which
disappears with it, or fails on a read-only path. Attach one writable Dataset
to the Job and to the App (the Data step of the publish dialog) and point
`DASH_SNAPSHOT_DIR` at its mount. `/mnt/data/NDMM` is where a **local** Dataset
named `NDMM` mounts; one imported from another project mounts elsewhere, so
read the mount path off the Data step. The Job and the App only have to agree
with each other.

### Deployment controls

None of these is visible from inside the app, and each needs a decision rather
than a default.

**The Dataset is as sensitive as the warehouse.** The Job exports every table
the run wrote - the raw ones beside the released ones - because a table with no
released copy has only its raw form and the App needs it. Several are one row
per patient and carry `PATID`. The App drops identifiers and prefers released
copies, but a person with filesystem or project access to the Dataset is not
going through the App. Keep the Dataset **private to the App and the Job**.

**Access to the Dataset is the one control not in the code.** Who may read the
files is set on the Domino Dataset and the project that owns it. Grant it to
the App and the Job and to nobody else, and re-check it whenever the project's
collaborators change; every other control here is downstream of that one.

**The shareable output is the shells, not a cut of the Dataset.** Seven tables
have an `S_*_RELEASE` copy; the rest of what a panel draws - the attrition
steps, the demographics, the line patterns, the time-to-event summaries - has
none, so an extract cut down to the released tables is both **incomplete** for
a reader and still **unsuppressed** wherever it is not. `TFLS/run_tfls.R`
fills the shells from the run at a floor that may only rise, writes tables that
carry no identifier and no cell under the floor, and applies the release
verdict below. It writes to `TFLS/out/` (or `TFLS_OUT_DIR`), which is not the
Dataset and must not be moved into it: where the two sit in one directory, the
next person to grant access grants both. Where a raw table itself has to go
out, that is a disclosure check by a person, not a file copy.

**The release verdict.** `mod_release()` withholds every cell under the floor,
then records in `S_RUN_METADATA.RELEASE_RECOVERABLE` the groups where one
withheld cell is still the group's total less the published rest, and in
`S_RUN_METADATA.RELEASE_RECOVERABLE_TABLES` the tables those groups are in -
the second is what a refusal is decided on, the first is the sentence a person
reads. Whether to regroup or withhold a second stratum is the analyst's call;
the code only declines to make it by default.

| the run's record says | the snapshot Job | the App, and the shell fill (`TFLS/run_tfls.R`) |
|---|---|---|
| `none` | exports | everything |
| a finding, e.g. `S_SAFETY_RATES_RELEASE: 3 …` | refuses | everything except the tables `RELEASE_RECOVERABLE_TABLES` lists. Where that list is absent or names anything that is not one of the seven released tables, the finding's own text decides: the released tables it names, or all seven where it names none |
| `release module did not run` | refuses | everything except the seven that would have had a released copy: they have none, so what is under the prefix is the working table the release was meant to replace |
| nothing at all | refuses | everything, with a notice: the Job is the check for this case, and re-exporting through it is what settles it |

Each path has one override, which says on the run that it was set:
`SNAPSHOT_ALLOW_RECOVERABLE=TRUE` exports anyway, `DASH_ALLOW_RECOVERABLE=TRUE`
shows the refused tables, `TFLS_ALLOW_RECOVERABLE=TRUE` fills from them.
`DASH_ALLOW_RECOVERABLE` is for a **single analyst** reading their own
unreleased run, not for a shared App. None of the three is a control against
someone who can set environment variables on the Job.

**A warehouse App is a second way in.** `DASH_SOURCE=warehouse` reads the
tables live, so nothing it shows has been through the Job; it applies the
verdict above on each read. Prefer the snapshot for anything more than one
analyst.

**Names are quoted, and path segments are checked.** `DASH_CATALOG`,
`DASH_WORK_SCHEMA`, `DASH_PREFIXES` and `DASH_LOT_PREFIX` reach SQL, so each
goes in backtick-quoted, Spark's delimited identifier: a leading underscore, a
hyphen, an all-digit name or a reserved word reads correctly, and a prefix of
`x; DROP TABLE p; --` is one identifier no warehouse has, so the read finds
nothing instead of running it. What is refused is only what quoting cannot
hold: a backtick, a control character, an empty name. A scenario prefix, and
the LOT run id and build that name a LOT directory (`<run id>.<build>`), are
used only as one path segment - letters, digits, `.`, `_` or `-`, starting with
a letter or digit - so a run id of `../../PRIVATE` cannot reach a file outside
the snapshot root. The Job checks the LOT name before it builds the directory
or its staging copy, and a name that fails stops that scenario's export with
nothing published; the page checks every segment again when it reads.
`TFLS_PREFIX` is held to the same rule.

### Reading the warehouse directly

`DASH_SOURCE=warehouse` reads the `S_*` tables live from the schema the study
run wrote to (`DASH_WORK_SCHEMA` and `DASH_CATALOG` point it elsewhere).
Scenarios are the tables whose name ends in `S_RUN_METADATA`, filtered by
`DASH_PREFIX_PATTERN` unless `DASH_PREFIXES` lists them. The connection is the
study package's own, over the Databricks ODBC DSN by default, so the App needs
`DATABRICKS_PWD` as well. Add `DASH_LOT_PREFIX` for the LOT tabs: the study's
metadata records which LOT *run* a scenario read, not where that run wrote, and
the prefix's newest status row has to be that run and build before any of its
tables is read, so a prefix pointing at a different one is caught rather than
drawn. The App opens one connection as it starts and every viewer shares it,
re-querying on every control change.

---

## Running it outside Domino

```bash
# a demo with generated data, no warehouse - from this folder
DASH_SOURCE=synthetic Rscript -e "shiny::runApp('.', port = 8888)"

# a snapshot - app.sh changes to the folder above dashboard/, so it can be
# started from anywhere
DASH_SOURCE=snapshot DASH_SNAPSHOT_DIR=/mnt/data/NDMM ./app.sh

# the suite: no Shiny and no warehouse
Rscript tests/run_tests.R
```

Every number the app puts on a page comes from a function in `R/` that runs
without Shiny, which is what makes the suite possible. `app.R` is wiring, and
the last section of the suite reads it as text to hold the wiring to the
registries.

## Adding to it

The study package is the authority on what exists: which cohorts, which
modules, which tables, which open questions and what each may be set to. The
dashboard imports those rather than restating them, so a new open question
appears in the settings panel and the scenario labels without an edit. A new
**table** is known without an edit, but is only *shown* once a panel in
`R/panels.R` points at it; a table with no spec gets a plain grid.

| to add | edit |
|---|---|
| a panel | one entry in `R/panels.R` |
| a better view of a table | one entry in `TABLE_SPEC`, `R/spec.R` |
| a scenario | one row in `scenarios.csv` |
| a table shell, a row of one, or what a class column holds | one row in the shells beside this folder, and no code at all |
| a LOT table | one entry in `TABLE_SPEC` with `source = "lot"`, and one in `LOT_DASHBOARD_TABLES` |
| a module, a cohort, an open question | the **package** - it appears here on its own |

## The files

| file | what it is |
|---|---|
| `app.R` | the Shiny wiring: the sidebar, the tabs, and which panel goes where |
| `global.R` | loaded once at startup: the package's registries and the hash of the contract they are, then the dashboard's, then the data source |
| `config/dashboard_config.R` | the `DASH_*` environment variables, validated |
| `R/spec.R` | `TABLE_SPEC` - how each table is best shown, and which columns identify a patient |
| `R/panels.R` | the panel registry - what is on each tab |
| `R/scenarios.R` | a scenario from a run's metadata, the settings that differ between two, and the command that would produce one |
| `R/sources.R` | the three data sources, the run-ownership check every read is bound to, and the release verdict |
| `R/prepare.R` | the release check applied to everything drawn |
| `R/tfls.R` | the table shells: loading the engine beside this folder, filling a shell and drawing it |
| `R/aggregate.R` | counts, percentages and distributions over a patient-level table |
| `R/render.R` | the HTML tables, headline counts and charts |
| `R/synthetic.R` | the generated rows behind the demo |
| `jobs/build_scenarios.R`, `jobs/export_lib.R` | the snapshot Job |
| `scenarios.csv` | one row per scenario the Job builds |
| `app.sh` | the Domino launcher |
| `tests/run_tests.R` | the suite |
