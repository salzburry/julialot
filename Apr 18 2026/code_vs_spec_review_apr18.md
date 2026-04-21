# Code vs Spec Review — Apr 18 2026

**Review date:** 2026-04-21
**Scope:** LOT + attrition R code in `Apr 18 2026/Program/` reviewed against the 8 Apr 18 specs in `Program Spec and Scenarios/` and the Apr 14 attrition spec in `Attrition/`.
**Deliverable:** review only — no code changes made.

**Previously covered (not re-litigated here):** the Apr 19 LOT1 end-reason spec is handled in `code_alignment_review.md` and `program_review_vs_apr19_spec.md`. Known issues from those reviews — CART_INIT date offset, `SCT_NO_MAINT` routing, `S16a_lot1_maintenance` subsystem, stale rule-number comments — are out of scope for this pass.

---

## Executive summary

- **Overall alignment is strong.** Across the 8 Apr 18 specs plus the attrition spec, no new **critical** drift was found beyond what the Apr 19 review already flagged. The pipeline structure, thresholds, and derivation rules match the specs.
- **One policy-level item** worth confirming with stakeholders: all four attrition exclusion flags (pregnancy, clinical trial, other malignancy, baseline MM) **default to FALSE** in `config_prompts.R:112-117` per a 2026-04-14 stakeholder decision. Steps 7–10 of the attrition spec are therefore computed but not applied to the working cohort.
- **Two medium items** in MMA processing: multi-class `MED_ABBR` ambiguity is warned but not enforced (`lot_program.R:198-211`), and the permissible-substitution CSV is not validated for symmetry/self-subs/cycles (`lot_program.R:92-93, 137-144`).
- **One spec-text gap**: the `medical_day_supply = 28` default cites "per spec (5A.MMA_MED row 15)" at `lot_program.R:298` but the spec PDF row itself could not be read during review — flag for study-team confirmation.
- **Documentation gap**: most `config_lot.R` / `config_prompts.R` thresholds are correct but do not cite the specific spec section they came from. Low severity; matters for traceability.
- **What's clean**: LOT1 start / induction window / steroid exclusion / LOT discontinuation gap / SCT AUTO+ALLO+CART typing / tandem detection / CAR-T 45-day consolidation / MTX anchor rule are all correctly implemented per Apr 18 specs.

---

## Methodology

Three parallel passes, each anchored to a distinct spec cluster:
1. **Part A** — `studypopapr18.pdf` + `attritiom apr 14.pdf` vs the attrition pipeline (`main.R`, `pipeline_steps.R`, `criteria_attrition.R`, `config_prompts.R`, `codelists.R`, `db_utils.R`).
2. **Part B** — `dataprepapr18.pdf`, `clmmarolluoapr18.pdf`, `mmamedapr18.pdf`, `mapmedapr18.pdf` vs LOT steps S00–S07.
3. **Part C** — `lot1baseapr18.pdf` (start/induction/base only — end-reasons excluded), `sctapr18.pdf`, `mtx scenarios.pdf` vs LOT steps S08–S16b.

Spec PDFs were read page-by-page; `.txt` layout files were used where available. Findings cite file:line and either a spec page or a short spec quote.

---

## Part A — Study population and attrition

**Verdict:** Match, with one policy flag and a few low-severity items.

### Attrition pipeline structure — Match
The attrition spec's 10-step structure is implemented end-to-end:

| Spec step | Code location | Status |
|---|---|---|
| Step 0 — ≥1 MM dx, any position | `criteria_attrition.R:162` | Match |
| Step 1 — MM qualifying (IP strict OR 2 OP in window) | `pipeline_steps.R:248-342` | Match; 30/60/90 windows all computed |
| Step 2 — Age ≥ 18 | `criteria_attrition.R:25-28` | Match (`cfg$min_age = 18`) |
| Step 3 — 6-mo baseline CE, ≤30-day gaps | `pipeline_steps.R:354-488` | Match (`baseline_days = 183`, `gap_days = 30`) |
| Step 4 — ≥1 day follow-up CE | `pipeline_steps.R:467-488` | Match; strict variant CE_3mosf at `:937-957` |
| Step 5 — No baseline therapy (excl) | `criteria_attrition.R:40-43` | Match |
| Step 6 — FU therapy required | `criteria_attrition.R:45-48` | Match |
| Step 7 — BL MM evidence (excl) | `pipeline_steps.R:602-620` | Match, default OFF (see policy note) |
| Step 8 — Other malignancy (excl) | `pipeline_steps.R:814-890` | Match, default OFF |
| Step 9 — Pregnancy (excl) | `pipeline_steps.R:694-747` | Match, default OFF |
| Step 10 — Clinical trial (excl) | `pipeline_steps.R:753-811` | Match, default OFF |

