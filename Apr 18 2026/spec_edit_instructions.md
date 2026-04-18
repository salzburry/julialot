# Spec Edit Instructions — Validated, Step-by-Step

**Review date:** 2026-04-18
**Review basis:** Cross-validated against extracted text of the Apr 18 spec PDFs.
**Target:** Apply the edits below to align the spec with the Apr 15 2026 meeting decisions.

**Key framing that drives every edit (per Apr 15 meeting, LOT1):**
> The study does not derive a separate standalone maintenance period or maintenance regimen. It records whether LOT1 contains a valid maintenance-approved subset using `contains_mtx_reg`. The flag still requires identifying a valid subset with an anchor agent — but that is **for flagging presence only**, not for creating one official maintenance interval. Therefore Rules 4 and 8 (which ended a LOT based on a separate maintenance phase) no longer apply.

---

## What was validated against the actual spec text

| Claim | Validated against | Outcome |
|---|---|---|
| Restated Rule 4 text present in rules cell | `lot1baseendapr18.pdf` p.1, rules cell lines 291–320 of extract | ✅ "(Rule 4) SCTs not followed by maintenance within 180days" — confirmed verbatim |
| Restated Rule 8 text present in rules cell | Same cell, lines 361–365 of extract | ✅ "(Rule 8) End of maintenance regimen." — confirmed verbatim |
| Struck-through Rule 4/8 in opening paragraph | Same cell, lines 220–260 of extract | ✅ OCR-garbled but clearly struck-through |
| `contains_mtx_reg` uses operational wording | `lot1baseendapr18.pdf` p.3 | ✅ "Definition of a maintenance period: The LOT's initial regimen transitions into a maintenance regimen …" |
| `CART_45D_CONSOLIDATION` row present | `lot1baseendapr18.pdf` p.2 | ✅ "within 45 days of the CAR-T infusion are consolidated" |
| CAR-T precedence over MED_ADD described in LOTn_TX_ENDDATE_REASON row | `lot1baseendapr18.pdf` p.2 | ✅ "if a new oncology agent is introduced within 45 days of the CAR-T infusion, that agent is incorporated into the CAR-T LOT rather than initiating a new line of therapy" |
| DARA/LENA dual in rollup | `clmmarolluoapr18.pdf` p.1 | ✅ DARA row: DUAL_MAINTENANCE_WITH=LENA; LENA row: BORT, CARF, DARA |
| `mtx scenarios.pdf` frames maintenance operationally | `mtx scenarios.pdf` p.1 | ✅ "Definition of a maintenance period…" + Example 1/1b/2/2b/3/3b show "mtx period starts…" |

---

## How to use this file

- **Required** sections (1–5) MUST be applied. After applying, the spec is substantively aligned with the meeting.
- **Recommended** sections (6–8) are clarifications that reduce ambiguity for QC/readers.
- **Not included**: Anything concerning LOT 2–5 — Julia owes that spec next week. Do not attempt to infer those edits yet.

Each edit gives: (a) target file + tab + cell/row; (b) **FIND** = exact current text to locate; (c) **REPLACE WITH** or **INSERT** = exact text to apply.

---

# Required Edits (1–5)

## Edit 1 — Remove restated Rules 4 and 8 from the main rules cell

**Target file:** `lot1baseendapr18.pdf`
**Tab:** `10. LOT1_BASE_END`
**Cell:** Page 1, the long narrative cell that holds the rules list (same cell appears twice in the workbook — once with Rule 4/8 struck through near the top, once with Rule 4/8 clean further down).

### 1a. Clean paragraph — delete Rule 4

**FIND** (verbatim, including punctuation):
```
(Rule 4) SCTs not followed by maintenance within 180days;
```
*(note: the separator after "180days" in the extracted text shows as `:` due to OCR — it is `;` in the source)*

**REPLACE WITH:** (delete the whole clause including trailing semicolon; close the gap)

