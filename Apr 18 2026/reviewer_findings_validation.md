# Reviewer findings — validation and detailed report

**Date:** 2026-04-21
**Purpose:** Validate the 7 findings submitted by an external reviewer against the actual code and the local spec source set, and flag where my prior review (`code_vs_spec_review_apr18.md`) under-called or missed the same drift.
**Method:** static code read + direct spec quotes from `studypopapr18.pdf` pages 1–3, `lot1baseendupdatedapr19.txt`, and `attritiom apr 14_layout.txt`. No code changes.

---

## TL;DR — reviewer's findings are all valid

All 7 reviewer findings are supported by the code and — where applicable — by the StudyPop spec text. My earlier review caught 4 of the 7 (and called 3 of those at the correct severity). **I missed or under-called 3 findings**, all in the attrition pipeline:

| # | Reviewer finding | My prior call | Correct call |
|---|---|---|---|
| R1 | Default run stops at Step 6 | A1 — Medium | **High** (upgrade) |
| R2 | Baseline MM drops non-diagnostic rule | not flagged | **High** (new) |
| R3 | Other-cancer outpatient stricter than spec | called MATCH | **High** (new drift) |
| R4 | Legacy maintenance outputs still exported | covered by Apr 19 review | Medium (no change) |
| R5 | SCT_NO_MAINT still drives end routing | covered by Apr 19 review | High (no change) |
| R6 | CART_INIT uses infusion date | covered by Apr 19 review | High (no change) |
| R7 | Same-day add-med tie-break uses min(), not random | noted but not flagged | Low (new drift) |

**Net new findings this pass** (not previously written up anywhere): R2, R3, R7. R1 needs its severity upgraded.

---

## Validation per finding

### R1 — Default run stops at Step 6, not the Step 10 spec cohort

**Reviewer severity:** P1 / High
**My prior call:** A1, Medium — severity under-called
**Verdict:** **Valid. Upgrade to High.**

**Code evidence — `config_prompts.R:111-117`:**
```r
# STAKEHOLDER DECISION (2026-04-14): All exclusion flags default FALSE so
# the working cohort stays at the Step 6 level (~21k patients). Flags are
# computed in ELIG_COH_ALLFLAGS for ad-hoc analysis; set TRUE to apply.
apply_pregnancy_excl   = as.logical(Sys.getenv("APPLY_PREGNANCY_EXCL",   unset = "FALSE")),
apply_clintrial_excl   = as.logical(Sys.getenv("APPLY_CLINTRIAL_EXCL",   unset = "FALSE")),
apply_other_malig_excl = as.logical(Sys.getenv("APPLY_OTHER_MALIG_EXCL", unset = "FALSE")),
apply_baseline_mm_excl = as.logical(Sys.getenv("APPLY_BASELINE_MM_EXCL", unset = "FALSE")),
```

**Gate evidence — `pipeline_steps.R:996-1011` (Step 24, `ELIG_COH_FINAL`):**
```sql
WITH filtered AS (
  SELECT * FROM ELIG_COH_ALLFLAGS
  WHERE 1=1
    AND (inpt_qual = 1 OR outpt2_{cfg$outpatient_window} = 1)
    {criteria_sql}
)
```
`{criteria_sql}` is built from `criteria_attrition.R` only for flags whose `apply_*` is `TRUE`, so the four exclusions above silently drop out of the final cohort build.

**Spec evidence — `attritiom apr 14_layout.txt`:** the 10-step attrition table lists Steps 7–10 (baseline MM / other cancer / pregnancy / clintrial) as applied exclusions, not as optional flags.

**Impact:** a default `ELIG_COH_FINAL` run produces the Step 6 working cohort, not the Step 10 spec cohort. This is a **material default/spec mismatch**, even though the flags are computed in `ELIG_COH_ALLFLAGS`. My prior review framed this as a policy item; the reviewer is right that its visibility and consequence warrant High severity.

---

### R2 — Baseline MM exclusion drops the StudyPop non-diagnostic rule

**Reviewer severity:** P1 / High
**My prior call:** not flagged
**Verdict:** **Valid. New finding. High.**

