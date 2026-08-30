# Synthetic-population runs

In the merge gate, as the `harnesses` job of the Jul 28 tests workflow. It is
a job of its own because it needs Python with `duckdb` and `sqlglot`, which
nothing else here does. Locally:

```
pip install duckdb sqlglot
python3 validation/synthetic/run_synthetic.py
python3 validation/synthetic/run_synthetic.py --seed 7 --n 2000
```

`run_synthetic.py` is the population run; 600 patients take about twenty
seconds. Four more harnesses in this folder plant named patients and assert
the lines they should produce — `run_melp_simple.py` (melphalan),
`run_map_foldin.py` (MAP fold-in and the shipped QC over planted patients),
`run_lot_scenarios.py` and `run_aug15_screen.py`. CI runs all five. They are
where every patient-level defect found in review came from, so run them
around any engine change, not just the gate.

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
> no transplant in no line at all (E5) ·
> 3L ⊆ 2L · a cohort's index is that line's start · no cohort row without both
> enrolment flags

## ...and the shipped QC catalogue, on the same patients

`emit_qc.R` asks `lot/qc/R/checks.R` for its own SQL and that SQL runs here,
bound to the tables this harness builds. A `fail` check with a row breaks the
run like any invariant above; `warn` and `info` are counted and printed.

This replaced two Python rewrites of QC predicates, which proved the rewrites.
A rewrite can be right while the shipped check is wrong, and both were:

| check | on 400 patients | what it was |
|---|---|---|
| `A7` | **65** rows | every AUTO-started line with no drug in its window — a shape the build produces on purpose |
| `C2` | **11** rows | every regimen drug returning after a confirmed gap — the rule `prior_regimen.R` implements |

Both are `fail` severity, so both would have blocked every warehouse run, and
neither was reachable while the harness ran copies.

Four checks cannot be answered against the patient population and say so rather
than passing quietly: three need the attrition funnel or the metadata row, which
`build_lot.R` writes outside the emitted chain, and `D2` reads per-source
run-out dates that `map_stacked` carries in the warehouse and not as a fixture
here.

**All four are `fail` severity**, so a green patient run is not the same
sentence as "the catalogue passed".

`F2` and `F3` are covered anyway, by `qc_scenarios.py` — the shipped SQL run
against hand-built attrition tables, each wrong in one specific way, asserting
the check notices. Those have expected answers, and that is right here: what is
under test is the check, not the algorithm. `E1` is there for a different
reason — it reads the raw per-line flags, and a correct build cannot produce
the double flag it looks for, so a patient run can only ever show it silent.

The scenarios earn their place. Against the versions that shipped before them,
five passed and should not have: a missing final funnel row, a duplicated one,
a line count that disagrees while the patients match, the zero progression rows
for lines nobody reached, and a row above `max_lot`.

`D2` and `F4` remain answerable only by `run_lot_qc.R` against a warehouse, and
`03_mma_map.R` and `05_sct.R` are fixture inputs rather than executed logic, for
the duckdb reason under *What it cannot do*.

`permissible_subs` used to be a third gap — empty, so the substitute paths had
static assertions and no executable patient. It now carries one pair, `BORT` →
`CARF`. One row, because the engine expands a pair in both directions itself
and a fixture that declared the reverse too would hide it if that stopped being
true. The pair is not a real biosimilar relationship; what is under test is the
equivalence machinery, which only needs a declared pair to have something to
do. It is not decoration: against the same seed with the table empty, 102 lines
appear or disappear, 207 change value, and 2L/3L membership moves for 22 and 27
patients.

## Eighteen patients that are not drawn

Everything else is random. That is the point, and it means a rule reached only
by a narrow combination of dates can go untested for a whole run. Eighteen
patients are built by hand so they are always present.

`P0000`–`P0006` are the transplant shapes: a regimen that runs out early with a
transplant later in the same window, the same one day outside it, a tandem
partner far beyond the window, an allograft that ends the line before an
in-window transplant, two CAR-T-started lines with a transplant either side of
the consolidation window, and a transplant landing before the patient's first
line. That last one the generator cannot draw — its transplants start at least
100 days after index and its first medication by day 70 — and it is what
decides whether an unowned transplant is a defect or a reconciliation number.

`M0001`–`M0011` are the melphalan shapes. Melphalan is not in any random
history, so without them the whole rule is unreachable and every mode emitted
different SQL over identical output. They cover the five in/out-of-induction
cases, a no-melphalan control, and the cases where the line ends between or
before the suppressed doses.

They are patients, not fixtures — nothing says what their lines should come
back as.

## The settings the checks are judged by

`CONFIRM_DAYS` and `CART_RULE` reach the emitted SQL through `emit_chain.R`,
and the checks read the same two values. They have to: at `CONFIRM_DAYS=0` a
run-out is confirmed the moment it happens, and a check holding the contract's
90 reported 53 legitimate discontinuations as failures on a 300-patient run.
At `CART_RULE=FALSE` the engine has no in-induction exemption, and a check that
kept one would excuse an orphan the build really produces.

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
