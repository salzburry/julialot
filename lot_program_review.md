# Comprehensive Review: `lot_program.R` vs Program Specifications

**Reviewed file:** `lot_program.R` (4337 lines)

**Reference documents (Apr 13 2026 folder):**
- Lot protocol Apr 13
- mmamedapr14 (5A. MMA_MED spec)
- maedapr14 (5B. MAP_MED spec)
- lot1baseapr14 (6. LOT1_BASE spec)
- sctapr14 (7. SCT spec)
- lotbaseendapr14 (10. LOT1_BASE_END spec)
- clmmarollupapr14 (Tab 40. CL_MMA_ROLLUP)
- codelist.pdf (Tab 41, permissible subs, SCT codes)
- optum business rules / optum data dict (CDM v9.0)
- sensitivity cbecks (Julia Moore email)

**Review type:** Static analysis only. Code was not modified.
**Review date:** 2026-04-15
**Reviewed by:** Three independent agents, cross-verified

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 4 |
| HIGH | 4 |
| MEDIUM | 1 |
| **Total** | **9** |

---

## CRITICAL Findings

### C1. Script does not parse — unescaped double-quote inside `glue()` string

**Code:** Line 3223, inside a `glue("...")` block that opens at line 3122:
```
-- Per map med.pdf page 5: "Pushout is not implemented" for medical.
```

**Problem:** The literal `"` characters around `"Pushout is not implemented"` terminate the R string delimiter early. R cannot parse this file. The script is not executable.

**Fix:** Escape the quotes (`\"`) or replace with single quotes in the SQL comment.

---

### C2. Pharmacy claims with missing/invalid DAY_SUPPLY are deleted instead of defaulted to 28

**Code:** Lines 3063-3067
```sql
filtered AS (
  SELECT *
  FROM enriched
  WHERE NOT (CLAIM_TYPE = 'pharmacy' AND (DAY_SUPPLY IS NULL OR DAY_SUPPLY < 1))
),
```
Line 3097 adds a post-filter assertion that stops execution if any survive.

**Spec (mmamedapr14, DAY_SUPPLY row):**
> "If CLAIM_TYPE_SOURCE=pharmacy and (DAY_SUPPLY_SOURCE < 1 or DAY_SUPPLY_SOURCE is missing), then consider 28 days supply."

**Protocol (Section 5.1.1):**
> "When pharmacy claims are missing days' supply, or when values are anomalous, a 28-day supply is assumed."

**Problem:** Both spec and protocol say **impute 28 days**. The code **deletes these rows**.

**Impact:** Pharmacy claims without valid days supply are lost entirely. This undercounts medication exposure, shortens MAPs, and can cause false discontinuations downstream.

---

### C3. Maintenance logic is not implemented despite being defined in the Apr 14 spec

**Code:** Lines 4037-4038
```r
log_msg("NOTE: Maintenance (mono/dual) specs not yet provided; LOT1_BASE_END_REASON")
log_msg("      does not yet include MAINTENANCE_START. Will need integration when available.")
```

**Spec (lotbaseendapr14) defines these variables — none are computed:**
- `LOT1_BASEMAINT_START` — Start date of maintenance period
- `LOT1_BASEMAINT_TYP` — Maintenance medication abbreviation
- `LOT1_BASEMAINT_END` — End date of maintenance period
- `LOT1_BASEMAINT_MED_[MED]` — Per-medication flags (BORT/DARA/IXAZ/LENA/CARF/THAL)
- `LOT1_BASEMAINT_END_REASON` — Maintenance end reason

**Protocol maintenance definition:**
> "A maintenance regimen is a period of 120 days or longer during which only a valid maintenance therapy is available."

**Valid maintenance therapies (NCCN/protocol):**
- Mono: lenalidomide, bortezomib, daratumumab, ixazomib, thalidomide
- Dual: bortezomib/lenalidomide, carfilzomib/lenalidomide, daratumumab/lenalidomide

**Problem:** The code loads MONOMAINTENANCE and DUALMAINTENANCEWITH from the rollup (lines 2756-2780) but never uses them. No maintenance period detection, no maintenance end reason, no maintenance variables are output.

**Impact:** All maintenance-related output variables are missing. This also blocks correct implementation of Rules 4 and 8 (see C4 and H3).

