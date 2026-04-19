# R Code Review — `Apr 18 2026/Program/` vs Apr 19 Spec (Consolidated)

**Review date:** 2026-04-19
**Scope:** Code review of the R program against `lot1baseendupdatedapr19.pdf`. No code changes made.
**Files reviewed:**
- `Apr 18 2026/Program/lot_program.R` (main pipeline)
- `Apr 18 2026/Program/R/*.R` (modular helpers)
- `Apr 18 2026/Program/main.R`

This review merges two independent passes. Every issue below has been verified directly against the code and the Apr 19 spec extract.

---

## Bottom line

Three critical fixes plus two cleanups in `lot_program.R`. The modular `R/` helpers are clean except for three deprecated maintenance parameters in `config_lot.R`. The issues are concentrated in one area: **LOT1 end-reason routing still depends on the old maintenance-period framework.**

---

## 1. Critical — CART_INIT end date uses `FIRST_CART_DT`; spec says `FIRST_CART_DT − 1`

**Spec (`lot1baseendupdatedapr19.pdf`):** For CAR-T transitions, including CART_INIT, `LOT1_BASE_END_DT` is the day before `FIRST_CART_DT`.

**Code:**

| Location | Current | Required |
|---|---|---|
| `lot_program.R:1940-1942` | `WHEN ec.CART_INIT_FLG = 1 ... THEN ec.FIRST_CART_DT` | `THEN date_sub(ec.FIRST_CART_DT, 1)` |
| `lot_program.R:1972-1974` | Same pattern inside `LOT1_BASE_LENGTH` CASE | Same fix |

**Impact:** Every CART_INIT patient currently has LOT1_BASE_END_DT off by one day and LOT1_BASE_LENGTH off by one day.

---

## 2. Critical — CART_INIT tie-handling against discontinuation uses the infusion date instead of the spec end date

**Spec:** CART_INIT ends LOT1 on `FIRST_CART_DT − 1`. Priority order puts CART_INIT strictly above DISCONTINUATION when end dates tie.

**Code gates currently compare `FIRST_CART_DT` (the infusion event date) against `LOT1_BASE_DISCON_DT`, so a tie on the true end date (DISCON_DT = `FIRST_CART_DT − 1`) misroutes the patient to DISCONTINUATION:**

| Location | Current gate | Required |
|---|---|---|
| `lot_program.R:1912-1913` (CART_INIT branch of `LOT1_BASE_END_REASON`) | `ec.FIRST_CART_DT <= ec.LOT1_BASE_DISCON_DT` | `date_sub(ec.FIRST_CART_DT, 1) <= ec.LOT1_BASE_DISCON_DT` |
| `lot_program.R:1940-1941` (CART_INIT branch of `LOT1_BASE_END_DT`) | Same pattern | Same fix |
| `lot_program.R:1955-1956` (DISCON branch of `LOT1_BASE_LENGTH`) | `ec.LOT1_BASE_DISCON_DT <= ec.FIRST_CART_DT` | `ec.LOT1_BASE_DISCON_DT <= date_sub(ec.FIRST_CART_DT, 1)` (so DISCON wins only when DISCON's end < CART_INIT's end) |
| `lot_program.R:1972-1974` (CART_INIT branch of `LOT1_BASE_LENGTH`) | Same as `:1912-1913` | Same fix |

**Also flag for review (similar pattern, different comparison axis):** `lot_program.R:1897`, `:1932`, `:1964` compare the SCT end date `LOT1_TX_ENDDATE` to `FIRST_CART_DT`. Because SCT priority > CART_INIT priority, the tie-break is slightly different — these should be re-checked as part of the same fix to ensure the new spec's end-date semantics are respected consistently.

---

## 3. Critical — `SCT_NO_MAINT` branch still active

**Spec:** *"Patients who would previously have been bucketed as SCT_NO_MAINT must be classified under the final non-maintenance LOT-ending rules above based on the earliest applicable event; SCT_NO_MAINT is not a final value in this study."*

**Code still emits SCT_AUTO from the `SCT_NO_MAINT` path, driven by the deprecated `MAINT_FOLLOWS_SCT_FLG` gate:**

| Location | What it does | Action |
|---|---|---|
| `lot_program.R:1843-1852` | Computes `LOT1_SCT_NO_MAINT_FLG` (driven by `MAINT_FOLLOWS_SCT_FLG`) | Delete |
| `lot_program.R:1854-1865` | Computes `SCT_NO_MAINT_END_DT` | Delete |
| `lot_program.R:1906-1910` | `WHEN ec.LOT1_SCT_NO_MAINT_FLG = 1 THEN 'SCT_AUTO'` branch | Delete the whole branch |
| `lot_program.R:1936-1939` | Mirror branch in `LOT1_BASE_END_DT` | Delete |
| `lot_program.R:1957` | `AND (ec.LOT1_SCT_NO_MAINT_FLG = 0 OR ...)` gate in `LOT1_BASE_LENGTH` | Delete |
| `lot_program.R:1968-1971` | Mirror inside `LOT1_BASE_LENGTH` | Delete |

**Result:** The ~926 patients previously bucketed `SCT_NO_MAINT` will naturally fall through to `DISCONTINUATION` / `MED_ADD` / `CART_INIT` / `SCT_AUTO` (only for 3rd/unplanned AUTO) / `SCT_ALLO` / censoring — driven by their actual earliest event, as the spec requires.

---

## 4. Medium — `S16a_lot1_maintenance` subsystem: ~370 lines, still active and exported

**Spec:** The Apr 19 end-spec retains `contains_mtx_reg` as the maintenance concept and frames it as descriptive only. No corresponding `LOT1_BASEMAINT_*` rows exist in the spec.

**Code still derives a full maintenance-period framework:**

