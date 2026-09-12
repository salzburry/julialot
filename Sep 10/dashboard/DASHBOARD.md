# The dashboard — what it is and what it looks like

An R Shiny app that shows what the study build and the LOT engine produced, and
lets a stakeholder change what they are looking at without anyone re-running
anything.

It is one of three sibling folders:

| folder | what it does |
|---|---|
| `dashboard/` | **this folder** — the app |
| `ndmm_study_updated/` | the study cohorts and variables it reads |
| `lot/` | the lines-of-therapy engine behind those |

They have to stay siblings. The app loads the study package's registries from
`../ndmm_study_updated/study223926` (overridable with `DASH_PACKAGE_DIR`). It
does **not** load the engine's code: LOT results reach it as tables — from the
snapshot or the warehouse — and its test suite reads `../lot/engine` only to
hold the two table lists to each other.

---

## The shape of the page

A left sidebar of controls, a row of tabs across the top, and panels stacked
down the page.

The sketch below is the layout, not a result — **the numbers in it are made up**
to show the shape of the page.

```
┌────────────────┬──────────────────────────────────────────────────────────┐
│                │  Overview │ Cohort │ Safety │ HCRU │ Malignancy │ …      │
│  SCENARIO      ├──────────────────────────────────────────────────────────┤
│  ┌──────────┐  │                                                          │
│  │ s223926_ ▾│  │   Cohort sizes                                          │
│  └──────────┘  │   ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐            │
│  study_start   │   │  4,812 │ │  3,104 │ │  1,977 │ │  2,455 │            │
│   = 2018-01-01 │   │ 1L      │ │ 2L      │ │ 3L      │ │ SEC2L   │        │
│                │   └────────┘ └────────┘ └────────┘ └────────┘            │
│  AGAINST       │                                                          │
│  ┌──────────┐  │   Attrition, criterion by criterion                      │
│  │ (none)  ▾│  │   ████████████████████████████  1. indexed               │
│  └──────────┘  │   ██████████████████████████    2. I1 myeloma diagnosis  │
│                │   ████████████████████████      3. I2 age                │
│  COHORT   [all]│   ██████████████████            4. I4 enrolment before    │
│  LINE     [all]│   ████████████████              5. I5 follow-up          │
│  PERIOD   [all]│   ██████████████                6. X1 no prior therapy   │
│                │                                                          │
│  FLOOR    [25] │   What produced these numbers                            │
│                │   ┌──────────────────────────────────────────────┐       │
│  ────────────  │   │ RUN_ID     │ 2026-09-08 14:22 │ LOT run r-91 │       │
│  Source:       │   │ COHORT     │ ndmm_NDMM_COHORT │ attempt 3    │       │
│  snapshot      │   └──────────────────────────────────────────────┘       │
└────────────────┴──────────────────────────────────────────────────────────┘
```

Everything is in the GSK palette — orange for the primary series, slate for
secondary, on an off-white ground.

---

## The tabs

| tab | what is on it |
|---|---|
| **Overview** | what produced these numbers; cohort sizes as headline counts; the attrition funnel, criterion by criterion |
| **Cohort** | baseline demographics; Charlson comorbidity; baseline and follow-up periods |
| **Safety** | key safety events as rates per person-year, as a chart and as a table |
| **HCRU** | hospitalisation, length of stay and ED visits |
| **Malignancy** | secondary malignancies |
| **Outcomes** | TTNT, TTD and overall survival as Kaplan-Meier curves, and the endpoints as a table |
| **Patterns** | regimen categories by line; what happened on each line; regimen transitions as a from → to table |
| **Compare** | one scenario against another, stratum by stratum; and every open question with where it is answered |
| **LOT engine** | the LOT run these lines came from; the LOT funnel; lines by line number; how a line ended against how the next one opened; the commonest line sequences; the regimen of a line against the next; what opened each line; how each line ended |
| **LOT validation** | face-validity checks; the 37 QC checks; build status; before and after the line criteria |

