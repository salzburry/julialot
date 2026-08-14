# LOT validation

Four validation asks against the LOT algorithm, plus one study-team rule
proposal, each taken as far as this folder can take it.

Where each one stands. None of it has executed against a warehouse, so
nothing here is an observed output.

| | |
|---|---|
| Edge-case vignettes | complete as documentation. 21 cases with what the rules say, derived from this run's parameters. It is a specification, not a run. |
| Sensitivity sweep | harness complete, unrun. Fourteen builds' worth of warehouse, opt-in, with the directions predicted first. Every cell is an explicit non-contract build, marked as one in the warehouse. |
| Distribution benchmarks | harness complete, pending sources. Every measurement is written and checked; `benchmarks.csv` ships with `published_value` blank, because the published figures are not this folder's to write. |
| Definition comparison | our column complete, theirs pending sources. The consensus paper and the trial protocols are not in this folder, and nothing here stands in for them. |
| Melphalan rule | complete as a measurement, unrun. A proposed line-advancing rule, counted against a finished run. It changes nothing in `lot` and rebuilds nothing. |

Two of the four wait on somebody with the literature. That is stated per row in
the outputs as well, so an unfilled cell reports itself rather than passing.

The vignettes first: a library of synthetic patient vignettes for the LOT
assignments that are hard, each with what this algorithm does with them.

```
Rscript lot/validation/run_vignettes.R
```

No warehouse, no connection, nothing written to the schema. It resolves the
catalogue against this run's configured parameters and writes a CSV and a
markdown table to `out/`.

## What it is, and what it is not

It is a specification. Each vignette says what the rules say, with the rule
quoted. Nothing here has been executed against a warehouse, so no line of it is
an observed output.

That distinction is on every row, as `confidence`:

| | |
|---|---|
| `derived` | the outcome follows from the rule quoted beside it - reading the code is enough |
| `to_confirm` | the rules interact and this is our reading of them; the first real run settles it |

`to_confirm` is a claim about us, not about the algorithm. Those rows are
the first-run checklist: they are where a careful reader should look before
quoting any of this.

## Why the days are not written down

The days that make a case hard are the configured parameters - 180 for a
tandem, 45 for CAR-T consolidation, 90 for a discontinuation gap. A document
saying "day 181" is wrong the moment one of them moves, and nothing says so.

So every offset is derived from the parameter that decides it, and the cases
come in pairs straddling it: one at the last day inside, one at the first day
outside. `check_vignettes()` then holds the catalogue to its own claims:

* the parameter has to exist in the build's config - a renamed setting fails
  rather than leaving prose describing a rule that is gone;
* the pair has to actually straddle the value;
* the two sides have to expect different things, or the boundary is testing
  nothing;
* the timeline has to run forwards;
* the file each rule is quoted from has to be there.

Change `SCT_TANDEM_DAYS` and the vignettes move with it. That is the whole
design; the vignettes themselves are the easy part.

## What is in it

21 vignettes. The cases the ask named - tandem near the boundary, biosimilar
switch mid-line, maintenance into relapse, overlapping oral refills, an
administrative gap, CAR-T bridging inside the 45-day window, allogeneic after a
failed autologous - plus the boundary pairs for every window parameter, and
four cases that are not boundaries but are worth stating:

`allo_single_day` - an allogeneic line spans one day and carries no
regimen string, because `10_lot2_5_base.R` suppresses induction rows for it.
That is the shape that broke the transition Sankeys, which read a blank regimen
as no line at all.

`maintenance_to_relapse` - maintenance is a descriptive flag
(`contains_mtx_reg`) and nothing more. There is no maintenance period and no
maintenance line. This is a deliberate divergence from algorithms that count
one, and it shifts every later line number by one against them.

`belantamab_any_line` - the criterion is patient-level, so an affected
patient loses every line, not the ones from belantamab onward. It is the one
rule that makes `LOT_LONG` and `LOT_LONG_FINAL` hold different patients.

