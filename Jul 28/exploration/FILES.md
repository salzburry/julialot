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
| `exploration/melphalan/` | a proposed line-advancing rule, built as three complete runs and differenced |
| `exploration/lot/` | benchmarks, the definition comparison, the sensitivity sweep, stockpiling, re-challenge, the melphalan measurement, and the audit counts |

The rule vignettes are **not** here. They are the machine-checked twins of the
scenarios in `lot/LOT_RULES.md`, so they stay with the rules, in
`exploration/lot/`.

---

## `exploration/melphalan/` — an exploration, not a rule

**Nothing here is in the study's numbers.** `apply_melp_rule` is pinned blank in
`CONTRACT`, blank generates the SQL the engine generated before this existed,
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

| path | what it does |
|---|---|
| `run_aug1_melp.R` | Builds the comparison as three complete runs rather than estimating it. Prints the plan by default; `AUG1_EXECUTE=TRUE` builds. |
| `R/cells.R` | Which three builds, what is read off them, and the checks that they saw the same cohort, the same code lists, the same code and the same window. |
| `R/scenarios.R` | The study team's four worked patients, held as data. |
| `run_melp_scenarios.R` | Runs those scenarios through the shipped rule — the decision lifted out of the generated SQL rather than restated — and exits non-zero if any of them moves. No connection. |
| `read_melp_metrics.R` | Reads the comparison off cells that are already built. |
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

| Branch | Condition | Effect | Against the shipped engine |
|---|---|---|---|
| A.1 | inside induction, gap < 180 | no boundary | agrees |
| A.2 | inside induction, gap ≥ 180 | the later dose advances the line | differs — today the repeat dose extends the line's run-out instead |
| B.1 | outside induction, gap < 60 | this dose starts a line | agrees, incidentally |
| B.2 | outside induction, 60 ≤ gap < 180 | no boundary | differs — today the first dose advances the line |
| B.3 | outside induction, gap ≥ 180 | the later dose advances the line | differs — today the first dose does |

It moves in both directions, so the net effect on line counts is not derivable:
A.2 makes more lines, B.2 and B.3 make fewer, and which wins depends on how many
patients sit in each branch. `run_melphalan_rule.R` in `exploration/lot/` reports
the branch counts off a finished run without rebuilding anything.

**Two readings of a coded transplant**, which is why three cells are built
rather than two. High-dose melphalan is transplant conditioning, so a melphalan
claim and an AUTO code are often the same clinical event and the transplant rule
already fires on it. `as_asked` judges every exposure regardless; `yield_to_sct`
leaves an exposure with an AUTO within `melp_sct_days` (14) to the transplant
rule, so the melphalan rule fills only the gap where a transplant left no
procedure code. Every output row records which mode produced it.

**What B.2 does and does not do.** Suppressing B.2's boundaries stops melphalan
ending the line at either dose. It does not hold the line open to the second
dose. A line's discontinuation date is its base agents' last cover, and a
melphalan first seen outside the induction window is not a base agent, so it
does not extend that date — a line whose regimen runs out between the two doses
still ends there, and the second dose falls in whatever line follows.

### What has to be settled before it could be built for real

The measurement program had to pick an answer to some of these to run at all.
Where it did, the assumption is named. An assumption is not a decision.

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

6. In B.2, does "both doses stay in the current line" mean the line has to be
   held open to the second dose? Half of this is settled — the worked examples
   say the second dose starts no line, and the boundary is removed at both
   doses. What is left open is whether the line has to be held open to reach it,
   which would need melphalan to join a regimen whose induction window it never
   entered: a change to what a regimen means rather than a setting, and a
   clinical decision. **Open**, and `n_b2_line_starts` is the number that
   settles it — MED-started lines whose start is a B.2 second dose, with
   `n_b2_melp_only` the subset no other agent could have started.

Neither mode is the proposal implemented to the letter: the mode names describe
the transplant reading, and on B.2 both take the narrow one above.

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
| `run_lot_audit_counts.R` | Real-data frequencies for the LOT assignment findings. Not formal QC — investigation. Eight counts, three of them sizing the post-end regimen defect: how many lines by line number and end reason, how often the stranded agent also starts a later line, and how often the run-out extends past the transplant that ended the line. The defect itself is recorded in `lot/LOT_RULES.md` §3.3 and §14.2, and as question 1 in `KNOWN_ISSUES.md`, so it survives this script being moved or retired. |
| `tests/` | One suite per measurement, each reading its SQL as a string. |
| `out/` | Generated. Nothing reads it back. |

It counts **boundaries**, not lines. Subtracting boundaries added from
boundaries removed does not give a line count: moving a boundary changes which
line an exposure falls in, whether an agent is inside an induction window,
regimen membership, discontinuation dates and every later line number.
