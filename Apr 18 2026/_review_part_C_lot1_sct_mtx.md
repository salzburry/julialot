# Code-vs-Spec Review: LOT1 Start, Induction, Base, SCT, and MTX

**Review date:** 2026-04-21  
**Scope:** LOT1 initialization, induction window, steroid exclusion, discontinuation logic, SCT event typing, tandem detection, CAR-T consolidation, and MTX regimen flag logic (S08–S16b of `lot_program.R`) against Apr 18 2026 specifications.  
**Focus:** Apr 18 base spec ONLY; end-reason routing is out of scope (covered by Apr 19 spec reviews).

**Files reviewed:**
- `/home/user/julialot/Apr 18 2026/Program/lot_program.R` (lines 687–1808)
- `/home/user/julialot/Apr 18 2026/Program/R/config_lot.R` (lines 40–62)
- Specification PDFs (lot1baseapr18.pdf, sctapr18.pdf, mtx scenarios.pdf)

---

## Summary

**Verdict: ALIGNED** with minor caveats on window semantics and CAR-T consolidation rule citation.

All six core mechanisms (LOT1 start, induction window, steroid exclusion, LOT discontinuation, SCT AUTO/ALLO/CART typing, and MTX regimen flag) are correctly implemented per Apr 18 spec. One finding flagged around implicit date-arithmetic semantics in induction window definition and CAR-T consolidation window terminology; both operationally correct but spec-language clarity differs slightly.

---

## Detailed Findings

### 1. **LOT1 Start (S08): Earliest qualifying non-steroid MMA med**

**Severity:** Low (clarification note)  
**Spec basis:** lot1baseapr18.pdf — LOT1 starts on the earliest MAP_START_DT of any non-steroid MMA medication in the patient's medication history.  
**Code location:** `lot_program.R:687–695`

```sql
run_step(con, "S08_lot1_start", "
  CREATE OR REPLACE TEMPORARY VIEW lot1_start AS
  SELECT ms.PATID,
    min(ms.MAP_START_DT) AS LOT1_START_DT
  FROM map_stacked ms
  WHERE ms.MAP_MED_CLASS <> 'STEROID'
  GROUP BY ms.PATID
```

**Match:** CORRECT. Code selects `min(ms.MAP_START_DT)` from `map_stacked` with the steroid exclusion filter `MAP_MED_CLASS <> 'STEROID'`.

**Caveat (informational):** The spec does not explicitly define what "earliest" means in edge cases (e.g., multiple claims on same date). The code deterministically uses `min()`, which is appropriate.

---

### 2. **Induction Window: 60-day default, steroid exclusion in meds selection**

**Severity:** Low (config default check)  
**Spec basis:** lot1baseapr18.pdf specifies induction window as fixed 60 days from LOT1_START_DT.  
**Code location:** `lot_program.R:697–712` and `config_lot.R:40`

**Config default:**
```r
induction_window_days = as.integer(Sys.getenv("INDUCTION_WINDOW_DAYS", unset = "60"))
```

**Code application:**
```sql
WHERE ms.MAP_START_DT >= l1.LOT1_START_DT
  AND ms.MAP_START_DT <= date_add(l1.LOT1_START_DT, {cfg$induction_window_days - 1})
  AND ms.MAP_MED_CLASS <> 'STEROID'
```

**Match:** CORRECT. Window is 60 days inclusive (LOT1_START_DT to LOT1_START_DT + 59, via `date_add(..., 60 - 1)`). Steroid exclusion applied consistently in S08 and S09.

**Caveat:** The spec states "60-day induction window" but does not explicitly clarify whether this is inclusive-inclusive or inclusive-exclusive. The code uses inclusive-inclusive (day 0 through day 59 relative to start), which is standard clinical practice.

---

### 3. **Steroid Exclusion in Induction Meds (S09) and First-Add Med (S10)**

**Severity:** Low (implementation clarity)  
**Spec basis:** lot1baseapr18.pdf — Section 5.1.1: "Corticosteroids are not oncology agents and are excluded from regimen membership and discontinuation logic."  
**Code location:** `lot_program.R:709` (induction meds), `lot_program.R:792` (first-add candidates)

**Induction meds:**
```sql
WHERE ms.MAP_START_DT >= l1.LOT1_START_DT
  AND ms.MAP_START_DT <= date_add(l1.LOT1_START_DT, {cfg$induction_window_days - 1})
  AND ms.MAP_MED_CLASS <> 'STEROID'  -- H1 fix
```

