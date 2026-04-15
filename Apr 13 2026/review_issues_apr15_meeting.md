# LOT Program Review — Issues & Action Items
## Based on Apr 15, 2026 Meeting Minutes, LOT Output (Apr 14), and Code Review

**Date:** April 15, 2026
**Reviewed by:** Code review agent
**Files reviewed:**
- `Apr 13 2026/meeting minutes apt 15` (meeting transcript)
- `Apr 13 2026/lot output apr 14.pdf` (current run output)
- `Apr 13 2026/Protocol/Lot protocol Apr 13.pdf` (protocol v6)
- `Apr 13 2026/Program/lot_program.R` and all R/ modules
- `Apr 13 2026/Program Spec and Scenarios/*.pdf` (all spec tabs)
- `Apr 13 2026/Attrition/attritiom apr 14.pdf`
- `Apr 13 2026/codelist.pdf`
- `Apr 13 2026/sensitivity cbecks.pdf`

---

## CRITICAL ISSUES (Must Fix Before Next Meeting — Apr 23)

### ISSUE 1: MAINTENANCE_END Reason Must Be Reclassified to DISCONTINUATION
- **Source:** Meeting transcript — Julia stated that patients ending LOT1 on a valid maintenance regimen should just be classified as "discontinued" since maintenance is not being defined for this study.
- **Current code:** `lot_program.R` line 1863 — `THEN 'MAINTENANCE_END'` is a standalone end reason category in the CASE logic (Rule 8).
- **What needs to change:** Replace `'MAINTENANCE_END'` with `'DISCONTINUATION'` at line 1863, or remove the MAINTENANCE_END branch entirely and let these patients fall through to the DISCONTINUATION case at line 1865.
- **Impact:** Affects the LOT1_BASE_END_REASON distribution in the dashboard and all downstream reporting. The end-reason bar chart and table will change.
- **Priority:** HIGH — Julia specifically flagged this as needing cleanup before the Apr 23 meeting with Vicky.

### ISSUE 2: SCT_NO_MAINT Category Needs Reclassification
- **Source:** Meeting transcript — Julia said "those also need to probably get reclassified" and mentioned they should become either "new agent introduced" or "3rd or unplanned autologous happening."
- **Current code:** `lot_program.R` lines 1850-1853 — `THEN 'SCT_NO_MAINT'` is its own end reason. The flag is set at lines 1797-1805 when a patient has an autologous SCT but no maintenance follows within 180 days and no other SCT/ALLO/CART events exist.
- **What needs to change:** Since maintenance is being removed as a defining concept, the SCT_NO_MAINT logic needs revisiting. These patients had a planned autologous SCT — without the maintenance requirement, they should likely be classified as `'SCT_AUTO'` (continuation of LOT1 with autologous SCT). The distinction between "SCT with maintenance" and "SCT without maintenance" becomes moot if maintenance is not being defined.
- **Impact:** The SCT_NO_MAINT row in the end-reason distribution will be redistributed. This also affects the LOT1_BASE_END_DT calculation at lines 1877-1880.
- **Priority:** HIGH — Directly linked to Issue 1 (maintenance decision).

### ISSUE 3: MED_ADD Near CAR-T Should Be Reclassified as CART_INIT
- **Source:** Meeting transcript — Julia stated: "if someone has a new medication added, but then within 45 days of that new agent, they're starting CAR-T, their reason for LOT1 end shouldn't be a medication add. It actually should be initiation of CAR-T therapy."
- **Current code:** `lot_program.R` lines 1819-1829 — `CART_CONSOL_FLG` is set when MED_ADD is within 45 days of CART (`cart_consolidation_days = 45` in config_lot.R line 59). When CART_CONSOL_FLG=1, MED_ADD is suppressed at line 1856.
- **Gap:** The code suppresses MED_ADD correctly but does NOT create a new end reason `'CART_INIT'` or `'INITIATION_OF_CART'`. When CART_CONSOL_FLG=1, the MED_ADD branch is skipped and the patient falls through to the next applicable reason (MAINTENANCE_END, DISCONTINUATION, DEATH, etc.), which is incorrect.
- **What needs to change:** Add a new CASE branch between SCT_NO_MAINT and MED_ADD (around line 1854) that catches `CART_CONSOL_FLG = 1` and assigns `'CART_INIT'` as the end reason with `FIRST_CART_DT` as the end date.
- **Note:** Julia also said "that's kind of getting into defining LOT2" so this may be deferred, but the logic gap should be documented and flagged.
- **Priority:** HIGH — Logic gap produces incorrect end reasons for affected patients.

