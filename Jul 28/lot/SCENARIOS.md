# The rules, worked through a patient's claims

Every rule in `LOT_RULES.md`, shown as what it does to a patient. The rules
document says what the build does; this one shows it. They are numbered the
same, so `§6.5` there is `6.5` here.

## How to read one

Days are relative to the line's own start, so `d0` is the first fill of the
line under discussion and `d+40` is forty days later. Below the rule is what
the build produces:

    d0     what happens
    d+40   what happens next
    ---
    the lines that come out, and why

Each scenario carries how far it has been checked, and the three are not the
same claim:

* ***derived*** — worked out from the parameters and the code, on paper.
* ***to confirm*** — the same, and it needs a run to confirm.
* ***vignette `name`*** — the scenario is in the machine-checked catalogue in
  `lot/validation/`, so a parameter change that would move it fails a test.

A vignette is **not** a patient executed through the engine. The catalogue is
derived from the same settings the build reads, so it proves the scenarios and
the settings agree with each other. Nothing here has been run against claims.

## What is not here

Anything that is not a rule the build applies on every run: the melphalan
proposal, the sensitivity sweep, the definition comparison. Those are in
`exploration/`, and `exploration/FILES.md` says where.

---

### 2.1 Steroids are excluded everywhere

**Scenario** — *derived; vignette `steroid_only_interval`.*

    d0     1L regimen starts
    d+150  dexamethasone alone for several weeks
    d+220  the next regimen begins
    ---
    the steroid stretch neither starts a line nor continues one

Steroids accompany almost every myeloma regimen. Counted, they would start lines
everywhere and no line would ever be seen to end.


### 2.2 A medical claim is assumed to cover 28 days

**Scenario** — *derived.*

    d0     a medical-claim administration, no day supply on the claim
    ---
    cover runs d0 -> d+27, medical_day_supply = 28 days inclusive


### 2.3 A claim arriving while cover is live extends the episode

**Scenario** — *engine output.*

    d0     LEN dispensed, 60 days supply  (covers to 2016-02-29)
    d+31   LEN refilled, 28 days supply, while cover is still live
    ---
    LOT1   2016-01-01 -> 2016-03-28   LEN

The refill does not move the end to its own run-out. It pushes the existing
run-out out by its own 28 days.

**Scenario** — *to confirm; vignette `overlapping_oral_refills`.*

    d0     oral agent dispensed, 30 days supply
    d+20   refilled early, before the first has run out
    d+40   refilled early again
    ---
    one episode, running to the accumulated run-out rather than to the last
    fill plus one supply

Early refills move the gap that would otherwise end the line.


### 3.1 Line 1 starts at the first non-steroid MM agent

**Scenario** — *derived.*

    d0     dexamethasone
    d+10   LEN dispensed
    ---
    LOT1 starts d+10

The steroid is not an oncology agent (§2.1), so it does not fix the index.


### 3.2 Line 1's induction window is 60 days

**Scenario** — *engine output.* A second agent inside the window joins the line.

    d0     LEN dispensed, 60 days supply
    d+31   POMA dispensed
    ---
    LOT1   2016-01-01 -> 2016-02-29   LEN POMA

**Scenario** — *engine output.* Outside the window it starts a line.

    d0     LEN dispensed, 60 days supply
    d+61   POMA dispensed
    ---
    LOT1   2016-01-01 -> 2016-02-29   LEN
    LOT2   2016-03-02 -> 2016-03-29   POMA

**Scenario** — *derived; vignettes `induction_lot1_within` /
`induction_lot1_beyond`.*

    d0                             1L regimen starts
    d+(induction_window_days - 1)  agent added on the last day inside
    ---
    joins LOT1's regimen

    d0                             1L regimen starts
    d+induction_window_days        agent added one day outside
    ---
    not an induction agent — it is an addition, and §7.4 decides what that does

The `- 1` is the difference between a regimen of four drugs and one of three.


### 3.3 Regimen membership is an episode start, not a fill

**Scenario** — *derived.*

    d0     LOT1 starts on LEN and DARA
    d+120  LOT2 starts on POMA, while DARA is still covered by a d+100 refill
    ---
    DARA is NOT in LOT2's regimen — its episode started in LOT1