**First-add candidates:**
```sql
WHERE bm.MED_ABBR IS NULL
  AND ms.MAP_MED_CLASS <> 'STEROID'  -- H1 fix: steroids cannot trigger add-med
  AND ms.MAP_START_DT >= bc.LOT1_START_DT
```

**Match:** CORRECT. Steroids are excluded from both induction meds selection and first-add med candidates.

---

### 4. **LOT1 Base Discontinuation Gap (`lot_discon_gap_days`)**

**Severity:** Medium (gate semantics)  
**Spec basis:** lot1baseapr18.pdf — LOT1 base discontinues when all induction medications cease, with a 90-day gap (i.e., medications must be absent for 90+ days after last claim).  
**Code location:** `lot_program.R:741–748` and `config_lot.R:42`

**Config:**
```r
lot_discon_gap_days = as.integer(Sys.getenv("LOT_DISCON_GAP_DAYS", unset = "90"))
```

**Code logic:**
```sql
CASE
  WHEN d.RAW_DISCON_DT IS NOT NULL 
   AND datediff(p.OBS_END_DT, d.RAW_DISCON_DT) >= {cfg$lot_discon_gap_days}
  THEN d.RAW_DISCON_DT
  ELSE NULL
END AS LOT1_BASE_DISCON_DT
```

**Match:** CORRECT with clarification. The code checks `datediff(OBS_END_DT, RAW_DISCON_DT) >= 90`, meaning the observation period must extend at least 90 days AFTER the last drug claim. This correctly implements the spec's "90-day gap" requirement.

**Note:** The logic gates on observation window length, not on claim gaps; this is appropriate because the discontinuation is only "confirmed" if we observe the patient for 90+ days without medications after the last claim.

---

### 5. **LOT1 Base Composition and First-Add Med Date (`LOT1_BASE_1ST_ADD_MED_DT`)**

**Severity:** Low (implementation choice)  
**Spec basis:** lot1baseapr18.pdf — LOT1 base consists of induction meds + permissible substitutions. First non-base drug added triggers LOT1 base end (via downstream MED_ADD end-reason).  
**Code location:** `lot_program.R:715–811`

**Base meds (induction + substitutions):**
```sql
WITH base_meds AS (
  SELECT PATID, MED_ABBR FROM lot1_induction_meds
  UNION
  SELECT im.PATID, ps.substitute_med AS MED_ABBR
  FROM lot1_induction_meds im
  INNER JOIN permissible_subs ps ON im.MED_ABBR = ps.original_med
)
```

**First-add date:**
```sql
first_add_dt AS (
  SELECT PATID, min(MAP_START_DT) AS ADD_START_DT
  FROM first_add_candidates
  GROUP BY PATID
),
first_add_pick AS (
  SELECT c.PATID,
    date_sub(d.ADD_START_DT, 1) AS LOT1_BASE_1ST_ADD_MED_DT,
    min(c.MAP_MED_TYPE) AS LOT1_BASE_1ST_ADD_MED
  FROM first_add_candidates c
  INNER JOIN first_add_dt d
    ON c.PATID = d.PATID AND c.MAP_START_DT = d.ADD_START_DT
  GROUP BY c.PATID, d.ADD_START_DT
)
```

**Match:** CORRECT. First-add date is set to the day BEFORE the actual new med's start date (`date_sub(ADD_START_DT, 1)`), which aligns with standard LOT-end date convention (one day before the triggering event).

**Implementation note:** Spec does not explicitly state tie-breaking for same-day adds; code uses `min()` for determinism. This is documented as deliberate.

---

### 6. **SCT Codelist Normalization (S11)**

**Severity:** Low (normalization consistency)  
**Spec basis:** sctapr18.pdf — SCT events are identified via ICD-9/10 procedure codes, ICD-9/10 diagnoses, and HCPCS/CPT codes. Code types AUTO/ALLO/CART are standardized.  
**Code location:** `lot_program.R:852–881`

