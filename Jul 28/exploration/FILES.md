# Exploration

Work that is **not** in the study's numbers: a proposed rule the build does not
apply, and the measurements that ask whether the rules it does apply are the
right ones.

Nothing here is part of a study run, and nothing here can become one by
accident. The two things that build — the sensitivity sweep and the melphalan
cells — write to throwaway prefixes of their own, are opt-in, and launch with
`LOT_CONTRACT_OVERRIDE=TRUE`, which writes `CONTRACT_DEVIATIONS` into that run's
status row. Every reader in the delivery refuses a run carrying one.

That is the boundary this folder exists to make visible. `lot/` is what the
study ships; this is what was asked about it.

| | |
|---|---|
| `exploration/melphalan/` | two proposed line-advancing rules, each built as complete runs and differenced |
| `exploration/lot/` | benchmarks, the definition comparison, the sensitivity sweep, stockpiling, re-challenge, the melphalan measurement, and the audit counts |

The rule vignettes are **not** here. They are the machine-checked twins of the
scenarios in `lot/LOT_RULES.md`, so they stay with the rules, in
`exploration/lot/`.

---

## `exploration/melphalan/` — an exploration, not a rule

**Nothing here is in the study's numbers.** `apply_melp_rule` is pinned blank in
`CONTRACT`. Blank emits no melphalan SQL at all,
and every cell that names a mode records a contract deviation that the
questions, the dashboard and the benchmark harness all refuse. This is why the
proposal is described here, in the folder inventory, and not in `LOT_RULES.md`:
`LOT_RULES.md` is the confirmed rules, and this is not one of them.

What it is: a study-team proposal that a melphalan (`MELP`) administration
should advance the line on windows of its own, built as three complete LOT runs
— `reference`, `as_asked`, `yield_to_sct` — and differenced. Three builds rather
than arithmetic on a finished run, because the engine is sequential: a line's
end date sets the next line's start, which sets that line's induction window,
which decides which drugs join its regimen, which sets its discontinuation date,
which decides whether the line after it starts at all.

All three or none: a run where one mode failed reads like a finished experiment
and is not one. Cells write to `melp_reference_`, `melp_as_asked_` and
`melp_yield_to_sct_`, and a plan that would write to the study's own prefix is
refused.

The study team's later note offered a SIMPLIFIED fallback, and that is a
separate package with its own two cells — see `run_melp_simple.R` below. The
two packages answer different questions and neither replaces the other.

| path | what it does |
|---|---|
| `run_aug1_melp.R` | Builds the comparison as three complete runs rather than estimating it. Prints the plan by default; `AUG1_EXECUTE=TRUE` builds. |
| `run_melp_simple.R` | The study team's SIMPLIFIED fallback, as its own two builds under `melp_simple_` prefixes: the contract build, and a rule where a melphalan course of 28 days or fewer outside induction does not advance a line on its own — unless a new agent starts inside the course, in which case the next line starts on the melphalan date. `MELP_SIMPLE_EXECUTE=TRUE` builds; the 28-vs-30-day cap is an open question, answered by rebuilding with `MELP_SIMPLE_COURSE_DAYS=30`. |
| `R/cells.R` | Which builds, what is read off them, and the checks that they saw the same cohort, the same code lists, the same code and the same window. Shared by both packages. |
| `R/scenarios.R` | The study team's four worked patients, held as data. |
| `run_melp_scenarios.R` | Runs those scenarios through the rule the engine ships — the decision is lifted out of the generated SQL rather than restated — and exits non-zero if any of them moves. No connection. |
| `read_melp_metrics.R` | Reads the comparison off cells that are already built. |
| `read_melp_asks.R` | The study team's three questions, off built cells. Question 1 writes three files: each cell's own median, the same patient's line paired across cells, and the change in how many lines a patient ends up with. |
| `read_melp_decisions.R` | What each decision the rule was built out of is worth, as a number per cell. Block 2 — melphalan doses in no line — is the one to read first. |
| `tests/test_aug1_melp.R` | That off is the absence of the rule, and the branch decision checked against the proposal. |

