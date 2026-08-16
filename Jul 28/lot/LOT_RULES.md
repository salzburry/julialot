# The lines-of-therapy rules

Every rule the build applies, the setting that governs it, the file it lives in,
and a scenario for each one.

**The rules this build applies, and only those.** The melphalan
line-advancing proposal is an exploration — it is not in the study's numbers,
it is not built into any run that ships, and it is not here. `lot/FILES.md`
says what that package is and what is still open on it.

*Applied* is not *settled*. Seven of the scenarios below are marked
`to confirm`, §11 carries two rules that are applied and still under review,
§12 lists where the build departs from the written protocol, §3.3 records a
known defect in the regimen rule, and §14 records a contradiction between two
rules that both ship. What every rule here has in common is that the
build does it on every run — not that the clinical question behind it is
closed.

Written from the code, not from the spec — where the two differ, this follows
the code and says so (§12). Two rules entered the numbers on 2026-08-13 and
were not in them before: the CAR-T induction rule (§6.4) and the discontinuation
confirmation buffer (§5.3). Runs before that date differ from this document.

`lot/FILES.md` is the other half of this folder's documentation: what is in it,
and what each file does.

---

## How to read a scenario

Every rule below carries one. A scenario is a timeline of claims and what the
algorithm makes of them:

    d0     LEN dispensed, 60 days supply
    d+31   POMA dispensed
    ---
    LOT1   d0 -> d+59   LEN POMA

`d0` is the patient's first non-steroid MM agent unless the scenario says
otherwise, and offsets are days from it. Where a scenario turns on a setting,
the offset is written as the setting rather than as a number, because a number
in prose is wrong the moment the setting moves.

Each one is labelled by how far it is from having been seen:

| | |
|---|---|
| *engine output* | run through the build. The dates are what it produced. |
| *derived* | follows from the rule quoted beside it — reading the code is enough |
| *to confirm* | the rules interact and this is our reading of them; the first real run settles it |

`to confirm` is a claim about us, not about the algorithm. Those are the ones to
look at before quoting any of this.

Scenarios naming a vignette id — `tandem_within` and the like — have a twin in
`lot/validation/R/vignettes.R`. `Rscript lot/validation/run_vignettes.R` renders
the catalogue.

Be clear about what that twin buys, because it is less than it looks.
`test_vignettes.R` checks the catalogue's **internal consistency**: that every
setting a case names exists in the config, that each boundary pair straddles its
setting and the two sides expect different things, that timelines run forwards,
that the quoted files are there, and that this document and the catalogue cite
each other in both directions. It does **not** run a patient through the engine.
No scenario on this page has been executed against the SQL, and none of them is
a regression test — an `expected` is a reading of the rules, not an observed
output. What the catalogue prevents is drift: a renamed setting or a moved
boundary fails it. What it cannot prevent is the rules being read wrongly in the
first place, which is what the `to confirm` marker is for.

## The rules at a glance

