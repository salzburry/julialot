# The dashboard — what it is and what it shows

An R Shiny app that shows what the study build and the LOT engine produced, and
lets a stakeholder change what they are looking at without anyone re-running
anything. It **reads**: it creates, replaces and drops nothing, so it can be
pointed at a finished study as often as anyone likes. The one thing in this
folder that writes is the snapshot job that feeds it (`DEPLOY_DOMINO.md`).

It sits beside `variables/`, `lot/` and `TFLS/`, and they have to stay siblings.
The app loads the study package's registries from `../variables`
(`DASH_PACKAGE_DIR` moves it). It does **not** load the engine's code: LOT
results reach it as tables, from the snapshot or the warehouse, and its test
suite reads `../lot/engine` only to hold the two table lists to each other. It
loads the shells' code from `../TFLS` (`DASH_TFLS_DIR` moves it) on first use,
and a deployment without that folder loses the Tables tab and nothing else.

---

## The page

A header with the title and how many scenarios were found where; a left
sidebar of controls; a row of tabs across the top; panels stacked down each
tab. A synthetic source says so in a banner on every page.

The sidebar:

| control | what it does |
|---|---|
| **Scenario** | the run to show. A run that is not `complete`, or was driven by another study contract, is listed with its state or `[other contract]` beside it |
| (under it) | the readings that differ between scenarios, and any notice about this run - not complete, or tables its own release record refuses |
| **Selection** | cohort, line and period, and the two strata the rate tables are written by (SOC category and age group), offered from what the scenario's own tables carry. Cohort starts at `DASH_DEFAULT_COHORT` (`1L`), a stratum at the line's own row |
| **Suppress cells below N** | the floor, from `DASH_SUPPRESS_MIN_N` (25) up to 200. It can be raised, never lowered |
| **Against** | a second scenario, for the Compare tab |

---

## The tabs

| tab | what is on it |
|---|---|
| **Overview** | what produced these numbers; cohort sizes as headline counts; the attrition funnel, criterion by criterion |
| **Cohort** | baseline demographics; Charlson comorbidity; baseline and follow-up periods |
| **Safety** | key safety events as rates per the run's `RATE_MULTIPLIER` (100,000 person-years by default), as a chart and as a table |
| **HCRU** | hospitalisation, length of stay and ED visits |
| **Malignancy** | secondary malignancies |
| **Outcomes** | TTNT, TTD and overall survival as Kaplan-Meier curves, and the endpoints as a table |
| **Patterns** | regimen categories by line; what happened on each line; regimen transitions |
| **Tables** | the requested table shells, filled from this scenario; and the class mapping behind their columns |
| **Compare** | one scenario against another, stratum by stratum; and every open question with where it is answered |
| **LOT engine** | the LOT run these lines came from; the LOT funnel; lines by line number; how a line ended against how the next one opened; the commonest line sequences; the regimen of a line against the next; what opened each line; how each line ended |
| **LOT validation** | face-validity checks; the QC checks; build status; before and after the line criteria |

A tab whose module did not run is **reported, not hidden**: "the safety module
did not run" is something a viewer needs to know.

**The line-to-line panels** are the ones for checking that the lines make sense
together. Each pairs a patient's consecutive lines and counts distinct patients
per pair: the reason line n ended against what opened line n+1, the agents of
line n against those of line n+1, and each patient's whole sequence of line
openings. A line that ran out of treatment followed by a transplant-opened
line, a CAR-T consolidation end with no CAR-T start behind it, or a regimen
returning in full one line later shows up here and nowhere else. Picking a line
in the sidebar narrows the pairs to those from that line. A pair under the
floor is not shown on its own, and neither is any pair whose count could be
read off a published total (what opened line n+1, the pairs from a line, how
line n ended) once the others are known; those are grouped into one row per
line whose count is their sum, and the grouped row does not say how many pairs
it holds. Each total is held on its own - the subtraction a reader makes - not
every total taken together. No patient is ever listed.

### Which run a number comes from

Every number on every tab is read **bound to the build the sidebar describes**:
the run id, and its state and timestamp, since a re-run inside one Domino run
keeps its id. The binding is checked around each read, so a snapshot rebuilt
after the page was opened shows a notice in place of each panel until the page
is reloaded.

- A run that is `started` or `failed` is listed, with its settings and the LOT
  run it read, and none of its tables is shown: the producer writes the metadata
  row before it replaces a table, so its tables are the previous build's, or
  part of this one.
- A run driven by a different study contract (`S_RUN_METADATA.STUDY_CONTRACT_MD5`
  against the registry loaded at startup) is listed as `[other contract]`, and
  none of its tables is shown: which tables it wrote and released cannot be
  decided from this registry. A run that recorded no hash is used.
