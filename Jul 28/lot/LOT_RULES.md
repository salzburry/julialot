# The lines-of-therapy rules

Every rule the build applies: what it does, the setting that governs it, the
file it lives in, and a worked example.

Behaviour only. Open clinical questions live on the Open questions sheet of the
scenario workbook (`exploration/lot/run_lot_scenarios.R`). What each file does
is `FILES.md`. What the study team asked for is `STUDY_TEAM_ASKS.md`.

Worked examples are cases in `lot/validation/R/`, not prose, and their
structure is machine-checked: every offset is derived from the setting that
decides it, each boundary pair straddles that setting by one day, and every
rule they cite still exists where they say it does. A renamed vignette, or one
no rule cites, fails `lot/validation/tests/test_vignettes.R`.

What is NOT checked is the OUTCOME. A vignette says what the rules give, and
nothing runs a patient through the engine to confirm it — which is why each one
carries a confidence, and why the ones marked `to_confirm` are our reading
rather than a result.

> **Changed 2026-08-30.** Three rules changed what starts and ends a line:
> §4.3 (a drug of the previous regimen never starts one), §4.7 (a short
> melphalan course) and §4.8 (a returning earlier-line drug). Each refuses a
> boundary and carries the line over the treatment instead, so a line's end can
> now sit later than its own regimen's cover (§5.2) and `MED_ADD` is narrower
> (§7.4). §4.8 puts its drug in `LOT_BASE_MEDS`; §4.3 and §4.7 do not. §4.3 is the widest —
> it reaches every patient with a treatment holiday, not only the ones the
> other two touch. **LOT numbers produced before that date are superseded.**

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
| §3.4 | Line 1's first autologous transplant never ends line 1 | — | |
| §4.1 | A later line opens on the earliest of four candidates | — | |
| §4.2 | Later induction is 30 days, and 45 on a CAR-T-started line | `lot_n_induction_window_days`, `cart_consolidation_days` | |
| §4.3 | A drug of the previous regimen never starts a line | `apply_own_return_fold` | |
| §4.4 | A permissible biosimilar substitute never starts a line | — | |
| §4.5 | Same-day starts break `SCT_ALLO > CART > SCT_AUTO > MED` | — | |
| §4.6 | An allogeneic line spans one day and carries no regimen | `allo_lot_span` | |
| §4.7 | A short melphalan course outside induction does not start a line | `apply_melp_rule`, `melp_simple_course_days` | |
| §4.8 | A returning drug joins the line it returns in, after one agent | `apply_map_foldin` | |
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
| `apply_map_foldin` | `TRUE` | a returning prior-line drug joins the line it returns in — §4.8 |
| `apply_own_return_fold` | `TRUE` | a drug of the line's own regimen coming back never starts a line — §4.3 |
| `melp_med_abbr` | `MELP` | how melphalan is spelled on the code list |
| `melp_exposure_days` | 30 | melphalan doses closer than this are one course |
| `melp_simple_course_days` | 28 | a course covering this or fewer days is short — §4.7 |

To build without the melphalan rule, use `APPLY_MELP_RULE=off`. Not a blank:
the settings loader fills any variable that is unset **or empty** from
`config.csv`, so a blank arrives as `simplified`.

`STUDY_START` and `STUDY_END` are **not** pinned. They belong to the cohort,
are passed per run, and are recorded in `LOT_RUN_METADATA`.

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
A permissible biosimilar substitute is **derived** into the set used for
discontinuation and added-medication logic, and a drug that reaches that set
only by derivation is neither counted in `LOT_MED_CNT` nor listed in
`LOT_BASE_MEDS`. A substitute the patient actually received in the window is a
different case: it has an episode of its own, so it is an observed agent and is
listed and counted like any other. A patient given both halves of a declared
pair inside one window therefore reports both and counts two, where §4.4 calls
them one agent everywhere else. Whether the reported regimen should collapse
the pair is an open question for the study team.

### 3.3 A regimen is bounded by the date the line ended

A line picks its regimen over its induction window, but never past its own end.
Where a transplant ends the line early, `REGIMEN_CUTOFF_DT` closes the window
the day before it, so an agent first dispensed after the line was over is not
in its regimen.