### A1. Medium — Attrition exclusion flags default to FALSE
**Spec:** attrition table lists Steps 7–10 as applied exclusions.
**Code:** `config_prompts.R:112-117` explicitly sets
```r
apply_pregnancy_excl    = FALSE
apply_clintrial_excl    = FALSE
apply_other_malig_excl  = FALSE
apply_baseline_mm_excl  = FALSE
```
with a comment citing a "STAKEHOLDER DECISION (2026-04-14): All exclusion flags default FALSE so the working cohort stays at the Step 6 level (~21k patients). Flags are computed in `ELIG_COH_ALLFLAGS` for ad-hoc analysis; set TRUE to apply."
**Impact:** final cohort does not exclude pregnancy / clinical trial / other cancer / baseline MM by default. Flags are fully computed — can be flipped without pipeline rebuild.
**Ask:** confirm with stakeholders this matches the intended study cohort.

### A2. Match — Inpatient detection (dual POS/TOS + confinement)
Both paths implemented and OR'd:
- Approach 1 (POS/TOS): `pipeline_steps.R:197-198` — `POS IN (21,51,61)` OR `TOS_CD IN ('FAC_IP.ACUTE','FAC_IP.REHSNF','PROF.INPVIS','FAC_IP.SNF')`
- Approach 2 (confinement): `pipeline_steps.R:157-172` — extracts `CONF_ID` requiring both `ADMIT_DATE` and `DISCH_DATE` non-null
- Combined at `pipeline_steps.R:199` with `OR` logic; QC at `:226` logs both counts separately.

### A3. Match — Strict vs broad MM code distinction
- Strict (`mm_dx_strict_flg`): `LIKE '2030%'` or `LIKE 'C900%'` — `pipeline_steps.R:206-211`
- Applied to inpatient-index qualification (`:254`) and baseline-MM evidence (`:614`)
- Outpatient uses broader `203.x` / `C90.x` via `mm_dx_events_id` — correct per spec.

### A4. Match — Multi-window (30/60/90) design
- Config: `cfg$dx_window_30/60/90` set in `config_prompts.R:94-96`
- All three windows are **computed** (`pipeline_steps.R:283-299`, flags `qualifies_30/60/90`)
- **Final filter** applies the configured `cfg$outpatient_window` (default 90) at Step 24 — `pipeline_steps.R:1001`. Comment at `:307-310` explains the "Option B" design: keep all 90d-qualified candidates so a later date can qualify if the earliest one fails IE criteria. Sound design.

### A5. Match — Death handling with month/year-level generalization
`pipeline_steps.R:521-587`:
- Month-known + index after 15th → month-end; else → 15th
- Year-only + index after Jul 15 → Dec 31; else → Jul 15
- Final clamp `DEATH_DT >= index_date` (line `:580-582`) prevents negative FU_DAYS from data issues

### A6. Match — Pregnancy/clintrial use DX + PROC + RVNU_CD
Both `Step 20` (`:721-726`) and `Step 21` (`:781-786`) include the revenue-code path that earlier spec revisions called out. Comment at `:689-691` explicitly notes "FIXED: Added revenue code (RVNU_CD) support per spec requirement."

### A7. Match — ENDDATE vs ENDDATE_CE dual framework
`pipeline_steps.R:970-974`:
- `ENDDATE = min(study_end, DEATH_DT)` — intent-to-treat tail
- `ENDDATE_CE = min(study_end, DEATH_DT, CE_f_end_date)` — observable (disenrollment = LTFU)
- `FU_DAYS = datediff(ENDDATE, index_date + 1) + 1`
- `S03_patient_input` at `lot_program.R:266` pulls both and sets `OBS_END_DT = coalesce(ENDDATE_CE, ENDDATE)`.

### A8. Low — Baseline window is hardcoded `183`, not configurable
`config_prompts.R:90`: `baseline_days = 183L`. Spec states "6 months" — 183 is a reasonable interpretation (not 180, not 6×30). Document or accept as-is.

---

## Part B — Data prep, MMA rollup, MMA meds, MAP

**Verdict:** Match overall. Two medium items on codelist validation; one spec row that needs a human eye on the PDF.