- A run shows only what it built. A table whose module the run did not select
  is not shown, drawn, offered to select on or compared (Compare says which
  side lacks it); rows of cohorts the run did not select are left out; and the
  released copy of a table is preferred only where the run ran the release
  module.

### The Tables tab is the requested shells, filled

The shells are the sibling `TFLS/` folder (`TFLS/README.md`). The tab loads
that code and hands it **this dashboard's own reader**, bound to the run the
sidebar names like every other panel, so a shell cell and the same figure on
another tab are one table, read one way.

| control | what it does |
|---|---|
| **Table** | which shell to show, by the title `shells/tables.csv` gives it |
| **Apply the study's time-to-event eligibility flag** | off by default. The study writes the whole cohort into its time-to-event table and marks the restricted analysis with `TTE_ELIGIBLE`, so applying it is a decision, and the table says which way it went |
| **Show the rows nothing could fill** | lists them with the reason, grouped by whose gap it is: the run did not write it, the shell does not say enough, or the statistic cannot be made from what the table holds |

The floor is **the sidebar's**, raised by the package's and then by the shell
engine's, so it can only withhold more. A withheld cell prints as `<25` (or the
floor in force), never as a blank; the line under each table says how many
cells were withheld and at what floor. A row nothing could fill reads as *not
filled*, never as a zero.

