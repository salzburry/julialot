# What the study team asked for, and where each ask stands

What was asked, when, what was decided, and whether the build does it today.

**This file decides nothing.** A rule the build applies is stated in
`lot/LOT_RULES.md`; a setting it turns on is pinned in `CONTRACT`. This is the
trail to those, and the list of what is still owed.

| | Ask | Asked | State |
|---|---|---|---|
| 1 | Melphalan short-course rule (28 days) | 19 Aug, confirmed 20 Aug | **Built.** `LOT_RULES.md` 4.7 |
| 2 | MAP fold-in: a returning drug joins the line it returns in | 15 Aug, refined 20 Aug | **Built and applied.** `LOT_RULES.md` 4.8 |
| 3 | Five-branch melphalan rule | 1 Aug | **Measured, not adopted** |
| 4 | Discontinued 1L, then a 12-month baseline before 2L / 3L | 19 Aug | **Answered** |
| 5 | What "melphalan mono" means when melphalan came with a steroid | 19 Aug | **Answered.** `LOT_RULES.md` 2.1 |
| 6 | A line advances on a NEW agent, so a drug the patient has had before should not start one | 30 Aug | **Built and applied.** `LOT_RULES.md` 4.3 |

---

## 1. The melphalan short-course rule — BUILT

**Asked (19 Aug), confirmed (20 Aug):** melphalan received for 28 days or fewer
outside any induction window does not advance the line. And: a patient
given melphalan on day 100 for 28 days who then starts a new agent on day 105
should have the new line start on **day 100**, when the melphalan appears — not
on day 105.

**Decided:** adopt it. The five-branch rule asked for first was measured and
not adopted — the boundaries it judges are not the ones melphalan actually
creates.

**Where it lives:** `apply_melp_rule = "simplified"` in `CONTRACT`,
`lot/LOT_RULES.md` 4.7, `lot/engine/R/melp_rule.R`. Course cap 28 days, and the
build offers no other.

**Two things it does that the ask did not say in words**, both deliberate, both
open to correction:

- **The line is carried to the end of the course's cover.** Refusing a course
  a boundary leaves the treatment in no line at all, so the line it fell in
  owns it. On a planted case this moves a day-150 run-out to day 327, changing
  that line's end date, its end reason and the baseline window before the next
  line. The vignettes are marked `to_confirm` for this reason.
- **A course after a line's own single-day shape still holds it.** An
  allogeneic line, or a CAR-T line with no consolidation drug, spans one day —
  unless a melphalan course it owns carries it further (`LOT_RULES.md` 4.6,
  7.2).

**One line owns a course** — the latest whose start comes before it. Another
line-defining agent arriving first disqualifies it from an earlier line, and so
does a transplant or CAR-T that breaks that line. Distance alone does not: a
course long after the drugs ran out still belongs to the line when nothing
happened in between.

A transplant breaks the line only when the engine's own rules say it does —
past the line's induction window, and not the second of a planned tandem pair.
Both rules read the same test.

---

## 2. The MAP fold-in rule — BUILT AND APPLIED

**Asked (15 Aug):** a patient on drug A + drug B in line 1, moved to line 2 by
a new drug C. If drug B comes back after line 2's induction window, B should be
**part of line 2** — not a reason to start line 3.

**Refined (20 Aug), and this refinement is what the mode now does:**

> If a drug comes back after being stopped, look at what was given in between.
>
> - If **one** new drug was given in between — outside the current line's
>   induction window, and it advanced the line — then the returning drug does
>   **not** start a new line. It is bundled into the line it returns in.
> - If **two or more** different agents were introduced in between — advancing
>   the line twice or more — then the drug's return **does** start a new line.

**State today.** Adopted on 30 Aug. `apply_map_foldin` is pinned `TRUE` in
`CONTRACT` and the rule is stated in `lot/LOT_RULES.md` 4.8, so the study's
lines carry it.

**How the count works.** For each return, the engine counts the **different
agents** that opened a line between that drug's two doses. One, and the return
folds. Two or more, and it starts a line, as it does today. Zero is not the
note's case at all — nothing advanced, so the drug is returning to the line it
left, and §4.3 keeps it there.

Agents, not lines, because that is the note's own word. A line is read through
the drug it opened on. Counting lines, a drug that opened one, stopped and
opened another on a released restart was two advances, and a drug returning
from an earlier line was refused a fold on one drug's treatment holiday. Ask 6
has since removed that restart's line altogether, so the two readings now
differ only where the same agent genuinely opens two lines.

