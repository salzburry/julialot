# Apr 18 2026 Spec Update Instructions — Final Revised & Validated

**Purpose:** Single action-ready document for updating the Apr 18 LOT1 spec so it matches the Apr 15 2026 meeting decisions on maintenance. This version folds in the final validation pass and adds the items that were still missing from the prior consolidated draft.

## What this revision adds (compared with the prior consolidated draft)

1. A required cleanup to the `LOT1_BASE_END_DT` row in `lot1baseendapr18` — because that row still says "Rules 2-8 are ending events", which implicitly preserves the old maintenance-based rules.
2. A required cross-tab cleanup in `lot1baseapr18` — because that tab still says the LOT1 Base period continues until "maintenance begins".
3. Explicit wording that `SCT_NO_MAINT` should not remain as a final end-reason value, even though its exact remapping still needs Julia's decision.
4. A quick follow-on cleanup on `LOT1_BASE_LENGTH` — same "Rules 1-8" residue.
5. More precise instructions on which spec rows must be aligned once the `CART_INIT` end-date convention is decided.

---

## Validation basis

Cross-checked against:
1. `Apr 18 2026/meeting minutes apt 15`
2. `Apr 18 2026/Program Spec and Scenarios/lot1baseendapr18.pdf` (extracted text verified)
3. `Apr 18 2026/Program Spec and Scenarios/lot1baseapr18.pdf` (extracted text verified)
4. `Apr 18 2026/Program Spec and Scenarios/clmmarolluoapr18.pdf`
5. `Apr 18 2026/Program Spec and Scenarios/mtx scenarios.pdf`
6. `Apr 18 2026/Program Spec and Scenarios/dataprepapr18.pdf`
7. `Apr 18 2026/Program/lot_program.R`

## Key validated facts

| Fact | Confirmed by |
|---|---|
| Restated `(Rule 4) SCTs not followed by maintenance within 180days` still in the clean rules cell | `lot1baseendapr18.pdf` p.1 extract |
| Restated `(Rule 8) End of maintenance regimen.` still in the clean rules cell | same |
| Rules cell text `(Rules 2-8 are ending events; Rule 1 ...)` still implicitly keeps Rules 4 & 8 alive | `lot1baseendapr18.pdf` p.1 extract, lines 640-644 of extract |
| `LOT1_BASE_LENGTH` row says `(earliest of Rules 1-8 in the protocol)` | `lot1baseendapr18.pdf` p.2 extract |
| `contains_mtx_reg` still contains operational wording beginning `Definition of a maintenance period...` | `lot1baseendapr18.pdf` p.3 extract |
| `mtx scenarios.pdf` still opens with `Definition of a maintenance period...` and shows `mtx period` timelines | direct extract |
| `lot1baseapr18` says LOT1 Base continues until `all induction regimen medications discontinue, censoring, HSCT, or maintenance begins` | `lot1baseapr18.pdf` extract |
| `dataprepapr18` already reflects the newer flag-only framing | `dataprepapr18.pdf` extract |
| DARA/LENA dual and THAL mono already in the rollup | `clmmarolluoapr18.pdf` extract |
| CAR-T 45-day consolidation row already present | `lot1baseendapr18.pdf` p.2 extract |
| Code sets `LOT1_BASE_END_DT = FIRST_CART_DT` when `CART_INIT_FLG = 1` | `lot_program.R:1940-1942` |
| Meeting discusses `CART_INIT` end reason but does not settle the end date | meeting transcript |
| Meeting says old maintenance-end cases should now be treated as discontinued if no new medication is added | meeting transcript |
| Meeting on `SCT_NO_MAINT`: needs recategorization but exact sub-case mapping not fully settled | meeting transcript |

---

## Core interpretation the spec should reflect

> The study does not derive a separate standalone maintenance period or maintenance regimen. It records whether LOT1 contains a valid maintenance-approved subset using `contains_mtx_reg`. The flag still requires identifying a valid subset with an anchor agent — but that is **for flagging presence only**, not for creating one official maintenance interval. Therefore the old maintenance-based LOT-ending rules no longer apply.

