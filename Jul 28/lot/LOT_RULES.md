# The lines-of-therapy rules

What the build does, rule by rule: the behaviour, the setting that governs it,
the file it lives in, and a worked example.

**Only what the code does.** No rejected
alternatives, no repair history. Where a rule is applied but the clinical
question behind it is still open, the rule is stated here as behaviour and the
question lives on the Open questions sheet of the scenario workbook
(`exploration/lot/run_lot_scenarios.R`). This document is written from the
code and describes nothing else.

The melphalan short-course rule IS in the study's numbers - the study team
adopted it on 2026-08-30 - and it is stated here, at 4.7. The five-branch
melphalan rule they asked for first was measured and not adopted; that one is
an exploration, and `lot/FILES.md` says what its package is.

Each rule names the vignette that tests it. Those are machine-checked cases in
`lot/validation/R/`, not prose - a renamed or deleted vignette fails
`lot/validation/tests/test_vignettes.R`, and a vignette no rule cites fails too.

This folder carries two documents. This one is the rules; `FILES.md` is what is
in the folder and what each file does.

---

## The rules at a glance

| | Rule | Setting | |
|---|---|---|---|
| §2.1 | Steroids are excluded everywhere | — | |
| §2.2 | A medical claim is assumed to cover 28 days | `medical_day_supply` | |
| §2.3 | A claim arriving while cover is live extends the episode | — | |
| §3.1 | Line 1 starts at the first non-steroid MM agent | — | |
| §3.2 | Line 1's induction window is 60 days | `induction_window_days` | |
| §3.3 | A regimen is bounded by the date the line ended | — | |
| §3.4 | Line 1's first autologous transplant is part of induction | — | |
| §4.1 | A later line opens on the earliest of four candidates | — | |
| §4.2 | Later induction is 30 days, and 45 on a CAR-T-started line | `lot_n_induction_window_days`, `cart_consolidation_days` | |
| §4.3 | A drug is held by its line while it runs, and released once stopped | `map_discon_gap_days` | |
| §4.4 | A permissible biosimilar substitute never starts a line | — | |
| §4.5 | Same-day starts break `SCT_ALLO > CART > SCT_AUTO > MED` | — | |
| §4.6 | An allogeneic line spans one day and carries no regimen | `allo_lot_span` | |
| §4.7 | A short melphalan course outside induction does not start a line | `apply_melp_rule`, `melp_simple_course_days` | |
| §5.1 | A 90-day gap is running out | `map_discon_gap_days` | |
| §5.2 | A run-out chains forward until the drug is discontinued | `map_discon_gap_days` | |
| §5.3 | A run-out is a discontinuation only once confirmed | `lot_discon_confirm_days` | |
| §6.1 | AUTO codes within 13 days are one transplant | `sct_auto_window_days` | |
| §6.2 | AUTO events under 60 days apart merge | `sct_auto_gap_days` | |
| §6.3 | A second AUTO within 180 days is a planned tandem | `sct_tandem_days` | |
| §6.4 | A CAR-T inside line 1's induction window is part of line 1 | `apply_cart_induction_rule` | |
| §6.5 | An AUTO inside a line's own window holds that line open | `induction_window_days`, `cart_consolidation_days` | |
| §7.1 | A line ends at the earliest qualifying event | — | |
| §7.2 | Within the transplant branch the earliest date wins | — | |
| §7.3 | An added agent then a CAR-T within 45 days is `CART_INIT` | `cart_consolidation_days` | |
| §7.4 | An agent added outside induction is `MED_ADD` | — | |
| §7.5 | Death, and the run-out it can displace | — | |
| §7.6 | Disenrollment is not censoring | — | |
| §7.7 | Line length is inclusive of both ends | — | |
| §8 | Belantamab removes the patient, not the line | `apply_no_belantamab` | |
| §9 | Five lines are built, and nothing above them | `max_lot` | |
| §10 | Maintenance is a flag, not a line | — | |

---

## 1. The pinned settings

Pinned in `CONTRACT`, `lot/engine/R/build_lot.R`. A run that changes any of them
needs `LOT_CONTRACT_OVERRIDE=TRUE` and records the change in
`CONTRACT_DEVIATIONS` on its status row, which every reader in this repo refuses
as the study's numbers.