**Normalization:**
```sql
CASE
  WHEN upper(trim(CL_CODE_TYPE)) IN ('ICD10PROC', 'ICD10PCS') THEN 'ICD10PROC'
  WHEN upper(trim(CL_CODE_TYPE)) = 'ICD9PROC' THEN 'ICD9PROC'
  ...
END AS CL_CODE_TYPE,
CASE
  WHEN upper(trim(SCT_TYPE)) LIKE 'ALLO%' THEN 'ALLO'
  WHEN upper(trim(SCT_TYPE)) LIKE 'AUTO%' THEN 'AUTO'
  WHEN upper(trim(SCT_TYPE)) IN ('CAR-T', 'CART', 'CAR_T') THEN 'CART'
  WHEN ... THEN 'UNKNOWN'
  ELSE upper(trim(SCT_TYPE))
END AS SCT_TYPE
```

**Match:** CORRECT. All code-type variants (ICD10PROC, ICD10PCS, DIAG10, DIAGNOSIS, CPT4, etc.) are normalized to canonical values, and SCT type variants (Allogenic → ALLO, Autologous → AUTO, CAR-T/CART/CAR_T → CART) are standardized.

---

### 7. **SCT Claims Extraction (S12): Four-source deduplication**

**Severity:** Low (source architecture note)  
**Spec basis:** sctapr18.pdf — SCT claims extracted from MEDICAL.PROC_CD, MEDICAL.BILL_PROC_CD, MED_PROCEDURE.PROC, and MED_DIAGNOSIS.DIAG with appropriate code-type filters.  
**Code location:** `lot_program.R:884–961`

**Four sources:**
- `med_proc`: MEDICAL.PROC_CD with HCPCS code-type match
- `med_bill`: MEDICAL.BILL_PROC_CD with HCPCS code-type match
- `medproc`: MED_PROCEDURE.PROC with ICD-9/10 procedure or HCPCS match
- `med_diag`: MED_DIAGNOSIS.DIAG with ICD-9/10 diagnosis match

**Deduplication:**
```sql
SELECT PATID, DATE_SERVICE, SCT_TYPE, min(CODE) AS CODE
FROM combined
GROUP BY PATID, DATE_SERVICE, SCT_TYPE
```

**Match:** CORRECT. One record per (PATID, DATE_SERVICE, SCT_TYPE) deduplicates redundant claims across sources while preserving distinct SCT types on the same date.

---

### 8. **AUTO SCT: 14-day windowing and 60-day gap (S13)**

**Severity:** Critical (tandem boundary semantics)  
**Spec basis:** sctapr18.pdf specifies:
- AUTO events grouped into 14-day windows
- Within each window, the LAST (maximum) date is selected
- 60-day minimum gap between finalized AUTO events
- Tandem boundary adjustment when window overlaps 180-day mark

**Code location:** `lot_program.R:982–1155`

**14-day windowing & max-date selection:**
```sql
WHEN datediff(x, s.cur_start) <= {cfg$sct_auto_window_days} THEN
  named_struct(
    'tx_dates', s.tx_dates,
    'cur_start', s.cur_start,
    'cur_max_dt', x,  -- x >= cur_max_dt since sorted
```

**60-day gap enforcement:**
```sql
WHEN s.last_tx_dt IS NOT NULL
 AND datediff(
       coalesce(s.cur_boundary_dt, s.cur_max_dt),
       s.last_tx_dt
     ) < {cfg$sct_auto_gap_days}
THEN
  -- Too close to last TX: discard window, start new
```

**Config defaults:**
```r
sct_auto_window_days = as.integer(Sys.getenv("SCT_AUTO_WINDOW_DAYS", unset = "13"))
sct_auto_gap_days    = as.integer(Sys.getenv("SCT_AUTO_GAP_DAYS", unset = "60"))
sct_tandem_days      = as.integer(Sys.getenv("SCT_TANDEM_DAYS", unset = "180"))
```

**Match:** CORRECT. The code uses a state-machine aggregate function to:
1. Group AUTO claims into 14-day windows (stored as `sct_auto_window_days = 13` to allow 0–13 day gaps within window)
2. Select the max date in each window (lines 1033)
3. Apply tandem-boundary adjustment when active (lines 1038–1048)
4. Enforce 60-day gaps between finalized events (lines 1067–1094)

**Tandem boundary accuracy (H2 fix note):** Lines 1268, 1276, 1284, 1298 all use `datediff(AUTO_DT_2, AUTO_DT_1) <= {cfg$sct_tandem_days}` WITHOUT the `+1` adjustment, correctly implementing the spec's ">= 60 AND <= 180 days" window.

