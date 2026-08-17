# Known issues — open questions for the study team

Three things that need a decision rather than a closer reading of the code.
None of them is a defect: the build does what it does on purpose, and what is
open is whether that is the right rule. Each one is written to be answered: what the build does today, a
worked patient, what it moves, the question, and the count that sizes it.

**None of these is being changed while it is open.** The build ships as
described, and every one is recorded in `lot/LOT_RULES.md` next to the rule it
affects, so nobody reads the rules without meeting the caveat.

## Getting the numbers first

What has been measured is named under each item. The counts live in
`exploration/lot/run_lot_audit_counts.R`, which also carries the ones that sized
the defects in the Closed section — worth re-running after a rebuild, since those
should now come back empty. They are read-only — every statement is a `SELECT`, nothing is written — and they run
against a finished study run:

```
DATABRICKS_PWD=... DOMINO_USER_NAME=usr00000 OBJECT_PREFIX=ndmm_ \
  INPUT_COHORT_TABLE=ndmm_NDMM_COHORT \
  AUDIT_EXECUTE=TRUE Rscript exploration/lot/run_lot_audit_counts.R
```

Run it without `AUDIT_EXECUTE` first: it lists what it would count and needs no
connection. Results print and land in `exploration/lot/out/lot_audit_counts.csv`.

The frequencies quoted below are from the **synthetic** cohort. They are the
shape of each problem, not its prevalence. Take the real numbers into the
conversation.

---

## 1. A continued agent is missing from the later line's regimen

**An open question, not a defect.** This entry used to assert that claim-level
membership had been agreed and that the build failed to implement it. That
assertion does not hold up. It rested on the heading of an engine test — *an
agent joins a regimen by being filled in the window, not by cover* — which
rejects **cover** and says nothing about claims versus episode starts. Reading it
as a decision between those two was a misreading, and it created a conflict with
`lot/LOT_RULES.md` §4.2 that no document outside this file supports.

What is actually true: the build has always used the episode start, the program
spec's crosswalk describes `MAP_START_DT`, and nothing located so far records a
decision either way on the narrower question. So this is a question about the
current rule, not a gap against an agreed one.

**What the build does.** `lot{n}_induction_meds` reads `map_stacked`, which
carries one row per MAP **episode**, and tests `MAP_START_DT`. A dispense arriving
while that drug's cover is live extends the open episode rather than opening a
new one (`03_mma_map.R` CASE 3), so it leaves no `MAP_START_DT` behind. There are
three possible rules and the build is on the third:

| | rule | in the regimen? |
|---|---|---|
| a | cover overlaps the window | rejected — this is the wide reading |
| b | a **claim** falls in the window | the alternative, unrecorded either way |
| c | an **episode starts** in the window | **what the build does, and always has** |

    d1     LEN, refilled without a break, covered through d200
    d100   POMA opens LOT2, window d100-d129
    d110   LEN dispensed — a real claim, inside the window
    ---
    LOT2 regimen = POMA. The d110 claim is invisible: it extended the
    episode that began on d1, and d1 is the only MAP_START_DT LEN has.

**Why it matters more than it looks.** It bites on exactly the drugs that get
continued across a line boundary — how many of this cohort's regimens that is
has not been measured, and `run_lot_audit_counts.R` is where such a count would
go. The more continuously a patient takes an agent, the more certainly it is
absent from the later line's regimen. Two clinically identical patients differ
on whether one missed a fill.

**The data is there.** `mma_med_processed` is materialized per claim, with
`DATE_SERVICE`, `MED_ABBR` and `MED_CLASS`, and it is built before the regimen
step. So this is not a data limitation; the fills are discarded by the time the
regimen is assembled.

**The fix, and the care it needs.** Test membership on a claim date rather than
an episode start. It is not a blind table swap: `map_med` filters and rolls up
claims that `mma_med_processed` still carries, so the claim test has to be
restricted to claims belonging to an episode the build kept, or the regimen will
gain agents the rest of the algorithm does not know about.

**It propagates, and that is what makes the answer matter.** The prior-regimen
exclusion that stops an agent starting a line looks **one line back only**
(`LOT_NUM = {prev}`). An agent absent from LOT2's regimen is therefore absent
from LOT3's exclusion set too, and becomes eligible to *start* LOT3. Under (c)
that is correct and there is nothing to fix; under (b) it is a line that should
not exist. Which is why the answer moves more than regimen strings.

    d1     LEN, filling continuously
    d100   POMA opens LOT2. LEN is omitted from LOT2's regimen (rule c)
    d200   POMA runs out, LOT2 ends
    d205   LEN's cover finally lapses and it restarts — a new episode
    ---
    under (c):  LOT3 starts d205 on LEN, because nothing excludes it
    under (b):  LEN was LOT2's agent and cannot start a line

With a BORT at d210 the two readings differ on whether `LOT3` is `BORT` or
`LEN BORT`, and on whether it starts five days earlier. With no BORT at all
they differ on whether that line exists. So the answer is not confined to
regimen strings: it moves start dates, start types and line counts. Which of
the two is right is the question, not something this entry settles.

**What it would move.** `LOT_BASE_MEDS` and `LOT_MED_CNT` on later lines, the
per-agent flags, line starts and counts through the exclusion above, and the
run-out — a newly-admitted agent is a base agent and
enters `discon_per_med`, so line lengths and boundaries move too. Published
regimen strings change for a large group.

**Question for the study team.** Which of (b) and (c) is intended? The protocol
says the regimen is "all MM therapies identified during the first 30 days of the
LOT", which reads wider than (c) — but reading it as (b) is an interpretation,
not something the text settles. Answering (b) makes this a change to the build;
answering (c) closes the entry.

