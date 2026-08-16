# Known issues — open questions for the study team

Four things the build does that need a decision rather than a closer reading of
the code. Each one is written to be answered: what the build does today, a
worked patient, what it moves, the question, and the count that sizes it.

**None of these is being changed while it is open.** The build ships as
described, and every one of them is recorded in `lot/LOT_RULES.md` next to the
rule it affects, so nobody reads the rules without meeting the caveat.

## Getting the numbers first

Every item names a count in `exploration/lot/run_lot_audit_counts.R`. Those are
read-only — every statement is a `SELECT`, nothing is written — and they run
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

## 1. A regimen can contain an agent that started after the line ended

**Priority.** The only one of the four that is a defect rather than a choice.
It affects LOT1 and LOT2-5 alike.

**What the build does.** Every line picks its regimen over the whole induction
window before it knows its own end date — at LOT1 `04_lot1_base.R` runs before
`05_sct.R`, and in the LOT2-5 loop the `induction_meds` stage runs before the
`sct` stage. When a transplant ends the line early, the rest of the window keeps
collecting agents into a regimen for a line that is already over.

    d0     LOT1 starts on LEN
    d+10   allogeneic transplant — LOT1 ends d+9
    d+30   DARA starts
    ---
    LOT1  d0 -> d+9   regimen LEN DARA      <- DARA starts 21 days after the end
    LOT2  d+10        the ALLO, a single-day line with no regimen
    LOT3  d+30        DARA

DARA is counted in LOT1's regimen **and** starts LOT3. The same shape occurs at
LOT2 with a CAR-T:

    d0     LOT2 starts on POMA
    d+10   CAR-T — LOT2 ends d+9
    d+20   DARA starts
    ---
    DARA is in LOT2's regimen, and in the CAR-T-started LOT3's as well

**Which paths do it.** Only an end computed independently of the regimen can
strand an agent, and only where that event is not already gated by a window:

| | LOT1 | LOT2-5 |
|---|---|---|
| AUTO | no | no — the in-LOT AUTO window is the regimen window |
| ALLO | **yes** | **yes** |
| CAR-T | no — the induction exemption closes it | **yes** |

**What it moves.** `LOT_BASE_MEDS`, `LOT_MED_CNT` and the per-agent flag
columns; the run-out, because a stranded agent is a base agent and enters
`discon_per_med`; the added-medication candidate list; and the next line's
prior-regimen exclusion. So it can move a later line boundary, not only a
regimen string.

**The fix has two halves, and the second is easy to miss.** Bounding regimen
*membership* at the transplant end is not enough on its own:

    REGIMEN_CUTOFF = min(regimen_window_end, independent_transplant_end)

`discon_per_med` chains a base agent's own later episodes forward from the
line's **start** with no upper bound, so a refill of an agent that legitimately
is in the regimen still pushes the run-out past the transplant after membership
has been corrected. The cutoff has to bound the per-drug episode scan too, and
then the run-out, the added-medication candidates, the end reason and the next
line's exclusion all have to be recomputed.

**Question for the study team.** Should a line's regimen be bounded by the date
the line actually ended? Our reading is yes — an agent first given after a line
is over was not part of that line's treatment — but it changes published
regimen strings and can change line counts, so it is not ours to decide.

**Counts.** `post-end-regimen-by-line-and-end-reason` (how many, split by line
and by what ended the line), `post-end-agent-also-starts-a-later-line` (the
double attribution, which is the number the decision turns on), and
`runout-extends-past-the-transplant-end` (the second half of the fix). Synthetic
shape: 30 of 10,659 lines carrying a regimen.

Full analysis: `lot/LOT_RULES.md` §14.2, and §3.3 for the rule it breaks.

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

**A CAR-T that belonged to no line** — fixed. The induction exemption measured
its window from line 1's start and never asked whether line 1 was still running,
so a line ending inside its own 60 days left an infusion that could neither end
that line nor start the next. The exemption is now conditional on the line being
active, and the run-out confirmation asks whether *any* transplant or CAR-T
falls after the run-out rather than comparing against the line's earliest one.
`lot/LOT_RULES.md` §14.1 carries the record, including the two wrong answers
tried on the way.
