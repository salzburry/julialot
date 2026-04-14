# Cohort Attrition Code Review: `new_code.R`

**Reviewed:** `Apr 13 2026/Program/new_code.R` (3,104 lines)
**Against:** Attrition chart (`attritiom apr 14.pdf`), Protocol (`Lot protocol Apr 13.pdf`), Study Population Spec (`studypopapr14.pdf`), Data Prep Spec (`dataprepapr14.pdf`), Optum Business Rules
**Date:** 2026-04-14
**Type:** Static code review only -- no code changes made, no pipeline execution

---

## Reference Attrition Table (from `attritiom apr 14.pdf`)

| Step | Type | Description | 30d N | 60d N | 90d N |
|------|------|-------------|-------|-------|-------|
| Step 0 | Inc 0 | >= 1 medical claims for MM (203.x / C90.x) any position | 94,951 | 94,951 | 94,951 |
| Step 1 | Inc 1 | >= 1 IP (203.0x/C90.0x) OR >= 2 OP (203.x/C90.x) separate days within 30/60/90d | 68,900 | 70,204 | 70,866 |
| Step 2 | Inc 2 | Age >= 18 in index year | 68,877 | 70,181 | 70,842 |
| Step 3 | Inc 3 | >= 6 months CE (medical + pharmacy) before index; gaps <= 30d allowed | 61,083 | 62,236 | 62,846 |
| Step 4 | Inc 4 | >= 1 day CE from index date; FU ends at earliest of death / study end | 61,080 | 62,233 | 62,843 |
| Step 5 | Excl 5 | >= 1 medical/pharmacy claim for FDA-approved MM therapy in baseline | 51,214 | 52,443 | 53,081 |
| Step 6 | Inc 6 | Evidence of FDA-approved MM therapy in follow-up | 21,263 | 21,487 | 21,572 |
| Step 7 | Excl 7 | >= 1 medical claim for MM (203.0x/C90.0x) in baseline | 15,470 | 16,248 | 16,526 |
| Step 8 | Excl 8 | Evidence of another cancer in baseline | ~8,700 | ~9,065 | ~9,197 |
| Step 9 | Excl 9 | Pregnancy/childbirth during baseline or follow-up | ~8,630 | ~8,981 | ~9,121 |
| Step 10 | Excl 10 | Clinical trial participation during baseline + follow-up | ~8,127 | ~8,465 | ~8,596 |

---

## CRITICAL Findings

### 1. Attrition Step Order Does Not Match the Reference Chart (Steps 3-6 Swapped)

**Lines:** 2738-2876
**Impact:** Cumulative attrition counts will not reconcile row-by-row with the reference Excel

The attrition chart applies criteria in this order:

| Chart Step | Criterion |
|------------|-----------|
| Step 3 | Baseline CE (6 months) |
| Step 4 | Follow-up CE (>= 1 day) |
| Step 5 | No baseline MM therapy (exclusion) |
| Step 6 | FU MM therapy required (inclusion) |

The code applies them in a different order:

| Code Step | Criterion | Code lines |
|-----------|-----------|------------|
| Step 3 | FU therapy required (`MM_FU_agents = 1`) | 2798-2806 |
| Step 4 | No baseline therapy (`MM_bl_agents = 0`) | 2808-2816 |
| Step 5 | Baseline CE (`CE_b = 1`) | 2818-2826 |
| Step 6 | Follow-up CE (`CE_f = 1`) | 2828-2836 |

The comments at lines 2738-2749 claim to match the chart but the actual implementation is swapped. Because attrition is cumulative, applying criteria in a different order produces different intermediate counts at each step even if the final cohort is the same. The output attrition table will not match the reference chart.

### 2. Default Exclusion Criteria Are FALSE in Non-Interactive Mode

**Lines:** 415-418 (config defaults), 167-203 (interactive defaults)
**Impact:** Unattended/batch runs silently skip Steps 7-10, broadening the cohort

The reference attrition chart clearly applies Steps 7-10 (baseline MM evidence, other cancer, pregnancy, clinical trial). However, the environment-variable defaults are all `FALSE`:

```r
apply_pregnancy_excl     = as.logical(Sys.getenv("APPLY_PREGNANCY_EXCL",     unset = "FALSE"))  # line 415
apply_clintrial_excl     = as.logical(Sys.getenv("APPLY_CLINTRIAL_EXCL",     unset = "FALSE"))  # line 416
apply_other_malig_excl   = as.logical(Sys.getenv("APPLY_OTHER_MALIG_EXCL",   unset = "FALSE"))  # line 417
apply_baseline_nondx_excl = as.logical(Sys.getenv("APPLY_BASELINE_NONDX_EXCL", unset = "FALSE")) # line 418
```

