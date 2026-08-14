# LOT - recorded decisions

The rules this build applies where a written authority left a choice open, what
each one does, and which questions are still unanswered.

---

## What this folder is

The same line engine as the other delivery, plus one extra output column,
`LOT_CONTINUING_MEDS`. There is no rule here that the other folder does not
also apply: the two builds place line boundaries identically.

| | question | answered by | settled |
|---|---|---|---|
| 1 | when does a drug's supply run? | MAP episodes, `steps/03_mma_map.R` | yes |
| 2 | did the patient stop the drug? | `MAP_DISCON_FLG`, set at `MAP_DISCON_GAP_DAYS` (90) | yes |
| 3 | can a drug from the previous regimen start the next line? | the prior-regimen rule, `engine/R/prior_regimen.R` | yes - no |

The 90-day threshold merges nothing. A new MAP opens the moment a claim lands
beyond every runout - one day's gap or five hundred - and the threshold is
applied afterwards, as a label on the *earlier* episode. Two episodes stay two
episodes.

---

## The prior-regimen rule

The protocol starts a later line at "the first administration for a new MM agent
**that was not part of the previous LOT regimen**". A drug that *was* that
regimen is not such an agent, so it cannot start the next line. `prior_regimen.R`
applies this with no switch - it is the protocol reading, not a sensitivity.

The line that owns the drug extends over its later episodes instead, stopping at
any *other* agent that arrives in between. `discon_per_med_sql()` chains a drug's
episodes forward and stops the chain at the first break that a different agent
causes, so a line's run-out cannot be dragged past an agent that already ended
it.

The cost is a line that can span a treatment-free interval: LENA in January and
again in September becomes one nine-month LOT1 with seven months uncovered. That
is the price of the return belonging to a line rather than to nothing.

---

## `LOT_CONTINUING_MEDS`

The one thing this folder adds. Non-steroid treatment whose episode starts
inside a line but is absent from that line's `LOT_BASE_MEDS`, collected into a
string beside the regimen.

Beside rather than inside because `discon_per_med` joins `base_meds`: **the
regimen set is also the run-out set**. Putting an agent in `LOT_BASE_MEDS` would
hand it control of the line's end date. Keeping it out is what makes the column
descriptive - it cannot move a boundary.

Two consequences worth knowing:

- Being a continuing med does **not** put an agent in the regimen for the next
  line's prior-regimen test. A drug can be continuing in LOT2 and base in LOT3.
  Nothing is double-counted as a boundary, but exposure-by-line tallies must
  read both columns.
- Nothing downstream reads the column. QC, dashboard, questions and benchmarks
  are untouched.

---

## Worked cases

Run through the engine. Days-supply of 30 assumed where a case does not give one.

| claims | result |
|---|---|
| LENA 1 Jan ds60, POMA 1 Feb | LOT1 only, regimen `LENA POMA` - POMA is inside LOT1's 60-day window |
| LENA 1 Jan ds60, POMA 2 Mar, LENA 12 Mar | LOT1 ends 1 Mar; LOT2 from 2 Mar, regimen `LENA POMA` |
| LENA 1 Jan ds60, LENA 1 Feb ds30 | LOT1 only - the refill is inside cover and pushes the run-out out |
| LENA 1 Jan ds60, LENA 1 Sep ds30 | **LOT1 only**, Jan 01 -> Sep 30, `DISCONTINUATION` - LENA was LOT1's regimen, so its return cannot open LOT2 |
| LENA 1-28 Mar, POMA 15 Mar-20 May, LENA 1-30 May | LOT1 on LENA to 14 Mar; LOT2 from 15 Mar on POMA, continuing `LEN` |

---

## Decided

- **Leftover days-supply does not carry an agent into the next line's regimen.**
  Settled by the study team; the code matches.
- **Permissible biosimilar substitutions do not advance the line.**
- **Induction windows:** 60 days at LOT1, 30 at LOT2-5, 45 for a CAR-T-started
  line.
- **An agent in the previous regimen cannot start the next line** - the rule
  above. Applied in both deliveries.
- **A drug dispensed inside a line but outside its regimen is recorded rather
  than dropped** - `LOT_CONTINUING_MEDS`, descriptive.

---

## Open

**1. Does a continuing medication hold the line open?**
Today: no. `LOT_CONTINUING_MEDS` is descriptive and does not reach
`discon_per_med`. Where a line ends on its regimen's run-out while a continuing
agent was still dispensed, those days sit in no line. Making it affect run-out
changes line duration, TTNT, when the next line starts, and 2L/3L membership.

**2. Should a real in-window fill absorbed into an older MAP join the regimen?**
Today: no - regimen membership is an episode start inside the window, not a fill
inside it. `lot1baseend_validated.csv` row 34 carries both readings: "first
administration/dispense date" against "`MAP_START_DT` from MAP algorithm". For a
drug the patient has never had those are the same date; for one already in hand
they are not.

**3. Melphalan: when a melphalan claim and an AUTO procedure code are the same
clinical event, which rule wins?**
Not answered, and deliberately so - `lot/melphalan` builds both readings
(`as_asked`, `yield_to_sct`) and sets them against each other rather than
picking. Identical in both folders. `APPLY_MELP_RULE` is blank in both, so the
rule is off, and no melphalan build has been run - there are no outputs in the
repo.

---

## Known gaps

- **Nothing downstream reads `LOT_CONTINUING_MEDS`.**
- **The melphalan arms do not carry the prior-regimen rule's predicate.**
  Melphalan reasons in 60- and 180-day gaps between *doses*, the prior-regimen
  rule in regimen membership between *lines*, so the two compose rather than one
  deferring to the other. `APPLY_MELP_RULE` is blank, so the arms emit nothing
  and the question is inert until a melphalan build is run.
- **Five lines is a cap, not a finding.** A patient recorded at line 5 may have
  had more; treatment after line 5 appears in no line.

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
agents fall in which regimen.

Ten events returned no prior claim before the boundary date, which the event
definition should make impossible. Unresolved.

**This folder has never run against the warehouse.** Everything else here is
synthetic fixtures.