**Transplants and CAR-T are outside the count, because the note is about
drugs.** It was written for a patient whose line was advanced by an agent, and
transplants were not in view. So they are not read into it either way: they
keep the rules they have everywhere else (`LOT_RULES.md` 6), where they are
standalone line-defining events, and one that opened a line between the two
doses overrides the fold whatever the agent count says. One the line owns —
inside its window, or a planned tandem partner — opens no line and overrides
nothing.

This is a scope, not an unanswered question. Nothing about transplants is owed
back to the study team here.

One consequence, and it is left as it is: a drug returning into a line that a
transplant or CAR-T opened does not fold. A drug coming back **soon** after a
transplant never needed this rule — the line's own consolidation window
(`LOT_RULES.md` 4.2) already takes it, and on a planted CAR-T line opened at
day 200 a return at day 230 joins that line under both builds. A return 100
days out gets a new line, which is what every other rule in the build gives.
Widening the window to reach it would change what a consolidation window means,
and `allo_lot_span = extend_to_next` does not help either: it lengthens the
transplant line but the return still ends it with `MED_ADD` and opens the next
one.

**The interval is dose to dose**, not stop to return. A drug's cover often runs
past the line it belonged to, so measuring from where it stopped would put the
advance that ended that line *before* the interval and count zero — and the
note's own example must fold.

**The return must be in the line that claims it.** While lines are built in
order the count is line-relative — at the second line only one line has opened,
at the third both have — so without this a single return folded into one line
and started another. That ownership test is separate from the count, and
procedures do count in it: a transplant that breaks the line, past its
induction window and not a planned tandem partner, means the return belongs to
a later line.

**A permissible substitute and the drug it replaces are one agent**, in both
directions. A regimen naming the reference product folds its substitute's
return, and a regimen naming the substitute folds the reference product's — the
fold set is read through the agent rather than through the drug the regimen
happened to write down. The pair dosed on a single day is one course, so the
tie decides nothing either.

**A prior line with two agents.** Each returning agent is judged on its own
interval and its own count, and a returning agent is not an advance for the
other. Line 1 of A + B, line 2 opened by C: A and B each see one advance, so
both fold into line 2 — whether they come back together or months apart. This
is the note's own example with both drugs coming back rather than one.

**What is still owed:**

- ~~Whether the returning drug joins the line's regimen string or only its
  span.~~ **Settled 30 Aug: the regimen.** A drug the rule says is part of the
  line reads as part of it, so it enters `LOT_BASE_MEDS`, `LOT_MED_CNT` and the
  line's med and class flags. Before this a line could span 13 months of two
  drugs and still read as monotherapy in every regimen table.

  Two bounds came out of building it, both on planted patients. The regimen
  names the drug **actually given**, so a permissible substitute appears under
  its own abbreviation rather than the one it stands in for. And a folded
  episode after a transplant that broke the line does **not** join — it belongs
  to the line that transplant opened. Without that second bound a line named a
  drug it never covered, which the QC invariant on regimen membership caught.

  A held melphalan course still joins neither the regimen nor the count (§4.7).
  That rule was not asked the same question, and nothing here decides it.
- ~~Whether agents of **every** earlier line fold, or only the previous line's.~~
  **Settled 30 Aug: the immediately previous line only**, which is the shape
  the 15 Aug note describes — A + B in one line, C advances it, B comes back.
  A drug from further back is out of scope and the engine's ordinary rules keep
  it.

  One thing follows that is worth the study team knowing: the note's **"two or
  more"** clause can then never fire. A drug is in a line's regimen only
  through an episode starting at or after that line's start, and the return has
  to be inside the line being built, so exactly one line can ever have opened
  in between. Scoped this way the count is always nought or one. Nothing
  observable changed when it was narrowed — every planted patient lands where
  it did — because the wider set could not reach two either, once a same-drug
  restart stopped opening a line of its own (ask 6).