| Setting | Value | What it governs |
|---|---|---|
| `induction_window_days` | 60 | line 1's induction window |
| `lot_n_induction_window_days` | 30 | the induction window for lines 2 to 5 |
| `cart_consolidation_days` | 45 | consolidation window on a CAR-T-started line, and the `CART_INIT` bridging window |
| `map_discon_gap_days` | 90 | gap that counts as running out of treatment |
| `lot_discon_confirm_days` | 90 | observation required after a run-out to confirm it, unless the patient restarts |
| `medical_day_supply` | 28 | assumed day supply for a medical claim |
| `sct_auto_window_days` | 13 | AUTO claims this many days apart are one transplant |
| `sct_auto_gap_days` | 60 | AUTO events closer than this merge into one |
| `sct_tandem_days` | 180 | a second AUTO within this is a planned tandem, not a new line |
| `allo_lot_span` | `single_day` | an ALLO line spans only the ALLO date |
| `max_lot` | 5 | lines built per patient |
| `apply_cart_induction_rule` | `TRUE` | a CAR-T inside line 1's induction is part of line 1 — §6.4 |
| `apply_no_belantamab` | `TRUE` | the belantamab criterion — §8 |
| `belantamab_med_abbr` | `BELA` | how belantamab is spelled on the code list |
| `apply_melp_rule` | `simplified` | the melphalan short-course rule — §4.7 |
| `melp_med_abbr` | `MELP` | how melphalan is spelled on the code list |
| `melp_exposure_days` | 30 | melphalan doses closer than this are one course |
| `melp_simple_course_days` | 28 | a course covering this or fewer days is short — §4.7 |

Three more `melp_*` settings — `melp_restart_days`, `melp_advance_days`,
`melp_sct_days` — are pinned but inert. They belong to the five-branch
melphalan rule, which was measured against this build and not adopted. They
are pinned so that a comparison cell rebuilt later is the same comparison the
choice was made on.

Asking for no melphalan rule at all takes the word `off`, not a blank. A blank
cannot travel: the settings loader fills any variable that is unset **or
empty** from `config.csv`, which carries the contract mode, so
`APPLY_MELP_RULE=` arrives as `simplified`. `off` is a different algorithm like
any other, so it needs `LOT_CONTRACT_OVERRIDE=TRUE` and is recorded in
`CONTRACT_DEVIATIONS`.

The study window (`STUDY_START`, `STUDY_END`) is **not** pinned. It is the
cohort's, passed per run and recorded in `LOT_RUN_METADATA`: the algorithm is
the same whatever window it reads, and different cohorts have different ones.

---

## 2. Episodes — what a line is built from

`MAP_STACKED`, one row per patient per medication available period, built in
`lot/engine/R/steps/03_mma_map.R` from rx and medical claims against
`cl_mma_codelist.csv`. Every rule below this one reads episodes, not claims.

### 2.1 Steroids are excluded everywhere

Worked example: `steroid_only_interval`.

`MAP_MED_CLASS = 'STEROID'` is filtered out before a line starts, before a
regimen is assembled, before discontinuation, and before an added medication can
end a line. Corticosteroids are not treated as oncology agents.
`lot/engine/R/steps/10_lot2_5_base.R` — `MAP_MED_CLASS <> 'STEROID'`.

### 2.2 A medical claim is assumed to cover 28 days

A medical claim carries no day supply, so `medical_day_supply` is assumed for
it. `MAP_END_DT` is the later of the rx run-out and the medical run-out.

### 2.3 A claim arriving while cover is live extends the episode

Worked example: `overlapping_oral_refills`.

A new period opens only for a claim beyond every run-out. One arriving while
cover is still live pushes the run-out out instead of opening a second episode.

Optum supplies no treatment end date, so cover is `FILL_DT` plus `DAYS_SUP`,
pushed out by overlapping refills. That stockpiling is a dispensing artefact
rather than a treatment record, and it is the mechanism behind §3.3 and §7.4.

---

## 3. Line 1

`lot/engine/R/steps/04_lot1_base.R`.

### 3.1 Line 1 starts at the first non-steroid MM agent

### 3.2 Line 1's induction window is 60 days

Worked example: `induction_lot1_within` / `induction_lot1_beyond`.