`Rscript exploration/lot/run_stockpiling_rule.R` sizes the second case against a
finished run, in `STOCKPILE_AGENTS` and `STOCKPILE_IMPACT`.


### 3.4 Line 1's first autologous transplant is part of induction

**Scenario** — *to confirm; from vignette `allo_after_failed_auto`.*

    d0     1L regimen starts
    d+40   autologous transplant
    ---
    the AUTO sits inside LOT1. It neither ends the line nor opens the next one


### 4.1 A later line opens on the earliest of four candidates

**Scenario** — *engine output.* The `d_MED` candidate, on the second example in
§3.2: POMA at d+61 is outside line 1's window and in no regimen of line 1's, so
it opens LOT2 on its own date.


### 4.2 Later induction is 30 days, and 45 on a CAR-T-started line

**Scenario** — *derived; vignettes `induction_lotn_within` /
`induction_lotn_beyond`.*

    d0                                   LOT2 starts
    d+(lot_n_induction_window_days - 1)  agent added on the last day inside
    ---
    joins LOT2's regimen

    d0                                   LOT2 starts
    d+lot_n_induction_window_days        agent added one day outside
    ---
    not part of LOT2's regimen

Two different windows in one algorithm is a standing source of error: the
later-line window closes sooner than a reader expects.

**Scenario** — *derived.* A dispense inside the window that joins nothing,
because it is not the start of anything.

    d1     LEN, refilled without a break, covered through d120
    d100   POMA starts — outside line 1's 60-day window, so it opens line 2
    d110   LEN dispensed again, inside line 2's d100-d129 window
    ---
    LOT1   d1 -> d99     LEN            ends MED_ADD at POMA
    LOT2   d100 -> ...   POMA

LEN is not in line 2's regimen even though it was dispensed on d110, inside the
window, and even though the patient is demonstrably taking both drugs. The d110
claim arrived while LEN's cover was live, so it extended the episode that began
on d1 (§2.3) rather than opening a new one, and `MAP_START_DT` is still d1. The
window has no episode start to find.

Moving that dispense earlier changes nothing, for the same reason:

    d1     LEN, covered through d120
    d90    LEN dispensed again — before line 2 even exists
    d100   POMA starts
    ---
    LOT2   d100 -> ...   POMA

Both are one LEN episode, d1 to d120. Where the dispense falls is irrelevant;
what matters is that it is not an episode start.

**Scenario** — *derived.* And it carries forward into the line after.

    d1     LEN, filling continuously
    d100   POMA opens LOT2 — LEN is omitted from LOT2's regimen
    d200   POMA runs out, LOT2 ends
    d210   BORT starts
    ---
    LOT3   d210 -> ...   BORT

The patient is on bortezomib and lenalidomide; the record says bortezomib. LEN
still has only its d1 episode start, so LOT3's window cannot see it either.

Worse, LEN is now free to start a line. The exclusion that stops a
previous-line agent opening a line reads **one line back only**, and LEN is not
in LOT2's regimen — so nothing holds it:

    d205   LEN's cover finally lapses and it restarts, before BORT
    ---
    what ships:  LOT3  d205 -> ...   LEN BORT
    correct:     LOT3  d210 -> ...   BORT

Five days earlier, a different start type, and two regimens merged. With no BORT
at all it is an extra line outright. `KNOWN_ISSUES.md` #1 carries this, and
`run_scenario_counts.R`'s `4.3-line-started-by-an-agent-from-two-lines-back`
counts it.

**Scenario** — *derived.* The same drug, the same window, opposite answer —
because the cover lapsed first.

    d1     LEN, cover ends d90
    d91    nothing
    d100   POMA starts, opening line 2
    d110   LEN dispensed, 20 days after its own cover ran out
    ---
    LOT1   d1 -> d99      LEN
    LOT2   d100 -> ...    POMA LEN

Here d110 is past LEN's own run-out, so it opens a **new** episode whose
`MAP_START_DT` is d110 — inside line 2's window — and LEN joins the regimen.

