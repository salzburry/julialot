# LOT - recorded decisions

This folder is the contract build plus one rule. This file is what that rule
is, what it changed, and what is still open.

---

## The whole change in one frame

Three questions the build answers. Only the third moved.

| | question | answered by | changed here |
|---|---|---|---|
| 1 | when does a drug's supply run? | MAP episodes, `steps/03_mma_map.R` | **no** - unchanged from the contract |
| 2 | did the patient stop the drug? | `MAP_DISCON_FLG`, set at `MAP_DISCON_GAP_DAYS` (90) | **no** |
| 3 | does a drug coming back start a line? | the returning-agent gate | **yes** |

The 90-day threshold has never merged anything. A new MAP opens the moment a
claim lands beyond every runout - one day's gap or five hundred - and the
threshold is applied afterwards, as a label on the *earlier* episode. Two
episodes stay two episodes. `map_stacked` is unchanged.

So the gate reads a label. It moves no date and merges no episode. It decides
one thing: whether a returning agent's new episode counts as *starting* a
medication.

---

## The rule

An agent returning to a line opens or ends one only when both hold:

    the agent is absent from that line's regimen
    AND (it is a first exposure OR its preceding episode has MAP_DISCON_FLG = 1)

| the agent returns | result |
|---|---|
| first exposure, never had it | can advance the LOT |
| preceding gap under the threshold | continuation - no new line |
| preceding gap at or over it | reintroduction - can start a line |
| already in this line's regimen | cannot advance it |

`engine/R/map_prev.R` holds both halves: `map_prev_sql()` builds the preceding
episode once, and `prev_discon_gate_sql()` is the predicate. Five gates splice
it, so line-ending and next-line-starting cannot disagree:
`first_add_candidates` (`steps/04_lot1_base.R`, `steps/10_lot2_5_base.R`),
`med_cand` (`steps/10_lot2_5_base.R`), and `post_runout_med`
(`steps/06_lot1_end.R`, `steps/10_lot2_5_base.R`).

`PREV_DISCON_FLG` is a `lag()`, never the candidate's own flag - a MAP's flag
describes the gap that *follows* it, so a returning episode's own flag is about
its future.

**The setting.** `RETURNING_AGENT_REQUIRES_DISCONTINUATION` in `engine/config.csv`,
TRUE here. Off, the gate emits nothing at all and the build is the contract's,
line for line - checked over 1,500 patients, zero lines differing. There is no
second gap parameter: the threshold is still `MAP_DISCON_GAP_DAYS`.

It is deliberately **not** in `CONTRACT`. Pinning it would make every run here a
recorded deviation needing `LOT_CONTRACT_OVERRIDE`, which is machinery a test
folder does not want. It has to go into `CONTRACT` before any of this reaches
the study build.

---

## Where the agent goes instead

A rejected agent used to land nowhere: not in `LOT_BASE_MEDS`, which is fixed at
induction; not a boundary, because the rule rejected it; not in the next line.
Dispensed therapy simply vanished.

`LOT_CONTINUING_MEDS` carries it - beside the regimen, not inside it - **but
only where the return starts inside a line.** See the open defect below: it does
not close the hole, it narrows it.

Beside rather than inside because `discon_per_med` joins `base_meds`: **the
regimen set is also the run-out set**. Putting an agent in `LOT_BASE_MEDS` would
hand it control of the line's end date. Keeping it out is what leaves open
decision 3 below instead of answering it by accident.

The membership test is "an episode starting inside the line, non-steroid, not in
`LOT_BASE_MEDS`". It never reads the flag, and does not need to: an agent the
rule *accepted* ends the line the day before its own start, so it falls outside
the span. The column is therefore consistent whether the rule is on or off, and
empty when off.

That same bound is the defect. A return the rule suppresses which arrives
*after* the line has ended starts outside every line's span, so this column
cannot reach it by construction.

Two consequences worth knowing:

- Being a continuing med does **not** put an agent in the regimen for the next
  line's prior-regimen test. A drug can be continuing in LOT2 and base in LOT3.
  Nothing is double-counted as a boundary, but exposure-by-line tallies must
  read both columns.
- Nothing downstream reads the column yet. QC, dashboard, questions and
  benchmarks are untouched.

---

## Worked cases

Run through both engines, actual output.

**A drug returning without having stopped.** LENA 1 Jan-28 Mar, POMA 15 Mar-20
May, LENA 1-30 May. LENA's gap is 34 days.