| | Rule | Setting | |
|---|---|---|---|
| §2.1 | Steroids are excluded everywhere | — | |
| §2.2 | A medical claim covers 28 days | `medical_day_supply` | |
| §2.3 | A claim arriving while cover is live extends the episode | — | |
| §3.1 | Line 1 starts at the first non-steroid MM agent | — | |
| §3.2 | Line 1's induction window is 60 days | `induction_window_days` | |
| §3.3 | Regimen membership is an episode start, not a fill | — | |
| §3.4 | Line 1's first autologous transplant is part of induction | — | |
| §4.1 | A later line opens on the earliest of four candidates | — | |
| §4.2 | Later induction is 30 days, 45 on a CAR-T-started line | `lot_n_induction_window_days`, `cart_consolidation_days` | |
| §4.3 | A drug in the previous line's regimen cannot start a line | — | |
| §4.4 | A permissible biosimilar substitute cannot either | — | |
| §4.5 | Same-day starts break `SCT_ALLO > CART > SCT_AUTO > MED` | — | |
| §4.6 | An allogeneic line spans one day and carries no regimen | `allo_lot_span` | |
| §5.1 | A 90-day gap is running out | `map_discon_gap_days` | |
| §5.2 | A run-out chains forward over the drug's own later episodes | — | |
| §5.3 | A run-out is a discontinuation only once confirmed | `lot_discon_confirm_days` | |
| §6.1 | AUTO codes within 13 days are one transplant | `sct_auto_window_days` | |
| §6.2 | AUTO events under 60 days apart merge | `sct_auto_gap_days` | |
| §6.3 | A second AUTO within 180 days is a planned tandem | `sct_tandem_days` | |
| §6.4 | A CAR-T inside line 1's induction window is part of line 1 | `apply_cart_induction_rule` | |
| §7.1 | A line ends at the first of six events, by priority | — | |
| §7.2 | Within the transplant branch the earliest date wins | — | |
| §7.3 | An added agent then a CAR-T within 45 days is `CART_INIT` | `cart_consolidation_days` | |
| §7.4 | An agent added outside induction is `MED_ADD` | — | |
| §7.5 | Death does not outrank a run-out the patient came back from | — | |
| §7.6 | Disenrollment is not censoring | — | |
| §7.7 | Line length is inclusive of both ends | — | |
| §8 | Belantamab removes the patient, not the line | `apply_no_belantamab` | |
| §9 | Five lines are built, and nothing above them | `max_lot` | |
| §10 | Maintenance is a flag, not a line | — | |
| §11 | Two rules that are applied and still under review | — | |
| §14 | **To confirm** — a CAR-T that belongs to no line | `apply_cart_induction_rule` | |

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

Being off is not the same as being absent, and it is worth being plain about
which this is. The rule's module is inside the engine (`R/melp_rule.R`, sourced
on every run) with splice points in `06_lot1_end.R` and `10_lot2_5_base.R`,
because the rule needs each line's own induction window and that exists only
while the line is being built. What makes blank safe is not that the code is
gone but that every hook emits an empty string, so the generated SQL is the SQL
the engine generated before the file existed — and
`exploration/melphalan/tests/test_aug1_melp.R` proves it rather than asserting it, by
substituting each hook's off value back into the step text and requiring nothing
melphalan to remain.

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

**Scenario** — *derived; vignette `steroid_only_interval`.*

    d0     1L regimen starts
    d+150  dexamethasone alone for several weeks
    d+220  the next regimen begins
    ---
    the steroid stretch neither starts a line nor continues one

Steroids accompany almost every myeloma regimen. Counted, they would start lines
everywhere and no line would ever be seen to end.

### 2.2 A medical claim is assumed to cover 28 days

A medical claim carries no day supply, so `medical_day_supply` is assumed for
it. `MAP_END_DT` is the later of the rx run-out and the medical run-out.

**Scenario** — *derived.*

    d0     a medical-claim administration, no day supply on the claim
    ---
    cover runs d0 -> d+27, medical_day_supply = 28 days inclusive

### 2.3 A claim arriving while cover is live extends the episode

A new period opens only for a claim beyond every run-out. One arriving while
cover is still live pushes the run-out out instead of opening a second episode.

Optum supplies no treatment end date, so cover is `FILL_DT` plus `DAYS_SUP`,
pushed out by overlapping refills. That stockpiling is a dispensing artefact
rather than a treatment record, and it is the mechanism behind §3.3 and §7.4.

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

---

## 3. Line 1

`lot/engine/R/steps/04_lot1_base.R`.

### 3.1 Line 1 starts at the first non-steroid MM agent

**Scenario** — *derived.*

    d0     dexamethasone
    d+10   LEN dispensed
    ---
    LOT1 starts d+10

The steroid is not an oncology agent (§2.1), so it does not fix the index.

### 3.2 Line 1's induction window is 60 days