The two patients may be clinically identical. The one who never missed a fill
gets `POMA`; the one with a three-week gap gets `POMA LEN`. §12 records this as
a divergence from the protocol's "all MM therapies identified during the first
30 days of the LOT", and
`run_scenario_counts.R`'s `4.2-prior-agent-covered-but-not-in-the-regimen`
counts who it touches.


### 4.3 A drug in the previous line's regimen cannot start a line

**Scenario** — *engine output.* A drug returning does not start a line on
itself.

    d0     LEN dispensed, 60 days supply
    d+244  LEN again, 185 days after cover ran out
    ---
    LOT1   2016-01-01 -> 2016-09-30   LEN

One line, spanning seven months with no cover. The alternative leaves the
September treatment belonging to nothing at all.

**Scenario** — *engine output.* The extension stops at any other agent.

    d0     LEN, covered to d+87
    d+74   POMA, covered to d+140
    d+121  LEN again, 34 days after LEN's own cover ended
    ---
    LOT1   2016-01-01 -> 2016-03-14   LEN
    LOT2   2016-03-15 -> 2016-04-30   POMA
    LOT3   2016-05-01 -> 2016-05-30   LEN

POMA starts while LEN is still covered and still opens a line: it is outside
line 1's window and in no regimen of line 1's. LEN's own reappearance is then
judged against LOT2's regimen, which is POMA — so it is a new agent there, and
opens LOT3.

§11.1 is the reasoning behind this rule and what it costs.


### 4.4 A permissible biosimilar substitute cannot start a line either

**Scenario** — *to confirm; vignette `biosimilar_switch`.*

    d0     1L regimen starts on the reference product
    d+70   the biosimilar of the same agent is dispensed instead
    ---
    no new line — a permissible substitute is the same agent for line purposes

Whether this holds depends on `permissible_subs.csv`, not on the rule. A
substitution the code list does not know about looks like a regimen change, and
starts a line that did not happen.


### 4.5 Same-day starts break `SCT_ALLO > CART > SCT_AUTO > MED`

**Scenario** — *derived.*

    d0     LOT1 starts
    d+200  an allogeneic transplant and a new agent on the same date
    ---
    the line starts as SCT_ALLO, not MED

`LOT_START_TYPE = 'MED'` therefore says a medication won the tie-break, not
which medication: `d_MED` is the earliest qualifying agent and the drug is not
kept.


### 4.6 An allogeneic line spans one day and carries no regimen

**Scenario** — *derived; vignette `allo_single_day`.*

    d0     LOT1 starts
    d+200  allogeneic transplant
    d+201  a medication the following day
    ---
    the ALLO line starts and ends on d+200, with a blank LOT_BASE_MEDS
    the d+201 medication starts the line after it

A one-day line with no regimen is the shape that broke the transition Sankeys,
which read a blank regimen as no line at all. Anything using `LOT_BASE_MEDS` to
decide whether a line exists will miss it.


### 5.1 A 90-day gap is running out

**Scenario** — *derived; vignettes `map_gap_within` / `map_gap_beyond`.*

    d0                                1L regimen starts
    d+60                              administrative hold, no claims
    d+(60 + map_discon_gap_days - 1)  the same agent resumes, one day inside
    ---
    no discontinuation — exposure continues across the gap

    d0                                1L regimen starts
    d+60                              no claims
    d+(60 + map_discon_gap_days)      the same agent resumes, exactly at it
    ---
    discontinuation

Prior-authorisation holds and hospitalisations both produce silence in claims,
and neither is a clinical decision to stop. That is what the threshold is
buying, and the inclusive `>=` puts the boundary day on the discontinuation
side.


### 5.2 A run-out chains forward over the drug's own later episodes

**Scenario** — *engine output.* The first example in §4.3: LEN returns 185 days
after its own cover ran out, nothing else in between, so LOT1's run-out chains
forward to the end of the September episode and the line ends 30 September.


### 5.3 A run-out is a discontinuation only once confirmed

**Scenario** — *derived, and checked line by line against the shipped step 04
and step 06 SQL.* Four patients, all running out on day 200, observation ending
day 250 unless stated.

