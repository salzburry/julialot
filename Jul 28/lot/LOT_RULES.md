# The LOT algorithm, rule by rule

Every rule the line-of-therapy build applies, with the setting that governs it
and the file it lives in. Written from the code, not from the spec — where the
two differ, this follows the code and says so.

The melphalan line-advancing rule (§9) is **not** in the contract build and is
marked as such throughout. Two rules **are**, both as of 2026-08-13: the CAR-T
60-day induction rule (§10) and the discontinuation confirmation buffer (§3).
Runs before that date differ from this document.

---

## 1. Settings

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
| `apply_melp_rule` | *(blank)* | the melphalan rule is **off** — see §9 |
| `apply_cart_induction_rule` | `TRUE` | a CAR-T inside LOT1 induction is part of LOT1 — see §10 |
| `melp_med_abbr` | `MELP` | |
| `melp_exposure_days` | 30 | |
| `melp_restart_days` | 60 | |
| `melp_advance_days` | 180 | |
| `melp_sct_days` | 14 | |

---

## 2. What a line is built from

`MAP_STACKED` — one row per patient per medication administration period, built
in `steps/03_mma_map.R` from rx and medical claims against
`cl_mma_codelist.csv`.

- **Steroids are excluded everywhere.** `MAP_MED_CLASS = 'STEROID'` is filtered
  out before a line starts, before a regimen is assembled, before
  discontinuation, and before an added medication can end a line. Corticosteroids
  are not treated as oncology agents.
- A medical claim carries no day supply, so **28 days** is assumed
  (`medical_day_supply`).
- `MAP_END_DT` is the later of the rx runout and the medical runout.

---

## 3. Running out of treatment

**Two different 90-day rules.** They are easy to conflate because both are 90
days, and they do different things.

**The gap** (`map_discon_gap_days` = 90). A patient has **run out** of a drug
when the gap from `MAP_END_DT` to the next `MAP_START_DT` is **90 days or
more**. A gap of 90+ days from the last `MAP_END_DT` to the end of observation
counts too.

Per drug, not per line. A drug's cover in a line ends at its **first** run-out —
a later fill of the same drug is a restart, and a restart opens the next line
(§6). The line has run out when its last base agent has.

**The confirmation buffer** (`lot_discon_confirm_days` = 90). A run-out is not
a discontinuation until it is confirmed, and there are two ways to confirm it.
Either is enough:

- **By observation** — at least `lot_discon_confirm_days` of follow-up remain
  after the run-out, i.e. `datediff(OBS_END_DT, run-out) >= 90`, and nothing
  appears in them.
- **By the patient** — a line-opening trigger appears after the run-out and on
  or before `OBS_END_DT`: a restarted or new non-steroid agent, an ALLO, a
  CAR-T, or a qualifying AUTO. `POST_RUNOUT_TRIGGER_FLG`.

Unconfirmed on both counts, the run-out date is dropped and the line falls
through the cascade (§7) to `DEATH` or `STUDY_END` — censored at the end of
observation rather than closed at the last fill.

The rule is a real-world-data one: no longer seeing fills and having stopped
treatment are different claims, and near the end of the data they cannot be
told apart. That is also exactly why a return confirms. The buffer waits
because the data is absent; a patient who comes back has replaced the absence
with evidence, and there is nothing left to wait for. Waiting anyway would
swallow their next line, since a line censored to `OBS_END_DT` leaves nothing
after it for the next one to start on.

The build takes the same position one branch away: `DEATH` does not outrank
`DISCONTINUATION` when a line-opening trigger sits between the run-out and the
death (§7). Same trigger, same reasoning.

**Where it is applied.** In the end step (`06_lot1_end.R`, and the LOT2-5
equivalent), not where the run-out is computed — `POST_RUNOUT_TRIGGER_FLG`
needs the transplant events, which are not built yet at `04_lot1_base.R`. So
`LOT*_BASE_RUNOUT_DT` is the raw run-out and `LOT*_BASE_DISCON_DT` is the
confirmed one. Anything bounding itself at the run-out — the add-med window —
reads the raw date, because an agent added after the regimen ran out opens the
next line rather than ending this one.

