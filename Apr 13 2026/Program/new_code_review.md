# Cohort Attrition Code Review: `new_code.R`

**Reviewed:** `Apr 13 2026/Program/new_code.R` (3,104 lines)
**Against:** Attrition chart (`attritiom apr 14.pdf`), Protocol (`Lot protocol Apr 13.pdf`), Study Population Spec (`studypopapr14.pdf`), Data Prep Spec (`dataprepapr14.pdf`), Optum Business Rules
**Date:** 2026-04-14
**Type:** Static code review only -- no code changes made, no pipeline execution

---

## Reference Attrition Table (from `attritiom apr 14.pdf`)

| Step | Type | Description | 30d N | 60d N | 90d N |
|------|------|-------------|-------|-------|-------|
| Step 0 | Inc 0 | >= 2 medical claims for MM (203.x / C90.x) any position | 94,951 | 94,951 | 94,951 |
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

### 2. Step 0 Definition Mismatch: Code Counts >= 1 MM Dx, Chart Requires >= 2

**Lines:** 2751-2754
**Impact:** Step 0 count will be inflated vs. the reference chart

The attrition chart defines Step 0 as:
> ">= 2 medical claims for multiple myeloma (any ICD-9-CM=203.x or ICD-10-CM code=C90.x) in any position on claim"

The code counts:
```r
q0 <- DBI::dbGetQuery(con_env$con,
  glue("SELECT count(DISTINCT PATID) AS n FROM {work_tbl('mm_dx_events_id')}"))
```

`mm_dx_events_id` contains all patients with **any** MM dx event in the ID period (>= 1 claim). There is no >= 2 claim filter applied. This will produce a higher Step 0 count than the reference chart, which specifically requires >= 2 claims for the starting population.

### 3. Default Exclusion Criteria Are FALSE in Non-Interactive Mode

**Lines:** 415-418 (config defaults), 167-203 (interactive defaults)
**Impact:** Unattended/batch runs silently skip Steps 7-10, broadening the cohort

The reference attrition chart clearly applies Steps 7-10 (baseline MM evidence, other cancer, pregnancy, clinical trial). However, the environment-variable defaults are all `FALSE`:

```r
apply_pregnancy_excl     = as.logical(Sys.getenv("APPLY_PREGNANCY_EXCL",     unset = "FALSE"))  # line 415
apply_clintrial_excl     = as.logical(Sys.getenv("APPLY_CLINTRIAL_EXCL",     unset = "FALSE"))  # line 416
apply_other_malig_excl   = as.logical(Sys.getenv("APPLY_OTHER_MALIG_EXCL",   unset = "FALSE"))  # line 417
apply_baseline_nondx_excl = as.logical(Sys.getenv("APPLY_BASELINE_NONDX_EXCL", unset = "FALSE")) # line 418
```

The interactive prompt (line 167-183) correctly defaults to `TRUE` for these, but any Domino/batch run with `PROMPT_USER=FALSE` or `interactive() == FALSE` will silently skip all four exclusion steps. This is a cohort-definition risk for production runs.

**Recommendation:** Align the environment-variable defaults with the attrition chart (set to `TRUE`), or at minimum add a loud warning when exclusions are skipped.

### 4. Other-Malignancy Exclusion Misses the Inpatient Pathway

**Lines:** 2295-2338
**Impact:** Under-applies the exclusion; patients with a single IP other-cancer claim are retained

The protocol states:
> ">= 1 inpatient or >= 2 outpatient ICD-9-CM or ICD-10-CM codes on separate days, within 30 days, for the same primary tumor type"

The code only implements the outpatient pathway -- it finds pairs of diagnosis dates within 30 days. It never checks whether a claim is inpatient. A patient with a **single** inpatient claim for another cancer type (e.g., one inpatient lung cancer claim) would pass through the exclusion filter and remain in the cohort.

The inpatient classification logic (POS/TOS + CONF_ID) already exists in the pipeline for MM claims. The same approach should be applied here but is not.

### 5. Dynamic IE Mode Can Produce a Cohort That Skips the Qualifying-Diagnosis Filter

**Lines:** 927, 1002, 1056-1059, 1126
**Impact:** Users could finalize a cohort without the core Step 1 qualifying criterion

In the dynamic interactive loop, all 10 criteria (including Step 1 qualifying dx) are optional. A user can enter `0` to finalize at any point. Since `ELIG_COH_ALLFLAGS` is built from `mm_qualifying` (which already represents the 90-day qualifying population), the Step 1 filter in dynamic mode is applying the **window-specific** IP/OP flag (30d/60d/90d) on top of an already-qualified base. If a user finalizes without applying Step 1, all three windows effectively behave as the 90-day cohort, which defeats the purpose of having window-specific attrition.

More importantly, the dynamic Step 0 base count (line 1010) reports the count from `ELIG_COH_ALLFLAGS` as ">= 1 MM dx" when in reality these patients have already passed the 90-day qualifying logic. This mislabels the starting population.

---

## SIGNIFICANT Findings

