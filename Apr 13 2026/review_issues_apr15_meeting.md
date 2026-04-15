# LOT Program Review — Issues & Action Items (Combined & Validated)
## Based on Apr 15, 2026 Meeting Minutes, Apr 14 LOT Output, Protocol v6, and Code Review

**Date:** April 15, 2026
**Review type:** Static review only. No code changes made.
**Files reviewed:**
- `Apr 13 2026/meeting minutes apt 15` (meeting transcript)
- `Apr 13 2026/lot output apr 14.pdf` (current run output)
- `Apr 13 2026/Protocol/Lot protocol Apr 13.pdf` (protocol v6)
- `Apr 13 2026/Program/lot_program.R` and all `R/` modules
- `Apr 13 2026/Program Spec and Scenarios/*.pdf` (all spec tabs)
- `Apr 13 2026/Attrition/attritiom apr 14.pdf`
- `Apr 13 2026/codelist.pdf`
- `Apr 13 2026/sensitivity cbecks.pdf`

---

## Executive Summary

The Apr 15 meeting introduces one major **study-level change** that is NOT yet reflected in the current LOT code:

- The team decided **not to define a maintenance period / maintenance LOT for this study**.
- Instead, they want a **flag only** (`contains_mtx_reg`) indicating whether the LOT1 induction regimen contains a valid maintenance-approved regimen with an anchor agent.

The current code still implements full maintenance-period derivation and still uses that logic to drive:
- `MAINTENANCE_END` as an end reason
- `SCT_NO_MAINT` as an end reason (Rule 4)
- `LOT1_BASEMAINT_*` variables (start, end, type, per-drug flags)
- Rule 4 / Rule 8 end-reason behavior in `LOT1_BASE_END_REASON`

The Apr 14 output still reflects the older maintenance-driven logic. **The main work is not dashboard polish — it is a substantive realignment of LOT1 end-reason logic and final outputs to the Apr 15 meeting decision.**

---

## CRITICAL ISSUES

### ISSUE 1: Remove maintenance-period logic from LOT1 end derivation — study now wants flag-only approach

**Severity:** Critical
**Source:** Meeting transcript + updated spec (`lotbaseendapr14.pdf` tab, field `contains_mtx_reg`)

**The Apr 15 meeting explicitly changes the study approach:**

Julia stated (verbatim from transcript):
- "we're just going to add a flag for the inclusion of if a regimen is included, if a valid maintenance regimen is included in part of the induction medication"
- "I took out all of the maintenance language from our protocol, and I moved it to the limitations section"
- "we're not going to define it for this study"
- "we're not trying to define the time and length of maintenance because it's quite messy"

This is NOT a simple rename from MAINTENANCE_END to DISCONTINUATION. It is a structural change: the entire maintenance-period engine should stop driving LOT1 end-reason logic.

**Current code still does the opposite:**
- `lot_program.R:1392-1763` (S16a) — Builds full maintenance detection: `LOT1_BASEMAINT_START`, `LOT1_BASEMAINT_END`, `LOT1_BASEMAINT_END_REASON`, per-drug flags, `MAINT_FOLLOWS_SCT_FLG`
- `lot_program.R:1765-1916` (S16) — Gives maintenance formal priority in `LOT1_BASE_END_REASON` (Rule 8), `LOT1_BASE_END_DT`, and `LOT1_BASE_LENGTH`

**What needs to change:**
- Retire maintenance-period outputs as LOT-ending constructs
- Stop using `LOT1_BASEMAINT_END`, `LOT1_BASEMAINT_END_REASON`, `MAINT_FOLLOWS_SCT_FLG` in the `LOT1_BASE_END_REASON` CASE logic (lines 1860-1863, 1885-1888, 1914-1916)
- The underlying maintenance-detection CTEs (`valid_maint_regimens`, `maint_eligible`, etc.) can be repurposed for computing the new `contains_mtx_reg` flag, but should NOT feed into end-reason determination
- Patients currently classified as `MAINTENANCE_END` should fall through to `DISCONTINUATION` or applicable censoring reason