Strongest meeting transcript support:
- *"we're adding a flag, but we're not going to define it for this study"*
- *"we're not trying to define the time and length of maintenance because it's quite messy"*
- *"we're just trying to see if there's a valid … maintenance regimen contained within the lot one induction regimen"*
- *"if those people are not having another medication added … we would just say that they're discontinued"*

---

## Section 1 — What is already fine

No maintenance-driven edit required:

| Item | Evidence |
|---|---|
| `contains_mtx_reg` row exists | `lot1baseendapr18.pdf` p.3 |
| CAR-T 45-day consolidation row exists | `lot1baseendapr18.pdf` p.2 |
| DARA/LENA dual maintenance in rollup | `clmmarolluoapr18.pdf` |
| THAL mono maintenance in rollup | `clmmarolluoapr18.pdf` |
| ALLO-always-ends-LOT row exists | `lot1baseendapr18.pdf` p.2 |
| 30-day induction window parameter for LOT 2-5 present | `lot1baseendapr18.pdf` p.2 |
| `dataprepapr18` already uses flag-only maintenance framing | `dataprepapr18.pdf` |

---

## Section 2 — Confirmed edits you can make now

These edits are supported directly by the meeting minutes and the current Apr 18 spec text.

### Edit 1. Remove the old maintenance-based end-reason rules from the page 1 rules narrative

**File:** `lot1baseendapr18.pdf`
**Tab:** `10. LOT1_BASE_END`
**Cell:** page 1 main rules narrative cell (contains Rules 2–8 twice — struck-through at top, clean below).

**Delete these exact phrases from the clean restated list:**

| FIND (verbatim) | ACTION |
|---|---|
| `(Rule 4) SCTs not followed by maintenance within 180days;` | Delete entire clause |
| `(Rule 8) End of maintenance regimen.` | Delete entire clause |

**Also delete the struck-through / OCR-garbled versions in the opening paragraph:**
- `(3) SGTs Het fella~. eel e·, rneif'lteAef'lee .. 1tll1F1 1 Be cleys u,e lest Eley er the LOT ts tile Elate el tile SGT.` → delete
- `(8) er ff!eIr,teF1eF1ee FBgiffleA.` → delete

**Also update the in-cell roll-up sentence that references the struck rules:**

| FIND | REPLACE WITH |
|---|---|
| `(Rules 2-8 are ending events; Rule 1 from the protocol defines permissible substitutions that do NOT end the LOT)` | `(Rules 2, 3, 5, 6, 7 are ending events; Rule 1 from the protocol defines permissible substitutions that do NOT end the LOT)` |

**Do NOT renumber** the remaining Rules 2/3/5/6/7 — keep their numbers intact so downstream references don't break.

**Optional replacement summary sentence (if desired after cleanup):**

> "The LOT ends for one of the following reasons: discontinuation of all agents, new qualifying medication addition, SCT or CAR-T event, death, health plan disenrollment, or end of study period. Maintenance is not treated as a separate LOT-ending construct in this study."

---

### Edit 2. Update `LOT1_BASE_END_DT` so it no longer silently preserves Rules 4 and 8

**File:** `lot1baseendapr18.pdf`
**Tab:** `10. LOT1_BASE_END`
**Row:** `LOT1_BASE_END_DT`

**Why this edit is required:** Even after Edit 1, this row still says "Rules 2-8 are ending events", which implicitly keeps the old maintenance-based endings alive.

**Replace the Definition / Description text with:**

> `LOT1_BASE_END_DT` is the earliest applicable LOT-ending date derived from discontinuation, new qualifying medication addition, qualifying SCT or CAR-T events, death, disenrollment, or study end. Rule 1 defines permissible substitutions that do NOT end the LOT. Maintenance is not an independent LOT-ending event in this study.

**Slightly fuller version if you want more detail in the cell:**

> `LOT1_BASE_END_DT` is the earliest applicable LOT-ending date derived from discontinuation, new qualifying medication addition, qualifying SCT or CAR-T events, death, disenrollment, or study end. Rule 1 defines permissible substitutions that do NOT end the LOT. If the current LOT is immediately interrupted by a new qualifying medication, the LOT end date is the day before the first administration or dispense date of that new medication. Maintenance is not an independent LOT-ending event in this study.

