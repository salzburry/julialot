# Spec Edit Instructions — Step-by-Step

**Target file to edit:** `Apr 18 2026/Program Spec and Scenarios/lot1baseendapr18.pdf` (source workbook) and `Apr 18 2026/Program Spec and Scenarios/mtx scenarios.pdf`.

**Goal:** Apply the 8 confirmed edits (5 core + 3 clarifications) so the spec matches the Apr 15 2026 meeting decisions.

**Key framing (per Apr 15 meeting, LOT1):** The study does NOT derive a separate standalone maintenance period or maintenance regimen. Instead, it records whether LOT1 contains a valid maintenance-approved subset using `contains_mtx_reg`. The flag still requires identifying a valid maintenance subset with an anchor agent — but that is for **flagging presence only**, not for creating one official maintenance interval. Consequently, the old maintenance-based LOT-ending rules (Rule 4 "SCTs not followed by maintenance within 180 days" and Rule 8 "End of maintenance regimen") no longer apply, and the former `MAINTENANCE_END` end-reason bucket is removed (patients who would have landed there now fall through to `DISCONTINUATION` unless a higher-priority event applies).

**How to use this file:** Each step gives (a) the file/tab/row to open, (b) the exact "BEFORE" text to locate, (c) the exact "AFTER" text to paste in. Follow the steps in order — Steps 1–5 must be done; Steps 6–8 are recommended clarifications.

**Important correction (from the validated review):** The `CART_INIT` end date aligns to `FIRST_CART_DT - 1 day`, NOT the day before the added agent. All wording below reflects this.

---

## Step 1 — Remove Rule 4 and Rule 8 restated wording

**File:** `lot1baseendapr18.pdf`
**Tab:** `10. LOT1_BASE_END`
**Cell/Row:** Main rules cell on page 1 (the long narrative cell that lists Rules 1–8 twice — once struck through at the top, once clean further down).

### 1a. Delete the restated Rule 4

**BEFORE** (delete this exact phrase from the clean restated list):
> (Rule 4) SCTs not followed by maintenance within 180 days;

**AFTER:** (nothing — delete the whole clause including trailing semicolon)

### 1b. Delete the restated Rule 8

**BEFORE** (delete this exact phrase from the clean restated list):
> (Rule 8) End of maintenance regimen.

**AFTER:** (nothing — delete the whole clause including trailing period)

### 1c. Renumber if needed

If the team prefers gapless numbering, relabel the remaining rules as:
- (Rule 2) Discontinuation of all agents
- (Rule 3) Unplanned SCTs
- (Rule 4) Death (formerly Rule 5)
- (Rule 5) Health plan disenrollment (formerly Rule 6)
- (Rule 6) End of the study period (formerly Rule 7)

**Alternative:** keep the original Rule 5 / 6 / 7 numbers so downstream references don't break. Either is fine — pick one and be consistent.

### 1d. Also strike the same rules in the opening paragraph

The struck-through OCR garble at the top (`SGTs Het fella~. eel e·, rneif'lteAef'lee` and `ff!eIr,teF1eF1ee FBgiffleA`) should be cleanly deleted, not just visually struck. This leaves one clean list instead of two conflicting lists.

---

## Step 2 — Add remapping note for former `MAINTENANCE_END` patients

**File:** `lot1baseendapr18.pdf`
**Tab:** `10. LOT1_BASE_END`
**Cell/Row:** `LOT1_BASE_END_REASON` row, Definition or Additional Notes column.

### 2a. Add new paragraph at the end of the definition

**INSERT:**
> **Note (per Apr 15 2026 decision):** Patients whose LOT1 would previously have ended via Rule 8 (end of maintenance regimen) now map to `DISCONTINUATION` — unless a higher-priority event applies first (`MED_ADD`, `CART_INIT`, any SCT rule, `DEATH`, `DISENROLLMENT`, or `STUDY_END`). There is no dedicated `MAINTENANCE_END` end-reason value in this study.

---

## Step 3 — Add remapping table for former `SCT_NO_MAINT` patients

**File:** `lot1baseendapr18.pdf`
**Tab:** `10. LOT1_BASE_END`
**Cell/Row:** `LOT1_BASE_END_REASON` row, Additional Notes column (directly below the Step 2 note).

### 3a. Add mapping table

**INSERT:**

