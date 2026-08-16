# How a line of therapy is built

Every rule the line-of-therapy build applies, the setting that governs it, the
file it lives in, and worked examples run through the engine.

Written from the code, not from the spec — where the two differ, this follows
the code and says so (§13).

Two rules are in the study's numbers as of 2026-08-13 and were not before it:
the CAR-T 60-day induction rule (§12) and the discontinuation confirmation
buffer (§6). Runs before that date differ from this document. The melphalan
line-advancing rule (§14) is **not** in the numbers at all and is marked as such
throughout.

`FILES.md` is the other half of this folder's documentation: what is in it, and
what each file does.

---

## 1. The shape of it

A line starts at the patient's first non-steroid myeloma agent. Any other agent
that starts within the induction window joins that line rather than opening a
new one — 60 days for line 1, 30 days for lines 2 to 5, 45 on a CAR-T-started
line.

A line ends at the first of these events, in this order:

| Priority | Reason | End date |
|---|---|---|
| 1 | transplant or CAR-T | day before the procedure |
| 2 | `CART_INIT` | day before a CAR-T that follows an added agent within 45 days |
| 3 | `MED_ADD` | day before an agent added outside the induction window |
| 4 | `DEATH` | date of death |
| 5 | `DISCONTINUATION` | the date the regimen ran out |
| 6 | `STUDY_END` | end of observation |

Running out is measured per drug: a drug has run out when the gap from the end
of its supply to its next fill is 90 days or more. The line has run out when its
last remaining base agent has.

Five lines are built per patient. The output is `LOT_LONG` — one row per patient
per line — and `LOT_LONG_FINAL`, which is `LOT_LONG` after the line criteria
(§9) and is the table every downstream reader uses.

Smallest possible example. LEN on 1 Jan with 60 days supply, POMA on 1 Feb:

    LOT1  2016-01-01 -> 2016-02-29   LEN POMA

POMA is inside line 1's 60-day window, so it joins the line rather than opening
one. Move it to 2 Mar — day 61 — and it opens line 2 instead:

    LOT1  2016-01-01 -> 2016-02-29   LEN
    LOT2  2016-03-02 -> 2016-03-29   POMA

Everything below is that, with the branches filled in.

---

## 2. The pinned settings

Pinned in `CONTRACT`, `lot/engine/R/build_lot.R`. A run that changes any of them
needs `LOT_CONTRACT_OVERRIDE=TRUE` and records the change in
`CONTRACT_DEVIATIONS` on its status row, which every reader in this repo refuses
as the study's numbers.

| Setting | Value | What it governs |
|---|---|---|
| `induction_window_days` | 60 | LOT1's induction window |
| `lot_n_induction_window_days` | 30 | LOT2+ induction window |
| `cart_consolidation_days` | 45 | consolidation window on a CAR-T-started line |
| `map_discon_gap_days` | 90 | gap that counts as running out of treatment |
| `lot_discon_confirm_days` | 90 | observation required after a run-out to confirm it, unless the patient restarts |
| `medical_day_supply` | 28 | assumed day supply for a medical claim |
| `sct_auto_window_days` | 13 | AUTO claims this many days apart are one transplant |
| `sct_auto_gap_days` | 60 | AUTO events closer than this merge into one |
| `sct_tandem_days` | 180 | second AUTO within this is a planned tandem, not a new line |
| `allo_lot_span` | `single_day` | an ALLO line spans only the ALLO date |
| `max_lot` | 5 | lines built per patient |
| `belantamab_med_abbr` | `BELA` | how belantamab is spelled on the code list |
| `apply_melp_rule` | *(blank)* | the melphalan rule is **off** — see §14 |
| `apply_cart_induction_rule` | `TRUE` | a CAR-T inside LOT1 induction is part of LOT1 — see §12 |
| `melp_med_abbr` | `MELP` | |
| `melp_exposure_days` | 30 | |
| `melp_restart_days` | 60 | |
| `melp_advance_days` | 180 | |
| `melp_sct_days` | 14 | |

The study window (`STUDY_START`, `STUDY_END`) is **not** pinned. It is the
cohort's, passed per run, and recorded in `LOT_RUN_METADATA`: the algorithm is
the same whatever window it reads, and different cohorts have different ones.

---

## 3. What a line is built from

`MAP_STACKED` — one row per patient per medication available period, built in
`lot/engine/R/steps/03_mma_map.R` from rx and medical claims against
`cl_mma_codelist.csv`.

- **Steroids are excluded everywhere.** `MAP_MED_CLASS = 'STEROID'` is filtered
  out before a line starts, before a regimen is assembled, before
  discontinuation, and before an added medication can end a line. Corticosteroids
  are not treated as oncology agents.
- A medical claim carries no day supply, so **28 days** is assumed
  (`medical_day_supply`).
- `MAP_END_DT` is the later of the rx runout and the medical runout.

**A new period opens only for a claim beyond every runout.** One arriving while
cover is live pushes the runout out instead. So a refill inside cover extends
the line by its own days supply rather than moving the end to the refill's own
runout — LEN 1 Jan ds60 covers to 29 Feb, and a LEN refill on 1 Feb ds28 arrives
while cover is live, so the runout is pushed out by 28 days:

    LOT1  2016-01-01 -> 2016-03-28   LEN

That stockpiling is the mechanism behind two of the rules below, and it is a
dispensing artefact rather than a treatment record: Optum supplies no treatment
end date, so cover is `FILL_DT` plus `DAYS_SUP`, pushed out by overlapping
refills.

