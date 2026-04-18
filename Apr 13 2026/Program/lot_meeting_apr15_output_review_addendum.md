# Addendum: Review of Combined Apr 15 LOT Issues Report

**Context:** This note reviews the combined Apr 15 meeting/output report and highlights a few additional issues or corrections that should be captured before implementation.

**Reviewed against:**
- `C:/Users/onkar/Documents/GitHub/julialot/Apr 13 2026/meeting minutes apt 15`
- `C:/Users/onkar/Documents/GitHub/julialot/Apr 13 2026/Program/lot_program.R`
- `C:/Users/onkar/Documents/GitHub/julialot/Apr 13 2026/Program/R/descriptives_lot.R`
- `C:/Users/onkar/Documents/GitHub/julialot/Apr 13 2026/Program/R/config_lot.R`
- `C:/Users/onkar/Documents/GitHub/julialot/Apr 13 2026/Program Spec and Scenarios/lotbaseendapr14_layout.txt`

**Review type:** Static review only. No code changes made.  
**Date:** 2026-04-15

---

## Summary

The combined review is directionally strong, but I would add or adjust **three important points** before using it as the final implementation guide:

1. the proposed `contains_mtx_reg` definition is currently a bit too narrow
2. removing maintenance-driven end reasons will also require **descriptives/dashboard** updates, not just core `lot_program.R` edits
3. reclassifying `SCT_NO_MAINT` to `SCT_AUTO` is **not** just deleting a branch; it needs an explicit new mapping path

There is also one cleanup item that the combined review does not call out:

4. once maintenance is no longer a LOT-defining construct, several maintenance config parameters and QC outputs become dead / misleading

---

## Additional Issues / Corrections

### A1. `contains_mtx_reg` should not require a specifically non-maintenance anchor agent

**Why this matters**

The combined report says the flag should require:

- a valid maintenance regimen
- plus "at least one non-maintenance drug also in induction"

That is probably **too strict** based on the meeting transcript.

### Evidence from the meeting

The transcript says:

- the regimen must be "anchored to something"
- that anchor "could be a valid maintenance medication, actually"
- the specific example `DARA + LENA + BORT` is discussed as complicated precisely because all three are maintenance-eligible in some way

So the real requirement is not:

- "valid maintenance subset + non-maintenance drug"

It is closer to:

- "valid maintenance subset + at least one additional induction agent outside the chosen subset, so a transition could theoretically be anchored"

That extra anchor agent may itself be maintenance-eligible in another context.

### Why this changes implementation

A rule like:

- `valid maintenance subset AND at least one non-maintenance drug`

would incorrectly miss certain anchorable regimens such as:

- `BORT + DARA + LENA`

if the study team intends one drug to anchor a valid remaining subset such as `DARA + LENA` or `BORT + LENA`.

### Recommendation

Before implementing `contains_mtx_reg`, refine the requirement to:

- identify valid maintenance-approved mono/dual subsets
- require at least one additional induction agent **outside that chosen subset**
- do **not** hardcode that the extra anchor must be globally non-maintenance

---

### A2. The combined review should explicitly include downstream dashboard/report cleanup

**Why this matters**

Even if `lot_program.R` is updated correctly, the reporting layer will still surface outdated maintenance-based categories unless it is changed too.

### Current downstream code still hardcodes removed categories

In `descriptives_lot.R`:

- `C:/Users/onkar/Documents/GitHub/julialot/Apr 13 2026/Program/R/descriptives_lot.R:675-680`

the LOT1 end-reason chart still includes:

- `SCT_NO_MAINT`
- `MAINTENANCE_END`

Those same categories also appear later in the file in the Sankey / color mapping logic:

- `C:/Users/onkar/Documents/GitHub/julialot/Apr 13 2026/Program/R/descriptives_lot.R:1648`

### Why this matters operationally

If the team updates only `lot_program.R`:

- old categories can still appear in charts, tables, legends, or zero-state views
- dashboard outputs may silently drift from the new study decision

### Recommendation

Add an explicit work item to:

- remove `SCT_NO_MAINT` and `MAINTENANCE_END` from `descriptives_lot.R`
- update LOT1 end-reason plots/tables/Sankey colors to the new final category set
- update any text labels or captions that still describe maintenance as a formal end-reason path

---

### A3. Reclassifying `SCT_NO_MAINT` to `SCT_AUTO` is not just a rename

**Why this matters**

The combined review is right that `SCT_NO_MAINT` should likely disappear, but the implementation note should be more explicit.

### Current code structure

`SCT_AUTO` currently comes only from the existing LOT-ending SCT path:

- `C:/Users/onkar/Documents/GitHub/julialot/Apr 13 2026/Program/lot_program.R:1839-1847`

That branch uses:

- `LOT1_TX_ENDDATE`
- `LOT1_TX_ENDDATE_REASON = 1`

which corresponds to the **existing** LOT-ending SCT logic (unplanned/excess AUTO path).

By contrast, planned AUTO patients with no maintenance are currently handled separately by:

- `LOT1_SCT_NO_MAINT_FLG`
- `SCT_NO_MAINT_END_DT`

at:

- `C:/Users/onkar/Documents/GitHub/julialot/Apr 13 2026/Program/lot_program.R:1796-1818`

### Why this matters

If you simply delete the `SCT_NO_MAINT` branch:

- those patients will not automatically become `SCT_AUTO`
- they may instead fall through to `MED_ADD`, `DISCONTINUATION`, or censoring

### Recommendation

The fix needs to say explicitly:

- planned AUTO / tandem-AUTO-without-maintenance cases should be mapped into the desired new end-reason bucket using the planned AUTO date
- not merely "remove `SCT_NO_MAINT`"

If the final label is `SCT_AUTO`, then code must deliberately route those cases into `SCT_AUTO` using `SCT_NO_MAINT_END_DT` (or its successor date field).

---

### A4. If maintenance becomes flag-only, maintenance config/QC artifacts become dead or misleading

**Why this matters**

The combined review focuses on logic branches, but once maintenance is no longer a LOT-defining construct, several parameters and QC summaries become obsolete or at least misleading.

### Current config still exposes maintenance-duration rules

In `config_lot.R`:

- `C:/Users/onkar/Documents/GitHub/julialot/Apr 13 2026/Program/R/config_lot.R:46-48`

the code still exposes:

- `maint_min_days`
- `maint_post_sct_min_days`
- `maint_sct_window_days`

Those parameters matter only if maintenance is being operationalized as a formal period.

### Current QC / output also assumes full maintenance derivation

In `lot_program.R`:

- `C:/Users/onkar/Documents/GitHub/julialot/Apr 13 2026/Program/lot_program.R:1757-1762`

the QC still reports:

- `n_with_maintenance`
- average maintenance duration
- maintenance counts post-SCT

Those would become confusing or invalid once the study switches to flag-only maintenance inclusion.

### Recommendation

Add an explicit cleanup item to:

- remove or retire maintenance-period config parameters if they are no longer used
- remove maintenance-period QC summaries that would no longer be meaningful
- replace them with QC for the new `contains_mtx_reg` flag instead

---

## Suggested Adjustment to the Combined Review

The combined report is strong, but I would revise these two lines conceptually:

### Instead of

- "`contains_mtx_reg` requires at least one non-maintenance drug also in induction"

### Prefer

- "`contains_mtx_reg` requires a valid maintenance-approved subset plus at least one additional induction agent outside that subset (anchor), which may or may not itself be maintenance-eligible in another context"

### And add explicitly

- dashboard/report category cleanup must be included
- `SCT_NO_MAINT -> SCT_AUTO` requires a new routing branch, not just branch deletion
- maintenance config/QC artifacts should be retired or replaced once maintenance becomes flag-only

---

## Bottom Line

The combined review is mostly right, but I would add:

1. a more precise anchor definition for `contains_mtx_reg`
2. explicit downstream reporting cleanup
3. explicit re-routing logic for `SCT_NO_MAINT`
4. cleanup of maintenance-specific config/QC once the new study decision is implemented

Those are the main additional issues I would capture before coding starts.
