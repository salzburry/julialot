# Spec alignment change log — 2026-04-21

> **Update (second pass, same day):** Following reviewer confirmation that
> `non-diagnostic` was intentionally removed from the baseline-MM rule after
> discussion (so R2 is a spec-document issue, not a code issue), the remaining
> formal finding — the `LOT1_BASEMAINT_*` output surface + dead S16a subsystem —
> has now been applied. See the new section "Second pass: R4 applied" at the
> bottom. R2 is no longer pending; only the Part 1 therapy-capture residual
> risk remains (still not a formal finding).

**Scope:** code updates in `Apr 18 2026/Program/` to bring the pipeline in sync with the Apr 18 specs and Apr 14 attrition table (plus the already-adopted Apr 19 LOT1 end-spec). Triggered by findings in `reviewer_findings_validation.md`. Review-only documents in `Apr 18 2026/` were left unchanged.

**Files changed:**
- `Apr 18 2026/Program/lot_program.R`
- `Apr 18 2026/Program/R/pipeline_steps.R`
- `Apr 18 2026/Program/R/config_prompts.R`

**Files left unchanged, flagged for study-team decision:** see "Not applied — needs study-team input" below.

---

## Applied changes

### 1. R3 — Other-cancer OP rule relaxed per StudyPop
**File:** `pipeline_steps.R` — `Step 22 other_malig_flag`, Path B of the OUTPATIENT branch.
**Before:** required both `op.first_dt` *and* `op.next_dt` ≤ day before index.
**After:** requires only `op.first_dt` in baseline; pair window (`diff_days <= 30`) kept unchanged.
**Rationale:** StudyPop `studypopapr18.pdf` p2 row `MM_baseline_other`: *"Only the first of the 2 codes is required to occur inside the baseline period."* Patients whose confirming second OP claim falls just after index are now correctly excluded.

### 2. R1 — Exclusion flags default TRUE
**File:** `config_prompts.R:118-121`.
**Before:** `apply_pregnancy_excl`, `apply_clintrial_excl`, `apply_other_malig_excl`, `apply_baseline_mm_excl` all default `"FALSE"` per 2026-04-14 stakeholder decision.
**After:** all four default `"TRUE"`. Env vars still override.
**Rationale:** the attrition table (`attritiom apr 14`) lists Steps 7–10 as applied exclusions. Under the prior defaults, a default `ELIG_COH_FINAL` build produced the Step 6 working cohort rather than the Step 10 spec cohort. Prior stakeholder decision is preserved in a superseded-by comment.