Every distinct non-steroid agent whose episode starts from the start date
through day 59 joins line 1's regimen — `induction_window_days` days inclusive
of day 0. `LOT_BASE_MEDS` and `LOT_MED_CNT` are those observed agents.
Permissible biosimilar substitutes enter the set used for discontinuation and
added-medication logic, but are not counted in `LOT_MED_CNT` and not listed in
`LOT_BASE_MEDS`.

### 3.3 A regimen is bounded by the date the line ended

Every line picks its regimen over its induction window, but no further than its
own end. Where a transplant ends the line early, `REGIMEN_CUTOFF_DT` closes the window
on the day before it. An agent first dispensed after the line was over is not
in its regimen. Which transplants cut the window depends on the line and on the
CAR-T rule: an allogeneic transplant always cuts, at every line. A CAR-T cuts
at lines 2 to 5 always, and at line 1 only when `apply_cart_induction_rule` is
off — with it on, an in-window CAR-T is part of line 1 and ends nothing (§6.4).
An autologous transplant never cuts, because it only extends a line (§6.5). The cutoff bounds the per-drug episode scan too: without
that, a refill of an agent legitimately in the regimen would push the run-out
past the transplant. `04_lot1_base.R`, `10_lot2_5_base.R`, `prior_regimen.R`.

QC check `C1` does not cover this. C1 asks whether a regimen agent has an
episode in the line's *induction window*; the bound is on the line's *actual
span*, and an early transplant makes those two different.

### 3.4 Line 1's first autologous transplant is part of induction

A first-ever transplant does not end line 1 and does not open line 2. Lines 2 to
5 do not keep this convention — there the first transplant outside the previous
line's window ends the line (§4.1).

---

## 4. Lines 2 to 5

`lot/engine/R/steps/10_lot2_5_base.R`.

### 4.1 A later line opens on the earliest of four candidates

All four must fall strictly after the previous line's end and on or before the
end of observation.

| Candidate | Rule |
|---|---|
| `d_MED` | earliest non-steroid MM agent, excluding the previous line's own regimen (§4.3) and its permissible substitutes (§4.4) |
| `d_ALLO` | earliest allogeneic transplant |
| `d_CART` | earliest CAR-T. At LOT2, one inside line 1's induction window is excluded — §6.4 |
| `d_AUTO` | earliest autologous transplant that is (i) outside the previous line's applicable window measured from that line's **start** — 0 days if ALLO-started, 44 if CAR-T-started, 29 otherwise — and (ii) not within `sct_tandem_days` of the immediately preceding AUTO, where **that** AUTO is itself inside the same window (§6.3) |

Unlike line 1, a first-ever AUTO can open a line here.

### 4.2 Later induction is 30 days, and 45 on a CAR-T-started line

Worked example: `induction_lotn_within` / `induction_lotn_beyond`.

Non-steroid agents from the start date through day 29
(`lot_n_induction_window_days`), or day 44 on a CAR-T-started line
(`cart_consolidation_days`).

The test is on `MAP_START_DT` — an episode *beginning* inside the window — and
never on `MAP_END_DT`. Cover running through the window does not put an agent in the regimen. Nor does
a dispense inside the window, if that agent's cover was already live. A claim
arriving under live cover extends the episode it is already in (§2.3). It opens
no new one, so there is no episode start for this test to find.

That has a consequence worth stating plainly, because it inverts the intuition.
An agent from the previous line joins this line's regimen only if its cover
**lapsed** and it restarted inside the window. The more continuously a patient
stays on it, the more certainly it is absent from the later regimen — a patient
taking lenalidomide without a break has one episode, starting at line 1, and it
can never be seen by any later line's window.

There is no prior-regimen exclusion here. `lot{n}_induction_meds` would take a
previous-line agent happily; what keeps it out is only that it has no episode
start to offer. That is a different gate from §4.3, which stops the same agent
*starting* a line and is unconditional.

Whether membership should be an episode start or any fill in the window is an
open question - Q1 on the scenario workbook's Open questions sheet.
`run_scenario_counts.R`'s `4.2-prior-agent-covered-but-not-in-the-regimen`
sizes it.

### 4.3 A drug is held by its line while it runs, and released once stopped

Worked example: `maintenance_to_relapse`.

A drug the patient has not stopped does not start a line: the line that owns it
extends over its later episodes (§5.2). A drug that has **discontinued** does -
an episode arriving after a gap of `map_discon_gap_days` is a restart, and opens
a line like any other agent.