---

## 4. Line 1

**Start** — the earliest non-steroid MM agent (`steps/04_lot1_base.R`).

**Regimen** — every distinct non-steroid agent given from the start date through
**day 60** (`induction_window_days`). `LOT_BASE_MEDS` and `LOT_MED_CNT` are those
observed agents. Permissible biosimilar substitutes are added to the set used
for discontinuation and added-medication logic, but are **not** counted in
`LOT_MED_CNT` or listed in `LOT_BASE_MEDS`.

**Membership is an episode start in the window, not a fill in it.** The test is
`MAP_START_DT` inside the window (`steps/04_lot1_base.R`,
`steps/10_lot2_5_base.R`), and a refill landing while an earlier episode still
has cover is absorbed into that episode instead of opening a new one. That has
two consequences, and they are not the same thing:

- Cover carried over from the previous line does not join this one, however much
  of the window it spans. Residual cover on an agent the patient has stopped
  filling is a dispensing artefact rather than treatment. The study team settled
  it this way.
- A real fill inside the window is dropped too, when the same agent's earlier
  episode is still open. The protocol counts "all MM therapies received within
  30 days on and following the LOT start date" (July 30 cohort protocol, p.19),
  and the LOT2-5 spec carries that wording in `LOTN_REGIMEN_WINDOW` before
  translating it to `MAP_START_DT` in `LOTN_MED_[MED]`
  (`docs/Part 3/Program Spec/lot2plus_validated.csv`). An episode start is
  narrower than a therapy received.

`lot/validation/run_stockpiling_rule.R` sizes the second case against a
finished run.

**The first AUTO is part of induction.** LOT1 keeps that convention: a
first-ever transplant does not open LOT2. Lines 2 to 5 do not — see §5.

---

## 5. Lines 2 to 5

A line opens on the earliest of four candidate dates, all strictly after the
previous line's end and on or before the end of observation
(`steps/10_lot2_5_base.R`).

| Candidate | Rule |
|---|---|
| `d_MED` | earliest non-steroid MM agent. **Permissible biosimilar substitutes of the previous line's drugs do not trigger.** A restart of a drug that was in the previous line's regimen **does not** — that line extends over its later episodes instead (§11.1) |
| `d_ALLO` | earliest ALLO |
| `d_CART` | earliest CAR-T. At LOT2, one inside LOT1's 60-day induction window is excluded — §12 |
| `d_AUTO` | earliest AUTO that is (i) outside the previous line's applicable window measured from that line's **start** — 0 days if ALLO-started, 44 if CAR-T-started, 29 otherwise — and (ii) not within 180 days of the immediately preceding AUTO (planned tandem) |

Unlike LOT1, a **first-ever AUTO can open a line** here.

**Same-day tie-break:** `SCT_ALLO` > `CART` > `SCT_AUTO` > `MED`.

**Regimen** — non-steroid agents from the start date through **day 30**
(`lot_n_induction_window_days`), or **day 45** on a CAR-T-started line
(`cart_consolidation_days`). An ALLO-started line carries no regimen rows at
all, and spans a single day (`allo_lot_span`).

---

## 6. Running out of treatment

**Two different 90-day rules.** They are easy to conflate because both are 90
days, and they do different things.

### The gap

`map_discon_gap_days` = 90. A patient has **run out** of a drug when the gap
from `MAP_END_DT` to the next `MAP_START_DT` is **90 days or more**. A gap of
90+ days from the last `MAP_END_DT` to the end of observation counts too.

Per drug, not per line. A drug's cover in a line is chained forward over its own
later episodes: a drug that was in this line's regimen cannot open the next
line, so the line it belongs to extends over its return (§5). The chain stops at
the first break caused by a *different* agent — and deliberately narrowly
(`lot/engine/R/prior_regimen.R`):

- a drug in **this** line's own regimen does not break it, and neither does a
  permissible substitute of one, so a second regimen agent refilling mid-line
  cannot truncate the first one's cover;
- steroids never break it;
- transplant and CAR-T are not read here at all. One that ends a line does so at
  a higher priority than `DISCONTINUATION`, so a run-out chained past it never
  surfaces; one that does not end a line — LOT1's induction AUTO, a tandem
  inside 180 days, a CAR-T inside LOT1's window — must not break the chain
  anyway.

The line has run out when its last base agent has.

### The confirmation buffer

`lot_discon_confirm_days` = 90. A run-out is not a discontinuation until it is
confirmed, and there are two ways to confirm it. Either is enough:

- **By observation** — at least `lot_discon_confirm_days` of follow-up remain
  after the run-out, i.e. `datediff(OBS_END_DT, run-out) >= 90`, and nothing
  appears in them.
- **By the patient** — a line-opening trigger appears after the run-out and on
  or before `OBS_END_DT`: a restarted or new non-steroid agent, an ALLO, a
  CAR-T, or a qualifying AUTO. `POST_RUNOUT_TRIGGER_FLG`.

Unconfirmed on both counts, the run-out date is dropped and the line falls
through the cascade (§8) to `DEATH` or `STUDY_END` — censored at the end of
observation rather than closed at the last fill.

The rule is a real-world-data one: no longer seeing fills and having stopped
treatment are different claims, and near the end of the data they cannot be told
apart. That is also exactly why a return confirms. The buffer waits because the
data is absent; a patient who comes back has replaced the absence with evidence,
and there is nothing left to wait for. Waiting anyway would swallow their next
line, since a line censored to `OBS_END_DT` leaves nothing after it for the next
one to start on.

