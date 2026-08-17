# The lines-of-therapy rules

Every rule the build applies, the setting that governs it, and the file it
lives in. `SCENARIOS.md` carries the worked example for each, numbered to match:
§6.5 here is 6.5 there.

**The rules this build applies, and only those.** The melphalan
line-advancing proposal is an exploration — it is not in the study's numbers,
it is not built into any run that ships, and it is not here. `lot/FILES.md`
says what that package is and what is still open on it.

*Applied* is not *settled*. §11 has two rules that are applied but still under
review. §12 lists where the build differs from the written protocol. §14 has two
things that need a ruling.

Every rule here is one the build applies on every run. That is all they have in
common. It does not mean the clinical question behind it is closed.

Written from the code, not from the spec — where the two differ, this follows
the code and says so (§12).

This folder carries three documents and no more. This one is the rules,
`SCENARIOS.md` is those rules worked through a patient's claims, and `FILES.md`
is what is in the folder and what each file does.

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
| §11 | Two rules that are applied and still under review | — | |
| §14.1 | **To confirm** — the CAR-T consolidation window: 45 days, where the spec says 30 | `cart_consolidation_days` | |
| §14.2 | **To confirm** — a confirmed discontinuation losing to a later death | — | |

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

`apply_melp_rule` is pinned blank, and the five `melp_*` thresholds are pinned
with it. It is an exploration, not a rule — `lot/FILES.md`, under
`exploration/melphalan/`.

Off is not the same as absent. The rule's code is inside the engine
(`R/melp_rule.R`), and it is sourced on every run. It has hooks in
`06_lot1_end.R` and `10_lot2_5_base.R`, because the rule needs each line's own
induction window, and that only exists while the line is being built.

What makes blank safe is not that the code is gone. It is that every hook
returns an empty string. So the SQL the engine builds is the same SQL it built
before the file existed. `exploration/melphalan/tests/test_aug1_melp.R` proves
this: it puts each hook's off value back into the step text and requires nothing
melphalan to be left.

The study window (`STUDY_START`, `STUDY_END`) is **not** pinned. It is the
cohort's, passed per run and recorded in `LOT_RUN_METADATA`: the algorithm is
the same whatever window it reads, and different cohorts have different ones.

---

## 2. Episodes — what a line is built from

`MAP_STACKED`, one row per patient per medication available period, built in
`lot/engine/R/steps/03_mma_map.R` from rx and medical claims against
`cl_mma_codelist.csv`. Every rule below this one reads episodes, not claims.

### 2.1 Steroids are excluded everywhere

`MAP_MED_CLASS = 'STEROID'` is filtered out before a line starts, before a
regimen is assembled, before discontinuation, and before an added medication can
end a line. Corticosteroids are not treated as oncology agents.
`lot/engine/R/steps/10_lot2_5_base.R` — `MAP_MED_CLASS <> 'STEROID'`.

### 2.2 A medical claim is assumed to cover 28 days

A medical claim carries no day supply, so `medical_day_supply` is assumed for
it. `MAP_END_DT` is the later of the rx run-out and the medical run-out.

### 2.3 A claim arriving while cover is live extends the episode

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
| `d_AUTO` | earliest autologous transplant that is (i) outside the previous line's applicable window measured from that line's **start** — 0 days if ALLO-started, 44 if CAR-T-started, 29 otherwise — and (ii) not within `sct_tandem_days` of the immediately preceding AUTO (§6.3) |

Unlike line 1, a first-ever AUTO can open a line here.

### 4.2 Later induction is 30 days, and 45 on a CAR-T-started line

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

**This is a divergence from the protocol wording**, and §12 carries it. The
protocol says the later regimen is "all MM therapies identified during the first
30 days of the LOT", which reads wider than fills. `run_scenario_counts.R`'s
`4.2-prior-agent-covered-but-not-in-the-regimen` sizes it.

### 4.3 A drug is held by its line while it runs, and released once stopped

The protocol starts a later line at "the first administration for a new MM agent
that was not part of the previous LOT regimen". A drug the patient has not
stopped is not new, so the line that owns it extends over its later episodes
(§5.2). A drug that has **discontinued** is: an episode arriving after a gap of
`map_discon_gap_days` is a restart, and opens a line like any other agent.

One rule in two halves, and each alone is worse than neither. `discon_per_med`
stops chaining at the last episode before the gap, so a line no longer spans its
own agent's absence; and the prior-regimen exclusion releases the same drug, so
the returning treatment has a line to go to. `lot/engine/R/prior_regimen.R`
carries both, and the run-out guards that mirror the start candidates read the
same definition. §11.1 is the reasoning and what the rule costs.