One rule in two halves, and both are needed. `discon_per_med` stops chaining at
the last episode before the gap, so a line does not span its own agent's
absence. The prior-regimen exclusion releases the same drug, so the returning
treatment has a line to go to. `lot/engine/R/prior_regimen.R` carries both, and
the run-out guards that mirror the start candidates read the same definition.

The threshold is `map_discon_gap_days`, not any gap. A drug whose cover lapses
for a day opens a new episode (§2.3) and nothing follows: the run-out chains
over it and the drug is still refused as a line start. It takes 90 days off the
drug. Whether 90 is the right threshold is Q2 on the scenario workbook's Open
questions sheet.

### 4.4 A permissible biosimilar substitute never starts a line

Worked example: `biosimilar_switch`.

The substitute is unioned into the previous line's regimen for this test, so it
is excluded from `d_MED` the same way the reference product is.
`permissible_subs.csv` names the pairs.

### 4.5 Same-day starts break `SCT_ALLO > CART > SCT_AUTO > MED`

### 4.6 An allogeneic line spans one day and carries no regimen

Worked example: `allo_single_day` / `allo_after_failed_auto`.

`allo_lot_span` is `single_day`, and induction rows are suppressed for an
ALLO-started line.

One thing lifts it: a melphalan course the line was carried to (§4.7). The
line then runs to the end of that cover instead of ending on its own start
date. Nothing else reaches it — the short-circuit is tested before any run-out.

### 4.7 A short melphalan course outside induction does not start a line

Worked example: `melp_short_course` / `melp_long_course`, and
`melp_short_course_confirmed` for the agent that does advance the line.

Melphalan doses closer together than `melp_exposure_days` are one course. A
course covering `melp_simple_course_days` or fewer days, whose first day falls
outside the line's own induction window, does not end the line and does not
start the next one. The line is carried instead to the last day that course
covers, capped by the line's own span.

The exception is another agent starting while the course still covers: one the
engine would itself accept against this line, non-steroid, and not melphalan.
Then the line does advance — and it advances on the **melphalan** date, not the
later agent's, so the boundary sits where treatment actually changed.

A course inside the induction window, or one covering more days than the cap,
is left to the engine untouched.

The rule reads days of **cover**, not dose dates, on both tests: what counts as
short, and how far the line is carried. A medical melphalan claim carries the
imputed `medical_day_supply`, so a single administration covers 28 days.

`R/melp_rule.R`, spliced into `06_lot1_end.R` and `10_lot2_5_base.R` — the rule
needs each line's own induction window, which exists only while that line is
being built. Melphalan is also exempted there from the returning-drug
exclusion (§4.3), so that this rule rather than that one decides melphalan's
boundaries.

Why melphalan: a brief course outside induction is usually transplant
conditioning, and conditioning is part of the transplant rather than a line of
treatment of its own.

---

## 5. Running out of treatment

Two different 90-day rules. They are easy to conflate because both are 90 days,
and they do different things.

### 5.1 A 90-day gap is running out

Worked example: `map_gap_within` / `map_gap_beyond`.

A patient has run out of a drug when the gap from `MAP_END_DT` to the next
`MAP_START_DT` is `map_discon_gap_days` **or more**. A gap of that length from
the last `MAP_END_DT` to the end of observation counts too. The predicate is
`>=`, so the threshold day itself is a gap.
`lot/engine/R/steps/03_mma_map.R` — `MAP_DISCON_FLG`.

Per drug, not per line. The line has run out when its last base agent has.

### 5.2 A run-out chains forward until the drug is discontinued

A drug's cover in a line is chained forward over its own later episodes, because
a drug the patient has not stopped cannot open the next line (§4.3). The chain
stops at the first break, and there are two kinds
(`lot/engine/R/prior_regimen.R`):

- **the drug's own discontinuation.** An episode whose gap to the next reaches
`map_discon_gap_days` carries `MAP_DISCON_FLG`, and the chain stops there. So a
line ends at its own run-out rather than spanning the absence, and the
returning episode is a restart that §4.3 releases. This never applies to a
permissible substitute. A gap in a substitute's own episodes does not break the
chain, because a substitution does not advance the line (§4.4) — and breaking
here while §4.3's gates refuse the same drug would end a line on a restart no
line could then own.
- **a different agent that would end the line.** Deliberately narrow: a drug in
  **this** line's own regimen does not break it, and neither does a permissible
  substitute of one — so a second regimen agent refilling mid-line cannot
  truncate the first one's cover; steroids never break it; and transplant and
  CAR-T are not read here at all. One that ends a line outranks `DISCONTINUATION`, so a run-out chained past it