The build takes the same position one branch away: `DEATH` does not outrank
`DISCONTINUATION` when a line-opening trigger sits between the run-out and the
death (§8). Same trigger, same reasoning.

**Where it is applied.** In the end step (`06_lot1_end.R`, and the LOT2-5
equivalent), not where the run-out is computed — `POST_RUNOUT_TRIGGER_FLG` needs
the transplant events, which are not built yet at `04_lot1_base.R`. So
`LOT*_BASE_RUNOUT_DT` is the raw run-out and `LOT*_BASE_DISCON_DT` is the
confirmed one. Anything bounding itself at the run-out — the add-med window —
reads the raw date, because an agent added after the regimen ran out opens the
next line rather than ending this one.

**Scope.** Every line, LOT1 through LOT5, and every LOT type. It runs against
`OBS_END_DT`, so the buffer is measured to death or study end, whichever bounds
that patient — a patient who dies 30 days after running out and never restarts
is censored by this rule, then classified `DEATH` by the cascade.

**What it moves.** End reasons, and for the censored lines their end dates and
`LOT_BASE_LENGTH`. Only patients who were never seen again are affected, so line
counts are unchanged. The effect concentrates in the lines closest to the data
cutoff, so later lines shift more than LOT1. Three patients, all running out on
day 200, observation ending day 250 unless stated:

| | follows the run-out | `DISCON_DT` | line ends | lines |
|---|---|---|---|---|
| restarts on day 210, a **different** agent | a new agent | day 200 | `DISCONTINUATION` day 200 | 2 |
| restarts on day 210, **a base agent of this line** | nothing that can open a line | *null* | `STUDY_END` day 250 | 1 |
| never returns | nothing | *null* | `STUDY_END` day 250 | 1 |
| never returns, observed to day 545 | nothing, but 345 days of it | day 200 | `DISCONTINUATION` day 200 | 1 |

*(verified against the shipped step 04/06 SQL)*

It also catches an agent still covered at the end of observation, which is never
flagged as run out and so cannot give the line a discontinuation date.

The spec is inconsistent here — its `LOT1_BASE` tab carries this rule and its
later end-date tabs re-derive the end date without it. The study team
adjudicated in favour of the tab that has it. QC check **B8** fails the run on
any `DISCONTINUATION` inside the window with no later line to confirm it;
confirmed-by-return lines are legitimate, and lines at the `max_lot` cap are
exempt because no later line would be built there anyway.

**Line length** — `LOT_BASE_LENGTH` is inclusive of both ends: runout date minus
start plus 1 for a discontinuation, end date minus start plus 1 otherwise.

---

## 7. Transplant and CAR-T events

Built in `steps/05_sct.R`, because a transplant appears as several claims.

**AUTO.** Claims within **13 days** of a window's first claim are one transplant,
and the **last** date in the window is taken — the earlier claims are workup, the
last is the infusion. Where a window straddles the 180-day tandem boundary, the
date closest to that boundary is taken instead, so the tandem test lands
correctly. Events less than **60 days** apart are then merged.

**Tandem.** A second AUTO within **180 days** (`sct_tandem_days`) of the one
before it is a planned tandem and does **not** start a new line.

**ALLO and CAR-T** are taken as coded, with no windowing.

Line 1's first autologous transplant is part of induction and does not end the
line. A second one ends it, unless it falls within 180 days of the first — that
is a planned tandem, and then it takes a third. Lines 2 to 5 do not keep this
convention: there the first transplant after the induction window ends the line.

That is about which transplant *ends* a line. One falling after a line has
already ended opens the next line whatever the line number.

---

## 8. How a line ends

Two stages, not one flat list.

**First, which kind of event.** A priority order, not a tie-break on equal dates.
Each branch is gated so it only fires when its event is at or before the runout.

| Priority | Branch | Meaning |
|---|---|---|
| 1 | a transplant or CAR-T | the earliest line-ending SCT of any type — see below |
| 2 | `CART_INIT` | an added medication followed by CAR-T within 45 days. **The line ends the day before the infusion** (`ENDING_CART_DT − 1`) |
| 3 | `MED_ADD` | a non-steroid agent added outside the induction window |
| 4 | `DEATH` | |
| 5 | `DISCONTINUATION` | ran out — 90-day gap, confirmed by 90 days of observation after it or by the patient restarting — §6 |
| 6 | `STUDY_END` | |

**Then, within the SCT branch, the earliest date wins** and the reason names
which type it was — `SCT_AUTO`, `SCT_ALLO` or `SCT_CART`. There is no priority
between the three; an ALLO does not outrank an earlier AUTO.

`SCT_CART` therefore arises two ways: a line that ends at a CAR-T (ending the
day before the infusion), and a CAR-T-started line with no consolidation agent,
which spans a single day. Neither applies to a CAR-T inside LOT1's induction
window — §12.

**An added medication is an episode start, so absorption hides it.** The
candidate test is `MAP_START_DT` after the induction window
(`steps/10_lot2_5_base.R`), against agents absent from **this** line's regimen
— which matches the protocol's rule 2, "initiation of a new MM agent that was
not present in the induction regimen". But a claim landing while an episode of
that agent is still open opens no episode, so it is never a candidate and the
line does not end. Two patients with the same refill get different line counts
depending on how much days-supply was left. `MED` line starts use a different
comparison — against the *previous* line's regimen, per the start rule — and
are unaffected. `lot/validation/run_stockpiling_rule.R` counts the hidden
boundaries in `STOCKPILE_ABSORBED_ADD`.