Every distinct non-steroid agent whose episode starts from the start date
through day 59 joins line 1's regimen — `induction_window_days` days inclusive
of day 0. `LOT_BASE_MEDS` and `LOT_MED_CNT` are those observed agents.
Permissible biosimilar substitutes enter the set used for discontinuation and
added-medication logic, but are not counted in `LOT_MED_CNT` and not listed in
`LOT_BASE_MEDS`.

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

The test is `MAP_START_DT` inside the window, and a refill landing while an
earlier episode still has cover is absorbed into that episode (§2.3) rather than
opening a new one. Two consequences, and they are not the same thing:

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

**Scenario** — *derived.*

    d0     LOT1 starts on LEN and DARA
    d+120  LOT2 starts on POMA, while DARA is still covered by a d+100 refill
    ---
    DARA is NOT in LOT2's regimen — its episode started in LOT1

`Rscript exploration/lot/run_stockpiling_rule.R` sizes the second case against a
finished run, in `STOCKPILE_AGENTS` and `STOCKPILE_IMPACT`.

**Known defect — an agent can be in the regimen whose supply starts after the
line ended.** Induction medications are gathered across the whole induction
window, and the line's end is fixed later in the cascade (§7.1). So an event
that closes the line early — a transplant is the usual one — can leave an agent
in `LOT_BASE_MEDS` whose first supply episode begins after the line was already
over.

    d0     LOT1 starts on LEN
    d+10   allogeneic transplant closes the line at d+9
    d+30   DARA dispensed, still inside the 60-day induction window
    ---
    LOT1  d0 -> d+9    regimen LEN DARA
    LOT2  d+10         the ALLO, a single-day line with no regimen (§4.6)
    LOT3  d+30         DARA

An allogeneic transplant rather than an autologous one: line 1's first AUTO is
part of induction and closes nothing (§3.4), so it cannot be what ends the line
here. An excess AUTO would do as well.

The agent is counted twice. DARA is in LOT1's `LOT_BASE_MEDS` even though its
supply starts 21 days after LOT1 ended, and it then starts LOT3 as well —
LOT2 is the ALLO line, which carries no regimen, so §4.3's prior-regimen
exclusion has nothing to exclude DARA against.

It is not only a cosmetic string. The agent also reaches the run-out
calculation (§5.2) and the next line's prior-regimen exclusion (§4.3), so it
can move a later line boundary as well.

QC check `C1` does **not** catch this. C1 asks whether a regimen agent has an
episode in the line's *induction window*; this asks whether it has one in the
line's *actual span*, and an early transplant makes those two different. The
count is `regimen-agent-begins-after-line-end` in
`exploration/lot/run_lot_audit_counts.R` — 30 of 10,659 lines carrying a regimen on the
synthetic cohort. Not yet fixed, and not yet measured against the production
run.

### 3.4 Line 1's first autologous transplant is part of induction

A first-ever transplant does not end line 1 and does not open line 2. Lines 2 to
5 do not keep this convention — there the first transplant outside the previous
line's window ends the line (§4.1).

**Scenario** — *to confirm; from vignette `allo_after_failed_auto`.*

    d0     1L regimen starts
    d+40   autologous transplant
    ---
    the AUTO sits inside LOT1. It neither ends the line nor opens the next one

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

**Scenario** — *engine output.* The `d_MED` candidate, on the second example in
§3.2: POMA at d+61 is outside line 1's window and in no regimen of line 1's, so
it opens LOT2 on its own date.

### 4.2 Later induction is 30 days, and 45 on a CAR-T-started line

Non-steroid agents from the start date through day 29
(`lot_n_induction_window_days`), or day 44 on a CAR-T-started line
(`cart_consolidation_days`).

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

### 4.3 A drug in the previous line's regimen cannot start a line

The protocol starts a later line at "the first administration for a new MM agent
that was not part of the previous LOT regimen", and a drug that *was* that
regimen is not such an agent — however long it has been gone. The line that owns
the drug extends over its later episodes instead (§5.2).
`lot/engine/R/prior_regimen.R`.

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

The substitute is unioned into the previous line's regimen for this test, so it
is excluded from `d_MED` the same way the reference product is.
`permissible_subs.csv` names the pairs.

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