**The line-to-line panels are the ones for checking that the lines make
sense together.** Each pairs a patient's consecutive lines and counts
patients per pair: the reason line n ended against what opened line n+1, the
agents of line n against the agents of line n+1, and each patient's whole
sequence of line openings. A line that ran out of treatment followed by a
transplant-opened line, a CAR-T consolidation end with no CAR-T start behind
it, or a regimen returning in full one line later shows up here and nowhere
else. Picking a line in the sidebar narrows the pairs to those from that line.

Counts are distinct patients. A pair under the floor is not shown on its own,
and neither is any pair whose count could be read off a published total — what
opened line n+1, the pairs from a line, or how line n ended — once the others
are known; those are grouped into one row per line whose count is their sum. So
a line that ended one way 50 times, 49 of them into the same next line, does not
show the 49 beside the 50 that "how each line ended" publishes. Lines that ended
a given way with no line after them are the part of that total the pairs do not
account for, and they count with the hidden pairs: where there are enough of
them the pairs from that end reason have cover, and where there are few or none
pairs are grouped until what is hidden reaches the floor. The grouped row does
not say how many pairs it holds, because with the published totals that number
alone can pick out the one way of filling the hidden cells that fits. Each total
is held on its own, which is the subtraction a reader makes; it is not an audit
of every total taken together. No patient is ever listed: the pairs are
aggregated before anything reaches the page.

A tab whose module did not run is **reported, not hidden**. "The safety module
did not run" is something a viewer needs to know; a silently absent tab does
not say it.

Every number on every tab is read **bound to the build the sidebar describes**
— the run id, and its state and timestamp, since a run id is reused by a
re-run inside one Domino run. The binding is checked around each read, not
once per page: a snapshot rebuilt after the page was opened shows a notice in
place of each panel, the headline counts and the metadata table included,
until the page is reloaded.

A run that is `started` or `failed` is listed, with its settings and the LOT
run it read, and none of its tables is shown: the producer writes the
metadata row before it replaces a table, so under such a run the tables are
the previous build's, or part of this one. Compare needs two complete runs.

And a run shows only what it built. A run writes the modules it selected,
for the cohorts it selected, and leaves everything else under its prefix as
the previous run left it — so a completed partial re-run's prefix can hold a
safety table it never wrote, a 2L partition it never built, or a released
table from before its raw one was rebuilt. None of that is this run's. Every
read is bound to the run's own metadata: a table whose module the run did
not select is not shown, drawn, offered to select on or compared (Compare
says which side lacks it); rows of cohorts the run did not select are left
out; and the released copy of a table is preferred only where the run ran
the release module. The snapshot job applies the same rules, so a snapshot
holds only what its run wrote.

### The LOT tabs describe the lineage, not the scenario

The LOT tables were written by a **different build**, under its own prefix,
and a study scenario records which run it read in `S_RUN_METADATA.LOT_RUN_ID`.
Several scenarios normally share one run — none of the study's open questions
changes how a line is counted — so two scenarios sharing a LOT run show
identical numbers on these tabs. That is the truth, not a bug.

`LOT_LONG` is only on the validation tab. It is the same table *before* the
line criteria, and a truncate criterion makes the two hold different patients
— so a panel drawn on it would describe people the study excluded, with
nothing on the page saying so.

---

## The controls, and what they can and cannot do

There are two kinds, and confusing them is the one way a dashboard like this
lies.

### Live — answered instantly

**Cohort, line and period** — the keys each table declares — filter numbers
that are already computed. There is no free-form stratum control: a table's
other columns are what its panel shows, not something to filter on.
**Suppress cells below N** raises the suppression threshold, and the control
says beside itself that it can be raised and never lowered.

These need no re-run because nothing has to be re-derived.

### Scenario — needs a run