Which transplants cut the window depends on the line and the CAR-T rule. An
allogeneic transplant always cuts, at every line. A CAR-T cuts
at lines 2 to 5 always, and at line 1 only when `apply_cart_induction_rule` is
off — with it on, an in-window CAR-T is part of line 1 and ends nothing (§6.4).
An autologous transplant never cuts, because it only extends a line (§6.5). The cutoff bounds the per-drug episode scan too: without
that, a refill of an agent legitimately in the regimen would push the run-out
past the transplant. `04_lot1_base.R`, `10_lot2_5_base.R`, `prior_regimen.R`.

QC check `C1` covers this. Its window helper builds the same transplant cutoff
and bounds the accepted range by it, so a regimen agent first dispensed after
an early transplant is reported rather than passed.

### 3.4 Line 1's first autologous transplant never ends line 1

Wherever it falls, the first-ever autologous transplant belongs to line 1.

**Inside line 1's 60-day window** it holds the line open to its own date
(§6.5). A line whose own cover ran out earlier is carried to the transplant
and ends there, `SCT_AUTO_CONT`.

**Outside that window** it neither holds the line nor ends it. A line 1 that is
still running continues exactly as if the transplant were not there — same end
date, same reason. Where line 1 has already ended on its own, the transplant
opens line 2 on its date like any other line-starting event. What it never does
is cut a line that is still going.

What ends line 1 is the **second** autologous transplant, or the **third**
where the first two are a planned tandem (§6.3) — the tandem partner belongs to
line 1 as well. Line 1 ends the day before it, `SCT_AUTO`, and the next line
opens on the transplant date.

Lines 2 to 5 do not keep this convention: there the first transplant outside the
previous line's window ends the line (§4.1).

> Until 2026-09-02 this section said a first transplant outside the window ended
> line 1 and opened line 2. The build has never done that — a lone first
> transplant leaves a live line 1 byte-for-byte unchanged — and `S03` in the
> scenario catalogue pins the build's answer, so the sentence contradicted both
> the code and the test that guards it. Corrected to the code, on the study
> team's decision that the code is right.

---

## 4. Lines 2 to 5

`lot/engine/R/steps/10_lot2_5_base.R`.

### 4.1 A later line opens on the earliest of four candidates

All four must fall strictly after the previous line's end and on or before the
end of observation.

| Candidate | Rule |
|---|---|
| `d_MED` | earliest non-steroid MM agent, excluding the previous line's own regimen (§4.3) and its permissible substitutes (§4.4). Two agents are excluded by rules of their own: a short melphalan course (§4.7) and a returning earlier-line drug the count folds (§4.8) |
| `d_ALLO` | earliest allogeneic transplant |
| `d_CART` | earliest CAR-T. At LOT2, one inside line 1's induction window is excluded — §6.4 |
| `d_AUTO` | earliest autologous transplant that is (i) outside the previous line's applicable window measured from that line's **start** — 0 days if ALLO-started, 44 if CAR-T-started, **59 where the previous line is line 1**, 29 otherwise. It is the window that line owns, so a LOT2 candidate is read against line 1's 60 days and not against the 30 lines 2-5 use for themselves — §6.5 has the table — and (ii) not within `sct_tandem_days` of the immediately preceding AUTO, where **that** AUTO is itself inside the same window (§6.3) |

Unlike line 1, a first-ever AUTO can open a line here.

One candidate can also be *moved* rather than removed: a short melphalan course
confirmed by another agent starting inside its cover opens the line on the
**melphalan** date rather than that agent's later one (§4.7).

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

### 4.3 A drug of the previous regimen never starts a line

Worked example: `maintenance_to_relapse`.

A line opens on an agent that was **not** in the previous regimen. A drug that
was in it is not one, whatever the gap since, so its later episodes never start
a line — the line that owns it runs on over them (§5.2).

**The previous regimen, not everything the patient has ever had.** A drug last
given two or more lines back is outside this rule and can open a line like any
other agent. That is the same scope §4.8's fold set reads, and §4.7's test for
what counts as a new agent — one meaning of "new" in all three.

**One rule in two halves, and both are needed.** Refuse the return a line and
the returning treatment would belong to no line at all, so the line's run-out
chains over the break instead of stopping at it. `discon_per_med` does not
break a chain on the drug's own gap; another drug interrupting still breaks it.
`lot/engine/R/prior_regimen.R` carries both halves off one setting
(`apply_own_return_fold`), and the run-out guards that mirror the start
candidates read the same definition.