### 1b. Clean paragraph — delete Rule 8

**FIND** (verbatim):
```
(Rule 8) End of maintenance regimen.
```

**REPLACE WITH:** (delete the whole clause including trailing period)

### 1c. Struck-through opening paragraph — clean it out

**FIND** (OCR-garbled but recognisable; delete the whole struck-through clause):
```
(3) SGTs Het fella~. eel e·, rneif'lteAef'lee .. 1tll1F1 1 Be cleys u,e lest Eley er the LOT ts tile Elate el tile SGT.
```
and
```
(8) er ff!eIr,teF1eF1ee FBgiffleA.
```

**REPLACE WITH:** (delete — do not keep strike-through styling; remove entirely)

### 1d. Leave these rules in both paragraphs unchanged

| Rule | Keep | Text |
|---|---|---|
| Rule 2 | ✓ | Discontinuation of all agents |
| Rule 3 | ✓ | Unplanned SCTs (unchanged) |
| Rule 5 | ✓ | Death |
| Rule 6 | ✓ | Health plan disenrollment |
| Rule 7 | ✓ | End of the study period |

**Do NOT renumber** — keeping the original Rule 5/6/7 numbers avoids breaking downstream references.

---

## Edit 2 — Remapping note for former `MAINTENANCE_END` patients

**Target file:** `lot1baseendapr18.pdf`
**Tab:** `10. LOT1_BASE_END`
**Row:** `LOT1_BASE_END_REASON` (Final LOT1 base period end reason)
**Column:** Additional Notes (or Definition — append at end)

### 2a. Add this paragraph

**INSERT:**
> **Note (per Apr 15 2026 decision):** The study does not derive a separate standalone maintenance period or maintenance regimen. Patients whose LOT1 would previously have ended via Rule 8 (end of maintenance regimen) now map to `DISCONTINUATION` unless a higher-priority event applies first (any `SCT_*`, `CART_INIT`, `MED_ADD`, `DEATH`, `DISENROLLMENT`, or `STUDY_END`). There is no dedicated `MAINTENANCE_END` end-reason value in this study.

---

## Edit 3 — Remapping for former `SCT_NO_MAINT` cases

**Target file:** `lot1baseendapr18.pdf`
**Tab:** `10. LOT1_BASE_END`
**Row:** `LOT1_BASE_END_REASON`
**Column:** Additional Notes (place directly after Edit 2 paragraph)

### 3a. Add mapping table

**INSERT:**
> **Remapping for former `SCT_NO_MAINT` cases (per Apr 15 2026 decision):** Single/tandem autologous SCTs are a continuation of the line (Rule 3) and do NOT by themselves end LOT1. Patients who would previously have been bucketed as `SCT_NO_MAINT` now take the first applicable end reason below:
>
> | Sub-case | New `LOT1_BASE_END_REASON` |
> |---|---|
> | Planned single/tandem AUTO followed only by run-out / gap | `DISCONTINUATION` |
> | Planned single/tandem AUTO followed by a new non-induction agent (≥ 46 d before any CAR-T) | `MED_ADD` |
> | Planned single/tandem AUTO, then a new agent, then CAR-T within 45 d | `CART_INIT` |
> | 3rd AUTO / unplanned AUTO / ALLO after the planned AUTO | `SCT_AUTO` (Rule 3) or `SCT_ALLO` |
> | Death / disenrollment / study-end intervenes first | `DEATH` / `DISENROLLMENT` / `STUDY_END` |
>
> Single/tandem AUTO by itself is never an LOT1-ending event in this study.

### 3b. Minimum-viable alternative (if the table is too large for the cell)

**INSERT** (one-sentence version):
> "Single/tandem AUTO SCTs do not create a separate maintenance-dependent LOT-ending category. LOT1 continues until Rule 2 (`DISCONTINUATION`), an unplanned/excess SCT (Rule 3), `CART_INIT`, or a censoring event."

---