**Scope.** Every line, LOT1 through LOT5, and every LOT type. It runs against
`OBS_END_DT`, so the buffer is measured to death or study end, whichever bounds
that patient — a patient who dies 30 days after running out and never restarts
is censored by this rule, then classified `DEATH` by the cascade.

**What it moves.** End reasons, and for the censored lines their end dates and
`LOT_BASE_LENGTH`. Only patients who were never seen again are affected, so
line counts are unchanged. The effect concentrates in the lines closest to the
data cutoff, so later lines shift more than LOT1. Three patients, all running
out on day 200, observation ending day 250 unless stated:

| | follows the run-out | `DISCON_DT` | line ends | lines |
|---|---|---|---|---|
| restarts on day 210 | a base agent | day 200 | `DISCONTINUATION` day 200 | 2 |
| never returns | nothing | *null* | `STUDY_END` day 250 | 1 |
| never returns, observed to day 545 | nothing, but 345 days of it | day 200 | `DISCONTINUATION` day 200 | 1 |

*(verified against the shipped step 04/06 SQL)*

It also catches an agent still covered at the end of observation, which is
never flagged as run out and so cannot give the line a discontinuation date.

The spec is inconsistent here — its `LOT1_BASE` tab carries this rule and its
later end-date tabs re-derive the end date without it. The study team
adjudicated in favour of the tab that has it. QC check **B8** fails the run on
any `DISCONTINUATION` inside the window with no later line to confirm it;
confirmed-by-return lines are legitimate, and lines at the `max_lot` cap are
exempt because no later line would be built there anyway.

---

## 4. Transplant events

Built in `steps/05_sct.R`, because a transplant appears as several claims.

**AUTO.** Claims within **13 days** of a window's first claim are one
transplant, and the **last** date in the window is taken — the earlier claims
are workup, the last is the infusion. Where a window straddles the 180-day
tandem boundary, the date closest to that boundary is taken instead, so the
tandem test lands correctly. Events less than **60 days** apart are then merged.

**Tandem.** A second AUTO within **180 days** (`sct_tandem_days`) of the one
before it is a planned tandem and does **not** start a new line.

**ALLO and CAR-T** are taken as coded, with no windowing.

---

## 5. LOT1

**Start** — the earliest non-steroid MM agent (`steps/04_lot1_base.R`).

**Regimen** — every distinct non-steroid agent given from the start date
through **day 60** (`induction_window_days`). `LOT_BASE_MEDS` and `LOT_MED_CNT`
are those observed agents. Permissible biosimilar substitutes are added to the
set used for discontinuation and added-medication logic, but are **not** counted
in `LOT_MED_CNT` or listed in `LOT_BASE_MEDS`.

**Membership is a fill in the window, not cover across it.** The test is
`MAP_START_DT` inside the window, so an episode that opened in the previous line
and is still stockpiled into this one does not join it, however much cover it
carries. Optum supplies no treatment end date — cover is `FILL_DT` plus
`DAYS_SUP`, pushed out by overlapping refills — and a patient who has switched is
no longer filling the old agent, so residual cover is a dispensing artefact
rather than treatment. This bites at LOT2-5, where a continuing oral can span the
whole 30-day window; the protocol's "all MM therapies identified during the first
30 days" reads wider, and the study team settled it this way.

**The first AUTO is part of induction.** LOT1 keeps that convention: a
first-ever transplant does not open LOT2. (LOT2-5 do not — see §6.)

---

## 6. LOT2 through LOT5

A line opens on the earliest of four candidate dates, all strictly after the
previous line's end and on or before the end of observation
(`steps/10_lot2_5_base.R`).