**`CART_INIT` vs `MED_ADD` is a taxonomy, not a fall-through.** An added
medication followed by a CAR-T within 45 days is bridging and belongs to
`CART_INIT`; it is never re-read as a `MED_ADD` event. So when the CAR-T lands
after the runout, the line ends `DISCONTINUATION` at the runout — not `MED_ADD`
at the bridging agent — and the CAR-T opens the next line.

**The post-runout guard.** `DEATH` outranks `DISCONTINUATION`, but only when no
line-opening trigger sits between the runout and the death. A patient who ran
out, started something new, then died ends that line at the runout — the new
therapy opens the next line.

**Disenrollment is not censoring.** A period ending at disenrollment is
classified `STUDY_END`; there is no `DISENROLLMENT` reason. The `*_CE_SENS`
columns carry the alternative reading.

---

## 9. Criteria applied to finished lines

`lot/engine/R/line_criteria.R`. A criterion is an expression over `lot_long` plus
the lines it applies to, declared as data rather than edited into the step SQL.
One is shipped and on:

**`no_belantamab`** — no belantamab (`BELA`) anywhere from the patient's first
line to the end of observation. It is **patient-level**: the test fails on every
line of an affected patient, so `truncate` leaves them with none. Belantamab
removes the patient rather than the line.

It asks `map_stacked` over the span from the patient's first line to the end of
observation, rather than reading `LOT_BASE_MEDS`, so the answer does not depend
on `max_lot` — "received belantamab in any LOT" cannot mean "in any of the lines
the build got round to constructing".

`on_fail` decides what a failing line does. `flag` adds a column and removes
nothing; `truncate` drops the failing line **and every later one**, because LOT N
is defined against LOT N−1 — removing a middle line would leave LOT1 beside LOT3.
`flag` is the default, so a new criterion cannot change a result until someone
deliberately chooses otherwise.

Two rules worth knowing: a line the criterion is not asked of **passes** (not
applicable is not a failure, or a criterion aimed at L2 would fail every L1), and
a predicate evaluating to NULL **fails** (unknown is not evidence the line
qualifies).

`LOT_LONG_ALLFLAGS` holds every line with every criterion as a 0/1 column,
computed whether or not it is enabled; `LOT_LONG_FINAL` is what survives the
enabled ones and is what every downstream reader uses.

`APPLY_NO_BELANTAMAB` ships `TRUE` because that is the NDMM cohort's exclusion.
It is not automatically right for another cohort, and passing a different cohort
does not change it — the switch has to be set `FALSE` deliberately.

---

## 10. Worked examples

Every line below is the engine's own output. Days supply of 60 for the first LEN
fill unless stated; a medical claim carries 28.

**A second agent inside line 1's window joins it.** LEN 1 Jan, POMA 1 Feb:

    LOT1  2016-01-01 -> 2016-02-29   LEN POMA

**Outside the window it starts a line.** LEN 1 Jan, POMA 2 Mar — day 61, past
the 60-day window:

    LOT1  2016-01-01 -> 2016-02-29   LEN
    LOT2  2016-03-02 -> 2016-03-29   POMA

**A refill inside cover extends the line by its own days supply**, rather than
moving the end to the refill's own runout. LEN 1 Jan ds60 covers to 29 Feb; a LEN
refill on 1 Feb ds28 arrives while cover is live, so the runout is pushed out by
28 days:

    LOT1  2016-01-01 -> 2016-03-28   LEN

**A drug returning does not start a line on itself.** The protocol starts a later
line at "the first administration for a new MM agent that was not part of the
previous LOT regimen", and a drug that *was* that regimen is not such an agent —
however long it has been gone. LEN 1 Jan ds60, nothing else, LEN 1 Sep, 185 days
after cover ran out:

    LOT1  2016-01-01 -> 2016-09-30   LEN

One line, spanning the seven months with no cover. The line extends over the
return rather than a second line opening on it, because the alternative leaves
the September treatment belonging to nothing at all.

The extension stops at any other agent. Where one arrives in between it ends the
line in the ordinary way, and the drug's later episode is judged against the next
line's regimen instead.

**A drug returning while another agent runs.** LEN 1 Jan–28 Mar, POMA 15 Mar–20
May, LEN again 1 May — 34 days after LEN's own cover ended:

    LOT1  2016-01-01 -> 2016-03-14   LEN
    LOT2  2016-03-15 -> 2016-04-30   POMA
    LOT3  2016-05-01 -> 2016-05-30   LEN

POMA starts while LEN is still covered and still opens a line: it is outside line
1's window and in no regimen. LEN's own reappearance opens another.

### The same cases as a table

Run through the engine. Days-supply of 30 assumed where a case does not give one.

