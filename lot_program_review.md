# Comprehensive Review: `lot_program.R` vs Program Specifications

**Reviewed file:** `/home/user/julialot/R/lot_program.R` (4337 lines)

**Reference documents (Apr 13 2026 folder):**
- Lot protocol Apr 13 (Protocol)
- mmamedapr14 (5A. MMA_MED spec)
- maedapr14 (5B. MAP_MED spec)
- lot1baseapr14 (6. LOT1_BASE spec)
- sctapr14 (7. SCT spec)
- lotbaseendapr14 (10. LOT1_BASE_END spec)
- clmmarollupapr14 (Tab 40. CL_MMA_ROLLUP)
- codelist.pdf (Tab 41. CL_MMA_CODELIST, permissible subs, SCT codes)
- optum business rules / optum data dict (Optum CDM v9.0)
- sensitivity cbecks (Julia Moore email re: maintenance/CYCLO/CAR-T)

**Review type:** Static analysis only. Code was not executed.

---

## Summary of Findings

| Severity | Count | Description |
|----------|-------|-------------|
| CRITICAL | 6 | Blocking issues that produce wrong results or prevent execution |
| HIGH | 5 | Significant deviations from spec that affect analytic correctness |
| MEDIUM | 6 | Spec inconsistencies or missing features with bounded impact |
| LOW | 5 | Minor gaps, naming issues, or future-scope items |

---

## CRITICAL Findings

### C1. Script does not parse — unescaped double-quote inside `glue()` string

**Code:** `lot_program.R:3223`
```r
-- Per map med.pdf page 5: "Pushout is not implemented" for medical.
```

**Problem:** This line is inside a `glue("...")` call that opens at line 3122. The literal `"` characters around `"Pushout is not implemented"` terminate the R string early, causing a parse error. The script cannot be sourced or executed.

**Spec:** N/A (syntax issue).

**Fix:** Escape the quotes (`\"`) or replace with single quotes inside the SQL comment.

---

### C2. Pharmacy claims with missing/invalid DAY_SUPPLY are deleted instead of defaulted to 28

**Code:** `lot_program.R:3063-3067`
```sql
filtered AS (
  SELECT *
  FROM enriched
  WHERE NOT (CLAIM_TYPE = 'pharmacy' AND (DAY_SUPPLY IS NULL OR DAY_SUPPLY < 1))
),
```

**Spec (mmamedapr14, row for DAY_SUPPLY):**
> "If CLAIM_TYPE_SOURCE=pharmacy and (DAY_SUPPLY_SOURCE < 1 or DAY_SUPPLY_SOURCE is missing), then consider 28 days supply."

**Protocol (Section 5.1.1):**
> "When pharmacy claims are missing days' supply, or when values are anomalous, a 28-day supply is assumed."

**Problem:** The spec and protocol both say to **impute 28 days** for pharmacy claims with missing or invalid DAY_SUPPLY. The code **removes these rows entirely** and even adds a post-filter assertion at line 3097 that stops execution if any survive.

**Impact:** Pharmacy claims without days supply data are lost. This undercounts medication exposure, shortens MAPs, and can cause false discontinuations.

---

### C3. Embedded medication rollup has only 8 of 28 unique medications from Tab 40

**Code:** `lot_program.R:225-246` — `embedded_mma_rollup()`

**Present in embedded (8):** BORT, CARF, IXAZ, LENA, POMA, DARA, DEXA, PRED

**Required by Tab 40 spec (28 unique abbreviations):**
BELA, BEND, BORT, CARF, CILT, CISP, CYCL, DARA, DOPL, DOXO, ELOT, ETOP, IDEC, ISAT, IXAZ, LENA, MELP, PANO, POMA, SELI, TECL, THAL, ELRA, LINV, TALQ, VENE, DEXA, PRED

**Missing from embedded (20):** BELA, BEND, CILT, CISP, CYCL, DOPL, DOXO, ELOT, ETOP, IDEC, ISAT, MELP, PANO, SELI, TECL, THAL, ELRA, LINV, TALQ, VENE

**Also missing from embedded codelist (line 251-268):** Only 6 code entries (2 HCPCS, 4 NDC). Tab 41 contains hundreds of HCPCS and NDC codes.

