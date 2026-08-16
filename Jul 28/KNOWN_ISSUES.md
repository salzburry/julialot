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

## 1. The CAR-T consolidation window is 45 days, and the spec says 30

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

## 2. A confirmed discontinuation still loses to a later death

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

## 3. A drug returning after a confirmed gap cannot start a line

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

## 4. A planned tandem partner outside the window is still lost

**What the build does.** `lot/LOT_RULES.md` §6.5 now holds a line open to a
transplant inside its own applicable window. A tandem partner 60 to 180 days
later is outside that window, so it does not hold the line open — and the next
line's start gate refuses it as well, because it is a planned tandem of the first
transplant and planned tandems do not start lines.

    d0     1L starts on LEN, 20 days supply
    d+19   cover runs out
    d+20   first autologous transplant — inside line 1's 60-day window
    d+150  second transplant, 130 days later — a planned tandem
    ---
    LOT1  d0 -> d+20   SCT_AUTO_CONT. The first transplant is recovered
    d+150 is outside the window, so it does not extend line 1
    d+150 is a planned tandem, so it does not start line 2
    the second transplant is in no line

Before §6.5 **both** transplants were lost this way. One of the two is now
recovered; this is the remainder.

**What the protocol says.** *"Tandem SCTs are two SCTs ≥60 to ≤180 days apart.
These are considered planned and a continuation of the line of therapy."*
(`docs/Part 3/Protocol/lot protocol.pdf`, §5.1.1.) On that reading the line
should be held open to the second transplant too, not only to the first.

**Why it was not done with §6.5.** §6.5 anchors on each line's own applicable
window, and the study team's rule set explicitly left the 60–180-day tandem rule
separate and unchanged. Extending a line to a transplant up to 180 days past a
window that is 30 to 60 days wide is a materially wider rule than the one that
was asked for, and it changes line 1 lengths for a different and larger group.

**What a change would move.** Line 1 and line 2–5 lengths, `TTD`, and the
transplant flags — a line held open to d+150 carries `LOT_TX_AUTO_TAND_FLG`
rather than `LOT_TX_AUTO_SING_FLG`. Not line counts, since neither transplant
starts a line under either reading.

**Question for the study team.** Where a line already extends to an in-window
transplant, should it extend again to that transplant's planned tandem partner?
Our reading of the protocol is yes, but it is a wider rule than §6.5 and it was
deliberately left out of it.

**Counts.** Not yet written. It needs the gap from each line's in-window
transplant to the next one, split by whether the next falls inside
`sct_tandem_days`, which no count in `run_lot_audit_counts.R` currently asks for.

`lot/LOT_RULES.md` §6.3 for the tandem rule, §6.5 for the window rule, and §14.5
for how the two meet.

---

## Closed

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