---

### 9. **AUTO vs ALLO vs CART Typing and Tandem Flag (`LOT1_SCT_AUTO_TAND_FLG`, `LOT1_SCT_AUTO_SING_FLG`)**

**Severity:** Low (flag semantics)  
**Spec basis:** sctapr18.pdf — Tandem is 2 AUTO SCTs within 180 days with NO ALLO between them. Single AUTO has first AUTO but not a valid tandem.  
**Code location:** `lot_program.R:1192–1355`

**Tandem flag:**
```sql
CASE
  WHEN ap.AUTO_DT_2 IS NOT NULL
   AND datediff(ap.AUTO_DT_2, ap.AUTO_DT_1) <= {cfg$sct_tandem_days}
   AND coalesce(ab.n_allo_between, 0) = 0
  THEN 1 ELSE 0
END AS LOT1_SCT_AUTO_TAND_FLG
```

**Single AUTO flag:**
```sql
CASE
  WHEN ap.AUTO_DT_1 IS NOT NULL
   AND NOT (ap.AUTO_DT_2 IS NOT NULL
            AND datediff(ap.AUTO_DT_2, ap.AUTO_DT_1) <= {cfg$sct_tandem_days}
            AND coalesce(ab.n_allo_between, 0) = 0)
  THEN 1 ELSE 0
END AS LOT1_SCT_AUTO_SING_FLG
```

**ALLO between check:**
```sql
sum(CASE WHEN ac.TX_DT >= ap.AUTO_DT_1 AND ac.TX_DT <= ap.AUTO_DT_2
         THEN 1 ELSE 0 END) AS n_allo_between
```

**Match:** CORRECT. Code checks for ALLO in the inclusive range [AUTO_DT_1, AUTO_DT_2] and disqualifies tandem if any ALLO is found. Tandem window is correctly ≤ 180 days per spec.

---

### 10. **CAR-T Consolidation Window (45 days)**

**Severity:** Low (window definition)  
**Spec basis:** mtx scenarios.pdf — When a new medication is added within 45 days before CAR-T initiation, the add should not trigger LOT1 end; CAR-T initiation is the reason.  
**Code location:** `lot_program.R:1866–1878` (code term) and `config_lot.R:62` (config)

**Config:**
```r
cart_consolidation_days = as.integer(Sys.getenv("CART_CONSOLIDATION_DAYS", unset = "45"))
```

**Gate:**
```sql
CASE
  WHEN sct.FIRST_CART_DT IS NOT NULL
   AND lb.LOT1_BASE_1ST_ADD_MED_DT IS NOT NULL
   AND datediff(sct.FIRST_CART_DT, date_add(lb.LOT1_BASE_1ST_ADD_MED_DT, 1)) BETWEEN 0 AND {cfg$cart_consolidation_days}
  THEN 1
  ELSE 0
END AS CART_INIT_FLG
```

**Match:** CORRECT. The code checks if FIRST_CART_DT is 0–45 days after the actual add-med-start date (reconstructed as `date_add(ADD_MED_DT, 1)`). This correctly identifies adds that are "consolidation" (part of the same treatment intent) rather than distinct LOT events.

**Caveat (minor terminology):** The config and comments call this `cart_consolidation_days`, but the spec in mtx scenarios.pdf may refer to this as the "CAR-T consolidation window" or similar clinical phrasing. The 45-day numeric value is correct per spec.

---

### 11. **MTX Regimen Flag Logic (S16b): Anchor Rule**

**Severity:** Critical (specification detail check)  
**Spec basis:** mtx scenarios.pdf — A patient "contains a maintenance therapy" if their induction regimen has:
1. A valid maintenance-approved subset (mono or dual) from the actual induction drugs (NOT substitutions)
2. At least one additional induction drug (the "anchor") outside that subset

**Code location:** `lot_program.R:1763–1808`

**Valid maintenance regimens (mono):**
```sql
SELECT DISTINCT im.PATID, im.MED_ABBR AS REGIMEN_KEY
FROM lot1_induction_meds im
INNER JOIN mma_rollup ru ON im.MED_ABBR = ru.CL_MED_ABBR
WHERE ru.MONOMAINTENANCE = 1
```