**Impact:** If CSV codelists are unavailable and `use_embedded_codes=TRUE`, the pipeline silently runs with ~29% of the required medications. Critical drugs like cyclophosphamide (CYCL), melphalan (MELP), thalidomide (THAL), and all CAR-T cell therapies (IDEC, CILT) are missed entirely.

---

### C4. Embedded rollup maintenance flags are incorrect vs Tab 40

**Code:** `lot_program.R:225-246`

| Medication | Embedded MONOMAINT | Spec MONOMAINT | Embedded DUALMAINT | Spec DUALMAINT |
|------------|-------------------|----------------|-------------------|----------------|
| BORT | 0 | YES | NULL | LENA |
| CARF | 0 | — | NULL | LENA |
| POMA | 1 | — (blank) | NULL | — |
| DARA | 0 | YES | NULL | — |
| LENA | 1 (correct) | YES | 'BORT' (partial) | BORT, CARF |

**Problem:** Multiple maintenance flags are wrong:
- BORT should be mono-maintenance=YES with dual partner LENA; embedded has 0/NULL
- CARF should have dual partner LENA; embedded has NULL
- POMA should NOT be mono-maintenance (blank in spec); embedded has 1
- DARA should be mono-maintenance=YES; embedded has 0
- LENA dual partner list is incomplete (missing CARF)

**Impact:** When maintenance logic is implemented, these flags will produce incorrect maintenance classification. Currently deferred because maintenance is not yet coded (see C5), but the embedded data is wrong for when it is.

---

### C5. Maintenance logic is not implemented despite being defined in the Apr 14 spec

**Code:** `lot_program.R:4037-4038`
```r
log_msg("NOTE: Maintenance (mono/dual) specs not yet provided; LOT1_BASE_END_REASON")
log_msg("      does not yet include MAINTENANCE_START. Will need integration when available.")
```

**Spec (lotbaseendapr14) defines these variables:**
- `LOT1_BASEMAINT_START` — Start date of maintenance period
- `LOT1_BASEMAINT_TYP` — Maintenance medication abbreviation
- `LOT1_BASEMAINT_END` — End date of maintenance period
- `LOT1_BASEMAINT_MED_[MED]` — Per-medication maintenance flags (BORT/DARA/IXAZ/LENA/CARF/THAL)
- `LOT1_BASEMAINT_END_REASON` — Maintenance end reason

**Protocol (Section 5.1.1) defines maintenance as:**
> "A maintenance regimen is a period of 120 days or longer during which only a valid maintenance therapy is available."

**Valid maintenance therapies (per NCCN/protocol):**
- Mono: lenalidomide, bortezomib, daratumumab, ixazomib, thalidomide
- Dual: bortezomib/lenalidomide, carfilzomib/lenalidomide, daratumumab/lenalidomide

**Problem:** The code loads MONOMAINTENANCE and DUALMAINTENANCEWITH from the rollup (lines 2756-2780) but never uses them. No maintenance period detection, no maintenance end reason, no maintenance variables are computed.

**Impact:** All maintenance-related output variables are missing. Downstream analyses that depend on maintenance classification cannot be performed. This also blocks correct implementation of Rules 4 and 8 (see C6 and H2).

---

### C6. Rule 4 not implemented: SCTs not followed by maintenance within 180 days should end LOT1

**Code:** `lot_program.R:3920-3928` (ENDING_AUTO_DT logic) and `lot_program.R:4002-4011` (LOT1_BASE_END_REASON)

**Protocol (Section 5.1.1, Rule 4):**
> "SCTs not followed by maintenance — if an SCT is not followed by a maintenance regimen within 180 days, then the last day of the LOT is the date of the SCT."

**Problem:** The code only ends LOT1 for excess AUTO events (2nd AUTO for single, 3rd for tandem), ALLO, or CAR-T. A single or tandem AUTO SCT that is NOT followed by valid maintenance within 180 days should also end LOT1 on the SCT date. This check is entirely absent.

**Impact:** Patients with a single/tandem AUTO SCT but no subsequent maintenance will have their LOT1 continue past the SCT date (ending on discontinuation or censoring instead), producing incorrect LOT1 end dates and end reasons.

