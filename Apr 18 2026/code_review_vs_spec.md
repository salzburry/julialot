# Code Review — `lot_program.R` vs Updated Spec

**Review date:** 2026-04-18
**Scope:** Static review of `Apr 18 2026/Program/lot_program.R` against the final spec decisions captured in `Apr 18 2026/spec_edit_instructions.md`.
**Action:** No code changes made. This document lists what needs to change, where, and why.

---

## Summary

| # | Severity | Area | Location | Status |
|---|----------|------|----------|--------|
| 1 | **CRITICAL** | `CART_INIT` end date | `lot_program.R:1942`, `:1974`, plus comparisons at `:1897`, `:1932`, `:1955`, `:1964` | Code sets `FIRST_CART_DT`; spec says `FIRST_CART_DT - 1` |
| 2 | **CRITICAL** | `SCT_NO_MAINT` handling | `lot_program.R:1843-1852`, `:1865`, `:1906-1910`, `:1936-1939`, `:1957`, `:1968` | Code relabels planned AUTO → `SCT_AUTO`; spec says route by earliest event and drop the flag entirely |
| 3 | **CRITICAL** | Maintenance-period variables still produced and persisted | `lot_program.R:1392-1761` (`S16a_lot1_maintenance`), plus `LOT1_BASEMAINT_*` columns on `lot1_base_end` | Spec: maintenance is flag-only; these columns should not exist |
| 4 | HIGH | `MAINT_FOLLOWS_SCT_FLG` gate | `lot_program.R:1736-1752` (emission), `:1849`, `:1859` (gate usage) | Only used to gate the obsolete `SCT_NO_MAINT` branch — remove with issue 2 |
| 5 | HIGH | Comment/doc references to old Rule numbering | `:1736`, `:1811`, `:1813`, `:1843`, `:1853`, `:1888`, `:1906` | Refer to "Rule 3", "Rule 4", "Rule 8" — inconsistent with the renumbered spec (Rule 3 = SCT/CAR-T; old Rules 4 and 8 gone) |
| 6 | MED | Priority-order comment | `:1886-1887` | States `SCT > SCT_AUTO(planned) > CART_INIT > ...`; `SCT_AUTO(planned)` tier is the obsolete SCT_NO_MAINT branch — should be removed from comment |
| 7 | MED | QC metrics track maintenance concepts no longer in spec | `S16a` `qc = "...n_lena_maint, n_bort_maint..."` at `:1759-1761`; also `sum(LOT1_BASEMAINT_MED_*)` | Low risk but carries obsolete concepts |
| 8 | LOW | Descriptives / Dashboard surface `LOT1_BASEMAINT_*` as variables | `R/descriptives_lot.R` (search `LOT1_BASEMAINT`) | If issue 3 is fixed upstream, descriptives need minor follow-up |

---

## What's already correct (no change needed)