## Edit 4 — Add `CART_INIT` as an explicit `LOT1_BASE_END_REASON` value

**Target file:** `lot1baseendapr18.pdf`
**Tab:** `10. LOT1_BASE_END`
**Row:** `LOT1_BASE_END_REASON`

### 4a. Values column — add enumerated allowed values

**INSERT** (Values column):
> **Allowed values:** `DISCONTINUATION`, `MED_ADD`, `SCT_AUTO`, `SCT_ALLO`, `SCT_CART`, `CART_INIT`, `DEATH`, `DISENROLLMENT`, `STUDY_END`.

### 4b. Definition column — add priority order (first line of the Definition cell)

**INSERT** (top of Definition, before existing text):
> **Priority order (earliest-matching rule wins):**
> `SCT_ALLO` / `SCT_CART` / `SCT_AUTO (Rule 3)` > `CART_INIT` > `MED_ADD` > `DISCONTINUATION` > `DEATH` > `DISENROLLMENT` > `STUDY_END`

### 4c. Add CART_INIT definition sub-row

**INSERT** (as a new bullet or sub-row under `LOT1_BASE_END_REASON`):
> **`CART_INIT`** — Applied when the patient has a non-induction agent added AND a CAR-T infusion within 45 days of that agent. Specifically:
>
> - **Trigger:** `LOT1_BASE_1ST_ADD_MED_DT` is not missing AND `FIRST_CART_DT - (LOT1_BASE_1ST_ADD_MED_DT + 1)` is between 0 and 45 days inclusive.
> - **End reason:** `LOT1_BASE_END_REASON = 'CART_INIT'` (NOT `'MED_ADD'`).
> - **End date:** `LOT1_BASE_END_DT = FIRST_CART_DT - 1` (day before the CAR-T infusion; CAR-T itself starts the CAR-T LOT).
>
> Rationale: Per the Apr 15 meeting, CAR-T cellular therapy is its own LOT. Oncology agents administered within 45 days before CAR-T are consolidated into the CAR-T LOT rather than initiating a separate MED_ADD line.

---

## Edit 5 — Reframe `contains_mtx_reg` as flag-only

**Target file:** `lot1baseendapr18.pdf`
**Tab:** `10. LOT1_BASE_END`
**Row:** `contains_mtx_reg` (last row of the variable table on page 3)

### 5a. Definition column — insert new first sentence

**INSERT** (very top of the Definition cell, before any existing wording):
> **The study does not derive a separate standalone maintenance period or maintenance regimen. This flag records whether LOT1 contains a valid maintenance-approved subset (mono or dual, from the approved list) together with at least one additional non-steroid induction drug acting as an anchor. Identifying a valid subset + anchor is required for flagging presence only — it does NOT create a maintenance start date, maintenance end date, or LOT-ending event.**

### 5b. Label the existing paragraph as background

The existing cell currently reads (validated from extract):
> "Definition of a maintenance period: The LOT's initial regimen transitions into a maintenance regimen, such that non-maintenance medications present during the initial regimen are discontinued leaving only maintenance medications for xx days. … It is thus imperative to include another agent, other than the drug(s) that transitions into a mtx regimen, to anchor the start of that mtx regimen."

**PREPEND this label to that existing paragraph:**
> _Background clarification (for interpreting the flag only — not an operational derivation):_

Keep the existing paragraph itself in place; just add the label so readers know it is background, not algorithm.

---

# Recommended Edits (6–8)

## Edit 6 — Label `mtx scenarios.pdf` as reference-only

**Target file:** `mtx scenarios.pdf`
**Location:** Top of page 1, above existing content.

### 6a. Add a banner

**INSERT:**
> **REFERENCE / BACKGROUND ONLY — updated per Apr 15 2026 meeting.**
>
> These scenarios are retained as background for interpreting the `contains_mtx_reg` flag only. The study does NOT derive a maintenance period or use these scenarios as operational LOT-ending logic. For the active definition used in this study, see the `contains_mtx_reg` row in `lot1baseendapr18.pdf`.