| Location | What it does |
|---|---|
| `lot_program.R:1392-1761` (`S16a_lot1_maintenance`) | Builds `MAINT_START_DT`, `MAINT_END_DT`, `LOT1_BASEMAINT_TYP`, `LOT1_BASEMAINT_MED_*`, `LOT1_BASEMAINT_END_REASON`, `MAINT_FOLLOWS_SCT_FLG` |
| `lot_program.R:1368-1370` | Registers `LOT1_MAINTENANCE` in the materialize-checkpoint list |
| `lot_program.R:1831-1840` | Carries all `LOT1_BASEMAINT_*` columns into `lot1_base_end` as passthrough outputs |
| `lot_program.R:1881` | `LEFT JOIN lot1_maintenance m ON lb.PATID = m.PATID` inside `S16` |
| `R/config_lot.R:45-51` | Parameters `maint_min_days`, `maint_post_sct_min_days`, `maint_sct_window_days` existing only for `S16a` |

**Action:** Decide whether `lot1_maintenance` is needed anywhere outside historical reference/QC.
- If not, delete the entire `S16a` block, the materialize-checkpoint entry, the join in `S16`, the passthrough columns, and the 3 config parameters.
- If any `LOT1_BASEMAINT_*` outputs must stay temporarily, document them as legacy / non-spec outputs until removed.

Note: `S16a` is the reason the deprecated `SCT_NO_MAINT` routing (issue 3) still exists — removing it unblocks that cleanup.

---

## 5. Cleanup — stale rule-number comments throughout `S16`

Apr 19 spec numbering: Rule 1 = Discontinuation, Rule 2 = SCT / CAR-T events, Rule 3 = Death, Rule 4 = Disenrollment, Rule 5 = Study end. Substitutions are a Note, not a rule.

| Location | Current comment | Action |
|---|---|---|
| `lot_program.R:1736` | `-- For Rule 4: is maintenance within 180 days of SCT?` | Deleted with issue 4 |
| `lot_program.R:1811` | `# End reason priority: SCT (Rule 3) > SCT_AUTO/planned (Rule 4) > CART_INIT > MED_ADD` | Rewrite to current priority (see below) |
| `lot_program.R:1813` | `# Apr 15 meeting: MAINTENANCE_END removed; SCT_NO_MAINT reclassified to SCT_AUTO.` | Correct per final spec: "MAINTENANCE_END and SCT_NO_MAINT removed; former cases routed by earliest applicable event." |
| `lot_program.R:1843`, `:1853`, `:1906` | `-- C4 fix (Rule 4)`, `-- The SCT date for Rule 4 end`, `-- Rule 4: Planned AUTO SCT ...` | Deleted with issue 3 |
| `lot_program.R:1886-1887` | Priority comment lists `SCT > SCT_AUTO(planned) > ...` | Rewrite: `SCT_ALLO > SCT_CART > SCT_AUTO (Rule 2, unplanned) > CART_INIT > MED_ADD > DISCONTINUATION > DEATH > DISENROLLMENT > STUDY_END` |
| `lot_program.R:1888` | Duplicate of `:1813` stale comment | Same fix |

---

## What is already correct

| Area | Evidence |
|---|---|
| Steroid exclusion in induction meds | `lot_program.R:709` |
| `contains_mtx_reg` flag + anchor logic (`S16b`) | `lot_program.R:1767-1808` |
| CAR-T 45-day consolidation detection | `lot_program.R:1866-1878` |
| End-reason output set emits all 9 required values | `lot_program.R:1900-1920` |
| `MAINTENANCE_END` not emitted as final value | No `THEN 'MAINTENANCE_END'` anywhere |
| Dashboard / descriptives color mappings for `CART_INIT`, `SCT_*` | `R/descriptives_lot.R:676-681`, `:1644-1648` |
| Modular helpers (`R/*.R`) free of maintenance drift | Scans returned no matches for `MAINT`, `SCT_NO_MAINT`, `MAINTENANCE_END`, or obsolete rule numbers except the 3 config params |

---

## Recommended execution order

1. **Remove the `SCT_NO_MAINT` path** in `S16` (issue 3). This depends on nothing else.
2. **Fix CART_INIT end date** (issue 1). Change `THEN ec.FIRST_CART_DT` → `THEN date_sub(ec.FIRST_CART_DT, 1)` in both `LOT1_BASE_END_DT` and `LOT1_BASE_LENGTH` CASE statements.
3. **Fix CART_INIT tie-handling gates** (issue 2). Update `ec.FIRST_CART_DT <= ec.LOT1_BASE_DISCON_DT` (and its inverse) to use `date_sub(ec.FIRST_CART_DT, 1)`. Review the `LOT1_TX_ENDDATE <= ec.FIRST_CART_DT` comparisons at `:1897`, `:1932`, `:1964` for consistent semantics.
4. **Delete `S16a_lot1_maintenance`** (issue 4): drop the run_step block, the checkpoint entry, the join in `S16`, the passthrough columns, and the 3 config parameters in `R/config_lot.R:45-51`.
5. **Update stale comments** (issue 5). Most get deleted with issues 3 and 4; rewrite what survives to match Apr 19 numbering.
6. **Rerun and verify:** no `MAINTENANCE_END`, no `SCT_NO_MAINT` in `LOT1_BASE_END_REASON`; `CART_INIT` present; `contains_mtx_reg` counts sensible; CART_INIT patients have `LOT1_BASE_END_DT = FIRST_CART_DT − 1` in the output.

---

## Out of scope

- **LOT 2–5 code** — not implemented yet; awaits Julia's LOT 2–5 spec.
- **Protocol Section 5.1.1 renumbering propagation** — spec-side, not code-side.

*End of consolidated review.*