### 3. R6 — CART_INIT ends on `FIRST_CART_DT - 1`
**File:** `lot_program.R` — S16 `lot1_base_end` CASE trees (end-reason, end-date, length).
**Before:** CART_INIT branches used `ec.FIRST_CART_DT` as both the THEN value and the tie-break gate. SCT-vs-CART_INIT tie-break used `LOT1_TX_ENDDATE <= ec.FIRST_CART_DT`. DISCON-vs-CART_INIT tie-break in the length CASE used `LOT1_BASE_DISCON_DT <= ec.FIRST_CART_DT`.
**After:**
- `THEN ec.FIRST_CART_DT` → `THEN date_sub(ec.FIRST_CART_DT, 1)` in both the end-date CASE and the inner length CASE.
- CART_INIT discon-tie gate: `ec.FIRST_CART_DT <= ec.LOT1_BASE_DISCON_DT` → `date_sub(ec.FIRST_CART_DT, 1) <= ec.LOT1_BASE_DISCON_DT`.
- SCT vs CART_INIT tie-break: `LOT1_TX_ENDDATE <= ec.FIRST_CART_DT` → `LOT1_TX_ENDDATE <= date_sub(ec.FIRST_CART_DT, 1)` (SCT only wins ties when its end is ≤ CART_INIT's spec end date).
- DISCON vs CART_INIT tie-break in the length outer CASE: `LOT1_BASE_DISCON_DT <= ec.FIRST_CART_DT` → `LOT1_BASE_DISCON_DT <= date_sub(ec.FIRST_CART_DT, 1)`.

**Rationale:** `lot1baseendupdatedapr19.txt:113-114`: for CAR-T transitions including `CART_INIT`, `LOT1_BASE_END_DT` is the day before `FIRST_CART_DT`. All three CASE trees (end-reason, end-date, length) now consistently use `date_sub(FIRST_CART_DT, 1)` as the CART_INIT end-date semantic.

### 4. R5 — `SCT_NO_MAINT` routing removed
**File:** `lot_program.R` — S16 `end_candidates` CTE and all three CASE trees.
**Removed:**
- `LOT1_SCT_NO_MAINT_FLG` derivation inside `end_candidates`.
- `SCT_NO_MAINT_END_DT` derivation inside `end_candidates`.
- Rule-4-equivalent WHEN branches in `LOT1_BASE_END_REASON`, `LOT1_BASE_END_DT`, and `LOT1_BASE_LENGTH` CASE trees.
- The `(ec.LOT1_SCT_NO_MAINT_FLG = 0 OR ...)` gate in the length outer branch.

**Effect:** patients previously bucketed `SCT_NO_MAINT` (planned AUTO without maintenance) now fall through to `DISCONTINUATION` / `MED_ADD` / `CART_INIT` / `SCT_AUTO (Rule 2 unplanned)` / `SCT_ALLO` / `SCT_CART` / censoring — driven by their actual earliest end event, as `lot1baseendupdatedapr19.txt` requires.

**Dependency note:** `lot1_maintenance` (S16a) is still joined in S16 to pass through the `LOT1_BASEMAINT_*` columns (see "Not applied" below). No end-reason logic depends on it anymore.

### 5. R7 — First-add same-day tie-break uses fixed-seed random
**File:** `lot_program.R:796-813` — `first_add_pick` CTE inside S10 `lot1_base`.
**Before:** aggregated `min(c.MAP_MED_TYPE) AS LOT1_BASE_1ST_ADD_MED` inside `first_add_pick` CTE with a comment acknowledging the deliberate deviation from spec.
**After:** rewrote the CTE to use `row_number() OVER (PARTITION BY PATID ORDER BY MAP_START_DT, rand(42)) = 1`. `rand(42)` is a fixed-seed Spark SQL pseudo-random, so the tie-break is reproducible across runs and matches the spec's "random with fixed seed" wording. Added a short comment explaining the seed.
**Impact:** end date and length logic are unaffected (both come from `ADD_START_DT`, which is tie-free). Only the recorded `LOT1_BASE_1ST_ADD_MED` label changes for patients with multiple same-day add candidates.
**Side effect:** `first_add_dt` CTE no longer needed; folded into the `row_number()` query.

### 6. Stale comment refresh
**File:** `lot_program.R` — S16 header comment and inline CASE-tree comments.
**Updated** to match Apr 19 spec numbering (Rule 1 = Discontinuation, Rule 2 = SCT/CAR-T, Rules 3–5 = censoring) and removed references to `MAINTENANCE_END` / `SCT_NO_MAINT` as final values. Maintenance passthrough comment notes that these columns are carried through for historical reference pending a study-team decision on whether to drop the S16a subsystem entirely.

---

## Not applied — needs study-team input

### R2 — Baseline MM definition (StudyPop non-diagnostic vs attrition table)
**File:** `pipeline_steps.R:593-615` (unchanged).
**Why not flipped automatically:** the code author explicitly recorded the decision at `:599-600`:
> `# NOTE: Attrition table does NOT require non-diagnostic; IE criteria PDF row 14 does. Following attrition table as the authoritative source.`

StudyPop `studypopapr18.pdf` p2 row `MM_baseline_diag` defines this flag as "≥1 **non-diagnostic** medical claim for MM". The attrition table simply says "≥1 MM dx". This is a source-of-truth conflict; flipping the definition without explicit sign-off would silently change the cohort.

**What the fix would look like, once the study team chooses:** if StudyPop wins, reintroduce the removed `claim_nondiagnostic` view (referenced in the in-code comment) and add `AND e.is_non_diagnostic = 1` to the `MM_BASELINE_EVIDENCE` CASE.

Also: because R1 is now applied, this flag IS applied by default — so R2 becomes materially visible immediately rather than latent as before. The study team should confirm the definition before the next production run.

### R4 — `S16a_lot1_maintenance` subsystem and `LOT1_BASEMAINT_*` passthrough
**File:** `lot_program.R:1392-1761` (unchanged), `:1837-1847` (unchanged), `R/config_lot.R:45-51` (unchanged).
**Why not removed:** `code_alignment_review.md` (prior pass) explicitly framed this as a "decide whether lot1_maintenance is needed anywhere outside historical reference/QC" question. Deleting ~370 lines plus 10 output columns plus 3 config params is too large a behavioural change to apply without confirmation.
**What the fix would look like, once the study team decides:** if the subsystem is not needed, delete `S16a_lot1_maintenance` in full, remove the `LEFT JOIN lot1_maintenance m` in S16, drop the 10 passthrough columns, drop the `LOT1_MAINTENANCE` checkpoint entry, and remove `maint_min_days` / `maint_post_sct_min_days` / `maint_sct_window_days` from `config_lot.R`. End-reason logic is already detached from this subsystem (R5 above).

### Residual risk (not a formal finding): Part 1 therapy capture narrower than Part 2
**File:** `pipeline_steps.R:631-648` (unchanged).
The attrition pipeline's `therapy_events` step pulls from `medical.PROC_CD` + `rx.NDC` only (2 sources). Part 2's `mma_med_raw` at `lot_program.R:299-387` pulls from 4 sources: `medical.PROC_CD`, `medical.BILL_PROC_CD`, `medical.NDC`, `rx.NDC`. A therapy event billed only under `BILL_PROC_CD`, or administered as an NDC on a medical claim, would be missed by the attrition's `MM_bl_agents` / `MM_FU_agents` checks.
**Why not changed:** needs spec check — does the `mm_therapy_codes` codelist actually contain HCPCS that would plausibly land in `BILL_PROC_CD`, or NDCs administered on the medical side? If yes, this is a real undercapture and the therapy extraction should add both sources. If the codelist is HCPCS+NDC but only `PROC_CD`/`rx.NDC` in practice, current code is fine.

---

## Verification steps I recommend before the next production run

1. **CASE/END balance** already verified — same count diff as before edits (not my regression).
2. **No dangling column references:** grepped for `LOT1_SCT_NO_MAINT_FLG` and `SCT_NO_MAINT_END_DT` — no remaining references in any file.
3. **Run the pipeline end-to-end** on a small cohort slice and compare `LOT1_BASE_END_REASON` counts against the last known-good run. Key expectation under Apr 19 spec:
   - No patients classified as `SCT_NO_MAINT` (was not a final value anyway, but the reclassified-to-`SCT_AUTO` path is gone — planned AUTO without later SCT event should now fall to `DISCONTINUATION` or censoring).
   - `CART_INIT` patients have `LOT1_BASE_END_DT = FIRST_CART_DT − 1` and `LOT1_BASE_LENGTH` 1 day shorter than before.
4. **Final cohort size will drop** after R1 takes effect — the exclusion flags now apply by default. Compare `count(distinct PATID)` in `ELIG_COH_FINAL` to the old ~21k working-cohort figure; the new default should be the Step 10 cohort.
5. **R3 impact:** `OTHER_MALIGN_FLAG` counts will go up modestly as patients with post-index second OP claims are now correctly flagged. Verify against a historical sample.
6. **R7 impact:** `LOT1_BASE_1ST_ADD_MED` label distribution will shift (no longer alphabetically biased). End dates and lengths unchanged.

---

*No review documents were modified by the first pass. This file is the only new documentation artifact from that pass.*

---

## Second pass: R4 applied (maintenance output surface removal)

Trigger: reviewer's updated report (2026-04-21) confirmed the baseline-MM `non-diagnostic` clarification (R2 is a doc issue, not code) and kept only one formal finding open — the `LOT1_BASEMAINT_*` output columns at `lot_program.R:1837` being inconsistent with the Apr 19 flag-only maintenance rule.

**Applied — removed the entire maintenance-period machinery since nothing consumes it after R5:**

1. **`lot_program.R` — S16 `end_candidates` CTE.** Dropped the 10 `LOT1_BASEMAINT_*` passthrough columns (`LOT1_BASEMAINT_START`, `_TYP`, `_END`, `_END_REASON`, `_MED_BORT`, `_MED_CARF`, `_MED_DARA`, `_MED_IXAZ`, `_MED_LENA`, `_MED_THAL`) and the `LEFT JOIN lot1_maintenance m ON lb.PATID = m.PATID`. `end_candidates` now joins only `lot1_sct` and `lot1_contains_mtx_reg`, with `contains_mtx_reg` being the sole maintenance concept in the final output.

2. **`lot_program.R` — S16a subsystem.** Deleted the entire `run_step(con, "S16a_lot1_maintenance", ...)` block (381 lines including the C3-fix comment header and the `qc` clause). Dead code after R5 removed `SCT_NO_MAINT` routing and step 1 above removed the passthrough consumers. No other module references `lot1_maintenance` or `MAINT_FOLLOWS_SCT_FLG`.

3. **`lot_program.R` — comments refreshed.**
   - Line ~844 SCT section comment: replaced "Maintenance detection is now in S16a_lot1_maintenance" with a note that Apr 19 makes maintenance a descriptive flag only (`contains_mtx_reg` from S16b).
   - Materialize-checkpoint header: changed "before maintenance detection" / "S16a and S16" / "for S16a/S16 performance" → "before S16 final assembly" / "S16" / "for S16 performance".
   - Persist section: "already materialized before S16a" → "already materialized before S16".

4. **`R/config_lot.R` — removed 3 dead config parameters:** `maint_min_days`, `maint_post_sct_min_days`, `maint_sct_window_days`, along with the 4-line comment block above them that referenced the Apr 15 maintenance decision.

**Structural verification:**
- Whole-file `grep` for `lot1_maintenance|LOT1_BASEMAINT|MAINT_FOLLOWS_SCT_FLG|maint_min_days|maint_post_sct_min_days|maint_sct_window_days|S16a` under `Apr 18 2026/Program/` now returns zero matches.
- `CASE`/`END` balance: before 2nd pass 78/76 → after 61/59. Same delta (2) as before, consistent with removing 17 balanced CASE/END pairs in S16a.
- Paren balance unchanged at -11 (pre-existing).
- `lot_program.R` dropped from 2244 lines to 1865 lines (−379 lines).
- No other module referenced the removed names; `descriptives_lot.R`, `dashboard_lot.R`, `cyclo_appendix_lot.R`, and `pipeline_steps.R` are untouched.

**Downstream impact:**
- Final `lot1_base_end` dataset: 10 fewer columns. Any downstream consumer expecting `LOT1_BASEMAINT_*` will need to switch to `contains_mtx_reg` (already present).
- `config_lot.R`: 3 fewer knobs. If any env (`MAINT_MIN_DAYS` etc.) was set in a runtime config, it now has no effect — that's intentional.
- Materialization of `MAP_STACKED` / `LOT1_BASE` / `LOT1_SCT` is retained because S16 still references them; only the purpose comment changed.

**Still outstanding (not formal findings):**
- Residual risk: Part 1 therapy capture (`pipeline_steps.R:631`) narrower than Part 2 (`lot_program.R:292-387`). Reviewer agreed this should not be escalated until confirmed against the `mm_therapy_codes` codelist and data practice.

**Documentation note (out of scope for code):** `Program Spec and Scenarios/studypopapr18.pdf` page 2 still contains the outdated "non-diagnostic" wording for `MM_baseline_diag`. The spec document should be updated to match the agreed rule — no code change needed.

*End of second pass.*

---

## Third pass: archive cleanup + materialization comment

Trigger: follow-up reviewer report flagged `Program/Old Code/new_code.R` as a dead duplicate inside the active `Program/` tree (P3), plus stale cross-references, plus a materialization-rationale comment that was still written as if S16a were live.

**Applied:**

1. **Deleted `Apr 18 2026/Program/Old Code/new_code.R`** (140KB, 4012 lines — pre-modularization monolith). Not sourced by any active entrypoint (`main.R` / `lot_program.R`). Preserved in git history; removed from the working tree. Empty parent `Old Code/` folder cleaned up.

2. **Cleaned 2 stale references to `new_code.R`:**
   - `lot_program.R:21` header comment — rewritten from *"(output of Part 1 attrition pipeline, new_code.R)"* to *"(output of the Part 1 attrition pipeline; see main.R)"*.
   - `R/codelists_lot.R:5` header comment — rewritten from *"Follows the same pattern as new_code.R's R/db_utils.R"* to an inline "Loader policy" statement (the policy was the useful part; the pointer to the deleted file wasn't).

3. **Updated the pre-S16 materialization comment** to reflect the post-S16a rationale. Before, the comment justified materialization in terms of "S16a and S16" re-referencing the views. Now S16 references each view only once; the real beneficiaries are `descriptives_lot.R` (~17 references to `map_stacked`, ~11 to `lot1_sct`, several to `lot1_base`), the MAP validation QC, and the run-metadata counts. Comment rewritten to say so; materialization loop itself unchanged (still useful, just for different reasons).

**Verification:**
- Repo-wide grep for `new_code|S16a_lot1_maintenance|LOT1_BASEMAINT|lot1_maintenance|MAINT_FOLLOWS_SCT_FLG` under `Apr 18 2026/Program/` returns zero matches.
- `Program/` tree now contains only the active modules (`R/`, `lot_program.R`, `main.R`). No archive subfolder under `Program/`.
- `lot_program.R`: 1867 lines (+2 from the materialization comment rewrite, otherwise unchanged from second pass).

**Outstanding (unchanged from second pass):**
- Part 1 therapy capture residual risk (`pipeline_steps.R:631` — only `medical.PROC_CD` + `rx.NDC`, vs Part 2's 4 sources). Still held until spec/data confirmation.

**Documentation note:** `Program Spec and Scenarios/studypopapr18.pdf` page 2 still contains outdated "non-diagnostic" wording for `MM_baseline_diag`. Spec doc should be updated; no code change.

*End of third pass.*