### 6b. Alternative (if a banner is impractical)

Rename the file to `mtx scenarios_REFERENCE_ONLY.pdf` or move it into an `archive/` sub-folder inside `Program Spec and Scenarios/`.

---

## Edit 7 — Add worked-example table to `contains_mtx_reg`

**Target file:** `lot1baseendapr18.pdf`
**Tab:** `10. LOT1_BASE_END`
**Row:** `contains_mtx_reg`
**Column:** Additional Notes (below the Edit 5 edits)

### 7a. Insert worked-example table

**INSERT:**
> **Worked examples (non-steroid induction drugs only):**
>
> | Induction regimen | Qualifying maintenance subset(s) | Anchor candidate(s) | `contains_mtx_reg` |
> |---|---|---|---|
> | BORT + LENA | BORT+LENA (dual), BORT (mono), LENA (mono) | none outside any subset | 0 |
> | BORT + LENA + CYCL | BORT+LENA (dual), BORT, LENA monos | CYCL | 1 |
> | BORT + LENA + DEXA | BORT+LENA (dual), BORT, LENA monos | none (DEXA is steroid — does not anchor) | 0 |
> | BORT + DARA + LENA | {BORT+LENA}, {DARA+LENA}, {BORT}, {LENA}, {DARA} | always ≥ 1 other drug | 1 |
> | DARA | DARA (mono) | none | 0 |
> | CYCL | none (CYCL not on mtx list) | — | 0 |
>
> **Rule:** Flag = 1 if ANY valid mono or dual maintenance subset is present in the induction regimen AND at least one other non-steroid induction drug is available to act as the anchor.

---

## Edit 8 — Explicitly exclude steroids as anchors

**Target file:** `lot1baseendapr18.pdf`
**Tab:** `10. LOT1_BASE_END`
**Row:** `contains_mtx_reg`
**Column:** Definition (append at end of the Definition cell)

### 8a. Add one sentence

**INSERT:**
> Corticosteroids (e.g., dexamethasone, prednisone; any drug with `CL_MED_CLASS = 'STEROID'` in `CL_MMA_ROLLUP`) do NOT qualify as an anchor agent. Only non-steroid MM oncology agents count.

---

# Summary order of operations

| Order | Edit | File | Cell / row |
|---:|---|---|---|
| 1 | Delete restated Rules 4 & 8 + clean out strike-through versions | `lot1baseendapr18.pdf` | Main rules cell, p.1 |
| 2 | Add MAINTENANCE_END remap note | `lot1baseendapr18.pdf` | `LOT1_BASE_END_REASON` row |
| 3 | Add SCT_NO_MAINT remap table | `lot1baseendapr18.pdf` | `LOT1_BASE_END_REASON` row |
| 4 | Enumerate end-reason values + priority + CART_INIT definition | `lot1baseendapr18.pdf` | `LOT1_BASE_END_REASON` row |
| 5 | Flag-only framing for contains_mtx_reg | `lot1baseendapr18.pdf` | `contains_mtx_reg` row, p.3 |
| 6 | REFERENCE-ONLY banner | `mtx scenarios.pdf` | Top of p.1 |
| 7 | Worked-example table | `lot1baseendapr18.pdf` | `contains_mtx_reg` row |
| 8 | Steroid-not-anchor sentence | `lot1baseendapr18.pdf` | `contains_mtx_reg` row |

Edits 1–5 are required. After those, the spec is substantively aligned with the Apr 15 meeting. 6–8 are clarifications.

---

# Explicitly out of scope

- **Protocol edits** — per user instruction.
- **LOT 2–5 spec** — Julia to produce; do not infer.
- **Code edits** — out of scope here; see `issues_to_fix.md`.
- **Rerun / output validation** — see `issues_to_fix.md`.

---

*End of validated edit instructions.*