> **Remapping for former `SCT_NO_MAINT` cases (per Apr 15 2026 decision):** Single/tandem autologous SCTs are continuation of the line (Rule 3) and do NOT by themselves end LOT1. Patients who would previously have landed in `SCT_NO_MAINT` now fall into one of the following, whichever event occurs first:
>
> | Former `SCT_NO_MAINT` sub-case | New `LOT1_BASE_END_REASON` |
> |---|---|
> | Planned single/tandem AUTO followed only by runout/gap | `DISCONTINUATION` |
> | Planned single/tandem AUTO followed by a new non-induction agent (≥ 46 d before any CAR-T) | `MED_ADD` |
> | Planned single/tandem AUTO, then a new agent, then CAR-T within 45 days | `CART_INIT` |
> | 3rd AUTO / unplanned AUTO / ALLO after the planned AUTO | `SCT_AUTO` (Rule 3) or `SCT_ALLO` |
> | Death / disenrollment / study-end intervenes first | `DEATH` / `DISENROLLMENT` / `STUDY_END` |
>
> Single/tandem AUTO is never by itself an LOT1-ending event in this study.

### 3b. Minimum-viable alternative

If the table is too much for the cell format, at minimum add this one-line sentence:

**INSERT:**
> "Single/tandem AUTO SCTs do not create a separate maintenance-dependent LOT-ending category. LOT1 continues until Rule 2 (`DISCONTINUATION`), an unplanned/excess SCT (Rule 3), or a censoring event (`DEATH` / `DISENROLLMENT` / `STUDY_END`)."

---

## Step 4 — Add `CART_INIT` as an explicit `LOT1_BASE_END_REASON` value

**File:** `lot1baseendapr18.pdf`
**Tab:** `10. LOT1_BASE_END`
**Cell/Row:** `LOT1_BASE_END_REASON` row, Values column.

### 4a. Add enumerated values list

If the row currently lists allowed values informally or narratively, replace with an explicit enumerated list.

**INSERT** (into the Values column):

> **Allowed values (`LOT1_BASE_END_REASON`):** `DISCONTINUATION`, `MED_ADD`, `SCT_AUTO`, `SCT_ALLO`, `SCT_CART`, `CART_INIT`, `DEATH`, `DISENROLLMENT`, `STUDY_END`.

### 4b. Add precedence order

**INSERT** (into the Definition column, directly before the existing text):

> **Priority order (earliest-matching rule wins):**
> `SCT_ALLO` / `SCT_CART` / `SCT_AUTO (Rule 3)` > `CART_INIT` > `MED_ADD` > `DISCONTINUATION` > `DEATH` > `DISENROLLMENT` > `STUDY_END`

### 4c. Add CART_INIT definition

**INSERT** (as a new sub-row or bullet under `LOT1_BASE_END_REASON`):

> **`CART_INIT`** — A CAR-T LOT end reason applied to LOT1 when the patient has a non-induction agent added AND a CAR-T infusion within 45 days. Specifically:
>
> - Trigger condition: `LOT1_BASE_1ST_ADD_MED_DT` is not missing AND `FIRST_CART_DT - (LOT1_BASE_1ST_ADD_MED_DT + 1) BETWEEN 0 AND 45` (inclusive).
> - When triggered:
>   - `LOT1_BASE_END_REASON = 'CART_INIT'` (NOT `'MED_ADD'`).
>   - **`LOT1_BASE_END_DT = FIRST_CART_DT - 1`** (day before the CAR-T infusion — the CAR-T event itself starts the CAR-T LOT).
> - Rationale (per Apr 15 2026 meeting): CAR-T cellular therapy is its own LOT; oncology agents administered within 45 days before CAR-T are consolidated into the CAR-T LOT rather than standing up a separate MED_ADD line.

---

## Step 5 — Reword `contains_mtx_reg` as flag-only

**File:** `lot1baseendapr18.pdf`
**Tab:** `10. LOT1_BASE_END`
**Cell/Row:** `contains_mtx_reg` row on page 3 (currently the last row of the variable table).

### 5a. Insert framing sentence at the top of the Definition cell

**INSERT** (first sentence of the Definition column, before any existing text):

> **The study does not derive a separate standalone maintenance period or maintenance regimen. Instead, this flag records whether LOT1 contains a valid maintenance-approved subset (mono or dual, from the approved list) together with at least one additional non-steroid induction drug acting as an anchor. Identifying a valid subset + anchor is required for flagging presence only — it does NOT create a maintenance start date, maintenance end date, or LOT-ending event.**

### 5b. Keep the existing background explanation

Leave the existing paragraph (the one starting "Definition of a maintenance period: The LOT's initial regimen transitions into a maintenance regimen …") in place AFTER the new framing sentence, but prepend a label:

**INSERT** (as a lead-in to the existing paragraph):
> _Background clarification (for interpretation of the flag only):_