**Do NOT hard-code the `CART_INIT` end-date convention in this row yet** — wait for Decision B (Section 3).

---

### Edit 3. Update `LOT1_BASE_END_REASON` — remove maintenance-based final categories

**File:** `lot1baseendapr18.pdf`
**Tab:** `10. LOT1_BASE_END`
**Row:** `LOT1_BASE_END_REASON`

**Paste-ready replacement for the Values / Definition cell:**

> **Allowed `LOT1_BASE_END_REASON` values:** `DISCONTINUATION`, `MED_ADD`, `SCT_AUTO`, `SCT_ALLO`, `SCT_CART`, `CART_INIT`, `DEATH`, `DISENROLLMENT`, `STUDY_END`.
>
> The study does **not** use `MAINTENANCE_END` or `SCT_NO_MAINT` as final LOT1 end-reason values. Patients who would previously have ended LOT1 via end of maintenance regimen now map to `DISCONTINUATION` unless a higher-priority event applies first. Former `SCT_NO_MAINT` cases must be recategorised under the final non-maintenance LOT-ending rules.
>
> **Priority order (earliest-matching rule wins):**
> `SCT_ALLO` / `SCT_CART` / `SCT_AUTO` > `CART_INIT` > `MED_ADD` > `DISCONTINUATION` > `DEATH` > `DISENROLLMENT` > `STUDY_END`

**Why confirmed:** The meeting explicitly removes maintenance as a final end bucket and supports recategorising the old `SCT_NO_MAINT` bucket (even though the exact sub-case mapping is still open — see Decision A).

---

### Edit 4. Reframe `contains_mtx_reg` as flag-only

**File:** `lot1baseendapr18.pdf`
**Tab:** `10. LOT1_BASE_END`
**Row:** `contains_mtx_reg` (last row of the variable table on page 3)

**Keep:** mono-maintenance list, dual-maintenance list, anchor concept.

**Paste-ready replacement for the main Definition text:**

> `contains_mtx_reg` is a flag-only variable. It does not create a maintenance start date, maintenance end date, or LOT-ending event. Set `contains_mtx_reg = 1` when the LOT1 induction regimen contains at least one valid mono-maintenance agent **or** valid dual-maintenance combination, AND at least one additional non-steroid MM oncology agent outside that qualifying maintenance subset is present as an anchor.
>
> - **Valid mono-maintenance agents:** lenalidomide, bortezomib, daratumumab, ixazomib, thalidomide.
> - **Valid dual-maintenance combinations:** bortezomib/lenalidomide, carfilzomib/lenalidomide, daratumumab/lenalidomide.
>
> The anchor concept is used only to support this flag. It is not used to derive a separate maintenance period or a maintenance-based LOT end.

---

### Edit 5. Keep the existing operational paragraph only as background

**File:** `lot1baseendapr18.pdf`
**Tab:** `10. LOT1_BASE_END`
**Row:** `contains_mtx_reg`

The cell currently contains an operational paragraph beginning:
> "Definition of a maintenance period: The LOT's initial regimen transitions into a maintenance regimen…"

**Action:** Keep the paragraph, but insert this lead-in line immediately before it so it reads as background, not as active derivation:

> _Background clarification (for interpreting the flag only — not an operational derivation):_

---

### Edit 6. Relabel `mtx scenarios.pdf` as reference / background only

**File:** `mtx scenarios.pdf`
**Location:** top of page 1, above existing content.

**Paste-ready banner:**

> **REFERENCE ONLY — updated per Apr 15 2026 meeting.**
>
> These maintenance scenarios are retained as background examples and do NOT define an operational maintenance period for this study. The current study uses `contains_mtx_reg` as a descriptive flag only and does not use maintenance to create a LOT-ending event. For the active definition, see the `contains_mtx_reg` row in `lot1baseendapr18.pdf`.

**Alternative (if a banner is impractical):** rename to `mtx scenarios_REFERENCE_ONLY.pdf` or move into an `archive/` sub-folder.

---

### Edit 7. Clean the remaining active maintenance wording out of `lot1baseapr18`