never surfaces. One that does not end a line must not break the chain anyway —
line 1's induction AUTO, a tandem inside `sct_tandem_days`, a CAR-T inside line
1's window.

### 5.3 A run-out is a discontinuation only once confirmed

`lot_discon_confirm_days`. There are two ways to confirm it, and either is
enough:

- **by observation** — at least `lot_discon_confirm_days` of follow-up remain
  after the run-out, `datediff(OBS_END_DT, run-out) >= 90`, and nothing appears
  in them;
- **by the patient** — a line-opening trigger appears after the run-out and on
  or before `OBS_END_DT`: a restarted or new non-steroid agent, an ALLO, a
  CAR-T, or a qualifying AUTO. `POST_RUNOUT_TRIGGER_FLG`.

Unconfirmed on both counts, the run-out date is dropped and the line falls
through the cascade (§7.1) to `DEATH` or `STUDY_END` — censored at the end of
observation rather than closed at the last fill.

The rule is a real-world-data one: no longer seeing fills and having stopped
treatment are different claims, and near the end of the data they cannot be told
apart. That is also exactly why a return confirms. The buffer waits because the
data is absent; a patient who comes back has replaced the absence with evidence,
and there is nothing left to wait for. Waiting anyway would swallow their next
line, since a line censored to `OBS_END_DT` leaves nothing after it for the next
one to start on.

**Where it is applied.** In the end step (`06_lot1_end.R` and the LOT2-5
equivalent), not where the run-out is computed — `POST_RUNOUT_TRIGGER_FLG` needs
the transplant events, which are not built yet at `04_lot1_base.R`. So
`LOT*_BASE_RUNOUT_DT` is the raw run-out and `LOT*_BASE_DISCON_DT` is the
confirmed one. Anything bounding itself at the run-out — the added-medication
window — reads the raw date, because an agent added after the regimen ran out
opens the next line rather than ending this one.

**Scope.** Every line, LOT1 through LOT5, and every LOT type. It runs against
`OBS_END_DT`, so the buffer is measured to death or study end, whichever bounds
that patient — a patient who dies 30 days after running out and never restarts
is censored by this rule, then classified `DEATH` by the cascade.

**What it moves.** End reasons, and for the censored lines their end dates and
`LOT_BASE_LENGTH`. Only patients who were never seen again are affected, so line
counts are unchanged. The effect concentrates in the lines closest to the data
cutoff, so later lines shift more than line 1. It also catches an agent still
covered at the end of observation, which is never flagged as run out and so
cannot give the line a discontinuation date.

QC check **B8** fails a run on any `DISCONTINUATION` inside the window with no
later line to confirm it. Confirmed-by-return lines are legitimate, and lines at
the `max_lot` cap are exempt, because no later line would be built there anyway.

---

## 6. Transplant and CAR-T events

`lot/engine/R/steps/05_sct.R`, because a transplant appears as several claims.
ALLO and CAR-T are taken as coded, with no windowing; the rules below are all
about AUTO.

### 6.1 AUTO codes within 13 days are one transplant

Worked example: `auto_window_within` / `auto_window_beyond`.

Claims within `sct_auto_window_days` of a window's first claim are one
transplant, and the **last** date in the window is taken — the earlier claims
are workup, the last is the infusion. Where a window straddles the tandem
boundary the date closest to that boundary is taken instead, so the tandem test
(§6.3) lands correctly.

### 6.2 AUTO events under 60 days apart merge

After the grouping in §6.1, events less than `sct_auto_gap_days` apart become
one. It is the second pass: §6.1 groups codes into events, this merges events
that are too close together to be two transplants.

### 6.3 A second AUTO within 180 days is a planned tandem

Worked example: `tandem_within` / `tandem_beyond` / `excess_auto`.

A second AUTO is a planned tandem when **both** hold: it is within
`sct_tandem_days` of the one before it, and **nothing happened between the two**
— no non-steroid medication starting, no allogeneic transplant, no CAR-T,
strictly between the two dates. A planned tandem does not end the line and does
not start one.