| what follows the run-out | `DISCON_DT` | the line ends | lines |
|---|---|---|---|
| restarts d+210 on a **different** agent | d+200 | `DISCONTINUATION` d+200 | 2 |
| restarts d+210 on **a base agent of this line** | *null* | `STUDY_END` d+250 | 1 |
| never returns | *null* | `STUDY_END` d+250 | 1 |
| never returns, but observed to d+545 | d+200 | `DISCONTINUATION` d+200 | 1 |

Row 2 is the one worth reading twice: the restart is a base agent of this line,
so it cannot open a line (§4.3) and therefore cannot confirm the run-out either.


### 6.1 AUTO codes within 13 days are one transplant

**Scenario** — *derived; vignettes `auto_window_within` / `auto_window_beyond`.*

    d0                             1L regimen starts
    d+40                           transplant code
    d+(40 + sct_auto_window_days)  a second code, still inside the window
    ---
    one transplant, not two. The predicate is <=, so the window is 14 calendar
    days inclusive of the first

    d0                                 1L regimen starts
    d+40                               transplant code
    d+(40 + sct_auto_window_days + 1)  a second code, one day outside
    ---
    two separate AUTO events, subject to the gap and tandem rules

A single admission often bills more than one code. The inclusive `<=` is the
part that is easy to get wrong by one day.


### 6.2 AUTO events under 60 days apart merge

**Scenario** — *derived.*

    d+40   an AUTO event
    d+80   a second AUTO event, 40 days later
    ---
    one AUTO event, not two — 40 < sct_auto_gap_days


### 6.3 A second AUTO within 180 days is a planned tandem

**Scenario** — *to confirm; vignettes `tandem_within` / `tandem_beyond`.*

    d0                             1L regimen starts
    d+30                           first autologous transplant
    d+(30 + sct_tandem_days - 1)   second AUTO, one day inside the window
    ---
    one tandem pair. A tandem is allowed, so LOT1 is not ended by the second

    d0                             1L regimen starts
    d+30                           first autologous transplant
    d+(30 + sct_tandem_days + 1)   second AUTO, one day past the window
    ---
    not a tandem. The second AUTO is excess, and excess AUTO ends LOT1

Planned tandem and unplanned second transplant look identical in claims. The
only thing separating them is the gap, and a patient sitting on it goes either
way — the same two claims, one day apart, land in different lines.

**Scenario** — *to confirm; vignette `excess_auto`.* A third transplant.

    d0                            1L regimen starts
    d+30                          first transplant
    d+(30 + sct_tandem_days - 1)  tandem partner
    d+400                         third transplant
    ---
    the first two are a tandem inside LOT1; the third is excess and ends LOT1


### 6.4 A CAR-T inside line 1's induction window is part of line 1

**Scenario** — *derived.*

    d0     1L regimen starts
    d+21   CAR-T, three weeks into induction
    ---
    LOT1 only. The CAR-T is part of LOT1's induction

    d0     1L regimen starts
    d+70   CAR-T, outside the 60-day window
    ---
    LOT1 ends d+69, and LOT2 starts d+70 as a CAR-T-started line

Before the rule the first of those came out as **two** lines — `CART_INIT`
closed LOT1 the day before the infusion and LOT2 opened as a CAR-T-started line.
A CAR-T that soon after 1L started is not a second line; it is the same
treatment episode, or an index date in the wrong place.

A CAR-T acts on a line boundary in four places, and the rule reaches all four —
stopping only one moves the problem rather than fixing it:

| Where | Without the rule | With it |
|---|---|---|
| `lot1_sct` | `FIRST_CART_DT` feeds `LOT1_TX_ENDDATE`, ending LOT1 as `SCT_CART` | an in-induction CAR-T is not a line-ending SCT |
| `lot1_base_end` | `CART_INIT_FLG` ends LOT1 at `FIRST_CART_DT − 1` | the flag cannot be set by an in-induction CAR-T |
| LOT2 `d_CART` | the same infusion opens LOT2 | excluded as a start candidate — **only while line 1 is still running** |
| `POST_RUNOUT_TRIGGER_FLG` | an in-window CAR-T after the run-out confirmed nothing | asks whether **any** ALLO or CAR-T falls after the run-out, as an existence test rather than against a date |