**Spec evidence — `studypopapr18.pdf` p2, row `MM_baseline_diag`:**
> "Evidence of any MM here is defined use ≥1 **non-diagnostic** medical claim for MM (ICD-9-CM=203.0x or ICD-10-CM code=C90.0x) during the baseline period. This flag is used to help better identify smoldering patients."

Optum non-diagnostic definition on the same page:
> "a claim where one of the multiple myeloma diagnosis codes is present, but there is at least one service line on the claim that doesn't equal a diagnostic code … If the resulting facility claim had a diagnosis code for multiple myeloma and only one service line on the claim and that service line indicated a laboratory test, then we can't be certain that this is a true multiple myeloma diagnosis … Alternatively, if the claim had … two service lines: the first line for testing and the second line a HCPCS code for medication or a CPT code for physician care management then we will accept that claim as a 'non-diagnostic claim'."

**Code evidence — `pipeline_steps.R:593-615`:**
```r
# Step 16 (claim_nondiagnostic view) was removed -- it was orphaned and
# not referenced by any downstream step. The attrition table Step 7
# requires only >=1 MM dx (strict) in baseline, not non-diagnostic claims.
# ...
# NOTE: Attrition table does NOT require non-diagnostic; IE criteria PDF row 14 does.
# Following attrition table as the authoritative source.
...
max(CASE WHEN e.svc_dt BETWEEN date_sub(q.index_date, {cfg$baseline_days})
                             AND date_sub(q.index_date, 1)
              AND e.mm_dx_strict_flg = 1
         THEN 1 ELSE 0 END) AS MM_BASELINE_EVIDENCE
```

The code **counts any strict MM dx in baseline**, with no service-line / non-diagnostic filter. The comment explicitly acknowledges the StudyPop/IE-criteria conflict and makes a deliberate choice of the attrition table over StudyPop.

**Impact:** broadens the exclusion materially. A baseline claim that the StudyPop spec would treat as "just a diagnostic test for MM" (so the patient is not yet a confirmed MM case → not a smoldering-patient exclusion) is counted as baseline MM evidence under the current code. Cohort composition shifts whenever diagnostic-only baseline claims are present. Also: by default this flag is OFF (R1), so the effect is latent until someone sets `apply_baseline_mm_excl = TRUE`.

**Ask:** study-team decision on which source (StudyPop sheet vs attrition table) is authoritative. If StudyPop wins, the removed `claim_nondiagnostic` view needs to come back.

---

### R3 — Other-cancer outpatient logic is stricter than the StudyPop rule

**Reviewer severity:** P1 / High
**My prior call:** A9 / Match — wrong
**Verdict:** **Valid. New finding. High.**

**Spec evidence — `studypopapr18.pdf` p2, row `MM_baseline_other`:**
> "Patients with either ≥1 inpatient or ≥2 outpatient ICD-9-CM or ICD-10-CM codes on separate days, within 30 days, for the same primary tumor type and/or metastatic cancer. **Only the first of the 2 codes is required to occur inside the baseline period.**"

**Code evidence — `pipeline_steps.R:876-880`:**
```sql
-- Path B: 2 outpatient claims within 30d, BOTH in baseline
WHEN op.diff_days <= 30
  AND op.first_dt BETWEEN date_sub(q.index_date, {cfg$baseline_days})
                      AND date_sub(q.index_date, 1)
  AND op.next_dt  <= date_sub(q.index_date, 1)
THEN 1
```

The code requires BOTH `first_dt` and `next_dt` to be `≤ day before index`. The StudyPop spec says only `first_dt` needs to be in baseline; the confirming `next_dt` can fall shortly after index.

**Impact:** patients whose first OP cancer claim is in baseline and whose confirming second OP claim falls just after index are **kept** in the cohort under the current code, whereas the spec would exclude them. My prior review's Part A labelled this finding as MATCH; that was wrong — I did not cross-check the "only the first" clause in the StudyPop sheet.

---

### R4 — Legacy maintenance outputs still exported

