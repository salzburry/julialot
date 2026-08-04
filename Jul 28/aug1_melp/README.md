# The melphalan rule, built

The August-1 follow-up to the melphalan ask. The July request is recorded in
`questions/melphalan_lot_rule.md` and measured by `lot_validation`'s
`run_melphalan_rule.R`; neither is changed by anything here.

```
# print the plan; touches nothing, needs no connection
INPUT_COHORT_TABLE=ndmm_NDMM_COHORT Rscript aug1_melp/run_aug1_melp.R

# build it
DATABRICKS_PWD=... INPUT_COHORT_TABLE=ndmm_NDMM_COHORT COHORT_PREFIX=ndmm_ \
  AUG1_EXECUTE=TRUE Rscript aug1_melp/run_aug1_melp.R
```

## What was asked, and what was missing

The July answer set the rule beside the current build branch by branch, counted
how many patients each branch touches, and counted the line boundaries the rule
would add and remove. What it could not give was the resulting line structure -
lines per patient, reach to 2L and 3L, line lengths, regimens.

That was not a shortcut. The LOT engine is sequential: a line's end date sets
the next line's start, which sets that line's induction window, which decides
which drugs join its regimen, which sets its discontinuation date, which decides
whether the line after it starts at all. Move one melphalan boundary and every
line after it for that patient is different. No arithmetic on finished lines
recovers it. The only way to the adjusted structure is to build it.

So this program builds it.

## Three builds

| cell | what it is |
|---|---|
| `reference` | the contract build, unchanged |
| `as_asked` | the rule exactly as written |
| `yield_to_sct` | the same rule, with a coded transplant left to the SCT rule |

Two readings rather than one, because the request leaves a question open. High-
dose melphalan is transplant conditioning, so a melphalan claim and an AUTO
procedure code are often the same clinical event - and the transplant rule
already fires on it. The request does not say which rule should win. Rather than
picking one, both are built, and the difference between them is that question
answered in patients.

The reference cell is built, not read off an existing run. A run already under
the study prefix may have been built with settings that have since moved, and
every number here is a difference from that one.

## What is read off them

The nine figures the sensitivity sweep uses, so a melphalan cell and a threshold
cell can be read side by side, plus four about this rule:

| | |
|---|---|
| `n_melp_add` | lines ended by melphalan as an added medication |
| `n_melp_lines` | lines whose regimen contains melphalan |
| `n_sct_auto_end` | lines ended by an autologous transplant |
| `n_pat_with_melp` | patients with any melphalan line |

Those four are where the double-count shows. If `as_asked` ends more lines by
melphalan than `yield_to_sct` does and the transplant ends correspondingly
fewer, the two rules were firing on the same events.

## No direction is predicted

The sensitivity sweep writes down the expected sign before it runs and scores
itself against it. That works where a threshold moves a number one way and the
reasoning can be checked. This rule does not: A.2 adds boundaries, B.2 and B.3
remove them, and which wins depends on how many patients sit in each branch.
A prediction here would be a guess wearing a test's clothes.

The branch counts from `run_melphalan_rule.R` are the thing to read first. They
say how many patients are in each branch, which is what makes the direction of
these deltas interpretable rather than surprising.

## Where the rule lives, and why it is not in this folder

`lot/R/melp_rule.R`. It has to be inside `lot`: that package builds the lines
and reads nothing from a sibling, and the rule needs each line's own induction
window - which only exists while that line is being built.

It changes one thing. Which melphalan MAP rows may be an added medication, and
on what date:

- SUPPRESS an exposure the engine takes as an add and the rule does not:
  outside induction, next exposure 60 days or more away. That is B.2 and B.3,
  where the first dose does not advance.
- INJECT the exposure the rule advances at and the engine cannot see: the later
  dose of a 180-day-or-more pair, at its own date.

A.1 and B.1 need neither - there the rule and the engine already agree.

"Inside induction" is not measured with a datediff. A drug first seen inside a
line's induction window is a base agent of that line, so the base-meds join the
engine already makes answers it - at LOT1's 60 days, LOT2-5's 30, and a
CART-started line's 45 alike. A second measurement would be a second definition
of induction, and the two would drift.

LOT1 is corrected in `06_lot1_end.R` rather than in `04_lot1_base.R`, because
`yield_to_sct` needs `tx_auto_dates` and that view is built in `05_sct.R`.
Nothing between the two reads the add-med columns, so the lines are the same
either way.

## Off is the absence of the rule, not a setting of it

`APPLY_MELP_RULE` is blank in `config.csv` and blank in `CONTRACT`. Blank, every
hook emits an empty string, and the SQL the engine builds is the SQL it built
before this file existed. Two suites hold that from opposite sides:

- `validation/port/lot.R` undoes the two hooks as text and requires the step
  files to be `apr_30_2026`'s, line for line.
- `tests/test_aug1_melp.R` puts each hook's off value back into the step text
  and requires nothing melphalan to remain.

A hook that started returning something else passes the first and fails the
second. A hook edited in the step file fails the first and passes the second.

## What stops a cell being read as the study

`APPLY_MELP_RULE` is pinned in `CONTRACT`, so naming a mode is a contract
deviation and the build refuses it without `LOT_CONTRACT_OVERRIDE=TRUE`. With
it, the deviation is written into that cell's `LOT_BUILD_STATUS` row - the row
every reader in this folder already uses to resolve which run owns a prefix -
and the questions, the dashboard and the benchmark harness all refuse a run
carrying one. The five thresholds that say what the rule means are pinned too,
so moving one is also a deviation rather than a quiet change of algorithm.

Cells write to `melp_reference_`, `melp_as_asked_` and `melp_yield_to_sct_`.
`check_melp_plan()` refuses a plan that would write to the study's own prefix.

## What this still does not settle

Three of the five open questions in `questions/melphalan_lot_rule.md` are
assumptions here, not answers: melphalan alone rather than any conditioning
agent, 30 days rather than 28 for one administration, and consecutive pairs for
a patient with three or more exposures. Each is a setting, so changing one is a
cell rather than an edit - but each is still the study team's to settle.

The fourth, whether the rule applies at every line or only at 1L, is answered by
building it: it applies at every line, each against its own window.

The fifth - which rule owns a coded transplant - is what the two modes are for.

## Tests

```
Rscript tests/test_aug1_melp.R
```

No connection needed. The rule's decision is lifted out of the generated SQL and
checked branch by branch, rather than restated - a second copy would agree with
whatever the test believed.
