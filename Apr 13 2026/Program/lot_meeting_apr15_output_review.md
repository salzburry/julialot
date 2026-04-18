# LOT Program Review: Apr 15 Meeting + Apr 14 Output

**Date:** 2026-04-16  
**Review type:** Static review only. No code changes made.  
**Scope:** Apr 15 meeting transcript, Apr 14 LOT output, Apr 13 protocol/spec set, current modularized LOT code

## Files reviewed

- `C:/Users/onkar/Documents/GitHub/julialot/Apr 13 2026/meeting minutes apt 15`
- `C:/Users/onkar/Documents/GitHub/julialot/Apr 13 2026/lot output apr 14.pdf`
- `C:/Users/onkar/Documents/GitHub/julialot/Apr 13 2026/Protocol/Lot protocol Apr 13.pdf`
- `C:/Users/onkar/Documents/GitHub/julialot/Apr 13 2026/Program/lot_program.R`
- `C:/Users/onkar/Documents/GitHub/julialot/Apr 13 2026/Program/R/descriptives_lot.R`
- `C:/Users/onkar/Documents/GitHub/julialot/Apr 13 2026/Program/R/config_lot.R`
- `C:/Users/onkar/Documents/GitHub/julialot/Apr 13 2026/Program Spec and Scenarios/lotbaseendapr14_layout.txt`
- `C:/Users/onkar/Documents/GitHub/julialot/Apr 13 2026/Program Spec and Scenarios/clmmarollupapr14_layout.txt`
- `C:/Users/onkar/Documents/GitHub/julialot/Apr 13 2026/codelist.pdf`
- `C:/Users/onkar/Documents/GitHub/julialot/Apr 13 2026/sensitivity cbecks.pdf`

---

## Executive Summary

The main conclusion from the Apr 15 meeting is:

- the study is not dropping maintenance-regimen recognition entirely
- the study is dropping maintenance as a formal derived LOT period / LOT-ending construct
- the code should keep enough regimen logic to derive a new final flag, `contains_mtx_reg`
- the code should stop using full maintenance-period outputs to drive `LOT1_BASE_END_REASON`, `LOT1_BASE_END_DT`, and `LOT1_BASE_LENGTH`

So the right implementation target is not:

- "remove maintenance completely"

The right implementation target is:

- keep maintenance-combination recognition for the final flag
- retire maintenance-period derivation as a final LOT1 end-reason mechanism

The current code still implements a full maintenance-period engine and still uses it for final LOT1 end classification. The Apr 14 output still reflects that older logic. So the combined report is directionally correct, but it needed two clarifications:

1. maintenance recognition stays, but only as a flag-level concept  
2. `contains_mtx_reg` needs a broader anchor definition than "non-maintenance drug"

---

## What The Apr 15 Decision Actually Means

### What stays

- recognition of valid maintenance-approved mono/dual regimens
- use of Tab 40 rollup values for valid maintenance combinations
- enough logic to determine whether LOT1 induction contains a valid maintenance-approved subset with an anchor

### What goes away

- formal maintenance-period derivation as a LOT-ending construct
- `MAINTENANCE_END` as a final LOT1 end reason
- `SCT_NO_MAINT` as a separate final LOT1 end reason
- maintenance-period duration thresholds as decision rules for final LOT1 end classification

### Current code still does the old thing

The current code still builds and uses a full maintenance engine:

- `lot_program.R:1392-1763` builds `lot1_maintenance`
- `lot_program.R:1712-1755` outputs `LOT1_BASEMAINT_*` and `MAINT_FOLLOWS_SCT_FLG`
- `lot_program.R:1766-1922` still gives `SCT_NO_MAINT` and `MAINTENANCE_END` formal priority in final LOT1 end logic

That is why this is still a real implementation gap.

---

## Critical Issues That Need To Be Fixed

### 1. Retire maintenance-period logic as a LOT-ending construct, but do not remove maintenance-regimen recognition

**Severity:** Critical

### Current problem

The code still uses maintenance-period outputs in final LOT1 end derivation:

- `lot_program.R:1786-1794` carries `LOT1_BASEMAINT_*` fields into `end_candidates`
- `lot_program.R:1802-1812` uses `MAINT_FOLLOWS_SCT_FLG` to define `LOT1_SCT_NO_MAINT_FLG`
- `lot_program.R:1860-1863` still creates `MAINTENANCE_END`
- `lot_program.R:1885-1888` still uses `LOT1_BASEMAINT_END` as the final end date
- `lot_program.R:1914-1916` still uses `LOT1_BASEMAINT_END` in `LOT1_BASE_LENGTH`

### Why this conflicts with the meeting

The meeting says:

- maintenance is now a discussion/flag concept
- it is no longer supposed to be a formally defined LOT period for this study

### Precise instruction

Do not delete all maintenance logic blindly.

Instead:

1. keep enough maintenance-regimen recognition logic to identify valid maintenance-approved subsets in LOT1 induction
2. stop using maintenance-period outputs to determine final LOT1 end reason/date/length
3. retire `lot1_maintenance` as an end-reason driver
4. keep or refactor only the subset of logic needed to support `contains_mtx_reg`