---

### C4. Rule 4 missing: SCTs not followed by maintenance within 180 days should end LOT1

**Code:** Lines 3920-3928 (ENDING_AUTO_DT logic) and 4002-4011 (LOT1_BASE_END_REASON)

**Protocol (Section 5.1.1, Rule 4):**
> "SCTs not followed by maintenance — if an SCT is not followed by a maintenance regimen within 180 days, then the last day of the LOT is the date of the SCT."

**Problem:** The code only ends LOT1 for excess AUTO events (2nd AUTO for single, 3rd for tandem), ALLO, or CAR-T. There is no check for "single/tandem AUTO SCT followed by no valid maintenance within 180 days." This is a distinct logic hole — not just a consequence of missing maintenance variables. Even once maintenance is implemented, this rule must be explicitly coded as a separate end-reason check.

**Impact:** Patients with a single/tandem AUTO SCT but no subsequent maintenance will have LOT1 continue past the SCT date, ending on discontinuation or censoring instead.

---

## HIGH Findings

### H1. Steroids leak into LOT1 regimen, discontinuation, and add-med logic

**Code:**
- Line 3323: `LOT1_START_DT` correctly excludes steroids (`MAP_MED_CLASS <> 'STEROID'`)
- Line 3327-3341: `lot1_induction_meds` has **no** steroid exclusion filter
- Lines 3355-3358: Comment says "Steroid MAPs are included in base_meds"
- Lines 3413-3424: `first_add_candidates` does **not** exclude steroids

**Protocol (Section 5.1.1):**
> "LOT1 regimen: Includes all MM therapies received within 60 days... excluding non-oncology agents such as corticosteroids."
> "Receipt of corticosteroids only (e.g., dexamethasone) will not be considered evidence of receiving an approved MM oncology therapy."

**Spec (lotbaseendapr14):**
> LOT1 induction medications capture "the full set of oncology agents administered during this 60-day window, excluding non-oncology agents such as corticosteroids."

**Problem:** While LOT1 start date correctly excludes steroids, all downstream logic includes them:
1. Steroids inflate `LOT1_MED_CNT` and appear in `LOT1_BASE_MEDS`
2. Steroid MAPs extend `LOT1_BASE_DISCON_DT` (keeping LOT1 alive via steroid refills)
3. A steroid not in the induction window (e.g., PRED started after 60 days) becomes a false first-add-med, incorrectly ending LOT1

**Impact:** LOT1 regimen composition, length, and end reasons are all distorted by corticosteroids that the protocol treats as supportive/non-oncology agents.

---

### H2. Tandem SCT 180-day boundary off-by-one

**Code:** Line 3906
```sql
AND datediff(ap.AUTO_DT_2, ap.AUTO_DT_1) + 1 <= {cfg$sct_tandem_days}
```
Where `cfg$sct_tandem_days = 180`.

**Protocol:**
> "Patients classified as having a planned tandem SCT if they receive at least two autologous SCTs >= 60 to <= 180 days apart."

**Problem:** The code uses `datediff(...) + 1 <= 180`. With this formula, a pair exactly 180 days apart evaluates as `180 + 1 = 181 <= 180 = FALSE`, failing tandem classification. The agreed-upon rule is `>= 60 AND <= 180` days apart (i.e., `datediff >= 60 AND datediff <= 180` without the `+1`). The same off-by-one appears at lines 3913 and 3921.

**Note:** The programming spec (sctapr14) uses the `+1` formula, creating a spec-vs-protocol conflict. However, the team has already resolved this in favor of the protocol definition (without `+1`) during prior SCT cleanup work.

**Impact:** AUTO SCTs exactly 180 days apart are misclassified as non-tandem (unplanned), triggering an incorrect LOT1 termination.

---

### H3. `LOT1_BASE_END_REASON` is too coarse vs spec

**Code:** Lines 4001-4016

**Code produces:** `SCT_AUTO`, `SCT_ALLO`, `SCT_CART`, `SCT`, `MED_ADD`, `DISCONTINUATION`, `CENSORED`