`line_beyond_max` - nothing above `MAX_LOT` is built, and a capped patient
looks exactly like a completed one in the output.

## The sensitivity sweep

```
# print the plan and its cost; touches nothing, needs no connection
INPUT_COHORT_TABLE=ndmm_NDMM_COHORT Rscript lot/validation/run_sensitivity.R

# actually build them
DATABRICKS_PWD=... INPUT_COHORT_TABLE=ndmm_NDMM_COHORT COHORT_PREFIX=ndmm_ \
  SENS_EXECUTE=TRUE Rscript lot/validation/run_sensitivity.R
```

Execution is opt-in, because one cell is one complete LOT build. There is no
cheaper way: the gap threshold changes how MAPs are formed, which changes the
lines, which changes everything after them - none of it recoverable from an
existing `LOT_LONG` the way `ndmm` recomputes its CE alternatives inside one
run. The default prints the grid, the predicted directions and the cell count so
the cost is readable before anyone commits to it.

The grid is one at a time from the shipped configuration: six parameters
with two alternatives each, plus a seventh that is on or off, is fourteen
builds, not the thousand-odd a cross-product would be.

### The direction is stated before the run

That ordering is the whole value. Fourteen builds produce fourteen different
tables and a reader nods at all of them. Predicting the sign first turns it into
a test - a metric that moves the other way is either a bug or a hole in our
reading, and either is worth knowing.

Predictions carry the same `derived` / `to_confirm` marker as the vignettes,
plus a third value that matters: `unclear`, for metrics where two effects
pull against each other. `unclear` is recorded, never scored. Marking it as a
hit or a miss would reward whichever guess happened to be written down.

The comparison scores the sign relative to the parameter's own direction,
not the size. Fewer lines from a larger gap is the prediction; the same number
of lines from a smaller gap is the opposite finding, and the harness says so.

A number that did not move is its own verdict, `no movement` - not a miss.
The prediction is about the algorithm. Whether anybody in the cohort sits near
the threshold is not, and a window nobody's claims straddle moves nothing
however it is set. Scoring that as `AGAINST EXPECTATION` reports a valid result
as a failure, and a sweep full of false failures stops being read. The
asymmetry is deliberate: predicting `none` and getting movement is still a
miss, because that one is the algorithm contradicting us.

A prediction that could not have come true is worse than a wrong one, and
`MAX_LOT` is where it hides. Its cells are 3 and 8, and LOT3 is built at both -
so `pct_reaching_lot3` cannot move, and predicting that it rises would have
produced the same false failure in every sweep forever. It is predicted `none`,
and the test holds any future cap axis to the same rule.

### Continuous enrolment is two questions

CE eligibility - who qualifies - is the cohort build's axis. `ndmm` already
reports it without rebuilding anything: `NDMM_FU_CE_COUNTS` gives the cohort at
0/30/60/90 days from a single run. Sweeping it here would rebuild the cohort
and the LOT per cell.

CE as censoring - whether LOT stops observing at disenrolment - is a setting
here, `censor_at_disenrollment`, and it is swept. It is the only axis that moves
the observation window rather than a threshold inside it, and the only one
that predicts nothing: all five of its metrics are `unclear`.

That is not caution, it is the shape of the thing. Shortening observation pulls
two ways:

- down - fewer triggers are reachable, so lines and lengths tend to shrink,
  and a patient whose first non-steroid agent lands after they disenrolled has
  no LOT1 at all (`lot1_start` reads `map_stacked`, bounded by `OBS_END_DT`).
- up - the `no_belantamab` criterion reads that same shortened window and
  `on_fail = "truncate"` removes every line of a patient it catches. A
  belantamab claim between disenrolment and study end is visible to the
  reference cell and invisible to this one, so a patient the primary run removes
  outright is kept here, and the counts rise.