| claims | result |
|---|---|
| LENA 1 Jan ds60, POMA 1 Feb | LOT1 only, regimen `LENA POMA` — POMA is inside LOT1's 60-day window |
| LENA 1 Jan ds60, POMA 1 Mar, LENA 12 Mar | LOT1 only, regimen `LENA POMA` — 1 Mar is day 59, the window's last day |
| LENA 1 Jan ds60, POMA 2 Mar, LENA 12 Mar | LOT1 ends 1 Mar; LOT2 from 2 Mar, regimen `LENA POMA` |
| LENA 1 Jan ds60, LENA 1 Feb ds30 | LOT1 only — the refill is inside cover and pushes the run-out out |
| LENA 1 Jan ds60, LENA 1 Mar ds30 | LOT1 only — 1 Mar is the last covered day, so still inside |
| LENA 1 Jan ds60, LENA 1 Sep ds30 | **LOT1 only**, 1 Jan -> 30 Sep, `DISCONTINUATION` — LENA was LOT1's regimen, so its return cannot open LOT2 — §11.1 |
| LENA 1 Jan ds30, LENA 1 Feb ds90, POMA 15 Mar ds90, LENA 3 May | LOT1, LOT2, **LOT3 from 3 May on LENA** — §11.2, opened by a two-day gap in cover |

The last two are decided by regimen membership, not by the length of the gap. In
the first, LENA returns to a line whose regimen is LENA, so it cannot open a new
one however long it was away. In the second the previous line's regimen is POMA,
so LENA is a new agent against it and LOT3 opens on a two-day lapse in cover.

### CAR-T

A CAR-T inside line 1's 60-day induction window belongs to line 1. It does not
end that line and it does not start one. Outside the window it does both: the
line ends the day before the infusion and the CAR-T opens the next line.

An agent added and then followed by a CAR-T within 45 days is bridging therapy.
The line ends `CART_INIT` the day before the infusion, and the bridging agent
stays in that line rather than starting a regimen of its own.

The rule does not reopen a closed line. If line 1 ended on day 30 for some other
reason and the CAR-T falls on day 40, line 1 still ends on day 30. The rule stops
that infusion starting a line; it does not extend the one before it.

---

## 11. Recorded decisions

Choices that change where a line begins or ends. Each says what the code does,
what the written authorities say, and which kind of open question it is.

| kind | what it means |
|---|---|
| DOCUMENT CONFLICT | two written authorities disagree and the code follows one |
| INTERPRETATION | the protocol states a rule, and turning it into claims logic needed a choice the protocol does not make. Needs an SME, not a protocol reading |
| DEVIATION | the code does something the written authorities do not support, on purpose |

### 11.1 A drug returning after its line has already ended — INTERPRETATION

**The code** does not open a new line on it. `lot/engine/R/prior_regimen.R`
excludes the previous line's regimen *and* its permissible biosimilar
substitutes from the agents that can start the next line. The line that owns
the drug extends over its later episodes instead, stopping at any *other* agent
arriving in between.

**The protocol** says a subsequent LOT starts at "the first administration for a
new MM agent **that was not part of the previous LOT regimen**". A drug that *was*
the previous regimen is not such an agent, so it cannot start the next line. The
code follows this reading.

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

### 11.2 A drug returning mid-line after a break in supply — INTERPRETATION

**The code** ends the line and opens the next one. The added-medication query
(`steps/10_lot2_5_base.R`, `steps/04_lot1_base.R`) takes agents outside this
line's regimen whose **`MAP_START_DT`** falls after the induction window.

A supply episode reopens whenever cover lapses by a single day, so a refill
collected late produces a new `MAP_START_DT` and reads as an initiation. The
patient never stopped the drug.

**The spec carries both readings in one row.** `lot1baseend_validated.csv` row 34,
`LOT1_BASE_1ST_ADD_MED_DT / LOT1_BASE_1ST_ADD_MED`:

| column | text |
|---|---|
| Definition (Validated from Protocol) | "the LOT end date is the day before the **first administration/dispense date** of the new agent" |
| Optum CDM Implementation | "where the medication is NOT in base_meds (induction + permissible subs). **`MAP_START_DT`** from MAP algorithm" |

For an agent the patient has never had, those two are the same date. For one
already in hand they are not.

The same row already carves out one exemption — "Per Rule 1: permissible
substitutions ... 'do not advance the LOT'" — so the concept of an appearance
that must not advance the line exists in the spec. It was never extended to a
drug returning after a break that is not a discontinuation.

**Status.** Open. The mechanism to settle it is already built and configurable —
what is missing is a ruling on whether a supply episode opening counts as an
initiation, which is a clinical question and not a protocol reading.

### 11.3 The measure both rules already have

`MAP_DISCON_GAP_DAYS,90` has been in `lot/engine/config.csv` since that file's
first commit, and `steps/03_mma_map.R` sets `MAP_DISCON_FLG` from it on every
episode: 1 where at least that many days separate an episode's `MAP_END_DT`
from the next episode's `MAP_START_DT`. It is a setting, not a constant — 30 or
60 is a config value and a rebuild, with no code change.

So nothing is absent. The flag sits on the same `map_stacked` rows the line rules
already select from. What 11.1 and 11.2 come down to is which queries read it:

| query | what it decides | reads the flag |
|---|---|---|
| `discon_per_med` | when the line's cover runs out | yes |
| `first_add_candidates` (`steps/04_lot1_base.R`, `steps/10_lot2_5_base.R`) | whether a returning agent ends the line | **no** |
| `med_cand` (`steps/10_lot2_5_base.R`) | whether a returning agent starts the next line | **no** |

Three predicates that do not consult a flag already on the row. That is the size
of it — not a missing parameter and not a missing concept. The added-medication
and line-start queries have never read the flag; this is original behaviour, not
something a refactor lost.