This keeps the detailed definition for readers who want it, but flags clearly that it is background, not a derivation rule.

---

## Step 6 — (Clarification) Label `mtx scenarios.pdf` as reference-only

**File:** `mtx scenarios.pdf`
**Location:** First page of the document.

### 6a. Add a banner note at the top of page 1

**INSERT** (bold, above existing text):
> **REFERENCE / BACKGROUND ONLY — updated per Apr 15 2026 meeting.**
>
> These scenarios are retained as background for interpreting the `contains_mtx_reg` flag. The study does NOT derive a maintenance period or use these scenarios as operational LOT-ending logic. For the active definition used in this study, see the `contains_mtx_reg` row in `lot1baseendapr18.pdf`.

### 6b. Alternative: rename the file

If the banner is not practical, rename the file to `mtx scenarios_REFERENCE_ONLY.pdf` or move it into an `archive/` or `reference/` sub-folder inside `Program Spec and Scenarios/`.

---

## Step 7 — (Clarification) Add worked examples to `contains_mtx_reg`

**File:** `lot1baseendapr18.pdf`
**Tab:** `10. LOT1_BASE_END`
**Cell/Row:** `contains_mtx_reg` row, Additional Notes column (below the Step 5 edits).

### 7a. Insert worked-example table

**INSERT:**

> **Worked examples (non-steroid induction drugs only):**
>
> | Induction regimen | Qualifying mtx subset(s) | Anchor candidate(s) | `contains_mtx_reg` |
> |---|---|---|---|
> | BORT + LENA | BORT+LENA (dual); BORT (mono); LENA (mono) | none outside any subset | 0 |
> | BORT + LENA + CYCL | BORT+LENA (dual); BORT, LENA monos | CYCL | 1 |
> | BORT + LENA + DEXA | BORT+LENA (dual); BORT, LENA monos | none (DEXA is steroid — does not anchor) | 0 |
> | BORT + DARA + LENA | {BORT+LENA}, {DARA+LENA}, {BORT}, {LENA}, {DARA} | always ≥ 1 other drug | 1 |
> | DARA alone | DARA mono | none | 0 |
> | CYCL alone | none (CYCL not in mtx list) | — | 0 |
>
> **Rule:** Flag = 1 if ANY valid mono or dual maintenance subset exists in the induction regimen AND at least one other non-steroid induction drug can anchor it.

---

## Step 8 — (Clarification) Explicitly exclude steroids as anchors

**File:** `lot1baseendapr18.pdf`
**Tab:** `10. LOT1_BASE_END`
**Cell/Row:** `contains_mtx_reg` row, Definition column (at the end of the Definition paragraph).

### 8a. Add one sentence

**INSERT** (last sentence of the Definition cell):
> Corticosteroids (e.g., dexamethasone, prednisone; any drug with `CL_MED_CLASS = 'STEROID'` in `CL_MMA_ROLLUP`) do NOT qualify as an anchor agent. Only non-steroid MM oncology agents count.

---

## Order of operations — quick summary

| Order | Step | File | Action |
|---:|---|---|---|
| 1 | 1 | `lot1baseendapr18.pdf` | Delete restated Rules 4 and 8 from the main rules cell |
| 2 | 2 | `lot1baseendapr18.pdf` | Add MAINTENANCE_END remapping note in `LOT1_BASE_END_REASON` |
| 3 | 3 | `lot1baseendapr18.pdf` | Add SCT_NO_MAINT remapping table in `LOT1_BASE_END_REASON` |
| 4 | 4 | `lot1baseendapr18.pdf` | Add enumerated values + priority + CART_INIT definition in `LOT1_BASE_END_REASON` |
| 5 | 5 | `lot1baseendapr18.pdf` | Add flag-only framing sentence to `contains_mtx_reg` |
| 6 | 6 | `mtx scenarios.pdf` | Add REFERENCE ONLY banner |
| 7 | 7 | `lot1baseendapr18.pdf` | Add worked-example table to `contains_mtx_reg` |
| 8 | 8 | `lot1baseendapr18.pdf` | Exclude steroids as anchors in `contains_mtx_reg` |

**Steps 1–5 are required.** Steps 6–8 are recommended clarifications. After Step 5, the spec is substantively aligned with the Apr 15 2026 meeting.

---

## What this file does NOT cover

- **Protocol edits** — out of scope per instruction.
- **LOT 2–5 spec** — future deliverable; Julia owes this next week.
- **Code edits** — out of scope; this file only fixes the spec text.
- **Rerun / output validation** — tracked separately in `issues_to_fix.md`.

---

*End of edit instructions.*
