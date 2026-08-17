# Synthetic-population runs

Opt-in. **Not in the merge gate** — it needs `duckdb` and `sqlglot`, which
nothing else here does, and 600 patients take about twenty seconds.

```
python3 validation/synthetic/run_synthetic.py
python3 validation/synthetic/run_synthetic.py --seed 7 --n 2000
```

## What it is

Random patients, from a fixed seed, pushed through **every statement the LOT
build issues, in order** — LOT1, the transplant step, the end cascade, LOT2
through LOT5, then the 2L/3L cohorts. The SQL is emitted from the step files
rather than copied, so it is the SQL that ships; edit a step and the tested
text changes with it.

It does **not** say what any individual patient's answer should be. That is the
thing an author gets wrong — and gets wrong identically in the fixture and in
the expectation, so it passes. It checks **invariants** instead: properties that
hold whatever the rules are.

> a line ends on or after it starts · length matches the dates · nothing
> outside observation · line numbers contiguous from 1 · each line starts after
> the previous ends · end reasons from the known set · `DISCONTINUATION`
> carries a date · no unconfirmed discontinuation (B8) · nothing past the cap ·
> no transplant inside a line's own window that the line ended before (B5c) ·
> 3L ⊆ 2L · a cohort's index is that line's start · no cohort row without both
> enrolment flags

One number is printed and not failed: transplants that landed in no line at
all. `E5` in the QC catalogue is a warn for the same reason — one of those can
be an event past the end of the data, which is data rather than a defect. What
matters is the number moving between two runs.

## Four patients that are not drawn

Everything else is random. That is the point, and it means a rule reached only
by a narrow combination of dates can go untested for a whole run. Four patients
are built by hand so they are always present: a regimen that runs out early
with a transplant later in the same window, the same one day outside it, a
tandem partner far beyond the window, and an allograft that ends the line
before an in-window transplant. They are patients, not fixtures — nothing says
what their lines should come back as.

## Two things it tells you that a green suite will not

**Coverage.** "Every invariant holds" over a population that never reaches a
rule proves nothing about that rule. The coverage block counts how many
patients reached each rule, and a bucket reading zero is called out as a green
that tested nothing.

**Regression.** `--snap` writes a canonical snapshot, `--base` diffs against
one. That is the check to run around a fix:

```
python3 validation/synthetic/run_synthetic.py --snap /tmp/before.json
# ... make the change ...
python3 validation/synthetic/run_synthetic.py --snap /tmp/after.json --base /tmp/before.json
```

Every row that moved has to be a row the change meant to move. A clean fix
looks like one transition type, no lines appearing or disappearing, and no
cohort membership change. Anything else in that list is collateral damage.

The same mechanism differences a run against itself under a changed setting.
`CONFIRM_DAYS` and `CART_RULE` are read from the environment by `emit_chain.R`,
so:

```
CONFIRM_DAYS=0 python3 validation/synthetic/run_synthetic.py --base /tmp/before.json
```

answers "what does rule B actually do to the numbers" by measurement.

The two settings give opposite signatures, which is the point of looking:

| | rule B off | CAR-T rule off |
|---|---|---|
| lines in one run only | **0** | **51** |
| transition types | **1** | 24 |
| 2L / 3L membership | unchanged | 19 / 16 patients |

Rule B moves `STUDY_END` → `DISCONTINUATION` and nothing else — a contained
change, and the same shape on every seed tried. Turning the CAR-T induction
rule off creates and destroys lines, shifts every later line for those
patients, and moves cohort membership with them. Both match what
`lot/LOT_RULES.md` says they do; the first is what a safe fix looks like and
the second is what a rule change looks like. A diff that sprawls when you
expected it contained is the signal to stop.

## What it cannot do

Two steps are absent from the chain, and for the same reason. `05_sct.R` builds
the AUTO transplant dates and `03_mma_map.R` builds the medication episodes, and
both do it with Spark's `aggregate()` folding a sorted array into a
`named_struct` accumulator. `sqlglot` translates that to duckdb's `list_reduce`
happily — the blocker is duckdb, whose `list_reduce` requires the accumulator to
be the list's own element type, so a fold from `DATE[]` into a struct will not
bind. `tx_auto_dates` and `map_stacked` are inputs to the harness instead.

So none of `05_sct.R`'s 13-day claim windowing, tandem-boundary date selection
or 60-day gap merging is exercised here, and neither is `03_mma_map.R`'s
stockpiling pushout. Running the shipped SQL on Spark would cover both; pyspark
is not installable in this environment, so it is not a route today.

duckdb is also not Spark. The dialect probe at the top of each run checks the
one semantic this code leans on hardest (`datediff(a, b)` is `a - b`). One
divergence is corrected rather than probed: Spark's `concat_ws` flattens an
array argument and duckdb's stringifies it, so `concat_ws(' ', sort_array(...))`
came back as `[LEN, MELP]` and every regimen-string predicate downstream matched
nothing. `to_duckdb()` rewrites it to `array_to_string`. Beyond those, it is a
translation, and a translation can be faithful on the cases you thought to write
and not on the ones you did not.

Nothing here has seen a warehouse row. No count, no attrition figure and no
execution plan is verified by it.
