# Apr 18 2026 Spec Update Instructions — Consolidated & Validated

**Purpose:** Single action-ready document for updating the Apr 18 LOT1 spec so it matches the Apr 15 2026 meeting decisions on maintenance. This consolidates three prior reviews (A = my line-by-line; B = second independent review; C = third agent review) and keeps only what was validated against the source materials.

**What the third reviewer caught (and this consolidation corrects):**
- `CART_INIT` end-date convention was **not** settled in the meeting — the transcript only discusses the end *reason*, not the end *date*. The code currently uses `FIRST_CART_DT` (not `FIRST_CART_DT - 1`). Earlier drafts over-prescribed here. Now treated as an open decision.
- `SCT_NO_MAINT` sub-case mapping was **not** fully settled — Julia said "I'm not sure what that means for us here." Full mapping table was inference. Now treated as an open decision with a safe-minimum edit.

---

## Validation basis

Cross-checked against:
1. Meeting minutes — `Apr 18 2026/meeting minutes apt 15`
2. LOT1 end spec — `Apr 18 2026/Program Spec and Scenarios/lot1baseendapr18.pdf` (extracted text verified)
3. Rollup — `Apr 18 2026/Program Spec and Scenarios/clmmarolluoapr18.pdf`
4. Mtx scenarios — `Apr 18 2026/Program Spec and Scenarios/mtx scenarios.pdf`
5. Current code — `Apr 18 2026/Program/lot_program.R`

**Key validated facts (drive the edits below):**

| Fact | Confirmed by |
|---|---|
| Restated "(Rule 4) SCTs not followed by maintenance within 180days" is in the clean rules cell | Direct extract from `lot1baseendapr18.pdf` p.1 |
| Restated "(Rule 8) End of maintenance regimen." is in the clean rules cell | Direct extract, same cell |
| `contains_mtx_reg` row uses operational wording ("Definition of a maintenance period: The LOT's initial regimen transitions…") | Direct extract from `lot1baseendapr18.pdf` p.3 |
| `mtx scenarios.pdf` p.1 opens with "Definition of a maintenance period…" and shows "mtx period" timelines | Direct extract |
| DARA/LENA dual + THAL mono already in the rollup | Direct extract from `clmmarolluoapr18.pdf` |
| CAR-T 45-day consolidation row already present | Direct extract from `lot1baseendapr18.pdf` p.2 |
| Code sets `LOT1_BASE_END_DT = FIRST_CART_DT` when `CART_INIT_FLG = 1` | `lot_program.R:1940-1942` |
| Meeting discusses CART_INIT end *reason* only, not end *date* | Meeting transcript |
| Meeting on SCT_NO_MAINT: Julia says "I'm not sure what that means for us here" | Meeting transcript |

---

## Core interpretation the spec should reflect (per Apr 15 meeting, LOT1)

> The study does not derive a separate standalone maintenance period or maintenance regimen. It records whether LOT1 contains a valid maintenance-approved subset using `contains_mtx_reg`. The flag still requires identifying a valid subset with an anchor agent — but that is **for flagging presence only**, not for creating one official maintenance interval. Therefore the old maintenance-based LOT-ending rules (Rule 4, Rule 8) no longer apply.

Strongest meeting transcript support:
- *"we're adding a flag, but we're not going to define it for this study"*
- *"we're not trying to define the time and length of maintenance because it's quite messy"*
- *"we're just trying to see if there's a valid … maintenance regimen contained within the lot one induction regimen"*
- On old maintenance-end cases: *"if those people are not having another medication added … we would just say that they're discontinued"*

---

## Section 1 — What is already fine

No edit required for these items (all three reviews agree):

| Item | Evidence |
|---|---|
| `contains_mtx_reg` row exists | `lot1baseendapr18.pdf` p.3 |
| CAR-T 45-day consolidation row exists | `lot1baseendapr18.pdf` p.2 |
| DARA/LENA dual maintenance in rollup | `clmmarolluoapr18.pdf` |
| THAL mono maintenance in rollup | `clmmarolluoapr18.pdf` |
| ALLO-always-ends-LOT row exists | `lot1baseendapr18.pdf` p.2 |
| 30-day induction window parameter for LOT 2-5 | `lot1baseendapr18.pdf` p.2 (as parameter only — full LOT 2-5 spec still owed) |

---

## Section 2 — Confirmed edits (paste-ready)

These five edits are supported directly by the meeting minutes and can be made now.

### Edit 1. Remove the old maintenance-based end-reason rules