The interactive prompt (line 167-183) correctly defaults to `TRUE` for pregnancy, clinical trial, and other malignancy, but any Domino/batch run with `PROMPT_USER=FALSE` or `interactive() == FALSE` will silently skip all four exclusion steps. This is a cohort-definition risk for production runs.

**Recommendation:** Align the environment-variable defaults with the attrition chart (set to `TRUE`), or at minimum add a loud warning when exclusions are skipped.

### 3. Other-Malignancy Exclusion Misses the Inpatient Pathway

**Lines:** 2295-2338
**Impact:** Under-applies the exclusion; patients with a single IP other-cancer claim are retained

The protocol and study population spec state:
> ">= 1 inpatient or >= 2 outpatient ICD-9-CM or ICD-10-CM codes on separate days, within 30 days, for the same primary tumor type"

The code only implements the outpatient paired-date pathway -- it finds pairs of diagnosis dates within 30 days. It never checks whether a claim is inpatient. A patient with a **single** inpatient claim for another cancer type (e.g., one inpatient lung cancer claim) would pass through the exclusion filter and remain in the cohort.

The inpatient classification logic (POS/TOS + CONF_ID) already exists in the pipeline for MM claims. The same approach should be applied to the other-malignancy step but is not. See `studypopapr14.pdf` other-cancer exclusion language and the existing inpatient logic at lines 1600-1669.

---

## SIGNIFICANT Findings

### 4. Dynamic IE Mode: Step 0 Mislabeled and Step 1 Is Optional

**Lines:** 927, 1002, 1010, 1056-1059, 1126
**Impact:** Window-specific qualifying can be bypassed; base count is mislabeled

In the dynamic interactive loop, `ELIG_COH_ALLFLAGS` is built from `mm_qualifying`, which already represents patients who passed the 90-day-window qualifying logic (IP strict OR 2 OP within 90d). However:

1. **Step 0 is mislabeled.** The dynamic Step 0 base count (line 1010) reports the count as ">= 1 MM dx" when these patients have already passed the 90-day qualifying filter. This mislabels the starting population -- it should say something like "Qualifying (90d max window)" or the true ">= 1 MM dx" base from `mm_dx_events_id` should be shown.

2. **Step 1 is optional.** Step 1 in the dynamic loop applies the window-specific IP/OP flag (30d/60d/90d) on top of the already-qualified base. If a user finalizes without selecting Step 1, all three window columns effectively show the same 90-day-qualified count, which defeats the purpose of window-specific attrition.

Dynamic mode does not allow skipping MM qualification entirely (all patients in `ELIG_COH_ALLFLAGS` already passed 90-day qualification), but it does allow skipping the narrower 30d/60d filters that differentiate the three cohort columns.

### 5. Final Attrition Row Duplicates a Single Window Count Across All Three Columns

**Lines:** 2878-2880
**Impact:** 30-day and 60-day final counts are misleading in non-dynamic mode

The static attrition reporting path queries the final cohort table once:
```r
q_final <- DBI::dbGetQuery(con_env$con,
  glue("SELECT count(*) AS n FROM {work_tbl(cfg$final_table_name)}"))
record_attrition("99_final", ..., q_final$n, q_final$n, q_final$n)
```

The final cohort is built using only the configured outpatient window (default 90 days). The same count is written into the 30-day, 60-day, and 90-day columns. This is incorrect -- the three cohorts should have different final counts, as they do at every preceding step. The dynamic IE path (lines 1147-1163) correctly computes per-window final counts; the static path should do the same.

### 6. Step 7 Baseline MM Evidence Exclusion (`apply_baseline_nondx_excl`) Defaults to FALSE

**Lines:** 418, 2838-2846
**Impact:** Step 7 is silently omitted from the attrition table output

The attrition chart clearly shows Step 7 being applied (reducing 90-day cohort from ~21,572 to ~16,526). However, the toggle for this exclusion (`apply_baseline_nondx_excl`) defaults to `FALSE` in both interactive and non-interactive modes:

- Environment default: `FALSE` (line 418)
- Interactive default: `FALSE` (line 182)

This means Step 7 is never applied unless explicitly enabled. The attrition table will skip from Step 6 directly to Step 8, and the reference chart counts for Steps 7-10 will not be reproducible.

