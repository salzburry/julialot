# Cohort Attrition Code Review: `new_code.R` -- Reconciled Fixes

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

## Must Fix

### 1. Static attrition step order does not match the Apr 14 chart

**Lines:** 2737-2836
**Verified against:** Code lines 2798-2836 and attrition chart Steps 3-6

The non-dynamic attrition builder applies Steps 3-6 in this order:

| Code order | Criterion | Code line |
|------------|-----------|-----------|
| Step 3 | FU therapy required (`MM_FU_agents = 1`) | 2798 |
| Step 4 | No baseline therapy (`MM_bl_agents = 0`) | 2808 |
| Step 5 | Baseline CE (`CE_b = 1`) | 2818 |
| Step 6 | Follow-up CE (`CE_f = 1`) | 2828 |

The Apr 14 attrition chart shows:

| Chart order | Criterion |
|-------------|-----------|
| Step 3 | Baseline CE (6 months) |
| Step 4 | Follow-up CE (>= 1 day) |
| Step 5 | Baseline MM therapy exclusion |
| Step 6 | Follow-up MM therapy requirement |

The comments at lines 2737-2749 claim "Order matches attrition.pdf exactly" but the implementation is wrong. Because attrition is cumulative, applying criteria in a different order produces different intermediate counts at each step even if the final cohort is the same. The generated attrition table will not reconcile row-by-row with the chart.

Note: The dynamic mode `all_criteria` list (lines 932-975) also uses the wrong step_id numbering for Steps 3-6 (step_id 3 = FU therapy, step_id 5 = CE baseline, etc.), so the same ordering issue exists in both paths.

### 2. Other-malignancy exclusion is missing the inpatient pathway

**Lines:** 2295-2338
**Verified against:** StudyPop spec (other-cancer exclusion language) and existing inpatient logic at lines 1640-1643

The StudyPop spec requires:
- `>= 1 inpatient` claim, **or**
- `>= 2 outpatient` claims on separate days within 30 days

for the same tumor type / metastatic cancer grouping.

The code only implements the paired-date pathway. It builds `distinct_dates` -> `with_next` -> `pairs` and checks for `diff_days <= 30`, which is the outpatient 2-claim logic. There is no join to the claim header or confinement tables to check whether a claim is inpatient.

The inpatient classification logic (POS/TOS Approach 1 + CONF_ID Approach 2) already exists in the pipeline at lines 1640-1643 for MM claims. The same approach should be applied here to catch patients with a single qualifying inpatient other-cancer claim.

### 3. Dynamic mode Step 0 is mislabeled, and Step 1 is optional

**Lines:** 927-1010, 1056-1059, 1126
**Verified against:** Code flow from `mm_qualifying` -> `ELIG_COH_ALLFLAGS` -> dynamic loop

Two issues:

**Step 0 mislabel:** At line 1010, Step 0 is presented as ">= 1 MM dx" (`format(current$n_30, big.mark = ",")`). But `ELIG_COH_ALLFLAGS` is built from `mm_qualifying` (line 2374), which already contains only patients who passed the 90-day-window qualifying logic (IP strict OR 2 OP within 90d). The dynamic Step 0 count is actually the 90-day qualified population, not the raw ">= 1 MM dx" base. The label should reflect this.

**Step 1 is optional:** Step 1 (step_id 1 in `all_criteria` at line 932) applies the window-specific IP/OP filter (30d/60d/90d). A user can finalize at any point by entering `0` (line 1056). If they finalize without applying Step 1, the 30-day and 60-day columns will show the same counts as 90-day, because the underlying table already has everyone who qualifies at 90d. This defeats the purpose of window-specific attrition in the dynamic flow.

This matters because interactivity is expected for stakeholder reruns.

### 4. Static final attrition row is wrong for the 30-day and 60-day columns

**Lines:** 2878-2880
**Verified against:** Code at line 2880 and dynamic path at lines 1147-1163

