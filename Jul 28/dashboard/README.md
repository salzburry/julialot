# dashboard

Descriptives and statistics for one cohort, after the cohort build and the LOT
build have run. One self-contained HTML file.

Reading only. This package creates no table, writes nothing to the
warehouse and changes no number. It can be re-run against a finished study as
often as anyone wants.

## Run it

```
DATABRICKS_PWD=... Rscript build.R <COHORT_TABLE> <lot_prefix_> [<cohort_prefix_>]
DATABRICKS_PWD=... Rscript build.R ndmm_NDMM_COHORT ndmm_
```

Or set `INPUT_COHORT_TABLE`, `LOT_PREFIX` and `COHORT_PREFIX`. The cohort prefix
defaults to the LOT prefix - one study, one prefix - and is only needed when the
cohort build wrote under a different one.

The cohort table is named with its prefix, as `lot` and `outcomes` name it.
The LOT prefix applies to the LOT tables listed below and not to the cohort,
which is read exactly as given.

Like `lot`, this folder names no cohort of its own. The tables it reads are
built from the prefix you pass.

## What it reads

| placeholder | table | used for |
|---|---|---|
| `{lot_final}` | `<lot_prefix>LOT_LONG_FINAL` | every clinical panel - this is the study population, and the run stops without it |
| `{lot_long}` | `<lot_prefix>LOT_LONG` | the Validation tab only, where the before/after comparison is the point |
| `{patients}` | `<lot_prefix>LOT_PATIENT_INPUT` | demographics and follow-up, restricted to PATIDs still in `{lot_final}` |
| `{run_meta}` | `<lot_prefix>LOT_RUN_METADATA` | which window and which code produced the numbers |
| `{build_st}` | `<lot_prefix>LOT_BUILD_STATUS` | which run wrote the tables above - read before any panel, never by one |
| `{attrition}` | `<cohort_prefix><ATTRITION_TABLE>` | the cohort funnel |
| `{lot_attrition}` | `<lot_prefix>LOT_ATTRITION` | the LOT funnel, which starts where that one ends |
| `{cohort}` | the table you passed | available to sections that want it |

### Two funnels, two panels

`{attrition}` counts patients into the cohort. `{lot_attrition}` counts
what happened to them afterwards. They get their own panels rather than one
chart running from the end of the first into the second, which would read as
a single narrowing when the populations and the reasons are different.

The LOT funnel's `KIND` splits it again. `input` / `reconciliation` /
`criterion` / `final` are the funnel; `progression` - reached LOT1, LOT2, and
on - is a separate panel, because nobody was removed there: a patient with no
LOT3 did not progress, or their follow-up ended.

A bar has no `KIND` column, so the funnel panel puts it in the label:
`[check]` for the reconciliation rows, `[removed]` for the criteria. Two of
those rows are not attrition - for a treatment-indexed cohort such as NDMM they
re-derive a fact the cohort build already established, so a drop is the two
scans disagreeing rather than patients the study lost. Under a heading saying
"attrition", with nothing on the chart to tell them apart, a drop there reads as
expected loss: the exact misreading the LOT build was changed to prevent,
reintroduced one layer up.

Each panel's percentages are of its own first row, which is what
`pct = "first"` over `ORDER BY STEP_NUM` gives: the funnel's base is the
cohort handed to LOT, and progression's base is LOT1, so the second panel
reads as line-to-line retention without a second render mode.

A bar carries one number, so `N_LINES` and `PCT_OF_PREV` - a criterion's own
cost, and the share of one line's patients going on to the next - get a table
beneath them.

Every LOT panel is scoped to `RUN_ID = {owner_run}`. Rows belonging to an
older LOT run under this prefix skip the panels with a note naming the run,
rather than drawing an empty chart or putting one run's funnel above another
run's numbers. Unlike the cohort funnel this needs no stamp check: the rows
are the LOT run's own, `clear_run_rows()` clears them before the build, and
`resolve_owner_run()` has already refused a latest run that did not finish.

Switches: `SHOW_LOT_ATTRITION`, `SHOW_LOT_PROGRESSION`,
`SHOW_LOT_ATTRITION_DETAIL`.

### The attrition table belongs to the cohort build - name and shape

`ndmm` calls it `NDMM_ATTRITION`. A different cohort build calls it something
else, or writes none - so the name is `ATTRITION_TABLE` in `config.csv` rather
than a constant in a package that is meant to name no study of its own. The
name is validated the same way `INPUT_COHORT_TABLE` is (a bare table name, no
schema), because it reaches a query the same way.