The ratios have no direction either - `pct_reaching_lotN` is patients reaching
the line over patients with a LOT1, and both move - and the median is over a set
whose membership changes, so per-patient shortening does not carry to it.
Declaring `down` would score a valid result as `AGAINST EXPECTATION` in every
sweep forever, which is exactly the false failure the rest of this section is
built to avoid. The numbers are recorded; a mover is investigated, starting with
`NO_BELANTAMAB_ANY_LOT`.

It is also the only non-numeric axis, and that costs something. Cell values
travel as text, because `as.integer(TRUE)` is `1` and the build reads that
back through `as.logical("1")` as `NA` - the cell would then build with the
shipped setting, report `no movement` on every metric, and read as a result.

### One of the ask's axes cannot be swept

maintenance-as-LOT vs flag is not a setting. Maintenance is a descriptive flag
(`contains_mtx_reg`) and there is no maintenance period -
`lot/engine/R/steps/05_sct.R:13`. Making it a line would be a different
algorithm, not a sensitivity of this one, so there is nothing here to vary. It
is in the vignette catalogue as the divergence it is.

It is named in the plan output rather than quietly dropped, since an axis
silently missing would read as coverage.

### A cell is not the contract build, and says so

Every parameter here is pinned in the LOT contract, and `build_lot` refuses a
value that is not the contract's - correctly, because a different threshold is
a different algorithm rather than a setting. That is exactly what a cell is, so
each one is launched with `LOT_CONTRACT_OVERRIDE=TRUE`. Without it there is no
executable path at all: thirteen of the fourteen cells stop at preflight, the
reference being the one that is the contract build.

The override is only safe because a cell cannot be picked up as the study. The
build writes what it deviated on into `CONTRACT_DEVIATIONS` in that cell's
`LOT_BUILD_STATUS` - the same row every downstream reader already uses to
resolve which run owns a prefix's tables - and the questions, the dashboard and
the benchmark harness all refuse a run carrying deviations. There is no way
past that one: the state and cohort checks are inferences that can be wrong
about a run, but this is what the build wrote about itself.

`CONTRACT_SETTINGS` in `LOT_RUN_METADATA` records what the run used rather
than what the contract pins, so the two cannot silently agree. On a contract
build that string is byte-identical to what it was before.

### One cohort, checked rather than intended

`COHORT_PREFIX` is required to execute. The build resolves the cohort's
status table under the run's own prefix unless told otherwise, and a cell's
prefix is a throwaway like `sens_max_lot_8_` - so without it every cell finds no
status, warns, and records no cohort run id. Fourteen sequential builds would
then have nothing showing they read one cohort, and a cohort rebuilt mid-sweep
would appear in the table as the parameter's effect.

With it, each cell records the cohort attempt it read - run id and stamp,
since a cohort re-run keeps its id and rewrites its rows - and the sweep
compares them across cells and says plainly if they differ.

### Guards

A cell writing to the study's own prefix is refused - that would overwrite the
run being measured. So is a grid past `SENS_MAX_CELLS` (24), and two cells
sharing a prefix. Each cell runs as its own process, because the build pins a
config and a run id globally and a second build in the same session inherits the
first's. Metrics are read against that cell's own `RUN_ID`, taken from its own
`LOT_BUILD_STATUS`, since `LOT_ATTRITION` is keyed by it.

A sweep leaves a full set of LOT tables per cell. `SENS_DROP_AFTER=TRUE` removes
them once the metrics are read; it is off by default, because dropping tables is
not something a measurement script should do quietly.

## Distribution benchmarks

```
# check the reference file and print what would be measured; no connection
Rscript lot/validation/run_benchmarks.R

# measure this run and compare
DATABRICKS_PWD=... DOMINO_USER_NAME=usr00000 OBJECT_PREFIX=ndmm_ \
  BENCH_EXECUTE=TRUE Rscript lot/validation/run_benchmarks.R
```