### B1. Match — MMA rollup and codelist normalization (S00, S01)
- `S00_mma_rollup` at `lot_program.R:96` correctly parses `MONOMAINTENANCE`, `DUALMAINTENANCEWITH`, `CONDITIONING`, `USED_FOR_OTHER_CANCERS` flags.
- `S01_mma_codelist` at `:124` normalizes code types and trims/uppercases codes.
- Consistency QC at `:198-211` detects:
  - orphan codelist meds not in rollup
  - rollup meds with zero codes
  - multi-class `MED_ABBR` (one med mapped to >1 `MED_CLASS`)

### B2. Medium — Multi-class `MED_ABBR` logged but not enforced
**Spec:** assumes 1:1 `MED_ABBR → MED_CLASS`.
**Code:** `lot_program.R:198-211` logs a WARNING but does not `stop()`. Downstream at `:508` (S06) a deterministic `min(MED_CLASS) AS MED_CLASS` tie-breaks silently.
**Impact:** bad codelist CSV can silently misclassify a med's class across the whole run.
**Ask:** make multi-class a hard failure, or document the `min()` tie-break as intentional with a priority order.

### B3. Medium — Permissible-substitution CSV not validated
**Code:** `lot_program.R:92-93, 137-144` loads `permissible_subs.csv` with `(original_med, substitute_med)` columns and applies only null/empty checks.
**Not validated:** self-substitutes (`A → A`), asymmetry (`A → B` without `B → A`), circular chains (`A → B → C → A`).
**Usage:** substitutions are UNION'd into base meds at `:721-724`, so a bad CSV silently inflates base-med membership.
**Ask:** add a QC check on load (self/asymmetry/cycle detection).

### B4. Match — MMA med raw & processed (S04, S05)
- Four medical sources UNION'd at `lot_program.R:299-360`: `MEDICAL.PROC_CD`, `MEDICAL.BILL_PROC_CD`, `MEDICAL.NDC`, pharmacy `RX_CLAIMS.NDC`.
- `MED_PROCEDURE.PROC` deliberately excluded at `:361-365` with comment: "Optum `med_procedure.PROC` contains ICD procedure codes, not HCPCS/NDC drug codes." Correct per Optum data dict.
- NDC11 normalization (lpad to 11 digits) applied to both medical and pharmacy at `:355-356, 383-384`.

### B5. Match — Pharmacy day-supply imputation
`lot_program.R:425-437`:
```sql
WHEN CLAIM_TYPE = 'pharmacy' AND (DAY_SUPPLY IS NULL OR DAY_SUPPLY < 1)
THEN 28
ELSE DAY_SUPPLY
```
- Imputes on NULL or `< 1` (not just NULL)
- Post-imputation QC at `:467` confirms no pharmacy rows left with invalid `DAY_SUPPLY`
- Correctly scoped to pharmacy only (medical claims get the fixed `cfg$medical_day_supply`).

### B6. Medium — `medical_day_supply = 28` cites spec row that needs human verification
**Code:** `config_lot.R:43` default `"28"` days; `lot_program.R:298` comment: "per spec (5A.MMA_MED row 15)".
**Issue:** the `mmamedapr18.pdf` row text was not readable via the automated review. 28 days is standard oncology-cycle practice, but the exact spec wording should be eyeballed by a human to confirm.
**Ask:** check `mmamedapr18.pdf` Section 5A row 15 to confirm the default matches the spec value and wording.

### B7. Match — MAP construction (S06, S07)
- `MAP_END_DT = greatest(coalesce(rx_runout, min_date), coalesce(med_runout, min_date))` at `lot_program.R:489, 564, 618` — matches `mapmedapr18.pdf` Figure 3.
- Pharmacy pushout branch: `date_add(s.rx_runout, x.ds)` when `x.dt <= s.rx_runout` (`:583`)
- Pharmacy reset branch: `date_add(x.dt, x.ds - 1)` when `x.dt > s.rx_runout` (`:587`)
- Medical no-pushout: always `date_add(x.dt, x.ds - 1)` (`:598-601`)
- Validation QC at `:2060-2071` asserts `MAP_END_DT = greatest(rx_runout, med_runout)` for all MAPs.

### B8. Low — Config defaults not cross-referenced to spec sections
`config_lot.R:40-43` defaults (`induction_window_days=60`, `map_discon_gap_days=90`, `lot_discon_gap_days=90`, `medical_day_supply=28`) are correct, but comments don't cite spec sections. `lot_program.R:298` is the exception. Worth a pass to add inline spec-citation comments for traceability.