Beyond `sct_tandem_days`, or with an interruption in the gap, the pair is not a
tandem: the transplant is excess and does both.

Running out of treatment is not an interruption. The clear-gap test asks what
happened, and an absence of treatment is not an event — see §6.5, which is where
that matters.

**The pair must be one a line owned.** Being a tandem is what stops the second
transplant opening a line, so it can only stop it where a line was holding the
pair in the first place. That means the **first** of the two has to fall inside
its line's applicable window — the same window §6.5 uses to decide whether a
transplant holds the line open, and the same one `d_AUTO` measures in §9.2's
condition (i).

Where it does not, the line never reached the second transplant, and refusing
that transplant a line of its own leaves it in none at all:

    d1     line 1 starts on its regimen
    d341   AUTO 1 — 341 days out, far outside the 60-day window, so nothing
           holds line 1 open to anything that follows it
    d400   line 1 ends on its own confirmed run-out
    d520   AUTO 2 — 179 days after AUTO 1, so within sct_tandem_days
    ---
    line 1 ended 120 days before AUTO 2 and cannot contain it. Treating the
    pair as a tandem would refuse AUTO 2 a line too, and the transplant
    would belong to nothing. It opens line 2 as SCT_AUTO instead.

QC check `E5` is what finds this: it starts from the processed transplants
rather than from the lines, so an event in no line has a row to be wrong on.
The narrower reading — that the tandem holds the earlier line open through the
second transplant wherever the first one sits — was measured and rejected: it
moves patients who have no unowned transplant at all, because a hold date
reaches forward and the extended line swallows the additions and allografts
in between.

### 6.4 A CAR-T inside line 1's induction window is part of line 1

`apply_cart_induction_rule` is `TRUE`, so this is the study's behaviour.
`lot/engine/R/cart_rule.R`.

The infusion does not end line 1 and does not start one — **for as long as line
1 is running**. Line 2 onward keep their own windows, and a CAR-T there behaves
as it always has.

The exemption has two conditions, and the second matters as much as the first:

| CAR-T timing | line 1 | result |
|---|---|---|
| inside the 60-day window | still running on that date | absorbed into line 1 — ends nothing, starts nothing |
| inside the 60-day window | **already ended** | opens line 2 in the ordinary way |
| after the window | either | the ordinary CAR-T rules (§7.2) |

Row 2 is the condition, and it is there because the window is measured from line
1's **start** — `TX_DT BETWEEN LOT1_START AND date_add(LOT1_START, 59)`. Without
asking whether line 1 was still running, the window outlives the line whenever
line 1 ends inside its own 60 days, and an infusion in that gap belonged to
nothing at all. "Part of line 1" cannot mean anything for an infusion arriving
after line 1 is over.

**What it deliberately does not do.** It does not extend line 1 to swallow a
CAR-T that arrived after line 1 had already ended for some other reason. Line 1
keeps the end the other rule gave it; the infusion opens the next line.

Turning it off needs `LOT_CONTRACT_OVERRIDE=TRUE` and
`APPLY_CART_INDUCTION_RULE=FALSE`, and is recorded as a deviation like any other
contract change.

### 6.5 An AUTO inside a line's own window holds that line open

A transplant inside a line's applicable window belongs to that line, so the line
cannot be finalised before it. Where the line would otherwise have ended earlier,
it runs to the transplant and ends **on** it, with reason `SCT_AUTO_CONT`.

The windows are each line's own, measured from its start:

| line started by | window | setting |
|---|---|---|
| line 1 (medication) | days 0–59 | `induction_window_days` |
| a medication or an AUTO, lines 2–5 | days 0–29 | `lot_n_induction_window_days` |
| a CAR-T | days 0–44 | `cart_consolidation_days` |
| an allogeneic transplant | the transplant date alone | — |