| Item | Evidence |
|---|---|
| Steroid exclusion in `lot1_induction_meds` | `:709` `WHERE ... AND ms.MAP_MED_CLASS <> 'STEROID'` — protocol-consistent |
| `contains_mtx_reg` anchor check uses actual induction drugs (not permissible-sub expanded) | `:1773-1799` — correct per spec clauses (a) and (b) |
| `contains_mtx_reg` anchor check is neutral on steroids (they're already excluded at induction-meds level upstream) | Consistent with the current spec wording of clause (b) — "additional agent" (unspecified w.r.t. steroids) |
| End-reason output set includes all required values | `:1900-1905` and `:1910-1919` emit `SCT_AUTO`, `SCT_ALLO`, `SCT_CART`, `CART_INIT`, `MED_ADD`, `DISCONTINUATION`, `DEATH`, `DISENROLLMENT`, `STUDY_END` |
| `MAINTENANCE_END` is not emitted as a final value | Not present in any `THEN '...'` branch of the `LOT1_BASE_END_REASON` CASE |
| CAR-T 45-day consolidation logic implemented | `:1866-1878` — matches spec row `CART_45D_CONSOLIDATION` and Cell 4 Definition |
| `descriptives_lot.R` has colors for `CART_INIT`, `SCT_AUTO`, `SCT_ALLO`, `SCT_CART` | `R/descriptives_lot.R:676-681` |

---

## Detailed findings

### 1. `CART_INIT` end date: code says `FIRST_CART_DT`, spec says `FIRST_CART_DT - 1`

**Spec (Cell 2 Definition):**
> "For CAR-T transitions — including the CART_INIT case — LOT1_BASE_END_DT is the day before FIRST_CART_DT. The CAR-T LOT begins on FIRST_CART_DT."

**Current code (`:1940-1942`):**
```sql
WHEN ec.CART_INIT_FLG = 1
 AND (ec.LOT1_BASE_DISCON_DT IS NULL OR ec.FIRST_CART_DT <= ec.LOT1_BASE_DISCON_DT)
THEN ec.FIRST_CART_DT
```

**Parallel branch inside `LOT1_BASE_LENGTH` CASE (`:1972-1974`):**
```sql
WHEN ec.CART_INIT_FLG = 1
 AND (ec.LOT1_BASE_DISCON_DT IS NULL OR ec.FIRST_CART_DT <= ec.LOT1_BASE_DISCON_DT)
THEN ec.FIRST_CART_DT
```

**Additional comparisons that use `FIRST_CART_DT` as the tie-break target for CART_INIT (may need the same -1 adjustment or their logic reviewed):**
- `:1897` `(ec.CART_INIT_FLG = 1 AND ec.LOT1_TX_ENDDATE <= ec.FIRST_CART_DT)`
- `:1913` `AND (ec.LOT1_BASE_DISCON_DT IS NULL OR ec.FIRST_CART_DT <= ec.LOT1_BASE_DISCON_DT)`
- `:1932`, `:1955`, `:1964` — same pattern in `LOT1_BASE_END_DT` and `LOT1_BASE_LENGTH` CASE statements

**Change required:**
- In both `THEN ec.FIRST_CART_DT` lines, change to `THEN date_sub(ec.FIRST_CART_DT, 1)`.
- Review the gate comparisons (`LOT1_TX_ENDDATE <= ec.FIRST_CART_DT`, `ec.FIRST_CART_DT <= ec.LOT1_BASE_DISCON_DT`, etc.) for whether the `FIRST_CART_DT` reference there should remain (it's the CAR-T event itself, which is still correct as a landmark date) or shift to `FIRST_CART_DT - 1` (since that's the LOT end date). Most should probably stay as `FIRST_CART_DT` because they're comparing to the infusion event, not the LOT end; but this needs explicit review.

**Impact:** Patient-level LOT1 lengths for CART_INIT patients are off by 1 day today. Adjacent LOT/CAR-T transitions don't currently have a 1-day gap.

---

### 2. `SCT_NO_MAINT` handling — code relabels to `SCT_AUTO`; spec says route by earliest event

**Spec (Cell 4 Definition):**
> "Patients who would previously have been bucketed as SCT_NO_MAINT must be classified under the final non-maintenance LOT-ending rules above based on the earliest applicable event; SCT_NO_MAINT is not a final value in this study."

**Current code behavior:**

- `:1843-1852` computes `LOT1_SCT_NO_MAINT_FLG = 1` for patients with a planned single/tandem AUTO and no ALLO/CART and no maintenance period.
- `:1906-1910` routes all such patients to `LOT1_BASE_END_REASON = 'SCT_AUTO'` — which contradicts Rule 3: single/tandem AUTO is "continuation of the line" and should NOT by itself end LOT1.

**Code locations to remove or rework:**

| Line | Current code | Action |
|---|---|---|
| `:1843-1852` | Computes `LOT1_SCT_NO_MAINT_FLG` | Remove the whole CASE — no longer needed |
| `:1854-1865` | Computes `SCT_NO_MAINT_END_DT` | Remove |
| `:1906-1910` | Emits `'SCT_AUTO'` when `LOT1_SCT_NO_MAINT_FLG = 1` | Remove this CASE branch entirely — let the patient fall through to MED_ADD / DISCONTINUATION / DEATH / DISENROLLMENT / STUDY_END |
| `:1936-1939` | Mirror branch in `LOT1_BASE_END_DT` CASE | Remove |
| `:1957` | `AND (ec.LOT1_SCT_NO_MAINT_FLG = 0 OR ec.LOT1_BASE_DISCON_DT <= ec.SCT_NO_MAINT_END_DT)` | Remove this clause (the DISCONTINUATION branch no longer needs to race against `SCT_NO_MAINT_END_DT`) |
| `:1968-1971` | Mirror inside `LOT1_BASE_LENGTH` | Remove |
| `:1908-1909`, `:1937-1938` | Gate clauses referencing `SCT_NO_MAINT_END_DT` | Remove along with the branches that contain them |

**Expected effect on the cohort:**

The ~926 patients previously labelled `SCT_NO_MAINT` in the Apr 14 output will now fall into:
- `DISCONTINUATION` — if they have a 90-day gap after last induction med run-out and no other event
- `MED_ADD` — if a new non-induction agent starts
- `CART_INIT` — if a new agent is followed by CAR-T within 45 days
- `SCT_AUTO` (Rule 3) — only if a 3rd/unplanned AUTO follows
- `SCT_ALLO` / `SCT_CART` — if ALLO or CAR-T directly follows
- Censoring values — if death/disenrollment/study end intervenes first

---

### 3. Maintenance-period variables still produced

**Spec (Cell 6 Definition):**
> "contains_mtx_reg is a descriptive flag. The study does NOT derive a separate standalone maintenance period or maintenance regimen."

**Current code (`S16a_lot1_maintenance`, `:1392-1761`):** A ~370-line block that computes a full maintenance period: `MAINT_START_DT`, `MAINT_END_DT`, `LOT1_BASEMAINT_TYP`, per-med maintenance flags (`LOT1_BASEMAINT_MED_BORT`, `..._CARF`, `..._DARA`, `..._IXAZ`, `..._LENA`, `..._THAL`), and `LOT1_BASEMAINT_END_REASON` (with values `SCT`, `NON_MAINT_ADD`, `DEATH`, `DISENROLLMENT`, `STUDY_END`, `DISCONTINUATION`).

**Downstream uses of these variables:**
- `LOT1_BASE_END` emits them as passthrough columns (`:1831-1840`).
- `MAINT_FOLLOWS_SCT_FLG` is used as a gate in the `LOT1_SCT_NO_MAINT_FLG` calculation (`:1849`, `:1859`) — but that whole path is being removed per issue 2.
- QC metrics at `:1759-1761` report `n_maint_eligible`, `n_lena_maint`, `n_bort_maint`.
- `R/descriptives_lot.R` may reference these columns (see issue 8).

**Action:** Delete the entire `S16a_lot1_maintenance` block (`:1383-1761`) and remove the join + column passthrough in `S16_lot1_base_end` (`:1830-1840`, `:1881`). Replace any downstream reference to `LOT1_BASEMAINT_*` with appropriate handling (probably just drop the column — these are not in the target output per spec).

**Note:** This is the single biggest simplification in the code and removes ~370 lines. It also removes the config parameters `maint_min_days`, `maint_post_sct_min_days`, `maint_sct_window_days` from `R/config_lot.R:49-51`.

---

### 4. `MAINT_FOLLOWS_SCT_FLG` gate — no longer needed

Produced at `:1736-1752` inside `S16a_lot1_maintenance`. Used only in the `LOT1_SCT_NO_MAINT_FLG` gate at `:1849` and `:1859`. Both sites disappear when issues 2 and 3 are fixed. No separate action needed beyond those.

---

### 5. Rule numbering in comments is stale

Per the spec's renumbering convention (Rule 1 = substitutions, Rule 2 = discontinuation, Rule 3 = SCT / CAR-T events, Rule 4 = death, Rule 5 = disenrollment, Rule 6 = study end; old Rules 4 and 8 removed), the following code comments are out of date:

| Line | Current comment | Issue |
|---|---|---|
| `:1736` | `-- For Rule 4: is maintenance within 180 days of SCT?` | References deleted Rule 4 |
| `:1811` | `# End reason priority: SCT (Rule 3) > SCT_AUTO/planned (Rule 4) > CART_INIT > MED_ADD` | References deleted Rule 4 |
| `:1813` | `# Apr 15 meeting: MAINTENANCE_END removed; SCT_NO_MAINT reclassified to SCT_AUTO.` | Second half is stale per final spec (should say "removed entirely, routed by earliest event") |
| `:1843` | `-- C4 fix (Rule 4): planned AUTO SCT — reclassified to SCT_AUTO (was SCT_NO_MAINT)` | References deleted Rule 4 and obsolete behavior |
| `:1853` | `-- The SCT date for Rule 4 end` | References deleted Rule 4 |
| `:1888` | `-- Apr 15 meeting: MAINTENANCE_END removed; SCT_NO_MAINT reclassified to SCT_AUTO` | Stale per final spec |
| `:1906` | `-- Rule 4: Planned AUTO SCT (reclassified from SCT_NO_MAINT to SCT_AUTO per Apr 15)` | References deleted Rule 4 |

**Action:** Delete comments tied to removed code (issues 2 and 3). For any remaining rule references, use the new numbering (Rule 3 = SCT / CAR-T events; no Rule 4 or Rule 8).

---

### 6. Priority-order comment at `:1886-1887` is stale

**Current:**
```
-- End reason priority: SCT > SCT_AUTO(planned) > CART_INIT > MED_ADD
--   > DISCONTINUATION > DEATH > DISENROLLMENT > STUDY_END
```

The `SCT_AUTO(planned)` tier is the `SCT_NO_MAINT → SCT_AUTO` branch that is being removed. The spec priority order (Cell 4 Definition) is:

```
SCT_ALLO > SCT_CART > SCT_AUTO (Rule 3, unplanned) > CART_INIT > MED_ADD > DISCONTINUATION > DEATH > DISENROLLMENT > STUDY_END
```

**Action:** Update the comment to match the spec, using the new single `SCT_AUTO` (unplanned) tier.

---

### 7. QC metrics for removed concepts

`S16a_lot1_maintenance` ends with (`:1756-1761`):
```sql
qc = "SELECT count(*) AS n_maint_eligible, sum(LOT1_BASEMAINT_MED_LENA) AS n_lena_maint,
             sum(LOT1_BASEMAINT_MED_BORT) AS n_bort_maint FROM lot1_maintenance"
```

Once `S16a` is removed (issue 3), this QC is gone automatically. If the team wants an analogue metric on the new flag, replace with a simple counter on `contains_mtx_reg`:

```sql
SELECT contains_mtx_reg, count(*) AS n FROM lot1_contains_mtx_reg GROUP BY contains_mtx_reg
```

(This query already exists at `:1806-1808` in `S16b`.)

---

### 8. Descriptives / dashboard references to maintenance columns

`R/descriptives_lot.R` references `LOT1_BASEMAINT_*` columns in several places. Once those columns stop being emitted (issue 3), the corresponding descriptives sections need:

- Removal of any figure/table that reads `LOT1_BASEMAINT_START`, `LOT1_BASEMAINT_END`, `LOT1_BASEMAINT_TYP`, or `LOT1_BASEMAINT_MED_*`.
- Potentially a new figure/table surfacing `contains_mtx_reg` distribution (currently absent from the dashboard — flag is only in the QC metric, not in any plot).

This is a follow-on task after the main code cleanup.

---

## Recommended execution order

1. Remove the `SCT_NO_MAINT` branch in `S16_lot1_base_end` (issue 2). Also remove `LOT1_SCT_NO_MAINT_FLG` computation and `SCT_NO_MAINT_END_DT`.
2. Fix the `CART_INIT` end date in both the `LOT1_BASE_END_DT` CASE and the `LOT1_BASE_LENGTH` CASE — change `THEN ec.FIRST_CART_DT` to `THEN date_sub(ec.FIRST_CART_DT, 1)` (issue 1). Audit the other `FIRST_CART_DT` comparisons for correctness.
3. Delete the entire `S16a_lot1_maintenance` step (issue 3). Drop related joins, column passthroughs, and the `MAINT_FOLLOWS_SCT_FLG` references (issue 4).
4. Update the priority-order comment (`:1886-1887`) and delete stale Rule-4/Rule-8 comments (issues 5, 6).
5. Clean up `config_lot.R` maintenance parameters (`maint_min_days`, `maint_post_sct_min_days`, `maint_sct_window_days`).
6. Update `R/descriptives_lot.R` to remove references to `LOT1_BASEMAINT_*` columns and optionally add a `contains_mtx_reg` figure (issue 8).
7. Rerun and verify the new end-reason distribution: no `MAINTENANCE_END`, no `SCT_NO_MAINT`, `CART_INIT` present, `SCT_AUTO` only for unplanned/excess AUTO.

---

## Out of scope for this review

- **LOT 2–5 code** — not implemented yet; Julia owes the spec.
- **Protocol Section 5.1.1 renumbering propagation** — spec-only concern; the code only has comment references.
- **Spec edits themselves** — see `spec_edit_instructions.md`.

---

*End of code review.*
