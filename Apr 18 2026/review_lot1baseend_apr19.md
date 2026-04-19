# Review: `lot1baseendupdatedapr19.pdf` vs Final Spec Decisions

**Review date:** 2026-04-19
**File reviewed:** `Apr 18 2026/Program Spec and Scenarios/lot1baseendupdatedapr19.pdf` (pulled from main branch)
**Compared against:** The 6 spec cells in `Apr 18 2026/spec_edit_instructions.md` that target this workbook (`lot1baseendapr18.xlsx`): Cells 1, 2, 3, 4, 5, 6.
**Scope:** Text-only comparison of the extracted PDF against the agreed paste-ready cell text.

## Bottom line

**Mostly aligned — safe to replace the old `lot1baseendapr18.pdf`, but with 2 small gaps to close first.** The maintenance-related content is correctly cleaned up; CART_INIT is correctly documented with `FIRST_CART_DT - 1`; all the old Rule 4 / Rule 8 / `SCT_NO_MAINT` / `MAINTENANCE_END` language is gone. The two gaps are not regressions — they are items from our cell-replacement list that were not carried over.

---

## What's correctly updated (matches the final spec)

| Our cell | Apr 19 file | Status |
|---|---|---|
| **Cell 2** — `LOT1_BASE_END_DT` / Definition: enumerated events, "Maintenance is NOT an independent LOT-ending event", CART_INIT = day before `FIRST_CART_DT` | Text present in the cell (page 2 extract, variable `LOT1_BASE_END_DT`) | ✅ Matches |
| **Cell 4** — `LOT1_BASE_END_REASON` / Definition: priority order (`SCT_ALLO > SCT_CART > SCT_AUTO > CART_INIT > MED_ADD > DISCONTINUATION > DEATH > DISENROLLMENT > STUDY_END`), CART_INIT rule with `FIRST_CART_DT - 1` | Present verbatim | ✅ Matches |
| **Cell 5** — `LOT1_BASE_LENGTH` / Definition: simplified to reference the `LOT1_BASE_END_DT` row | "LOT end date is the priority-based end date defined in the LOT1_BASE_END_DT row" — present | ✅ Matches |
| **Cell 6** — `contains_mtx_reg` / Definition: flag-only, (a)/(b) wording, mono/dual lists, neutral anchor language | Present on pages 3–4 with the expected wording | ✅ Matches |
| **Rule 4 (old, maintenance-based)** removed | No "not followed by maintenance within 180 days" text anywhere | ✅ Removed |
| **Rule 8 (old, end of maintenance regimen)** removed | No "end of maintenance regimen" text anywhere | ✅ Removed |
| **`MAINTENANCE_END`** as a final value removed | No occurrence in extract | ✅ Removed |
| **`SCT_NO_MAINT`** as a final value removed | No occurrence in extract | ✅ Removed |
| Rule 3 → now "SCT / CAR-T events" label | Text reads "(2) SCT / CAR-T events" in the rules narrative | ✅ Relabelled |
| CAR-T is its own LOT, with pointer to `LOT1_TX_ENDDATE_REASON` and `LOT1_BASE_END_DT` rows | Present verbatim | ✅ Matches |

---

## Gaps to close before deleting the old file

### Gap 1. Downstream rule-number references still use the old scheme — **verified INSIDE the Apr 19 file itself**

**Authoritative numbering (per Apr 19 file top-level rules, confirmed):**

| Rule | Covers |
|---:|---|
| Rule 1 | Discontinuation of all agents |
| Rule 2 | SCT / CAR-T events (unplanned AUTO, ALLO, CAR-T) |
| Rule 3 | Death |
| Rule 4 | Health plan disenrollment |
| Rule 5 | End of study period |
| — (Note) | Permissible substitutions — exception, not an ending event |

The **top-of-page rules narrative** in `LOT1_END_DT_TEMP` and `LOT1_END_REASON_TEMP` has been renumbered correctly. **But several other rows in the same workbook still quote OLD rule numbers**:

| Location (line no. in extracted text from `lot1baseendupdatedapr19.pdf`) | Current (stale) text | What it should say |
|---|---|---|
| `:2191` — `LOT1_BASE_1ST_ADD_MED_DT` row | *"Per **Rule 1**: permissible substitutions (biologic reference product with biosimilars) 'do not advance the LOT.'"* | "Per the permissible-substitutions Note in `LOT1_END_REASON_TEMP`" — substitutions are no longer Rule 1 in the new scheme |
| `:1082` — `FIRST_ALLO_DT` row | *"**Rule 3**: 'Any allogeneic SCTs are considered a new LOT…'"* | "**Rule 2** (SCT / CAR-T events): …" |
| `:2360` — `ALLO_ALWAYS_ENDS_LOT` row | *"**Rule 3**: 'Any allogeneic SCTs are considered a new LOT…'"* | "**Rule 2** (SCT / CAR-T events): …" |

**Also check outside this file:**
- Protocol Section 5.1.1 — if it uses rule numbers, align to the new 1–5 scheme.
- `lot_program.R` comments — references like `# Rule 3: Unplanned SCT`, `# Rule 4: Planned AUTO SCT` are stale. (Most of these get deleted when the SCT_NO_MAINT logic is removed per the code review, but any surviving references need the new numbers.)