So a same-drug re-challenge after any gap is **one line**, spanning the break.
`map_discon_gap_days` still decides when a drug's cover has run out (§5.1) and
where an episode boundary falls (§2.3); it no longer decides whether the return
opens a line.

> **Changed 2026-08-30.** Before this the gap **released** the drug: an episode
> after `map_discon_gap_days` was a restart and opened a line like any other
> agent, and the line stopped at the gap. A patient on one drug with a
> three-month break was two lines; they are now one. This changes line counts,
> line durations and line dates for every patient with a treatment holiday, not
> only the ones §4.8 touches.

§4.8 is the same idea for a drug of an **earlier** line: returning after
exactly one agent advanced the line, it joins the line it returns in.

### 4.8 A returning drug joins the line it returns in, after one agent

> Out of numerical order on purpose. §4.3 and §4.8 are one idea applied to two
> scopes — the line's own drug coming back, and an earlier line's — and reading
> them apart is harder than reading them together. §4.4 follows.

Worked example: `returning_drug_one_advance` / `returning_drug_two_advances`.

A drug from the **immediately previous** line that comes back is read by what
happened between its two doses. A drug from further back is out of scope, and
the engine's ordinary rules keep it. Count the **different agents** that opened
a line in that interval:

| different agents in between | what the return does |
|---|---|
| one | joins the line it returns in — no new line |
| two or more | opens a line, as any added agent would. Not reachable with the fold set scoped to the previous line — see below |
| none | nothing advanced, so this rule says nothing — §4.3 keeps the return in the line it left |

The interval is measured **dose to dose**, not from where the drug stopped. A
drug's cover often runs past the line it belonged to, so measuring from the stop
would put the advance that ended that line before the interval and count none.

An advance is an **agent**, not a line, and a **line is one advance** whatever
opened it: two drugs starting a line together advanced it once between them —
`returning_drug_two_agents_one_line`. A line is read through a single opener,
so one agent opening two lines counts once too. A permissible substitute is the
same agent as the drug it replaces (§4.4), so a biosimilar swap is not a second
agent either, in either direction.

**Transplants and CAR-T are not in that count**, which counts drugs. They keep
the rules they have everywhere else (§6), where they are standalone
line-defining events, and one that **opened a line** between the two doses
**overrides the fold** whatever the agent count says: a drug returning across a
transplant is not returning to the line it left.

A transplant the line owns overrides nothing. An AUTO inside the line's own
window (§6.5), or a planned tandem partner (§6.3), opens no line, so it is not
a line start and never reaches the test.

**The two-or-more row cannot fire while the fold set is the previous line's
regimen.** A drug is in that regimen only through an episode starting at or
after that line's start (§3.3), and the return has to be inside the line being
built, so exactly one line can have opened in between. The row is kept because
it states the rule the study team asked for. The scope is settled at the
previous line — decided 30 Aug, recorded in section 2 of `STUDY_TEAM_ASKS.md`
with why the two readings are not equivalent — so the row is a statement of the
rule rather than a branch waiting to fire. Widening the scope is what would make
it reachable, and that is a change to the settled rule, not a defect to fix.
The fold-in harness pins the outcome the row describes, by the route the narrow
scope actually takes, and says so where it does (`F13`).

A return only joins the line that actually contains it. While lines are built in
order the count is relative to the line being built, so a return with another
line-defining agent — a drug **or a procedure** — before it belongs to a later
line, and this one does not claim it. That ownership test is separate from the
count and procedures do count in it, on the same test §4.7 uses: past the line's
own induction window and not a planned tandem partner.

**One course, one answer.** Episodes of the same agent with no discontinuation
between them (`map_discon_gap_days`) are one course, and they fold together or
not at all. Judged one episode at a time, a returning course was split between
two owners: its first episode folded, and its own follow-up weeks later had no
advance behind it, so it opened a line.

**The returning drug joins the line's regimen**, not only its span. It enters
`LOT_BASE_MEDS`, `LOT_MED_CNT` and the line's med and class flags, because a
drug the rule says is part of the line should read as part of it. The line's
run-out is carried to the last day the drug's supply reaches, capped at
observation, so the treatment the rule refuses a line to still sits inside one.