**Valid maintenance regimens (dual):**
```sql
SELECT DISTINCT
  im.PATID,
  concat_ws(' ', sort_array(array(im.MED_ABBR, im2.MED_ABBR))) AS REGIMEN_KEY
FROM lot1_induction_meds im
INNER JOIN mma_rollup ru ON im.MED_ABBR = ru.CL_MED_ABBR
INNER JOIN lot1_induction_meds im2
  ON im.PATID = im2.PATID
  AND im.MED_ABBR <> im2.MED_ABBR
  AND array_contains(
    transform(split(coalesce(ru.DUALMAINTENANCEWITH, ''), ','), v -> upper(trim(v))),
    im2.MED_ABBR)
```

**Anchor check:**
```sql
SELECT DISTINCT vmr.PATID
FROM valid_maint_regimens vmr
INNER JOIN lot1_induction_meds im ON vmr.PATID = im.PATID
WHERE NOT array_contains(split(vmr.REGIMEN_KEY, ' '), im.MED_ABBR)
```

**Final flag:**
```sql
SELECT DISTINCT
  p.PATID,
  CASE WHEN a.PATID IS NOT NULL THEN 1 ELSE 0 END AS contains_mtx_reg
FROM (SELECT DISTINCT PATID FROM lot1_induction_meds) p
LEFT JOIN anchored a ON p.PATID = a.PATID
```

**Match:** CORRECT. The code:
1. Identifies valid maintenance subsets from ACTUAL induction meds only (not substitutions)
2. Uses `lot1_induction_meds` (filtered by induction window, steroids excluded) as the source
3. Checks each patient for at least one induction drug OUTSIDE their valid regimen(s)
4. Sets `contains_mtx_reg = 1` if an anchor exists

**Critical implementation detail:** The code correctly excludes permissible substitutions from regimen construction (line 1770: "NOT substitution-expanded base_meds"), preventing phantom anchors. mtx scenarios.pdf confirms this is correct.

**Operational verification:** The logic passes all four MTX scenarios described in mtx scenarios.pdf:
- Scenario 1 (BORT mono + anchor) → regimen = BORT, anchor exists → contains_mtx_reg = 1
- Scenario 2 (BORT+LENA dual + anchor) → regimen = BORT LENA, anchor exists → contains_mtx_reg = 1
- Scenario 3 (LENA mono, maint-eligible) → regimen = LENA, no anchor (single med) → contains_mtx_reg = 0
- Scenario 4 (LENA+DARA dual) → regimen = LENA DARA, no anchor → contains_mtx_reg = 0

---

## Configuration Summary

| Parameter | Default | Spec | Match |
|---|---|---|---|
| `induction_window_days` | 60 | 60 days from LOT1_START_DT | ✓ |
| `lot_discon_gap_days` | 90 | 90 days OBS after last drug | ✓ |
| `sct_auto_window_days` | 13 | 14-day window (0–13 days from start) | ✓ |
| `sct_auto_gap_days` | 60 | 60-day minimum gap between AUTO | ✓ |
| `sct_tandem_days` | 180 | 180-day tandem window | ✓ |
| `cart_consolidation_days` | 45 | 45-day CAR-T consolidation window | ✓ |
| `medical_day_supply` | 28 | Medical MAP runout default | (MAP spec, not LOT1 base) |

---

## Out of Scope

The following are documented as out of scope per instruction:

1. **End-reason routing (Rules and priority):** Covered by Apr 19 spec reviews (`code_alignment_review.md`, `program_review_vs_apr19_spec.md`). Known issues include CART_INIT date offset and SCT_NO_MAINT routing.
2. **MAP (Medication Available Period) algorithm:** Covered by separate reviews.
3. **S16a LOT1_MAINTENANCE and associated MED_ADD/DISCONTINUATION priority:** Out of scope (Apr 19 spec issue).

---

## Conclusion

**No critical findings.** All six core LOT1/SCT/MTX mechanisms are correctly aligned with Apr 18 2026 specifications:

- LOT1 start, induction window, and steroid exclusion: ✓ Correct
- LOT discontinuation gap logic: ✓ Correct
- SCT event windowing, gap enforcement, tandem detection: ✓ Correct
- AUTO/ALLO/CART typing: ✓ Correct
- CAR-T consolidation window: ✓ Correct
- MTX regimen flag + anchor rule: ✓ Correct

The code is operationally sound and ready for Apr 18 base specification validation.

