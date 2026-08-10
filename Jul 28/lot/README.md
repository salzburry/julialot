# LOT

The lines-of-therapy engine, and everything that depends on it.

One package here writes a study run's LOT tables, and only that one: everything
else reads that run, derives from it, or rebuilds it under a changed rule into a
prefix of its own. So the lines themselves have a single author. `lot/outcomes/`
does add tables under the study's prefix, but they are its own `OUT_*`, derived
from a finished run rather than a second account of it.

| | |
|---|---|
| `lot/engine/` | builds the lines. `build.R <COHORT_TABLE> <prefix_>`. The only package here that writes a study run. |
| `lot/dashboard/` | one self-contained HTML off a finished run. `build.R <COHORT_TABLE> <lot_prefix_>`. |
| `lot/outcomes/` | TTNT, TTD, OS and attrition off a finished run. `build.R <COHORT_TABLE> <lot_prefix_>`. |
| `lot/questions/` | the study team's questions, one script each. Not a build. |
| `lot/qc/` | the slower checks on a finished run, asked after the fact. `run_lot_qc.R`. |
| `lot/validation/` | whether the rules are the right rules - vignettes, benchmarks, definitions, a sensitivity sweep. |
| `lot/melphalan/` | a proposed line-advancing rule, built as three complete runs and differenced. Opt-in. |
| `lot/tools/` | edits a production code list on request. Not a study stage. |

Paths above are written from the study folder, so `lot/engine/` is what you type
standing at its root. Each package's own README runs its commands from that
package's folder instead, which is why they read `Rscript build.R` rather than
the whole path.

## What a study run uses

`lot/engine/`, then `lot/dashboard/`, `lot/outcomes/` and `lot/questions/` over
what it wrote. `lot/qc/` signs a finished run off.

The rest are not part of a run: `lot/validation/` is the case for the rules,
`lot/melphalan/` an experiment on one of them, `lot/tools/` a maintenance
utility. The two that build - the sensitivity sweep and the melphalan cells -
write to throwaway prefixes of their own and are opt-in, so neither can land on
a study's tables by being run at the wrong moment.

## Why the engine is its own folder

It is copied into other projects as-is, so it may not reach outside itself: no
sibling here is on its path, its only outside dependencies are the R packages
`DBI`, `odbc` and `glue`, and nothing in it names a cohort. Its own README says
so, and a check outside this folder holds every file in it to that.

The direction is one-way, and it is the whole reason the split reads the way it
does. `lot/qc/`, `lot/questions/`, `lot/validation/` and `lot/melphalan/`
resolve `../engine` and read its modules, so the config, the code lists and the
naming helpers have one definition rather than a copy per reader. `lot/engine/`
resolves nothing back.

`lot/dashboard/` and `lot/outcomes/` are the two that do not: they read a
finished run's tables and nothing else, so they carry their own `load_inputs.R`,
config and helpers. That is a real duplication, and the reason it is tolerated
is that neither reads a code list or a line rule - only columns the engine has
already written - so there is no rule for their copy to drift away from.

## The cohorts are not here

`overall/` and `ndmm/` build the cohorts. A cohort is what the engine is
pointed at - `build.R` takes the table name - so it comes before LOT rather
than under it, and neither cohort build reads anything in this folder at run
time.

Two things do cross, and both are worth knowing before this folder is moved
again. `ndmm/build_subsequent_cohorts.R` runs *after* a LOT run, because the 2L
and 3L index dates are line starts; it is still a cohort build, so it lives with
the cohorts. And `ndmm/tests/` reads `lot/engine/R/build_lot.R` as a source
file - not to run it, but to pin the interface between them: the columns the
engine requires of a cohort, and the columns its status table really has. A
suite that invented either would pass while the pair disagreed.

## Settings and tests

Each package has a `README.md` with its own settings, outputs and checks, and a
`config.csv` where it has settings at all. Read that one before running it.
`lot/tools/` is the exception on both counts: one script, documented in its own
header.

The tests need no connection. The study folder's `README.md` lists them all in
one block.