`allo_lot_span` is `single_day`, and induction rows are suppressed for an
ALLO-started line.

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

A drug's cover in a line is chained forward over its own later episodes, because
a drug that was in this line's regimen cannot open the next line (§4.3). The
chain stops at the first break caused by a *different* agent, and what breaks it
is deliberately narrow (`lot/engine/R/prior_regimen.R`):

- a drug in **this** line's own regimen does not break it, and neither does a
  permissible substitute of one — so a second regimen agent refilling mid-line
  cannot truncate the first one's cover;
- steroids never break it;
- transplant and CAR-T are not read here at all. One that ends a line does so at
  a higher priority than `DISCONTINUATION`, so a run-out chained past it never
  surfaces; one that does not end a line — line 1's induction AUTO, a tandem
  inside `sct_tandem_days`, a CAR-T inside line 1's window — must not break the
  chain anyway.

**Scenario** — *engine output.* The first example in §4.3: LEN returns 185 days
after its own cover ran out, nothing else in between, so LOT1's run-out chains
forward to the end of the September episode and the line ends 30 September.

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

After the grouping in §6.1, events less than `sct_auto_gap_days` apart become
one. It is the second pass: §6.1 groups codes into events, this merges events
that are too close together to be two transplants.

**Scenario** — *derived.*

    d+40   an AUTO event
    d+80   a second AUTO event, 40 days later
    ---
    one AUTO event, not two — 40 < sct_auto_gap_days

### 6.3 A second AUTO within 180 days is a planned tandem

A second AUTO within `sct_tandem_days` of the one before it is a planned tandem
and does not end the line and does not start one. Beyond it, the transplant is
excess and does both.

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

`apply_cart_induction_rule` is `TRUE`, so this is the study's behaviour.
Confirmed by the study team on 2026-08-13. `lot/engine/R/cart_rule.R`.

The infusion does not end line 1 and does not start one. Line 2 onward keep
their own windows, and a CAR-T there behaves as it always has.

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

A CAR-T acts on a line boundary in three places, and the rule reaches all three
— stopping only one moves the problem rather than fixing it:

| Where | Without the rule | With it |
|---|---|---|
| `lot1_sct` | `FIRST_CART_DT` feeds `LOT1_TX_ENDDATE`, ending LOT1 as `SCT_CART` | the in-induction CAR-T is not a line-ending SCT |
| `lot1_base_end` | `CART_INIT_FLG` ends LOT1 at `FIRST_CART_DT − 1` | the flag cannot be set by an in-induction CAR-T |
| LOT2 `d_CART` | the same infusion opens LOT2 | it is excluded as a start candidate |

The post-run-out guard (§7.5) is gated the same way, since it is documented as
mirroring LOT2's start candidates.

**What it deliberately does not do.** It does not extend line 1 to swallow a
CAR-T that arrived after line 1 had already ended for some other reason.

**Scenario** — *derived.*

    d0     1L regimen starts
    d+30   the line ends — a run-out, or an added medication
    d+40   CAR-T
    ---
    LOT1 still ends d+30. The rule stops that CAR-T starting a line; it does
    not reopen a closed one

`q3_cart_screen()` in `analysis/questions/jul20_studyteam_qs.R` counts the patients
that lands on.

**What it moved.** `SCT_CART` and `CART_INIT` counts both fall — not by the same
patients and not by the whole affected population, since the two reasons are
mutually exclusive and a patient whose line 1 already ended earlier for a
competing reason carried neither before the rule. Numbers from any run before
2026-08-13 are not comparable on those two end reasons, on line 1's length, or
on line counts for the patients it touches.

Turning it off needs `LOT_CONTRACT_OVERRIDE=TRUE` and
`APPLY_CART_INDUCTION_RULE=FALSE`, and is recorded as a deviation like any other
contract change.

---

## 7. How a line ends

Two stages, not one flat list.

### 7.1 A line ends at the earliest qualifying event

