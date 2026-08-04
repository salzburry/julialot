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
| `as_asked` | every exposure judged, including one with a transplant coded on it |
| `yield_to_sct` | the same, with a coded transplant left to the SCT rule |

The two mode names describe the transplant reading, which is what separates
them. Neither is the request implemented to the letter: on B.2 both take the
narrow reading described below.

Two readings rather than one, because the request leaves a question open. High-
dose melphalan is transplant conditioning, so a melphalan claim and an AUTO
procedure code are often the same clinical event - and the transplant rule
already fires on it. The request does not say which rule should win. Rather than
picking one, both are built and set against each other.

The reference cell is built, not read off an existing run. A run already under
the study prefix may have been built with settings that have since moved, and
every number here is a difference from that one.

All three, or none. A run where one mode failed still produces a reference and
one comparison, which reads like a finished experiment and is not one - the
transplant question has not been looked at. The runner stops instead.

## What is read off them

The nine figures the sensitivity sweep uses, so a melphalan cell and a threshold
cell can be read side by side, plus four about this rule:

| | |
|---|---|
| `n_melp_add` | lines ended by melphalan as an added medication |
| `n_melp_lines` | lines whose regimen contains melphalan |
| `n_sct_auto_end` | lines ended by an autologous transplant |
| `n_pat_with_melp` | patients with any melphalan line |
| `n_b2_line_starts` | MED-started lines whose start is a B.2 second dose |
| `n_b2_melp_only` | ...of those, the ones no other agent would have started |

Those four are where the double-count shows. If `as_asked` ends more lines by
melphalan than `yield_to_sct` does and the transplant ends correspondingly
fewer, the two rules were firing on the same events.

Beside them, the two modes are compared patient by patient - a patient counts as
differing when their line count, or any line's start, end or end reason, is not
the same under both readings. That is the number the transplant question turns
on, and subtracting totals does not give it: the SCT rule may win the end-reason
priority anyway, one moved boundary can shift several later lines, and two
patients moving opposite ways cancel. The aggregate table is the downstream
consequence of the two interpretations; it is not a count of the events where
both rules fired.

## The three builds have to have seen the same world

One cohort table and one cohort prefix is not enough, because a table name is
not a cohort attempt. Re-running the cohort build under the same prefix replaces
`NDMM_COHORT` in place - so a reference built over attempt A and two cells built
over attempt B all complete, all look right, and the A-to-B difference is
reported as the effect of melphalan. The same goes for a production code list
edited between cells, for the LOT code itself, and for the study window.

LOT already records all of it, across three tables rather than one:
`COHORT_RUN_ID` and `COHORT_STAMP` with the code fingerprint and study window in
`LOT_RUN_METADATA`, every code list's md5 in `LOT_CODELIST_METADATA`, and
`CONTRACT_DEVIATIONS` in `LOT_BUILD_STATUS` - which is deliberately not a
metadata column, because the status row is the one every downstream reader uses
to decide which run owns a prefix. It is read back rather than assumed, and a
mismatch stops the run naming the field and the cell.

Each cell is also held to being the algorithm it claims: the reference recording
no deviation at all, each mode recording `apply_melp_rule` set to the mode that
cell is for, and neither recording anything else. Three separate processes, so a
second setting reaching one of them would otherwise be read as the rule's
effect.

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
- INJECT the exposures the rule advances at and the engine has no candidate for:
  the later dose of a 180-day-or-more pair at its own date (A.2, B.3), and the
  first dose of a B.1 pair.

A.1 needs neither. Where the engine already opens B.1's boundary, the injected
row is the same (patient, date, drug) tuple and the UNION folds the two
together.

### What B.2 does and does not do

Suppressing B.2's boundary stops melphalan ending the line early.
It does not hold the line open to the second dose.

A line's discontinuation date is its base agents' last cover, and a melphalan
first seen outside the induction window is not a base agent - so it does not
extend that date. Take a line starting on day 0 whose base regimen runs out on
day 120, with melphalan on day 100 and again on day 170. Not advancing at day
100 removes the boundary melphalan would have made; the regimen still runs out
on day 120 for reasons that have nothing to do with melphalan, and the day-170
dose starts the next line under the ordinary new-therapy rule.