---

## HIGH PRIORITY ISSUES (Fix This Sprint)

### ISSUE 4: New Maintenance Regimen Flag Missing from Final Dataset
- **Source:** Meeting transcript — Julia described a new flag needed in the final dataset: "I added this flag, the very last row, for the maintenance... if someone has any combination of these things, but they have to have an anchor agent included."
- **Current code:** `lot_program.R` lines 1442-1458 — The CTE `valid_maint_regimens` already computes which patients have valid mono or dual maintenance regimens as part of their induction. However, this information is NOT surfaced as a column in the final `lot1_base_end` output.
- **What needs to change:** Add a binary flag (e.g., `LOT1_HAS_VALID_MAINT_REGIMEN`) to the `lot1_maintenance` view output (around line 1710) and propagate it through to `lot1_base_end`. The flag should be 1 if the patient's LOT1 induction regimen contains at least one valid maintenance regimen (mono or dual), 0 otherwise.
- **Definition per meeting:** A valid maintenance regimen requires:
  - A non-maintenance medication (anchor agent) linked with a maintenance medication
  - When the non-maintenance medication falls away, the maintenance medication remains
  - For regimens like DARA+LEN+BORT (3 valid maintenance drugs), you need a qualifying anchor agent to know when maintenance starts
- **Protocol reference:** Protocol v6 Section 5.1.1 — maintenance regimen definition; also described in the spec Tab 40 (last row added by Julia).
- **Priority:** HIGH — Julia specifically asked for sign-off on this flag.

### ISSUE 5: Top 15/25 Induction Regimen Table Not Refreshed
- **Source:** Meeting transcript — Julia noted "this table didn't get updated for some reason" referring to the induction regimen counts. She said one table still had "whole numbers" while another was updated.
- **Current code:** `R/descriptives_lot.R` lines 577-628 — The Top 25 regimen query pulls from `lot1_base_end` and the Figure 5 (Top 15 bar chart) includes both counts and percentages.
- **Issues found in code:**
  1. The saved table (`save_table` at line 627) does NOT include a percentage column — only `regimen`, `n_patients`, `avg_length`, `avg_meds`. The percentage is calculated on-the-fly for the chart but not persisted.
  2. The dashboard may be showing a cached/stale version if not refreshed after the latest run.
- **What needs to change:**
  1. Add a `pct` column to the saved regimen table: `regimens$pct <- round(100 * regimens$n_patients / total_lot1, 1)` before the `save_table()` call.
  2. Ensure the dashboard link is refreshed and shared with Julia before the Apr 23 meeting.
- **Priority:** HIGH — Julia specifically asked for an updated dashboard before her Vicky meeting.

### ISSUE 6: Dual Maintenance Combinations — Codelist Verification Needed
- **Source:** Meeting transcript — Discussion about adding Lenalidomide (LENA) to dual maintenance columns with Daratumumab (DARA), and confirming Thalidomide (THAL) as mono maintenance. Onker added LENA to the spec and Julia confirmed alignment.
- **Current code:** `lot_program.R` lines 1410-1436 — The maintenance logic correctly reads `MONOMAINTENANCE` and `DUALMAINTENANCEWITH` columns from the `mma_rollup` CSV. The code supports flexible combinations.
- **What needs to be verified in `cl_mma_rollup.csv`:**
  1. DARA row: `DUALMAINTENANCEWITH` should include `'LENA'`
  2. LENA row: `DUALMAINTENANCEWITH` should include `'DARA, BORT, CARF'` (all valid dual partners)
  3. THAL row: `MONOMAINTENANCE` should be `1`
  4. CARF row: `DUALMAINTENANCEWITH` should include `'LENA'`
  5. BORT row: `DUALMAINTENANCEWITH` should include `'LENA'`