### 4.4 A permissible biosimilar substitute never starts a line

The substitute is unioned into the previous line's regimen for this test, so it
is excluded from `d_MED` the same way the reference product is.
`permissible_subs.csv` names the pairs.

### 4.5 Same-day starts break `SCT_ALLO > CART > SCT_AUTO > MED`

### 4.6 An allogeneic line spans one day and carries no regimen

`allo_lot_span` is `single_day`, and induction rows are suppressed for an
ALLO-started line.

---

## 5. Running out of treatment

Two different 90-day rules. They are easy to conflate because both are 90 days,
and they do different things.

### 5.1 A 90-day gap is running out

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

A second AUTO within `sct_tandem_days` of the one before it is a planned tandem
and does not end the line and does not start one. Beyond it, the transplant is
excess and does both.

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

The window bounds **both** transplants of a tandem pair, not only the first. A
partner inside `sct_tandem_days` of an in-window transplant but outside the
window itself does not hold the line open. Holding it open would let a line run
to day 209 at LOT2 and swallow an added agent months after its regimen stopped.

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
the run-out. And so on (`06_lot1_end.R`). So a later event never displaces an earlier one.

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

The reason names which type it was — `SCT_AUTO`, `SCT_ALLO` or `SCT_CART`. There
is no priority between the three; an ALLO does not outrank an earlier AUTO.

`SCT_CART` therefore arises two ways: a line that ends at a CAR-T, and a
CAR-T-started line with no consolidation agent, which spans a single day.
Neither applies to a CAR-T inside line 1's induction window (§6.4).

### 7.3 An added agent then a CAR-T within 45 days is `CART_INIT`

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
This matches the protocol's rule 2, "initiation of a new MM agent that was not
present in the induction regimen".

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

`max_lot`. `check_lot_long()` refuses any line number outside `1..max_lot`.

---

## 10. Maintenance is a flag, not a line

There is no maintenance concept in the build. `contains_mtx_reg` is descriptive
and nothing more; `MAINTENANCE_END` and `SCT_NO_MAINT` are not final end
reasons, and those cases route by their earliest applicable event.

---

## 11. Applied, and still under review

Both of these are what the build does today, on every run. What is open is not
the behaviour but whether it is the right reading, and each needs a clinician
rather than a closer reading of the protocol.

| kind | what it means |
|---|---|
| INTERPRETATION | the protocol states a rule, and turning it into claims logic needed a choice the protocol does not make |
| DOCUMENT CONFLICT | two written authorities disagree and the code follows one |

### 11.1 A drug returning after its line has ended — INTERPRETATION

The rule is §4.3. What is recorded here is the reading behind it.

**The protocol** says a subsequent LOT starts at "the first administration for a
new MM agent **that was not part of the previous LOT regimen**". Read strictly,
that excludes a previous-regimen drug forever. The build reads it as excluding a drug the patient has not stopped. An episode
after a gap of `map_discon_gap_days` is a restart, not a continuation.
Otherwise a line spans its own agent's absence, and a nine-month line with no
cover is not a line of therapy in any clinical sense.

**The spec** agrees in the one place it touches this,
`maintenance_validated.csv` `MAINT_REINTRODUCTION_RULE`: "The introduction of
any MM therapies **including therapies that were part of the original regimen
does not advance the LOT** but ends the maintenance period." That rule is scoped
to maintenance, which the engine does not implement, so it is indicative rather
than binding.

**What is still open.** Whether `map_discon_gap_days` — 90 days, the same
threshold used for episode-level discontinuation — is the right length for this
judgement. It is a clinical question about when a re-start is a new line rather
than a reading of the protocol.

**The release is narrow, and deliberately so.** It applies to a drug that was
the regimen. It never applies to one present only as a permissible biosimilar
substitute: §4.4 says a substitution does not advance the line, and a long gap in
a substitute's own episodes is not evidence about the drug it stands in for.
Reading it as one would be a new clinical rule, not an implementation of an
existing one.

That holds in all five places a release is asked for — the two add-medication
blocks, the two run-out guards and the next line's start — so a substitute
cannot end a line, confirm a run-out or open the next one by any route. Each
exclusion set records which of the two each drug is, and a drug that is both an
actual regimen agent and somebody's substitute counts as the former.

### 11.2 A drug returning mid-line after a break in supply — INTERPRETATION

**The code** ends the line and opens the next one. The added-medication query
takes agents outside this line's regimen whose `MAP_START_DT` falls after the
induction window (§7.4). A supply episode reopens whenever cover lapses by a
single day, so a refill collected late produces a new `MAP_START_DT` and reads
as an initiation. The patient never stopped the drug.

