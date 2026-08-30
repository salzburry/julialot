# What the study team asked for, and where each ask stands

A standing record so nothing is lost between conversations: what was asked,
when, what was decided, and whether the build does it today.

**This file does not decide anything.** A rule the build applies is stated in
`lot/LOT_RULES.md`; a setting it turns on is pinned in `CONTRACT`. This is the
trail that leads to those, and the list of what is still owed.

| | Ask | Asked | State |
|---|---|---|---|
| 1 | Melphalan short-course rule (28 days) | 19 Aug, confirmed 20 Aug | **Built.** `LOT_RULES.md` 4.7 |
| 2 | MAP fold-in: a returning drug joins the line it returns in | 15 Aug, refined 20 Aug | **Not built.** Refinement below is not implemented either |
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

## 2. The MAP fold-in rule — ASKED, NOT BUILT

**Asked (15 Aug):** a patient on drug A + drug B in line 1, moved to line 2 by
a new drug C. If drug B comes back after line 2's induction window, B should be
**part of line 2** — not a reason to start line 3.

**Refined (20 Aug), and this refinement is NOT implemented:**

> If a drug comes back after being stopped, look at what was given in between.
>
> - If **one** new drug was given in between — outside the current line's
>   induction window, and it advanced the line — then the returning drug does
>   **not** start a new line. It is bundled into the line it returns in.
> - If **two or more** different agents were introduced in between — advancing
>   the line twice or more — then the drug's return **does** start a new line.

**State today.** `apply_map_foldin` is pinned `FALSE`, so the build still ends
the line at the returning drug and can start the next one on it. A fold-in mode
exists and is proven on planted patients, but it folds **unconditionally** — it
does not count how many agents came in between, so it is not what the 20 Aug
note describes. Turning it on would apply the wrong rule.

**What is still owed:**

- Count the line-advancing agents between the two doses of the returning drug,
  and fold only when that count is exactly one.
- Two readings the fold-in mode takes that the note has not confirmed: whether
  agents of **every** earlier line fold or only the previous line's, and
  whether a drug returning after the line already ran out still folds.
- Whether the returning drug joins the line's regimen string or only its span.
  Today it joins the span only.
- The two rules have not been made to work together. With fold-in on, a
  returning drug that folds into a line can still be read by the melphalan rule
  as a new agent confirming a short course — so the same drug would be bundled
  by one rule and treated as a change by the other. This needs one decision and
  one test, not two.

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