- ~~Which rule is applied first where the two meet.~~ **Settled**, from what
  the two notes say rather than from a choice of ours. Both directions now
  hold:
  - a melphalan course the melphalan rule suppressed does not advance the
    line, so it is not an agent that advanced it for this count either;
  - a returning drug is, in the note's own words, "the returning drug" and not
    a new one, and the melphalan rule advances a short course only when the
    patient "starts a **new** agent" — so a returning drug confirms nothing.

  Neither reading needed an ordering decision, because neither rule has to
  consult the other's output: what a returning drug IS comes from the earlier
  lines' regimens, which are already built. On a planted patient the fold-in
  used to do nothing at all here — the drug was bundled by one rule and read
  as a change by the other, and the line advanced on the melphalan date
  regardless.

**Sizing already done, on a build without the rule:** 1,408 patients have a
line break caused only by a returning previous-line drug; 39 more keep the
break because a genuinely new drug started the same day. Most returns are
soon — 1,114 within six months of the drug's last cover, 92 beyond a year.

---

## 6. A drug the patient has had before does not start a line — BUILT AND APPLIED

**Asked (30 Aug):** to advance a line you need a new agent that was not part of
the prior regimen. A drug of the line's own regimen coming back after a break
is not that, so it should not open the next line.

**State today.** Adopted. `apply_own_return_fold` is pinned `TRUE` in
`CONTRACT`, the rule is `lot/LOT_RULES.md` 4.3, and the engine's older release —
where a gap of `map_discon_gap_days` let the drug open a line like any other
agent — is gone.

**The other half, and it is not optional.** Refuse the return a line and the
returning treatment would belong to no line at all, so the line's run-out now
chains over the break. A same-drug re-challenge is one line spanning the gap,
where it used to be two. `map_discon_gap_days` still decides when cover has run
out and where an episode boundary falls; it no longer decides whether the return
opens a line.

**This is the widest of the three rules adopted on 30 Aug.** It reaches every
patient with a treatment holiday, not only the ones §4.7 and §4.8 touch. It
changes line counts, line durations and line dates, and line duration now
includes any break inside the line. The scenario catalogue's S06 is the shape:
one drug, a 90-day break, then the same drug again — two lines before, one now.

**Not yet sized.** The population is every patient whose own regimen drug comes
back after a gap. `exploration/lot/run_rechallenge_evidence.R` counts those
returns and the gap behind each one; the next production run is what puts a
number on the change.

---

## 3. The five-branch melphalan rule — MEASURED, NOT ADOPTED

**Asked (1 Aug):** melphalan advances the line on windows of its own, on a
five-branch table keyed to when the next melphalan exposure comes.

**Result:** it moved almost nothing — most conditioning melphalan has no later
dose for the branches to judge. 2L melphalan-only went 424 → 422 patients. Not
adopted. The cells stay runnable as the evidence:
`exploration/melphalan/run_aug1_melp.R`.

---

## 4. Discontinued the prior line, then a 12-month baseline — ANSWERED

**Asked (19 Aug):** how many patients discontinue 1L before a 12-month
continuous-enrolment baseline period for 2L, and the same for 3L.

**Answered** by `analysis/questions/aug15_studyteam_qs.R`. The window is a
fixed 365 days back from the next line's start, not the gap between the lines.

Produced on a build **without** the melphalan rule, so superseded by the next
production run.

---

## 5. What "melphalan mono" means — ANSWERED

**Raised (19 Aug):** some patients recorded as melphalan monotherapy may be
valid mono regimens, and some were melphalan with a steroid.

**Answered by the algorithm, not by a decision waiting to be made.** Steroids
are not oncology agents here: `LOT_RULES.md` 2.1 excludes them from every line
decision — sixteen predicates across the steps and the two adopted rules — and
the code-list load drops steroid rows from the rollup before any of them run.
So melphalan given with a steroid **is** melphalan monotherapy, in the same way
it is for every other regimen in the study. There is nothing here that reads
one way for melphalan and another way elsewhere.

**What is worth saying when those counts are quoted** is the reporting side,
which is a read rather than a decision. The spec keeps steroid claims in the
episode data even though no rule reads them, so whether a melphalan-mono line
can be told apart from melphalan-plus-steroid depends on the production rollup:
QC check `D3` counts episodes carrying a steroid, and it says which state the
run is in. Zero and the two cannot be separated at all; a count and they can,
by reading the episodes directly. Either way no line moves.

---

## Numbers on this page

Everything quoted here came from the 19 Aug production run, built **before**
the melphalan rule was adopted. The rule changes line counts, line ends and line
shapes, so every figure needs re-reading from the next run before it is quoted
again.
