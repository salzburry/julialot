# What was fixed, and how

A log of the review and repair work on the LOT engine. One entry per defect: the
shape that showed it, what was wrong, and the fixture that now holds it.

Every entry was reproduced before it was fixed, by planting a patient and
running it through the engine's own emitted SQL. Every fix was then reverted to
check its fixture fails without it. Nothing here rests on reading the code alone.

## How a defect was found

Two adversarial sweeps, each attacking a different rule surface with planted
patients, and each finding checked by three independent reviewers before it
counted. 33 candidates were raised; 22 were refuted by the rules themselves —
usually because the behaviour is documented and the reporter had read one table
row and not the next. 11 survived.

## Fixed

| what was wrong | the shape | fixture |
|---|---|---|
| A confirmed short course got no boundary, so the returning drug opened a line 4.3 refuses | LOT2-5 candidates | `F34` |
| A returning drug that opened a line was invisible to the melphalan rule, so an earlier line claimed a course it did not own | CAR-T line, drug of line 1 returning inside it | `ZB1`–`ZB3x` |
| Line 1's first transplant was a melphalan boundary here while being none in the end cascade | first AUTO outside the 60-day window | `SJ1`, `W3` |
| A line judged a course whose cover ran out before it began, so the fold-in lost the dose history and a transplant line got a run-out before its own start | conditioning course, later re-challenge | `F36`, `SU1` |
| The same, for a course covering INTO the next line | course day 40-67, line 2 opening day 65 | `F37` |
| An allogeneic line read a course on its own date as an induction drug, so the line was started by a dose it then held out of its regimen | melphalan on the allograft date | `P0008` |
| An allogeneic line owned a tandem pair it cannot hold, leaving the partner in no line | AUTO on the allograft date, partner 100 days later | `P0007` |
| The next-line statement re-judged line 1's course without 3.4's first-transplant exemption | line 1's only AUTO on day 100 | `SW1`, `P0010` |
| Line 1 did not own its tandem pair when the first of the two fell outside the window | scenario `S11c` plus a course | `SX1` |
| QC check C2 called the melphalan injection a failure, which 4.7 authorises | the shipped fixture `SB` | `P0009` |

Three of these were caught by the delivery's own QC catalogue — checks `A7`,
`C4`, `E5` and `C2`, all severity `fail`. One of them fired on a fixture the
package already ships.

## Left open, on purpose

**Which ends a line first — the melphalan carry or an added medication?**
An allograft line one day after a suppressed course reads that course as
confirmed and takes no carry, leaving four days in no line. Bounding
confirmation by the line's own start fixes that half, and the carry then runs
past the next agent, which loses its line entirely. The cap that would settle it
is a rule nobody has been asked. `STUDY_TEAM_ASKS.md` section 7.

**An agent that opens no line still takes a course away from its line.**
`melp_taken` asks whether another agent got to a course first, but not whether
that agent could open a line. The bound wanted is the line's own run-out, and
the step computes that after the melphalan decision while reading the decision
to do it. Closing it is a change to the step's shape. `LOT_RULES.md` 4.7.

**A drug starting on the allograft date joins no line.**
The arithmetic sum of three separate rules, and already sized on real data as a
by-design outcome. The question is clinical, not technical: should peri-transplant
claims dated on the allograft day be excluded, or moved a day?

## Also done

Redundancy: one definition of the tandem relation instead of three copies, and
the melphalan decision is one function rather than a pass-through onto another.
The dead verdict fallback is gone.

Documentation: the package map, the scenario count, the fold-in screen's meaning
and the tandem window rule were each wrong and are corrected. Generated output no
longer dirties the working tree, and the runbook names the three R packages the
engine needs.

## A later sweep, on the plumbing rather than the rules

The sweeps above attacked the line rules. This one attacked what surrounds them
— settings, escaping, retries, generated names — where a defect is silent
because nothing clinical looks wrong.

| what was wrong | the shape | now |
|---|---|---|
| An integer setting of all digits that `as.integer()` cannot hold passed the check and became `NA` | `INDUCTION_WINDOW_DAYS=99999999999999999999` | refused, naming the overflow |
| `OBJECT_PREFIX` was pasted into every table name unchecked, while `PROJECT_WORK_SCHEMA` beside it was checked for exactly this | `OBJECT_PREFIX=a.b.c` makes a five-part name, found only after the session opened | refused unless it is a name a table can start with |
| `sql_count()` wrote `Inf` as the word and `1.5` as a decimal into BIGINT columns | one the warehouse rejects, the other it truncates in silence | both `NULL` |
| Two permanent-error patterns are ordinary English and appear inside transient messages | `Operation not allowed: transient lock` killed a recoverable run | an explicit retry hint from the server beats a generic substring |
| A criterion's name becomes a view name and an alias, unchecked | a criterion named `a-b` would fail in the warehouse's words, mid-build | refused at the name |
| An assertion whose expression *raised* took the whole suite down — no count, every later result lost | a mutation read as "not caught" because there was no `FAIL` line to find | `ok()` evaluates the condition itself and reports a raise as a failure |

The last one is why the others are worth recording: the harness was hiding how
well it worked.

Four surfaces were attacked and found already sound, which is worth as much as
the findings. The generated column names are guarded against collision,
quote injection and the reserved `CNT` — punctuation and spaces both become
`_`, and two abbreviations that would make one column stop the run. A fatal
code-list check cannot be waived from the environment. The contract override
records its deviation rather than hiding it. And a `DELETE`+`INSERT` retried as
one unit re-runs the `DELETE` on every attempt, so a lost acknowledgement
leaves one copy.

## The QC checks, run rather than read

The QC suite said it outright: *"Nothing here has run against a warehouse, so
what can be tested is the SQL as a string... The checks are generated with fake
table names and inspected."* All 37 checks — the ones that decide whether a LOT
build is trustworthy — were verified only as text. Text cannot tell a working
check from a `WHERE` that can never be true, and a check that cannot fail
reports "pass" on a real defect for ever.

`qc/tests/run_duckdb.py` now runs them. Each check is executed twice: against a
clean fixture, where it must count nothing, and against the same fixture with
the defect it describes planted in it, where it must count that and name it.
The 13 checks that read only `LOT_LONG_FINAL` are covered — every
`fail`-severity structural and end-reason check. All 13 pass both halves.

Five deliberate sabotages of the checks confirm the harness bites: inverting a
predicate, making one that can never be true, widening an allowed set, dropping
half a condition, and removing the id masking. Each is caught.

Two of the first plants were wrong, not the checks — B6 and B7 test a date
against the line's own start, not against the end reason, and both stayed
silent until the plant was corrected. That is the argument for running them
rather than reading them, made against the person writing the fixtures.

| what was wrong | now |
|---|---|
| `qc_outcome()` stopped the runner outright when a check returned no `N_BAD` column, losing every check after it | reported as that check's own error, which is the runner's own rule |
| An assertion whose expression raised took the suite down — no count, later results lost | `ok()` evaluates the condition and reports a raise as a failure, in the qc and validation harnesses as well |

Four surfaces were attacked and found already sound. Every check masks the
patient id it reports, proven by running rather than by reading. A duplicate
check id or an unknown severity is refused at load. The vignette catalogue
refuses a pair whose sides agree, an offset that does not straddle its
parameter, a parameter that does not exist and an anchor absent from the file
it cites. And `LOT_START_TYPE` really is the four values A5 allows —
`SCT_CART` and `SCT_AUTO_CONT` are end reasons, not start types.

## What this does not prove

The harnesses run the real emitted SQL, but through DuckDB rather than Spark, so
a Spark-only failure would not show. No run has touched a warehouse.
