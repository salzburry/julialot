# The LOT algorithm, rule by rule

Every rule the line-of-therapy build applies, with the setting that governs it
and the file it lives in. Written from the code, not from the spec — where the
two differ, this follows the code and says so.

Two things are **not** in the contract build and are marked as such throughout:
the melphalan line-advancing rule (§9) and the CAR-T 60-day induction rule
(§10). Neither is applied to the study's numbers today.

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
| `medical_day_supply` | 28 | assumed day supply for a medical claim |
| `sct_auto_window_days` | 13 | AUTO claims this many days apart are one transplant |
| `sct_auto_gap_days` | 60 | AUTO events closer than this merge into one |
| `sct_tandem_days` | 180 | second AUTO within this is a planned tandem, not a new line |
| `allo_lot_span` | `single_day` | an ALLO line spans only the ALLO date |
| `max_lot` | 5 | lines built per patient |
| `belantamab_med_abbr` | `BELA` | how belantamab is spelled on the code list |
| `apply_melp_rule` | *(blank)* | the melphalan rule is **off** — see §9 |
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

A patient has **run out** when the gap from `MAP_END_DT` to the next
`MAP_START_DT` is **90 days or more** (`map_discon_gap_days`). A gap of 90+ days
from the last `MAP_END_DT` to the end of observation counts too.

This is per drug, not per line. The line's runout date is the last cover of its
base agents.

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
| `d_CART` | earliest CAR-T |
| `d_AUTO` | earliest AUTO that is (i) outside the previous line's applicable window measured from that line's **start** — 0 days if ALLO-started, 44 if CAR-T-started, 29 otherwise — and (ii) not within 180 days of the immediately preceding AUTO (planned tandem) |

Unlike LOT1, a **first-ever AUTO can open a line** here.

**Same-day tie-break:** `SCT_ALLO` > `CART` > `SCT_AUTO` > `MED`.

**Regimen** — non-steroid agents from the start date through **day 30**
(`lot_n_induction_window_days`), or **day 45** on a CAR-T-started line
(`cart_consolidation_days`). An ALLO-started line carries no regimen rows at
all.

---

## 7. How a line ends

One cascade, highest priority first. This is a priority order, not a tie-break
on equal dates — but each branch is gated so it only fires when its event is at
or before the runout.

| Priority | Reason | Meaning |
|---|---|---|
| 1 | `SCT_ALLO` | allogeneic transplant |
| 2 | `SCT_CART` | CAR-T-started line with no consolidation agent — spans one day |
| 3 | `SCT_AUTO` | an AUTO outside the line's window |
| 4 | `CART_INIT` | an added medication followed by CAR-T within 45 days. **The line ends the day before the infusion** (`FIRST_CART_DT − 1`) |
| 5 | `MED_ADD` | a non-steroid agent added outside the induction window |
| 6 | `DEATH` | |
| 7 | `DISCONTINUATION` | ran out — 90-day gap |
| 8 | `STUDY_END` | |

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

## 10. The CAR-T 60-day induction rule — **proposed, not applied**

**Today a CAR-T always ends LOT1.** `CART_INIT` closes the line the day before
the infusion, and LOT2 opens as a CAR-T-started line. A patient whose CAR-T
falls three weeks into 1L induction comes out as **two lines**.

**The rule asks that it not.** When the first CAR-T falls inside LOT1's 60-day
induction window, it should count as part of LOT1 rather than a LOT2 start —
the CAR-T-started LOT2 folds back into LOT1.

**Status: screened, never implemented.** `q3_cart_screen()` in
`lot/questions/jul20_studyteam_qs.R` counts the affected patients and shows what
folding would look like; it describes itself as "not an engine re-run". There is
no fold-back anywhere in `lot/engine/`.

Two things need settling before it can be built:

1. Affected patients with **no LOT2 row** have no derivable merged LOT1 end
   date from the current outputs.
2. Folding moves the LOT1 end date, which changes the induction window content,
   the discontinuation date, and every later line for those patients.

---

## 11. Where this differs from the written protocol

- **The melphalan rule and the CAR-T rule are not in the numbers.** Both are
  requested; neither is applied. §9, §10.
- **B.2 removes a boundary without holding the line open.** §9.
- **Disenrollment is not censoring** in the primary analysis. §7.
- **Maintenance is not implemented.** There is no maintenance concept in the
  build; `MAINTENANCE_END` and `SCT_NO_MAINT` are not final end reasons and
  those cases route by their earliest applicable event.
- **`max_lot` is 5.** A patient capped at 5 lines is indistinguishable from one
  who completed 5.

---

## 12. Source files

| Rule | File |
|---|---|
| Settings, contract, metadata | `lot/engine/R/build_lot.R` |
| MAP stacking, day supply, runout | `lot/engine/R/steps/03_mma_map.R` |
| LOT1 start, regimen | `lot/engine/R/steps/04_lot1_base.R` |
| Transplant events, tandem | `lot/engine/R/steps/05_sct.R` |
| LOT1 end cascade | `lot/engine/R/steps/06_lot1_end.R` |
| LOT2-5 start, regimen, end | `lot/engine/R/steps/10_lot2_5_base.R` |
| Line criteria, truncation | `lot/engine/R/line_criteria.R` |
| Melphalan rule | `lot/engine/R/melp_rule.R`, `lot/melphalan/` |
| CAR-T screen | `lot/questions/jul20_studyteam_qs.R` |