| Candidate | Rule |
|---|---|
| `d_MED` | earliest non-steroid MM agent. **Permissible biosimilar substitutes of the previous line's drugs do not trigger.** A restart of the same drug **does** — the previous line ended by running out, and a fresh fill is a new line. |
| `d_ALLO` | earliest ALLO |
| `d_CART` | earliest CAR-T. At LOT2, one inside LOT1's 60-day induction window is excluded — §10 |
| `d_AUTO` | earliest AUTO that is (i) outside the previous line's applicable window measured from that line's **start** — 0 days if ALLO-started, 44 if CAR-T-started, 29 otherwise — and (ii) not within 180 days of the immediately preceding AUTO (planned tandem) |

Unlike LOT1, a **first-ever AUTO can open a line** here.

**Same-day tie-break:** `SCT_ALLO` > `CART` > `SCT_AUTO` > `MED`.

**Regimen** — non-steroid agents from the start date through **day 30**
(`lot_n_induction_window_days`), or **day 45** on a CAR-T-started line
(`cart_consolidation_days`). An ALLO-started line carries no regimen rows at
all.

---

## 7. How a line ends

Two stages, not one flat list.

**First, which kind of event.** A priority order, not a tie-break on equal
dates. Each branch is gated so it only fires when its event is at or before the
runout.

| Priority | Branch | Meaning |
|---|---|---|
| 1 | a transplant or CAR-T | the earliest line-ending SCT of any type — see below |
| 2 | `CART_INIT` | an added medication followed by CAR-T within 45 days. **The line ends the day before the infusion** (`ENDING_CART_DT − 1`) |
| 3 | `MED_ADD` | a non-steroid agent added outside the induction window |
| 4 | `DEATH` | |
| 5 | `DISCONTINUATION` | ran out — 90-day gap, confirmed by 90 days of observation after it or by the patient restarting — §3 |
| 6 | `STUDY_END` | |

**Then, within the SCT branch, the earliest date wins** and the reason names
which type it was — `SCT_AUTO`, `SCT_ALLO` or `SCT_CART`. There is no priority
between the three; an ALLO does not outrank an earlier AUTO.

`SCT_CART` therefore arises two ways: a line that ends at a CAR-T (ending the
day before the infusion), and a CAR-T-started line with no consolidation agent,
which spans a single day. Neither applies to a CAR-T inside LOT1's induction
window — §10.

**`CART_INIT` vs `MED_ADD` is a taxonomy, not a fall-through.** An added
medication followed by a CAR-T within 45 days is bridging and belongs to
`CART_INIT`; it is never re-read as a `MED_ADD` event. So when the CAR-T lands
after the runout, the line ends `DISCONTINUATION` at the runout - not `MED_ADD`
at the bridging agent - and the CAR-T opens the next line.

**The post-runout guard.** `DEATH` outranks `DISCONTINUATION`, but only when no
line-opening trigger sits between the runout and the death. A patient who ran
out, started something new, then died ends that line at the runout — the new
therapy opens the next line.

**Disenrollment is not censoring.** A period ending at disenrollment is
classified `STUDY_END`; there is no `DISENROLLMENT` reason. The
`*_CE_SENS` columns carry the alternative reading.

**Line length** — `LOT_BASE_LENGTH` is inclusive of both ends: runout date minus
start plus 1 for a discontinuation, end date minus start plus 1 otherwise.

---

## 8. Criteria applied to lines

`lot/engine/R/line_criteria.R`. One is shipped and on:

**`no_belantamab`** — no belantamab (`BELA`) anywhere from the patient's first
line to the end of observation. It is **patient-level**: the test fails on every
line of an affected patient, so `truncate` leaves them with none.

`truncate` drops the failing line **and every later one**, because LOT N is
defined against LOT N−1 — removing a middle line would leave LOT1 beside LOT3.