The static reporting path queries the final cohort once:
```r
q_final <- DBI::dbGetQuery(con_env$con,
  glue("SELECT count(*) AS n FROM {work_tbl(cfg$final_table_name)}"))
record_attrition("99_final", ..., q_final$n, q_final$n, q_final$n)
```

The final cohort (`ELIG_COH_FINAL`) is built using only the configured outpatient window (default 90d, line 2448). The same count is written into all three columns. The 30-day and 60-day values are misleading -- they should be lower since fewer patients qualify under narrower windows.

The dynamic path already computes per-window final counts correctly at lines 1147-1163 using `final_count_per_window()`. The static path should do the same.

### 5. Step 7 baseline MM evidence exclusion is off by default in all modes

**Lines:** 167-182, 279-281, 418
**Verified against:** All three default-setting locations

The Apr 14 attrition chart includes Step 7 (reducing 90-day cohort from ~21,572 to ~16,526). But `apply_baseline_nondx_excl` defaults to `FALSE` everywhere:

| Location | Default | Line |
|----------|---------|------|
| Interactive criteria list | `FALSE` | 182 |
| Interactive prompt | Hardcoded `FALSE` (with comment: "diagnostic code list is incomplete, causes 81% false exclusion rate") | 279-281 |
| Environment variable | `FALSE` | 418 |

Line 279-281 is especially notable:
```r
# NOTE: Baseline non-diagnostic claim exclusion is hardcoded to FALSE
# (diagnostic code list is incomplete, causes 81% false exclusion rate)
criteria$apply_baseline_nondx_excl <- FALSE
```

This hardcoding means there is no way to enable Step 7 through the interactive prompt -- the user's choice is overridden to `FALSE` regardless of input. To reproduce the attrition chart, this must be changed to default `TRUE` and the hardcoding removed.

---

## Stakeholder Decision: Steps 8-10 Remain FALSE

### 6. Batch defaults for pregnancy, clinical trial, and other malignancy exclusions

**Lines:** 415-417
**Verified against:** Environment-variable defaults

The environment-variable defaults for these three exclusions are `FALSE`:

```r
apply_pregnancy_excl     = as.logical(Sys.getenv("APPLY_PREGNANCY_EXCL",     unset = "FALSE"))  # line 415
apply_clintrial_excl     = as.logical(Sys.getenv("APPLY_CLINTRIAL_EXCL",     unset = "FALSE"))  # line 416
apply_other_malig_excl   = as.logical(Sys.getenv("APPLY_OTHER_MALIG_EXCL",   unset = "FALSE"))  # line 417
```

The interactive defaults (lines 179-181) are `TRUE`, so interactive runs would apply them by default. Batch/non-interactive runs would skip them.

**Stakeholder decision:** These exclusions are intentionally kept `FALSE` for now so the cohort remains at approximately 21,000 patients (the Step 6 count in the attrition chart). The attrition chart shows what happens when they *are* applied (Steps 8-10 drop the cohort to ~8,100), but the current working cohort deliberately stops before those exclusions.

This is not a code bug -- it is a deliberate cohort-definition choice. However, it should be documented clearly in the code comments so future users understand this is by design and not an oversight. The interactive defaults (`TRUE`) and env defaults (`FALSE`) should also be aligned to whichever behavior is intended as the default.

---

## Cleanup Worth Doing

### 7. `MM_BASELINE_NONDX` naming is misleading, and Step 16 is orphaned

**Lines:** 2035-2078 (Step 16), 2084-2103 (Step 17)
**Verified against:** Code flow from Step 16 -> Step 17 -> ELIG_COH_ALLFLAGS

Step 16 (`16_claim_nondiagnostic`, line 2035) builds a claim-level non-diagnostic classification view (`claim_nondiagnostic`) that marks whether each claim has diagnostic vs. non-diagnostic procedure lines.

Step 17 (`17_mm_baseline_nondx_flag`, line 2084) **does not reference Step 16's output at all**. It simply checks for any strict MM dx (203.0x/C90.0x) in the baseline period:

```sql
max(CASE WHEN e.svc_dt BETWEEN date_sub(q.index_date, 183) AND date_sub(q.index_date, 1)
          AND e.mm_dx_strict_flg = 1
     THEN 1 ELSE 0 END) AS MM_BASELINE_NONDX
```

