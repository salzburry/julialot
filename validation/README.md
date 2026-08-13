# Validation

Checks that prove the `Jul 28` packages are still what they were migrated to
be. They are **not part of the deliverable** — only `Jul 28/` is deployed — and
that is the whole reason they live here.

```
Rscript validation/run_all.R                      every suite, one summary
```

## Why they are outside the packages

They name the baseline the packages were migrated from and cite line ranges
inside it, so a package shipping with them would ship that name too. Keeping
them outside the deployable folder holds both: `Jul 28/` carries no reference
to the baseline, and the equivalence check still runs on every change.

| | |
|---|---|
| `port/overall.R` | the overall build's steps against the baseline, line for line |
| `port/ndmm.R` | every ported NDMM file against its range in the baseline |
| `port/lot.R` | the LOT1 phases and `10_lot2_5_base.R` against the baseline |
| `hygiene/lot_selfcontained.R` | the LOT engine resolves no path outside itself |
| `hygiene/study_folder_standalone.R` | the study folder names no other delivery |

## Paths

`_common.R` resolves the packages at `<repo>/Jul 28` and the baseline at
`<repo>/apr_30_2026`. Both are overridable, so a release job can point at a
checkout laid out differently or at a renamed package folder:

```
PKG_BASE=/some/checkout/pkgs BASELINE_DIR=/some/checkout/baseline \
  Rscript validation/run_all.R
```

A suite names the package it checks and where it sits, because that is the
suite's business rather than `_common.R`'s: `pkg_dir` takes path segments, so
the LOT engine is `pkg_dir("lot", "engine")` under the `lot/` group and a
cohort build is still `pkg_dir("ndmm")`.

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

`hygiene/lot_selfcontained.R` runs with **no exclusions**. The two files that
would need carving out — itself, and the port comparison that reads the
baseline on purpose — both live here, so every file left inside the package is
held to the rule.