**Counts.** Both halves have a count and neither has been run.
`4.2-prior-agent-covered-but-not-in-the-regimen` sizes the regimen half, and
`4.3-line-started-by-an-agent-from-two-lines-back` sizes the propagation — the
lines whose regimen holds an agent present two lines back and absent one line
back. Both are in `exploration/lot/run_scenario_counts.R`.

`lot/LOT_RULES.md` §4.2, §12 and §14.3.


---

## 1b. Two readings the code had to choose, and the protocol does not settle

Both are applied on every run. What is open is not the behaviour but whether it
is the right reading of the protocol, and each needs a clinician rather than a
closer reading of the text. `lot/LOT_RULES.md` states what the code does;
this is why the choice was open.

**A drug returning after its line has ended** — `lot/LOT_RULES.md` §4.3. The
protocol starts a later line at "the first administration for a new MM agent
that was not part of the previous LOT regimen". A drug the patient never
stopped is arguably not new, so the build holds it inside the line that owns it
and releases it only once discontinued. Reading "new" as "new episode" instead
would open a line at every refill after a lapse.

**A drug returning mid-line after a break in supply** — §7.4. A supply episode
reopens whenever cover lapses by a single day, so a refill collected late
produces a new episode start and reads as an initiation. The build ends the line
and opens the next one. The patient never stopped the drug.

Both turn on the same thing: whether an episode boundary in claims means a
treatment decision. `exploration/lot/run_scenario_counts.R` sizes each.

---

## 1c. Where the build differs from the written protocol

Recorded so a reader of the protocol is not surprised by the numbers. None of
these is a defect; each is a deliberate choice made when the two disagreed.

- **The tandem window is inclusive of 180 elapsed days.** The engine tests
  `datediff(AUTO_2, AUTO_1) <= sct_tandem_days`; the program-spec crosswalk
  writes it `datediff + 1 <= 180`. They differ on a pair exactly 180 days apart.
- **A planned tandem needs a clear gap, not only an interval.** The protocol
  names the interval; the build also requires nothing to have happened between
  the two transplants.
- **A regimen is the agents whose supply episode STARTED in the window.** The
  protocol reads wider — see item 1 above.
- **The discontinuation confirmation buffer is applied**, and confirmed two
  ways where the spec names only one: `lot_discon_confirm_days` of observation,
  or a LOT-qualifying trigger.
- **A CAR-T-started line consolidates for 45 days, and the spec says 30** — item 2.
- **A confirmed discontinuation loses to a later death** — item 3.
- **Disenrollment is not censoring** in the primary analysis.
- **Maintenance is not implemented** as a period; it is a descriptive flag.

---

## 2. The CAR-T consolidation window is 45 days, and the spec says 30

**What the build does.** `cart_consolidation_days` is 45.
`10_lot2_5_base.R`'s own header records it as superseding an earlier 30, so the
change was deliberate rather than drift — but the protocol and program spec
carry 30, and this repository holds no document that carries 45. It came from
prior internal work that is not here, which is why it cannot be checked against
the protocol text.

**What it decides.** Two things at once, so a ruling moves both: the
CAR-T-started line's own regimen window, and the `CART_INIT` bridging window
that decides whether an added agent followed by a CAR-T is bridging therapy or
an ordinary addition. At 30, an addition followed by a CAR-T 31 to 45 days later
stops being `CART_INIT` and becomes a `MED_ADD` — which opens a line the current
build does not.

**Question for the study team.** Is 45 the agreed number, and if so what is the
source? If it is 30, the change is a one-line config edit and a rebuild.

**Safety.** It is pinned in `CONTRACT`, so a run at 30 records the deviation and
every downstream reader refuses it as the study's numbers. There is no way to
produce a 30-day run by accident.

`lot/LOT_RULES.md` §14.1.

---

## 3. A confirmed discontinuation still loses to a later death

**What the build does.** The death branch of the end cascade is gated on
`POST_RUNOUT_TRIGGER_FLG` alone; `DEATH_DT` is never compared with
`LOT1_BASE_DISCON_DT`. So where both exist, the death takes the line's end
whatever the dates are.

    d+100  the regimen runs out
    d+220  death, 120 days later, nothing in between
    ---
    LOT*_BASE_DISCON_DT is d+100, confirmed by 120 days of observation
    the line still ends DEATH at d+220

**This is only a question for one of the three cases.** A patient who dies
*inside* the confirmation window can never complete it — observation ends at the
death — so there the death is the only end available and the branch is doing
exactly what it should. A patient who restarts before dying keeps the
discontinuation. It is the third case, above, that diverges from the protocol's
earliest-qualifying-event rule.

**Why the two rules disagree.** They were decided months apart: the death
branch first, to keep death as the recorded end of a line, and the 90-day
confirmation buffer in August. Neither was written against the other.

**What a change would move.** `LOT_BASE_LENGTH`, `TTD`, and the attrition split
between died and discontinued — not line counts. The alternative is one
predicate: `AND (DISCON_DT IS NULL OR DEATH_DT <= DISCON_DT)`.

**Question for the study team.** Where a discontinuation is confirmed and a
death follows it with no treatment in between, should the line end at the
discontinuation, with the death recorded as the patient outcome it already is?

**Not urgent, and here is why.** `LOT*_BASE_DISCON_DT` is on the row either way,
so the other reading is recoverable in analysis without a rebuild.

`lot/LOT_RULES.md` §7.5 and §14.2.