The rule itself is not in this folder — it is `lot/engine/R/melp_rule.R`,
because the engine builds the lines and the rule needs each line's own induction
window, which exists only while that line is being built. It is off by default
and off emits nothing.

### The proposal

An exposure is one administration; doses less than `melp_exposure_days` (30)
apart are the same exposure. Consecutive exposures are judged as a pair, on the
gap between them and on whether the first sits inside the line's induction
window:

| Branch | Condition | Effect | Against the engine with the rule off |
|---|---|---|---|
| A.1 | inside induction, gap < 180 | no boundary | agrees below a 90-day gap; differs at or above one, where the returning-drug release already advances the later dose |
| A.2 | inside induction, gap ≥ 180 | the later dose advances the line | agrees — a 180-day gap is past the 90-day release, so the engine already advances there |
| B.1 | outside induction, gap < 60 | this dose starts a line | agrees, unless an earlier dose put melphalan in the regimen and it came back inside 90 days — then the engine opens no boundary and the rule injects one |
| B.2 | outside induction, 60 ≤ gap < 180 | no boundary | differs — today the first dose advances the line, and at a 90-day gap or more so does the second |
| B.3 | outside induction, gap ≥ 180 | the later dose advances the line | differs — today both do, and the rule keeps only the later one |

The right-hand column turns on the **returning-drug release**, which is why the
gap matters twice. A drug in the line's own regimen cannot start a line while it
is still being taken, but `map_discon_gap_days` (90) between one episode and the
next makes the later one a restart, and `lot/engine/R/prior_regimen.R` releases a
restart to open a line like any other drug's. So the engine is not frozen after
the first dose, and a branch that reads as "no boundary" is only a change where
the engine would otherwise have opened one.

It moves in both directions, so the net effect on line counts is not derivable:
A.1 and B.2 and B.3 remove boundaries the engine opens, A.2 removes none and
B.1 adds one on a narrow population, and which wins depends on how many patients
sit in each branch. `run_melphalan_rule.R` in `exploration/lot/` reports the
branch counts off a finished run without rebuilding anything.

**Two readings of a coded transplant**, which is why three cells are built
rather than two. High-dose melphalan is transplant conditioning, so a melphalan
claim and an AUTO code are often the same clinical event and the transplant rule
already fires on it. `as_asked` judges every exposure regardless; `yield_to_sct`
leaves an exposure with an AUTO within `melp_sct_days` (14) to the transplant
rule, so the melphalan rule fills only the gap where a transplant left no
procedure code. Every output row records which mode produced it.

**What B.2 does.** Two things, because the request asks for two.

Suppressing B.2's boundaries stops melphalan ending the line at either dose.
That alone does not keep the second dose *inside* the line. A line's
discontinuation date is its base agents' last cover, and a melphalan first seen
outside the induction window is not a base agent. So where the regimen runs out
between the two doses, the line ends there and the second dose falls outside it
— and the same rule refuses that dose as a line start, so it lands in no line at
all.

The request says both doses stay in the current line, so the line is carried to
the second dose. The carry rides on the run-out (`melp_hold` in
`lot/engine/R/melp_rule.R`) rather than on an end reason of its own. That keeps
the 90-day confirmation measured from the dose, and leaves every other end still
outranking it.

### What has to be settled before it could be built for real

The measurement program picks an answer to each of these so it can run. The
answer it picks is named. An assumption is not a decision.

1. Does the rule apply to melphalan alone, or to any agent used as transplant
   conditioning? As written it is drug-specific, which is a first for this
   algorithm — every other rule is about classes, windows and gaps. *The program
   assumes melphalan alone, through `melp_med_abbr`.* **Open.**

2. What happens when the transplant procedure code is also present? The AUTO
   rule and this rule would both fire on one clinical event. *The program runs
   both readings and writes the mode onto every row.* **Open.**

3. Is 30 days the exposure threshold, or 28? The build's medical day supply is
   28, so episodes already merge on that boundary. *The program uses 30.*
   **Confirmed by the worked examples.**

4. Third and later exposures. The proposal is written for a first and a next
   dose. *The program judges consecutive pairs.* **Confirmed by examples 3 and
   4.**