---


## HIGH Findings

### H1. ENDDATE vs OBS_END_DT used inconsistently relative to specs

**Code locations:**
- MMA claim filter: `lot_program.R:2941-2946` uses `FST_DT <= OBS_END_DT`
- LOT1_BASE_DISCON_DT: `lot_program.R:3376` uses `datediff(p.OBS_END_DT, d.RAW_DISCON_DT) >= 90`
- LOT1_BASE_LENGTH censored: `lot_program.R:3454` uses `datediff(bc.OBS_END_DT, bc.LOT1_START_DT) + 1`
- LOT1_BASE_END_DT censored: `lot_program.R:4027` uses `lb.OBS_END_DT`

**Spec references:**
- MMA_MED spec (mmamedapr14): "Each claim/claim-line for a given patient must occur between the patient's index date and the patient's **ENDDATE** (inclusive)."
- LOT1_BASE spec (lot1baseapr14): "If ENDDATE - LOT1_BASE_DISCON_DT < 90 then set to missing." and "Otherwise set to **ENDDATE** - LOT1_START_DT + 1."
- LOT1_BASE_END spec (lotbaseendapr14): References **OBS_END_DT** in its additional notes.

**Problem:** The MMA_MED and LOT1_BASE specs explicitly say `ENDDATE` (which ignores disenrollment = min(death, study_end)). The code uses `OBS_END_DT` throughout (= coalesce(ENDDATE_CE, ENDDATE), which INCLUDES disenrollment). The LOT1_BASE_END spec does reference OBS_END_DT.

The code comment at lines 2899-2903 explains this was a deliberate choice: "Using ENDDATE would create fake follow-up after disenrollment." This is analytically defensible, but it deviates from the literal MMA_MED and LOT1_BASE spec text.

**Impact:** For disenrolled patients, the code produces shorter observation windows than the spec defines. This can cause:
- Fewer MMA claims captured (claims between disenrollment and death/study_end are excluded)
- LOT1_BASE_LENGTH is shorter for censored patients
- Some discontinuations may not be confirmed (< 90 days post-disenrollment)

**Recommendation:** Confirm with study team whether OBS_END_DT or ENDDATE is the intended boundary. If OBS_END_DT is correct, update the MMA_MED and LOT1_BASE specs to match.

---

### H2. LOT1_BASE_END_REASON categories do not match the spec's rule-based reasons

**Code:** `lot_program.R:4001-4016`

**Code produces these reasons:** `SCT_AUTO`, `SCT_ALLO`, `SCT_CART`, `SCT`, `MED_ADD`, `DISCONTINUATION`, `CENSORED`

**Spec (lotbaseendapr14 and protocol Rules 2-8) expects:**
- Rule 2: Discontinuation of all agents (with or without switch)
- Rule 3: Unplanned SCTs (AUTO > 180 days after previous)
- Rule 4: SCTs not followed by maintenance within 180 days
- Rule 5: Death
- Rule 6: Health plan disenrollment
- Rule 7: End of study period
- Rule 8: End of maintenance regimen

**Problem:** The code collapses death, disenrollment, and end-of-study into a single `CENSORED` bucket. Rules 4 and 8 are not implemented at all (maintenance dependency). The spec also defines `LOT1_END_DT_TEMP` and `LOT1_END_REASON_TEMP` as intermediate variables that are not computed.

**Impact:** Analytic summaries cannot distinguish between death, disenrollment, and administrative censoring as LOT1 end reasons. This limits the utility of the LOT1_BASE_END dataset for downstream analyses.

---

### H3. LOT1_BASE_LENGTH uses a 3-way calculation; spec defines only 2-way

**Code:** `lot_program.R:3448-3455`
```sql
CASE
  WHEN fa.LOT1_BASE_1ST_ADD_MED_DT IS NOT NULL
   AND (bc.LOT1_BASE_DISCON_DT IS NULL OR fa.LOT1_BASE_1ST_ADD_MED_DT <= bc.LOT1_BASE_DISCON_DT)
  THEN datediff(fa.LOT1_BASE_1ST_ADD_MED_DT, bc.LOT1_START_DT) + 1
  WHEN bc.LOT1_BASE_DISCON_DT IS NOT NULL
  THEN datediff(bc.LOT1_BASE_DISCON_DT, bc.LOT1_START_DT) + 1
  ELSE datediff(bc.OBS_END_DT, bc.LOT1_START_DT) + 1
END AS LOT1_BASE_LENGTH,
```