Only the **first** transplant of a tandem pair need be inside the window. Its
partner may sit outside it and still hold the line open to its own date. Not
arbitrarily far out: the pair must still be within `sct_tandem_days` of each
other, which is what makes it a pair at all (§6.3). What makes that safe is §6.3's clear gap: a pair with a medication start,
an allogeneic transplant or a CAR-T between them is not a tandem at all, so
nothing the extension could swallow survives to be swallowed.  A confirmed
discontinuation between the two does **not** break the pair. Running out of
treatment is an absence, not an event, and §6.3 asks only what happened. So a
line whose regimen ran out on day 59, with a tandem partner on day 150 and
nothing in between, runs to day 150 as `SCT_AUTO_CONT` rather than ending on
day 59 as `DISCONTINUATION`. Under this rule the pair is classified as a tandem, and the gap is what that
classification looks like in claims. Whether it was planned in advance is not
something the claims establish.

Ending **on** the transplant is the opposite of the two other AUTO-shaped
reasons, and deliberately so. `SCT_AUTO` and the transplant branch in §7.2 end a
line the day *before* their event, because there the transplant starts the next
line. Here it closes this one.

---

## 7. How a line ends

Two stages, not one flat list.

### 7.1 A line ends at the earliest qualifying event

**The earliest event wins. The order below decides only which reason is
recorded when two land on the same date.** Every branch is gated against the ones under it. The transplant branch fires
only when `LOT1_TX_ENDDATE <= LOT1_BASE_1ST_ADD_MED_DT` and `<=
LOT1_BASE_DISCON_DT`. `MED_ADD` fires only when the added agent is at or before
the run-out. And so on (`06_lot1_end.R`). So a later event never displaces an
earlier one — with one exception: `DEATH` is not gated on a date comparison, so
a later death displaces an earlier confirmed run-out (§7.5).

| Order | Branch | End date |
|---|---|---|
| 1 | `SCT_AUTO_CONT` | the date of the transplant itself — §6.5 |
| 2 | a transplant or CAR-T | the day before the procedure — §7.2 |
| 3 | `CART_INIT` | the day before the infusion — §7.3 |
| 4 | `MED_ADD` | the day before the added agent — §7.4 |
| 5 | `DEATH` | the date of death — §7.5 |
| 6 | `DISCONTINUATION` | the confirmed run-out date — §5.3 |
| 7 | `STUDY_END` | the end of observation |

`SCT_AUTO_CONT` is first only in the sense of being asked first. It is the one
branch that reaches *forward* rather than gating itself against what is below,
so it is gated the other way round: it fires only when its transplant falls
strictly **after** the date every other branch would have produced. Where it
fires, the line was going to end too early; where it does not, it changes
nothing. Death is excluded from it explicitly rather than by the ordering.

### 7.2 Within the transplant branch the earliest date wins

The reason names which type it was — `SCT_AUTO`, `SCT_ALLO` or `SCT_CART`. On
different dates there is no priority between the three; an ALLO does not
outrank an earlier AUTO. On an exact same-day tie the recorded reason follows
the order the CASE tests in, and the two sites disagree: line 1 records AUTO,
then ALLO, then CAR-T (`05b_lot1_sct.R`); lines 2–5 record ALLO, then CAR-T,
then AUTO (`10_lot2_5_base.R`). The end date is identical either way — open
question Q4 in the scenario workbook.

`SCT_CART` therefore arises two ways: a line that ends at a CAR-T, and a
CAR-T-started line with no consolidation agent, which spans a single day.
Neither applies to a CAR-T inside line 1's induction window (§6.4).

That single-day span, like the ALLO one in §4.6, is lifted by a melphalan
course the line was carried to (§4.7).

### 7.3 An added agent then a CAR-T within 45 days is `CART_INIT`

Worked example: `cart_bridge_within` / `cart_bridge_beyond`.

An added medication followed by a CAR-T inside `cart_consolidation_days` is
bridging therapy. The line ends the day before the infusion, and the bridging
agent stays in that line rather than starting a regimen of its own.

The added medication has to be an addition, which at line 1 means it starts on
or after day 60: anything starting inside the induction window joins the
regimen and is not an added agent at all (§7.4). The scenarios below place it
there for that reason.

**`CART_INIT` is a taxonomy, not a fall-through.** An added medication followed
by a CAR-T inside the window belongs to `CART_INIT` and is never re-read as a
`MED_ADD` event.

### 7.4 An agent added outside induction is `MED_ADD`

The candidate is any non-steroid episode from the line's start to its run-out
whose agent is **absent from this line's regimen** (`first_add_candidates`,
`04_lot1_base.R`). There is no separate "after the induction window" predicate:
the regimen is exactly the agents whose episode started inside that window, so
an agent starting inside it is in the regimen by construction and can never be
an addition. At line 1 that puts the earliest possible `MED_ADD` on day 60.

