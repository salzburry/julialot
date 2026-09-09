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
- **LOT engine** — the lines these numbers rest on: the LOT funnel, lines per
  line number, what opened each line and how each ended.
- **LOT validation** — face validity, the QC checks, the build status, and
  `LOT_LONG` before the line criteria against `LOT_LONG_FINAL` after them.

### The LOT tabs describe the lineage, not the scenario

The LOT tables were written by a **different build**, under its own prefix, and
a study scenario records which run it read in `S_RUN_METADATA.LOT_RUN_ID`.
Several scenarios normally share one run — none of the study's open questions
changes how a line is counted — so two scenarios sharing a LOT run show
identical numbers on these tabs. That is the truth, not a bug.

It matters on **Compare**, which asks the question before drawing anything:

- same LOT run → every difference below is this package's;
- different runs → said loudly, because the lines differ too and a delta
  carries both without being able to separate them;
- one of them naming no run → said, because not knowing is not the same as
  knowing they match.

`LOT_LONG` is only on the validation tab. It is the same table *before* the
line criteria, and a truncate criterion makes the two hold different patients —
so a panel drawn on it describes people the study excluded, with nothing on the
page saying so. The same caution `Jul 28/reporting/FILES.md` gives.

## Adding to it

Three registries, and none of them is in this folder twice.

| to add | edit |
|---|---|
| a panel | one entry in `R/panels.R` |
| a better view of a table | one entry in `TABLE_SPEC`, `R/spec.R` |
| a scenario | one row in `scenarios.csv` |
| a LOT table | one entry in `TABLE_SPEC` with `source = "lot"`, and one in `LOT_DASHBOARD_TABLES` |
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
  normally reads: no warehouse session per viewer. Scenario tables sit under
  `<prefix>/`, and LOT tables under `lot/<LOT_RUN_ID>/` — filed by run, not by
  scenario, so a shared run is exported once rather than copied per scenario.
- **`warehouse`** — the `S_*` tables live, for a session that has a cluster.
  `DASH_LOT_PREFIX` names where the LOT build wrote, since `S_RUN_METADATA`
  records which LOT *run* a scenario read and not where that run wrote.

## Suppression

The package already suppresses into `S_*_RELEASE` at its 25-patient floor, and
the dashboard reads those by default. The slider is a **second** floor on top:
it can be raised and never lowered, because a cell the package withheld arrived
`NULL` and there is nothing under it to reveal. Enforced rather than trusted,
so a mis-set environment variable cannot turn this into a disclosure route.

A withheld row is shaded, not dropped. An absent stratum and a suppressed one
mean different things and only one of them is "we could not say".

Three rules an adversarial pass added, after it got past all three:

- **No per-patient row is ever rendered.** A `subject` table — one row per
  `PATID` — is summarised into counts, percentages and distributions. Five
  panels used to list 1,200 patients each, identifier included.
- **Identifier columns are dropped whatever the shape.** `PATID`,
  `PAT_PLANID`, `CLMID` and the rest never reach the HTML, so a spec that
  forgets to declare one cannot leak it.
- **A table with no declared denominator is still suppressed.** The floor now
  finds a count column when the spec names none, so "a new module appears in
  the dashboard on its own" no longer also means "and skips suppression".

## What it does not do

It **reads**. It creates, replaces and drops nothing, so it can be pointed at a
finished study as often as anyone likes — the same discipline as
`Jul 28/reporting/dashboard`.

Asking for a scenario nobody has run therefore prints the command that would
produce it rather than running it. Running one writes to the warehouse and
belongs to whoever owns the schema.

That block is meant to be pasted into a shell, so every value in it is
shell-quoted: a setting value carrying a newline or a `;` used to put its own
line in it. And a prefix or LOT run id is only ever used as one path segment —
a run id of `../../PRIVATE`, which comes from a metadata table anyone with
warehouse write access controls, read a file outside the snapshot root and
handed it to whoever opened the page.

## Tests

```
Rscript "Jul 28/ndmm_study_updated/dashboard/tests/run_tests.R"
```

No Shiny and no warehouse. Every number the app puts on a page comes from a
function in `R/` that runs without Shiny, which is what makes that possible;
`app.R` is wiring, and the last section reads it as text to hold the wiring to
the registries.

The count is not repeated here. It was, and it drifted from what the suite
actually reports - a number in prose is a second copy of a fact nothing checks.
The suite prints its own total.