`OBJECT_PREFIX` is required, and it has to name a LOT run that finished.
A blank prefix resolves to the unprefixed table names - either absent, or some
older run's, and either way not this study's. The run is resolved from
`LOT_BUILD_STATUS` before anything is measured, and its id and input cohort go
out in the CSV: a benchmark table is exactly the kind of output that outlives
the session that made it, and "median 2.1 lines" carries nothing about where it
came from. It is the latest status row whatever state it reached, not the
latest complete one, for the reason the dashboard and the question scripts use
the same rule - the build replaces `LOT_LONG_FINAL` early and validates it
afterwards, so a rerun that replaced it and then failed owns those tables. A
run carrying contract deviations is refused outright: that is a sensitivity
cell, and comparing an alternative algorithm's distributions to a published
figure would attribute the difference to this cohort rather than to the setting
that was changed.

How many lines to measure comes from the run, not from this package.
`max_lot` is read out of that run's own `CONTRACT_SETTINGS`. They are the same
on the study's run and they stop being the same the moment this is pointed at a
run built with a different cap - and then the package's value either asks for
lines that run never built or leaves out lines it did, with nothing in the
output to say which.

The published numbers are not here and were not written from memory.
`benchmarks.csv` ships with a row for every metric and `published_value` blank,
so whoever has the literature can see exactly which figures are wanted, and an
unfilled row reports itself as `no reference supplied` rather than passing
silently. A value with no `source` is refused when the file loads - that row
would become a citation nobody can chase.

### A benchmark without its definition is not a benchmark

"Median 2 lines" from a paper is not comparable to anything on its own. It
depends on who was counted, how long they were followed, and above all whose
line algorithm was used - a source counting maintenance as a line reports a
larger median than this algorithm can produce, and the gap is the two
definitions rather than a defect in either.

So each row carries `source_population`, `source_followup`, `source_algorithm`,
and the operator's judgement in `comparable`:

| | |
|---|---|
| `yes` | close enough to compare |
| `caveat` | usable, with the difference named in the `caveat` column |
| `no` | recorded for context; scored as nothing |

An unmarked row defaults to `no`. Defaulting the other way would let a
convenient number quietly become evidence.

Nothing here is a pass or a fail. A difference between this cohort and a
published one is two studies differing until the `comparable` column says
otherwise.

### Two definitions that decide whether the comparison means anything

Time to next treatment is a real Kaplan-Meier median, not the median gap
among patients who reached the next line. That naive figure conditions on the
event - it answers "among those who progressed, how fast" - and comes out far
shorter than any published KM median. The worked example in the tests shows the
size of it: the same five patients give 40 days censored properly and 20 days
with the censored ones dropped. Patients without the next line are censored at
their observation end.

Line durations exclude lines still open at study end (`LOT_BASE_END_REASON =
'STUDY_END'`) and count them separately. Folding a censored line in treats it
as a short one and drags the median down. `LOT_BASE_LENGTH` is inclusive -
`datediff + 1` - which is a day per line against a source that is not.

A regimen percentage is out of everyone at that line, including the lines
that carry no regimen string. An allogeneic line has a blank `LOT_BASE_MEDS` by
construction - induction rows are suppressed for it - so summing the named
regimens to get the denominator drops those patients and every percentage comes
out slightly high, under a heading that says "% of line-n patients". It is the
same mistake that made the transition Sankeys read a blank regimen as no line at
all. The consequence is that the top-N percentages do not sum to 100: the
remainder is the tail beyond N plus those blank-regimen lines, which is the
arithmetic a published regimen frequency is on.

The crude `pct_reaching_line` figures are not follow-up adjusted and say so:
a patient with six months of observation had less chance to reach LOT2 than one
with five years. A source reporting a KM estimate is measuring something else.

## Line-of-therapy definition comparison

```
Rscript lot/validation/run_definitions.R
```

No warehouse and no connection - the rules are in the code, not in the data.

Our side is complete: twelve dimensions, each with what this build does and
the file and line to check it against - `path:line`, held to that shape by the
tests, and to a line the file actually has. A citation naming only a file sends
the reader to eight hundred lines of SQL to find out whether one sentence is
true, and a claim that expensive to check does not get checked. That half is the
reusable one, and it did not exist before - the rules live across eight step
files, and "does this count SCT as a line" had nowhere single to look.