**The spec carries both readings in one row.** `lot1baseend_validated.csv` row
34, `LOT1_BASE_1ST_ADD_MED_DT / LOT1_BASE_1ST_ADD_MED`:

| column | text |
|---|---|
| Definition (Validated from Protocol) | "the LOT end date is the day before the **first administration/dispense date** of the new agent" |
| Optum CDM Implementation | "where the medication is NOT in base_meds (induction + permissible subs). **`MAP_START_DT`** from MAP algorithm" |

For an agent the patient has never had, those two are the same date. For one
already in hand they are not. The same row already carves out one exemption —
"Per Rule 1: permissible substitutions ... 'do not advance the LOT'" — so the
concept of an appearance that must not advance the line exists in the spec. It
was never extended to a drug returning after a break that is not a
discontinuation.

**The measure both rules already have.** `MAP_DISCON_GAP_DAYS` has been in
`lot/engine/config.csv` since that file's first commit, and `03_mma_map.R` sets
`MAP_DISCON_FLG` from it on every episode (§5.1). So nothing is absent — the
flag sits on the same `map_stacked` rows the line rules already select from.
What §11.1 and §11.2 come down to is which queries read it:

| query | what it decides | reads the flag |
|---|---|---|
| `discon_per_med` | when the line's cover runs out | yes |
| `first_add_candidates` | whether a returning agent ends the line | **no** |
| `med_cand` | whether a returning agent starts the next line | **no** |

Three predicates that do not consult a flag already on the row. That is the size
of it — not a missing parameter and not a missing concept, and 30 or 60 days is
a config value and a rebuild rather than a code change. The added-medication and
line-start queries have never read the flag; this is original behaviour, not
something a refactor lost.

**What has been measured.** `run_stockpiling_rule.R` and
`run_rechallenge_evidence.R` size this against a finished run. Against the
production run:

- **898 line boundaries in 624 patients** sit on a prior episode with
  `MAP_DISCON_FLG = 0` — the drug was still running by the build's own
  reckoning. Median 8 days uncovered.
- **495 boundaries in 448 patients** sit on a prior episode flagged
  discontinued. Median 257 days uncovered.
- **22** are a first exposure, with no prior episode.

These are boundary counts, not a resulting line structure: removing a boundary
merges two lines, renumbers every later one, moves the induction windows and can
change which agents fall in which regimen. An exact structure needs an alternate
build. Ten events returned no prior claim before the boundary date, which the
event definition should make impossible — unresolved.

**Status.** Open. The mechanism to settle it is already built and configurable;
what is missing is a ruling on whether a supply episode opening counts as an
initiation, which is a clinical question and not a protocol reading.

### 11.3 Not in dispute

- Leftover days-supply does not carry an agent into the next line's regimen
  (§3.3). The study team settled this and the code matches it.
- Permissible biosimilar substitutions do not advance the line (§4.4).
- The induction windows: 60 days at line 1, 30 at lines 2-5, 45 for a
  CAR-T-started line.

---

## 12. Where this differs from the written protocol

- **A planned tandem needs a clear gap, not only an interval.** The protocol
  defines a planned tandem by the 60-180 day gap between two autologous
  transplants and by no allogeneic transplant between them. Requiring that
  nothing else happens in between either — no non-steroid medication starting, no
  CAR-T — is a study-team decision, not something the protocol establishes, and
  it governs where the two differ. §6.3.
- **A regimen is what was dispensed in the window, not what was available.** The
  protocol says a later line's regimen is "all MM therapies identified during the
  first 30 days of the LOT". The build reads that as an episode *starting* in the window. So an agent whose
cover runs through the window without lapsing is not in the regimen. Nor is one
dispensed inside the window while its own cover was live, because that dispense
extends the existing episode. Two clinically identical patients can therefore get
  different regimens depending on whether one of them missed a fill. Settled this
  way by the study team and pinned by the engine suite; §4.2 has the mechanics,
  and `run_scenario_counts.R`'s
  `4.2-prior-agent-covered-but-not-in-the-regimen` is what would size it.
- **The discontinuation confirmation buffer is applied**,
  resolving a contradiction inside the spec rather than departing from it: the `LOT1_BASE` tab requires 90 days of observation after a run-out
  and the later end-date tabs do not. The build follows the tab that has it, on
  every line. §5.3.
- **The buffer is confirmed two ways, and the spec names only one.** The
  `LOT1_BASE` tab requires observation after a run-out; it says nothing about a
  patient who restarts inside that window. The build treats the restart as
  confirmation in its own right, so the run-out stands and the next line opens.
  Gating on elapsed observation alone would have merged those two lines into
  one. §7.5 already takes that position against `DEATH`. §5.3.
