# R Code Review — `Apr 18 2026/Program/` vs Finalised Spec

**Review date:** 2026-04-19
**Files reviewed:**
- `Apr 18 2026/Program/lot_program.R` (main pipeline, 2273 lines)
- `Apr 18 2026/Program/R/*.R` (modular helpers — 10 files)
- `Apr 18 2026/Program/main.R` (entry point)

**Reference spec:** `Apr 18 2026/Program Spec and Scenarios/lot1baseendupdatedapr19.pdf` with the authoritative rule numbering (Rule 1 = Discontinuation, Rule 2 = SCT / CAR-T events, Rule 3 = Death, Rule 4 = Disenrollment, Rule 5 = Study end; substitutions as a Note).

---

## Bottom line

**3 critical fixes + 2 cleanups required in `lot_program.R`.** The modular helper files in `R/` are almost entirely clean — only `config_lot.R` carries 3 deprecated maintenance parameters.

---

## Critical — must fix for spec alignment

### 1. `CART_INIT` end date: code sets `FIRST_CART_DT`; spec says `FIRST_CART_DT − 1`

| Location | Current code | Required |
|---|---|---|
| `lot_program.R:1940-1942` | `WHEN ec.CART_INIT_FLG = 1 ... THEN ec.FIRST_CART_DT` | `THEN date_sub(ec.FIRST_CART_DT, 1)` |
| `lot_program.R:1972-1974` | Same pattern inside the `LOT1_BASE_LENGTH` CASE | Same fix |

**Spec reference:** `LOT1_BASE_END_DT` Definition in `lot1baseendupdatedapr19.pdf`: *"For CAR-T transitions — including the CART_INIT case — LOT1_BASE_END_DT is the day before FIRST_CART_DT. The CAR-T LOT begins on FIRST_CART_DT."*

**Impact:** Every `CART_INIT` patient currently has their LOT1 ending 1 day later than the spec says.

---

### 2. `SCT_NO_MAINT` branch still active — must remove

Spec (`LOT1_BASE_END_REASON` Definition): *"Patients who would previously have been bucketed as SCT_NO_MAINT must be classified under the final non-maintenance LOT-ending rules above based on the earliest applicable event; SCT_NO_MAINT is not a final value in this study."*

