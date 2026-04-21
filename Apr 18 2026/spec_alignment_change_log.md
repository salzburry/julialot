# Spec alignment change log — 2026-04-21

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

*No review documents were modified by this pass. This file is the only new documentation artifact.*