### 11.4 What has been measured, and what has not

`lot/validation/run_stockpiling_rule.R` and
`lot/validation/run_rechallenge_evidence.R` size 11.2 against a finished run.
Against the production run:

- **898 line boundaries in 624 patients** sit on a prior episode with
  `MAP_DISCON_FLG = 0` — the drug was still running by the build's own reckoning.
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

### 11.5 Not in dispute

- Leftover days-supply does not carry an agent into the next line's regimen. The
  study team settled this and the code matches it.
- Permissible biosimilar substitutions do not advance the line.
- The induction windows: 60 days at LOT1, 30 at LOT2-5, 45 for a CAR-T-started
  line.

---

## 12. The CAR-T 60-day induction rule — **applied**

`apply_cart_induction_rule` is `TRUE` in `CONTRACT`, so this **is** the study's
behaviour. Confirmed by the study team on 2026-08-13. Implementation in
`lot/engine/R/cart_rule.R`.

**A CAR-T inside LOT1's induction window is part of LOT1.** It does not end the
line, and it does not start one.

Before the rule, a CAR-T three weeks into first-line induction came out as **two
lines** — `CART_INIT` closed LOT1 the day before the infusion and LOT2 opened as
a CAR-T-started line. A CAR-T that soon after 1L started is not a second line; it
is the same treatment episode, or an index date in the wrong place.

**LOT1 and 60 days only.** LOT2 onward keep their own windows, and a CAR-T there
behaves as it always has.

A CAR-T acts on a line boundary in three places, and the rule reaches all three —
stopping only one moves the problem rather than fixing it:

| Where | Without the rule | With it |
|---|---|---|
| `lot1_sct` | `FIRST_CART_DT` feeds `LOT1_TX_ENDDATE`, ending LOT1 as `SCT_CART` | the in-induction CAR-T is not a line-ending SCT |
| `lot1_base_end` | `CART_INIT_FLG` ends LOT1 at `FIRST_CART_DT − 1` | the flag cannot be set by an in-induction CAR-T |
| LOT2 `d_CART` | the same infusion opens LOT2 | it is excluded as a start candidate |

The post-runout guard is gated the same way, since it is documented as mirroring
LOT2's start candidates.

**What it deliberately does not do.** It does not extend LOT1 to swallow a CAR-T
that arrived after LOT1 had already ended for some other reason. If a runout or
an added medication closed the line on day 30 and the CAR-T is on day 40, the
line ended on day 30 — the rule stops that CAR-T starting a line, it does not
reopen a closed one. `q3_cart_screen()` in `lot/questions/jul20_studyteam_qs.R`
counts those patients.

**Turning it off** needs `LOT_CONTRACT_OVERRIDE=TRUE` and
`APPLY_CART_INDUCTION_RULE=FALSE`, and is recorded as a deviation like any other
contract change. With it off, the generated SQL is unchanged from before the rule
existed.

**Effect on `SCT_CART` and `CART_INIT` counts.** Both fall. Not by the same
patients and not by the full affected population: the two reasons are mutually
exclusive, and a patient whose LOT1 already ended earlier for a competing reason
carried neither of them before the rule, so loses neither now. The affected group
is patients whose LOT1 end was **set by** a CAR-T inside induction.

Numbers from any run before 2026-08-13 are not comparable on those two end
reasons, on LOT1 length, or on line counts for those patients.

---

## 13. Where this differs from the written protocol

- **The melphalan rule is not in the numbers.** It is requested and built, but
  only in the melphalan cells. §14.
- **The CAR-T induction rule is in the numbers** as of 2026-08-13, so runs before
  that date differ on `SCT_CART`, `CART_INIT`, LOT1 length and line counts for
  the patients it touches. §12.
- **The discontinuation confirmation buffer is in the numbers** as of 2026-08-13,
  resolving a contradiction inside the spec rather than departing from it: the
  `LOT1_BASE` tab requires 90 days of observation after a run-out and the later
  end-date tabs do not. The build follows the tab that has it, on every line.
  Runs before that date differ on end reasons, end dates and `LOT_BASE_LENGTH`
  for lines running out near the cutoff. §6.
- **The buffer is confirmed two ways, and the spec names only one.** The
  `LOT1_BASE` tab requires observation after a run-out; it says nothing about a
  patient who restarts inside that window. The build treats the restart as
  confirmation in its own right, so the run-out stands and the next line opens
  (§6). Gating on elapsed observation alone would have merged those two lines
  into one. §8's `POST_RUNOUT_TRIGGER_FLG` already takes that position against
  `DEATH`.
- **B.2 removes a boundary without holding the line open.** §14.
- **Disenrollment is not censoring** in the primary analysis. §8.
- **Maintenance is not implemented.** There is no maintenance concept in the
  build; `MAINTENANCE_END` and `SCT_NO_MAINT` are not final end reasons and those
  cases route by their earliest applicable event. Maintenance is a descriptive
  flag (`contains_mtx_reg`) and nothing more. This is a deliberate divergence
  from algorithms that count a maintenance line, and it shifts every later line
  number by one against them.
- **`max_lot` is 5.** Nothing above line 5 is built. A capped patient is
  indistinguishable from a completed one **where line 5 ends by runout or study
  end**; where it ends by a transplant, an added medication or CAR-T, the end
  reason itself shows a further line-opening trigger existed.

---

## 14. The melphalan rule — **proposed, not applied**

