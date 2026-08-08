# LOT QC

Thirty checks against a finished LOT run. Reads only; writes a report to `out/`.

```
# list the checks; no connection
Rscript lot_qc/run_lot_qc.R

# run them
DATABRICKS_PWD=... DOMINO_USER_NAME=usr00000 OBJECT_PREFIX=ndmm_ \
  INPUT_COHORT_TABLE=ndmm_NDMM_COHORT \
  QC_EXECUTE=TRUE Rscript lot_qc/run_lot_qc.R
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
| End reason | each branch of the end cascade against the date it should have produced, and the enum itself |
| Regimen | every regimen drug has an episode in that line's window; the added medication is not already in the regimen |
| Episodes | run-out arithmetic, observation bounds, and no steroid anywhere |
| Transplant | tandem against single, the 60-to-180 band, the transplant end date floor |
| Reconciliation | the published table against the unfiltered one, the funnel, the progression rows and the metadata |

Three severities. `fail` is something the algorithm's own definition says cannot
happen, so a count above zero is a defect rather than a property of the data.
`warn` is worth a look. `info` is counted and never scored - those are the ones
that say what a known ambiguity actually costs on this cohort.

A check that could not run is reported as an error, not a pass, and counts
against the exit status. A QC run that quietly skipped half its checks is not a
QC run.

## Three of them exist because of a specific disagreement

**D3, no steroid in any episode.** Steroid codes are kept out of the medication
code list, so no steroid claim should reach an episode at all. The program spec
records the opposite - steroids in the regimen, extending the run-out date - so
anyone reconciling to that document needs the difference to be a measured zero
rather than an assurance.

**E3, tandem pairs exactly on the boundary.** The build tests
`datediff(dt2, dt1) <= 180`. The spec's formula is `(dt2 - dt1 + 1) <= 180`, one
day tighter, and the autologous windowing step still aims at the tighter
reading. A pair at exactly 180 days is a planned tandem under one and not the
other, and a planned tandem does not end the line. This counts the patients the
disagreement is worth.

**C3, lines where more than one drug could have been the added medication.**
When several non-regimen drugs share the earliest added date the build breaks
the tie with `rand(42)` inside a window `ORDER BY`. Spark seeds that per
partition, so the *date* is stable across re-runs but the *drug* is only stable
while the physical plan is. Zero means the question never arises on this cohort.

None of the three is a failure. They are numbers a reviewer needs before
signing, and they are here because reading them off the code is not the same as
knowing them.

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
Rscript lot_qc/tests/test_lot_qc.R
```

No connection. The checks are generated with fake table names and inspected:
that each answers the same shape, that each reads only the tables it declares,
that no patient id leaves unmasked, that the settings parsing survives a key
which is a suffix of another key, and that a count becomes the right verdict.