**File:** `lot1baseendapr18.pdf`
**Tab:** `10. LOT1_BASE_END`
**Cell:** Page 1, main rules narrative cell (contains Rules 2–8 twice — struck-through version at the top, clean restated version below).

**Remove these exact phrases from the clean restated list:**

| FIND (verbatim) | ACTION |
|---|---|
| `(Rule 4) SCTs not followed by maintenance within 180days;` | Delete entire clause |
| `(Rule 8) End of maintenance regimen.` | Delete entire clause |

**Also clean out the struck-through / OCR-garbled versions in the opening paragraph** (so the cell no longer contains two conflicting lists):

- `(3) SGTs Het fella~. eel e·, rneif'lteAef'lee .. 1tll1F1 1 Be cleys u,e lest Eley er the LOT ts tile Elate el tile SGT.` → delete
- `(8) er ff!eIr,teF1eF1ee FBgiffleA.` → delete

**Do NOT renumber** remaining Rules 2/3/5/6/7 — leave their numbers intact so downstream references don't break.

**Optional paste-ready summary sentence** (if you want a replacement summary line in the rules cell after cleanup):

> "The LOT ends for one of the following reasons: discontinuation of all agents, new qualifying medication addition, SCT or CAR-T event, death, health plan disenrollment, or end of study period. Maintenance is not treated as a separate LOT-ending construct in this study."

---

### Edit 2. Update `LOT1_BASE_END_REASON` row — enumerate values + remove MAINTENANCE_END

**File:** `lot1baseendapr18.pdf`
**Tab:** `10. LOT1_BASE_END`
**Row:** `LOT1_BASE_END_REASON` (Final LOT1 base period end reason)

**Paste-ready replacement for the Values / Definition cell:**

> **Allowed `LOT1_BASE_END_REASON` values:** `DISCONTINUATION`, `MED_ADD`, `SCT_AUTO`, `SCT_ALLO`, `SCT_CART`, `CART_INIT`, `DEATH`, `DISENROLLMENT`, `STUDY_END`.
>
> The study does **not** use `MAINTENANCE_END` as a final LOT1 end-reason value. Patients who would previously have ended LOT1 via end of maintenance regimen now map to `DISCONTINUATION` unless a higher-priority event applies first (any `SCT_*`, `CART_INIT`, `MED_ADD`, `DEATH`, `DISENROLLMENT`, or `STUDY_END`).
>
> **Priority order (earliest-matching rule wins):**
> `SCT_ALLO` / `SCT_CART` / `SCT_AUTO (Rule 3)` > `CART_INIT` > `MED_ADD` > `DISCONTINUATION` > `DEATH` > `DISENROLLMENT` > `STUDY_END`

**Why confirmed by the meeting:** Julia explicitly said the old maintenance-end patients should be treated as discontinued if no new medication is added.

---

### Edit 3. Reframe `contains_mtx_reg` as flag-only

**File:** `lot1baseendapr18.pdf`
**Tab:** `10. LOT1_BASE_END`
**Row:** `contains_mtx_reg` (last row of the variable table on page 3)

**Keep:** the mono-maintenance list, the dual-maintenance list, the anchor concept.

**Replace / rewrite the Definition cell with paste-ready text:**

> `contains_mtx_reg` is a flag-only variable. It does not create a maintenance start date, maintenance end date, or LOT-ending event. Set `contains_mtx_reg = 1` when the LOT1 induction regimen contains at least one valid mono-maintenance agent **or** valid dual-maintenance combination, AND at least one additional non-steroid MM oncology agent outside that qualifying maintenance subset is present as an anchor.
>
> - **Valid mono-maintenance agents:** lenalidomide, bortezomib, daratumumab, ixazomib, thalidomide.
> - **Valid dual-maintenance combinations:** bortezomib/lenalidomide, carfilzomib/lenalidomide, daratumumab/lenalidomide.
>
> The anchor concept is used only to support this flag. It is not used to derive a separate maintenance period or a maintenance-based LOT end.

**Why confirmed by the meeting:** direct match to "we're adding a flag, but we're not going to define it for this study" and "we're just trying to see if there's a valid maintenance regimen contained within the lot one induction regimen."

---

### Edit 4. Label the existing operational paragraph as background

**File:** `lot1baseendapr18.pdf`
**Tab:** `10. LOT1_BASE_END`
**Row:** `contains_mtx_reg`

The existing paragraph in the cell currently reads (verbatim from extract):

> "Definition of a maintenance period: The LOT's initial regimen transitions into a maintenance regimen, such that non-maintenance medications present during the initial regimen are discontinued leaving only maintenance medications for xx days. … It is thus imperative to include another agent, other than the drug(s) that transitions into a mtx regimen, to anchor the start of that mtx regimen."

