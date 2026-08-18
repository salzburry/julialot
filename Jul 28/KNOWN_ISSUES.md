# Known issues — open questions for the study team

Three rules need a decision from a clinician. None is a defect. The build
applies each one on every run. What is open is whether the rule is right.

Each entry says what the code does, shows a patient, says what a change would
move, asks the question, and names the count that sizes it.

`lot/LOT_RULES.md` carries the same rules next to the code that applies them.

## Getting the numbers first

The counts are read-only. Every statement is a `SELECT`. They run against a
finished study run:

```
DATABRICKS_PWD=... DOMINO_USER_NAME=usr00000 OBJECT_PREFIX=ndmm_ \
  INPUT_COHORT_TABLE=ndmm_NDMM_COHORT \
  AUDIT_EXECUTE=TRUE Rscript exploration/lot/run_lot_audit_counts.R
```

Run it without `AUDIT_EXECUTE` first. It lists what it would count and needs no
connection. Results print and land in `exploration/lot/out/lot_audit_counts.csv`.

Any frequency quoted below is from the **synthetic** cohort. It is the shape of
the problem, not its prevalence. Take real numbers into the conversation.

---

## 1. A continued agent is missing from the later line's regimen

**What the code does.** `lot{n}_induction_meds` reads `map_stacked`. That table
holds one row per supply **episode**. The test is on `MAP_START_DT`.

A dispense arriving while the drug's cover is still live extends the open
episode (`03_mma_map.R` CASE 3). It leaves no new `MAP_START_DT`. So the drug
is invisible to the window it was dispensed in.

Three rules are possible. The code is on (c):

| | rule | in the regimen? |
|---|---|---|
| a | cover overlaps the window | no — this is the wide reading |
| b | a **claim** falls in the window | the alternative |
| c | an **episode starts** in the window | **what the code does** |

    d1     LEN, refilled without a break, covered through d200
    d100   POMA opens LOT2, window d100-d129
    d110   LEN dispensed — a real claim, inside the window
    ---
    LOT2 regimen = POMA. The d110 claim is invisible. It extended the
    episode that began on d1, and d1 is the only MAP_START_DT LEN has.

**Who it hits.** Drugs taken without a break across a line boundary. The more
continuously a patient takes an agent, the more certainly it is absent from the
later line's regimen. Two patients on the same treatment differ on whether one
missed a fill.

**The claims are still there.** `mma_med_processed` holds one row per claim with
`DATE_SERVICE`, `MED_ABBR` and `MED_CLASS`, and it is built before the regimen
step. The fills are dropped at the regimen step, not missing from the data.

**What rule (b) would need.** Test membership on a claim date. Not a table swap:
`map_med` filters and rolls up claims that `mma_med_processed` still carries, so
the claim test has to be restricted to claims inside an episode the build kept.
Otherwise the regimen gains agents the rest of the algorithm does not know about.

**It reaches further than the regimen string.** The exclusion that stops an
agent starting a line looks **one line back only** (`LOT_NUM = {prev}`). An
agent absent from LOT2's regimen is absent from LOT3's exclusion set. It can
then start LOT3.

    d1     LEN, filling continuously
    d100   POMA opens LOT2. LEN is not in LOT2's regimen (rule c)
    d200   POMA runs out, LOT2 ends
    d205   LEN's cover lapses and it restarts — a new episode
    ---
    under (c):  LOT3 starts d205 on LEN, because nothing excludes it
    under (b):  LEN was LOT2's agent and cannot start a line

Add a BORT at d210 and the two readings differ on whether LOT3 is `BORT` or
`LEN BORT`, and on whether it starts five days earlier. With no BORT they differ
on whether the line exists at all.

**What a change would move.** `LOT_BASE_MEDS` and `LOT_MED_CNT` on later lines.
The per-agent flags. Line starts and line counts, through the exclusion above.
Line lengths, because a new regimen agent is a base agent and enters
`discon_per_med`. Published regimen strings change for a large group.

**The question.** Is (b) or (c) intended? The protocol says the regimen is "all
MM therapies identified during the first 30 days of the LOT". That reads wider
than (c). Reading it as (b) is an interpretation the text does not settle.

**The counts.** Neither has been run.
`4.2-prior-agent-covered-but-not-in-the-regimen` sizes the regimen half.
`4.3-line-started-by-an-agent-from-two-lines-back` sizes the reach — lines whose
regimen holds an agent present two lines back and absent one line back. Both are
in `exploration/lot/run_scenario_counts.R`.

Rule: `lot/LOT_RULES.md` §4.2.

---