**The earliest event wins. The order below decides only which reason is
recorded when two land on the same date.** Every branch in the cascade is gated
against the ones under it — the transplant branch fires only when
`LOT1_TX_ENDDATE <= LOT1_BASE_1ST_ADD_MED_DT` and `<= LOT1_BASE_DISCON_DT`,
`MED_ADD` only when the added agent is at or before the run-out, and so on
(`06_lot1_end.R`). So a later event never displaces an earlier one.

| Order | Branch | End date |
|---|---|---|
| 1 | a transplant or CAR-T | the day before the procedure — §7.2 |
| 2 | `CART_INIT` | the day before the infusion — §7.3 |
| 3 | `MED_ADD` | the day before the added agent — §7.4 |
| 4 | `DEATH` | the date of death — §7.5 |
| 5 | `DISCONTINUATION` | the confirmed run-out date — §5.3 |
| 6 | `STUDY_END` | the end of observation |

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

The reason names which type it was — `SCT_AUTO`, `SCT_ALLO` or `SCT_CART`. There
is no priority between the three; an ALLO does not outrank an earlier AUTO.

`SCT_CART` therefore arises two ways: a line that ends at a CAR-T, and a
CAR-T-started line with no consolidation agent, which spans a single day.
Neither applies to a CAR-T inside line 1's induction window (§6.4).

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

An added medication followed by a CAR-T inside `cart_consolidation_days` is
bridging therapy. The line ends the day before the infusion, and the bridging
agent stays in that line rather than starting a regimen of its own.

The added medication has to be an addition, which at line 1 means it starts on
or after day 60: anything starting inside the induction window joins the
regimen and is not an added agent at all (§7.4). The scenarios below place it
there for that reason.

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

**`CART_INIT` is a taxonomy, not a fall-through.** An added medication followed
by a CAR-T inside the window belongs to `CART_INIT` and is never re-read as a
`MED_ADD` event.

**Scenario** — *derived.*

    d0     LOT1 starts
    d+200  the regimen runs out
    d+300  bridging agent added
    d+320  CAR-T
    ---
    LOT1 ends DISCONTINUATION at d+200 — not MED_ADD at d+300 — and the CAR-T
    opens the next line

### 7.4 An agent added outside induction is `MED_ADD`

The candidate is any non-steroid episode from the line's start to its run-out
whose agent is **absent from this line's regimen** (`first_add_candidates`,
`04_lot1_base.R`). There is no separate "after the induction window" predicate:
the regimen is exactly the agents whose episode started inside that window, so
an agent starting inside it is in the regimen by construction and can never be
an addition. At line 1 that puts the earliest possible `MED_ADD` on day 60.
This matches the protocol's rule 2, "initiation of a new MM agent that was not
present in the induction regimen".

**Scenario** — *derived.*

    d0     LOT1 starts on LEN
    d+90   POMA dispensed, outside the 60-day window and inside LEN's cover
    ---
    LOT1 ends d+89 as MED_ADD, and LOT2 starts d+90 on POMA

**Absorption hides an addition.** A claim landing while an episode of that agent
is still open opens no episode (§2.3), so it is never a candidate and the line
does not end.

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

### 7.5 Death does not outrank a run-out the patient came back from

`DEATH` outranks `DISCONTINUATION`, but only when no line-opening trigger sits
between the run-out and the death. Same trigger as §5.3, same reasoning.

**Scenario** — *derived.*

    d0     LOT1 starts
    d+200  the regimen runs out
    d+210  a new agent
    d+220  death
    ---
    LOT1 ends DISCONTINUATION at d+200, and the new therapy opens LOT2

    d0     LOT1 starts
    d+200  the regimen runs out
    d+220  death, with nothing in between
    ---
    LOT1 ends DEATH at d+220

### 7.6 Disenrollment is not censoring

A period ending at disenrollment is classified `STUDY_END`. There is no
`DISENROLLMENT` end reason; the `*_CE_SENS` columns carry the alternative
reading.

