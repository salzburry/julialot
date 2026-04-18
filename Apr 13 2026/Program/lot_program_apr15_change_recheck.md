# Review: Apr 15 LOT Logic Changes Recheck

**Date:** 2026-04-16  
**Review type:** Static code review only. No code changes made.

## Scope reviewed

- `C:/Users/onkar/Documents/GitHub/julialot/Apr 13 2026/Program/lot_program.R`
- `C:/Users/onkar/Documents/GitHub/julialot/Apr 13 2026/Program/R/descriptives_lot.R`
- `C:/Users/onkar/Documents/GitHub/julialot/Apr 13 2026/Program/R/config_lot.R`

## Validation status

The current pulled `lot_program.R` now parses successfully with local R:

```r
& 'C:\\Program Files\\R\\R-4.4.3\\bin\\Rscript.exe' --vanilla -e "parse('C:/Users/onkar/Documents/GitHub/julialot/Apr 13 2026/Program/lot_program.R')" | Out-Null
```

## Conclusion

The current change set is much closer and the previously reported parse blocker is fixed. The earlier two fixes also look present:

- `contains_mtx_reg` is now derived from actual induction drugs instead of substitution-expanded maintenance candidates
- `CART_INIT` is no longer obviously unreachable, because the generic CART/SCT branch now steps aside when `CART_INIT_FLG = 1` and the SCT reason is CART

I found **one remaining logic issue** in the current pulled code.

---

## Remaining Issue

### 1. Planned AUTO / former `SCT_NO_MAINT` cases still bypass the new `CART_INIT` date comparison

**Severity:** High

**Code:**

- `lot_program.R:1907-1910`
- `lot_program.R:1936-1939`
- `lot_program.R:1968-1971`

**Current logic**

The former `SCT_NO_MAINT` branch was reclassified to `SCT_AUTO`, but its comparison against competing events is still:

```sql
(ec.LOT1_BASE_1ST_ADD_MED_DT IS NULL OR ec.CART_INIT_FLG = 1 OR ec.SCT_NO_MAINT_END_DT <= ec.LOT1_BASE_1ST_ADD_MED_DT)
```

When `CART_INIT_FLG = 1`, that middle condition makes the whole comparison pass automatically.

**Why this is a problem**

That means a planned AUTO case can still win even when the reclassified CART event should be the earlier competing event.

After the new CAR-T logic was introduced, the competing event is no longer:

- the original `LOT1_BASE_1ST_ADD_MED_DT`

It is:

- `FIRST_CART_DT` when `CART_INIT_FLG = 1`

The Rule 3 SCT branch was already updated to handle this distinction correctly:

- `lot_program.R:1894-1899`
- `lot_program.R:1929-1934`
- `lot_program.R:1961-1966`

But the planned AUTO / former `SCT_NO_MAINT` branch was not updated the same way.

**Why this matters**

A patient can now be classified as `SCT_AUTO` from the planned-AUTO branch even if:

- `CART_INIT_FLG = 1`
- and `FIRST_CART_DT` is earlier than `SCT_NO_MAINT_END_DT`

because the current branch treats `CART_INIT_FLG = 1` as an automatic pass instead of comparing the dates.

**What needs to change**

The planned AUTO / former `SCT_NO_MAINT` branch needs the same style of conditional comparison already used in the Rule 3 branch:

- compare against `FIRST_CART_DT` when `CART_INIT_FLG = 1`
- compare against `LOT1_BASE_1ST_ADD_MED_DT` when `CART_INIT_FLG = 0`

That same correction needs to be applied consistently in:

1. the end-reason CASE
2. the end-date CASE
3. the inner CASE inside `LOT1_BASE_LENGTH`

---

## What looks fixed from this pass

### A. Parse blocker is fixed

The raw quote issue inside the SQL `glue()` block is gone and local R parse now succeeds.

### B. `contains_mtx_reg` false-positive path from permissible substitutions looks fixed

`lot1_contains_mtx_reg` now builds valid maintenance subsets directly from `lot1_induction_meds`:

- `lot_program.R:1767-1808`

This removes the earlier false-positive path where substitution-expanded helper meds could create phantom maintenance subsets.

### C. `CART_INIT` no longer looks unreachable

The generic SCT branch now skips CART cases when:

- `CART_INIT_FLG = 1`
- `LOT1_TX_ENDDATE_REASON = 3`

at:

- `lot_program.R:1894-1899`
- `lot_program.R:1929-1934`
- `lot_program.R:1961-1966`

So the earlier issue where every such case would always become `SCT_CART` appears to be fixed.

### D. Reporting cleanup is present

The hardcoded `SCT_NO_MAINT` and `MAINTENANCE_END` color entries are gone from:

- `descriptives_lot.R:675-680`
- `descriptives_lot.R:1644-1648`

and `CART_INIT` is present.

## Bottom Line

The pulled code is significantly improved and now parses. I only see one remaining issue: the planned AUTO / former `SCT_NO_MAINT` branch still needs to compare against `FIRST_CART_DT` when `CART_INIT_FLG = 1`, instead of automatically passing. Once that is fixed consistently in the three CASE expressions, this Apr 15 logic change set will look much cleaner.