## 1b. Two readings of the protocol, both applied

The code applies both on every run. Each needs a clinician.

**A drug returning after its line has ended** — §4.3. The protocol starts a
later line at "the first administration for a new MM agent that was not part of
the previous LOT regimen". A drug the patient never stopped is arguably not new.
So the line that owns the drug holds it, and releases it only once the drug is
discontinued. Reading "new" as "new episode" would open a line at every refill
after a lapse.

**A drug returning mid-line after a break** — §5.2 and §7.4. A lapse of one day
opens a new episode and leaves a new `MAP_START_DT`. That alone does nothing.
For a drug the line already owns, the new episode is a boundary only once
`MAP_DISCON_FLG` sits on the episode before it. That takes
`map_discon_gap_days` — 90 days. Under 90 days the drug is still the line's own:
the run-out chains over the gap, and `med_cand` refuses the drug as a line
start. A late refill does not end a line. Ninety days off the drug does.

The question is the 90 itself. Is three months without a fill a treatment
decision, or a claims artefact — a long holiday, a change of pharmacy benefit, a
stockpile?

Both readings turn on the same thing: whether an episode boundary in claims
means a treatment decision. `exploration/lot/run_scenario_counts.R` sizes each.

---

## 1c. Where the code differs from the written protocol

- **The tandem window is inclusive of 180 elapsed days.** The code tests
  `datediff(AUTO_2, AUTO_1) <= sct_tandem_days`. The program-spec crosswalk
  writes `datediff + 1 <= 180`. They differ on a pair exactly 180 days apart.
- **A planned tandem needs a clear gap, not only an interval.** The protocol
  names the interval. The code also requires that nothing happened between the
  two transplants.
- **A regimen is the agents whose supply episode STARTED in the window.** The
  protocol reads wider — item 1.
- **A run-out needs confirming, two ways.** The spec names one. The code accepts
  either `lot_discon_confirm_days` of observation, or a LOT-qualifying trigger.
- **A CAR-T-started line consolidates for 45 days. The spec says 30** — item 2.
- **A confirmed discontinuation loses to a later death** — item 3.
- **Disenrollment is not censoring** in the primary analysis.
- **Maintenance is a descriptive flag, not a period.**

---

## 2. The CAR-T consolidation window is 45 days, and the spec says 30

**What the code does.** `cart_consolidation_days` is 45. The protocol and the
program spec carry 30. No document in this repository carries 45.

**What it decides.** Two things, so one ruling moves both:

- the CAR-T-started line's own regimen window;
- the `CART_INIT` bridging window, which decides whether an added agent followed
  by a CAR-T is bridging therapy or an ordinary addition.

At 30, an addition followed by a CAR-T 31 to 45 days later stops being
`CART_INIT` and becomes a `MED_ADD`. That opens a line the current build does
not.

**The question.** Is 45 the agreed number, and what is the source? If it is 30,
the change is one config value and a rebuild.

**Safety.** The value is pinned in `CONTRACT`. A run at 30 records the deviation
and every downstream reader refuses it as the study's numbers. A 30-day run
cannot be produced by accident.

Rule: `lot/LOT_RULES.md` §4.2.

---

## 3. A confirmed discontinuation loses to a later death

**What the code does.** The death branch of the end cascade is gated on
`POST_RUNOUT_TRIGGER_FLG` alone. `DEATH_DT` is never compared with
`LOT1_BASE_DISCON_DT`. Where both exist, the death takes the line's end whatever
the dates are.

    d+100  the regimen runs out
    d+220  death, 120 days later, nothing in between
    ---
    LOT*_BASE_DISCON_DT is d+100, confirmed by 120 days of observation
    the line still ends DEATH at d+220

**Only one of three cases is in question.**

- A patient who dies *inside* the confirmation window can never complete it.
  Observation ends at the death. The death is the only end available, and the
  branch is right.
- A patient who restarts before dying keeps the discontinuation.
- The third case, above, is the one that differs from the protocol's
  earliest-qualifying-event rule.

**What a change would move.** `LOT_BASE_LENGTH`, TTD, and the attrition split
between died and discontinued. Not line counts. The alternative is one
predicate: `AND (DISCON_DT IS NULL OR DEATH_DT <= DISCON_DT)`.

**The question.** Where a discontinuation is confirmed and a death follows it
with no treatment in between, should the line end at the discontinuation, with
the death recorded as the patient outcome it already is?

**Not urgent.** `LOT*_BASE_DISCON_DT` is on the row either way. The other
reading is recoverable in analysis without a rebuild.

Rule: `lot/LOT_RULES.md` §7.5.