**Spec (lot1baseapr14, LOT1_BASE_LENGTH):**
> "If not missing(LOT1_BASE_DISCON_DT) then set to LOT1_BASE_DISCON_DT - LOT1_START_DT + 1. Otherwise if missing(LOT1_BASE_DISCON_DT) then set to ENDDATE - LOT1_START_DT + 1."

**Problem:** The spec defines LOT1_BASE_LENGTH with exactly 2 branches: discontinuation date or ENDDATE. The code adds a third priority branch for MED_ADD (first add-med date). This means LOT1_BASE_LENGTH can be shorter than what the spec defines when a new medication is added before discontinuation.

**Impact:** LOT1_BASE_LENGTH values will differ from spec for patients who have an add-med event. The LOT1_BASE_END_DT (which does account for MED_ADD in the spec) is the correct place for the 3-way logic — not LOT1_BASE_LENGTH itself.

---

### H4. Corticosteroid MAPs can trigger false first-add-med events and extend discontinuation dates

**Code:**
- `lot_program.R:3327-3341` — `lot1_induction_meds` has no steroid exclusion filter
- `lot_program.R:3355-3358` — Comment: "Steroid MAPs are included in base_meds"
- `lot_program.R:3413-3424` — `first_add_candidates` does not exclude steroids

**Protocol (Section 5.1.1):**
> "LOT1 regimen: Includes all MM therapies received within 60 days... excluding non-oncology agents such as corticosteroids."
> "Receipt of corticosteroids only (e.g., dexamethasone) will not be considered evidence of receiving an approved MM oncology therapy."

**LOT1_START_DT (line 3323):** Correctly excludes steroids (`MAP_MED_CLASS <> 'STEROID'`).

**Problem:** While LOT1 start correctly excludes steroids, the induction regimen identification does NOT. This means:
1. Steroids inflate LOT1_MED_CNT and appear in LOT1_BASE_MEDS
2. Steroid MAPs can extend LOT1_BASE_DISCON_DT (keeping LOT1 alive longer via steroid refills)
3. A steroid not in the induction window (e.g., PRED started after 60 days) could become a false first-add-med, incorrectly ending LOT1

**Note:** There is spec ambiguity. The lot1baseapr14 spec says "for all [MED]s" when defining LOT1_MED_[MED] flags, which could include steroids. But the protocol is clear that steroids are not oncology agents. At minimum, steroids should be excluded from `first_add_candidates` to prevent false LOT1 terminations.

---

### H5. Tandem SCT boundary check has spec-vs-protocol discrepancy

**Code:** `lot_program.R:3906`
```sql
AND datediff(ap.AUTO_DT_2, ap.AUTO_DT_1) + 1 <= {cfg$sct_tandem_days}
```
Where `cfg$sct_tandem_days = 180`.

**Programming spec (sctapr14):**
> `if (LOT1_TX_AUTO_DT_2 - LOT1_TX_AUTO_DT_1 + 1) >= 60 AND (LOT1_TX_AUTO_DT_2 - LOT1_TX_AUTO_DT_1 + 1) <= 180`

**Protocol:**
> "Patients classified as having a planned tandem SCT if they receive at least two autologous SCTs >= 60 to <= 180 days apart."

**Problem:** The code matches the programming spec formula (`datediff + 1 <= 180`), but the protocol says "180 days apart" which means `datediff <= 180` (no +1). With the +1, a pair exactly 180 days apart (datediff=180) evaluates as 181 <= 180 = FALSE, failing tandem classification.

**Impact:** Edge case — AUTO SCTs exactly 180 days apart are classified as non-tandem (unplanned), triggering an incorrect LOT1 termination. The programming spec and protocol disagree on this boundary.

---


## MEDIUM Findings