**File:** `lot1baseapr18.pdf`
**Tab:** `6. LOT1_BASE`
**Row / narrative:** LOT1 Base period definition text on page 1

**Why this edit is required:** This tab still says the induction regimen period continues until:
> "…all induction regimen medications discontinue, censoring, HSCT, or **maintenance begins**."

That treats "maintenance begins" as an active LOT1-Base ending condition — inconsistent with the Apr 15 decision.

**Action:** delete the phrase `or maintenance begins` from that sentence.

**Suggested replacement sentence:**

> "Once the induction regimen medications are identified, the induction regimen period begins with the earliest MMA medication claim and continues until a valid medication add is introduced, all induction regimen medications discontinue, censoring occurs, or HSCT occurs."

**Note:** The separate substitution bullet mentioning ixazomib "as a maintenance therapy" does NOT need immediate removal unless Julia wants every maintenance mention scrubbed from background examples. The urgent contradiction is only the phrase that makes maintenance an active LOT1-Base ending condition.

---

### Edit 8. Follow-on cleanup on `LOT1_BASE_LENGTH` row

**File:** `lot1baseendapr18.pdf`
**Tab:** `10. LOT1_BASE_END`
**Row:** `LOT1_BASE_LENGTH`

**Why:** the row currently says *"(earliest of Rules 1-8 in the protocol)"* — same residue as Edit 2.

**Action:** change `Rules 1-8` to `Rules 1, 2, 3, 5, 6, 7` (or use prose: `the rules listed above`).


---

## Section 3 — Open decisions that still need Julia's input

These are real issues, but the meeting did not lock down the final wording. Safe-minimum edits are provided so the spec can still be internally consistent.

### Decision A. Exact handling of former `SCT_NO_MAINT` cases

**What the meeting supports:**
- The old maintenance-dependent `SCT_NO_MAINT` bucket should not remain.
- Those patients need to be recategorised.

**What is NOT fully settled:**
- Whether all former `SCT_NO_MAINT` patients should be relabelled `SCT_AUTO`, OR
- Whether they should be routed by the actual earliest downstream event (`DISCONTINUATION` / `MED_ADD` / `CART_INIT` / `SCT_AUTO` / `SCT_ALLO`).

**Current code behaviour (for context):** `lot_program.R:1906-1910` sets `LOT1_BASE_END_REASON = 'SCT_AUTO'` whenever `LOT1_SCT_NO_MAINT_FLG = 1`, subject to higher-priority events.

**Safe-minimum spec text (use until Julia decides):**

> "Planned single or tandem autologous SCT without maintenance does not create a separate maintenance-based end-reason category in this study. These cases must be classified under the final non-maintenance LOT-ending rules."

**Question to ask Julia:**

> "For the former `SCT_NO_MAINT` cohort, do you want to (a) relabel all of them as `SCT_AUTO`, or (b) route them by the actual earliest downstream event?"

---

### Decision B. Exact `LOT1_BASE_END_DT` convention for `CART_INIT`

**What the meeting supports:** If a new medication is added and CAR-T starts within 45 days, the end reason should be `CART_INIT` (not `MED_ADD`).

**What the meeting does NOT explicitly settle:** Whether the end date in that case is `FIRST_CART_DT` or `FIRST_CART_DT - 1`.

**Current code behaviour:** `lot_program.R:1940-1942` sets `LOT1_BASE_END_DT = FIRST_CART_DT` (the CAR-T infusion date itself).

**Spec tension:** `LOT1_TX_ENDDATE_REASON` currently states the general CAR-T convention as *"the preceding LOT ending the day before the CAR-T infusion date"*. If `CART_INIT` follows that general rule, the end date would be `FIRST_CART_DT - 1`.

**Safe-minimum spec text (use until Julia decides):**

> "If a new MM oncology agent is introduced and CAR-T begins within 45 days, `LOT1_BASE_END_REASON = CART_INIT` rather than `MED_ADD`. `LOT1_BASE_END_DT` follows the study's chosen CAR-T transition convention and must be applied consistently throughout the spec and program."

**Question to ask Julia:**

> "For `CART_INIT`, should `LOT1_BASE_END_DT` = `FIRST_CART_DT` to match the current code, or `FIRST_CART_DT - 1` to match the general CAR-T-as-new-LOT convention stated elsewhere in the spec?"