An open question changes the SQL, so it cannot be applied to a finished table.
`S_SAFETY_RATES` was computed under **one** reading of the washout, and no
filter recovers another.

So the scenario picker lists the runs that **exist**. A scenario nobody has run
does not appear. The settings panel says, for every open question, whether it
is applied by this package or upstream, what this run answered, which
environment variable sets it, and that it is **not** a live control. A switch
that quietly did nothing would be worse than no switch.

To produce a scenario, add a row to `scenarios.csv` and run the snapshot job
(below). `R/scenarios.R` also carries `scenario_command()`, which turns a set
of readings into the `export ...; Rscript build.R` lines a build needs; it is
tested and not wired to the page.

---

## Compare

The point of the whole thing. Pick a second scenario in **Against**, and every
rate table is shown stratum by stratum: A, B, the difference, and the
percentage change, sorted by how far apart they are.

Before it draws anything it answers one question: **do these two rest on the
same lines?** Two scenarios sharing a LOT run — the same run *and the same
build of it* — differ only in what the study package did. Two reading
different runs, or two builds of one run, differ in the lines as well, and a
difference between them carries both without saying so — so the panel says
which case it is, in a banner, above the numbers.

---

## Suppression

Two layers, and the app can only ever hide **more** than the build did.

1. The study package suppressed every cell under **25 patients** into its
   `S_*_RELEASE` tables before the dashboard saw anything.
2. The app applies the viewer's floor on top. Raising it hides more. Lowering
   it below 25 reveals nothing, because those cells arrived empty — and the app
   enforces that rather than trusting it.

The rule is applied **after aggregation, on the thing being drawn** — headline
counts, tables, charts, survival curves, captions and comparisons all go
through one release check. A withheld cell reads as withheld, never as a zero.

A patient-level table is **never** rendered as a grid. It is summarised —
counts and percentages per level, mean and median for continuous columns — and
every identifier column is dropped whatever the spec says. Where one level of a
variable is withheld, a second goes with it, because otherwise the hidden one
is the difference between the total and the rest.

A table with no declared denominator is still suppressed: the floor finds a
count column when the spec names none, so a module that appears in the
dashboard on its own does not also skip suppression.

---

## Where the numbers come from

Three sources, chosen with `DASH_SOURCE`:

| source | reads | for |
|---|---|---|
| `snapshot` | CSVs written by `jobs/build_scenarios.R` | **the normal deployment.** No warehouse session per viewer |
| `warehouse` | the tables directly | a live check |
| `synthetic` | rows generated in-process | a demo with no data behind it, and the default for the tests |

A synthetic run says so on every page. It cannot be mistaken for real numbers,
and a deployment meant to show real ones refuses to fall back to it.

### The snapshot job

`jobs/build_scenarios.R` runs the study package once per row of
`scenarios.csv`, then exports what each run wrote as CSV. Each row is one
scenario: `prefix` is what it writes under, and every upper-case column is a
setting for that run and nothing else. **Adding a scenario is adding a row.**

A snapshot is one **build**, not a directory that happens to hold one. The job
pins the run's newest metadata row before it reads a table — and only a
`complete` one — reads every table against that pin, and reads the row again
after the last table; a rebuild landing in between stops the export rather
than publishing one build's metadata beside another's rows. Then the tables
are staged and the directory swapped whole, so a refresh that fails leaves the
previous snapshot in place under its own identity.

LOT tables are filed under `lot/<LOT_RUN_ID>.<build>/`, by run **and** by
build, because the engine keeps a run id for the life of a session and can
build it more than once: the study run records which build it read
(`S_RUN_METADATA.LOT_RUN_VERSION`, the stamp of the status row it vouched
for), the job copies the LOT prefix only while its newest status row is that
build, and each scenario reads the directory of the build it read. A build
already exported by an earlier scenario is reused, never rewritten.

---

## Running it