```
                                              contract            with the rule
LOT1  Jan 01 -> Mar 14  base LEN              MED_ADD (POMA)      same
LOT2  Mar 15 -> Apr 30  base POMA             MED_ADD (LEN)       -
LOT3  May 01 -> May 30  base LEN              DISCONTINUATION     -
LOT2  Mar 15 -> May 20  base POMA                                 DISCONTINUATION
                        continuing LEN
```

POMA starts while LENA is still covered and still advances the line - it is
outside LOT1's window and in no regimen. That is unchanged. LENA's return is
what the gate stops.

**The same, then a new agent.** Add DARA 15 Jun: LOT2 ends 20 May at POMA's
run-out and LOT3 opens 15 Jun on DARA. The run-out precedes DARA, and DARA is
the post-run-out trigger that *confirms* the discontinuation - which is why the
same gate sits on `post_runout_med`.

**The same, then LENA again 1 Oct** (124 days after its May episode): LOT3 opens
on LENA. Its preceding episode is flagged, and it is not in LOT2's
`LOT_BASE_MEDS`.

**A same-drug restart.** LENA 1 Jan ds60, nothing else, LENA 1 Sep:

```
LOT1  2016-01-01 -> 2016-02-29  meds LEN  DISCONTINUATION
LOT2  2016-09-01 -> 2016-09-30  meds LEN  DISCONTINUATION
```

Identical in both folders - the gate does not touch it, because a 184-day gap
flags the first episode. See decision 2.

---

## Decided

- **Leftover days-supply does not carry an agent into the next line's regimen.**
  Settled by the study team; the code matches.
- **Permissible biosimilar substitutions do not advance the line.**
- **Induction windows:** 60 days at LOT1, 30 at LOT2-5, 45 for a CAR-T-started
  line.
- **A returning agent that never stopped does not advance the line** - the rule
  above, this folder.
- **A return inside a line is recorded rather than dropped** -
  `LOT_CONTINUING_MEDS`, descriptive. A return after the line ended is not; see
  the open defect.

---

## Open defect - treatment assigned to no line

The rule can suppress a return that arrives after the prior line has already
ended. Nothing then owns it: no boundary, no regimen, and `LOT_CONTINUING_MEDS`
is bounded by the line's own span so it cannot reach it either.

    LEN  1-30 Jan          LOT1  Jan 01 -> Mar 14  base LEN   MED_ADD
    POMA 15-31 Mar         LOT2  Mar 15 -> Mar 31  base POMA  DISCONTINUATION
    LEN  20 Apr (81d gap)  -- in no line at all

The contract build gives LOT3 on LEN from 20 April. Here the episode exists in
`map_stacked` and appears in no row of `LOT_LONG`. A month of dispensed therapy
is absent from the output.

This has to be settled before the rule is used for anything but sensitivity.
Three shapes: extend the prior line to own the return, let it open a line after
all - which is the contract's answer and defeats the rule - or record it outside
the line structure. Each moves different downstream numbers.

---

## Open defect - a real discontinuation reported as censoring

The gate sits on `post_runout_med` as well, so a suppressed return stops being
evidence of anything - not only of a new line. Where it was the sole trigger
after the run-out and observation ends inside the confirm window, the run-out
cannot be confirmed and the line is censored instead.

    LEN  1 Jan - 29 Feb     contract                    with the rule
    POMA 11 Mar - 9 Apr     LOT2 Mar 11 -> Apr 09       LOT2 Mar 11 -> May 30
    LEN  10 May (71d gap)   DISCONTINUATION  len 30     STUDY_END  len 81
                            LOT3 May 10 -> May 30       (no LOT3)

POMA ran out on 9 April and never returned: the discontinuation is real in the
claims. No treatment is lost - LEN is carried in `LOT_CONTINUING_MEDS` - but the
line around it is misdescribed. The end reason is downgraded, the line is 2.7x
too long, and the patient no longer reaches a third line.

This is the same root as the defect above. Whatever settles that one has to say
what a suppressed return is still allowed to be evidence *of*: confirming a
run-out is a weaker claim than starting a line, and the two need not share an
answer.

---

## Open

**1. Does a continuing medication hold the line open?**
Today: no. `LOT_CONTINUING_MEDS` is descriptive and does not reach
`discon_per_med`. In case A, LOT2 ends 20 May on POMA's run-out while LENA was
dispensed to the 30th, so 21-30 May sits in no line. Making it affect run-out
changes line duration, TTNT, when the next line starts, and 2L/3L membership.