**Reviewer severity:** P2 / Medium
**My prior call:** already covered by the Apr 19 review (issue #4 in `code_alignment_review.md`)
**Verdict:** **Valid. No change.**

**Code evidence — `lot_program.R:1830-1841`:**
```sql
-- Maintenance columns (kept for reference, no longer drive end-reason per Apr 15 meeting)
m.LOT1_BASEMAINT_START,
m.LOT1_BASEMAINT_TYP,
m.LOT1_BASEMAINT_END,
m.LOT1_BASEMAINT_END_REASON,
m.LOT1_BASEMAINT_MED_BORT,
m.LOT1_BASEMAINT_MED_CARF,
m.LOT1_BASEMAINT_MED_DARA,
m.LOT1_BASEMAINT_MED_IXAZ,
m.LOT1_BASEMAINT_MED_LENA,
m.LOT1_BASEMAINT_MED_THAL,
-- contains_mtx_reg flag (Apr 15 meeting: flag-only maintenance concept)
COALESCE(cmr.contains_mtx_reg, 0) AS contains_mtx_reg,
```

The shipped `lot1_base_end` surface still carries 10 `LOT1_BASEMAINT_*` columns plus the whole `S16a_lot1_maintenance` step upstream (per Apr 19 review). The Apr 19 spec kept `contains_mtx_reg` as the maintenance concept and removed the standalone maintenance period. Already tracked.

---

### R5 — SCT_NO_MAINT still drives final LOT1 end routing

**Reviewer severity:** P1 / High
**My prior call:** already covered (Apr 19 review, issue #3)
**Verdict:** **Valid. No change.**

**Code evidence — `lot_program.R:1843-1865`:** `LOT1_SCT_NO_MAINT_FLG` and `SCT_NO_MAINT_END_DT` are computed, then consumed by the CASE tree at `:1906-1910` which maps them directly to `SCT_AUTO`. The Apr 19 spec removed `SCT_NO_MAINT` as a final value and reclassifies those cases via the ordinary earliest-event logic. Already tracked in `code_alignment_review.md` at `code_alignment_review.md:52-67`.

---

### R6 — CART_INIT end date still uses the infusion date

**Reviewer severity:** P1 / High
**My prior call:** already covered (Apr 19 review, issues #1 and #2)
**Verdict:** **Valid. No change.**

**Spec evidence — `lot1baseendupdatedapr19.txt:113-114`:** for CAR-T transitions including `CART_INIT`, `LOT1_BASE_END_DT` is **the day before** `FIRST_CART_DT`.

**Code evidence — `lot_program.R:1940-1942`:**
```sql
WHEN ec.CART_INIT_FLG = 1
 AND (ec.LOT1_BASE_DISCON_DT IS NULL OR ec.FIRST_CART_DT <= ec.LOT1_BASE_DISCON_DT)
THEN ec.FIRST_CART_DT
```
Needs `date_sub(ec.FIRST_CART_DT, 1)` on the THEN branch AND on the discon-tie gate. Already tracked.

---

### R7 — Same-day added-med ties deviate from the spec's random-with-fixed-seed rule

**Reviewer severity:** P3 / Low
**My prior call:** noted at C5 ("documented as deliberate") but **not flagged as drift**
**Verdict:** **Valid. New finding. Low.**

**Code evidence — `lot_program.R:805-806`:**
```sql
-- Spec says 'random' for same-day ties; we use min() for determinism (deliberate deviation)
min(c.MAP_MED_TYPE) AS LOT1_BASE_1ST_ADD_MED
```

The code author acknowledges the deviation in the comment: spec expects a random-with-fixed-seed tie-break; the code uses alphabetic `min()` for run-to-run determinism.

**Impact:** end date and length are unaffected (both come from `ADD_START_DT`, which is tie-free). Only the recorded `LOT1_BASE_1ST_ADD_MED` differs — under the current code it is always the alphabetically-earliest med of the same-day add. Reproducibility is stronger than the spec (good), but the value does not match what the spec prescribes (drift).

**Ask:** either update the spec to accept deterministic `min()` with an explicit tie-break ordering, or implement the fixed-seed random selection (the standard way is `row_number() over (partition by … order by rand(seed))` + `rn = 1`).

---

## Also aligned (reviewer's "what looks aligned" items — confirmed)

- **Attrition frame**: 183-day baseline + 30-day CE gap + `CE_3mosf` sensitivity flag + month/year death-date generalization at `pipeline_steps.R:345` onwards — matches StudyPop / Data Prep.
- **Inpatient detection**: POS/TOS approach combined with validated `CONF_ID` (requires both `ADMIT_DATE` and `DISCH_DATE`) at `pipeline_steps.R:194-199` — matches Optum business rules.
- **MMA / MAP core**: `lot_program.R:292` (S04 raw) and `:492` (S06 map) correctly implement 28-day medical day supply, pharmacy bad-day-supply imputation to 28, pharmacy pushout, no medical pushout, 90-day MAP discontinuation. Matches the data-prep and MAP spec.
- **SCT processing core**: `lot_program.R:982` onwards (S13 AUTO dates) — 14-day window, 60-day gap, 180-day tandem all correct per SCT spec.

---

## Corrected net-new findings (to be added to `code_vs_spec_review_apr18.md`)

| ID | Severity | Area | Location | One-line fix direction |
|---|---|---|---|---|
| A1 (upgrade) | **High** | Attrition defaults | `config_prompts.R:111-117` | Flip the 4 `apply_*_excl` defaults to `TRUE` (or add a hard banner on Part 1 start when any are FALSE) |
| A9a (new) | **High** | Baseline MM evidence | `pipeline_steps.R:593-615` | Restore non-diagnostic filter per StudyPop row `MM_baseline_diag`, OR get explicit written sign-off that attrition table supersedes StudyPop |
| A9b (new) | **High** | Other-cancer OP | `pipeline_steps.R:876-880` | Drop the `op.next_dt <= date_sub(index_date, 1)` condition; require only `op.first_dt` in baseline (and keep the 30-day within-pair window) |
| C5a (new) | Low | First-add tie-break | `lot_program.R:805-806` | Replace `min()` with either a spec-aligned fixed-seed random pick, or document a deterministic tie-break ordering in the spec |

Already-tracked items (Apr 19 review): R4 (legacy maintenance), R5 (SCT_NO_MAINT), R6 (CART_INIT date) — no change.

---

## What my prior review got wrong

Being explicit so the corrections are auditable:

1. **Severity miscall on A1.** I wrote this up as Medium and framed it as a stakeholder policy choice. The reviewer is right that — regardless of the 2026-04-14 decision — the functional effect is a cohort-definition default mismatch with the spec and should be High.
2. **Missed R2 entirely.** I did not cross-check `MM_baseline_diag` against the StudyPop row and accepted the in-code comment's choice of the attrition table without independently verifying. The code comment at `pipeline_steps.R:599-600` was effectively a self-flag that I should have surfaced.
3. **Wrongly called R3 a MATCH.** I did not notice the "**Only the first** of the 2 codes is required to occur inside the baseline period" clause on the StudyPop sheet. The code's both-dates-pre-index logic is a real drift.
4. **Soft-pedalled R7.** At C5 I described the tie-break as "documented as deliberate" and didn't flag it as drift. It is drift — the code comment says so explicitly.

No code was changed. No specs were changed. This file documents the validation only.

---

## Source of truth pointers

- **Spec file quoted for R2 and R3:** `Program Spec and Scenarios/studypopapr18.pdf`, page 2, rows `MM_baseline_diag` and `MM_baseline_other`.
- **Spec file quoted for R6:** `Program Spec and Scenarios/lot1baseendupdatedapr19.txt` lines 113–114.
- **Attrition table reference for R1:** `Attrition/attritiom apr 14_layout.txt` — 10-step attrition table.
- **Existing reviews:** `code_alignment_review.md`, `program_review_vs_apr19_spec.md`, `code_vs_spec_review_apr18.md`, `r_code_optimization_review.md`.

*End of validation report.*