### ISSUE 2: Add the new final dataset flag `contains_mtx_reg`

**Severity:** Critical
**Source:** Meeting transcript + updated spec (`lotbaseendapr14.pdf`, last row added by Julia)

The updated spec explicitly asks for a new flag: `contains_mtx_reg`. The meeting transcript confirms this in plain language — add a flag if LOT1 induction contains a valid maintenance regimen with an anchor agent.

**Definition per meeting and protocol:**
- A valid maintenance regimen requires a non-maintenance medication (anchor agent) linked with a maintenance medication
- When the non-maintenance medication falls away, the maintenance medication remains — that defines the theoretical maintenance start
- For regimens with multiple valid maintenance drugs (e.g., DARA+LEN+BORT, which are all 3 valid maintenance), you need a qualifying anchor agent to distinguish what would be the maintenance regimen
- The flag is NOT about whether maintenance actually occurred — it's about whether the induction regimen *contains* a valid maintenance combination

**Valid maintenance therapies (per protocol v6 Section 5.1.1 and Tab 40):**
- Mono: LENA, BORT, DARA, IXAZ, THAL
- Dual: BORT/LENA, CARF/LENA, DARA/LENA

**Current code:**
- No `contains_mtx_reg` output exists anywhere in `lot_program.R`
- The CTE `valid_maint_regimens` (lines 1442-1458) already computes which patients have valid mono or dual maintenance regimens, but this is NOT surfaced as a column in the final output

**What needs to change:**
- Derive `contains_mtx_reg` from the existing `valid_maint_regimens` CTE logic
- The flag should be 1 if the LOT1 induction regimen contains at least one valid maintenance regimen (mono or dual) AND has an anchor agent (at least one non-maintenance drug also in the induction), 0 otherwise
- Add to the final `lot1_base_end` persisted output

---

### ISSUE 3: `SCT_NO_MAINT` should no longer be a separate LOT1 end reason

**Severity:** High
**Source:** Meeting transcript

**Current code:**
- `lot_program.R:1797-1818` — Builds `LOT1_SCT_NO_MAINT_FLG` and `SCT_NO_MAINT_END_DT`
- `lot_program.R:1850-1853` — Sets `LOT1_BASE_END_REASON = 'SCT_NO_MAINT'`

**Meeting discussion (Julia, verbatim):**
- "SCT no maintenance — I think those also need to probably get reclassified"
- "those are all autologous transplant people"
- "they're probably all going to be SCT auto this time"

**Why this must change:**
Once maintenance is no longer formally defined for the study, the distinction between "SCT with maintenance" and "SCT without maintenance" becomes meaningless. Rule 4 (planned SCT not followed by maintenance within 180 days) was predicated on maintenance being a defined concept.

**What needs to change:**
- Remove `SCT_NO_MAINT` from the end-reason CASE logic (lines 1850-1853)
- Reclassify these patients using the remaining SCT logic — most likely `SCT_AUTO` since they had a planned autologous SCT
- Remove or simplify `LOT1_SCT_NO_MAINT_FLG` and `SCT_NO_MAINT_END_DT` (lines 1797-1818)

---

### ISSUE 4: `MAINTENANCE_END` should no longer be a separate LOT1 end reason

**Severity:** High
**Source:** Meeting transcript

This is a direct consequence of Issue 1. The current code at lines 1860-1863 sets:
```
THEN 'MAINTENANCE_END'
```

**Meeting discussion (Julia):**
- "if those people are not having another medication added, I think that we would just say that they're discontinued"