This is correct per the attrition chart Step 7 description (">= 1 medical claim for MM in baseline"). But the naming creates confusion:

- The variable is called `MM_BASELINE_NONDX` (suggesting non-diagnostic claims)
- The toggle is called `apply_baseline_nondx_excl` (same suggestion)
- Step 16 builds a non-diagnostic view that nothing uses

The code comment at lines 2081-2083 explains the intent: "Attrition table does NOT require non-diagnostic; IE criteria PDF row 14 does. Following attrition table as the authoritative source."

**Recommendation:** Rename to `MM_BASELINE_EVIDENCE` / `apply_baseline_mm_excl` for clarity. Either remove the orphaned Step 16 or wire it in as a separate sensitivity flag if the non-diagnostic concept is needed later.

---

## What Looks Correct and Well-Aligned

| Area | Code Location | Assessment |
|------|---------------|------------|
| MM qualifying logic (IP strict OR OP broad, keeps all candidate index dates, picks earliest passing) | Lines 1687-1783, 2435-2457 | Matches spec and attrition chart |
| Inpatient classification (POS/TOS Approach 1 + CONF_ID Approach 2) | Lines 1600-1669 | Matches Optum business rules |
| Confinement validation (requires ADMIT_DATE + DISCH_DATE) | Lines 1600-1615 | Matches Optum business rules |
| Death date derivation (month -> 15th, year-only -> Jul 15 / Dec 31 rule) | Lines 1955-2023 | Matches protocol Section 4.5 |
| FU_DAYS calculation (starts from INDEX_DATE + 1) | Line 2420 | Matches StudyPop spec definition |
| Enrollment gap logic (30-day gaps absorbed) | Lines 1797-1831 | Matches spec |
| Strict enrollment spans for CE_3mosf (no gaps) | Lines 1843-1886 | Matches spec sensitivity requirement |
| Pregnancy flag (DX + PROC + RVNU_CD, baseline + follow-up) | Lines 2174-2228 | Matches protocol exclusion criteria |
| Clinical trial flag (DX + PROC + RVNU_CD, baseline + follow-up split) | Lines 2234-2292 | Matches protocol exclusion criteria |
| Therapy events (medical PROC_CD + Rx NDC) | Lines 2109-2133 | Correct dual-source approach |
| Death-aware therapy flag (FU bounded by death_dt) | Lines 2140-2163 | Good data quality safeguard |
| Code list priority (CSV > embedded > external table) | Lines 603-624 | Flexible and well-structured |
| Outpatient broad vs. strict codes | Lines 1695, 1707 | Code follows attrition chart (IP=strict, OP=broad) |

---

## Summary

| # | Category | Finding | Action |
|---|----------|---------|--------|
| 1 | Must Fix | Static attrition step order (3-6) does not match chart | Reorder to: CE baseline -> CE followup -> BL therapy excl -> FU therapy. Also fix dynamic mode step_id numbering. |
| 2 | Must Fix | Other-malignancy missing >= 1 inpatient pathway | Add IP single-claim check using existing POS/TOS/CONF_ID logic |
| 3 | Must Fix | Dynamic mode Step 0 mislabeled; Step 1 optional | Fix Step 0 label; consider making Step 1 mandatory or pre-applying it |
| 4 | Must Fix | Static final attrition row copies one count to all 30/60/90 columns | Compute per-window final counts (as dynamic path already does) |
| 5 | Must Fix | Step 7 (`apply_baseline_nondx_excl`) is FALSE and hardcoded off in interactive mode | Change defaults to TRUE; remove hardcoding at line 281 |
| 6 | By Design | Pregnancy, clinical trial, other malignancy exclusions default FALSE | Stakeholder decision to keep cohort at ~21k. Document the intent; align interactive vs. env defaults. |
| 7 | Cleanup | `MM_BASELINE_NONDX` naming misleading; Step 16 orphaned | Rename variable/toggle; remove or repurpose Step 16 |