**Every table is filled and suppressed together**, as the written outputs are,
though the tab shows one at a time: some sums only exist across tables (T5c's
age columns split T4's `Overall`). The joint fill is kept per scenario, run and
setting, so picking another table costs nothing; a fill during which the run
moved is not kept.

The second panel is the **class mapping**, from `shells/regimen_classes.csv`:
each class heading and the study categories it rolls up. Editing one line of
that file changes the columns of every table above it, with no code to edit.

If the shells are not beside the dashboard, **this tab says so and the rest of
the page is unaffected**. A shell file with a mistake in it shows the loader's
own message, naming the file and the row.

### The LOT tabs describe the lineage, not the scenario

The LOT tables were written by a **different build**, under its own prefix, and
a study scenario records which run - and which build of it - it read
(`S_RUN_METADATA.LOT_RUN_ID`, `LOT_RUN_VERSION`). Several scenarios normally
share one run - none of the study's open questions changes how a line is
counted - so two scenarios sharing a LOT run show identical numbers on these
tabs.

`LOT_LONG` is only on the validation tab. It is the same table *before* the
line criteria, and a truncate criterion makes the two hold different patients,
so a panel drawn on it would describe people the study excluded.

---

## The controls, and what they can and cannot do

**Live - answered instantly.** The Selection keys filter numbers that are
already computed, and the floor raises the suppression threshold. Nothing has
to be re-derived.

**Scenario - needs a run.** An open question changes the SQL, so it cannot be
applied to a finished table: `S_SAFETY_RATES` was computed under **one** reading
of the washout, and no filter recovers another. So the scenario picker lists
the runs that **exist**, and a scenario nobody has run does not appear. The
settings panel says, for every open question, whether it is applied by this
package or upstream, what this run answered, which environment variable sets
it, and that it is **not** a live control.

To produce a scenario, add a row to `scenarios.csv` and run the snapshot job
(`DEPLOY_DOMINO.md`). `scenario_command()` in `R/scenarios.R` turns a set of
readings into the shell lines such a run needs, every value shell-quoted; it is
a tested helper for whoever owns the schema, not wired to the page, because
running one writes to the warehouse.

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

Two layers, and the app can only ever hide **more** than the build did.

1. The study package suppressed every cell under **25 patients** into its
   `S_*_RELEASE` tables before the dashboard saw anything.
2. The app applies the viewer's floor on top. Raising it hides more; it cannot
   be set below the package's 25.

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
tables refused on every read; the sidebar says which. `DEPLOY_DOMINO.md`
**Deployment controls** has the four cases and the override.

---

## Where the numbers come from

Three sources, chosen with `DASH_SOURCE`:

| source | reads | for |
|---|---|---|
| `snapshot` | the CSVs `jobs/build_scenarios.R` wrote, `<DASH_SNAPSHOT_DIR>/<prefix>/<TABLE>.csv`, and the LOT tables under `lot/<LOT_RUN_ID>.<build>/` | **the normal deployment.** No warehouse session per viewer |
| `warehouse` | the tables directly, over the study package's own connection | a live check by one analyst |
| `synthetic` | rows generated in-process | a demo with no data behind it, and the default for the tests |

A synthetic run says so on every page, and a deployment meant to show real
numbers (`DASH_ALLOW_SYNTHETIC=FALSE`) refuses to start rather than fall back to
it. A snapshot is one build of each scenario, pinned and swapped whole by the
job (`DEPLOY_DOMINO.md` step 2). A prefix or LOT run id is only ever used as one
path segment, so a run id of `../../PRIVATE` cannot reach a file outside the
snapshot root.

### Settings

Every `DASH_*` variable is read and checked in `config/dashboard_config.R`.

| setting | default | |
|---|---|---|
| `DASH_SOURCE` | `synthetic` | `snapshot`, `warehouse` or `synthetic` |
| `DASH_SNAPSHOT_DIR` | `/mnt/data/NDMM` | the snapshot root |
| `DASH_ALLOW_SYNTHETIC` | `TRUE` | `FALSE` refuses to start on synthetic data |
| `DASH_PREFIXES` | (discover) | the scenario prefixes to offer, `,` or `\|` between. Each must be letters, digits, `.`, `_` or `-`, starting with a letter or digit |
| `DASH_PREFIX_PATTERN` | `^s223926` | warehouse: which discovered prefixes to offer |
| `DASH_CATALOG` | `DATABRICKS_CATALOG`, then `hive_metastore` | warehouse catalog |
| `DASH_WORK_SCHEMA` | `WORK_SCHEMA`, then `PROJECT_WORK_SCHEMA`, then the Domino user's own | warehouse schema, the study run's order; `catalog.schema` accepted |
| `DASH_LOT_PREFIX` | (none) | warehouse: where the LOT build wrote, for the LOT tabs |
| `DASH_SUPPRESS_MIN_N` | `25` | the slider's lowest value; the floor applied is never below the package's 25 |
| `DASH_PREFER_RELEASE` | `TRUE` | read the `_RELEASE` copy where the run released one |
| `DASH_ALLOW_RECOVERABLE` | `FALSE` | show tables the run's own release record refuses (`DEPLOY_DOMINO.md`) |
| `DASH_DEFAULT_COHORT` | `1L` | the cohort the Selection starts at |
| `DASH_MAX_ROWS` | `5000` | the most rows a table on the page prints |
| `DASH_PACKAGE_DIR` | `../variables` (`app.sh`: `variables`) | the study package |
| `DASH_TFLS_DIR` | `../TFLS` | the shells |
| `DASH_TITLE` | `GSK 223926 - NDMM / RRMM explorer` | the page title |
| `DASH_RUN_CMD` | `Rscript build.R` | the command `scenario_command()` writes |
| `SHOW_<PANEL>` | shown | `FALSE` drops a panel; anything other than `TRUE` or `FALSE` stops startup |

---

## Running it

```bash
# a demo with generated data, no warehouse - from this folder
DASH_SOURCE=synthetic Rscript -e "shiny::runApp('.', port = 8888)"

# the normal deployment - app.sh changes to the folder above dashboard/
# itself, so it can be started from anywhere, as a Domino App starts it
DASH_SOURCE=snapshot DASH_SNAPSHOT_DIR=/mnt/data/NDMM ./app.sh
```

`DEPLOY_DOMINO.md` has the Domino Job and App setup.

```bash
Rscript tests/run_tests.R      # no Shiny and no warehouse
```

Every number the app puts on a page comes from a function in `R/` that runs
without Shiny, which is what makes that possible. `app.R` is wiring, and the
last section of the suite reads it as text to hold the wiring to the
registries.

---

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
| a module, a cohort, an open question | the **package** — it appears here on its own |

## The files

| file | what it is |
|---|---|
| `app.R` | the Shiny wiring: the sidebar, the tabs, and which panel goes where |
| `global.R` | loaded once at startup: the package's registries and the hash of the contract they are, then the dashboard's, then the data source |
| `config/dashboard_config.R` | every `DASH_*` environment variable, validated |
| `R/spec.R` | `TABLE_SPEC` — how each table is best shown, and which columns identify a patient |
| `R/panels.R` | the panel registry — what is on each tab |
| `R/scenarios.R` | a scenario from a run's metadata, the settings that differ between two, and the command that would produce one |
| `R/sources.R` | the three data sources, and the run-ownership check every read is bound to |
| `R/prepare.R` | the release check applied to everything drawn |
| `R/tfls.R` | the table shells: loading the engine beside this folder, filling a shell and drawing it |
| `R/aggregate.R` | counts, percentages and distributions over a patient-level table |
| `R/render.R` | the HTML tables, headline counts and charts |
| `R/synthetic.R` | the generated rows behind the demo |
| `jobs/build_scenarios.R`, `jobs/export_lib.R` | the snapshot job |
| `scenarios.csv` | one row per scenario the job builds |
| `app.sh` | the Domino launcher |
| `tests/run_tests.R` | the suite |
