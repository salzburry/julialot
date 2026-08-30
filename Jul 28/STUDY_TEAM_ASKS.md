# What the study team asked for, and where each ask stands

A standing record so nothing is lost between conversations: what was asked,
when, what was decided, and whether the build does it today.

**This file does not decide anything.** A rule the build applies is stated in
`lot/LOT_RULES.md`; a setting it turns on is pinned in `CONTRACT`. This is the
trail that leads to those, and the list of what is still owed.

| | Ask | Asked | State |
|---|---|---|---|
| 1 | Melphalan short-course rule (28 days) | 19 Aug, confirmed 20 Aug | **Built.** `LOT_RULES.md` 4.7 |
| 2 | MAP fold-in: a returning drug joins the line it returns in | 15 Aug, refined 20 Aug | **Built and applied.** `LOT_RULES.md` 4.8 |
| 3 | Five-branch melphalan rule | 1 Aug | **Measured, not adopted** |
| 4 | Discontinued 1L, then a 12-month baseline before 2L / 3L | 19 Aug | **Answered** |
| 5 | What "melphalan mono" means when melphalan came with a steroid | 19 Aug | **Open** — needs the study team |

---

## 1. The melphalan short-course rule — BUILT

**Asked (19 Aug), confirmed (20 Aug):** melphalan received for fewer than 28
days outside any induction window does not advance the line. And: a patient
given melphalan on day 100 for 28 days who then starts a new agent on day 105
should have the new line start on **day 100**, when the melphalan appears — not
on day 105.

**Decided:** adopt it. The five-branch rule asked for first was measured and
not adopted, because the boundaries it judges are not the ones melphalan
actually creates.

**Where it lives:** `apply_melp_rule = "simplified"` in `CONTRACT`,
`lot/LOT_RULES.md` 4.7, `lot/engine/R/melp_rule.R`. Course cap 28 days, and the
build does not offer another.

**Two things it does that the ask did not say in words**, both deliberate, both
open to correction:

- **The line is carried to the end of the course's cover.** Refusing a course
  a boundary leaves the treatment in no line at all, so the line it fell in
  owns it. On a planted case this moves a day-150 run-out to day 327, which
  changes that line's end date, its end reason, and the baseline window before
  the next line. The vignettes are marked `to_confirm` for this reason.
- **A course after a line's own single-day shape still holds it.** An
  allogeneic line, or a CAR-T line with no consolidation drug, spans one day —
  unless a melphalan course it owns carries it further (`LOT_RULES.md` 4.6,
  7.2).

**One line owns a course** — the latest whose start comes before it. Another
line-defining agent arriving first disqualifies it from an earlier line, and so
does a transplant or CAR-T after that line's induction window. Distance alone
does not: a course long after the drugs ran out still belongs to the line when
nothing happened in between.

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

**How the count works.** For each return, the engine counts the lines that
opened between that drug's two doses. One, and the return folds. Two or more,
and it starts a line, exactly as it does today. Zero is not the note's case at
all — nothing advanced, so the drug is returning to the line it left and the
engine's ordinary restart rule keeps it.

Three things about that count, each a reading to confirm:

- **The interval is dose to dose**, not stop to return. A drug's cover often
  runs past the line it belonged to, so measuring from where it stopped would
  put the advance that ended that line *before* the interval and count zero —
  and the note's own example must fold.
- **An advance is a line that opened**, whatever opened it. That reads the
  note's "advancing the LOT" directly, and it means a transplant-started line
  counts. The note says "agents", which would not.
- **The return must be in the line that claims it.** While lines are built in
  order the count is line-relative — at the second line only one line has
  opened, at the third both have — so without this a single return folded into
  one line and started another. A return with another line-defining agent
  before it belongs to a later line.

**What is still owed:**

- Whether the returning drug joins the line's regimen string or only its span.
  Today it joins the span only.
- Whether agents of **every** earlier line fold, or only the previous line's.
- **The two rules meet in one place only, and only one direction is
  resolved.** A melphalan course the melphalan rule suppressed is not a
  line-defining agent, so it no longer blocks a fold — that direction is done.
  The reverse is not: a returning drug that folds into a line can still be read
  by the melphalan rule as a new agent confirming a short course, so the same
  drug is bundled by one rule and treated as a change by the other. It cannot
  be fixed by reading the other rule back, because each rule would then depend
  on the other and neither can be built first. It needs a decision about which
  rule is applied first, and one test that says so.

**Sizing already done, on a build without the rule:** 1,408 patients have a
line break caused only by a returning previous-line drug; 39 more keep the
break because a genuinely new drug started the same day. Most returns are
soon — 1,114 within six months of the drug's last cover, 92 beyond a year.

---

## 3. The five-branch melphalan rule — MEASURED, NOT ADOPTED

**Asked (1 Aug):** melphalan advances the line on windows of its own, on a
five-branch table keyed to when the next melphalan exposure comes.

**Result:** it moved almost nothing, because most conditioning melphalan has no
later dose for the branches to judge. 2L melphalan-only went 424 → 422
patients. Not adopted. The cells stay runnable as the evidence for that
choice — `exploration/melphalan/run_aug1_melp.R`.

---

## 4. Discontinued the prior line, then a 12-month baseline — ANSWERED

**Asked (19 Aug):** how many patients discontinue 1L before a 12-month
continuous-enrolment baseline period for 2L, and the same for 3L.

**Answered** by `analysis/questions/aug15_studyteam_qs.R`. The window is a
fixed 365 days back from the next line's start, not the gap between the lines.

These numbers were produced on a build **without** the melphalan rule and are
superseded by the next production run.

---

## 5. What "melphalan mono" means — OPEN

**Raised (19 Aug):** some patients recorded as melphalan monotherapy may be
valid mono regimens, and some were melphalan with a steroid, which was dropped
from the code list.

Steroids are not captured anywhere in this build, so a melphalan-plus-steroid
line reads as melphalan alone in every count. Nothing decides this; it is
stated wherever those counts are printed.

---

## Numbers on this page

Everything quoted here came from the 19 Aug production run, which was built
**before** the melphalan rule was adopted. The rule changes line counts, line
ends and line shapes, so every one of those figures needs re-reading from the
next run before it is quoted again.
