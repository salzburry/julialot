# LOT QC

Thirty-two checks against a finished LOT run. Reads only; writes a report to `out/`.

```
# list the checks; no connection
Rscript lot/qc/run_lot_qc.R

# run them
DATABRICKS_PWD=... DOMINO_USER_NAME=usr00000 OBJECT_PREFIX=ndmm_ \
  INPUT_COHORT_TABLE=ndmm_NDMM_COHORT \
  QC_EXECUTE=TRUE Rscript lot/qc/run_lot_qc.R
```

Exit status is 0 when nothing failed and 1 when something did, so it can gate a
handover step.

## Why it is separate from the build

The build already refuses a `LOT_LONG` whose lines overlap, run backwards, skip
a line number or end after observation. Those are cheap and it makes them on
every run.

The questions here are slower and mostly not worth a rebuild: does each end
reason agree with its own date, does every drug in a regimen have a treatment
episode inside that line's window, do the funnel and the published table
describe the same run. Asking them afterwards means a run already on disk can
be signed off without touching it.

Nothing here duplicates a check the build already makes.

## What it checks

| | |
|---|---|
| Structure | the length column against its own dates, the CE sensitivity columns, start types, regimen size, empty regimens |
| End reason | each branch of the end cascade against the date it should have produced, the enum itself, and the two populations where the spec and the build read an end differently |
| Regimen | every regimen drug has an episode in that line's window; the added medication is not already in the regimen |
| Episodes | run-out arithmetic, observation bounds, and whether steroids reach the episodes |
| Transplant | tandem against single, the 60-to-180 band, the transplant end date floor |
| Reconciliation | the published table against the unfiltered one, the funnel, the progression rows and the metadata |

Three severities. `fail` is something the algorithm's own definition says cannot
happen, so a count above zero is a defect rather than a property of the data.
`warn` is worth a look. `info` is counted and never scored - those are the ones
that say what a known ambiguity actually costs on this cohort.

A check that could not run is reported as an error, not a pass, and counts
against the exit status. A QC run that quietly skipped half its checks is not a
QC run.

## Five of them exist because of a specific disagreement

Each is a place where the documents say two things, or say one thing and the
build does another - checked against the spec and protocol revisions directly.
None of the five is a failure: they are the numbers a reviewer needs before
signing, because reading them off the code is not the same as knowing them.

**D3, episodes carrying a steroid (warn).** Two spec-consistent states. The
spec keeps steroid claims in the episode data - its own worked example is a
dexamethasone episode - and excludes them from every line decision by class,
which the engine does at each decision point. The engine README
(`lot/engine/README.md`) goes further: the code list itself should not carry
them, and `lot/tools/remove_steroids_from_rollup.R` is what removes them.
Zero means the list is clean; a count means the exclusion is resting on the
class filters alone.

**E3, tandem pairs exactly on the boundary (info).** The spec says both. Its
prose and its LOT2-6 settings table give the window as 60 to 180 days
inclusive with no `+1` - which is what the build tests - while its SCT tab
still carries the older `(dt2 - dt1 + 1) <= 180` formula, one day tighter, and
the autologous windowing step still aims at the tighter reading. A pair at
exactly 180 days is a planned tandem under one and not the other, and a
planned tandem does not end the line.

**C3, lines where more than one drug could have been the added medication
(info).** When several non-regimen drugs share the earliest added date the
build breaks the tie with `rand(42)` inside a window `ORDER BY`. Spark seeds
that per partition, so the *date* is stable across re-runs but the *drug* is
only stable while the physical plan is. Zero means the question never arises
on this cohort.

**B8, discontinuations inside the old confirmation window (info).** The spec's
LOT1_BASE tab still carries a rule nulling a run-out within 90 days of
observation end - not enough follow-up to confirm a true discontinuation -
while its later end-date tabs re-derive the date with no such condition, which
is what the build does. Whether that rule was demoted or forgotten, these are
the lines it would have censored instead.

**B9, deaths outranking an earlier run-out (info).** The spec ends a line at
the earliest of its ending events, with the priority order only breaking
same-day ties - and in that tie-break death ranks below discontinuation. The
build instead lets a death outrank an earlier run-out when nothing between the
two would have started the next line. These are the lines where the two
readings give different end reasons and end dates.

## It judges a run by that run's settings

The windows come out of `CONTRACT_SETTINGS` on the run's own metadata row, not
out of `config.csv`. A window edited since the build would otherwise be used to
judge lines built under the old one - which fails checks that are correct, or
worse, passes ones that are not.

A setting the run did not record stops the QC by name rather than defaulting.
Defaulting would judge the run by a number it never used.

The same goes for the observation end: the build derives it once, in a session
view that is long gone, so it is rebuilt here the same way from the recorded
`censor_at_disenrollment` rather than assumed to be `ENDDATE`.

## Which run it checks

The latest row in `<prefix>LOT_BUILD_STATUS`, whatever state it reached - the
same run every other reader in this folder resolves, and for the same reason:
the build replaces its tables before it validates them, so a re-run that
replaced them and then failed still owns them.

An incomplete run stops it. A run carrying `CONTRACT_DEVIATIONS` stops it too,
because most of these checks are statements about the contract algorithm.
Checking a sensitivity or melphalan cell is reasonable, so `QC_ALLOW_DEVIATION`
lets it through - and the report then carries the deviation on its face.

## Patient ids

Masked to the last six characters wherever a check names an example. The report
is a file that gets circulated, and a check that finds a hundred bad rows only
needs to show you one of them well enough to find it again.

## Tests

```
Rscript lot/qc/tests/test_lot_qc.R
```

No connection. The checks are generated with fake table names and inspected:
that each answers the same shape, that each reads only the tables it declares,
that no patient id leaves unmasked, that the settings parsing survives a key
which is a suffix of another key, and that a count becomes the right verdict.