The regimen names the drug **actually given** — a permissible substitute enters
under its own abbreviation, not the one it stands in for.

A folded episode past a transplant that broke the line does not join: it belongs
to the line that transplant opened. A held melphalan course still joins neither
the span's regimen nor its count (§4.7) — that rule was not asked the same
question.

A melphalan course the melphalan rule suppressed is not a line-defining agent
here either — that rule has already decided it opens nothing.

`lot/engine/R/foldin_rule.R`.

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

That agent has to be a **new** one. A drug from the **immediately previous**
line coming back is the returning drug, not a new one — §4.8 bundles it into
the line it returns in — so it confirms nothing. Without this the same drug was
bundled by §4.8 and read as a change by this rule, and the line advanced on the
melphalan date anyway. This is the one place the two rules meet, and it settles
both directions: a course this rule suppressed is not a line-defining agent for
§4.8's count either, and it joins no regimen (§4.7 holds it, and a held course
is in neither `LOT_BASE_MEDS` nor `LOT_MED_CNT`).

**And the melphalan itself may be the returning drug.** A course this rule
CONFIRMS starts the next line, on its own first day — so §4.8 stands back from
it too, exactly as it does from a suppressed one, and for the opposite reason:
a suppressed course opens nothing, a confirmed one opens a line, and neither is
a drug folding back into the line before it. Worked example:
`melp_confirmed_beats_the_fold`. Left to both rules, the previous line named a
drug whose only episode began after that line had ended, and its end date and
end reason moved with it.

**One course, one answer — for BOTH verdicts.** A suppressed course comes off
the candidate list at every one of its doses, and so does a confirmed one:
only its FIRST day is the boundary, and the doses after that belong to the
line that day opened. The line they fall in is carried to reach them, exactly
as it is for a suppressed course. Worked example:
`melp_confirmed_course_is_one_course`. Judged the other way, a confirmed
course given as more than one dose had its later doses left as ordinary
candidates, and where a transplant ended the line the course had opened, one
of them opened another.

**A confirmed course is a boundary for OTHER drugs too.** It opens the next
line, so a drug returning after it is returning into that line, not into the
one before — §4.8 counts it as an advance like any other agent. A *suppressed*
course is the opposite: it opens nothing, so it is no advance at all. The two
verdicts answer "did something arrive here?" differently, and reading one for
the other let a returning drug fold into a line that had already ended.

**A transplant inside a course does not split it.** One course gets one
answer, and the answer is settled by where the course STARTS — the ask says a
course outside **any** induction window does not advance the line, so a
transplant landing between two doses of one course changes nothing about
whether it advances. A course that began before a line is outside that line's
induction window, not exempt from its judgement. The line the transplant opened
is carried to the end of that course's cover and owns the doses that fall in
it, exactly as it would for a course that began after it. Not a choice between
owners: the transplant ends the earlier line where it falls (§6), so that line
cannot reach the later dose at all. Worked example:
`melp_course_split_by_a_transplant`. Judged only against a line it starts
inside, the course was dropped by the transplant's line and its later dose
opened a line of its own.

**A steroid never confirms a course.** Corticosteroids are not oncology agents
(§2.1), so melphalan given with one is still melphalan on its own: the course
stays suppressed and the line is carried to its cover. That is what the study
team's "melphalan mono" question settles, and it settles nothing wider — the
agent that confirms has to be a non-steroid drug.

**A returning drug does not confirm a course, even where it opens a line.**
Where a transplant or CAR-T opened the line, §4.8 refuses the fold, so the
returning drug is line-defining and starts the next line **on its own date**.
It still does not confirm the melphalan course, so the line is not backdated to
the melphalan date. The same history with a drug the patient never had gives
the earlier start and puts the course in the regimen:

| arriving while a short course covers | the next line starts | its regimen |
|---|---|---|
| a steroid | it does not start — the course is held | — |
| a drug of the previous regimen | **its own date** | that drug |
| a drug never given before | **the melphalan date** | the course and that drug |
| the returning drug first, then a new one | **the returning drug's date** | both drugs; the course is held |