---

## Part C — LOT1 base (start/induction/composition), SCT, MTX

**Scope note:** end-reason routing is excluded here; it's covered by the existing Apr 19 reviews. This part covers LOT1 start, induction, steroid exclusion, base composition, SCT event typing, tandem/single detection, CAR-T 45-day consolidation, and the `contains_mtx_reg` anchor rule.

**Verdict:** Match across all six mechanisms. No new critical issues.

### C1. Match — LOT1 start (S08)
`lot_program.R:687-695`: `min(MAP_START_DT)` from `map_stacked` with `MAP_MED_CLASS <> 'STEROID'`. Deterministic tie-break via `min()`. Matches `lot1baseapr18.pdf`.

### C2. Match — Induction window (60 days, inclusive)
- Config: `config_lot.R:40` — `induction_window_days = 60`
- Application: `lot_program.R:697-712` —
  ```sql
  AND ms.MAP_START_DT <= date_add(l1.LOT1_START_DT, {cfg$induction_window_days - 1})
  ```
  i.e. inclusive `[LOT1_START_DT, LOT1_START_DT + 59]`. Standard clinical interpretation of "60-day window."

### C3. Match — Steroid exclusion applied consistently
- Induction meds (S09): `lot_program.R:709` — `MAP_MED_CLASS <> 'STEROID'`
- First-add candidates (S10): `lot_program.R:792` — same filter; comment "steroids cannot trigger add-med"

### C4. Match — LOT1 base discontinuation gate
`lot_program.R:741-748`:
```sql
WHEN d.RAW_DISCON_DT IS NOT NULL
 AND datediff(p.OBS_END_DT, d.RAW_DISCON_DT) >= {cfg$lot_discon_gap_days}
THEN d.RAW_DISCON_DT
ELSE NULL
```
Requires ≥ 90 days of observation *after* the raw discon candidate before it's confirmed. Matches spec's "90-day gap" semantics.

### C5. Match — First-add-med date is one day before the trigger
`lot_program.R:715-811`:
- `base_meds = induction ∪ permissible_subs` (only then)
- `LOT1_BASE_1ST_ADD_MED_DT = date_sub(ADD_START_DT, 1)` — i.e. prior LOT ends the day before the new med starts. Correct convention.

### C6. Match — SCT codelist normalization (S11)
`lot_program.R:852-881` normalizes:
- code types (`ICD10PROC`/`ICD10PCS` → `ICD10PROC`, etc.)
- SCT types (`Allogenic` → `ALLO`, `Autologous` → `AUTO`, `CAR-T`/`CART`/`CAR_T` → `CART`)

### C7. Match — SCT claim sources and dedup (S12)
Four sources UNION'd at `lot_program.R:884-961`: `MEDICAL.PROC_CD`, `MEDICAL.BILL_PROC_CD`, `MED_PROCEDURE.PROC`, `MED_DIAGNOSIS.DIAG` (each with appropriate code-type filter). Dedup:
```sql
SELECT PATID, DATE_SERVICE, SCT_TYPE, min(CODE) AS CODE
FROM combined
GROUP BY PATID, DATE_SERVICE, SCT_TYPE
```
Preserves distinct SCT types on the same date — correct.

### C8. Match — AUTO windowing, gap, tandem (S13)
- 14-day window (stored as `sct_auto_window_days = 13` to allow 0–13 day gaps inclusive): `lot_program.R:982-1155`
- 60-day minimum gap between finalized AUTO events: `config_lot.R:sct_auto_gap_days = 60`
- Tandem window: `sct_tandem_days = 180`. Tandem gates at `:1268, :1276, :1284, :1298` use `datediff(AUTO_DT_2, AUTO_DT_1) <= 180` — correct per spec ("within 180 days, with no ALLO between")

### C9. Match — AUTO tandem vs single flag logic (S15)
`lot_program.R:1192-1355`:
- `LOT1_SCT_AUTO_TAND_FLG = 1` when `AUTO_DT_2` exists, `datediff ≤ 180`, and `n_allo_between = 0`
- `LOT1_SCT_AUTO_SING_FLG = 1` when first AUTO exists but tandem conditions fail
- ALLO-between test uses inclusive range `[AUTO_DT_1, AUTO_DT_2]`

