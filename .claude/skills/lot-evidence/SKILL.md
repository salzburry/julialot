---
name: lot-evidence
description: >
  Fill and check the two external-evidence grids the LOT validation harness in
  `Jul 28/lot/validation/` is waiting on — `definitions_sources.csv`, which sets the
  algorithm's rules against IMWG consensus and pivotal trial protocols dimension by
  dimension, and `benchmarks.csv`, which sets its outputs against published real-world
  numbers. Use this skill whenever the user wants to compare the LOT algorithm to a
  clinical trial's or a guideline's definition of a line of therapy; asks whether a
  published median, LOT distribution or regimen frequency agrees with the build; wants
  to source, cite, or check a benchmark; mentions IMWG, NCCN, a registry, a named trial
  or a published cohort in the context of line counting; or asks how a rule the engine
  applies compares to how the literature defines it — even if they never say "grid",
  "benchmark" or "evidence".
---

# LOT evidence grids

Two CSVs in `Jul 28/lot/validation/` hold everything this study claims about the
outside world. Both are fully scaffolded and both are empty.

| | | rows |
|---|---|---|
| `definitions_sources.csv` | how each of 12 LOT dimensions is operationalised by IMWG consensus and 5 pivotal trials | 72, none sourced |
| `benchmarks.csv` | published values for 5 metrics — lines per patient, % reaching line n, line duration, KM time-to-next-treatment, regimen share | 29, none sourced |

Filling them is this skill's job. **Not** deciding what the algorithm does — that
is `lot-contracts`. This is only ever: what does the outside source say, where
exactly does it say it, and does it agree.

## The rule that matters most

**An empty cell is fine. An unsourced one is not.**

A blank row is visibly not done. A row with a plausible number and no citation
is invisible: it reads as evidence, gets quoted, and cannot be chased. Both
readers already refuse it, so the failure mode is not a silently wrong study —
it is a run that stops. Do not work around that by removing a value; work
around it by finding the citation or leaving the cell blank.

Never infer a value from context, a recollection, or another cell. If a trial's
protocol does not say whether transplant is a separate line, the answer is
`unclear` with a citation to where it declines to say — not a guess at what
they probably meant.

## Filling `definitions_sources.csv`

One row per (dimension, source). Read `R/definitions.R` first: it holds the 12
dimensions, what each one asks, and **our** answer with a `where =` citation
into the engine. Your job is the other side of each row.

| column | |
|---|---|
| `dimension_id` | must be one of the 12. A name that is not stops the load. |
| `source_id` | `IMWG_consensus` or `trial_1`..`trial_5`. Say which trial in `notes` on first use. |
| `source_type` | one of the accepted types. Some are rejected outright — the reader names them. |
| `citation` | required once `answer` is filled. Specific enough to reopen: section or table, not just a title. |
| `retrieved` | required for a registry, publication or guideline. Those change. |
| `answer` | what the source operationalises, in its terms, not ours. |
| `concordance` | `agrees` / `differs` / `unclear` against our answer. |

`unclear` is a real finding and the most common honest one — a trial that
counts prior lines without defining a line is telling you something about the
field. Record it rather than forcing agreement.

Where a source `differs`, say how in `notes`, concretely: "counts tandem
transplant as one line; we count the second as excess beyond 180 days".

## Filling `benchmarks.csv`

One row per (metric, line, regimen). The metrics are fixed by
`BENCHMARK_METRICS` in `R/benchmarks.R`; a metric the harness does not measure
stops the load.

`published_value` must be numeric, and needs `source`. Beyond that:

**Claiming comparability is a claim about three things.** If you set
`comparable` to `yes` or `caveat`, then `source_population`, `source_followup`
and `source_algorithm` must all be filled, and the reader enforces it. Two
studies can differ entirely because one counted maintenance as a line — a
median quoted as comparable without saying which algorithm produced it is the
number most likely to be repeated and least able to be checked.

Leaving `comparable` blank is always allowed and falls back to `no`: the value
is recorded, and the harness reports "recorded, not comparable" rather than a
difference. Prefer that to a comparability you cannot support.

A gap between observed and published is **never a pass or a fail**. It is two
studies differing until `comparable` says otherwise. Do not describe one as
validating or invalidating the other.

## Check your work before handing it back

```
Rscript "Jul 28/lot/validation/tests/test_definitions.R"
Rscript "Jul 28/lot/validation/tests/test_benchmarks.R"
Rscript "Jul 28/lot/validation/run_definitions.R"     # renders both sides
```

Both readers stop on the first structural problem and name the row. A run that
loads is not a run that is right — it means every filled cell carries what it
needs to be checked by someone else.

## Starting from scratch

`references/starting-prompt.md` is a ready-to-run prompt for the trial
comparison, one source at a time. Run it per source rather than for all six at
once: a single pass over IMWG and five trials produces six answers of the
quality of the worst one, and nothing afterwards says which was which.

## What this skill does not do

* It does not change the algorithm. A source that differs is recorded as
  differing; whether to follow it is `lot-contracts` and the study team's.
* It does not fill `Jul 28/lot/safety/`. Those are claim code lists, not
  literature, and they have their own guard.
* It does not compare against another delivery in this repository. The grids
  are for external evidence.