`apply_melp_rule` is blank in `CONTRACT`, so **the study's numbers do not
include this rule.** It is built only in the three melphalan cells
(`lot/melphalan/`), each of which records the deviation. What follows describes
those cells, not the study cohort.

### 14.1 Why melphalan is the drug this is asked about

High-dose melphalan is the conditioning for autologous transplant, so a MELP
claim is often the transplant rather than a drug in a regimen. The build already
treats a transplant this way — `sct_tandem_days` is 180, and a second AUTO within
180 days is a planned tandem that does not end the line, while one beyond 180 days
is excess and does.

The proposed rule is the same 180-day reasoning applied to the drug claim. That
matters where the transplant procedure code is absent — a transplant billed
elsewhere leaves the melphalan claim as the only evidence it happened.

### 14.2 The rule as asked

An exposure is one administration; doses less than **30 days** apart
(`melp_exposure_days`) are the same exposure. Consecutive exposures are then
judged as a pair, by the gap between them and by whether the first sits inside
the line's induction window:

| Branch | Condition | Effect |
|---|---|---|
| A.1 | inside induction, gap < 180 | no boundary |
| A.2 | inside induction, gap ≥ 180 | the later dose advances the line |
| B.1 | outside induction, gap < 60 | this dose starts a line |
| B.2 | outside induction, 60 ≤ gap < 180 | **no boundary** — both doses stay in the current line |
| B.3 | outside induction, gap ≥ 180 | the later dose advances the line |

### 14.3 Proposed against current, branch by branch

Today there is no melphalan-specific rule: MELP is an ordinary MM agent, a
medical claim covers 28 days, and a repeat dose of a drug already in the regimen
extends the line rather than advancing it — `LOT1_BASE_DISCON_DT` is
`max(MAP_END_DT)` across the base agents with no upper bound on the date
(`04_lot1_base.R`), so a second MELP dose at any distance pushes the line's
discontinuation date out past itself, and can then never start a line.

| | first dose | next dose | proposed | today | |
|---|---|---|---|---|---|
| A.1 | inside induction | < 180 d | does not advance | does not advance — the dose extends `DISCON` | agrees |
| A.2 | inside induction | >= 180 d | advances at the later dose | does not advance — same extension, at any distance | differs |
| B.1 | outside induction | < 60 d | advances, starting at the first dose | advances, starting at the first dose | agrees, incidentally |
| B.2 | outside induction | 60-179 d | does not advance | advances at the first dose | differs |
| B.3 | outside induction | >= 180 d | later dose starts a line on its own date | advances at the first dose | differs |

B.1 agrees for a different reason. Today a MELP dose first seen outside the
induction window is an added medication, so it ends the current line the day
before itself and starts the next one on its own date — whatever the second dose
does, and whether or not there is one.

The rule moves in both directions, so the net effect on line counts is not
derivable: A.2 makes more lines, B.2 and B.3 make fewer, and which wins depends
on how many patients sit in each branch.

### 14.4 Two readings of a coded transplant

High-dose melphalan is transplant conditioning, so a melphalan claim and an AUTO
code are often the same clinical event and the transplant rule already fires on
it. The request does not say which rule should win, so both readings are built:

- **`as_asked`** — every exposure judged, including one with a transplant coded
  on it. One clinical event can end a line twice.
- **`yield_to_sct`** — an exposure with an AUTO within `melp_sct_days` (14) is
  left to the transplant rule; the melphalan rule fills only the gap where a
  transplant left no procedure code.

Yielding looks at the exposure the boundary would fall on, not the one being
judged. The A.2 and B.3 boundaries land on the next exposure, so that is whose
transplant code decides it.

Three complete builds come out of that — `reference` (the contract build,
unchanged), `as_asked` and `yield_to_sct` — rather than arithmetic on a finished
run, because the engine is sequential: a line's end date sets the next line's
start, which sets that line's induction window, which decides which drugs join
its regimen, which sets its discontinuation date, which decides whether the line
after it starts at all. Move one melphalan boundary and every line after it for
that patient is different.

### 14.5 What B.2 does and does not do

Suppressing B.2's boundaries stops melphalan ending the line at either dose.
**It does not hold the line open to the second dose.**

Both doses, not one. The pair is judged from the row that carries the gap, and
the later dose has no gap of its own — so removing only the first dose's boundary
would leave the later one judged by nothing, falling through to the engine and
advancing the line at exactly the boundary B.2 says is not there.

What is still not done is holding the line open. A line's discontinuation date is
its base agents' last cover, and a melphalan first seen outside the induction
window is not a base agent, so it does not extend that date. Take a line starting
on day 0 whose base regimen runs out on day 120, with melphalan on day 100 and
again on day 170. Neither dose ends the line now; the regimen still runs out on
day 120 for reasons that have nothing to do with melphalan, and the day-170 dose
falls in whatever line follows.

Holding it open would require melphalan to join a regimen whose induction window
it never entered — a change to what a regimen means rather than a setting, and a
clinical decision. It is open question 6 below, and `n_b2_line_starts` counts
what it decides.

`n_b2_line_starts` is the B.2 population rather than a proxy for it. A line
counts only when all four hold: the previous line ended by running out;
melphalan started this line, which needs the start type to be `MED` as well as
the exposure to be on the start date, since a transplant coded the same day takes
the start; the exposure immediately before it sits in the previous line, outside
that line's own induction window; and the two are 60 to 179 days apart.
`n_b2_melp_only` is the subset where no other non-steroid agent starts on the
same date — a `MED` start says a medication won the tie-break and not which one,
so a line another agent would have started anyway is no evidence either way.