### C10. Match — CAR-T 45-day consolidation (S16)
- Config: `config_lot.R:62` — `cart_consolidation_days = 45`
- Gate at `lot_program.R:1866-1878`:
  ```sql
  AND datediff(sct.FIRST_CART_DT, date_add(lb.LOT1_BASE_1ST_ADD_MED_DT, 1)) BETWEEN 0 AND 45
  ```
  — i.e. the add-med start is within 0–45 days before CAR-T infusion, so it's treated as consolidation (doesn't trigger a LOT end on its own).
- Minor note: config name is `cart_consolidation_days`; `mtx scenarios.pdf` may use "consolidation window" phrasing. Numeric value correct.

### C11. Match — `contains_mtx_reg` anchor rule (S16b)
`lot_program.R:1763-1808` implements the anchor rule from `mtx scenarios.pdf`:
1. Build valid maintenance regimens (mono + dual) **from actual induction meds only**, not substitution-expanded base meds — correct per spec
2. For each valid regimen, check for at least one induction med **outside** the regimen (the "anchor")
3. `contains_mtx_reg = 1` iff an anchor exists

Verified against the four documented scenarios:
- BORT mono + anchor → flag = 1
- BORT+LENA dual + anchor → flag = 1
- LENA mono, no other drug → flag = 0
- LENA+DARA dual, no other drug → flag = 0

### C12. Config summary (all defaults match Apr 18 specs)

| Parameter | Default | Spec value | Status |
|---|---|---|---|
| `induction_window_days` | 60 | 60 | Match |
| `lot_discon_gap_days` | 90 | 90 | Match |
| `sct_auto_window_days` | 13 | 14 (0–13 inclusive) | Match |
| `sct_auto_gap_days` | 60 | 60 | Match |
| `sct_tandem_days` | 180 | 180 | Match |
| `cart_consolidation_days` | 45 | 45 | Match |
| `medical_day_supply` | 28 | see B6 | Match (needs human eyeball on spec row) |

---

## Cross-cutting findings

### CC1. Policy vs spec — exclusion flags default to FALSE
See A1. This is the single most visible gap between the attrition spec and the running code; it's a deliberate stakeholder decision, not drift, but should be re-confirmed if the study pop spec is read strictly.

### CC2. Codelist input validation is light
- Multi-class `MED_ABBR` (B2) — warn only, not enforced.
- Permissible substitutions (B3) — no symmetry/self/cycle check.

Both are CSV inputs loaded at runtime; a bad file silently flows downstream. Adding load-time QC would remove a class of silent misclassification bugs at very low cost.

### CC3. Spec traceability in config
`config_lot.R` / `config_prompts.R` defaults are correct but (with one exception) don't cite spec section/row. Low severity, but matters when the spec evolves — makes it easier to update the right parameter when a spec row changes.

### CC4. Optum business rules — no violations observed
The inpatient detection dual-approach (A2), the `med_procedure.PROC` exclusion from MMA med extraction (B4), and the NDC11 normalization are all consistent with the Optum business-rules layout. Nothing flagged here.

---

## Open questions for the study team

1. **Exclusion-flag defaults (A1).** Is the "Step 6 level cohort ~21k" intentionally the working cohort, or should Steps 7–10 be applied by default? If so, flip the defaults in `config_prompts.R:112-117`.
2. **Medical day supply (B6).** Confirm `mmamedapr18.pdf` Section 5A row 15 — is 28 the spec value, or is the code carrying a prior default?
3. **Multi-class `MED_ABBR` (B2).** If a codelist CSV ever maps one `MED_ABBR` to multiple classes, should the pipeline fail, or is the current `min()` tie-break intentional with a priority ordering?
4. **Permissible substitutions (B3).** Is the substitution CSV meant to be symmetric, or one-way? Documenting the intent lets us add a targeted validator.
5. **Baseline window 183 days (A8).** Is 183 the intended interpretation of "6 months", or should this be `cfg`-driven?

---

## Out of scope / previously covered

- **Apr 19 LOT1 end-reason spec** — see `code_alignment_review.md` and `program_review_vs_apr19_spec.md`. Known issues: CART_INIT end date (`FIRST_CART_DT` vs `FIRST_CART_DT − 1`), CART_INIT tie-handling, `SCT_NO_MAINT` routing, `S16a_lot1_maintenance` subsystem, stale rule-number comments.
- **LOT 2–5** — not implemented; awaits Julia's LOT 2–5 spec.
- **R-code optimization** — see `r_code_optimization_review.md` (per-step QC overhead, report rescans).

---

*End of review.*