### 6. Enrollment Check Does Not Explicitly Verify Medical AND Pharmacy Benefits

**Lines:** 1797-1831 (enrollment_spans)
**Impact:** Could include patients who have medical-only or pharmacy-only coverage

The attrition chart Step 3 specifies:
> "Patients with >= 6 months of Continuous Enrollment **with medical and pharmacy benefits** before the index date"

The code builds enrollment spans from `member_enrollment` using only `ELIGEFF` and `ELIGEND`:

```sql
SELECT PATID, cast(ELIGEFF as date) AS elig_eff, cast(ELIGEND as date) AS elig_end
FROM member_enrollment
```

There is no filter on benefit type (e.g., `MED_COVERAGE`, `PHARM_COVERAGE`, or `BUS` field). The Optum `member_enrollment` table has fields indicating benefit type. While the CDM documentation states it "restricts membership to individuals with both medical and pharmacy benefits," an explicit filter would guard against data segments that don't follow this restriction and would match the spec language exactly.

Note: The code uses `member_cont_enrollment` for demographics (line 1935) but `member_enrollment` (raw) for enrollment spans. The `member_cont_enrollment` table may already enforce dual-benefit coverage, but this should be validated or documented.

### 7. FU_DAYS Calculation Is Off By One Day vs. Protocol

**Lines:** 2420
**Impact:** Follow-up duration is one day shorter than the protocol definition

The protocol states:
> "The variable-length follow-up begins on the index date"

The code computes:
```sql
datediff(ENDDATE, date_add(b.index_date, 1)) + 1 AS FU_DAYS
```

This starts follow-up on `index_date + 1` (the day after), not on the index date itself. For a patient with index_date = Jan 1 and ENDDATE = Jan 10:
- Code yields: `datediff(Jan 10, Jan 2) + 1 = 9 days`
- Protocol definition: `datediff(Jan 10, Jan 1) + 1 = 10 days` (inclusive of index date)

The code comment at line 2346 confirms: "follow-up starts day after index." This contradicts the protocol and the attrition chart Step 4 which states follow-up starts **on** the index date.

### 8. Final Attrition Row Duplicates a Single Window Count Across All Three Columns

**Lines:** 2878-2880
**Impact:** 30-day and 60-day final counts are misleading in non-dynamic mode

The static attrition reporting path queries the final cohort table once:
```r
q_final <- DBI::dbGetQuery(con_env$con,
  glue("SELECT count(*) AS n FROM {work_tbl(cfg$final_table_name)}"))
record_attrition("99_final", ..., q_final$n, q_final$n, q_final$n)
```

The final cohort is built using only the configured outpatient window (default 90 days). The same count is written into the 30-day, 60-day, and 90-day columns. This is incorrect -- the three cohorts should have different final counts, as they do at every preceding step. The dynamic IE path (lines 1147-1163) correctly computes per-window final counts.

### 9. Step 7 Baseline MM Evidence Exclusion (`apply_baseline_nondx_excl`) Defaults to FALSE

**Lines:** 418, 2838-2846
**Impact:** Step 7 is silently omitted from the attrition table output

The attrition chart clearly shows Step 7 being applied (reducing 90-day cohort from ~21,572 to ~16,526). However, the toggle for this exclusion (`apply_baseline_nondx_excl`) defaults to `FALSE` in both interactive and non-interactive modes:

- Environment default: `FALSE` (line 418)
- Interactive default: `FALSE` (line 182)

This means Step 7 is never applied unless explicitly enabled. The attrition table will skip from Step 6 directly to Step 8, and the reference chart counts for Steps 7-10 will not be reproducible.

### 10. Variable Naming Confusion: `MM_BASELINE_NONDX` Is Not About Non-Diagnostic Claims

**Lines:** 2035-2103 (Step 16 vs Step 17)
**Impact:** Latent bug risk; misleading code maintenance

Step 16 builds a non-diagnostic claim classification view (`claim_nondiagnostic`), but Step 17 **does not use it**. Instead, `MM_BASELINE_NONDX` is set from any strict MM dx claim (203.0x/C90.0x) in the baseline period, regardless of whether the claim is diagnostic or non-diagnostic:

```sql
max(CASE WHEN e.svc_dt BETWEEN ... AND e.mm_dx_strict_flg = 1
     THEN 1 ELSE 0 END) AS MM_BASELINE_NONDX
```

The variable name and the toggle name (`apply_baseline_nondx_excl`) both suggest a "non-diagnostic claim" concept, but the actual implementation is simply "any strict MM dx in baseline." The `claim_nondiagnostic` view built in Step 16 is orphaned -- it is never joined or referenced by any subsequent step.

This is consistent with the attrition table Step 7 description (which just says ">= 1 medical claim for MM in baseline"), but the naming is confusing and Step 16 is dead code.

---

## MINOR / Observational Findings

### 11. Embedded Therapy Code List Is Very Incomplete

**Lines:** 724-738
**Impact:** Low in production (CSV/external tables are primary), but risky as a fallback