**Scenario** — *derived.*

    d0     LOT1 starts
    d+300  the patient leaves the plan
    d+500  the study period ends, the line still open
    ---
    LOT1 ends STUDY_END at d+500, and LOT1_BASE_END_CE_SENS carries d+300

### 7.7 Line length is inclusive of both ends

`LOT_BASE_LENGTH` is the run-out date minus the start plus 1 for a
discontinuation, and the end date minus the start plus 1 otherwise.

**Scenario** — *derived.*

    LOT1 starts d0 and ends d+29
    ---
    LOT_BASE_LENGTH = 30, not 29

A reader computing their own `datediff` reports every percentile a day short of
the number the rest of the study quotes.

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

---

## 9. Five lines are built, and nothing above them

`max_lot`. `check_lot_long()` refuses any line number outside `1..max_lot`.

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

---

## 10. Maintenance is a flag, not a line

There is no maintenance concept in the build. `contains_mtx_reg` is descriptive
and nothing more; `MAINTENANCE_END` and `SCT_NO_MAINT` are not final end
reasons, and those cases route by their earliest applicable event.

**Scenario** — *derived; vignette `maintenance_to_relapse`.*

    d0     1L regimen starts
    d+120  reduced to a single maintenance agent
    d+400  new agents added at relapse
    ---
    no maintenance line. The relapse is handled by the ordinary rules, so the
    line count does not include one

This is a deliberate divergence from algorithms that count maintenance
separately, and it shifts every later line number by one against them.

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

The rule is §4.3, and it is applied unconditionally in both deliveries with no
switch. What is recorded here is what it costs.

**The protocol** says a subsequent LOT starts at "the first administration for a
new MM agent **that was not part of the previous LOT regimen**", so a drug that
was that regimen cannot start the next line. The code follows this reading.

**The spec** agrees in the one place it touches this,
`maintenance_validated.csv` `MAINT_REINTRODUCTION_RULE`: "The introduction of
any MM therapies **including therapies that were part of the original regimen
does not advance the LOT** but ends the maintenance period." That rule is scoped
to maintenance, which the engine does not implement, so it is indicative rather
than binding.

**The cost.** A line can span a treatment-free interval — the §4.3 scenario is
one nine-month LOT1 with seven months uncovered, ending `DISCONTINUATION`. That
is the price of the return belonging to a line rather than to nothing.

### 11.2 A drug returning mid-line after a break in supply — INTERPRETATION

**The code** ends the line and opens the next one. The added-medication query
takes agents outside this line's regimen whose `MAP_START_DT` falls after the
induction window (§7.4). A supply episode reopens whenever cover lapses by a
single day, so a refill collected late produces a new `MAP_START_DT` and reads
as an initiation. The patient never stopped the drug.

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

- **The CAR-T induction rule is in the numbers** as of 2026-08-13, so runs
  before that date differ on `SCT_CART`, `CART_INIT`, line 1's length and line
  counts for the patients it touches. §6.4.
- **The discontinuation confirmation buffer is in the numbers** as of
  2026-08-13, resolving a contradiction inside the spec rather than departing
  from it: the `LOT1_BASE` tab requires 90 days of observation after a run-out
  and the later end-date tabs do not. The build follows the tab that has it, on
  every line. Runs before that date differ on end reasons, end dates and
  `LOT_BASE_LENGTH` for lines running out near the cutoff. §5.3.
- **The buffer is confirmed two ways, and the spec names only one.** The
  `LOT1_BASE` tab requires observation after a run-out; it says nothing about a
  patient who restarts inside that window. The build treats the restart as
  confirmation in its own right, so the run-out stands and the next line opens.
  Gating on elapsed observation alone would have merged those two lines into
  one. §7.5 already takes that position against `DEATH`. §5.3.
- **Regimen membership is an episode start, and the protocol reads wider.**
  §3.3.
- **Disenrollment is not censoring** in the primary analysis. §7.6.
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

## 14. To confirm — a CAR-T that belongs to no line