**Protocol Rules 2-8 expect distinct reasons for:**
- Rule 2: Discontinuation of all agents
- Rule 3: Unplanned SCTs
- Rule 4: SCTs not followed by maintenance within 180 days
- Rule 5: Death
- Rule 6: Health plan disenrollment
- Rule 7: End of study period
- Rule 8: End of maintenance regimen

**Problem:** Death, disenrollment, and end-of-study are collapsed into a single `CENSORED` bucket. Rules 4 and 8 are absent entirely (maintenance dependency). The spec also defines `LOT1_TX_AUTO_FLG` and `LOT1_TX_AUTO_MAX_DT` as output variables that are not computed, though these are straightforward derivations.

**Impact:** Analytic summaries cannot distinguish death from disenrollment from administrative censoring. Downstream analyses requiring specific end-reason breakdowns will not work.

---

### H4. Codelist sourcing should fail loud instead of silently falling back to incomplete data

**Code:** Lines 196-219 (`get_code_source()` priority: CSV > embedded > ref table)

**Problem:** If server CSVs are unavailable, the code silently falls back to embedded data or reference tables with only an informational log message. The embedded fallback is severely incomplete:

- **Embedded rollup:** 8 of 28 unique medication abbreviations (missing CYCL, MELP, THAL, BEND, IDEC, CILT, BELA, ISAT, ELOT, ETOP, PANO, SELI, TECL, DOPL, DOXO, CISP, ELRA, LINV, TALQ, VENE)
- **Embedded codelist:** 6 code entries vs hundreds in the full Tab 41
- **Embedded maintenance flags are wrong:** BORT has MONOMAINT=0 (spec: YES), DARA has MONOMAINT=0 (spec: YES), POMA has MONOMAINT=1 (spec: blank/NO), CARF missing DUALMAINT=LENA, LENA missing DUALMAINT partner CARF
- **Embedded permissible subs:** Only DARA-DARA, BORT-IXAZ, IXAZ-BORT (may be incomplete vs server file for biosimilar substitutions)

**Impact:** In environments without mounted CSVs (local dev, broken mount), the pipeline runs with ~29% of medications and produces severely incomplete results with no prominent alert. A spec-locked LOT algorithm should not silently degrade.

**Recommendation:** Add a validation step that checks loaded codelist counts against minimum expected thresholds and fails with a clear error if they are not met.

---

## MEDIUM Findings

### M1. `LOT1_BASE_LENGTH` uses 3-way calculation vs spec's 2-way

**Code:** Lines 3448-3455
```sql
LOT1_BASE_LENGTH = CASE
  WHEN LOT1_BASE_END_REASON = 'DISCONTINUATION'
    THEN datediff(LOT1_BASE_DISCON_DT, LOT1_START_DT) + 1
  WHEN LOT1_BASE_END_REASON IN ('MED_ADD','SCT_AUTO','SCT_ALLO','SCT_CART','SCT')
    THEN datediff(LOT1_BASE_END_DT, LOT1_START_DT) + 1
  ELSE datediff(OBS_END_DT, LOT1_START_DT) + 1
END
```

**Spec (lotbaseendapr14, LOT1_BASE_LENGTH row):**
> "If LOT1_BASE_END_REASON = 'DISCONTINUATION' then LOT1_BASE_DISCON_DT - LOT1_START_DT + 1. Else LOT1_BASE_END_DT - LOT1_START_DT + 1."

**Problem:** The spec defines a 2-way calculation:
1. Discontinuation → use `LOT1_BASE_DISCON_DT`
2. Everything else → use `LOT1_BASE_END_DT`

The code adds a third branch for the ELSE/CENSORED case using `OBS_END_DT`. This may be intentional if `LOT1_BASE_END_DT` is NULL for censored patients (since no explicit end event occurred), but it diverges from the spec as written.

**Impact:** For censored patients, the computed length may differ from what `LOT1_BASE_END_DT` would yield. The team should confirm whether the 3-way split is the intended definition or whether `LOT1_BASE_END_DT` should be populated for censored patients so the 2-way spec formula works.

---

## Appendix A: Medication Coverage Gap — Embedded vs Full Codelist

The table below shows medications present in the full Tab 40 (CL_MMA_ROLLUP) that are **missing** from the embedded fallback at lines 225-246. If the CSV codelist is unavailable and the pipeline falls back to embedded data, these medications will not be detected in claims.