**Once Julia decides, align all of the following:**
1. `lot1baseendapr18.pdf` row `LOT1_BASE_END_DT`
2. `lot1baseendapr18.pdf` row `LOT1_TX_ENDDATE_REASON`
3. Review `CART_45D_CONSOLIDATION` wording for consistency.
4. `lot_program.R:1940-1942`

---

## Section 4 — Recommended clarifications

Not required for substantive alignment with the Apr 15 meeting, but they would make the `contains_mtx_reg` section easier to interpret.

### Recommendation 1. Add one short worked-example note to `contains_mtx_reg`

**Paste-ready text:**

> **Examples:**
> - `BORT + LENA` alone → flag = 0 (no additional anchor outside the qualifying subset).
> - `BORT + LENA + CYCL` → flag = 1 (CYCL anchors the BORT+LENA subset).
> - `BORT + DARA + LENA` → flag = 1 (any valid mono or dual subset always has ≥ 1 other induction drug available as an anchor).
> - `DARA` alone → flag = 0 (no anchor).

### Recommendation 2. Explicitly exclude steroids as anchors

**Why this would help:** The code already excludes steroids; the spec does not currently say so.

**Note:** This is a clarification inferred from the protocol's general treatment of steroids — it was not directly discussed in the Apr 15 meeting. Confirm with Julia before finalising.

**Paste-ready text (append to `contains_mtx_reg` Definition cell):**

> "Corticosteroids (e.g., dexamethasone, prednisone; any drug with `CL_MED_CLASS = 'STEROID'` in `CL_MMA_ROLLUP`) do NOT qualify as an anchor agent. Only non-steroid MM oncology agents count."

---

## Section 5 — Recommended order of operations

1. Apply **Edit 1** in `lot1baseendapr18` — remove Rules 4 and 8 from the page 1 rules narrative (both clean and struck-through versions) and update the "(Rules 2-8 are ending events…)" sentence.
2. Apply **Edit 2** — rewrite `LOT1_BASE_END_DT`.
3. Apply **Edit 3** — update `LOT1_BASE_END_REASON`.
4. Apply **Edit 4** — rewrite `contains_mtx_reg` as flag-only.
5. Apply **Edit 5** — label the operational paragraph as background.
6. Apply **Edit 6** — banner on `mtx scenarios.pdf`.
7. Apply **Edit 7** — remove "or maintenance begins" from `lot1baseapr18`.
8. Apply **Edit 8** — fix `LOT1_BASE_LENGTH` "(earliest of Rules 1-8…)" residue.
9. **Pause and ask Julia Decision A and Decision B.**
10. After Julia's decisions, finalise the `SCT_NO_MAINT` mapping and `CART_INIT` end-date wording, and align the corresponding code paths.
11. (Optional) Add the clarifications in Section 4.

After Steps 1–8, the LOT1 spec is substantively aligned with the Apr 15 maintenance decision. Decisions A and B are still needed for full internal consistency between spec, protocol, and code.

---

## Explicitly out of scope for this document

- Protocol edits.
- LOT 2–5 spec drafting (Julia owes this next week).
- Code changes themselves (see `issues_to_fix.md`).
- Rerun / output validation.

Note: once Decisions A and B are made, corresponding code alignment may still be required.

---

## Bottom line

The maintenance update is not "remove maintenance." It is "do not operationalise maintenance as a separate standalone LOT construct."

The spec should therefore:
1. **Keep** `contains_mtx_reg`.
2. **Remove** maintenance as a final end-reason bucket (Edits 1 + 3).
3. **Stop describing** maintenance as its own active derived period in `lot1baseendapr18` (Edits 2, 4, 5, 8).
4. **Stop describing** maintenance as an active trigger that ends LOT1 Base in `lot1baseapr18` (Edit 7).
5. **Reframe** `mtx scenarios.pdf` as reference material rather than active derivation logic (Edit 6).
6. **Resolve** the two open decisions on `SCT_NO_MAINT` mapping and `CART_INIT` end-date convention before the remaining rows are finalised.

*End of consolidated edit instructions.*