---

### 2. Add `contains_mtx_reg` to the final output, using the correct anchor definition

**Severity:** Critical

### Current problem

The current code has no `contains_mtx_reg` output in the final dataset.

The updated spec row is visible in:

- `lotbaseendapr14_layout.txt:772-781`

### Correct definition

`contains_mtx_reg = 1` when LOT1 induction contains:

- at least one valid maintenance-approved mono or dual subset
- plus at least one additional induction agent outside that chosen subset

That additional anchor agent:

- does not have to be globally non-maintenance
- may itself be maintenance-eligible in another context

This is important for regimens like:

- `DARA + LENA + BORT`

where all 3 agents may be maintenance-eligible in some way, but one of them can still anchor a valid remaining subset.

### Precise instruction

Implement `contains_mtx_reg` as:

1. derive all valid mono/dual maintenance-approved subsets from the induction regimen
2. for each candidate subset, check whether at least one additional induction drug exists outside that subset
3. set `contains_mtx_reg = 1` if any such anchored subset exists
4. persist the flag in the final `lot1_base_end` output

Do not implement this as:

- "valid subset plus a strictly non-maintenance anchor"

---

### 3. `SCT_NO_MAINT` should no longer exist as a separate final end-reason bucket

**Severity:** High

### Current problem

The code still explicitly derives and emits this bucket:

- `lot_program.R:1805-1818` builds `LOT1_SCT_NO_MAINT_FLG` and `SCT_NO_MAINT_END_DT`
- `lot_program.R:1850-1853` emits `SCT_NO_MAINT`

### Why this is not just a deletion

The current `SCT_AUTO` branch is:

- `lot_program.R:1839-1847`

and it depends on:

- `LOT1_TX_ENDDATE`
- `LOT1_TX_ENDDATE_REASON = 1`

Those are not the same patients as current `SCT_NO_MAINT` patients.

If you simply delete the `SCT_NO_MAINT` branch:

- those patients will not automatically become `SCT_AUTO`
- they may fall through to `MED_ADD`, `DISCONTINUATION`, or censoring

### Precise instruction

If the agreed new bucket is `SCT_AUTO`, then:

1. keep identifying the planned AUTO / tandem AUTO cases that used to become `SCT_NO_MAINT`
2. explicitly route those patients into `SCT_AUTO`
3. use the planned AUTO date (`SCT_NO_MAINT_END_DT` or its replacement) as the end date for that rerouted branch
4. only then remove `SCT_NO_MAINT` as a final displayed category

---

### 4. `MAINTENANCE_END` should no longer exist as a separate final end-reason bucket

**Severity:** High

### Current problem

The code still emits:

- `lot_program.R:1860-1863` -> `MAINTENANCE_END`

and still uses it in:

- `lot_program.R:1885-1888`
- `lot_program.R:1914-1916`

### Precise instruction

Remove `MAINTENANCE_END` from the final end-reason/date/length logic.

These patients should then fall through to:

- `DISCONTINUATION`
- or `DEATH`
- or `DISENROLLMENT`
- or `STUDY_END`

based on the normal non-maintenance end logic.

Do not retain a dedicated maintenance-ending branch once the study has moved to flag-only maintenance recognition.

---

### 5. CAR-T 45-day logic still needs to be changed to match the meeting decision

**Severity:** High

### Current problem

The meeting language is:

- if a patient has a new medication added
- and then within 45 days of that new medication starts CAR-T
- the LOT1 end reason should not remain `MED_ADD`
- it should be treated as CAR-T initiation

The current code still checks the opposite direction:

- `lot_program.R:1823-1829`

```sql
datediff(date_add(lb.LOT1_BASE_1ST_ADD_MED_DT, 1), sct.FIRST_CART_DT) BETWEEN 0 AND {cfg$cart_consolidation_days}
```

That expression means:

- add-med start is on or after CAR-T

So the code still captures:

- CAR-T first, add-med after

not the meeting's stated logic:

- add-med first, CAR-T after

### Additional current gap

Even when `CART_CONSOL_FLG = 1`, the current code only suppresses `MED_ADD`:

- `lot_program.R:1854-1858`

It does not positively map those patients to a new end reason such as `CART_INIT`.

### Precise instruction

Update the logic so that it checks:

- `datediff(FIRST_CART_DT, actual_add_med_start_dt) BETWEEN 0 AND 45`

for the meeting's stated direction.

Then:

1. add an explicit `CART_INIT` end-reason branch, or whatever final label the team approves
2. use `FIRST_CART_DT` as the end date for that branch
3. update downstream reporting colors/tables if this new category is added
4. clarify with Julia whether both directions should be supported, or only the meeting direction

---

## Medium-Priority Issues

### 6. Runtime rollup CSV must match the Apr 15 maintenance sign-offs

**Severity:** Medium

### Current importance

The code is now CSV-only, so the maintenance-approved combinations used for `contains_mtx_reg` depend entirely on the runtime rollup.