A configurable name is only half of it. The two cohort builds in this folder do
not agree on a shape:

| build | table | columns |
|---|---|---|
| `ndmm` | `NDMM_ATTRITION` | `RUN_ID`, `STEP_NUM`, `CRITERION`, `N_PATIENTS`, `PCT_OF_START`, `RECORDED_AT` |
| `overall` | `<prefix>attrition_report` | `row_order`, `run_id`, `final_table_name`, `created_at`, `step_id`, `description`, `n_30`, `n_60`, `n_90` |

One fixed query against the `ndmm` columns fails outright on an `overall`-built
cohort - the panel becomes a query-failed notice while the rest of the page
renders, which reads as "this study has no funnel" rather than "this dashboard
cannot read this funnel". So `ATTRITION_LAYOUTS` in `sections.R` holds one spec
per shape, and the layout is detected - `DESCRIBE` the table, match its
columns - rather than being a second setting that can disagree with the
warehouse. A shape matching neither skips that one panel and prints the columns
it actually found. Adding a third cohort build means adding an entry.

`overall` carries all three outpatient-window counts side by side and records
nowhere which one the build was configured with. Only that column describes the
cohort that was written; the other two are sensitivity, with no table behind
them. `ATTRITION_WINDOW` (30/60/90, default 90) names it and the panel label
repeats it - `overall`'s own printer stars the built column and warns against
reading the row left to right, and picking one here silently would be the same
mistake in a different medium.

The `ndmm` table is history - the build deletes and re-inserts only its own
`RUN_ID`, so previous runs stay - and its query takes the latest by
`RECORDED_AT`. Without that a reused prefix returns several funnels interleaved
by `STEP_NUM`, with the bar taking its denominator from whichever row came back
first. `overall` writes `CREATE OR REPLACE`, so its table holds one run and
needs no such filter. Each layout says which it is.

### Which LOT run these tables came from

Not "the latest metadata row", and not "the latest completed metadata row"
either. LOT writes `LOT_LONG_FINAL` with `CREATE OR REPLACE` in the
line-criteria phase and validates it afterwards, then records the counts, then
marks the build complete. So a rerun that replaced the table and then died
leaves its table on disk with an incomplete metadata row - filtered out by
any completeness test - while the previous run's complete row is still the
newest one that passes. The page would carry the failed run's numbers under the
successful run's provenance, which is worse than either alone.

`LOT_BUILD_STATUS` settles it: one row per run, `STATE` written `complete` after
every other write in the build, so the latest row on the prefix is the run
that last wrote these tables - whatever state it reached. `resolve_owner_run()`
reads it before any panel runs and:

* latest row is `complete` -> that run owns the tables; provenance is its row,
  selected by `RUN_ID` with nothing left to sort or choose between;
* latest row is anything else -> the run stops, because the table on disk may
  be that run's, built and unvalidated, and nothing here can tell those numbers
  from good ones. `DASH_IGNORE_BUILD_STATE=TRUE` overrides it for an operator
  who knows the run failed before it wrote anything;
* `complete` but with no completed metadata row -> stops. Those two are written
  seconds apart at the end of the same build, so disagreeing means one has been
  edited or partly restored;
* no `LOT_BUILD_STATUS` at all (a study built by an older `lot`) -> falls back
  to the newest row with `N_LOT_FINAL_ROWS IS NOT NULL`, which is `lot`'s own
  completeness predicate. The log says this is the weaker claim: it establishes
  that a run finished, not that it wrote these tables.

### What is not established: cohort <-> LOT alignment

Nothing keys a cohort run to a LOT run. They share a prefix, not a run id, and
neither table records the other's - so a cohort rebuilt after LOT ran, with LOT
not re-run, leaves the newest funnel describing a cohort the clinical panels
were not built from.

The dashboard cannot close that; it can only detect one direction of it. A
funnel recorded after the owning LOT run's timestamp cannot be the funnel of
the cohort LOT read, and the panel label says so when it happens. A funnel
recorded earlier is not thereby proved to be the right one - it is a detector,
not a link. Closing it properly needs the cohort build to stamp a run id that
`lot` captures, which is a change to those two packages rather than to this one.

### Which population a panel describes

`LOT_LONG_FINAL`, everywhere it is a study number. `LOT_LONG` is the same table
before the line criteria, and with a patient-level `truncate` criterion such
as `no_belantamab` the two hold different patients, not merely different
lines. A panel drawn on `LOT_LONG` therefore describes people the study
excluded, with nothing on the page saying so - so only `criteria_impact` and
`line_integrity` read it, on the Validation tab.

