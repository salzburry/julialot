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

## What this does not prove

The harnesses run the real emitted SQL, but through DuckDB rather than Spark, so
a Spark-only failure would not show. No run has touched a warehouse.