**What needs to change:**
- Remove the `MAINTENANCE_END` branch from the end-reason CASE logic (line 1863)
- These patients should fall through to `DISCONTINUATION` (line 1865) or applicable censoring reasons (DEATH, DISENROLLMENT, STUDY_END)
- Also remove the corresponding end-date branch (lines 1885-1888) and length branch (lines 1914-1916)

### ISSUE 5: CAR-T 45-day reclassification — directionality mismatch in code vs. meeting

**Severity:** High
**Source:** Meeting transcript + code review

**Meeting requirement (Julia, verbatim):**
- "if someone has a new medication added, but then within 45 days of that new agent, they're starting CAR-T, their reason for LOT1 end shouldn't be a medication add. It actually should be initiation of CAR-T therapy."

This describes: **MED_ADD happens first → CAR-T within 45 days after**

**Current code (lot_program.R lines 1823-1829):**
```sql
CASE
  WHEN sct.FIRST_CART_DT IS NOT NULL
   AND lb.LOT1_BASE_1ST_ADD_MED_DT IS NOT NULL
   AND datediff(date_add(lb.LOT1_BASE_1ST_ADD_MED_DT, 1), sct.FIRST_CART_DT)
       BETWEEN 0 AND {cfg$cart_consolidation_days}
  THEN 1
  ELSE 0
END AS CART_CONSOL_FLG
```

`datediff(A, B)` in Databricks = A - B. So this expression is:
- `(ADD_MED_DT + 1) - CART_DT BETWEEN 0 AND 45`
- True when ADD_MED_DT is 0-45 days **AFTER** CART_DT

This captures: **CAR-T happens first → MED_ADD within 45 days after** (the opposite direction).

**Two distinct issues:**

1. **Direction mismatch:** The code handles CART→MED_ADD (new med after CART is consolidation therapy). The meeting describes MED_ADD→CART (new med before CART should be reclassified as CART initiation). These are different scenarios.

2. **Missing end reason:** Even when CART_CONSOL_FLG=1, the code only *suppresses* MED_ADD (line 1856: `AND ec.CART_CONSOL_FLG = 0`). It does NOT create a positive `CART_INIT` end reason. The patient falls through to other reasons instead.

**What needs to change:**
- Add logic for the meeting's direction: if MED_ADD date is before FIRST_CART_DT and `datediff(FIRST_CART_DT, ADD_MED_DT) BETWEEN 0 AND 45`, flag it
- Add a new end reason `CART_INIT` (or similar) in the CASE logic with FIRST_CART_DT as the end date
- Clarify with Julia whether BOTH directions should be handled, or only the meeting's direction
- **Note:** Julia acknowledged "that's kind of getting into defining LOT2" so this may be partially deferred, but the logic gap should be fixed

---

## MEDIUM PRIORITY ISSUES

### ISSUE 6: Runtime rollup CSV must match Apr 15-approved maintenance combinations

**Severity:** Medium
**Source:** Meeting transcript (Tab 40 sign-off discussion)

The code is now CSV-only (`config_lot.R` line 50-51), so maintenance-approved combinations depend entirely on the runtime CSV content.

**Combinations confirmed/signed-off during the meeting:**
- DARA: `DUALMAINTENANCEWITH` should include `LENA` (Julia confirmed: "Dara and Len... that's a good idea")
- LENA: `DUALMAINTENANCEWITH` should include `BORT, CARF, DARA`
- THAL: `MONOMAINTENANCE` should be `1` (Julia confirmed: "just a valid mono maintenance... added as part of this study")
- BORT: `DUALMAINTENANCEWITH` should include `LENA`
- CARF: `DUALMAINTENANCEWITH` should include `LENA`

**What needs to change:**
- Before the next run, verify that the server-side `cl_mma_rollup.csv` loaded by the program matches these signed-off values
- Cross-check against `clmmarollupapr14.pdf` spec which shows the expected values

### ISSUE 7: Add targeted QC outputs for clinically unexpected first-line regimens