- **Cross-reference:** Protocol v6 Section 5.1.1 lists valid maintenance therapies:
  - Mono: LENA, BORT, DARA, IXAZ, THAL
  - Dual: BORT/LENA, CARF/LENA, DARA/LENA
- **Priority:** HIGH — Incorrect codelist = incorrect maintenance detection. Julia signed off on the additions during the meeting.

---

## MEDIUM PRIORITY ISSUES (Plan for Next Iteration)

### ISSUE 7: LOT2-5 Implementation — Not Yet Started
- **Source:** Meeting transcript — Julia confirmed LOT2-5 spec will be based on the LOT1 spec with key differences. She offered to start the LOT2-5 spec or have Onker do it after finishing LOT1 cleanup.
- **Current code:** Zero LOT2-5 logic exists. The program only builds LOT1_BASE, LOT1_SCT, LOT1_MAINTENANCE, and LOT1_BASE_END. No LOT2, LOT3, LOT4, LOT5 views/tables.
- **Key differences from LOT1 per meeting and protocol:**
  1. **Induction window:** 30 days (vs. 60 days for LOT1) — `config_lot.R` line 40 currently hardcodes 60
  2. **LOT start triggers:** LOT2+ can start with CAR-T event, allogeneic SCT, or autologous SCT (in addition to new agent)
  3. **Iterative structure:** Each subsequent LOT's start depends on the previous LOT's end, requiring a loop or recursive CTE