- **Regimen membership is an episode start, and the protocol reads wider.**
  §3.3.
- **A CAR-T-started line consolidates for 45 days, and the spec says 30.** The
  code's own header records the supersede — `cart_consolidation_days = 45
  (supersedes the earlier 30d value)`, `10_lot2_5_base.R` — so this is a
  deliberate change rather than drift, but it is not the written protocol's
  number. It sets both the CAR-T-started line's regimen window and the
  `CART_INIT` bridging window (§7.3), so it moves regimen membership and line
  boundaries together. Staying at 45. §14.1.
- **A confirmed discontinuation loses to a later death.** The protocol ends a
  line at the earliest qualifying event; the death branch is not date-gated, so
  a run-out confirmed by 90+ days of observation is still overridden by a death
  after it. Only that case diverges — a death inside the confirmation window is
  the branch working as intended, since the buffer cannot complete for a patient
  who dies in it. §7.5, §14.2.
- **Disenrollment is not censoring** in the primary analysis. The protocol ends
  follow-up at the earliest of death, disenrollment or study end; the primary
  cascade carries disenrollment in the `*_CE_SENS` columns instead. §7.6.
- **Maintenance is not implemented.** §10.
- **`max_lot` is 5.** §9.
- **A drug returning cannot start a line on itself**, and a drug returning after
  a lapse in cover can. §11.1, §11.2.

---

## 13. Which file holds which rule

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

## 14. Still open

Two things that need a ruling rather than a closer reading of the code. Both
are also in `KNOWN_ISSUES.md`, one level up, written as questions to put to the
study team — this section is the analysis, that one is the ask.

### 14.1 The CAR-T consolidation window: 45 days, where the spec says 30

`cart_consolidation_days` is 45. `10_lot2_5_base.R`'s own header records 45 as superseding an earlier 30. So the
change was deliberate, not drift. But the protocol and the program spec both
carry 30, and no document here carries 45. It came from prior internal work
that is not in this repository. That is why it cannot be checked against the
protocol text.

It decides two things at once, so a ruling moves both:

| | |
|---|---|
| the CAR-T-started line's regimen window | which agents are in that line's regimen, §4.2 |
| the `CART_INIT` bridging window | whether an added agent followed by a CAR-T is bridging or an ordinary addition, §7.3 |

At 30 the second is the sharper effect: an addition followed by a CAR-T 31 to
45 days later stops being `CART_INIT` and becomes a `MED_ADD`, which opens a
line where the current build opens none.

**Staying at 45**, on the study team's instruction, until they rule. Changing
it is a one-line config edit and a rebuild, and it is pinned in `CONTRACT`, so
a run at 30 records the deviation and every downstream reader refuses it as the
study's numbers — there is no way to produce a 30-day run by accident.

### 14.2 A confirmed discontinuation losing to a later death

§7.5's third scenario. The rule is not wrong where it was designed to help — a
patient who dies inside the confirmation buffer can never complete it, because
observation ends at the death, so the death is the only end available. What
needs a ruling is the case beyond that: the buffer completed, the
discontinuation is confirmed and written, and a later death still takes the
line's end.

Two decisions made months apart now meet here. The death branch came first, to
keep death as the recorded end of a line; the confirmation buffer came in
August (§5.3). Neither was written against the other, and the branch's gate is
`POST_RUNOUT_TRIGGER_FLG` alone, so it never asks which date is earlier.

The alternative is one predicate — fire the death branch only when the
discontinuation is absent or later than the death:

    AND (LOT1_BASE_DISCON_DT IS NULL OR DEATH_DT <= LOT1_BASE_DISCON_DT)

which would leave the line ending `DISCONTINUATION` at the run-out and the
death recorded as the patient outcome it already is, on `DEATH_DT`. That is the
protocol's earliest-qualifying-event reading, and it is what §7.1 says the rest
of the cascade does.

What it would move: end reasons and end dates for patients who ran out, were
observed for the full buffer, never returned, and then died — so
`LOT_BASE_LENGTH`, `TTD`, and the attrition split between died and
discontinued. Not line counts.

## 15. What stops a run

A cohort whose own build did not finish. A cohort that does not fit the study
window the run was given. A setting that differs from the pinned contract
without an explicit override. A code list that cannot be read, or one failing a
consistency check that is not waivable. A `LOT_LONG` whose lines overlap, run
backwards, skip a line number or end after observation. A line that ends in a
way these rules cannot produce.