**Severity:** Medium
**Source:** Meeting transcript (Peter's feedback)

Drugs flagged for follow-up review:
- **BEND (Bendamustine):** Peter said it's not approved in 1st line. Some patients have it in the output. Real-world data makes it possible but unusual.
- **DARA + POMA (Pomalidomide):** Peter said this is typically a 2nd-line combination. Present in the Apr 14 output.
- **Cyclophosphamide followed by transplant:** Already has a dedicated deep-dive module (`R/cyclo_appendix_lot.R`), patient CSVs prepared.

**Current code:** No targeted QC extracts exist for BEND or DARA+POMA. The CYCLO appendix exists.

**What needs to change:**
- Add focused QC exports / patient-level review tables for BEND and DARA+POMA combinations in LOT1
- Julia said to wait for a more comprehensive list from Peter before deep-diving: "I'll wait till we get a more extensive list"
- Share CYCLO patient CSVs with Julia via Domino project (not email, due to patient IDs)

### ISSUE 8: LOT2-5 Implementation — Not Yet Started

**Severity:** Medium (blocked on LOT1 cleanup)
**Source:** Meeting transcript

**Key differences from LOT1 per meeting and protocol v6:**
1. **Induction window:** 30 days (vs. 60 days for LOT1) — `config_lot.R` line 40 currently hardcodes 60
2. **LOT start triggers:** LOT2+ can start with CAR-T event, allogeneic SCT, or autologous SCT (in addition to new agent)
3. **Iterative structure:** Each subsequent LOT's start depends on the previous LOT's end

**Meeting outcome:**
- Julia offered to start the LOT2-5 spec or have Onker do it after LOT1 cleanup
- Onker to finish LOT1 cleanup by end of week, then start LOT2 spec
- Julia to share old LOT2-5 spec from Optum for reference
- Julia noted: "LOT1 won't really make sense until you have your other LOTs, like if you can see a full patient journey"

**Current code:** Zero LOT2-5 logic exists. The program only builds LOT1.

---

## LOW PRIORITY / INFORMATIONAL

### ISSUE 9: Top 15/25 Induction Regimen Table

**Severity:** Low — NOT a confirmed code bug
**Source:** Meeting transcript

The meeting initially questioned whether the regimen table was stale, but then the discussion concluded the numbers were correct:
- Julia: "I thought, when I saw the numbers initially, 5000, it kind of triggered a bit"
- Onker: "I think it is kind of similar. It's just the... induction regimen"
- Julia: "they are the correct number"

Julia confirmed the **figures are accurate** but requested a dashboard refresh: "I'll refresh it. I'll send it to you."

**Minor code note:** The saved table in `R/descriptives_lot.R` (line 627) does not include a percentage column in the exported data, though the console output and chart both show percentages. Adding `pct` to the saved table would be a small improvement.

### ISSUE 10: Attrition Table — No Issues Found

**Source:** `Apr 13 2026/Attrition/attritiom apr 14.pdf`

Attrition flow (90-day cohort):
| Step | Description | N | % |
|------|-------------|---|---|
| Starting Population | >= 1 medical claim for MM | 94,951 | 100.0% |
| Inclusion 1 | >= 1 IP or >= 2 OP claims within 90 days | 70,866 | 74.6% |
| Inclusion 2 | Age >= 18 in index year | 70,842 | 74.6% |
| Inclusion 3 | >= 6 months CE baseline | 62,846 | 66.2% |
| Inclusion 4 | >= 1 day CE follow-up | 62,843 | 66.2% |
| Exclusion 5 | No MM therapy in baseline | 53,081 | 55.9% |
| Inclusion 6 | Evidence of MM therapy in follow-up | 21,512 | 22.7% |

Counts are consistent across 30-day, 60-day, and 90-day cohort definitions. No anomalies detected.

### ISSUE 11: Protocol v6 — Parameters Aligned

Julia confirmed protocol v6 is finalized ("shouldn't be any more changes"). Code parameters verified against protocol:
- Induction window: 60 days (LOT1) — `config_lot.R` line 40 ✓
- Maintenance minimum: 120 days — `config_lot.R` line 46 ✓
- Post-SCT maintenance minimum: 30 days — `config_lot.R` line 47 ✓
- SCT maintenance window: 180 days — `config_lot.R` line 48 ✓
- Tandem SCT: 60-180 days apart — `config_lot.R` lines 55-56 ✓
- CART consolidation: 45 days — `config_lot.R` line 59 ✓
- Medical day supply assumed: 28 days — `config_lot.R` line 43 ✓
- MAP discontinuation gap: 90 days — `config_lot.R` line 42 ✓

### ISSUE 12: Spec Comments — Signed Off

Julia reviewed Onker's comments on spec tabs during the meeting:
- Adding LENA to DARA dual maintenance column: signed off ✓
- Adding THAL as mono maintenance: signed off ✓
- Updated statement language in spec comments: signed off ✓
- Julia closed comments with her signature and date ✓

---

## ACTION ITEMS — PRIORITY ORDER

### Before Apr 23 Meeting (with Vicky):
| Priority | Action | Issue Ref |
|----------|--------|-----------|
| P0 | Remove maintenance-period logic from LOT1 end-reason derivation | Issue 1 |
| P1 | Add `contains_mtx_reg` flag to final dataset | Issue 2 |
| P2 | Remove `MAINTENANCE_END` end reason (reclassify to DISCONTINUATION) | Issue 4 |
| P3 | Remove `SCT_NO_MAINT` end reason (reclassify to SCT_AUTO) | Issue 3 |
| P4 | Fix CAR-T 45-day directionality + add CART_INIT end reason | Issue 5 |
| P5 | Verify runtime `cl_mma_rollup.csv` matches signed-off combinations | Issue 6 |
| P6 | Refresh dashboard and share updated link with Julia | Issue 9 |

### Next Sprint (Post-Apr 23):
| Priority | Action | Issue Ref |
|----------|--------|-----------|
| P7 | Start LOT2-5 spec (30-day window, CAR-T/SCT start triggers) | Issue 8 |
| P8 | Add BEND / DARA+POMA QC outputs when Peter provides full list | Issue 7 |
| P9 | Share CYCLO patient CSVs via Domino project | Issue 7 |
| P10 | Julia to send old LOT2-5 spec from Optum | Issue 8 |

---

## CODE LOCATIONS REFERENCE

| Component | File | Lines |
|-----------|------|-------|
| Maintenance detection (S16a) — repurpose for flag | `lot_program.R` | 1392-1763 |
| valid_maint_regimens CTE — basis for `contains_mtx_reg` | `lot_program.R` | 1442-1458 |
| Maintenance output columns — stop using for end reasons | `lot_program.R` | 1710-1753 |
| LOT1 end reason CASE logic — remove Rules 4 & 8 | `lot_program.R` | 1836-1870 |
| LOT1 end date CASE logic — remove maint/SCT_NO_MAINT branches | `lot_program.R` | 1872-1892 |
| LOT1 base length CASE logic — remove maint branches | `lot_program.R` | 1893-1922 |
| SCT_NO_MAINT flag — remove or simplify | `lot_program.R` | 1797-1818 |
| CART_CONSOL_FLG — fix directionality | `lot_program.R` | 1819-1829 |
| MED_ADD suppression — add CART_INIT path | `lot_program.R` | 1854-1858 |
| Top 25 regimen table / Figure 5 | `R/descriptives_lot.R` | 577-628 |
| Configuration parameters | `R/config_lot.R` | 15-75 |
| CYCLO deep-dive | `R/cyclo_appendix_lot.R` | (full file) |

---

## BOTTOM LINE

The main issue from the Apr 15 meeting is **not minor dashboard cleanup**. It is a **study-definition change**: stop defining maintenance as a formal LOT-ending construct and replace it with a flag-only concept (`contains_mtx_reg`). The Apr 14 LOT output still reflects the older maintenance-driven logic, so it should be treated as **out of date relative to the Apr 15 meeting decision**.

---

*This document is for internal review only. No code changes have been made.*
*Generated: April 15, 2026*

---

## ADDENDUM: Additional Corrections From Third-Pass Validation

The following 4 items were identified during a third-pass review and have been validated against the source code and meeting transcript. They correct or extend the main issues above.

### A1. `contains_mtx_reg` anchor definition is too narrow in the main report — CORRECTED

**Severity:** High (affects implementation correctness)

The main report (Issue 2) stated the flag requires "at least one non-maintenance drug also in induction." This is **too strict**.

**Transcript evidence (Julia, verbatim):**
- "the anchor could be a valid maintenance medication, actually"
- "if someone had Dara Len Bortezomib, those are 3 valid maintenance medications. So you don't know what the anchor agent is in that. Like if Dara fell away, you could have Bort and Len left alone."
- "you just need to have some 2nd or 3rd or 4th qualifying agent to sort of anchor your regimen"

**Correct definition:**
- `contains_mtx_reg = 1` when the LOT1 induction regimen contains a valid maintenance-approved mono or dual subset PLUS at least one additional induction agent **outside that chosen subset** to serve as the anchor
- The anchor agent may itself be maintenance-eligible in another context
- Example: DARA + LEN + BORT — all 3 are maintenance-eligible, but:
  - DARA anchors the BORT/LENA dual subset
  - BORT or LENA anchors the DARA mono subset
  - DARA or BORT anchors the LENA mono subset
  - So `contains_mtx_reg = 1` for this regimen

**Why this matters for implementation:**
A rule requiring a strictly non-maintenance anchor would incorrectly miss many valid regimens where all drugs happen to be maintenance-eligible in some context. The existing `valid_maint_regimens` CTE (lines 1442-1458) already computes valid mono/dual subsets per patient — the flag just needs to check whether at least one additional induction drug exists outside any of those subsets.

### A2. Dashboard/report layer must be updated — not just `lot_program.R`

**Severity:** Medium (operational correctness)

The main report focused on `lot_program.R` changes but did not explicitly call out downstream reporting cleanup.

**Confirmed hardcoded references to removed categories in `descriptives_lot.R`:**
- Line 680: `"SCT_NO_MAINT" = "#B47EB3", "MAINTENANCE_END" = "#44AF69"` — end-reason bar chart color map
- Line 1648: `SCT_NO_MAINT = "#B47EB3", MAINTENANCE_END = "#44AF69"` — Sankey diagram color map

**What needs to change:**
- Remove `SCT_NO_MAINT` and `MAINTENANCE_END` from both color maps
- Add `CART_INIT` to the color map (if Issue 5 CART_INIT end reason is implemented)
- Update any text labels, captions, or legend entries that describe maintenance as a formal end-reason path
- Verify no other hardcoded end-reason references exist in the reporting layer

### A3. `SCT_NO_MAINT` reclassification to `SCT_AUTO` requires explicit new routing — cannot just delete the branch

**Severity:** High (deleting without rerouting produces wrong results)

The main report (Issue 3) says to "remove the SCT_NO_MAINT branch" and reclassify to `SCT_AUTO`. However, simply deleting lines 1850-1853 will NOT produce `SCT_AUTO`.

**Why deletion alone fails:**
- `SCT_AUTO` comes from the Rule 3 branch (lines 1839-1848) which requires `ec.LOT1_TX_ENDDATE IS NOT NULL`
- SCT_NO_MAINT patients are defined by `LOT1_TX_ENDDATE IS NULL` (line 1799: `sct.LOT1_TX_ENDDATE IS NULL`)
- These are planned autologous SCTs that did not trigger the LOT-ending SCT pathway
- If the SCT_NO_MAINT branch is deleted, these patients fall through to `MED_ADD`, `DISCONTINUATION`, or censoring — NOT to `SCT_AUTO`

**What needs to change:**
- The fix must explicitly route planned-AUTO-without-maintenance cases into `SCT_AUTO` (or whatever the agreed target bucket is)
- Use `SCT_NO_MAINT_END_DT` (or its successor date field) as the end date for these reclassified patients
- One approach: modify the Rule 3 branch (lines 1839-1848) to also catch `LOT1_SCT_NO_MAINT_FLG = 1` cases, OR add a separate branch that maps them to `SCT_AUTO` with the planned AUTO date

### A4. Maintenance config parameters and QC outputs become dead/misleading under flag-only approach

**Severity:** Low-Medium (cleanup item)

Once maintenance is no longer a LOT-defining construct, several config parameters and QC summaries lose their meaning.

**Config parameters that become dead (`config_lot.R` lines 46-48):**
- `maint_min_days = 120` — minimum maintenance period duration (not needed for flag-only)
- `maint_post_sct_min_days = 30` — minimum post-SCT maintenance duration (not needed)
- `maint_sct_window_days = 180` — SCT-to-maintenance window (not needed for flag-only)

**QC outputs that become misleading (`lot_program.R` lines 1757-1762):**
- `n_with_maintenance` — count of patients with formal maintenance period
- `avg_maint_duration` — average maintenance period duration
- `n_maint_post_sct` — maintenance following SCT

**What needs to change:**
- Remove or retire maintenance-period config parameters if no longer used by any logic
- Remove maintenance-period QC summaries that are no longer meaningful
- Replace with QC for the new `contains_mtx_reg` flag (e.g., `n_with_valid_maint_regimen`, distribution of maintenance-eligible regimen types)
- Note: if the `valid_maint_regimens` CTE is repurposed for `contains_mtx_reg`, some of the underlying maintenance detection logic may still be needed — just not the duration-based filtering (`MAINT_DURATION >= MIN_MAINT_DAYS` at line 1754)

---

## REVISED COMPLETE ACTION ITEMS — PRIORITY ORDER

### Before Apr 23 Meeting (with Vicky):
| Priority | Action | Issue Ref |
|----------|--------|-----------|
| P0 | Remove maintenance-period logic from LOT1 end-reason derivation | Issue 1 |
| P1 | Add `contains_mtx_reg` flag with correct anchor definition (agent outside chosen subset, may itself be maintenance-eligible) | Issue 2 + A1 |
| P2 | Remove `MAINTENANCE_END` end reason — patients fall to DISCONTINUATION or censoring | Issue 4 |
| P3 | Reclassify `SCT_NO_MAINT` to `SCT_AUTO` with **explicit routing**, not just branch deletion | Issue 3 + A3 |
| P4 | Fix CAR-T 45-day directionality + add CART_INIT end reason | Issue 5 |
| P5 | Verify runtime `cl_mma_rollup.csv` matches signed-off combinations | Issue 6 |
| P6 | Update `descriptives_lot.R` color maps and Sankey to remove old categories | A2 |
| P7 | Refresh dashboard and share updated link with Julia | Issue 9 |

### Next Sprint (Post-Apr 23):
| Priority | Action | Issue Ref |
|----------|--------|-----------|
| P8 | Retire dead maintenance config params + QC outputs, add `contains_mtx_reg` QC | A4 |
| P9 | Start LOT2-5 spec (30-day window, CAR-T/SCT start triggers) | Issue 8 |
| P10 | Add BEND / DARA+POMA QC outputs when Peter provides full list | Issue 7 |
| P11 | Share CYCLO patient CSVs via Domino project | Issue 7 |

---

*Addendum validated against source code and meeting transcript. All 4 points confirmed accurate.*
*Generated: April 15, 2026*