Current code still computes `LOT1_SCT_NO_MAINT_FLG` and emits `'SCT_AUTO'` for those patients (which contradicts Rule 2's "single/tandem AUTO is continuation of the line"):

| Location | What it does | Action |
|---|---|---|
| `lot_program.R:1843-1852` | Computes `LOT1_SCT_NO_MAINT_FLG` via `MAINT_FOLLOWS_SCT_FLG` gate | Delete |
| `lot_program.R:1854-1865` | Computes `SCT_NO_MAINT_END_DT` | Delete |
| `lot_program.R:1906-1910` | `WHEN ec.LOT1_SCT_NO_MAINT_FLG = 1 THEN 'SCT_AUTO'` branch in `LOT1_BASE_END_REASON` CASE | Delete the whole branch |
| `lot_program.R:1936-1939` | Mirror branch in `LOT1_BASE_END_DT` CASE | Delete |
| `lot_program.R:1957`, `:1968-1971` | References in `LOT1_BASE_LENGTH` CASE | Delete |

**Result:** The ~926 patients previously bucketed as `SCT_NO_MAINT` will naturally fall through to `DISCONTINUATION` / `MED_ADD` / `CART_INIT` / `SCT_AUTO` (only if excess/unplanned AUTO) / `SCT_ALLO` / censoring — based on their actual next event, as the spec requires.

---

### 3. `S16a_lot1_maintenance` — remove the entire step (~370 lines)

Spec: *"The study does not derive a separate standalone maintenance period or maintenance regimen."*

`lot_program.R:1383-1761` computes a full maintenance period with start/end dates, per-med flags, and end reasons. These are no longer needed.

**Action:** Delete the entire `S16a_lot1_maintenance` `run_step()` block and every reference to `lot1_maintenance` / `LOT1_BASEMAINT_*` downstream:

- `lot_program.R:1368-1370` — drop `LOT1_MAINTENANCE` from the materialize checkpoint list.
- `lot_program.R:1831-1840` — remove `LOT1_BASEMAINT_*` passthrough columns from `S16_lot1_base_end`.
- `lot_program.R:1881` — remove the `LEFT JOIN lot1_maintenance m ON lb.PATID = m.PATID`.

`contains_mtx_reg` (in `S16b_lot1_contains_mtx_reg`) is the only maintenance-related output needed and is already correctly implemented.

---

## Cleanup — should fix with the critical items

### 4. Stale rule-number comments throughout `S16`

New numbering per Apr 19 spec: Rule 1 = Discontinuation, Rule 2 = SCT / CAR-T, Rule 3 = Death, Rule 4 = Disenrollment, Rule 5 = Study end.

| Location | Current comment | Action |
|---|---|---|
| `lot_program.R:1736` | `-- For Rule 4: is maintenance within 180 days of SCT?` | Deleted with issue 3 |
| `lot_program.R:1811` | `# End reason priority: SCT (Rule 3) > SCT_AUTO/planned (Rule 4) > CART_INIT > MED_ADD` | Update to new priority without the obsolete "(Rule 4)" tier |
| `lot_program.R:1813` | `# Apr 15 meeting: MAINTENANCE_END removed; SCT_NO_MAINT reclassified to SCT_AUTO.` | Correct per final spec to: "MAINTENANCE_END and SCT_NO_MAINT removed; former cases routed by earliest applicable event." |
| `lot_program.R:1843` | `-- C4 fix (Rule 4): planned AUTO SCT — reclassified to SCT_AUTO (was SCT_NO_MAINT)` | Deleted with issue 2 |
| `lot_program.R:1853` | `-- The SCT date for Rule 4 end` | Deleted with issue 2 |
| `lot_program.R:1886-1887` | Priority-order comment lists `SCT > SCT_AUTO(planned) > ...` | Rewrite: `SCT_ALLO > SCT_CART > SCT_AUTO (Rule 2, unplanned) > CART_INIT > MED_ADD > DISCONTINUATION > DEATH > DISENROLLMENT > STUDY_END` |
| `lot_program.R:1888` | Same "Apr 15 meeting" comment as :1813 | Same fix |
| `lot_program.R:1906` | `-- Rule 4: Planned AUTO SCT (reclassified from SCT_NO_MAINT to SCT_AUTO per Apr 15)` | Deleted with issue 2 |

---

### 5. Deprecated maintenance config parameters in `R/config_lot.R`

`R/config_lot.R:49-51`:

```r
maint_min_days         = as.integer(Sys.getenv("MAINT_MIN_DAYS", unset = "120")),
maint_post_sct_min_days = as.integer(Sys.getenv("MAINT_POST_SCT_MIN_DAYS", unset = "30")),
maint_sct_window_days  = as.integer(Sys.getenv("MAINT_SCT_WINDOW_DAYS", unset = "180")),
```

These only exist for `S16a_lot1_maintenance`. Once issue 3 is applied, these parameters have no consumers.

**Action:** Delete these 3 parameter lines from `config_lot.R`. Also remove the surrounding comment block at `:45-48` that explains them.

---

## What's already correct

| Area | Evidence |
|---|---|
| `R/config_lot.R` | `cart_consolidation_days = 45` already present (`:62`) |
| `R/codelists_lot.R` | Pure codelist loader; no spec logic to drift |
| `R/codelists.R` | Quarterly-table helpers; no drift |
| `R/db_utils.R`, `R/db_utils_lot.R` | DB helpers; no drift |
| `R/criteria_attrition.R` | Attrition criteria; no end-reason logic; no drift |
| `R/pipeline_steps.R` | Does not reference maintenance, SCT_NO_MAINT, or MAINTENANCE_END |
| `R/dashboard_lot.R` | No maintenance references |
| `R/descriptives_lot.R` | Has color mappings for `CART_INIT`, `SCT_AUTO`, `SCT_ALLO`, `SCT_CART` (`:676-681`, `:1644-1648`). No `LOT1_BASEMAINT_*` references. |
| `R/config_prompts.R` | No maintenance prompts |
| `R/cyclo_appendix_lot.R` | No maintenance references |
| `lot_program.R:709` | Steroids correctly excluded from `lot1_induction_meds` |
| `lot_program.R:1767-1808` (`S16b_lot1_contains_mtx_reg`) | Flag-only anchor logic correct per spec |
| `lot_program.R:1866-1878` | CAR-T 45-day consolidation window correctly detected |
| End-reason output set | `SCT_AUTO`, `SCT_ALLO`, `SCT_CART`, `CART_INIT`, `MED_ADD`, `DISCONTINUATION`, `DEATH`, `DISENROLLMENT`, `STUDY_END` all emitted |
| `MAINTENANCE_END` | Not emitted as a final value anywhere |

---

## Recommended execution order

1. Delete `LOT1_SCT_NO_MAINT_FLG` computation + its CASE branch in `LOT1_BASE_END_REASON` and `LOT1_BASE_END_DT` (issue 2).
2. Change `THEN ec.FIRST_CART_DT` to `THEN date_sub(ec.FIRST_CART_DT, 1)` in both `LOT1_BASE_END_DT` and `LOT1_BASE_LENGTH` CASE statements (issue 1).
3. Delete `S16a_lot1_maintenance` step, remove `lot1_maintenance` join in `S16`, remove `LOT1_BASEMAINT_*` passthrough columns (issue 3).
4. Delete `maint_min_days`, `maint_post_sct_min_days`, `maint_sct_window_days` from `config_lot.R` (issue 5).
5. Update stale rule-number comments (issue 4).
6. Rerun and verify: no `MAINTENANCE_END`, no `SCT_NO_MAINT` in `LOT1_BASE_END_REASON`; `CART_INIT` appears; `contains_mtx_reg` counts are sensible.

---

## Out of scope

- **LOT 2–5 code** — not implemented yet; awaits Julia's LOT 2–5 spec.
- **Protocol Section 5.1.1 renumbering propagation** — spec-side, not code-side.

*End of code review.*
