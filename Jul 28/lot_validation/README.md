# LOT validation

Idea 3 from `questions/asked/July 30 2026/LOT New ideas.txt`: a library of
synthetic patient vignettes for the LOT assignments that are hard, each with
what this algorithm does with them.

```
Rscript lot_validation/run_vignettes.R
```

No warehouse, no connection, nothing written to the schema. It resolves the
catalogue against this run's configured parameters and writes a CSV and a
markdown table to `out/`.

## What it is, and what it is not

**It is a specification.** Each vignette says what the rules say, with the rule
quoted. Nothing here has been executed against Databricks, so no line of it is
an observed output.

That distinction is on every row, as `confidence`:

| | |
|---|---|
| `derived` | the outcome follows from the rule quoted beside it — reading the code is enough |
| `to_confirm` | the rules interact and this is our reading of them; the first real run settles it |

`to_confirm` is a claim about **us**, not about the algorithm. Those rows are
the first-run checklist: they are where a careful reader should look before
quoting any of this.

## Why the days are not written down

The days that make a case hard are the configured parameters — 180 for a
tandem, 45 for CAR-T consolidation, 90 for a discontinuation gap. A document
saying "day 181" is wrong the moment one of them moves, and nothing says so.

So every offset is **derived** from the parameter that decides it, and the cases
come in pairs straddling it: one at the last day inside, one at the first day
outside. `check_vignettes()` then holds the catalogue to its own claims:

* the parameter has to exist in the build's config — a renamed setting fails
  rather than leaving prose describing a rule that is gone;
* the pair has to actually straddle the value;
* the two sides have to expect different things, or the boundary is testing
  nothing;
* the timeline has to run forwards;
* the file each rule is quoted from has to be there.

Change `SCT_TANDEM_DAYS` and the vignettes move with it. That is the whole
design; the vignettes themselves are the easy part.

## What is in it

21 vignettes. The cases the ask named — tandem near the boundary, biosimilar
switch mid-line, maintenance into relapse, overlapping oral refills, an
administrative gap, CAR-T bridging inside the 45-day window, allogeneic after a
failed autologous — plus the boundary pairs for every window parameter, and
four cases that are not boundaries but are worth stating:

**`allo_single_day`** — an allogeneic line spans one day and carries **no
regimen string**, because `10_lot2_5_base.R` suppresses induction rows for it.
That is the shape that broke the transition Sankeys, which read a blank regimen
as no line at all.

**`maintenance_to_relapse`** — maintenance is a descriptive flag
(`contains_mtx_reg`) and nothing more. There is no maintenance period and no
maintenance line. This is a deliberate divergence from algorithms that count one,
and it shifts every later line number by one against them.

**`belantamab_any_line`** — the criterion is patient-level, so an affected
patient loses *every* line, not the ones from belantamab onward. It is the one
rule that makes `LOT_LONG` and `LOT_LONG_FINAL` hold different **patients**.

**`line_beyond_max`** — nothing above `MAX_LOT` is built, and a capped patient
looks exactly like a completed one in the output.

## The sensitivity sweep — idea 2(d)

```
# print the plan and its cost; touches nothing, needs no connection
INPUT_COHORT_TABLE=ndmm_NDMM_COHORT Rscript lot_validation/run_sensitivity.R

# actually build them
DATABRICKS_PWD=... INPUT_COHORT_TABLE=ndmm_NDMM_COHORT \
  SENS_EXECUTE=TRUE Rscript lot_validation/run_sensitivity.R
```

**Execution is opt-in, because one cell is one complete LOT build.** There is no
cheaper way: the gap threshold changes how MAPs are formed, which changes the
lines, which changes everything after them — none of it recoverable from an
existing `LOT_LONG` the way `nndm` recomputes its CE alternatives inside one
run. The default prints the grid, the predicted directions and the cell count so
the cost is readable before anyone commits to it.

The grid is **one at a time** from the shipped configuration: six parameters
with two alternatives each is thirteen builds, not the seven hundred and
twenty-nine a cross-product would be.

### The direction is stated before the run

That ordering is the whole value. Thirteen builds produce thirteen different
tables and a reader nods at all of them. Predicting the sign first turns it into
a test — a metric that moves the other way is either a bug or a hole in our
reading, and either is worth knowing.

Predictions carry the same `derived` / `to_confirm` marker as the vignettes,
plus a third value that matters: **`unclear`**, for metrics where two effects
pull against each other. `unclear` is *recorded, never scored*. Marking it as a
hit or a miss would reward whichever guess happened to be written down.