The transplant answer is the one worth reading twice, because the obvious half
of it is wrong. `05_sct.R` gives the LOT1 rule - a single AUTO allowed, a tandem
pair allowed, a further one ends the line - and it reads like the whole answer.
It is not: at LOT2 and later `SCT_AUTO` is a start type, so a transplant
beyond what the previous line allowed becomes a line of its own, with no drug
beside it. Stopping at LOT1 would have told a protocol comparison "never a
separate line", which is the opposite of what this build does.

The dimensions the ask named are all there - SCT as separate line vs part of
induction, maintenance counted or not, gap and switch rules - plus the ones
where this algorithm decides something another could decide differently:
substitutions, steroids, dose changes, the CAR-T bridging window, the line cap,
and what fixes the start of first line.

### Their side is empty, and it stays empty until somebody sources it

The consensus paper and the trial protocols are not in this folder, and no
summary of one is allowed to stand in. A summary reads like a citation, cannot
be checked by anyone holding the source, and would produce a concordance table
that looks authoritative and is not. `read_definition_sources()` rejects
`search_summary` and `recollection` by name, and refuses any answer without
a citation at all.

So `definitions_sources.csv` ships as a grid somebody with the documents can
fill mechanically - 12 dimensions x 6 source slots (IMWG plus the five pivotal
trials the ask asked for), with the question to put to each protocol spelled out
per dimension.

### The default falls to "not yet sourced"

Never to "agrees". An empty comparison that reads as agreement retires the
question instead of answering it, and one sourced dimension must not make the
others look answered. A sourced answer with no judgement recorded is `unclear`,
not agreement.

Registry and publication citations require a `retrieved` date - records change,
and a citation without one cannot be checked against what was actually read.

## What the ask wanted and this does not have

The ask asked for each vignette's assignment under IMWG rules and >=2 published
alternative algorithms as well as ours.

Those columns are not here and were not guessed. Filling them needs the IMWG
consensus and the published algorithms in front of you; writing them from
recollection would produce a comparison table that looks authoritative and cites
nothing. The catalogue is built so those columns can be added beside
`expected` - the vignettes and their timelines are the reusable half - but
somebody with the sources has to add them.

The definition comparison above is the same limit at protocol scale: the
framework and our column are built; the source documents are not here.


## Regimen membership: stockpiling

Optum supplies no treatment end date. Cover is `FILL_DT` plus `DAYS_SUP`, and an
overlapping refill pushes it out rather than opening a new episode, so an agent
can be covered across the whole of the next line's induction window while still
carrying the earlier line's `MAP_START_DT`. The build tests `MAP_START_DT`, so
that agent does not join the next line's regimen.

The protocol reads wider — "all MM therapies identified during the first 30 days
of the LOT" — and the LOT2-5 spec's worked example A assumes a continuing agent
lands in LOT2. The study team settled it as built: a patient who has switched is
no longer filling the old agent, so residual cover is a dispensing artefact. This
sizes what the other reading would have cost.

```
Rscript lot/validation/run_stockpiling_rule.R                       # the rule, no connection

DATABRICKS_PWD=... DOMINO_USER_NAME=usr00000 OBJECT_PREFIX=ndmm_ \
  STOCK_EXECUTE=TRUE Rscript lot/validation/run_stockpiling_rule.R  # measure it
```

| table | one row per |
|---|---|
| `<prefix>STOCKPILE_AGENTS` | line and agent a coverage rule would add, with the episode that carries it |
| `<prefix>STOCKPILE_IMPACT` | affected line - agents gained, regimen size before and after |
| `<prefix>STOCKPILE_BY_LOT` | line number - affected against every line at that number |
| `<prefix>STOCKPILE_BY_MED` | agent - how often it carries, and for how long |

