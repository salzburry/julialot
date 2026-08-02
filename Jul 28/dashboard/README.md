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
| `{lot_final}` | `<lot_prefix>LOT_LONG_FINAL` | **every clinical panel** — this is the study population |
| `{lot_long}` | `<lot_prefix>LOT_LONG` | the Validation tab only, where the before/after comparison is the point |
| `{patients}` | `<lot_prefix>LOT_PATIENT_INPUT` | demographics and follow-up, **restricted to PATIDs still in `{lot_final}`** |
| `{run_meta}` | `<lot_prefix>LOT_RUN_METADATA` | which window and which code produced the numbers |
| `{attrition}` | `<cohort_prefix>NDMM_ATTRITION` | the cohort funnel |
| `{cohort}` | the table you passed | available to sections that want it |

### Which population a panel describes

`LOT_LONG_FINAL`, everywhere it is a study number. `LOT_LONG` is the same table
*before* the line criteria, and with a patient-level `truncate` criterion such
as `no_belantamab` the two hold **different patients**, not merely different
lines. A panel drawn on `LOT_LONG` therefore describes people the study
excluded, with nothing on the page saying so — so only `criteria_impact` and
`line_integrity` read it, on the Validation tab.

`LOT_PATIENT_INPUT` is the cohort LOT was *handed*, so the cohort panels
restrict to `PATID IN (SELECT DISTINCT PATID FROM {lot_final})`. A test asserts
both rules, and that every section's `needs` names the tables its SQL reads.

The NDMM attrition panel is the cohort build's funnel and **ends before** the
LOT-side belantamab criterion — its label says so, and `criteria_impact` on the
same tab shows what that criterion removed.

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
`bar` (needs `label` and `n`) or `sankey` (needs `source`, `target` and `n`).

A `bar` must also declare `pct` — what the percentage beside each bar is a
percentage **of**. There is no answer right for every chart:

| `pct` | meaning | used by |
|---|---|---|
| `first` | of the first bar | the attrition funnel, where row one *is* the denominator |
| `total` | of all bars | a partition — index year, highest line reached |
| `none` | no percentage | overlapping or merely ranked categories — journey coverage |

Assuming one is how a number comes to mean something nobody intended: a share
of the first bar, on a chart whose first bar is simply the largest category, is
arithmetic without a claim behind it. `validate_sections()` refuses a bar that
declares no `pct`.

## Transitions

One Sankey per consecutive LOT pair — `LOT1 to LOT2` through `LOT4 to LOT5`,
which is every pair the build produces at `MAX_LOT=5` — showing which regimen
patients moved to.

`INNER JOIN`, so a patient who never reached the next line is not a flow: the
chart is about what progressors switched to, and carrying non-progressors would
put the biggest ribbon on a transition that never happened. `TOP_N` sources;
targets outside the top N collapse to **`Other`**, which is drawn rather than
dropped and sits at the bottom because it is a bucket, not a regimen.

Drawn as **inline SVG**, not plotly — a handful of bezier paths, no JavaScript
bundle, and it prints, which a canvas chart does not. Every ribbon carries its
count as a hover tooltip, and a one-patient flow is floored at a hairline rather
than rounded to nothing.

Raising `MAX_LOT` means one more line: `.transition_section(5, 6)` plus its
`SHOW_LOT5_TO_LOT6` row.

## Patient journeys

`patient_journeys` shows a few patients per scenario, line by line — start,
end, days, what started the line, the regimen, the first drug added, what ended
it. Scenarios are `JOURNEY_CATEGORIES` in `R/sections.R`; add one by adding a
label and a predicate over `max_lot`, `lot1_start_type`, `lot1_end_reason`,
`any_cart`, `any_sct_auto`, `any_sct_allo`.

`any_cart` is the CAR-T **line** — `LOT_CART_LOT_FLG`, `LOT_START_TYPE = 'CART'`
or a prior line ending on `CART_INIT`. Keying on `CART_INIT` alone missed a
patient whose LOT1 *is* the CAR-T, because there is no preceding line to carry
that end reason, and the transplant panel counted them while the examples did
not.

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

**The folder is one run.** Existing `.csv` files there are cleared first — a
panel switched off, a query that failed, a panel that came back empty, or the
same `OUTPUT_DIR` reused for another cohort would otherwise leave a file that
reads as current, since the names carry no cohort, prefix or run id. Nothing but
`.csv` in that folder is touched.

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
