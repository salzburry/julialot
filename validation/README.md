# Validation

Checks that prove the `Jul 28` packages are still what they were migrated to
be. They are **not part of the deliverable** — only `Jul 28/` is deployed — and
that is the whole reason they live here.

```
Rscript validation/run_all.R                      the R suites, one summary
python3 validation/mutation/lot_battery.py        minutes; before a release
python3 validation/mutation/nndm_battery.py
```

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

## Known gap: 14 stale anchors in the NDMM battery

`nndm_battery.py` has 246 mutations. **232 are anchored and run; 14 are not.**
Each mutation edits an exact string in the source, and these 14 name regions
that have since been rewritten:

| mutation | why its anchor is gone |
|---|---|
| `ported flags sql`, `flags checkpoint after patids` | `NDMM_PATIDS` builds its conjunction from `NDMM_CRITERIA` now |
| `ported cohort sql`, `belantamab last` | `ndmm_counts()` walks that list instead of writing predicates out |
| `attrition step dropped`, `attrition order` | `ATTRITION_STEPS` is derived from the same list |
| `scope counts not costed`, `fu ce criterion count only` | the sensitivity tables derive all-but-their-own criterion |
| `reconcile beyond the cohort`, `reconcile drops the date` | the reconciliation reads `NDMM_FLAGS_ALL`, not the cohort |
| `clear run rows stops the build`, `clear run rows before the status` | it stops now, and the failed-status handler is armed before it |
| `readme port count stale`, `readme port total stale` | the deviation-count paragraph left the README with the scrub |

Several are **obsolete rather than merely stale**: they mutate a behaviour into
one the code now has deliberately. `clear run rows stops the build` turns a
warning into a stop, which is what it does. `reconcile beyond the cohort` makes
the reconciliation look past the cohort, which is the fix. Those need retiring
or inverting, not re-pointing, and that is a judgement per mutation rather than
a find-and-replace.

The battery checks every anchor before it mutates anything and exits 1 listing
the stale ones, so this fails loudly. It does not silently pass.