`LOT_LONG_ALLFLAGS` holds every line with the criteria as columns;
`LOT_LONG_FINAL` is what survives them and is what every downstream reader uses.

---

## 9. The melphalan rule — **proposed, not applied**

`apply_melp_rule` is blank in `CONTRACT`, so **the study's numbers do not
include this rule.** It is built only in the three melphalan cells
(`lot/melphalan/`), each of which records the deviation.

Melphalan doses less than **30 days** apart (`melp_exposure_days`) are one
exposure. Consecutive exposures are then judged as a pair, by the gap between
them and by whether the first sits inside the line's induction window:

| Branch | Condition | Effect |
|---|---|---|
| A.1 | inside induction, gap < 180 | no boundary |
| A.2 | inside induction, gap ≥ 180 | the later dose advances the line |
| B.1 | outside induction, gap < 60 | this dose starts a line |
| B.2 | outside induction, 60 ≤ gap < 180 | **no boundary** — both doses stay in the current line |
| B.3 | outside induction, gap ≥ 180 | the later dose advances the line |

**Two readings of a coded transplant**, which is why three cells are built
rather than two. High-dose melphalan is transplant conditioning, so a melphalan
claim and an AUTO code are often the same clinical event and the transplant rule
already fires on it:

- **`as_asked`** — every exposure judged, including one with a transplant coded
  on it. One clinical event can end a line twice.
- **`yield_to_sct`** — an exposure with an AUTO within `melp_sct_days` (14) is
  left to the transplant rule; the melphalan rule fills only the gap where a
  transplant left no procedure code.

**Open — B.2 does not hold the line open.** The rule as written says both doses
stay in the current line. The implementation removes the boundary but does not
hold the line open to the second dose: where the regimen runs out between them,
the line ends there and the second dose starts the next one. Holding it open
would require melphalan to join a regimen whose induction window it never
entered, which is a clinical decision. Open question 6 in
`lot/questions/melphalan_lot_rule.md`; `n_b2_line_starts` counts what it decides.

**Open — the mixed-yield pair.** A pair whose first dose sits beside a
transplant but whose second does not currently does not advance at the second.
The other reading — that a boundary asks only about the exposure it falls on —
would advance it. No worked scenario carries a coded transplant, so none of them
tells the two apart.

---

## 10. The CAR-T 60-day induction rule — **applied**

`apply_cart_induction_rule` is `TRUE` in `CONTRACT`, so this **is** the study's
behaviour. Confirmed by the study team on 2026-08-13. Implementation in
`lot/engine/R/cart_rule.R`.

**A CAR-T inside LOT1's induction window is part of LOT1.** It does not end the
line, and it does not start one.

Before the rule, a CAR-T three weeks into first-line induction came out as
**two lines** — `CART_INIT` closed LOT1 the day before the infusion and LOT2
opened as a CAR-T-started line. A CAR-T that soon after 1L started is not a
second line; it is the same treatment episode, or an index date in the wrong
place.

**LOT1 and 60 days only.** LOT2 onward keep their own windows, and a CAR-T
there behaves as it always has.

A CAR-T acts on a line boundary in three places, and the rule reaches all three
— stopping only one moves the problem rather than fixing it:

| Where | Without the rule | With it |
|---|---|---|
| `lot1_sct` | `FIRST_CART_DT` feeds `LOT1_TX_ENDDATE`, ending LOT1 as `SCT_CART` | the in-induction CAR-T is not a line-ending SCT |
| `lot1_base_end` | `CART_INIT_FLG` ends LOT1 at `FIRST_CART_DT − 1` | the flag cannot be set by an in-induction CAR-T |
| LOT2 `d_CART` | the same infusion opens LOT2 | it is excluded as a start candidate |

The post-runout guard is gated the same way, since it is documented as
mirroring LOT2's start candidates.