The middle row is a deliberate choice, not a gap. A returning drug is the
returning drug (§4.8), and a course it arrives beside is still a course nobody
started a new regimen on — so it opens a line where the engine's own rules give
it one, and takes nothing back to the melphalan date with it.

**A drug that opened a line is a boundary, and an agent after one belongs to
the line it opened.** The last row is that rule, not a fourth case: the
returning drug starts its line on its own date (row two), so the new agent five
days later arrives inside that line and is no candidate against the one before
it. It cannot make that line's course advance, and the course is held where it
falls. This is the same test a transplant already gets — a course on day 100
with an allograft on 102 and a new drug on 105 is not confirmed by that drug —
applied to the only medication that can be a boundary here without confirming
the course itself. Worked example: `ZB1`/`ZB2` in the melphalan harness.

The two drugs starting on the **same** day are not this case. Neither is after
the other; they open one line together, and the new one confirms as it would
alone.

**A course belongs to the line the returning drug opened, not the one before
it.** Ownership asks the same question from the other side and used to answer
it differently: a return was read as folded into the line before it wherever
the previous regimen named that drug, so a CAR-T line went on to claim a course
falling after the return, and was carried from a single day to the day before
it. Where a procedure opened the line, §4.8 refuses the fold — so the return is
line-defining there and the course after it is not the procedure line's.
Worked example: `ZB3`/`ZB3x`.

**"Not new" is the previous line only, the same scope §4.8's fold set reads.**
A drug last given further back than that is a new agent here and confirms a
course like any other. It has to be: §4.3 excludes only the previous regimen,
so such a drug can already open a line — and reading every earlier line here
made it both at once, too old to confirm and new enough to start a line. It
then opened the next line on its **own** date while a drug the patient had
never had opened it on the melphalan date, for the same shape of history.

> **Changed 2026-08-30.** Narrowed from every earlier line to the previous one,
> so the two rules share one meaning of "new". It moves the next line's start
> from the returning drug's date to the melphalan date, by up to
> `melp_simple_course_days`, for patients where a drug from two or more lines
> back returns inside a short course.

A course inside the induction window, or one covering more days than the cap,
is left to the engine untouched.

**One line owns a course** — the latest whose start comes before it. Another
line-defining agent arriving first disqualifies the course from an earlier
line: that agent ends the line, and what follows belongs to the line it
started. Distance alone does not disqualify it, so a course long after the
drugs ran out still belongs to the line when nothing happened in between.

**And a line judges only the courses it can see** — one starting inside it, and
one that started earlier and still covers into it, which is the course a
transplant splits. A course whose cover ran out before a line began has no dose
in that line and belongs to an earlier one, so the later line does not judge it
at all. Without that bound each line re-judged every earlier course against its
own window, and two things followed. A conditioning course line 1 held inside
its 60 days came back **suppressed** at line 2 — so §4.8 lost it as a returning
drug's previous dose, and a melphalan re-challenge that should have folded
opened a line of its own (`F36`/`F36c` in the fold-in harness). And the hold
followed the same course forward, handing a later transplant-opened line with no
regimen a run-out before its own start, which §7.1's `SCT_AUTO_CONT` branch read
as a line ending too early and clamped to a single day — the state QC check `B7`
calls a failure (`SU1`/`SU2` in the melphalan harness).

A course inside the induction window of the line that owns it is inside an
induction window, and §4.7 asks whether a course is outside **any** of them. So
a course an **earlier** line took into its own window is never suppressed by a
later one, whether or not its cover reaches that line — the cover test above
only settles which line may judge a course at all, and a conditioning course
covering *into* the next line was still being re-judged and suppressed there
(`F37`/`F37c`). A course that **opened** a line is not in that set: it sits on
its own line's first day, and protecting it would stop the line a transplant
opens next from suppressing it, leaving a later dose a line of its own (`SQ`).

A transplant or CAR-T is that agent only when it **breaks** the line, and the
three kinds break it differently — the same rules §3.4, §6.3, §6.4 and §6.5
state:

| | breaks the line |
|---|---|
| AUTO | past the line's own induction window, and not an uninterrupted tandem partner of an AUTO the line held |
| ALLO | strictly after the line's start. No window |
| CAR-T | the same, except inside line 1's own window, where §6.4 makes it part of line 1 |

An AUTO inside the window, or a tandem partner however far out it sits, belongs
to the line and leaves this rule alone.

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