The comparison scores the **sign relative to the parameter's own direction**,
not the size. Fewer lines from a *larger* gap is the prediction; the same number
of lines from a *smaller* gap is the opposite finding, and the harness says so.

### Two of the ask's four axes cannot be swept

**maintenance-as-LOT vs flag** is not a setting. Maintenance is a descriptive
flag (`contains_mtx_reg`) and there is no maintenance period —
`lot/R/steps/05_sct.R:13`. Making it a line would be a different algorithm, not
a sensitivity of this one, so there is nothing here to vary. It is in the
vignette catalogue as the divergence it is.

**CE requirements** are the cohort build's axis. `nndm` already reports them
without rebuilding anything — `NDMM_FU_CE_COUNTS` gives the cohort at 0/30/60/90
days from a single run. Sweeping them here would rebuild the cohort *and* the
LOT per cell.

Both are named in the plan output rather than quietly dropped, since two of four
axes silently missing would read as coverage.

### Guards

A cell writing to the study's own prefix is refused — that would overwrite the
run being measured. So is a grid past `SENS_MAX_CELLS` (24), and two cells
sharing a prefix. Each cell runs as its **own process**, because the build pins a
config and a run id globally and a second build in the same session inherits the
first's. Metrics are read against that cell's own `RUN_ID`, taken from its own
`LOT_BUILD_STATUS`, since `LOT_ATTRITION` is keyed by it.

A sweep leaves a full set of LOT tables per cell. `SENS_DROP_AFTER=TRUE` removes
them once the metrics are read; it is off by default, because dropping tables is
not something a measurement script should do quietly.

## Distribution benchmarks — idea 2(a)-(c)

```
# check the reference file and print what would be measured; no connection
Rscript lot_validation/run_benchmarks.R

# measure this run and compare
DATABRICKS_PWD=... DOMINO_USER_NAME=usr00000 OBJECT_PREFIX=ndmm_ \
  BENCH_EXECUTE=TRUE Rscript lot_validation/run_benchmarks.R
```

**The published numbers are not here and were not written from memory.**
`benchmarks.csv` ships with a row for every metric and `published_value` blank,
so whoever has the literature can see exactly which figures are wanted, and an
unfilled row reports itself as `no reference supplied` rather than passing
silently. A value with no `source` is **refused when the file loads** — that row
would become a citation nobody can chase.

### A benchmark without its definition is not a benchmark

"Median 2 lines" from a paper is not comparable to anything on its own. It
depends on who was counted, how long they were followed, and above all whose
line algorithm was used — a source counting maintenance as a line reports a
larger median than this algorithm can produce, and the gap is the two
definitions rather than a defect in either.

So each row carries `source_population`, `source_followup`, `source_algorithm`,
and the operator's judgement in `comparable`:

| | |
|---|---|
| `yes` | close enough to compare |
| `caveat` | usable, with the difference named in `notes` |
| `no` | recorded for context; scored as nothing |

**An unmarked row defaults to `no`.** Defaulting the other way would let a
convenient number quietly become evidence.

Nothing here is a pass or a fail. A difference between this cohort and a
published one is two studies differing until the `comparable` column says
otherwise.

### Two definitions that decide whether the comparison means anything

**Time to next treatment is a real Kaplan-Meier median**, not the median gap
among patients who reached the next line. That naive figure conditions on the
event — it answers "among those who progressed, how fast" — and comes out far
shorter than any published KM median. The worked example in the tests shows the
size of it: the same five patients give 40 days censored properly and 20 days
with the censored ones dropped. Patients without the next line are censored at
their observation end.

**Line durations exclude lines still open at study end** (`LOT_BASE_END_REASON =
'STUDY_END'`) and count them separately. Folding a censored line in treats it as
a short one and drags the median down. `LOT_BASE_LENGTH` is inclusive —
`datediff + 1` — which is a day per line against a source that is not.

The crude `pct_reaching_line` figures are **not** follow-up adjusted and say so:
a patient with six months of observation had less chance to reach LOT2 than one
with five years. A source reporting a KM estimate is measuring something else.

## What the ask wanted and this does not have

The ask asked for each vignette's assignment under **IMWG rules and ≥2 published
alternative algorithms** as well as ours.

Those columns are not here and were not guessed. Filling them needs the IMWG
consensus and the published algorithms in front of you; writing them from
recollection would produce a comparison table that looks authoritative and cites
nothing. The catalogue is built so those columns can be added beside
`expected` — the vignettes and their timelines are the reusable half — but
somebody with the sources has to add them.

The same limit applies to idea 1 in that file, which is the same comparison at
protocol scale.