| MED_ABBR | MED_CLASS | In Embedded? | Notes |
|----------|-----------|:------------:|-------|
| BORT | PROTINHIB | YES | Embedded MONOMAINT=0, spec says YES |
| CARF | PROTINHIB | YES | Embedded missing DUALMAINT=LENA |
| IXAZ | PROTINHIB | YES | OK |
| LENA | IMMUNOMOD | YES | Embedded missing DUALMAINT partners |
| POMA | IMMUNOMOD | YES | Embedded MONOMAINT=1, spec says NO |
| DARA | ANTICD38 | YES | Embedded MONOMAINT=0, spec says YES |
| DEXA | STEROID | YES | OK |
| PRED | STEROID | YES | OK |
| THAL | IMMUNOMOD | NO | — |
| CYCL | MUSTARD | NO | — |
| MELP | MUSTARD | NO | — |
| BEND | MUSTARD | NO | — |
| IDEC | ANTICD38 | NO | — |
| CILT | BCMA | NO | — |
| BELA | BCMA | NO | — |
| ISAT | ANTICD38 | NO | — |
| ELOT | SIGNALING | NO | — |
| ETOP | TOPOISOMERASE | NO | — |
| PANO | HDACINHIBITOR | NO | — |
| SELI | XPORTINHIBITOR | NO | — |
| TECL | BCMA | NO | — |
| DOPL | BCMA | NO | — |
| DOXO | ANTHRACYCLINE | NO | — |
| CISP | PLATINUM | NO | — |
| ELRA | ANTICD38 | NO | — |
| LINV | CELMOD | NO | — |
| TALQ | CELMOD | NO | — |
| VENE | BCL2INHIBITOR | NO | — |

**Summary:** 8 of 28 unique medications present in embedded fallback (29% coverage). 20 medications would be undetectable if CSV files are unavailable.

---

## Appendix B: Recommended Fix Priority

| Priority | Finding | Effort | Rationale |
|----------|---------|--------|-----------|
| 1 | **C1** Parse error | Trivial | Script cannot run at all. Fix: escape two quote characters. |
| 2 | **C2** DAY_SUPPLY delete vs default | Low | One-line change: replace WHERE filter with COALESCE/CASE to impute 28. |
| 3 | **H1** Steroid leakage | Low | Add `MAP_MED_CLASS <> 'STEROID'` filter to lot1_induction_meds and first_add_candidates CTEs. |
| 4 | **H2** Tandem off-by-one | Trivial | Remove `+ 1` from datediff comparisons at lines 3906, 3913, 3921. |
| 5 | **H4** Codelist fail-loud | Low | Add count-check after codelist load; abort if below threshold. |
| 6 | **H3** END_REASON granularity | Medium | Split CENSORED into DEATH, DISENROLLMENT, STUDY_END using DOD and enrollment dates. |
| 7 | **M1** LOT1_BASE_LENGTH | Trivial | Confirm intended definition with team; either align code to 2-way spec or update spec. |
| 8 | **C4** Rule 4 (SCT + no maint) | Medium | Requires maintenance detection (C3) to be implemented first. |
| 9 | **C3** Maintenance logic | High | Full feature implementation: 120-day detection, mono/dual classification, end reasons, output variables. Blocked by spec finalization. |

---

## Appendix C: Cross-Reference to Protocol Rules

| Protocol Rule | Description | Code Status | Finding |
|---------------|-------------|-------------|---------|
| Rule 1 | LOT1 starts at first non-steroid therapy | Implemented correctly | — |
| Rule 2 | Discontinuation of all agents (90-day gap) | Implemented (but steroids leak) | H1 |
| Rule 3 | Unplanned SCT ends LOT | Implemented (off-by-one in tandem) | H2 |
| Rule 4 | SCT not followed by maintenance within 180d | **Not implemented** | C4 |
| Rule 5 | Death ends LOT | Collapsed into CENSORED | H3 |
| Rule 6 | Disenrollment ends LOT | Collapsed into CENSORED | H3 |
| Rule 7 | End of study period | Collapsed into CENSORED | H3 |
| Rule 8 | End of maintenance regimen | **Not implemented** (needs C3) | C3 |

---

*End of review.*