### 7. Variable Naming Confusion: `MM_BASELINE_NONDX` Is Not About Non-Diagnostic Claims

**Lines:** 2035-2103 (Step 16 vs Step 17)
**Impact:** Latent bug risk; misleading code maintenance

Step 16 builds a non-diagnostic claim classification view (`claim_nondiagnostic`), but Step 17 **does not use it**. Instead, `MM_BASELINE_NONDX` is set from any strict MM dx claim (203.0x/C90.0x) in the baseline period, regardless of whether the claim is diagnostic or non-diagnostic:

```sql
max(CASE WHEN e.svc_dt BETWEEN ... AND e.mm_dx_strict_flg = 1
     THEN 1 ELSE 0 END) AS MM_BASELINE_NONDX
```

The variable name and the toggle name (`apply_baseline_nondx_excl`) both suggest a "non-diagnostic claim" concept, but the actual implementation is simply "any strict MM dx in baseline." The `claim_nondiagnostic` view built in Step 16 is orphaned -- it is never joined or referenced by any subsequent step.

This is consistent with the attrition table Step 7 description (which just says ">= 1 medical claim for MM in baseline"), but the naming is confusing and Step 16 is dead code.

**Recommendation:** Rename to `MM_BASELINE_EVIDENCE` and `apply_baseline_mm_excl`. Either remove the orphaned Step 16 or wire it into the flag logic if the non-diagnostic concept is needed for a sensitivity analysis.

---

## MINOR / Observational Findings

### 8. Embedded Therapy Code List Is Very Incomplete (Fallback-Path Risk)

**Lines:** 724-738
**Impact:** Low in production (CSV/external tables are primary), but risky if fallback is enabled

The embedded MM therapy codes include only 6 drugs (bortezomib, carfilzomib, daratumumab, elotuzumab, lenalidomide, velcade) with just 9 total codes. Key FDA-approved MM therapies are missing:
- Pomalidomide (Pomalyst), Thalidomide, Ixazomib (Ninlaro), Panobinostat (Farydak)
- Selinexor (Xpovio), Isatuximab (Sarclisa), Melphalan, Cyclophosphamide
- CAR-T therapies (idecabtagene vicleucel, ciltacabtagene autoleucel)
- Bispecific antibodies (teclistamab, talquetamab, elranatamab)

The code defaults to CSV files or external ref tables (`use_embedded_codes = FALSE`), so this is not a production issue if proper code lists are loaded. However, if a user enables embedded codes as a fallback, therapy identification will be critically incomplete, drastically underestimating Steps 5 and 6 counts. Recommend documenting that embedded codes are for dev/testing only.

### 9. Clinical Trial and Other-Malignancy Embedded Code Lists Are Narrow

**Lines:** 787-799, 802-818
**Impact:** Same fallback-path caveat as above

- **Clinical trial:** Only 4 codes (Z006, V707, 99199, 0762). May under-capture trial participants.
- **Other malignancy:** Only 4 tumor types (lung, breast, colon, prostate). Misses bladder, kidney, pancreas, liver, melanoma, lymphoma, leukemia, thyroid, head/neck, ovarian, uterine, and others.

Same caveat: production should use comprehensive CSV or external reference tables. The embedded lists are a minimal fallback.

### 10. Outpatient Qualifying Uses BROAD Codes (203.x/C90.x) -- Confirm vs. Spec

**Lines:** 1704-1741
**Impact:** Harmonization question, not a code bug

The attrition chart Step 1 says:
- Inpatient: 203.0x / C90.0x (**strict**)
- Outpatient: 203.x / C90.x (**broad**)

The code correctly uses `mm_dx_strict_flg = 1` for inpatient (line 1695) and the full `mm_dx_events_id` (which includes all broad codes) for outpatient pairs (line 1707). This matches the attrition chart.

However, the Study Population spec appears to reference 203.0x/C90.0x (strict) for both inpatient and outpatient. This may be a discrepancy between the spec and the attrition chart. Recommend confirming with the study team which is authoritative. The code currently follows the attrition chart, which is the appropriate choice if the chart is considered the final validated output.

### 11. Enrollment Benefit-Type Filtering: Observation

**Lines:** 1797-1831
**Impact:** Cannot confirm as a bug from static review alone

The attrition chart Step 3 references "medical and pharmacy benefits." The code builds enrollment spans from `member_enrollment` using `ELIGEFF`/`ELIGEND` without an explicit benefit-type filter. The Optum CDM documentation states the database "restricts membership to individuals with both medical and pharmacy benefits," which may mean the filter is inherently applied at the data level. This is a data-model validation question rather than a confirmed code defect. Recommend confirming with the data team whether `member_enrollment` records in this CDM instance always imply dual-benefit coverage, and if not, adding a `BUS` or benefit-type filter.

