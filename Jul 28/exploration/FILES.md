# Exploration

Work that is **not** in the study's numbers: the measurements that ask whether
the rules the build applies are the right ones.

Nothing here is part of a study run, and nothing here can become one by
accident. The things that build — the sensitivity sweep and the fold-in cells —
are opt-in, write to throwaway prefixes of their own, and launch with
`LOT_CONTRACT_OVERRIDE=TRUE`, which writes `CONTRACT_DEVIATIONS` into that run's
status row. Every reader in the delivery refuses a run carrying one.

`lot/` is what the study ships; this is what was asked about it.

| | |
|---|---|
| `exploration/lot/` | benchmarks, the definition comparison, the sensitivity sweep, stockpiling, re-challenge, the MAP fold-in cells, and the audit counts |

The melphalan comparison is no longer here. The rule was adopted, so what
measures it moved to `lot/melphalan/` with it, and the five-branch rule that
was not adopted was removed on 2026-08-30 — `STUDY_TEAM_ASKS.md` keeps the
finding.

The rule vignettes are **not** here. They are the machine-checked twins of the
scenarios in `lot/LOT_RULES.md`, so they stay with the rules, in
`lot/validation/` — `lot/FILES.md` describes them.

## `exploration/lot/` — measuring the algorithm

Five asks against the rules, plus the audit counts. None of it has executed
against a warehouse, so nothing here is an observed output. Every runner prints
what it would measure, needs no connection until told to execute, and resolves
which run actually wrote the tables before measuring them.

| path | what it does |
|---|---|
| `R/run_binding.R` | Works out which run actually wrote the tables about to be measured, since the tables themselves do not say. Shared by every measurement below. |
| `R/benchmarks.R` | This algorithm's distributions — lines per patient, regimen frequencies, durations, TTNT — beside published figures. |
| `benchmarks.csv` | The reference grid, shipping with `published_value` blank: the published figures are not this folder's to write, and an unfilled row reports itself rather than passing. A value with no `source` is refused on load. |
| `run_benchmarks.R` | Measures a finished run and compares. `OBJECT_PREFIX` required; `BENCH_EXECUTE=TRUE` to run. |
| `R/definitions.R` | How this algorithm operationalises "line of therapy" across twelve dimensions, each answer cited to file and line so a reader can check it. |
| `definitions_sources.csv` | The grid somebody with the documents fills in — 12 dimensions × 6 source slots. A summary or a recollection is rejected by name; the default falls to "not yet sourced", never to "agrees". |
| `run_definitions.R` | Renders the comparison. No warehouse — the rules are in the code, not the data. |
| `R/sensitivity.R` | Moves one threshold at a time, with the direction predicted before the run, so a metric moving the other way is a finding. Fourteen cells, each a complete LOT build under `LOT_CONTRACT_OVERRIDE` into a throwaway prefix. |
| `run_sensitivity.R` | Prints the grid, the predicted directions and the cell count by default; `SENS_EXECUTE=TRUE` builds them. |
| `R/stockpiling.R` | Sizes coverage-based regimen membership: what leftover cover would add or remove if it counted. Writes `STOCKPILE_AGENTS`, `STOCKPILE_IMPACT`, `STOCKPILE_BY_LOT`, `STOCKPILE_BY_MED`. |
| `run_stockpiling_rule.R` | Prints the rule; `STOCK_EXECUTE=TRUE` measures it. |
| `R/rechallenge.R` | Sizes re-challenge events — an agent returning — and the gap that decides each one. |
| `sql/rechallenge_evidence.sql` | The query behind it. |
| `run_rechallenge_evidence.R` | Prints what would be measured; opt-in to run. |
| `run_lot_scenarios.R` | How a line of therapy is created, scenario by scenario, and how many patients each rule decides. Thirty-four worked treatment histories with the lines the engine builds from them — each one produced by running the engine's own SQL over that patient, not predicted — plus a count per scenario. `SCENARIO_EXECUTE=TRUE` writes `out/lot_scenarios.xlsx` with the counts; without it a no-connection preview goes to `out/lot_scenarios_reference.xlsx` instead. |
| `R/lot_scenarios.R` | The catalogue: per scenario, the timeline, the lines the engine builds, the rule that decides it, and the counting SQL. The synthetic harness re-runs every timeline and fails if a line moves. |
| `run_lot_audit_counts.R` | Real-data frequencies for the shapes the LOT rules turn on. Not formal QC — investigation. Twelve counts. Three ask whether a regimen agent has any cover inside its line. Four size the transplant-ownership shapes: transplants in no line, tandem pairs whose first transplant is outside its line's window, and post-run-out transplants. One bands how close returning drugs sit to the 90-day release. The rest are durations and treatment outside every line. |
| `run_foldin_cells.R` | The MAP fold-in the study adopted, against a build without it, under `foldin_` prefixes. A prior line's agent returning after the current line's regimen window joins that line instead of splitting it, when exactly ONE agent advanced the line between that drug's two doses (`lot/LOT_RULES.md` 4.8). The returning drug joins the line's REGIMEN as well as its span — `LOT_BASE_MEDS`, `LOT_MED_CNT` and the med and class flags all carry it, so a folded line no longer reads as monotherapy. the fold reaches only the IMMEDIATELY PREVIOUS line's agents. What is counted is an AGENT, because the request is about drugs; transplants and CAR-T are outside it by scope and keep their own rules, so a line one opened overrides the fold. `APPLY_MAP_FOLDIN` is TRUE in `CONTRACT`, so the folded cell is the study's build and the reference is the deviation. `FOLDIN_EXECUTE=TRUE` builds and differences the pair, including a per-patient before/after line file. The sizing screen in `analysis/questions` reads the SAME scope — previous-line returns — but counts candidate boundaries before the fold's own conditions are applied, so it is larger than the population the rule moves. |
| `run_scenario_counts.R` | Whether the real data contains the shapes `lot/LOT_RULES.md` is written around. Eleven counts, each naming the section it belongs to, and each splitting the matching patients by what the build actually did with them — so "there are N of these" is followed by "and here is how they came out". A rule with no patients behind it is not wrong but is not carrying weight either; a count of zero where one was expected means the scenario has been mis-read, or the shape cannot arise for a reason nobody has written down. It counts finished output and does not execute patients through the engine, so a surprising split is a reason to look at the rule, not proof that the rule fired. |
| `tests/` | One suite per measurement, each reading its SQL as a string. |
| `out/` | Generated. Nothing reads it back. |

It counts **boundaries**, not lines. Boundaries added minus boundaries removed
is not a line count: moving a boundary changes which line an exposure falls in,
whether an agent is inside an induction window, regimen membership,
discontinuation dates and every later line number.