`LOT_PATIENT_INPUT` is the cohort LOT was handed, so the cohort panels
restrict to `PATID IN (SELECT DISTINCT PATID FROM {lot_final})`. A test asserts
both rules, and that every section's `needs` names the tables its SQL reads.

The attrition panel is the cohort build's funnel, read rather than
recomputed, and its label says only that. Where it ends is that build's
business: `ndmm` stops before the LOT-side belantamab criterion, another cohort
build stops somewhere else, and nothing in the warehouse keys a cohort run to a
LOT run - the two tables share a prefix, not a run id. A label naming one
build's criteria would be false on every other cohort, and there is nothing this
package could read to make it true. `criteria_impact` on the Validation tab
shows what the LOT-side criteria removed, which is a number this package can
stand behind.

`LOT_LONG_FINAL` is required - it is the study population and every clinical
panel reads it. It is also written last, in the line-criteria phase, so a LOT
run that failed in between leaves `LOT_LONG` behind and no final table; the
dashboard stops rather than producing a file that looks finished with nearly
every panel saying "not shown". Anything else missing turns its sections into a
panel that says which table is absent - a study that ran LOT but not the cohort
build still gets a dashboard, minus the funnel.

## What it shows, and changing it

`R/sections.R` is the dashboard. Each panel is one entry:

```r
list(name  = "line_length", tab = "Lines",
     label = "Line length in days",
     needs = "lot_long", render = "table",
     sql   = "SELECT LOT_NUM AS `Line`, ... FROM {lot_long} GROUP BY 1")
```

Add a panel by adding an entry and a `SHOW_LINE_LENGTH` row in `config.csv`.
Remove one by deleting the entry, or set its switch `FALSE` to keep it in the
file but off the page. A switch that is neither `TRUE` nor `FALSE` stops the
build: a dashboard renders happily with a panel missing, and nobody can see the
gap from the output.

`render` is one of `table`, `kpi` (one row of big numbers, one tile per column),
`bar` (needs `label` and `n`) or `sankey` (needs `source`, `target` and `n`).

A `bar` must also declare `pct` - what the percentage beside each bar is a
percentage of. There is no answer right for every chart:

| `pct` | meaning | used by |
|---|---|---|
| `first` | of the first bar | the attrition funnel, where row one is the denominator |
| `total` | of all bars | a partition - index year, highest line reached |
| `none` | no percentage | overlapping or merely ranked categories - journey coverage |

Assuming one is how a number comes to mean something nobody intended: a share
of the first bar, on a chart whose first bar is simply the largest category, is
arithmetic without a claim behind it. `validate_sections()` refuses a bar that
declares no `pct`.

## Transitions

One Sankey per consecutive LOT pair - `LOT1 to LOT2`, `LOT2 to LOT3`, and on to
`MAX_LOT`. Generated by `.transition_sections()` from that setting rather than
written out per pair: pinned to five, a run that built six would lose LOT5->LOT6
with nothing saying so, and one that built three would draw two empty panels.

`MAX_LOT` here is a second copy of the LOT build's setting, so
`check_max_lot()` compares it with that run's own - the LOT build records its
contract in `LOT_RUN_METADATA`, `max_lot` included, so the setting is checked
against the setting. A disagreement is a warning: a run configured to LOT6
while this says 5 leaves LOT5->LOT6 in the tables and on no panel, which is a
missing answer nobody can see is missing.

How far patients got is a different question, and not a problem. If nobody
reaches LOT5, the LOT4->LOT5 panel showing every patient flowing into `No LOT5`
is the finding - lowering `MAX_LOT` to match would delete the panel carrying
it. Reading the observed maximum as the configured one would have advised
exactly that, so only a run with no recorded contract falls back to
`max(LOT_NUM)`, and then only warns in the direction that loses a panel.

Nothing here stops the run.

Every `LOT{a}` patient is in the chart, including those who never reached
`LOT{b}` - they flow to a terminal `No LOT{b}` node. So the ribbons leaving a
regimen add up to that regimen's `LOT{a}` patients, and the panel shows the one
thing a reader looks at a transition for: how many went on at all. An `INNER
JOIN` here would make those patients vanish.

Two more things are needed before that claim holds.

A line decides whether the patient got there, not a regimen string. An
`SCT_ALLO` line carries no regimen at all - `10_lot2_5_base.R` suppresses the
induction rows for it, because an allogeneic singleton LOT contains no MM
therapy - so filtering on a non-blank `LOT_BASE_MEDS` threw those lines away and
the patient read as `No LOT{b}` when they had reached `LOT{b}`. As the source
line it removed them from the chart entirely. That is worse than the old inner
join: it invents attrition rather than omitting it. A blank regimen is now
labelled by what started the line - `SCT_ALLO (no regimen)`.

