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

### Gap 1. Different renumbering scheme

**What the Apr 19 file does:** Numbered list in both `LOT1_END_DT_TEMP` and `LOT1_END_REASON_TEMP` starts at (1) Discontinuation, (2) SCT / CAR-T events, (3) Death, (4) Health plan disenrollment, (5) End of study period. Permissible substitutions are moved out of the numbered list into a trailing "Note" ("Substitution … is an exception, not an ending event").

**What our `spec_edit_instructions.md` specified:** (Rule 1) Permissible substitutions, (Rule 2) Discontinuation, (Rule 3) SCT / CAR-T events, (Rule 4) Death, (Rule 5) Disenrollment, (Rule 6) Study end.

**Impact:** Both are internally consistent. The Apr 19 scheme is actually tighter — numbered list = ending events only, substitutions as a Note — which is arguably cleaner. However:

- **Downstream references must match.** The Apr 19 cell for `LOT1_BASE_END_REASON` Definition says it is "Derived by selecting the earliest end date across the LOT-ending events listed in the LOT1_END_REASON_TEMP rules narrative" — no rule numbers — so this is resilient.
- **But** the existing `ALLO_ALWAYS_ENDS_LOT` row still says **"Rule 3: 'Any allogeneic SCTs are considered a new LOT…'"** (per prior extract of the same workbook). In the new Apr 19 numbering, allogeneic SCT is now Rule 2 (SCT / CAR-T events), not Rule 3. This row still references the OLD rule number.
- Similarly, any protocol Section 5.1.1 reference and any `lot_program.R` code comment that says "Rule 3" for SCT needs to be checked.

**Action:** Pick a renumbering convention and stick with it. Either (a) update the other rows and downstream references to the new 1–5 numbering, OR (b) revert to the original 1–7/1–8 numbering. Do not leave a mix.

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

**You can delete the old `lot1baseendapr18.pdf` after closing Gap 2 (populate the Values column) and deciding on Gap 1 (renumbering consistency).** The maintenance-removal changes, CART_INIT convention, priority order, and `contains_mtx_reg` reframing are all correctly captured in `lot1baseendupdatedapr19.pdf`.

If you want a zero-risk path:
1. Populate the `Values` column on `LOT1_BASE_END_REASON` with the allowed-values text (Cell 3).
2. Sweep the workbook for any remaining "Rule 3" / "Rule 4" / "Rules 1–8" / "Rules 2–8" references and align them with the new 1–5 numbering (especially the `ALLO_ALWAYS_ENDS_LOT` row, which still says "Rule 3").
3. Then the old `lot1baseendapr18.pdf` is safe to delete.

*End of review.*