### 12. `baseline_days = 183` Is an Approximation of 6 Months

**Lines:** 82, 370
**Impact:** Negligible

183 days approximates 6 months but does not exactly equal 6 calendar months (which varies 181-184 days). This is standard practice in claims analysis and consistent with how most Optum studies implement a 6-month lookback.

---

## What Looks Correct and Well-Aligned

| Area | Code Location | Assessment |
|------|---------------|------------|
| MM qualifying logic (IP strict OR OP broad, keeps all candidate index dates, picks earliest passing) | Lines 1687-1783, 2435-2457 | Matches spec and attrition chart |
| Inpatient classification (POS/TOS Approach 1 + CONF_ID Approach 2) | Lines 1600-1669 | Matches Optum business rules |
| Confinement validation (requires ADMIT_DATE + DISCH_DATE) | Lines 1600-1615 | Matches Optum business rules |
| Death date derivation (month-level -> 15th, year-only -> Jul 15 / Dec 31 rule) | Lines 1955-2023 | Matches protocol Section 4.5 |
| Enrollment gap logic (30-day gaps absorbed) | Lines 1797-1831 | Matches spec |
| Strict enrollment spans for CE_3mosf (no gaps) | Lines 1843-1886 | Matches spec sensitivity requirement |
| FU_DAYS calculation (starts from INDEX_DATE + 1) | Line 2420 | Matches StudyPop spec definition |
| Pregnancy flag (DX + PROC + RVNU_CD across baseline + follow-up) | Lines 2174-2228 | Matches protocol exclusion criteria |
| Clinical trial flag (DX + PROC + RVNU_CD, baseline + follow-up split) | Lines 2234-2292 | Matches protocol exclusion criteria |
| Therapy events (medical PROC_CD + Rx NDC) | Lines 2109-2133 | Correct dual-source approach |
| Death-aware therapy flag (FU bounded by death_dt) | Lines 2140-2163 | Good data quality safeguard |
| Code list priority (CSV > embedded > external table) | Lines 603-624 | Flexible and well-structured |
| Materialization checkpoints (break Spark lazy eval) | Lines 441-449, 2704-2711 | Good performance practice |
| Retry/reconnect logic with exponential backoff | Lines 1236-1250 | Robust connection handling |

---

## Summary of Recommendations (Priority Order)

| # | Severity | Finding | Recommendation |
|---|----------|---------|----------------|
| 1 | CRITICAL | Attrition step order (3-6) does not match chart | Reorder Steps 3-6 in the attrition reporting to: CE baseline -> CE followup -> No baseline therapy -> FU therapy required |
| 2 | CRITICAL | Exclusion defaults are FALSE for batch runs | Change env-var defaults to TRUE for `APPLY_PREGNANCY_EXCL`, `APPLY_CLINTRIAL_EXCL`, `APPLY_OTHER_MALIG_EXCL`, and `APPLY_BASELINE_NONDX_EXCL` |
| 3 | CRITICAL | Other-malignancy missing inpatient pathway | Add inpatient single-claim path using existing POS/TOS/CONF_ID logic per spec |
| 4 | SIGNIFICANT | Dynamic mode Step 0 mislabeled; Step 1 optional | Fix Step 0 label to reflect 90d-qualified base; consider making Step 1 (window-specific filter) mandatory |
| 5 | SIGNIFICANT | Final attrition row copies one window count to all three | Compute per-window final counts (as dynamic path already does at lines 1147-1163) |
| 6 | SIGNIFICANT | Step 7 defaults to FALSE in all modes | Change interactive and env defaults to TRUE to match the attrition chart |
| 7 | SIGNIFICANT | Variable naming confusion (NONDX vs. any-dx); Step 16 is dead code | Rename to `MM_BASELINE_EVIDENCE` / `apply_baseline_mm_excl`; remove or wire in orphaned Step 16 |
| 8 | MINOR | Embedded therapy/trial/malignancy code lists are incomplete | Document that embedded codes are dev/testing only; require CSV/external for production |
| 9 | MINOR | Outpatient broad vs. strict codes: chart vs. spec discrepancy | Confirm with study team which document is authoritative |
| 10 | OBSERVATION | Enrollment benefit-type not explicitly filtered | Validate with data team whether `member_enrollment` implies dual-benefit in this CDM instance |