5. Does it apply at every line, or only at 1L? The induction window is 60 days
   at 1L and 30 later, so the branches land differently. *The program applies it
   at every line, against that line's own window.* **Confirmed by examples 3 and
   4.**

6. In B.2, does "both doses stay in the current line" mean the line is held
   open to the second dose? **Settled by the request**, which says in words
   that both doses stay in the current line. The line is carried to the second
   dose — see *What B.2 does* above.

   `n_b2_line_starts` checks it: MED-started lines whose start is a B.2 second
   dose, with `n_b2_melp_only` the subset no other agent could have started.
   Under the rule those lines should not exist, so a rule cell should count
   zero.

Both modes implement the branch table. What the mode names describe is the
transplant reading — the one thing the request does not cover — and that is the
only difference between them.

## `exploration/lot/` — measuring the algorithm

Five asks against the rules, plus the audit counts. None of it has executed
against a warehouse, so nothing here is an observed output. Every runner prints
what it would measure and needs no connection until told to execute, and each
one resolves which run actually wrote the tables before measuring them.

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
| `R/melphalan.R` | Measures the melphalan rule against a finished run without applying it. Writes `MELP_RULE_EXPOSURES`, `MELP_RULE_BRANCHES`, `MELP_RULE_IMPACT`. |
| `run_melphalan_rule.R` | Prints the rule and its settings; `MELP_EXECUTE=TRUE` measures it. |
| `run_lot_scenarios.R` | How a line of therapy is created, scenario by scenario, and how many patients each rule decides. Thirty-one worked treatment histories with the lines the engine builds from them — each one produced by running the engine's own SQL over that patient, not predicted — plus a count per scenario. `SCENARIO_EXECUTE=TRUE` writes `out/lot_scenarios.xlsx` with the counts; without it a no-connection preview goes to `out/lot_scenarios_reference.xlsx` instead. |
| `R/lot_scenarios.R` | The catalogue: per scenario, the timeline, the lines the engine builds, the rule that decides it, and the counting SQL. The synthetic harness re-runs every timeline and fails if a line moves. |
| `run_lot_audit_counts.R` | Real-data frequencies for the shapes the LOT rules turn on. Not formal QC — investigation. Twelve counts. Three ask whether a regimen agent has any cover inside its line. Four size the transplant-ownership shapes: transplants in no line, tandem pairs whose first transplant is outside its line's window, and post-run-out transplants. One bands how close returning drugs sit to the 90-day release. The rest are durations and treatment outside every line. |
| `run_foldin_cells.R` | The study team's MAP fold-in, as its own two builds under `foldin_` prefixes: the contract build, and a rule where a prior line's agent returning after the current line's regimen window joins that line instead of splitting it. Two readings inside that are TAKEN, not settled, and both are disclosed in the outputs: the line's SPAN owns the returning drug — `LOT_BASE_MEDS` and the drug counts do not change — and the fold reaches agents of EVERY earlier line, not only the immediately previous one. The engine carries it as the gated `APPLY_MAP_FOLDIN` mode, pinned FALSE, so the study run is untouched. `FOLDIN_EXECUTE=TRUE` builds and differences the pair, including a per-patient before/after line file. The sizing screen in `analysis/questions` counts previous-line returns only, so its count is a LOWER BOUND on the cell's population. |
| `run_scenario_counts.R` | Whether the real data contains the shapes `lot/LOT_RULES.md` is written around. Eleven counts, each naming the section it belongs to, and each splitting the matching patients by what the build actually did with them — so "there are N of these" is followed by "and here is how they came out". A rule with no patients behind it is not wrong but is not carrying weight either; a count of zero where one was expected means the scenario has been mis-read, or the shape cannot arise for a reason nobody has written down. It counts finished output and does not execute patients through the engine, so a surprising split is a reason to look at the rule, not proof that the rule fired. |
| `tests/` | One suite per measurement, each reading its SQL as a string. |
| `out/` | Generated. Nothing reads it back. |

It counts **boundaries**, not lines. Subtracting boundaries added from
boundaries removed does not give a line count: moving a boundary changes which
line an exposure falls in, whether an agent is inside an induction window,
regimen membership, discontinuation dates and every later line number.