**Action:** Keep this paragraph AFTER the Edit 3 text, but prepend a clear label so readers know it is background, not a derivation rule:

**INSERT** (as a lead-in line before the existing paragraph):
> _Background clarification (for interpreting the flag only — not an operational derivation):_

---

### Edit 5. Relabel `mtx scenarios.pdf` as reference / background only

**File:** `mtx scenarios.pdf`
**Location:** Top of page 1, above existing content.

**Paste-ready banner:**

> **REFERENCE ONLY — updated per Apr 15 2026 meeting.**
>
> These maintenance scenarios are retained as background examples and do **not** define an operational maintenance period for this study. The current study uses `contains_mtx_reg` as a descriptive flag only and does not use maintenance to create a LOT-ending event. For the active definition, see the `contains_mtx_reg` row in `lot1baseendapr18.pdf`.

**Alternative (if a banner is impractical):** rename the file to `mtx scenarios_REFERENCE_ONLY.pdf` or move it into an `archive/` sub-folder.

**Why confirmed by the meeting:** The file currently reads as an operational derivation ("Definition of a maintenance period: The LOT's initial regimen transitions …"). The meeting explicitly moved maintenance out of active study logic.

---

## Section 3 — Open decisions (need Julia's input before finalising text)

These are real issues, but the meeting did not lock down the exact wording. Safe-minimum edits provided so the spec can still be internally consistent even without a final decision.

### Decision A. Exact handling of former `SCT_NO_MAINT` cases

**Where the old concept still appears:**
- Rules cell on page 1 (already scheduled for removal in Edit 1 — struck through as Rule 4)
- `LOT1_BASE_END_REASON` row (addressed in Edit 2 via MAINTENANCE_END remap, but `SCT_NO_MAINT` sub-case mapping is separate)

**What the meeting supports:** The old maintenance-dependent `SCT_NO_MAINT` bucket should not remain. Julia said these patients are "either having a new agent probably introduced or they're having a 3rd or unplanned atologous happening."

**What is NOT fully settled:**
- Whether all former `SCT_NO_MAINT` patients should be relabelled `SCT_AUTO`, OR
- Whether they should be routed by the actual earliest downstream event (`DISCONTINUATION` / `MED_ADD` / `CART_INIT` / `SCT_AUTO` / `SCT_ALLO`).

**Current code behaviour (for context):** `lot_program.R:1906-1910` sets `LOT1_BASE_END_REASON = 'SCT_AUTO'` whenever `LOT1_SCT_NO_MAINT_FLG = 1`, subject to higher-priority events (unplanned SCT, MED_ADD before the SCT date, DISCON before the SCT date).

**Safe-minimum spec edit (use if the final mapping is not yet agreed):**

> "Planned single or tandem autologous SCT without maintenance does not create a separate maintenance-based end-reason category in this study. These cases must be classified under the final non-maintenance LOT-ending rules."

**Full mapping (use only if Julia confirms):**

> | Sub-case | New `LOT1_BASE_END_REASON` |
> |---|---|
> | Planned single/tandem AUTO followed only by run-out / gap | `DISCONTINUATION` |
> | Planned single/tandem AUTO followed by a new non-induction agent (≥ 46 d before any CAR-T) | `MED_ADD` |
> | Planned single/tandem AUTO, then a new agent, then CAR-T within 45 d | `CART_INIT` |
> | 3rd AUTO / unplanned AUTO / ALLO after the planned AUTO | `SCT_AUTO` (Rule 3) or `SCT_ALLO` |
> | Death / disenrollment / study-end intervenes first | `DEATH` / `DISENROLLMENT` / `STUDY_END` |

**Question to ask Julia:** "For the former `SCT_NO_MAINT` cohort, do you want to (a) relabel all of them as `SCT_AUTO`, or (b) route them by the actual earliest downstream event per the table above?"

---

### Decision B. Exact `LOT1_BASE_END_DT` convention for `CART_INIT`

**What the meeting supports:** If a new medication is added and CAR-T starts within 45 days, `LOT1_BASE_END_REASON = CART_INIT` (not `MED_ADD`).

**What is NOT in the meeting:** The exact LOT1 end-date convention in this case.

**Current code behaviour:** `lot_program.R:1940-1942` sets `LOT1_BASE_END_DT = FIRST_CART_DT` (the CAR-T infusion date itself).

**Spec tension:** The `LOT1_TX_ENDDATE_REASON` row describes the general CAR-T rule as *"the preceding LOT ending the day before the CAR-T infusion date"*. If `CART_INIT` follows this general rule, the end date would be `FIRST_CART_DT - 1`, not `FIRST_CART_DT`. The code currently does NOT match this.