**2. A same-drug restart after a confirmed discontinuation - resume, or a new
line?**
Today: a new line. `med_cand` excludes `prev_meds_expanded`, which is only the
*permissible substitutes* of prior-LOT drugs, never the drugs themselves
(`steps/10_lot2_5_base.R:246-250`). So LENA restarting after 184 days gives two
lines, both LENA.

The protocol says a subsequent LOT starts at "the first administration for a new
MM agent **that was not part of the previous LOT regimen**", which a strict
reading says LENA is not. `maintenance_validated.csv`'s
`MAINT_REINTRODUCTION_RULE` points the same way but is scoped to maintenance,
which the engine does not implement.

Note the condition already in force: a restart only opens a line where the
previous episode was flagged. Under the threshold, `discon_per_med`'s
`min(end WHERE flag=1)` pulls the line's end past the second episode and no new
line opens. Whichever way this is decided, that part is not in question.

Resuming the line needs a narrower mechanism than taking the last episode's end
in `discon_per_med`: that also drags a run-out forward whenever any regimen
agent has a later episode, turning DISCONTINUATION endings into MED_ADD ones in
cases with nothing to do with the gap.

**3. Should a real in-window fill absorbed into an older MAP join the regimen?**
Today: no - regimen membership is an episode start inside the window, not a fill
inside it. `lot1baseend_validated.csv` row 34 carries both readings: "first
administration/dispense date" against "`MAP_START_DT` from MAP algorithm". For a
drug the patient has never had those are the same date; for one already in hand
they are not.

**4. Melphalan: when a melphalan claim and an AUTO procedure code are the same
clinical event, which rule wins?**
Not answered, and deliberately so - `lot/melphalan` builds both readings
(`as_asked`, `yield_to_sct`) and sets them against each other rather than
picking. Identical in both folders. `APPLY_MELP_RULE` is blank in both, so the
rule is off, and no melphalan build has been run - there are no outputs in the
repo.

---

## Known gaps

- **The melphalan inject arm does not carry this rule, on purpose.**
  A sensitivity folder should differ from the contract by one decision, and
  gating `melp_inject_arm()` would make it two: melphalan reasons in 60- and
  180-day gaps between *doses*, this rule in 90 days between *episodes*, so the
  two compose rather than one deferring to the other. The B.1 arm injects a dose
  whose *next* dose is inside 60 days and says nothing about what came before
  it, so a gate would reject injections the melphalan rule intends - a change to
  an unapproved rule that nobody has ruled on or measured.
  It also costs nothing to leave off: `APPLY_MELP_RULE` is blank, so the arm
  emits nothing at all and a gate on it is inert. Leaving it ungated keeps
  `engine/R/melp_rule.R` identical to the contract's, so melphalan means the
  same thing in either folder and a melphalan run answers one question.
  **Required before promotion.** Rule 9 of the continuity draft says every path
  that injects or suppresses a medication boundary must share this predicate.
  That binds when this rule becomes contract, not while it is a sensitivity.
- **Nothing downstream reads `LOT_CONTINUING_MEDS`.**
- **`RETURNING_AGENT_REQUIRES_DISCONTINUATION` is not in `CONTRACT`**, so a run
  here records no deviation. Deliberate for a test folder; must change before
  the study build.

---

## What has been measured, and what has not

**Against the production contract run**, by
`lot/validation/run_stockpiling_rule.R` and `run_rechallenge_evidence.R`:

- **898 boundaries in 624 patients** sit on a prior episode with
  `MAP_DISCON_FLG = 0` - still running by the build's own reckoning. Median 8
  days uncovered.
- **495 boundaries in 448 patients** sit on one flagged discontinued. Median 257
  days.
- **22** are a first exposure.

These are boundary counts, not a line structure: removing a boundary merges two
lines, renumbers every later one, moves induction windows and can change which
agents fall in which regimen. And they are an **upper bound** on this rule's
effect - they are not split by immediate-prior-regimen membership, permissible
substitution, or first exposure, so some of the 898 would not have been rejected
anyway.

Ten events returned no prior claim before the boundary date, which the event
definition should make impossible. Unresolved.

**This folder has never run against the warehouse.** Everything else here is
synthetic fixtures. On 4,000 generated patients the rule removes every
still-running boundary (129 to 0) and moves categories 1 and 2 by three
boundaries each, which is knock-on from merged lines renumbering. That is
evidence the rule closes the population it targets. It is not a cohort estimate.
