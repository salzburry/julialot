# LOT - recorded decisions

Choices that change where a line begins or ends. Each says what the code does,
what the written authorities say, and which kind of open question it is.

| kind | what it means |
|---|---|
| DOCUMENT CONFLICT | two written authorities disagree and the code follows one |
| INTERPRETATION | the protocol states a rule, and turning it into claims logic needed a choice the protocol does not make. Needs an SME, not a protocol reading |
| DEVIATION | the code does something the written authorities do not support, on purpose |

---

## 1. A drug returning after its line has already ended - INTERPRETATION

**The code** does not open a new line on it. `engine/R/prior_regimen.R` excludes
the previous line's regimen *and* its permissible biosimilar substitutes from
the agents that can start the next line. The line that owns the drug extends
over its later episodes instead, stopping at any *other* agent arriving in
between.

**The protocol** says a subsequent LOT starts at "the first administration for a
new MM agent **that was not part of the previous LOT regimen**". A drug that
*was* the previous regimen is not such an agent, so it cannot start the next
line. The code follows this reading.

**The spec** agrees in the one place it touches this, `maintenance_validated.csv`
`MAINT_REINTRODUCTION_RULE`: "The introduction of any MM therapies **including
therapies that were part of the original regimen does not advance the LOT** but
ends the maintenance period." That rule is scoped to maintenance, which the
engine does not implement, so it is indicative rather than binding.

**The cost.** A line can span a treatment-free interval. LENA in January and
again in September is one nine-month LOT1 with seven months uncovered, ending
`DISCONTINUATION`. That is the price of the return belonging to a line rather
than to nothing.

**Status.** Applied unconditionally, in both deliveries. No switch.

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

**Status.** Open. The mechanism to settle it is already built and configurable -
what is missing is a ruling on whether a supply episode opening counts as an
initiation, which is a clinical question and not a protocol reading.

---

## 3. The measure both rules already have

`MAP_DISCON_GAP_DAYS,90` has been in `engine/config.csv` since that file's first
commit, and `steps/03_mma_map.R` sets `MAP_DISCON_FLG` from it on every episode:
1 where at least that many days separate an episode's `MAP_END_DT` from the next
episode's `MAP_START_DT`. It is a setting, not a constant - 30 or 60 is a config
value and a rebuild, with no code change.

So nothing is absent. The flag sits on the same `map_stacked` rows the line rules
already select from. What decisions 1 and 2 come down to is which queries read
it:

| query | what it decides | reads the flag |
|---|---|---|
| `discon_per_med` | when the line's cover runs out | yes |
| `first_add_candidates` (`steps/04_lot1_base.R`, `steps/10_lot2_5_base.R`) | whether a returning agent ends the line | **no** |
| `med_cand` (`steps/10_lot2_5_base.R`) | whether a returning agent starts the next line | **no** |

Three predicates that do not consult a flag already on the row. That is the
size of it - not a missing parameter and not a missing concept.

The added-medication and line-start queries have never read the flag. This is
original behaviour, not something a refactor lost.

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
| LENA 1 Jan ds60, LENA 1 Sep ds30 | **LOT1 only**, 1 Jan -> 30 Sep, `DISCONTINUATION` - LENA was LOT1's regimen, so its return cannot open LOT2 - decision 1 |
| LENA 1 Jan ds30, LENA 1 Feb ds90, POMA 15 Mar ds90, LENA 3 May | LOT1, LOT2, **LOT3 from 3 May on LENA** - decision 2, opened by a two-day gap in cover |

The last two are decided by regimen membership, not by the length of the gap. In
the first, LENA returns to a line whose regimen is LENA, so it cannot open a new
one however long it was away. In the second the previous line's regimen is POMA,
so LENA is a new agent against it and LOT3 opens on a two-day lapse in cover.

---

## 5. What has been measured, and what has not

`lot/validation/run_stockpiling_rule.R` and
`lot/validation/run_rechallenge_evidence.R`
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