### M1. CAR-T consolidation therapy (45-day window) is not implemented

**Code:** No CAR-T consolidation logic found anywhere in the file.

**Protocol (Section 5.1.1):**
> "CAR-T cellular therapy infusions are classified as their own LOT. Therapies (including supportive agents, e.g., corticosteroids) given within 45 days of CAR-T cellular therapy are consolidated as part of the CAR-T LOT."

**Sensitivity email (Julia Moore):**
> "Confirming no one had a CAR-T event interrupt their LOT1? Because they are rolling up CAR-T with any new agent introduced within 45 days (was 30d) of a patient initiating CAR-T."

**Impact:** If a patient receives CAR-T during follow-up, therapies within 45 days should be grouped into the CAR-T LOT. Without this logic, those therapies may be incorrectly attributed to an adjacent LOT.

---

### M2. Codelist sourcing silently falls back to incomplete data without warning

**Code:** `lot_program.R:196-219` — `get_code_source()` priority chain: CSV > embedded > ref table

**Problem:** The fallback is silent. If CSVs are not found, the code logs `"CSV not found; using embedded codes"` but does not warn that the embedded codes cover a fraction of the full drug list. The `log_msg` is informational, not a warning or error.

**Impact:** In environments where CSVs are unavailable (e.g., local dev, broken mount), the pipeline runs with 8 of 28 medications and 6 of hundreds of drug codes, producing severely incomplete results with no prominent alert.

**Recommendation:** Add a validation step that checks the loaded codelist against a minimum expected count and fails loudly if the threshold is not met.

---

### M3. Missing spec-defined output variables from LOT1_BASE_END

**Spec (lotbaseendapr14) defines these variables that are not computed:**

| Variable | Description | Present in code? |
|----------|-------------|-----------------|
| `LOT1_END_DT_TEMP` | Temporary end date before final priority | No |
| `LOT1_END_REASON_TEMP` | Temporary end reason before final priority | No |
| `LOT1_TX_AUTO_FLG` | Binary flag: patient had any valid AUTO SCT | No |
| `LOT1_TX_AUTO_MAX_DT` | Latest valid AUTO SCT date (single or tandem) | No |
| `LOT1_BASEMAINT_*` | All maintenance variables (see C5) | No |

**Impact:** Downstream consumers expecting these variables will fail or produce incorrect joins. The LOT1_TX_AUTO_FLG and LOT1_TX_AUTO_MAX_DT are simple derivations from existing data and should be straightforward to add.

---

### M4. Permissible substitutions list is incomplete vs spec

**Code:** `lot_program.R:273-281` — `embedded_permissible_subs()`
```
DARA → DARA, BORT → IXAZ, IXAZ → BORT
```

**Spec (lot1baseapr14, LOT1_BASE_DISCON_DT notes):**
> "Permissible substitutions: Rituximab ↔ rituximab/hyaluronidase; Daratumumab ↔ daratumumab/hyaluronidase; Reference product ↔ biosimilar; Bortezomib induction ↔ ixazomib maintenance."

**Problem:** The embedded list only covers DARA self-substitution and BORT↔IXAZ. It is missing:
- daratumumab ↔ daratumumab_hyaluronidase (both map to DARA in Tab 40, so this may be handled by the common abbreviation — but only if the rollup maps both correctly)
- Generic reference product ↔ biosimilar substitutions (these would need to be specified per drug)
- Rituximab entries (rituximab is not in the MM rollup, so this may be N/A)

**Impact:** If external CSVs/ref tables cover these properly, the embedded fallback gap is deferred. But if embedded codes are used, some biosimilar switches could be incorrectly flagged as new agents ending LOT1.

---

### M5. Mesna exclusion is not explicitly implemented

**Code:** No reference to mesna found in the codebase.

**Protocol (Section 5.1):**
> "Excluded therapy: mesna (treatment of MM to protect the patient's bladder against the toxic side-effects of certain anticancer drugs)."

