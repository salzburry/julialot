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