`cart_consolidation_days` stays at 45 and `apply_cart_induction_rule` stays
`TRUE`. Nothing below is a proposed change; it is a contradiction between two
rules that both ship, recorded so the study team can settle which one gives
way.

### The case

The CAR-T induction rule (§6.4) measures its window from **line 1's start**,
and applies it whatever line 1's end date turned out to be. So when line 1 ends
early, the window outlives the line:

    d0     LEN starts, 30 days of cover
    d+29   LEN runs out
    d+40   CAR-T
    d+120  observation continues, confirming the d+29 run-out (§5.3)
    ---
    LOT1   d0 -> d+29   DISCONTINUATION
    LOT2   never opened
    the CAR-T at d+40 is in no line at all

Four rules meet, and each is individually doing what it was written to do:

| | |
|---|---|
| §5.3 | the run-out at d+29 is confirmed, so LOT1 ends there |
| §6.4 | d+40 is inside d0–d+59, so the infusion is "part of LOT1" |
| §6.4 | ...but the rule does not reopen or extend a line that has already ended |
| §6.4 | ...and the same test removes d+40 from LOT2's `d_CART` candidates |

Verified in the code rather than inferred: `cart_in_induction_sql`
(`R/cart_rule.R`) tests `TX_DT BETWEEN PREV_START_DT AND date_add(PREV_START_DT,
59)`, and `cart_cand` in `10_lot2_5_base.R` ANDs `NOT(...)` of that into the
LOT2 start candidates. `PREV_START_DT` is line 1's start; the line's end date
is not consulted.

### Why it does not show up elsewhere

The orphan needs line 1 to end **before** the CAR-T for a reason that does not
itself open line 2. A run-out confirmed by observation is the case that does
it. Two near neighbours do not:

- **A transplant ends line 1 first.** The ALLO or excess AUTO opens LOT2 itself,
  so by the time LOT3's candidates are collected the previous line is no longer
  LOT1 and the exclusion is not applied at all (`cart_on` is
  `lot_num == 2L`). The CAR-T is reconsidered and starts a line.
- **A `MED_ADD` ends line 1 first.** The added agent opens LOT2, and the same
  reasoning applies.

So the population is narrow: line 1 discontinuing inside its own induction
window, with a CAR-T after the run-out and still inside day 59.

### The two consistent readings

The rules have to give one of these up. Both are one-line changes; neither is
made here.

1. **The infusion belongs to line 1, so line 1 must reach it.** Hold the line
   open to the CAR-T — extend `LOT1_BASE_END_DT` to at least the infusion date
   when an in-induction CAR-T falls after the end. This keeps §6.4's claim
   literally true and makes the line span a period with no cover, which §4.3
   already does elsewhere.
2. **Line 1 ended before the infusion, so the infusion starts line 2.** Gate the
   exclusion on the line's end as well as its start — exclude only a CAR-T that
   falls inside the induction window *and* on or before `LOT1_BASE_END_DT`. This
   keeps line 1 as the discontinuation left it and lets the CAR-T open LOT2.

Reading 2 is the smaller change and the one that cannot lose a treatment
episode, which is why it is written second rather than first — but that is an
argument, not a decision, and it belongs to the study team. Whichever is chosen,
`q3_cart_screen()` in `analysis/questions/jul20_studyteam_qs.R` is where the
affected patients are counted, and the count should be taken before the change
rather than after.

### What is not in dispute

The 45-day consolidation window (`cart_consolidation_days`) is not involved in
this at all — it governs the CAR-T-started line's own regimen window and the
`CART_INIT` bridging window (§7.3). The contradiction is entirely inside line
1's 60-day `induction_window_days`.

---

## 15. What stops a run

A cohort whose own build did not finish. A cohort that does not fit the study
window the run was given. A setting that differs from the pinned contract
without an explicit override. A code list that cannot be read, or one failing a
consistency check that is not waivable. A `LOT_LONG` whose lines overlap, run
backwards, skip a line number or end after observation. A line that ends in a
way these rules cannot produce.