**Safe-minimum spec edit:**

> "If a new MM oncology agent is introduced and CAR-T begins within 45 days, `LOT1_BASE_END_REASON = CART_INIT` rather than `MED_ADD`. `LOT1_BASE_END_DT` follows the study's chosen CAR-T transition convention and must be applied consistently in both the spec and the program."

**Question to ask Julia:** "For `CART_INIT`, should `LOT1_BASE_END_DT` = `FIRST_CART_DT` (CAR-T infusion date, matches current code) or `FIRST_CART_DT - 1` (day before, matches the general CAR-T-as-new-LOT convention stated elsewhere in the spec)?"

**Once decided:** update both the spec row AND `lot_program.R:1940-1942` to match.

---

## Section 4 — Recommended clarifications (nice-to-have, not meeting-driven)

### Recommendation 1. Add one short example note to `contains_mtx_reg`

**Purpose:** Resolve the BORT + DARA + LENA ambiguity Julia specifically called out in the meeting ("a complicated situation").

**Paste-ready text (append to the `contains_mtx_reg` Definition cell after Edit 3):**

> **Examples:**
> - `BORT + LENA` alone → flag = 0 (no additional anchor outside the qualifying subset).
> - `BORT + LENA + CYCL` → flag = 1 (CYCL anchors the BORT+LENA subset).
> - `BORT + DARA + LENA` → flag = 1 (any valid mono or dual subset always has ≥ 1 other induction drug to anchor).
> - `DARA` alone → flag = 0 (no anchor).

---

### Recommendation 2. Explicitly exclude steroids as anchors

**Purpose:** Dexamethasone is routinely co-administered with BORT/LENA; if DEXA could anchor, the flag becomes meaningless. The code already excludes steroids (`lot_program.R:1475`) but the spec does not say so.

**Note:** This is a clarification inferred from protocol steroid handling — it was not directly discussed in the Apr 15 meeting. Confirm with Julia before writing the final wording.

**Paste-ready text (append to the `contains_mtx_reg` Definition cell):**

> "Corticosteroids (e.g., dexamethasone, prednisone; any drug with `CL_MED_CLASS = 'STEROID'` in `CL_MMA_ROLLUP`) do NOT qualify as an anchor agent. Only non-steroid MM oncology agents count."

---

## Section 5 — Recommended order of operations

1. **Edit 1** — delete Rules 4 and 8 from both the struck-through opening paragraph and the clean restated list. Do not renumber.
2. **Edit 2** — update `LOT1_BASE_END_REASON` row: enumerate allowed values, add MAINTENANCE_END remap note, add priority order.
3. **Edit 3** — rewrite `contains_mtx_reg` Definition as flag-only.
4. **Edit 4** — label the existing operational paragraph as background.
5. **Edit 5** — add REFERENCE-ONLY banner to `mtx scenarios.pdf`.
6. **Pause — ask Julia Decision A and Decision B.**
7. After Julia's decisions, apply the chosen text for `SCT_NO_MAINT` sub-case mapping and `CART_INIT` end-date convention.
8. (Optional) Recommendations 1 and 2 for `contains_mtx_reg` clarifications.

After Steps 1–5 the spec is substantively aligned with the Apr 15 meeting. Decisions A and B are needed before the spec is fully internally consistent with the code.

---

## Explicitly out of scope for this document

- **Protocol edits** — per user instruction.
- **LOT 2–5 spec** — Julia is producing that separately next week. Any maintenance wording for LOT 2–5 was NOT discussed in the Apr 15 meeting; do not infer.
- **Code edits** — see `issues_to_fix.md`. Note that once Decisions A and B are made, corresponding code changes may be required (especially Decision B if Julia chooses `FIRST_CART_DT - 1`).
- **Rerun / output validation** — see `issues_to_fix.md`.

---

## Bottom line

The maintenance update is **not** "remove maintenance." It is: "do not operationalise maintenance as a separate standalone LOT construct." The spec should therefore:

1. **Keep** `contains_mtx_reg` (already present).
2. **Remove** maintenance as a final end-reason bucket (Edits 1 and 2).
3. **Stop describing** maintenance as its own active derived period inside the LOT1 spec (Edits 3 and 4).
4. **Reframe** `mtx scenarios.pdf` as reference material rather than active derivation logic (Edit 5).
5. **Resolve** two open decisions (A on `SCT_NO_MAINT` mapping; B on `CART_INIT` end-date convention) before the remaining cells can be finalised.

*End of consolidated edit instructions.*