### 14.6 Where the rule lives

`lot/engine/R/melp_rule.R`. It has to be inside the engine: that package builds
the lines and reads nothing from a sibling, and the rule needs each line's own
induction window, which exists only while that line is being built.

It changes one thing — which melphalan MAP rows may be an added medication, and
on what date:

- **SUPPRESS** an exposure the engine takes as an add and the rule does not:
  outside induction, next exposure 60 days or more away. That is B.2 and B.3,
  where the first dose does not advance — and B.2's later dose, which does not
  advance either.
- **INJECT** the exposures the rule advances at and the engine has no candidate
  for: the later dose of a 180-day-or-more pair at its own date (A.2, B.3), and
  the first dose of a B.1 pair.

Off is the absence of the rule rather than a setting of it: blank, every hook
emits an empty string, and the SQL the engine builds is the SQL it built before
the file existed.

### 14.7 The worked examples

Four patient examples came with the restated request, each drawn twice — as the
build classifies it today and as the rule would.

| | the pair | branch | reclassified as |
|---|---|---|---|
| 1 | first dose outside induction, next +90 d | B.2 | no new line at either dose |
| 2 | ...then a third +210 d | B.3 | a new line at the third dose |
| 3 | first dose inside induction, +50 d, +70 d | A.1 then B.2 | unchanged |
| 4 | first dose inside induction, +50 d, then +190 d | A.1 then B.3 | a new line at the third dose |

Example 1 is the one that earns its place. It is the only shape in which the
later dose of a B.2 pair is the patient's last exposure, and that dose was being
judged by nothing: the pair is judged from the row that carries the gap, and a
trailing dose has none, so it fell through to the engine and started a line at
exactly the boundary B.2 says is absent. Examples 2, 3 and 4 all reproduce
without it.

### 14.8 What has to be settled

The measurement program had to pick an answer to some of these to run at all.
Where it did, the assumption is named. An assumption is not a decision — these
are still the study team's to settle, and changing one changes the counts.

1. Does the rule apply to melphalan alone, or to any agent used as transplant
   conditioning? As written it is drug-specific, which is a first for this
   algorithm — every other rule is about classes, windows and gaps. *The program
   assumes melphalan alone, and takes the abbreviation from `melp_med_abbr` so a
   second agent is a setting rather than an edit.* **Open.**

2. What happens when the transplant procedure code is also present? The AUTO rule
   and this rule would both fire on one clinical event. *The program runs both
   readings and writes the mode onto every row; neither is treated as the answer
   — §14.4.* **Open.**

3. Is 30 days the exposure threshold, or 28? The build's medical day supply is
   28, so MAPs already merge on that boundary. *The program uses 30, the number
   the request names.* **Confirmed by the worked examples.**

4. Third and later exposures. The rule is written for a first and a next dose.
   *The program judges consecutive pairs, so a third exposure is judged against
   the second.* **Confirmed by examples 3 and 4.**

5. Does it apply at every line, or only at 1L? "The induction window" is 60 days
   at 1L and 30 at 2L and later, so the branches land differently. *The program
   applies it at every line, using that line's own window.* **Confirmed by
   examples 3 and 4.**

6. In B.2, does "both doses stay in the current line" mean the line has to be
   held open to the second dose? The two are not the same thing, and the build
   can only do the first without a further decision. Half of this is settled: the
   worked examples say the second dose starts no line, and the boundary is
   removed at both doses. What is left open is whether the line has to be held
   open to reach it — see §14.5. **Open**, and `n_b2_line_starts` is the number
   that settles it.

### 14.9 The mixed-yield pair

A pair whose first dose sits beside a transplant but whose second does not
currently does not advance at the second. The other reading — that a boundary
asks only about the exposure it falls on — would advance it. No worked scenario
carries a coded transplant, so none of them tells the two apart. Open.

---

## 15. Which file holds which rule

| Rule | File |
|---|---|
| Settings, contract, metadata | `lot/engine/R/build_lot.R` |
| MAP stacking, day supply, runout | `lot/engine/R/steps/03_mma_map.R` |
| LOT1 start, regimen, run-out | `lot/engine/R/steps/04_lot1_base.R` |
| Transplant events, tandem | `lot/engine/R/steps/05_sct.R` |
| LOT1 end cascade, confirmation buffer | `lot/engine/R/steps/06_lot1_end.R` |
| LOT2-5 start, regimen, end, confirmation buffer | `lot/engine/R/steps/10_lot2_5_base.R` |
| The prior-regimen rule and the run-out chain | `lot/engine/R/prior_regimen.R` |
| Line criteria, truncation | `lot/engine/R/line_criteria.R` |
| Melphalan rule | `lot/engine/R/melp_rule.R`, `lot/melphalan/` |
| CAR-T induction rule | `lot/engine/R/cart_rule.R` |
| CAR-T affected-patient screen | `lot/questions/jul20_studyteam_qs.R` |

## 16. What stops a run

A cohort whose own build did not finish. A cohort that does not fit the study
window the run was given. A setting that differs from the pinned contract without
an explicit override. A code list that cannot be read, or one failing a
consistency check that is not waivable. A `LOT_LONG` whose lines overlap, run
backwards, skip a line number or end after observation. A line that ends in a way
these rules cannot produce.