### What it can and cannot say

It counts regimen changes, and the two boundary effects that follow from a
finished run: an added agent is a base agent, so it enters the run-out
calculation (`WOULD_EXTEND_RUNOUT`) and leaves the added-medication candidate
list (`WOULD_REMOVE_ADD_MED`). It is not a resulting line count — the lines
that follow a moved boundary are not recoverable from finished lines.

LOT1 cannot be affected: it starts at the patient's first non-steroid MM agent,
so no such episode precedes it. A non-zero LOT1 is printed as a warning rather
than filtered away, because it would mean the line table is not what this
assumes. ALLO-started lines are excluded — they carry no regimen at all.

## The melphalan rule

A study-team proposal: a melphalan administration should advance the line on
windows of its own. The rule and how it differs from the build, branch by
branch, are in `lot/questions/melphalan_lot_rule.md`. This measures it.

```
Rscript lot/validation/run_melphalan_rule.R                       # the rule, no connection

DATABRICKS_PWD=... DOMINO_USER_NAME=usr00000 OBJECT_PREFIX=ndmm_ \
  MELP_EXECUTE=TRUE Rscript lot/validation/run_melphalan_rule.R   # measure it
```

It changes nothing in `lot`. No setting, no step, no line rebuilt - it reads
a finished run and counts the line boundaries the rule would add and remove.
That is deliberate: the three files it would otherwise touch are compared
line-for-line against the source, and a proposal under discussion should not
move them.

| table | one row per |
|---|---|
| `<prefix>MELP_RULE_EXPOSURES` | exposure - its line, its gap, and what the rule does with it |
| `<prefix>MELP_RULE_BRANCHES` | branch of the rule - the table from the request, with counts |
| `<prefix>MELP_RULE_IMPACT` | patient whose line count moves - split, merged, before and after |

### What it can and cannot say

It counts BOUNDARIES, not lines. How many the rule adds, and how many it
removes. Subtracting one from the other does not give a resulting line
count, and none is published: moving a boundary changes which line an exposure
falls in, whether an agent is inside an induction window, regimen membership,
discontinuation dates and every later line number. An exact line structure needs
an alternate build, once the clinical rule is settled.

The placement is not circular. The finished lines already encode the current
algorithm's decisions about this drug: a melphalan dose first seen outside the
induction window is an add-med, and the build ends the line the day before it
(`04_lot1_base.R:131`) - so that dose sits on day 0 of the line it created.
Asking "which line contains this date" would read it as inside the induction
window and turn every B branch into an A. The reference line is therefore the
previous one wherever this drug created the boundary.

Every exposure carries a reason, never a bare blank. `UNPLACED`, `NO_NEXT`,
`YIELDED`, `YIELDED_NEXT`, `NO_ADVANCE`, `FIRST`, `NEXT`. A boundary is removed
only on `NO_ADVANCE` - the rule actively declining. Collapsing those into one
"no advance" would remove the boundary of a lone exposure the rule says nothing
about.

### The transplant question

High-dose melphalan is transplant conditioning, and the build already has a
transplant rule with the same 180-day tandem window. The request does not say
what happens when both see one event, so `MELP_RULE_MODE` carries both readings
and every output row records which produced it:

| | |
|---|---|
| `yield_to_sct` (default) | an exposure with an AUTO coded within `MELP_SCT_DAYS` is left to the transplant rule. The melphalan rule then fills only the gap where a transplant left no procedure code. |
| `as_asked` | every exposure is judged, as the rule is written. Where a transplant is coded, both rules see one event; `HAS_AUTO` counts the overlap either way. |

`HAS_AUTO` is recorded under both, so the size of the overlap is readable
without running it twice - though running it twice is the direct comparison.

Yielding looks at the exposure the boundary would fall on, not the one being
judged. The A.2 and B.3 boundaries land on the next exposure, so that is whose
transplant code decides it; checking only the current one let a coded transplant
open a melphalan boundary in yield mode.