```bash
# a demo with generated data, no warehouse - from this folder
DASH_SOURCE=synthetic Rscript -e "shiny::runApp('.', port = 8888)"

# the normal deployment - app.sh can be started from anywhere: it changes to
# the folder above dashboard/ itself, which is how a Domino App launches it
# (DEPLOY_DOMINO.md)
DASH_SOURCE=snapshot DASH_SNAPSHOT_DIR=/mnt/data/NDMM ./app.sh
```

`DEPLOY_DOMINO.md` has the Domino App setup: which files, which environment
variables, and what the job that refreshes the snapshot needs.

```bash
Rscript tests/run_tests.R      # 446 checks, no Shiny and no warehouse
```

Every number the app puts on a page comes from a function in `R/` that runs
without Shiny, which is what makes that possible. `app.R` is wiring, and the
last section of the suite reads it as text to hold the wiring to the
registries.

---

## Adding to it

Three registries, and none of them is in this folder twice.

| to add | edit |
|---|---|
| a panel | one entry in `R/panels.R` |
| a better view of a table | one entry in `TABLE_SPEC`, `R/spec.R` |
| a scenario | one row in `scenarios.csv` |
| a LOT table | one entry in `TABLE_SPEC` with `source = "lot"`, and one in `LOT_DASHBOARD_TABLES` |
| a module, a cohort, an open question | the **package** — it appears here on its own |

`SHOW_<PANEL>=FALSE` drops a panel. Anything other than `TRUE` or `FALSE`
stops startup — a panel dropped by a typo is invisible on the page, and a halt
is easier to notice than a gap.

---

## What it does not do

It **reads**. It creates, replaces and drops nothing, so it can be pointed at
a finished study as often as anyone likes.

It therefore cannot produce a scenario. One nobody has run does not appear in
the picker, and running one writes to the warehouse and belongs to whoever
owns the schema. `scenario_command()` in `R/scenarios.R` turns a set of
readings into the shell lines such a run needs; it is a helper for that
person, tested and not wired to the page. Its output is meant to be pasted
into a shell, so every value in it is shell-quoted.

A prefix or LOT run id is only ever used as one path segment — a run id of
`../../PRIVATE`, which comes from a metadata table anyone with warehouse write
access controls, cannot reach a file outside the snapshot root.

---

## What it reads, and what it does not restate

The study package is the authority on what exists: which cohorts, which
modules, which tables, which open questions and what each may be set to. The
dashboard imports those rather than restating them. A new open question appears
in the settings panel and the scenario labels without an edit. A new **table**
is known to the dashboard without an edit, but is only *shown* once a panel in
`R/panels.R` points at it — the panel list is deliberately fixed, so a page
cannot grow a tab nobody designed. A table with no spec gets a plain grid.

| file | what it is |
|---|---|
| `app.R` | the Shiny wiring: the sidebar, the tabs, and which panel goes where |
| `global.R` | loaded once at startup: the package's registries, then the dashboard's, then the data source |
| `config/dashboard_config.R` | every `DASH_*` environment variable, validated |
| `R/spec.R` | `TABLE_SPEC` — how each table is best shown, and which columns identify a patient |
| `R/panels.R` | the panel registry — what is on each tab |
| `R/scenarios.R` | a scenario from a run's metadata, the settings that differ between two, and the command that would produce one |
| `R/sources.R` | the three data sources, and the run-ownership check every read is bound to |
| `R/prepare.R` | the release check applied to everything drawn |
| `R/aggregate.R` | counts, percentages and distributions over a patient-level table |
| `R/render.R` | the HTML tables, headline counts and charts |
| `R/synthetic.R` | the generated rows behind the demo |
| `jobs/build_scenarios.R`, `jobs/export_lib.R` | the snapshot job |
| `scenarios.csv` | one row per scenario the job builds |
| `app.sh` | the Domino launcher |
| `tests/run_tests.R` | the suite |