**Problem:** If mesna appears in the external codelist (it shouldn't per the spec, but if it does), it would be included in MMA extraction. There is no explicit exclusion filter.

**Impact:** Low if codelists are correct. But there is no defensive check. Recommend adding a comment or validation that mesna codes are not present in the loaded codelist.

---

### M6. med_procedure table removed from MMA extraction but comment is misleading

**Code:** `lot_program.R:2995-2998` (comment block where Subquery 4 was removed)
```r
-- Subquery 4: REMOVED - Optum med_procedure.PROC contains ICD procedure codes,
-- not HCPCS/NDC drug codes. The MMA codelist only has HCPCS and NDC codes.
```

**Business rules (optum business rules):**
> "Finding patients who took a drug of interest: PROC and FST_DT from T_MED_PROCEDURE for HCPCS/CPT codes."

**Problem:** The removal comment says med_procedure only has ICD codes, but the business rules doc says med_procedure can contain HCPCS/CPT codes. The med_procedure table IS used for SCT detection (line 3549-3578), where it matches both ICD and HCPCS codes. If the table can hold HCPCS for SCT codes, it may also hold HCPCS for drug administration codes.

**Impact:** Some drug administration claims captured only in med_procedure.PROC (as HCPCS) may be missed for MMA extraction while being correctly captured for SCT detection.

---

## LOW Findings

### L1. LOT2-LOT5 not implemented

**Protocol (Section 3):**
> "Objective: Develop a LOT algorithm to identify up to five LOTs for MM."

**Code:** Only LOT1 is implemented. Lines 4037-4038 acknowledge this.

**Impact:** Expected scope limitation. LOT2-5 requires LOT1 to be correct first.

---

### L2. Sensitivity analyses not implemented

**Protocol (Section 5.3):**
> "Sensitivity analyses will be conducted to further refine the algorithm" — varying CE requirements, look-back windows, alternative cohort definitions.

**Impact:** Expected scope limitation for initial build.

---

### L3. CYCLO monotherapy deep-dive (lines 2387-2702) is hardcoded to specific regimen strings

**Code:** `lot_program.R:2387-2702` — Section 11 uses `LOT1_BASE_MEDS = 'CYCL'` for strict cohort.

**Problem:** If cyclophosphamide codes are not in the loaded codelist (e.g., embedded fallback), this entire analysis produces zero results silently.

---

### L4. `sanitize_class` function referenced at line 3408 but defined as `sanitize_col`

**Code:** `lot_program.R:3408` references `sanitize_class` in the class flag column construction.

**Problem:** If `sanitize_class` is not defined (only `sanitize_col` is shown at line 2880), this would cause a runtime error. Need to verify whether `sanitize_class` is defined elsewhere or if this is a typo for `sanitize_col`.

---

### L5. Dashboard/descriptive sections (lines 327-2706) are extensive but not spec-defined

**Code:** ~2400 lines of dashboard, plotting, and CYCLO analysis code.

**Impact:** Not a spec compliance issue. These are QC/reporting features. However, they comprise >55% of the file and make the core pipeline logic harder to review and maintain.

---

## Cross-Reference: Other Agent Review Verification

The following table validates each finding from the separate agent review:

| Other Agent Finding | Verified? | Notes |
|---|---|---|
| 1. Parse error (unescaped quote in glue) | **YES** | Line 3223 inside glue() at 3122. Confirmed blocking. See C1. |
| 2. Maintenance not implemented | **YES** | Line 4037 acknowledges. Spec defines it. See C5. |
| 3. Rule 4 missing (SCT + no maintenance) | **YES** | No 180-day post-SCT maintenance check. See C6. |
| 4. Corticosteroids in regimen | **PARTIALLY** | LOT1_START_DT excludes steroids correctly. But induction_meds, base_meds, and first_add do NOT exclude them. Spec is ambiguous on inclusion in LOT1_BASE_MEDS but protocol says exclude from regimen. See H4. |
| 5. Pharmacy DAY_SUPPLY filter vs default | **YES** | Spec says impute 28; code deletes. See C2. |
| 6. Tandem off-by-one at 180-day boundary | **PARTIALLY** | Code matches programming spec formula (with +1). Protocol says "days apart" (without +1). This is a spec-vs-protocol discrepancy, not strictly a code bug. See H5. |
| 7. END_REASON doesn't match spec | **YES** | CENSORED collapses death/disenroll/study-end. Rules 4,8 missing. See H2. |
| 8. Codelist fallback is silent | **YES** | Embedded data covers ~29% of medications. See M2 and C3. |

---

## Appendix A: Full Medication Coverage Gap (Embedded vs Tab 40)

| # | CL_MEDICATION_FULL | CL_MED_CLASS | CL_MED_ABBR | In Embedded? | CONDITIONING | OTHER_CANCERS |
|---|---|---|---|---|---|---|
| 1 | belantamab | ABCMA | BELA | NO | — | — |
| 2 | bendamustine | MUSTARD | BEND | NO | — | YES |
| 3 | bortezomib | PROTINHIB | BORT | YES | — | — |
| 4 | carfilzomib | PROTINHIB | CARF | YES | — | — |
| 5 | cilta-cabtagene | ATCELL | CILT | NO | — | — |
| 6 | cisplatin | PLAT | CISP | NO | — | YES |
| 7 | cyclophosphamide | MUSTARD | CYCL | NO | YES | YES |
| 8 | daratumumab | ACD38 | DARA | YES | — | — |
| 9 | daratumumab_hyaluronidase | ACD38 | DARA | NO* | — | — |
| 10 | doxorubicin_peg_lip | TOPOINHIB | DOPL | NO | — | YES |
| 11 | doxorubicin | TOPOINHIB | DOXO | NO | — | YES |
| 12 | elotuzumab | ASLAMF7 | ELOT | NO | — | — |
| 13 | etoposide | TOPOINHIB | ETOP | NO | — | YES |
| 14 | idecabtagene | ATCELL | IDEC | NO | — | — |
| 15 | isatuximab | ACD38 | ISAT | NO | — | — |
| 16 | ixazomib | PROTINHIB | IXAZ | YES | — | — |
| 17 | lenalidomide | IMMUNOMOD | LENA | YES | — | YES |
| 18 | melphalan (4 variants) | MUSTARD | MELP | NO | YES | — |
| 19 | panobinostat | HIST | PANO | NO | — | — |
| 20 | pomalidomide | IMMUNOMOD | POMA | YES | — | — |
| 21 | selinexor | NUCLEAR | SELI | NO | — | YES |
| 22 | teclistamab | ABCMA | TECL | NO | — | — |
| 23 | thalidomide | IMMUNOMOD | THAL | NO | — | YES |
| 24 | elranatamab | ABCMA | ELRA | NO | — | — |
| 25 | linvoseltamab | ABCMA | LINV | NO | — | — |
| 26 | talquetamab | IMMUNOMOD | TALQ | NO | — | — |
| 27 | venetoclax | BLC2I | VENE | NO | — | YES |
| 28 | dexamethasone | STEROID | DEXA | YES | — | — |
| 29 | prednisone | STEROID | PRED | YES | — | — |

*daratumumab_hyaluronidase shares abbreviation DARA with daratumumab but has its own codelist entries.

---

## Appendix B: Recommended Fix Priority

| Priority | Finding | Effort |
|----------|---------|--------|
| 1 (blocker) | C1 — Fix parse error | Minutes |
| 2 | C2 — Change pharmacy DAY_SUPPLY filter to imputation | Small |
| 3 | H4 — Exclude steroids from first_add_candidates at minimum | Small |
| 4 | H1 — Decide ENDDATE vs OBS_END_DT with study team | Decision |
| 5 | H3 — Fix LOT1_BASE_LENGTH to 2-way per spec | Small |
| 6 | H2 — Expand CENSORED into DEATH/DISENROLL/STUDY_END | Medium |
| 7 | C3/C4 — Update embedded rollup and codelist | Medium |
| 8 | M2 — Add codelist validation / fail-loud on insufficient coverage | Small |
| 9 | C5/C6 — Implement maintenance logic | Large |
| 10 | M1 — Implement CAR-T consolidation | Medium |
| 11 | M3 — Add missing output variables | Small |
| 12 | H5 — Resolve tandem boundary with study team | Decision |

---

*Review completed: 2026-04-15*
*Reviewer: Claude Code automated analysis*
*Status: DO NOT MODIFY CODE — issues list only*