The last two are the pair that has to agree, and they are the fix. Both are
about an infusion arriving after the line's treatment stopped, so both treat it
as line 2's business: it opens the line, and it confirms the run-out that closed
line 1. Read without that condition, the start candidate was refused *and* the
run-out went unconfirmed by it — which is how one infusion could fall out of the
algorithm altogether.

**Scenario** — *derived.* The line has ended, so the exemption does not reach
the infusion.

    d0     LEN starts, 30 days of cover
    d+29   LEN runs out, and is later confirmed (§5.3)
    d+40   CAR-T — inside d0–d+59, but after line 1 ended
    ---
    LOT1  d0 -> d+29   DISCONTINUATION
    LOT2  d+40         CAR-T-started

The CAR-T also confirms the d+29 run-out in its own right, through
`POST_RUNOUT_TRIGGER_FLG`, so the line does not need the full 90 days of
observation to close. That arm asks whether *any* ALLO or CAR-T falls after the
run-out — an existence test over the transplant rows, not a comparison against
the line's earliest infusion. The distinction is the whole rule when a patient
has more than one:

    d0     LEN starts
    d+20   first CAR-T — absorbed, LOT1 is running
    d+39   LEN runs out
    d+50   second CAR-T — after the run-out, still inside d0–d+59
    d+100  observation ends, 61 days after the run-out
    ---
    LOT1  d0 -> d+39   DISCONTINUATION, confirmed by the d+50 infusion
    LOT2  d+50         CAR-T-started

Neither of the line's summary dates can see the d+50 infusion here.
`FIRST_CART_DT` is `min()` over the line, so it is d+20 and not after the
run-out; `ENDING_CART_DT` is null, because the exemption nulls both. Only
asking the rows directly finds it. Read without the still-running condition,
this patient had LOT1 ending d+29, no LOT2, and a CAR-T on d+40 belonging to no
line.

`q3_cart_screen()` in `analysis/questions/jul20_studyteam_qs.R` counts the
patients that lands on.


### 6.5 An AUTO inside a line's own window holds that line open

**Scenario** — *to confirm.* A short first fill, then a transplant.

    d0     1L starts on LEN, 20 days supply
    d+19   cover runs out
    d+40   autologous transplant, inside line 1's 60-day window
    ---
    LOT1  d0 -> d+40   SCT_AUTO_CONT
    the transplant is line 1's, and line 1 covers the day it happened

Before this rule the same patient produced a line 1 of `d0 -> d+19`
(`DISCONTINUATION`) and no line 2, because line 2's start gate refuses a
transplant inside line 1's window — so the transplant appeared in no line at all.
§14.5 has the full account.

It cannot outrank an added agent, and the arithmetic rather than the branch
order is why. An agent starting inside the window joins the regimen instead of
being an addition, so `MED_ADD` needs a start on day 60 or later at line 1 — at
or past the furthest a hold date reaches. The same holds on a 30-day and a
45-day line. A tandem partner can reach beyond the window, but a medication
between the two transplants breaks the tandem before it gets there.

**Scenario** — *to confirm.* It loses to a death.

    d0     1L starts on LEN, 20 days supply
    d+19   cover runs out
    d+30   death
    d+40   a transplant claim dated after the death
    ---
    LOT1  d0 -> d+30   DEATH. A line does not outlive the patient

The second is not hypothetical bookkeeping: claims carry service dates after a
recorded death, so the death guard is written into the rule rather than left to
the ordering of the branches.

A transplant at or after an allogeneic transplant or a CAR-T can never reach this
rule — §6.4's censor drops it first — so `SCT_ALLO`, `SCT_CART` and `CART_INIT`
ends are untouched by it.


### 7.1 A line ends at the earliest qualifying event

**Scenario** — *derived.* The earlier event ends the line, whatever its rank.

    d0     LOT1 starts on LEN
    d+90   POMA added, outside the induction window
    d+120  allogeneic transplant
    ---
    LOT1 ends d+89 as MED_ADD, not d+119 as SCT_ALLO

