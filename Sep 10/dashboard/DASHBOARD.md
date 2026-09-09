# The dashboard — what it is and what it looks like

An R Shiny app that shows what the study build and the LOT engine produced, and
lets a stakeholder change what they are looking at without anyone re-running
anything.

It is one of three folders delivered together, and they are siblings:

| folder | what it does |
|---|---|
| `dashboard/` | **this folder** — the app |
| `ndmm_study_updated/` | the study cohorts and variables it reads |
| `lot/` | the lines-of-therapy engine behind those |

They have to stay siblings. The app finds the study package at
`../ndmm_study_updated/study223926` and the engine at `../lot/engine`; both can
be overridden with `DASH_PACKAGE_DIR`.

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
| **Patterns** | regimen categories by line; what happened on each line; regimen transitions as a flow |
| **Compare** | one scenario against another, stratum by stratum; and every open question with where it is answered |
| **LOT engine** | the LOT run these lines came from; the LOT funnel; lines by line number; what opened each line; how each line ended |
| **LOT validation** | face-validity checks; the 37 QC checks; build status; before and after the line criteria |

A tab whose module did not run is **reported, not hidden**. "The safety module
did not run" is something a viewer needs to know; a silently absent tab does
not say it.

---

## The controls, and what they can and cannot do

There are two kinds, and confusing them is the one way a dashboard like this
lies.

### Live — answered instantly

**Cohort, line, period, stratum** filter numbers that are already computed.
**Suppress cells below N** raises the suppression threshold, and the control
says beside itself that it can be raised and never lowered.

These need no re-run because nothing has to be re-derived.

### Scenario — needs a run

An open question changes the SQL, so it cannot be applied to a finished table.
`S_SAFETY_RATES` was computed under **one** reading of the washout, and no
filter recovers another.

So the scenario picker lists the runs that **exist**. A scenario nobody has run
does not appear — and the app prints the command that would produce it:

```
export OBJECT_PREFIX='s223926_ms_cal_'
export MONTHS_AS='calendar'
Rscript build.R
```

The settings panel says, for every open question, whether it is applied by this
package or upstream, what this run answered, and that it is **not** a live
control. A switch that quietly did nothing would be worse than no switch.

---

## Compare

The point of the whole thing. Pick a second scenario in **Against**, and every
rate table is shown stratum by stratum: A, B, the difference, and the
percentage change, sorted by how far apart they are.

Before it draws anything it answers one question: **do these two rest on the
same lines?** Two scenarios sharing a LOT run differ only in what the study
package did. Two reading different LOT runs differ in the lines as well, and a
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

A snapshot becomes visible only once everything it holds has been read: tables
are staged and the directory swapped whole, so a refresh that fails leaves the
previous snapshot in place under its own identity rather than mixing the two.

---

## Running it

```bash
# a demo with generated data, no warehouse
DASH_SOURCE=synthetic Rscript -e "shiny::runApp('.', port = 8888)"

# the normal deployment
DASH_SOURCE=snapshot DASH_SNAPSHOT_DIR=/mnt/artifacts/results ./app.sh
```

`DEPLOY_DOMINO.md` has the Domino App setup: which files, which environment
variables, and what the job that refreshes the snapshot needs.

```bash
Rscript tests/run_tests.R      # 319 checks, no Shiny and no warehouse
```

Every number the app puts on a page comes from a function in `R/` that runs
without Shiny, which is what makes that possible. `app.R` is wiring, and the
last section of the suite reads it as text to hold the wiring to the
registries.

---

## What it reads, and what it does not restate

The study package is the authority on what exists: which cohorts, which
modules, which tables, which open questions and what each may be set to. The
dashboard imports those rather than restating them — so a module or a question
added to the package appears here **without an edit**, and a table it does not
know gets a plain grid until someone writes three lines of spec for it.

`README.md` in this folder is the developer's version of this page: the file
layout, the panel registry, and how to add a panel.