The embedded MM therapy codes include only 6 drugs (bortezomib, carfilzomib, daratumumab, elotuzumab, lenalidomide, velcade) with just 9 total codes. Key FDA-approved MM therapies are missing:
- Pomalidomide (Pomalyst)
- Thalidomide
- Ixazomib (Ninlaro)
- Panobinostat (Farydak)
- Selinexor (Xpovio)
- Isatuximab (Sarclisa)
- Melphalan
- Cyclophosphamide
- CAR-T therapies (idecabtagene vicleucel, ciltacabtagene autoleucel)
- Bispecific antibodies (teclistamab, talquetamab, elranatamab)

The code defaults to CSV files or external ref tables (`use_embedded_codes = FALSE`), so this is not a production issue if proper code lists are loaded. However, if a user enables embedded codes as a fallback, the therapy identification will be critically incomplete, drastically underestimating Steps 5 and 6 counts.

### 12. Clinical Trial Code List Is Narrow

**Lines:** 787-799
**Impact:** May under-capture clinical trial participants

The embedded clinical trial codes contain only 4 entries:
- Z006 (ICD-10 clinical research encounter)
- V707 (ICD-9 clinical trial exam)
- 99199 (HCPCS unlisted special service)
- 0762 (Revenue code investigational services)

This is a conservative list that may miss patients in clinical trials identified through other mechanisms (e.g., condition-specific clinical trial codes, modifier codes). Again, the CSV/external table pathway would be the primary source in production.

### 13. Other-Malignancy Code List Covers Only 4 Tumor Types

**Lines:** 802-818
**Impact:** May miss patients with other cancers not in the embedded list

The embedded list covers lung (C34), breast (C50), colon (C18/C19), and prostate (C61). Common cancers excluded from the embedded list:
- Bladder (C67), kidney (C64), pancreas (C25), liver (C22), melanoma (C43), lymphoma (C81-C86), leukemia (C91-C95), thyroid (C73), head/neck (C00-C14), ovarian (C56), uterine (C54-C55)

Same caveat: production should use comprehensive CSV/external tables.

### 14. Outpatient Qualifying Uses BROAD Codes (203.x/C90.x) -- Confirm vs. Spec

**Lines:** 1704-1741
**Impact:** May or may not be intentional

The attrition chart Step 1 says:
- Inpatient: 203.0x / C90.0x (**strict**)
- Outpatient: 203.x / C90.x (**broad**)

The code correctly uses `mm_dx_strict_flg = 1` for inpatient (line 1695) and the full `mm_dx_events_id` (which includes all broad codes) for outpatient pairs (line 1707). This matches the attrition chart.

However, the Study Population spec (studypopapr14.pdf) appears to reference 203.0x/C90.0x (strict) for both inpatient and outpatient. There may be a discrepancy between the spec and the attrition chart. Recommend confirming which is authoritative.

### 15. `baseline_days = 183` Is an Approximation of 6 Months

**Lines:** 82, 370
**Impact:** Negligible in most cases

183 days approximates 6 months but does not exactly equal 6 calendar months (which varies from 181-184 days depending on which months). This is standard practice in claims analysis and unlikely to cause issues, but it is worth noting that the spec says "6 months" while the code uses a fixed 183-day lookback.

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
| 2 | CRITICAL | Step 0 counts >= 1 MM dx instead of >= 2 | Add a >= 2 distinct claim-date filter to the Step 0 count query |
| 3 | CRITICAL | Exclusion defaults are FALSE for batch runs | Change env-var defaults to TRUE for `APPLY_PREGNANCY_EXCL`, `APPLY_CLINTRIAL_EXCL`, `APPLY_OTHER_MALIG_EXCL`, and `APPLY_BASELINE_NONDX_EXCL` |
| 4 | CRITICAL | Other-malignancy missing inpatient pathway | Add inpatient single-claim path using existing POS/TOS/CONF_ID logic |
| 5 | CRITICAL | Dynamic mode allows skipping Step 1 | Make Step 1 (qualifying dx) mandatory in dynamic mode or pre-apply it |
| 6 | SIGNIFICANT | CE enrollment doesn't verify medical + pharmacy benefits | Add benefit-type filter to enrollment span query |
| 7 | SIGNIFICANT | FU_DAYS off by one day | Change to `datediff(ENDDATE, index_date) + 1` per protocol |
| 8 | SIGNIFICANT | Final attrition row copies one window count to all three | Compute per-window final counts (as dynamic path already does) |
| 9 | SIGNIFICANT | Step 7 defaults to FALSE in all modes | Change interactive default to TRUE; change env default to TRUE |
| 10 | SIGNIFICANT | Variable naming confusion (NONDX vs. any-dx) | Rename to `MM_BASELINE_EVIDENCE` and `apply_baseline_mm_excl`; remove orphaned Step 16 or wire it in |
| 11 | MINOR | Embedded therapy list incomplete | Document that embedded codes are for dev/testing only; require CSV/external for production |
| 12 | MINOR | Confirm OP qualifying codes (broad vs. strict) against spec | Clarify with study team whether attrition chart or spec is authoritative |