The transplant is first in the order and still loses, because its gate requires
its date to be at or before the added medication's and d+120 is not. The
transplant then opens the next line in the ordinary way.

**Scenario** — *derived.* Same two events, same date.

    d0     LOT1 starts on LEN
    d+90   POMA added, outside the induction window
    d+90   allogeneic transplant
    ---
    LOT1 ends d+89 as SCT_ALLO

Here the gate holds — d+90 <= d+90 — so the order decides, and the transplant
takes the reason. `DEATH` is the one branch not gated on a date comparison: it
is gated on `POST_RUNOUT_TRIGGER_FLG` instead (§7.5).


### 7.2 Within the transplant branch the earliest date wins

**Scenario** — *to confirm; vignette `allo_after_failed_auto`.*

    d0     1L regimen starts
    d+40   autologous transplant
    d+240  allogeneic transplant after relapse
    ---
    the AUTO sits inside LOT1 (§3.4). The ALLO ends the line it falls in and
    opens a one-day SCT_ALLO line (§4.6)

Salvage allo after a failed auto is a different clinical event from a planned
tandem, and the two are told apart by which rule fires, not by a flag.


### 7.3 An added agent then a CAR-T within 45 days is `CART_INIT`

**Scenario** — *derived; vignette `cart_bridge_within`.*

    d0     1L regimen starts
    d+60   bridging agent added, the first day it can be an addition
    d+105  CAR-T, inside the window that opens the day after the addition
    ---
    LOT1 ends CART_INIT at d+104. The bridging agent stays part of LOT1

**Scenario** — *to confirm; vignette `cart_bridge_beyond`.*

    d0     1L regimen starts
    d+60   agent added
    d+107  CAR-T, one day outside the window
    ---
    not CART_INIT. The addition is an ordinary regimen change (§7.4) and the
    CAR-T is handled by the ordinary rules for a CAR-T event

Bridging therapy is given to hold a patient until CAR-T. Counted as its own
line, it inflates every downstream line number.

**Scenario** — *derived.*

    d0     LOT1 starts
    d+200  the regimen runs out
    d+300  bridging agent added
    d+320  CAR-T
    ---
    LOT1 ends DISCONTINUATION at d+200 — not MED_ADD at d+300 — and the CAR-T
    opens the next line


### 7.4 An agent added outside induction is `MED_ADD`

**Scenario** — *derived.*

    d0     LOT1 starts on LEN
    d+90   POMA dispensed, outside the 60-day window and inside LEN's cover
    ---
    LOT1 ends d+89 as MED_ADD, and LOT2 starts d+90 on POMA

**Scenario** — *derived.*

    d0     LOT1 starts on LEN and POMA
    d+120  POMA refilled while its earlier episode is still covered
    ---
    no MED_ADD, and no line boundary. Two patients with the same refill get
    different line counts depending on how much days-supply was left

`MED` line starts use a different comparison — against the *previous* line's
regimen, per §4.3 — and are unaffected.
`Rscript exploration/lot/run_stockpiling_rule.R` counts the hidden boundaries in
`STOCKPILE_ABSORBED_ADD`.


### 7.5 Death, and the run-out it can displace

**Scenario** — *derived.* The patient came back, so the run-out stands.

    d0     LOT1 starts
    d+100  the regimen runs out
    d+130  a new agent
    d+150  death
    ---
    LOT1 ends DISCONTINUATION at d+100, and the new therapy opens LOT2
    the death falls inside LOT2

**Scenario** — *derived.* The patient died before the run-out could be
confirmed, and the death is the only answer available.

    d0     LOT1 starts
    d+100  the regimen runs out
    d+150  death — only 50 days later, and nothing in between
    ---
    LOT1_BASE_DISCON_DT is null: 50 < lot_discon_confirm_days, and no return
    LOT1 ends DEATH at d+150

Observation ends at the death (the cohort clamps `ENDDATE` there), so the
confirmation buffer can never complete for a patient who dies inside it. This
case is what the death branch is for, and it needs no comparison to work.