- **Protocol reference:** Protocol v6 Section 5.1.1 — "Second-line and later LOTs (LOT2-LOT5)"
- **Action items:**
  1. Julia to share old LOT2-5 spec from Optum (noted in meeting — she couldn't find it during the call)
  2. Onker to finish LOT1 cleanup by end of week
  3. Start LOT2-5 spec next week
- **Priority:** MEDIUM — Blocked on LOT1 cleanup; Julia noted "LOT1 won't really make sense until you have your other LOTs."

### ISSUE 8: Bendamustine (BEND) — Not Approved in 1st Line
- **Source:** Meeting transcript — Peter (medical consultant) flagged that Bendamustine is not approved in 1st line and found it odd that some patients had it.
- **Current code:** No special handling for Bendamustine. If BEND is in the codelist, it's treated like any other MM therapy.
- **What needs to change:** Add an informational flag or report patients with Bendamustine in LOT1 induction. This is a data quality/clinical review item, not necessarily a code fix.
- **Suggested approach:** Add to descriptives — flag patients with BEND in LOT1_BASE_MEDS and report count. May also want to cross-check with LOT2+ once implemented (BEND is expected in later lines).
- **Priority:** MEDIUM — Awaiting a more comprehensive list from Peter before deep-diving into patient examples.

### ISSUE 9: Daratumumab + Pomalidomide — Typically 2nd Line Combination
- **Source:** Meeting transcript — Peter flagged that Daratumumab + Pomalidomide (DARA+POM) is typically a 2nd-line combination.
- **Current code:** No reference to Pomalidomide (POMA/POM) found in lot_program.R. If it's in the codelist, it gets included without any line-specific restrictions.
- **What needs to change:** Similar to BEND — flag patients with DARA+POM in LOT1 as potentially unusual 1st-line use. No code change needed now; this is a clinical review flag.
- **Priority:** MEDIUM — Part of the broader patient-example review Peter will provide.

### ISSUE 10: Cyclophosphamide Monotherapy — Patient Examples & Transplant Follow-up
- **Source:** Meeting transcript — Discussion about cyclophosphamide (CYCLO) monotherapy patients and their subsequent transplant status. Onker prepared CSV files with patient details and transplant dates.
- **Current code:** `R/cyclo_appendix_lot.R` — A dedicated deep-dive module (321 lines) already exists for CYCLO monotherapy analysis, including dx-date sensitivity and post-CYCLO treatment patterns.
- **Status:** PARTIALLY ADDRESSED — The CYCLO deep-dive module exists and produces CSVs. Onker has the patient-level files ready to share.
- **Action items:**
  1. Share CYCLO patient CSVs with Julia (via Domino project, not email, due to patient IDs)
  2. Julia to review and potentially cross-reference with Peter's other drug flags
  3. Peter also flagged another drug (not captured clearly in transcript — possibly JVM?) for similar review
- **Priority:** MEDIUM — Patient examples are informational, not blocking LOT1 logic.

---

## LOW PRIORITY / INFORMATIONAL ISSUES

### ISSUE 11: Attrition Table — Review of Patient Counts
- **Source:** `Apr 13 2026/Attrition/attritiom apr 14.pdf` (reviewed via PNG)
- **Attrition flow (90-day cohort):**
  | Step | Description | N | % |
  |------|-------------|---|---|
  | Starting Population | >= 1 medical claim for MM | 94,951 | 100.0% |
  | Inclusion 1 | >= 1 IP or >= 2 OP claims within 90 days | 70,866 | 74.6% |
  | Inclusion 2 | Age >= 18 in index year | 70,842 | 74.6% |
  | Inclusion 3 | >= 6 months CE baseline | 62,846 | 66.2% |
  | Inclusion 4 | >= 1 day CE follow-up | 62,843 | 66.2% |
  | Exclusion 5 | No MM therapy in baseline | 53,081 | 55.9% |
  | Inclusion 6 | Evidence of MM therapy in follow-up | 21,512 | 22.7% |
- **Observations:**
  1. The 30-day and 60-day cohort columns are also present (sensitivity analyses per protocol Section 4.2.1)
  2. Counts appear consistent across cohort definitions
  3. No anomalies detected in the attrition flow
- **Priority:** LOW — Informational only. Attrition looks reasonable.

### ISSUE 12: Embedded Codelist Fallbacks — Already Flagged in Optimization Report
- **Source:** `lot_program_optimization_report.md` Section 6
- **Current status:** The modularized code (`lot_program.R` + `R/*.R`) has already removed embedded codelist fallbacks and uses CSV-only loading (config_lot.R line 50-51).
- **Priority:** LOW — Already resolved in current codebase.

### ISSUE 13: Protocol v6 Finalization
- **Source:** Meeting transcript — Julia confirmed protocol v6 is finalized. She asked Vicky to read it once more but said "there shouldn't be any more changes."
- **Action:** Ensure all code parameters align with protocol v6 definitions. Key parameters verified:
  - Induction window: 60 days (LOT1) ✓ (config_lot.R line 40)
  - Maintenance minimum: 120 days ✓ (config_lot.R line 46)
  - Post-SCT maintenance minimum: 30 days ✓ (config_lot.R line 47)
  - SCT maintenance window: 180 days ✓ (config_lot.R line 48)
  - Tandem SCT: 60-180 days apart ✓ (config_lot.R lines 55-56)
  - CART consolidation: 45 days ✓ (config_lot.R line 59)
  - Medical day supply assumed: 28 days ✓ (config_lot.R line 43)
  - MAP discontinuation gap: 90 days ✓ (config_lot.R line 42)
- **Priority:** LOW — Protocol is aligned with code parameters.

### ISSUE 14: Spec Comments — Onker's Additions Signed Off
- **Source:** Meeting transcript — Julia reviewed Onker's comments on the spec tabs (particularly Tab 40 for maintenance drugs). Julia signed off on:
  1. Adding LENA to DARA dual maintenance column
  2. Adding THAL as mono maintenance
  3. Updated statement language in spec comments
- **Action:** Ensure these spec changes are reflected in `cl_mma_rollup.csv` (see Issue 6).
- **Priority:** LOW — Sign-offs obtained; just needs codelist verification.

---

## LOT OUTPUT (APR 14) — OBSERVATIONS

The LOT output PDF could not be rendered directly (poppler-utils not installed), but based on meeting discussion and code review:

### Dashboard Items Discussed:
1. **End-reason distribution** — Julia reviewed this during the meeting and flagged MAINTENANCE_END and SCT_NO_MAINT as needing reclassification (Issues 1 & 2)
2. **Top 15 induction regimens** — One table not updated (Issue 5). Julia noted the numbers seemed correct when she recalculated manually by summing individual medication counts
3. **SCT descriptives** — Julia confirmed these were fixed ("I have fixed it up")
4. **Maintenance descriptives** — Need updating after maintenance decision change

### Numbers Referenced in Meeting:
- BORT induction: ~4,934 patients
- Multiple regimen combinations adding up to ~14,000 patients on BORT-containing regimens
- Total LOT1 patients with certain medication combos: ~440,000 claims (combined)
- These numbers were deemed consistent with expectations after manual verification

---

## ACTION ITEMS SUMMARY

### Before Apr 23 Meeting (with Vicky):
| # | Action | Owner | Issue Ref |
|---|--------|-------|-----------|
| 1 | Reclassify MAINTENANCE_END to DISCONTINUATION | Dev | Issue 1 |
| 2 | Reclassify SCT_NO_MAINT (likely to SCT_AUTO) | Dev | Issue 2 |
| 3 | Fix CART_CONSOL gap — add CART_INIT end reason | Dev | Issue 3 |
| 4 | Add LOT1_HAS_VALID_MAINT_REGIMEN flag | Dev | Issue 4 |
| 5 | Add pct column to Top 25 regimen saved table | Dev | Issue 5 |
| 6 | Verify cl_mma_rollup.csv dual maintenance entries | Dev | Issue 6 |
| 7 | Refresh dashboard and share updated link with Julia | Dev | Issue 5 |

### Next Sprint (Post-Apr 23):
| # | Action | Owner | Issue Ref |
|---|--------|-------|-----------|
| 8 | Start LOT2-5 spec (copy LOT1 anchor version, update window to 30 days) | Dev/Julia | Issue 7 |
| 9 | Add BEND/DARA+POM flags to descriptives when patient list from Peter arrives | Dev | Issues 8, 9 |
| 10 | Share CYCLO patient CSVs via Domino project | Dev | Issue 10 |
| 11 | Julia to send old LOT2-5 spec from Optum | Julia | Issue 7 |
| 12 | Julia to reshare protocol v6 link | Julia | Issue 13 |

---

## CODE LOCATIONS REFERENCE

| Component | File | Lines |
|-----------|------|-------|
| LOT1 end reason CASE logic | `lot_program.R` | 1836-1870 |
| LOT1 end date CASE logic | `lot_program.R` | 1872-1892 |
| SCT_NO_MAINT flag | `lot_program.R` | 1797-1818 |
| CART_CONSOL_FLG | `lot_program.R` | 1819-1829 |
| Maintenance detection (S16a) | `lot_program.R` | 1392-1763 |
| Maintenance output columns | `lot_program.R` | 1710-1753 |
| valid_maint_regimens CTE | `lot_program.R` | 1442-1458 |
| Top 25 regimen table | `R/descriptives_lot.R` | 577-628 |
| Configuration parameters | `R/config_lot.R` | 15-75 |
| CYCLO deep-dive | `R/cyclo_appendix_lot.R` | (full file) |
| End reason distribution print | `R/descriptives_lot.R` | 555-575 |

---

*This document is for internal review only. No code changes have been made.*
*Generated: April 15, 2026*
