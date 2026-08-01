# Validation

Checks that prove the `Jul 28` packages are still what they were migrated to
be. They are **not part of the deliverable** — only `Jul 28/` is deployed — and
that is the whole reason they live here.

```
Rscript validation/run_all.R                      the R suites, one summary
python3 validation/mutation/lot_battery.py        minutes; before a release
python3 validation/mutation/nndm_battery.py       minutes; --all before a release
```

A battery run with no arguments covers only the mutations whose file this tree
has changed, and says so. `--all` is the release check.

**Do not pipe a battery into `tail` or `head`.** A pipeline's exit status is the
last command's, so `python3 nndm_battery.py --all | tail -30` reports 0 even
when a mutation survived — the summary line says `problems: 1` and the shell
says success. Run it bare, or capture with `PIPESTATUS`. A CI job written the
first way passes through a surviving mutation.

## Why they are outside the packages

They used to sit in `Jul 28/<pkg>/tests/`. They name the baseline the packages
were migrated from and cite line ranges inside it, so a package that shipped
with them shipped that name too. Deleting them instead removed the only thing
that keeps proving the migration still holds — git history says what was true
at one commit, not what is true now.

Outside the deployable folder, both hold: `Jul 28/` carries no reference to the
baseline, and the equivalence check still runs on every change.

| | |
|---|---|
| `port/overall.R` | the overall build's steps against the baseline, line for line |
| `port/nndm.R` | every ported NDMM file against its range in the baseline |
| `port/lot.R` | the LOT1 phases and `10_lot2_5_base.R` against the baseline |
| `hygiene/lot_selfcontained.R` | the LOT package resolves no path outside itself |
| `mutation/*.py` | break one thing each suite claims to hold; the suite has to notice |

## Paths

`_common.R` resolves the packages at `<repo>/Jul 28` and the baseline at
`<repo>/apr_30_2026`. Both are overridable, so a release job can point at a
checkout laid out differently or at a renamed package folder:

```
PKG_BASE=/some/checkout/pkgs BASELINE_DIR=/some/checkout/baseline \
  Rscript validation/run_all.R
```

A suite whose package or baseline is missing exits **3** and reports SKIP.
`run_all.R` counts skips separately and exits non-zero on any, because a
release check that quietly ran nothing is exactly the failure this directory
exists to prevent.

## What the port suites do

They are not similarity checks. Each undoes the deviations that are registered,
with a reason, and then demands the code be **identical**. An unregistered
change survives the undo and breaks equality. A registered deviation that is
deleted leaves an entry with nothing to undo, which is reported rather than
reading as a perfect match.

`hygiene/lot_selfcontained.R` now runs with **no exclusions**. It used to carve
out two files — itself, and the port comparison that reads the baseline on
purpose. Both are here now, so every file left inside the package is held to
the rule.

## The batteries

| | mutations | state |
|---|---|---|
| `lot_battery.py` | 37 | every anchor valid; full sweep run, 0 problems |
| `nndm_battery.py` | 244 | every anchor valid; the 18 touched by the re-anchoring run, 0 problems |

Each mutation edits one exact string in the source and the suites must notice.
A mutation that survives means the assertion for it reads the source rather
than running it.

The anchor check is a **gate on the whole run**: every anchor is verified before
anything is mutated, and one stale anchor exits 1 without running any mutation.
That is deliberate — a stale anchor read as a pass once, which is worse than no
run — but it means a stale anchor makes this a red check, not a partial one.
Fourteen went stale when the criteria were centralised and had to be re-derived
before the battery would run again.

### What changed when the criteria moved into one list

Twelve mutations were re-pointed. The properties they break are unchanged; the
strings that express them moved:

| mutation | now breaks |
|---|---|
| `criteria where drops all but one` | `ndmm_criteria_where()` renders only the first criterion |
| `funnel rows not cumulative` | the funnel asks for prefix 1 every row instead of `i` |
| `belantamab narrows an earlier row` | the funnel loop runs one further, so belantamab enters early |
| `attrition step dropped`, `attrition order` | an `NDMM_CRITERIA` entry is removed or two are swapped |
| `scope counts not costed`, `fu ce criterion count only` | a sensitivity table gets a prefix instead of all-but-its-own |
| `reconcile beyond the cohort`, `reconcile drops the date` | the reconciliation's join and date column, under the new alias |
| `flags checkpoint dropped` | the checkpoint no longer precedes `NDMM_PATIDS` |
| `clear run rows before the status` | the clear runs before the run is marked started |

One was **inverted**. `clear run rows stops the build` used to turn a warning
into a stop; the build stops now, so `clear run rows warns instead of stopping`
turns the stop back into a no-op.

Two were **retired**: `readme port count stale` and `readme port total stale`
pinned a deviation-count paragraph that left the README with the scrub, along
with the assertion that read it. README coverage is carried by the funnel and
criteria mutations, which are anchored and run.

### One more the anchors could not have told us

`attrition key typo` had a valid anchor and still **survived** the first full
sweep — which is the case only a full run finds. It renamed a criterion's key
in the middle of the list. That used to break the join between the labels and
the counts, because each side kept its own list. Both sides read `NDMM_CRITERIA`
now, so a renamed key moves on both at once, they still agree, and nothing is
wrong: the published table keys off `label`, and the key is internal.

That is single-sourcing working — there is no longer a disagreement to detect —
but it left the mutation testing nothing. It is re-pointed at the one key that
is still two-sided: `ndmm_final` is derived into `ATTRITION_STEPS` from the
list, while `ndmm_counts()` returns it as a literal, because the last row reads
the cohort view rather than a prefix. A typo there still breaks the join, and
is caught.

A surviving mutation is not always a bug in the code. Here it was a mutation
that had stopped meaning anything, and the fix was to aim it at the seam that
still exists.