**Scenario** — *derived, and the case that diverges (§12, §14).* The buffer
completed, and the death still takes the end.

    d0     LOT1 starts
    d+100  the regimen runs out
    d+220  death — 120 days later, and nothing in between
    ---
    LOT1_BASE_DISCON_DT is d+100, confirmed by 120 days of observation
    LOT1 still ends DEATH at d+220

Here the confirmed discontinuation is computed, written to
`LOT*_BASE_DISCON_DT`, and then not used as the end. The line is recorded as
running 220 days when the treatment stopped on day 100, so `LOT_BASE_LENGTH`
carries 120 days with no cover in it, and `TTD` reads the line as ending at the
death. The discontinuation date itself is not lost — it is on the row — so a
reader can recover the other reading without a rebuild, which is the reason
this is recorded rather than treated as urgent.


### 7.6 Disenrollment is not censoring

**Scenario** — *derived.*

    d0     LOT1 starts
    d+300  the patient leaves the plan
    d+500  the study period ends, the line still open
    ---
    LOT1 ends STUDY_END at d+500, and LOT1_BASE_END_CE_SENS carries d+300


### 7.7 Line length is inclusive of both ends

**Scenario** — *derived.*

    LOT1 starts d0 and ends d+29
    ---
    LOT_BASE_LENGTH = 30, not 29

A reader computing their own `datediff` reports every percentile a day short of
the number the rest of the study quotes.


## 8. Belantamab removes the patient, not the line

**Scenario** — *derived; vignette `belantamab_any_line`.*

    d0     1L regimen starts
    d+300  LOT2 starts
    d+500  belantamab given at LOT3
    ---
    the patient loses EVERY line, not just LOT3 onward. They are in LOT_LONG
    and absent from LOT_LONG_FINAL entirely

That is the one shape that makes the two tables hold different *patients*, not
merely different lines. `LOT_LONG_ALLFLAGS` carries every criterion as a 0/1
column whether or not it is enabled; `LOT_LONG_FINAL` is what survives the
enabled ones and is what every downstream reader uses.

Two rules worth knowing: a line the criterion is not asked of **passes** — not
applicable is not a failure, or a criterion aimed at L2 would fail every L1 —
and a predicate evaluating to NULL **fails**, because unknown is not evidence
the line qualifies.

`APPLY_NO_BELANTAMAB` ships `TRUE` because that is the NDMM cohort's exclusion.
It is not automatically right for another cohort, and passing a different cohort
does not change it — the switch has to be set `FALSE` deliberately.


## 9. Five lines are built, and nothing above them

**Scenario** — *derived; vignette `line_beyond_max`.*

    d0        1L starts
    d+1000    a regimen change that would be LOT6
    ---
    no line above LOT5 is built. The patient's later therapy is not represented

A count of lines is a count of lines **built**, not of lines received. The cap
is invisible in the output where line 5 ends by run-out or study end — a capped
patient looks exactly like a completed one. Where line 5 ends by a transplant,
an added medication or a CAR-T, the end reason itself shows that a further
line-opening trigger existed.


## 10. Maintenance is a flag, not a line

**Scenario** — *derived; vignette `maintenance_to_relapse`.*

    d0     1L regimen starts
    d+120  reduced to a single maintenance agent
    d+400  new agents added at relapse
    ---
    no maintenance line. The relapse is handled by the ordinary rules, so the
    line count does not include one

This is a deliberate divergence from algorithms that count maintenance
separately, and it shifts every later line number by one against them.


### 11.2 A drug returning mid-line after a break in supply — INTERPRETATION

**Scenario** — *engine output.*

    d0     LENA, 30 days supply
    d+31   LENA, 90 days supply
    d+73   POMA, 90 days supply
    d+122  LENA again, two days after its own cover lapsed
    ---
    LOT1, LOT2, and LOT3 from d+122 on LENA

LOT3 opens on a two-day lapse in cover. Contrast the §4.3 scenario, where LENA
returned after seven months and opened nothing: what decides it is regimen
membership, not the length of the gap. Here the previous line's regimen is POMA,
so LENA is a new agent against it.
