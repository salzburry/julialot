# dashboard

Descriptives and statistics for one cohort, after the cohort build and the LOT
build have run. One self-contained HTML file.

**Reading only.** This package creates no table, writes nothing to the
warehouse and changes no number. It can be re-run against a finished study as
often as anyone wants.

## Run it

```
DATABRICKS_PWD=... Rscript build.R <COHORT_TABLE> <lot_prefix_> [<cohort_prefix_>]
DATABRICKS_PWD=... Rscript build.R NDMM_COHORT ndmm_
```

Or set `INPUT_COHORT_TABLE`, `LOT_PREFIX` and `COHORT_PREFIX`. The cohort prefix
defaults to the LOT prefix — one study, one prefix — and is only needed when the
cohort build wrote under a different one.

Like `lot`, this folder names no cohort of its own. The tables it reads are
built from the prefix you pass.

## What it reads

| placeholder | table | used for |
|---|---|---|
| `{patients}` | `<lot_prefix>LOT_PATIENT_INPUT` | demographics, follow-up — the cohort **as LOT read it** |
| `{lot_long}` | `<lot_prefix>LOT_LONG` | every line the build produced |
| `{lot_final}` | `<lot_prefix>LOT_LONG_FINAL` | after the line criteria |
| `{run_meta}` | `<lot_prefix>LOT_RUN_METADATA` | which window and which code produced the numbers |
| `{attrition}` | `<cohort_prefix>NDMM_ATTRITION` | the cohort funnel |
| `{cohort}` | the table you passed | available to sections that want it |

Only `LOT_LONG` is required. Anything else missing turns its sections into a
panel that says which table is absent — a study that ran LOT but not the cohort
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
`bar` (needs `label` and `n`, sized against the first row) or `sankey` (needs
`source`, `target` and `n`).

## Transitions

One Sankey per consecutive LOT pair — `LOT1 to LOT2`, `LOT2 to LOT3`,
`LOT3 to LOT4` — showing which regimen patients moved to.

`INNER JOIN`, so a patient who never reached the next line is not a flow: the
chart is about what progressors switched to, and carrying non-progressors would
put the biggest ribbon on a transition that never happened. `TOP_N` sources;
targets outside the top N collapse to **`Other`**, which is drawn rather than
dropped and sits at the bottom because it is a bucket, not a regimen.

Drawn as **inline SVG**, not plotly — a handful of bezier paths, no JavaScript
bundle, and it prints, which a canvas chart does not. Every ribbon carries its
count as a hover tooltip, and a one-patient flow is floored at a hairline rather
than rounded to nothing.

Adding `LOT4 to LOT5` is one line: `.transition_section(4, 5)` plus its
`SHOW_LOT4_TO_LOT5` row.

## Patient journeys

`patient_journeys` shows a few patients per scenario, line by line — start,
end, days, what started the line, the regimen, the first drug added, what ended
it. Scenarios are `JOURNEY_CATEGORIES` in `R/sections.R`; add one by adding a
label and a predicate over `max_lot`, `lot1_start_type`, `lot1_end_reason`,
`any_cart_init`, `any_sct_auto`, `any_sct_allo`.

Examples, not a sample: three random patients are three LOT1-only patients,
because most patients are. `JOURNEYS_PER_CATEGORY` (default 3) sets how many
each scenario shows, and patients are taken in `PATID` order — so the same
cohort gives the same examples twice, which is what makes an example something
two people can discuss.

**`PATID` is masked to its last six characters in the SQL**, so the identifier
reaches neither the HTML nor the CSV. No section selects a raw one, and a test
holds that.

`journey_coverage` counts how many patients each scenario has. That is the
panel that tells you whether an empty scenario means "none in this cohort" or
"a rule is not firing".

## CSV export

`EXPORT_CSV` (default `TRUE`) writes one CSV per panel that produced rows, into
`<OUTPUT_DIR>/<CSV_DIR>/<section_name>.csv`. So `patient_journeys.csv`,
`attrition.csv` and so on, alongside the HTML.

The frames come from the panels, not from a second pass at the warehouse — the
CSV is the numbers on the page rather than a re-query that could disagree with
it. Empty and skipped panels write nothing.

## Colours

GSK orange `#F36633` on white. The header band is the orange itself, the page
is white, and the greys are there only to separate things — no third brand
colour.

`PALETTE` at the top of `R/render.R` is the whole scheme. Every CSS rule refers
to a variable, so changing the palette changes the page, and a test asserts no
rule carries a literal hex — which is what stops a hard-coded tint surviving a
swap and looking like a bug in the swap.

Placeholders are filled only from the table above. A section naming anything
else stops the build rather than reaching a name that happened to be in scope.

## Why it draws its own HTML

`apr_30_2026`'s dashboards render through ggplot2, plotly, DT, htmlwidgets,
jsonlite and base64enc, and `build_dashboard()` **no-ops when any is missing** —
logging "skipping" and writing no file. That is the wrong failure for a
deliverable: a run reports complete and produces nothing, which looks the same
as a run nobody wanted a dashboard from.

None of those packages is guaranteed on the Domino image, and a dashboard is
worth less than the tables it describes — not worth making the run depend on
them. So this renders tables, KPI tiles and bars as styled HTML from base R. No
script tag, nothing fetched from the network, opens from a `file://` path on a
machine with nothing installed, and attaches to an email as one file.

## Tests

```
Rscript tests/test_runner.R
```

No warehouse — every query goes through a stub. What is tested is the registry,
the guards, the placeholder filling, that the package cannot write, and that the
HTML escapes values and needs no network.
