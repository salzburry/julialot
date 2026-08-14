# LOT - recorded decisions

Choices that change where a line begins or ends. Each says what the code does,
what the written authorities say, and which kind of open question it is.

| kind | what it means |
|---|---|
| DOCUMENT CONFLICT | two written authorities disagree and the code follows one |
| INTERPRETATION | the protocol states a rule, and turning it into claims logic needed a choice the protocol does not make. Needs an SME, not a protocol reading |
| DEVIATION | the code does something the written authorities do not support, on purpose |

---

## 1. A drug returning after its line has already ended - DEVIATION

**The code** opens a new line on it. `steps/10_lot2_5_base.R` builds
`prev_meds_expanded` from the previous line's regimen and excludes only its
**permissible biosimilar substitutes**, not the drugs themselves:

> `-- A same-drug restart (the original prior-LOT drug itself) DOES trigger;`
> `-- the prior LOT ended by run-out and a fresh fill is a new line.`

**The protocol** says a subsequent LOT starts at "the first administration for a
new MM agent **that was not part of the previous LOT regimen**". A drug that
*was* the previous regimen is not such an agent, so on a strict reading it
cannot start the next line.

**The spec** touches it once, in `maintenance_validated.csv`,
`MAINT_REINTRODUCTION_RULE`: "The introduction of any MM therapies **including
therapies that were part of the original regimen does not advance the LOT** but
ends the maintenance period." That rule is scoped to maintenance, which the
engine does not implement, so it is indicative rather than binding.

**Status.** Deliberate, recorded only in code comments until now. Clinically
defensible - a patient off treatment for months who restarts has begun something
new - but not what either document says. Not adjudicated.

---

## 2. A drug returning mid-line after a break in supply - INTERPRETATION

**The code** ends the line and opens the next one. The added-medication query
(`steps/10_lot2_5_base.R`, `steps/04_lot1_base.R`) takes agents outside this
line's regimen whose **`MAP_START_DT`** falls after the induction window.

A supply episode reopens whenever cover lapses by a single day, so a refill
collected late produces a new `MAP_START_DT` and reads as an initiation. The
patient never stopped the drug.

**The spec carries both readings in one row.** `lot1baseend_validated.csv` row
34, `LOT1_BASE_1ST_ADD_MED_DT / LOT1_BASE_1ST_ADD_MED`:

| column | text |
|---|---|
| Definition (Validated from Protocol) | "the LOT end date is the day before the **first administration/dispense date** of the new agent" |
| Optum CDM Implementation | "where the medication is NOT in base_meds (induction + permissible subs). **`MAP_START_DT`** from MAP algorithm" |

For an agent the patient has never had, those two are the same date. For one
already in hand they are not.

The same row already carves out one exemption - "Per Rule 1: permissible
substitutions ... 'do not advance the LOT'" - so the concept of an appearance
that must not advance the line exists in the spec. It was never extended to a
drug returning after a break that is not a discontinuation.

**Status.** Open. Needs an SME ruling on what "initiation" means, not a protocol
reading.

---

## 3. The measure that separates the two

`mapmedpage_validated.csv` defines `MAP_DISCON_FLG`: set when at least
`MAP_DISCON_GAP_DAYS` (90) elapse between an episode's `MAP_END_DT` and the next
episode's `MAP_START_DT`. `steps/03_mma_map.R` computes it on every episode.

`discon_per_med` reads it. No line-start rule and no added-medication rule does.

---

## 4. Worked cases

Run through the engine. Days-supply of 30 assumed where a case does not give
one.

| claims | result |
|---|---|
| LENA 1 Jan ds60, POMA 1 Feb | LOT1 only, regimen `LENA POMA` - POMA is inside LOT1's 60-day window |
| LENA 1 Jan ds60, POMA 1 Mar, LENA 12 Mar | LOT1 only, regimen `LENA POMA` - 1 Mar is day 59, the window's last day |
| LENA 1 Jan ds60, POMA 2 Mar, LENA 12 Mar | LOT1 ends 1 Mar; LOT2 from 2 Mar, regimen `LENA POMA` |
| LENA 1 Jan ds60, LENA 1 Feb ds30 | LOT1 only - the refill is inside cover and pushes the run-out out |
| LENA 1 Jan ds60, LENA 1 Mar ds30 | LOT1 only - 1 Mar is the last covered day, so still inside |
| LENA 1 Jan ds60, LENA 1 Sep ds30 | LOT1 ends 1 Mar; **LOT2 from 1 Sep on LENA** - decision 1 |
| LENA 1 Jan ds30, LENA 1 Feb ds90, POMA 15 Mar ds90, LENA 3 May | LOT1, LOT2, **LOT3 from 3 May on LENA** - decision 2, opened by a two-day gap in cover |

The last two differ only in the length of the gap: 184 days against 2. The code
treats them the same because both open a supply episode.

---

## 5. What has been measured, and what has not

`validation/run_stockpiling_rule.R` and `validation/run_rechallenge_evidence.R`
size decision 2 against a finished run. Against the production run:

- **898 line boundaries in 624 patients** sit on a prior episode with
  `MAP_DISCON_FLG = 0` - the drug was still running by the build's own reckoning.
  Median 8 days uncovered.
- **495 boundaries in 448 patients** sit on a prior episode flagged discontinued.
  Median 257 days uncovered.
- **22** are a first exposure, with no prior episode.

These are boundary counts. They are **not** a resulting line structure: removing
a boundary merges two lines, renumbers every later one, moves the induction
windows and can change which agents fall in which regimen. An exact structure
needs an alternate build.

Ten events returned no prior claim before the boundary date, which the event
definition should make impossible. Unresolved.

---

## 6. Not in dispute

- Leftover days-supply does not carry an agent into the next line's regimen. The
  study team settled this and the code matches it.
- Permissible biosimilar substitutions do not advance the line.
- The induction windows: 60 days at LOT1, 30 at LOT2-5, 45 for a CAR-T-started
  line.