- **the drug's own discontinuation — not under the rule the study pins.**
`apply_own_return_fold` is `TRUE`, so a drug's own gap no longer breaks its
chain: the episode after it belongs to the line it left, and the line runs on
over the absence (§4.3). Both halves of that rule move together, and this is
the half that stopped the chain.

  With `apply_own_return_fold` `FALSE` — the engine's older rule, kept for
  comparison builds — an episode whose gap to the next reaches
  `map_discon_gap_days` carries `MAP_DISCON_FLG`, the chain stops there, and
  the returning episode is a restart §4.3 releases. Never for a permissible
  substitute even then: a substitution does not advance the line (§4.4), and
  breaking here while §4.3 refuses the same drug would end a line on a restart
  no line could own.
- **a different agent that would end the line.** Deliberately narrow: a drug in
  **this** line's own regimen does not break it, and neither does a permissible
  substitute of one — so a second regimen agent refilling mid-line cannot
  truncate the first one's cover; steroids never break it; and transplant and
  CAR-T are not read here at all. One that ends a line outranks `DISCONTINUATION`, so a run-out chained past it
never surfaces. One that does not end a line must not break the chain anyway —
line 1's induction AUTO, a tandem inside `sct_tandem_days`, a CAR-T inside line
1's window, and a returning earlier-line drug the count folds (§4.8), which is
part of this line and so breaks nothing in it.

**A run-out can also be carried past where the drugs stop.** A suppressed
melphalan course (§4.7) or a folded returning drug (§4.8) is held inside the
line, and the line's run-out moves to the last day that treatment covers. So a
line's end can sit later than any of its own regimen's cover, and the rest of
the end cascade — confirmation, death, a real addition in between — still
applies on top of it.

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

**Being a tandem does not depend on a window.** The pair is read off the two
dates and the gap between them, so a pair whose first transplant falls outside
its line's window is still a tandem and still counts as one event: at line 1 a
pair on days 200 and 300 leaves the **third** transplant as the one that ends
the line, exactly as an in-window pair would — scenario `S11c`, and `S11a` and
`S11b` are the one- and two-transplant cases beside it.

**What the window decides is whether the pair holds the line OPEN.** Only a
first transplant inside the line's applicable window can do that (§6.5), and
without the hold the line ends on its own run-out wherever that falls. A tandem
cannot keep a line open that has already ended, and that is where the two
readings come apart:

    d1     line 1 starts on its regimen
    d341   AUTO 1 — 341 days out, far outside the 60-day window, so nothing
           holds line 1 open to anything that follows it
    d400   line 1 ends on its own confirmed run-out
    d520   AUTO 2 — 179 days after AUTO 1, so within sct_tandem_days
    ---
    line 1 ended 120 days before AUTO 2 and cannot contain it. If nothing
    else gave AUTO 2 a line, the transplant would belong to nothing. It
    opens line 2 as SCT_AUTO instead.

What gives it that line is the **next line's** candidate rule, not a refusal to
call the pair a tandem: §9.2's condition (ii) exempts an AUTO within
`sct_tandem_days` of the one before it only where **that earlier AUTO is itself
inside the window**. Here it is not, so AUTO 2 is a candidate and opens line 2.
Where the earlier AUTO is in the window the exemption holds, the pair stays
inside the line it belongs to, and no line opens on the partner.

QC check `E5` is what finds an event that falls through both: it starts from the
processed transplants rather than from the lines, so an event in no line has a
row to be wrong on.
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

Only the **first** transplant of a tandem pair need be inside the window; its
partner may sit outside it and still hold the line open to its own date. The
pair must still be within `sct_tandem_days` of each other, or it is not a pair
(§6.3). What makes that safe is §6.3's clear gap: a pair with a medication start,
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

**Two agents are taken off this list by rules of their own**, so `MED_ADD` is
narrower than it reads here: a short melphalan course outside induction (§4.7),
and a returning earlier-line drug the count folds (§4.8). Both are held inside
the line instead, which is why the line's run-out can sit later than its own
drugs' cover.

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
| The melphalan short-course rule — §4.7 | `lot/engine/R/melp_rule.R` |
| The returning-drug fold-in — §4.8 | `lot/engine/R/foldin_rule.R` |
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