**Absorption hides an addition.** A claim landing while an episode of that agent
is still open opens no episode (§2.3), so it is never a candidate and the line
does not end.

### 7.5 Death, and the run-out it can displace

`DEATH` is the one branch not gated on a date comparison (§7.1). Its only gate
is `POST_RUNOUT_TRIGGER_FLG = 0` — no line-opening trigger between the run-out
and the death:

```sql
WHEN DEATH_DT IS NOT NULL AND DEATH_DT <= OBS_END_DT
 AND POST_RUNOUT_TRIGGER_FLG = 0 THEN 'DEATH'
WHEN LOT1_BASE_DISCON_DT IS NOT NULL THEN 'DISCONTINUATION'
```

`DEATH_DT` is never compared with `LOT1_BASE_DISCON_DT`, so where both exist the
death takes the line's end whatever the dates are. Three cases, and they do not
all behave the same way.

### 7.6 Disenrollment is not censoring

A period ending at disenrollment is classified `STUDY_END`. There is no
`DISENROLLMENT` end reason; the `*_CE_SENS` columns carry the alternative
reading.

### 7.7 Line length is inclusive of both ends

`LOT_BASE_LENGTH` is the run-out date minus the start plus 1 for a
discontinuation, and the end date minus the start plus 1 otherwise.

---

## 8. Belantamab removes the patient, not the line

Worked example: `belantamab_any_line`.

`lot/engine/R/line_criteria.R`. A criterion is an expression over `lot_long`
plus the lines it applies to, declared as data rather than edited into the step
SQL. One is shipped and on.

**`no_belantamab`** — no belantamab (`BELA`) anywhere from the patient's first
line to the end of observation. It asks `map_stacked` over that whole span
rather than reading `LOT_BASE_MEDS`, so the answer does not depend on `max_lot`:
"received belantamab in any LOT" cannot mean "in any of the lines the build got
round to constructing".

`on_fail = "truncate"` drops the failing line **and every later one**, because
LOT N is defined against LOT N−1 — removing a middle line would leave LOT1
beside LOT3. Because this criterion is patient-level the test fails on every
line, so truncation leaves the patient with none.

---

## 9. Five lines are built, and nothing above them

Worked example: `line_beyond_max`.

`max_lot`. `check_lot_long()` refuses any line number outside `1..max_lot`.

---

## 10. Maintenance is a flag, not a line

There is no maintenance concept in the build. `contains_mtx_reg` is descriptive
and nothing more; `MAINTENANCE_END` and `SCT_NO_MAINT` are not final end
reasons, and those cases route by their earliest applicable event.

---

## 11. Which file holds which rule

| Rule | File |
|---|---|
| Settings, contract, metadata, the `LOT_LONG` checks | `lot/engine/R/build_lot.R` |
| Episodes, day supply, the run-out flag | `lot/engine/R/steps/03_mma_map.R` |
| Line 1 start, regimen, run-out, added medication | `lot/engine/R/steps/04_lot1_base.R` |
| Transplant events, grouping, merging, tandem | `lot/engine/R/steps/05_sct.R` |
| Line 1's transplant summary | `lot/engine/R/steps/05b_lot1_sct.R` |
| Line 1's end cascade and the confirmation buffer | `lot/engine/R/steps/06_lot1_end.R` |
| Lines 2-5: start, regimen, end, confirmation buffer | `lot/engine/R/steps/10_lot2_5_base.R` |
| The prior-regimen rule and the run-out chain | `lot/engine/R/prior_regimen.R` |
| Line criteria and truncation | `lot/engine/R/line_criteria.R` |
| The CAR-T induction rule | `lot/engine/R/cart_rule.R` |
| The scenarios above, machine-checked | `lot/validation/R/vignettes.R` |
| The patients the CAR-T rule touches | `analysis/questions/jul20_studyteam_qs.R` |

## 12. What stops a run

A cohort whose own build did not finish. A cohort that does not fit the study
window the run was given. A setting that differs from the pinned contract
without an explicit override. A code list that cannot be read, or one failing a
consistency check that is not waivable. A `LOT_LONG` whose lines overlap, run
backwards, skip a line number or end after observation. A line that ends in a
way these rules cannot produce.