**What it deliberately does not do.** It does not extend LOT1 to swallow a
CAR-T that arrived after LOT1 had already ended for some other reason. If a
runout or an added medication closed the line on day 30 and the CAR-T is on day
40, the line ended on day 30 — the rule stops that CAR-T starting a line, it
does not reopen a closed one. `q3_cart_screen()` in
`lot/questions/jul20_studyteam_qs.R` counts those patients.

**Turning it off** needs `LOT_CONTRACT_OVERRIDE=TRUE` and
`APPLY_CART_INDUCTION_RULE=FALSE`, and is recorded as a deviation like any other
contract change. With it off, the generated SQL is unchanged from before the
rule existed.

**Effect on `SCT_CART` and `CART_INIT` counts.** Both fall. Not by the same
patients and not by the full affected population: the two reasons are mutually
exclusive, and a patient whose LOT1 already ended earlier for a competing
reason carried neither of them before the rule, so loses neither now. The
affected group is patients whose LOT1 end was **set by** a CAR-T inside
induction. `q3_cart_screen()` counts them.

Numbers from any run before 2026-08-13 are not comparable on those two end
reasons, on LOT1 length, or on line counts for those patients.

---

## 11. Where this differs from the written protocol

- **The melphalan rule is not in the numbers.** It is requested and built, but
  only in the melphalan cells. §9.
- **The CAR-T induction rule is in the numbers** as of 2026-08-13, so runs
  before that date differ on `SCT_CART`, `CART_INIT`, LOT1 length and line
  counts for the patients it touches. §10.
- **The discontinuation confirmation buffer is in the numbers** as of
  2026-08-13, resolving a contradiction inside the spec rather than departing
  from it: the `LOT1_BASE` tab requires 90 days of observation after a run-out
  and the later end-date tabs do not. The build follows the tab that has it, on
  every line. Runs before that date differ on end reasons, end dates and
  `LOT_BASE_LENGTH` for lines running out near the cutoff. §3.
- **The buffer is confirmed two ways, and the spec names only one.** The
  `LOT1_BASE` tab requires observation after a run-out; it says nothing about a
  patient who restarts inside that window. The build treats the restart as
  confirmation in its own right, so the run-out stands and the next line opens
  (§3). Gating on elapsed observation alone would have merged those two lines
  into one. §7's `POST_RUNOUT_TRIGGER_FLG` already takes that position against
  `DEATH`.
- **B.2 removes a boundary without holding the line open.** §9.
- **Disenrollment is not censoring** in the primary analysis. §7.
- **Maintenance is not implemented.** There is no maintenance concept in the
  build; `MAINTENANCE_END` and `SCT_NO_MAINT` are not final end reasons and
  those cases route by their earliest applicable event.
- **`max_lot` is 5.** Nothing above line 5 is built. A capped patient is
  indistinguishable from a completed one **where line 5 ends by runout or study
  end**; where it ends by a transplant, an added medication or CAR-T, the end
  reason itself shows a further line-opening trigger existed.

---

## 12. Source files

| Rule | File |
|---|---|
| Settings, contract, metadata | `lot/engine/R/build_lot.R` |
| MAP stacking, day supply, runout | `lot/engine/R/steps/03_mma_map.R` |
| LOT1 start, regimen, run-out | `lot/engine/R/steps/04_lot1_base.R` |
| Transplant events, tandem | `lot/engine/R/steps/05_sct.R` |
| LOT1 end cascade, confirmation buffer | `lot/engine/R/steps/06_lot1_end.R` |
| LOT2-5 start, regimen, end, confirmation buffer | `lot/engine/R/steps/10_lot2_5_base.R` |
| Line criteria, truncation | `lot/engine/R/line_criteria.R` |
| Melphalan rule | `lot/engine/R/melp_rule.R`, `lot/melphalan/` |
| CAR-T induction rule | `lot/engine/R/cart_rule.R` |
| CAR-T affected-patient screen | `lot/questions/jul20_studyteam_qs.R` |
