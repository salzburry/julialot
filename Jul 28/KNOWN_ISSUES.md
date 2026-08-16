# Known issues — open questions for the study team

Four things: one defect with a known correct answer, and three that need a
decision rather than a closer reading of the code. Each one is written to be answered: what the build does today, a
worked patient, what it moves, the question, and the count that sizes it.

**None of these is being changed while it is open.** #1 is a defect and the
others are decisions the code cannot make for itself. The build ships as
described, and every one is recorded in `lot/LOT_RULES.md` next to the rule it
affects, so nobody reads the rules without meeting the caveat.

The **Closed** section at the end lists what has been found and fixed. It is kept
rather than deleted: each was found after the build was believed correct.

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

**A defect, not a choice.** The rule the study team settled is *an agent joins a
regimen by being filled in the window, not by cover* — that is the heading of the
engine test that pins it. The code implements something narrower, and nobody
appears to have chosen it.

**What the build does.** `lot{n}_induction_meds` reads `map_stacked`, which
carries one row per MAP **episode**, and tests `MAP_START_DT`. A dispense arriving
while that drug's cover is live extends the open episode rather than opening a
new one (`03_mma_map.R` CASE 3), so it leaves no `MAP_START_DT` behind. There are
three possible rules and the build is on the third:

| | rule | in the regimen? |
|---|---|---|
| a | cover overlaps the window | rejected — this is the wide reading |
| b | a **claim** falls in the window | **what was decided** |
| c | an **episode starts** in the window | **what shipped** |

    d1     LEN, refilled without a break, covered through d200
    d100   POMA opens LOT2, window d100-d129
    d110   LEN dispensed — a real claim, inside the window
    ---
    LOT2 regimen = POMA. The d110 claim is invisible: it extended the
    episode that began on d1, and d1 is the only MAP_START_DT LEN has.

**Why it matters more than it looks.** It bites on exactly the drugs that get
continued across a line boundary, which in myeloma is most of them —
lenalidomide above all. The more continuously a patient takes an agent, the more
certainly it is absent from the later line's regimen. Two clinically identical
patients differ on whether one missed a fill.

**The data is there.** `mma_med_processed` is materialized per claim, with
`DATE_SERVICE`, `MED_ABBR` and `MED_CLASS`, and it is built before the regimen
step. So this is not a data limitation; the fills are discarded by the time the
regimen is assembled.

**The fix, and the care it needs.** Test membership on a claim date rather than
an episode start. It is not a blind table swap: `map_med` filters and rolls up
claims that `mma_med_processed` still carries, so the claim test has to be
restricted to claims belonging to an episode the build kept, or the regimen will
gain agents the rest of the algorithm does not know about.

**It propagates, and this is the worst of it.** The prior-regimen exclusion
that stops an agent starting a line looks **one line back only**
(`LOT_NUM = {prev}`). An agent wrongly absent from LOT2's regimen is therefore
wrongly absent from LOT3's exclusion set, and becomes eligible to *start* LOT3 —
a line it should not be able to open.

    d1     LEN, filling continuously
    d100   POMA opens LOT2. LEN is omitted from LOT2's regimen (the defect)
    d200   POMA runs out, LOT2 ends
    d205   LEN's cover finally lapses and it restarts — a new episode
    ---
    what ships:  LOT3 starts d205 on LEN, because nothing excludes it
    correct:     LEN is LOT2's agent and cannot start a line

With a BORT at d210 that turns `LOT3 = BORT` into `LOT3 = LEN BORT` starting
five days earlier. With no BORT at all it is an **extra line** that should not
exist. So this is not confined to regimen strings: it moves start dates, start
types and line counts.

**What it would move.** `LOT_BASE_MEDS` and `LOT_MED_CNT` on later lines, the
per-agent flags, line starts and counts through the exclusion above, and the
run-out — a newly-admitted agent is a base agent and
enters `discon_per_med`, so line lengths and boundaries move too. Published
regimen strings change for a large group.

**Question for the study team.** Confirm rule (b) is the intended one — our
reading of the recorded decision and of the protocol's "all MM therapies
identified during the first 30 days of the LOT" is that it is — and this is a
fix rather than a change.

**Counts.** `4.2-prior-agent-covered-but-not-in-the-regimen` sizes the regimen
half. The propagation needs its own count — lines started by an agent that was
in the regimen two lines back but not one — which is not yet written. Neither
has been run.

`lot/LOT_RULES.md` §4.2 and §12.

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

`lot/LOT_RULES.md` §14.3.

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

`lot/LOT_RULES.md` §7.5 and §14.4.

---

## 4. A drug returning after a confirmed gap cannot start a line

**What the build does.** An agent in the previous line's regimen can never start
the next line, however long it has been gone. The line that owns the drug
extends over its later episodes instead.

    d0     LEN, 60 days supply
    d+244  LEN again, 185 days after cover ran out
    ---
    LOT1  d0 -> d+274   one line, spanning seven months with no cover

**Where the doubt is.** `MAP_DISCON_FLG` already marks every episode where the
gap to the next one reaches `map_discon_gap_days`, and it sits on the same rows
the line rules read. But the prior-regimen exclusion is applied unconditionally
and `discon_per_med` never consults the flag. If the intended rule is *a
previous-regimen drug cannot advance the line while continuing, but may start a
later line once it has discontinued*, the build does not implement it.

**What has been measured.** Against the production run, 898 line boundaries in
624 patients sit on a prior episode still flagged as running (median 8 days
uncovered), and 495 in 448 patients on an episode flagged discontinued (median
257 days). Those are boundary counts, not a resulting line structure — an exact
structure needs an alternate build.

**Question for the study team.** Is a re-start after a confirmed 90-day gap a
new line, or a continuation of the line the drug belongs to? This is a clinical
question, not a protocol reading, which is why it has stayed open.

`lot/LOT_RULES.md` §11.1, §11.2 and §11.3.

---

## Closed

**A planned tandem partner outside the window** — fixed, once the study team
settled what makes a pair planned: a **clear gap**. Where nothing happens between
the two transplants the second follows the first past the line's own window and
the line is held open to it; where a medication, an allogeneic transplant or a
CAR-T falls in between, the pair was never planned, so the later transplant is
free to start a line instead. That single rule also settles the case where a
partner fell inside a *later* line's window and was attached to the wrong line —
the medication that started that later line is itself the interruption.
`lot/LOT_RULES.md` §6.5 and §14.5.


**A regimen containing an agent that started after the line ended** — fixed. A
line picked its regimen over the whole induction window before it could know its
own end date, because `phase_sct` ran after `phase_lot1_base`. Where a transplant
ended the line early, the rest of the window kept collecting agents into the
regimen of a line that was already over, and the same agent went on to start a
later line. `phase_sct` now runs first, and `lot1_regimen_cutoff` /
`lot{n}_regimen_cutoff` bound both the regimen window and the per-drug episode
scan in `discon_per_med` — the second being the half that is easy to miss, since
a refill of an agent legitimately in the regimen would otherwise still push the
run-out past the transplant. `lot/LOT_RULES.md` §14.2 carries the record.


**A CAR-T that belonged to no line** — fixed. The induction exemption measured
its window from line 1's start and never asked whether line 1 was still running,
so a line ending inside its own 60 days left an infusion that could neither end
that line nor start the next. The exemption is now conditional on the line being
active, and the run-out confirmation asks whether *any* transplant or CAR-T
falls after the run-out rather than comparing against the line's earliest one.
`lot/LOT_RULES.md` §14.1 carries the record, including the two wrong answers
tried on the way.