**Action:** In the same workbook, update the three stale references above and any others like them. Sweep the protocol and code comments for the same treatment.

`spec_edit_instructions.md` already uses the new numbering, so it does not need further edits for this gap.

---

### Gap 2. `LOT1_BASE_END_REASON` — `Values` column is not populated

**What our `spec_edit_instructions.md` Cell 3 specified:** The `Values` column (separate from `Definition`) should read:

```
Allowed values: DISCONTINUATION, MED_ADD, SCT_AUTO, SCT_ALLO, SCT_CART, CART_INIT, DEATH, DISENROLLMENT, STUDY_END.

The study does NOT use MAINTENANCE_END or SCT_NO_MAINT as final values.
```

**What the Apr 19 file shows:** I searched the extract for "Allowed values", "DISCONTINUATION, MED_ADD", "MAINTENANCE_END", "SCT_NO_MAINT" — **no matches anywhere**. The `Values` column for `LOT1_BASE_END_REASON` appears to be empty or not carrying an enumerated list.

**Impact:** A QC reader has no authoritative list of the allowed string values. They have to infer the values from the priority order narrative in the Definition column. This was a specific cleanup the team agreed to make.

**Action:** Paste the Cell 3 text into the `Values` column of `LOT1_BASE_END_REASON`.

---

### Gap 3. `contains_mtx_reg` still mixes new flag-only framing with the old operational paragraph

**Spec (Cell 6):** rewrites the cell around the flag-only framing and lists mono / dual agents, keeping the background paragraph but prepending "Background clarification (for interpreting the flag only — not an operational derivation):" so it's clearly labelled.

**Apr 19 file:** has the new flag-only lead-in, but the old operational paragraph *"Definition of a maintenance period: The LOT's initial regimen transitions into a maintenance regimen, such that non-maintenance medications present during the initial regimen are discontinued …"* still appears unlabelled. Verified occurrences in the extract:
- `:2734` (inside the `contains_mtx_reg` row) — "Definition of a maintenance period" text
- `:3130` / `:3162` — same text appears again, with "regimen transitions into a maintenance regimen" wording

**Impact:** A reader sees the "flag only" sentence at the top AND the operational-derivation wording right below with no labelling to signal which is authoritative. Consistent with the Cell 6 wording in `spec_edit_instructions.md`, add the label:

> _Background clarification (for interpreting the flag only — not an operational derivation):_

…immediately before the "Definition of a maintenance period…" paragraph, so the mixed framing is resolved.

---

## Nice-to-have, not blocking

### Note 1. Explicit `MAINTENANCE_END` / `SCT_NO_MAINT` remap sentences

Our agreed Cell 4 Definition also included two remap sentences:

> "Patients who would previously have ended LOT1 via end of maintenance regimen now map to DISCONTINUATION unless a higher-priority event applies first."
> "Patients who would previously have been bucketed as SCT_NO_MAINT must be classified under the final non-maintenance LOT-ending rules above based on the earliest applicable event; SCT_NO_MAINT is not a final value in this study."

The Apr 19 extract does not contain these sentences. Since both bucket names are also absent from the Definition text, a reader will not see them anywhere — which is arguably fine, but downstream engineers looking at the pre-Apr-15 output (where MAINTENANCE_END and SCT_NO_MAINT did exist) will not find explicit guidance on where those patients now go.

**Optional:** paste the two remap sentences into `LOT1_BASE_END_REASON` / Additional Notes (or append to Definition). Not required for correctness; helpful for transition clarity.

---

## Cross-tab cleanups that are NOT in this file (out of scope for this review)

These are from the final cell list but live in other workbooks, so they do not affect whether `lot1baseendapr18.pdf` can be deleted:

- **`lot1baseapr18.xlsx`** tab `6. LOT1_BASE` — remove "or maintenance begins" from LOT1 Base period narrative (Cell 7).
- **`Mtx_scenarios.xlsx`** page 1 — add REFERENCE ONLY banner (Cell 8).

Worth confirming these two are also handled before closing the spec pass.

---

## Recommendation

**Do NOT delete the old `lot1baseendapr18.pdf` yet.** The Apr 19 file is directionally correct but not yet fully aligned. Three concrete items remain:

1. **Gap 1 — rule-number sweep.** Three stale references inside the Apr 19 workbook itself (at extract lines `:1082`, `:2191`, `:2360`). Update them to the new 1–5 scheme. Also sweep protocol Section 5.1.1 and `lot_program.R` comments.
2. **Gap 2 — populate `Values` column.** The allowed-values enumeration (Cell 3) is missing. Paste it in.
3. **Gap 3 — label the old operational paragraph inside `contains_mtx_reg`.** Prepend "Background clarification (for interpreting the flag only — not an operational derivation):" so the mixed framing is resolved.

Once those three are done, the old `lot1baseendapr18.pdf` is safe to delete.

---

## Note on workspace / branch mismatch

If `spec_edit_instructions.md` and `review_lot1baseend_apr19.md` are not visible in your local clone, it's because they live on branch `claude/review-meeting-minutes-BWAJF`, not `main`. Switch branches (`git checkout claude/review-meeting-minutes-BWAJF`) or pull that branch to see them. The Apr 19 PDF itself was pulled from `main` into this branch for the review.

*End of review.*