The rule as written says both doses stay in the current line. Getting that would
need melphalan to join a regimen whose induction window it never entered - a
concept the algorithm does not have, and a change to what a regimen means rather
than a setting. It is a clinical decision, so it is open question 6 in
`questions/melphalan_lot_rule.md` rather than something decided here.

`n_b2_line_starts` is what makes it decidable on a number, and it is the B.2
population rather than a proxy for it. A line counts only when all four hold:

1. the previous line ended by running out;
2. melphalan started this line - the exposure is on the start date and the
   start type is `MED`, because the same-day tie-break is
   `SCT_ALLO > CART > SCT_AUTO > MED` and an AUTO coded on the melphalan date
   makes the line the transplant's;
3. the exposure immediately before it sits in the previous line, outside
   that line's own induction window, which makes it a B branch and not an A;
4. the two are 60 to 179 days apart.

Any one of those alone lets in lines that have nothing to do with B.2 - a line
DARA started, with melphalan merely joining its induction window, would satisfy
"starts after a runout and has melphalan in the regimen" without a B.2 pair
anywhere.

`n_b2_melp_only` is the subset that answers the counterfactual, and it is a
different question. `LOT_START_TYPE = 'MED'` says a medication won the same-day
tie-break, not *which* one: the engine takes `d_MED` as the earliest qualifying
non-steroid agent and does not keep the drug. So if daratumumab also starts on
the melphalan date, that line exists under either B.2 reading and is no evidence
for the choice. `n_b2_melp_only` drops those - it counts the lines where nothing
else could have started them, and those are the ones that would not exist under
the other reading.

It is a lower bound on purpose. `med_cand` also passes over the previous line's
own agents expanded by permissible substitutes, and that expansion is a session
view inside the build rather than a table this can read - so an agent that is
only a substitute for a previous-line drug counts here as another starter when
the engine would have ignored it. That direction drops a line rather than
inventing one.

The pair is the immediately preceding exposure because that is the pair the
engine judged: it uses `lead()` over the ordered exposures, so it only ever
looks at consecutive ones. Matching any earlier exposure in range would count
pairs the rule never saw - exposures on days 100, 160 and 250 give the engine
100-160 and 160-250, and a range join would also match 100-250 and report one
line twice.

Under the other reading the `n_b2_melp_only` lines would not exist.

"Inside induction" is this exposure's date against this line's induction end -
not whether melphalan is in the regimen. The two are the same thing only for the
first dose. A patient dosed on day 10 and again on day 100 has melphalan in the
base regimen throughout, but the day-100 dose is outside the window and starts a
B branch; reading it off the regimen would call it A and lose the boundary. The
induction end is the expression the step itself uses to bound its candidates,
handed in rather than restated, so the rule and the engine cannot disagree about
where the window closes - at LOT1's 60 days, LOT2-5's 30 and a CART-started
line's 45 alike.

B.1 needs an injected boundary for the same reason. Outside induction with the
next dose inside 60 days, the rule advances at that dose - and where an earlier
dose already put melphalan in the regimen the engine opens no boundary at any
melphalan date in that line, so B.1's would simply be lost.

LOT1 is corrected in `06_lot1_end.R` rather than in `04_lot1_base.R`, because
`yield_to_sct` needs `tx_auto_dates` and that view is built in `05_sct.R`.
Nothing between the two reads the add-med columns, so the lines are the same
either way.

## Off is the absence of the rule, not a setting of it

`APPLY_MELP_RULE` is blank in `config.csv` and blank in `CONTRACT`. Blank, every
hook emits an empty string, and the SQL the engine builds is the SQL it built
before this file existed.

`tests/test_aug1_melp.R` holds that directly rather than by inspection: it puts
each hook's off value back into the step text and requires nothing melphalan to
remain. So a hook that starts returning something other than "" fails it, and
the two step files are checked for having exactly the hooks they should and no
others.

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