Sources outside `TOP_N` become an `Other` source rather than being dropped.
Filtering them out would make "every patient" false while the panel said it.

Targets outside the top N collapse to `Other` too, drawn rather than dropped
and sitting at the bottom because it is a bucket, not a regimen. The stopped
node is ranked out of that - on a cohort with many distinct regimens the
largest single answer is usually "stopped", and ranking it with the regimens
would fold it into `Other`.

Drawn as inline SVG, not plotly - a handful of bezier paths, no JavaScript
bundle, and it prints, which a canvas chart does not. Every ribbon carries its
count as a hover tooltip, and a one-patient flow is floored at a hairline rather
than rounded to nothing.

Raising `MAX_LOT` adds the panel automatically; only its `SHOW_LOT5_TO_LOT6`
row has to be added to `config.csv` if you want to be able to switch it off.

## Patient journeys

`patient_journeys` shows a few patients per scenario, line by line - start,
end, days, what started the line, the regimen, the first drug added, what ended
it. Scenarios are `JOURNEY_CATEGORIES` in `R/sections.R`; add one by adding a
label and a predicate over `max_lot`, `lot1_start_type`, `lot1_end_reason`,
`any_cart`, `any_sct_auto`, `any_sct_allo`.

`any_cart` is the CAR-T line - `LOT_CART_LOT_FLG`, `LOT_START_TYPE = 'CART'`
or a prior line ending on `CART_INIT`. Keying on `CART_INIT` alone missed a
patient whose LOT1 is the CAR-T, because there is no preceding line to carry
that end reason, and the transplant panel counted them while the examples did
not.

Examples, not a sample: three random patients are three LOT1-only patients,
because most patients are. `JOURNEYS_PER_CATEGORY` (default 3) sets how many
each scenario shows, and patients are taken in `PATID` order - so the same
cohort gives the same examples twice, which is what makes an example something
two people can discuss.

`PATID` is masked to its last six characters in the SQL, so the identifier
reaches neither the HTML nor the CSV. No section selects a raw one, and a test
holds that.

`journey_coverage` counts how many patients each scenario has. That is the
panel that tells you whether an empty scenario means "none in this cohort" or
"a rule is not firing".

## CSV export

`EXPORT_CSV` (default `TRUE`) writes one CSV per panel that produced rows, into
`<OUTPUT_DIR>/<CSV_DIR>/<section_name>.csv`. So `patient_journeys.csv`,
`attrition.csv` and so on, alongside the HTML.

The folder is one run, including when `EXPORT_CSV=FALSE` - the folder is
cleared either way. A panel switched off, a query that failed, a panel that came
back empty, the same `OUTPUT_DIR` reused for another cohort, or the export
turned off entirely would otherwise leave a file that reads as current, since
the names carry no cohort, prefix or run id. Nothing but `.csv` in that folder
is touched.

The frames come from the panels, not from a second pass at the warehouse - the
CSV is the numbers on the page rather than a re-query that could disagree with
it. Empty and skipped panels write nothing.

## Colours

GSK orange `#F36633` on white. The header band is the orange itself, the page
is white, and the greys are there only to separate things - no third brand
colour.

`PALETTE` at the top of `R/render.R` is the whole scheme. Every CSS rule refers
to a variable, so changing the palette changes the page, and a test asserts no
rule carries a literal hex - which is what stops a hard-coded tint surviving a
swap and looking like a bug in the swap.

Placeholders are filled only from the table above. A section naming anything
else stops the build rather than reaching a name that happened to be in scope.

## Why it draws its own HTML

A dashboard built on ggplot2, plotly, DT, htmlwidgets, jsonlite and base64enc
no-ops when any of them is missing - logging "skipping" and writing no file.
That is the wrong failure for a deliverable: a run reports complete and
produces nothing, which looks the same as a run nobody wanted a dashboard from.

None of those packages is guaranteed on the Domino image, and a dashboard is
worth less than the tables it describes - not worth making the run depend on
them. So this renders tables, KPI tiles and bars as styled HTML from base R. No
script tag, nothing fetched from the network, opens from a `file://` path on a
machine with nothing installed, and attaches to an email as one file.

## Tests

```
Rscript tests/test_runner.R
```

No warehouse - every query goes through a stub. What is tested is the registry,
the guards, the placeholder filling, that the package cannot write, and that the
HTML escapes values and needs no network.