### Signed-off combinations from the meeting/spec

- `DARA` dual with `LENA`
- `LENA` dual with `BORT`, `CARF`, `DARA`
- `THAL` mono-maintenance = `1`
- `BORT` dual with `LENA`
- `CARF` dual with `LENA`

### Precise instruction

Before the next run:

1. verify the server-side `cl_mma_rollup.csv`
2. confirm the loaded values match `clmmarollupapr14`
3. verify the runtime file used by the program, not just the reviewed PDF

---

### 7. Reporting/dashboard layer must be updated along with core logic

**Severity:** Medium

### Current problem

`descriptives_lot.R` still hardcodes the old categories:

- `descriptives_lot.R:680` includes `SCT_NO_MAINT` and `MAINTENANCE_END`
- `descriptives_lot.R:1648` includes `SCT_NO_MAINT` and `MAINTENANCE_END` in the Sankey color mapping

### Precise instruction

When the core logic is changed:

1. remove `SCT_NO_MAINT` and `MAINTENANCE_END` from chart/table/Sankey color maps
2. add `CART_INIT` if that new category is implemented
3. review labels/captions/legends for any remaining maintenance-as-end-state wording
4. regenerate the dashboard only after the code/output categories are aligned

---

### 8. Add targeted QC outputs for clinically unexpected first-line regimens

**Severity:** Medium

### Current state

The CYCLO appendix exists, but there are no dedicated QC extracts yet for:

- `BEND`
- `DARA + POMA`

### Precise instruction

Add focused QC outputs once Peter's broader review list is finalized:

1. patient-level export for LOT1 regimens containing `BEND`
2. patient-level export for LOT1 regimens containing `DARA + POMA`
3. keep using the existing CYCLO appendix for cyclophosphamide follow-up checks
4. share patient-level outputs only through the approved secure path

---

### 9. LOT2-5 remain out of scope for this cleanup, but the transition dependency should be acknowledged

**Severity:** Medium

### Current state

The code still only builds LOT1.

### Precise instruction

Do not block this LOT1 cleanup on LOT2-5.

But note for next sprint:

1. LOT2+ induction window becomes 30 days
2. LOT2+ can start with CAR-T / ALLO / AUTO as well as new-agent logic
3. the old Optum LOT2-5 reference spec should be reviewed before implementation starts

---

## Low-Priority / Informational

### 10. Top 15/25 induction regimen table does not look like a confirmed logic bug

The meeting discussion ends with the view that the figures themselves appear correct, though the dashboard/table refresh was still needed.

Small improvement only:

- if desired, add `pct` to the saved regimen table in `descriptives_lot.R`

---

### 11. Attrition review did not identify a new issue

The Apr 14 attrition table looks consistent with the prior cohort review and does not introduce a new LOT-specific action item here.

---

## Config And QC Cleanup Required By The New Maintenance Decision

### Current config still assumes full maintenance-period derivation

- `config_lot.R:46-48`

Current parameters:

- `maint_min_days`
- `maint_post_sct_min_days`
- `maint_sct_window_days`

### Current QC still assumes maintenance is a formal derived period

- `lot_program.R:1757-1762`

Current QC outputs:

- `n_with_maintenance`
- `avg_maint_duration`
- `n_maint_post_sct`

### Precise instruction

Once maintenance becomes flag-only:

1. remove or retire config parameters that only support formal maintenance-period derivation
2. remove or rewrite QC metrics that summarize maintenance duration as if it were still a final analysis object
3. replace them with QC tied to `contains_mtx_reg`, for example:
   - count of patients with `contains_mtx_reg = 1`
   - counts by valid mono vs dual maintenance-approved subset
   - counts by anchored regimen pattern

---

## Revised Implementation Order

### Before the Apr 23 meeting

1. retire maintenance-period logic as a LOT-ending construct, but keep maintenance-recognition logic for flagging
2. add `contains_mtx_reg` with the corrected anchor definition
3. reroute `SCT_NO_MAINT` cases explicitly into the approved replacement bucket
4. remove `MAINTENANCE_END` from final end logic
5. update CAR-T 45-day logic to match the meeting direction and add a positive end-reason path if approved
6. verify runtime `cl_mma_rollup.csv` matches the signed-off combinations
7. update `descriptives_lot.R` to remove obsolete categories and add any new category
8. refresh and redistribute the dashboard after category alignment

### Next sprint

1. retire obsolete maintenance config and QC
2. add targeted BEND / DARA+POMA QC exports
3. start LOT2-5 specification and implementation planning

---

## Bottom Line

The combined review mostly makes sense, but the most precise way to state the maintenance decision is:

- maintenance-regimen recognition stays
- maintenance-period derivation should stop driving final LOT1 end logic
- the new deliverable is `contains_mtx_reg`, not a formal maintenance phase

So you were not mistaken to question the wording. Maintenance was not removed entirely. But the current code still uses it in exactly the way the Apr 15 meeting says the study no longer wants, which is why this remains a real set of fixes rather than just a wording issue.
