# Scenario explorer — GSK 223926

A Shiny dashboard over the updated study's own outputs, so a stakeholder can
change what is undecided and see what it costs.

```
shiny::runApp("Jul 28/ndmm_study_updated/dashboard")   # synthetic, no warehouse
```

## The idea: a scenario is a run

The study has twenty-nine open questions, and fifteen of them change this
package's SQL. `S_SAFETY_RATES` was computed under **one** reading of the acute
washout; no filter over a finished table recovers another. A dashboard that
offered a dropdown for it would be lying.

So the dashboard separates two kinds of control, and says which is which:

| | what it is | how it is answered |
|---|---|---|
| **Selection** | cohort, line, period, stratum, the suppression floor | instantly, on numbers already computed |
| **Scenario** | an open question — the washout, the hospitalisation route, denied claims | by reading a **different run** |

A scenario is an `OBJECT_PREFIX` and the `S_RUN_METADATA` row the run wrote.
The package already does all of it: every table carries the run's prefix, and
every run records its answer to each open question. Two runs under two prefixes
**are** two scenarios. Nothing was added to the package for this.

## Layout

- **Sidebar** — the scenario, the settings that make it different from the
  others, the selection controls (built from the keys the scenario's own tables
  carry), the suppression floor, and a second scenario to compare against.
- **Overview** — what produced these numbers, cohort sizes, the attrition
  funnel criterion by criterion.
- **Cohort** — demographics, Charlson, baseline and follow-up.
- **Safety / HCRU / Malignancy** — rates per 1,000 person-years, as charts and
  as tables.
- **Outcomes** — TTNT, TTD and OS as Kaplan–Meier curves.
- **Patterns** — regimen categories by line, what happened on each line,
  transitions.
- **Compare** — two runs side by side: the settings that differ, then every
  measure under both with the difference. This is the tab the dashboard exists
  for.

## Adding to it

Three registries, and none of them is in this folder twice.

| to add | edit |
|---|---|
| a panel | one entry in `R/panels.R` |
| a better view of a table | one entry in `TABLE_SPEC`, `R/spec.R` |
| a scenario | one row in `scenarios.csv` |
| a module, a cohort, an open question | the **package** — it appears here on its own |

A table the package writes that nothing here declares is still shown, as a
grid, with its keys found from its columns. So a module added to
`study223926/R/registry.R` is visible in the dashboard immediately, and gets a
chart when someone writes three lines in `R/spec.R`.

`SHOW_<PANEL>=FALSE` drops a panel. Anything other than `TRUE` or `FALSE` stops
startup — a panel dropped by a typo is invisible on the page, and a halt is
easier to notice than a gap.

## Where the numbers come from

`DASH_SOURCE` picks one:

- **`synthetic`** (default) — generated in-process. No warehouse, no files, so
  a first deploy comes up and can be clicked through before any run exists.
  Every page says so. `DASH_ALLOW_SYNTHETIC=FALSE` refuses to start on it.
- **`snapshot`** — CSVs `jobs/build_scenarios.R` exported. What a deployed App
  normally reads: no warehouse session per viewer.
- **`warehouse`** — the `S_*` tables live, for a session that has a cluster.

## Suppression

The package already suppresses into `S_*_RELEASE` at its 25-patient floor, and
the dashboard reads those by default. The slider is a **second** floor on top:
it can be raised and never lowered, because a cell the package withheld arrived
`NULL` and there is nothing under it to reveal. Enforced rather than trusted,
so a mis-set environment variable cannot turn this into a disclosure route.

A withheld row is shaded, not dropped. An absent stratum and a suppressed one
mean different things and only one of them is "we could not say".

## What it does not do

It **reads**. It creates, replaces and drops nothing, so it can be pointed at a
finished study as often as anyone likes — the same discipline as
`Jul 28/reporting/dashboard`.

Asking for a scenario nobody has run therefore prints the command that would
produce it rather than running it. Running one writes to the warehouse and
belongs to whoever owns the schema.

## Tests

```
Rscript "Jul 28/ndmm_study_updated/dashboard/tests/run_tests.R"
```

89 checks, no Shiny and no warehouse. Every number the app puts on a page comes
from a function in `R/` that runs without Shiny, which is what makes that
possible; `app.R` is wiring, and the last section reads it as text to hold the
wiring to the registries.
