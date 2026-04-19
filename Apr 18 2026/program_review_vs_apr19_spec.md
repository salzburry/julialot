# Program Review vs Apr 19 Spec

**Review date:** 2026-04-19

**Scope:** Review the current R program against the updated Apr 19 LOT1 end-spec discussion. No code changes made.

**Files reviewed:**
- `Program/lot_program.R`
- `Program/R/config_lot.R`
- `Program Spec and Scenarios/lot1baseendupdatedapr19.txt`

**Note on cleanup:** A recursive scan of the `Apr 18 2026` workspace did not find any earlier `.md` files to delete before this review was written.

## Findings

### 1. High - `CART_INIT` still ends on `FIRST_CART_DT` in code, but the Apr 19 spec now ends the prior LOT the day before CAR-T

**Spec basis**
- `lot1baseendupdatedapr19.txt:113-114` says: for CAR-T transitions, including `CART_INIT`, `LOT1_BASE_END_DT` is the day before `FIRST_CART_DT`.
- `lot1baseendupdatedapr19.txt:129-134` repeats that `CART_INIT` uses the day before `FIRST_CART_DT`.

**Current code**
- `lot_program.R:1940-1942` sets `LOT1_BASE_END_DT = ec.FIRST_CART_DT`.
- `lot_program.R:1972-1974` uses the same `FIRST_CART_DT` branch inside `LOT1_BASE_LENGTH`.

**Impact**
- Patient-level `LOT1_BASE_END_DT` and `LOT1_BASE_LENGTH` are still off by one day for `CART_INIT`.
- The code is not aligned with the now-final Apr 19 spec convention.

**What needs to be fixed**
- Update all `CART_INIT` end-date derivations to use `date_sub(FIRST_CART_DT, 1)` instead of `FIRST_CART_DT`.
- Recompute any dependent length logic from that same corrected end date.

### 2. High - Former `SCT_NO_MAINT` cases are still routed through a dedicated planned-AUTO branch that depends on deprecated maintenance-period logic

**Spec basis**
- The Apr 19 spec no longer uses `SCT_NO_MAINT` as a final end-reason value.
- `contains_mtx_reg` is now a descriptive flag only: `lot1baseendupdatedapr19.txt:291-305` and `334-365`.

**Current code**
- `lot_program.R:1843-1865` still creates `LOT1_SCT_NO_MAINT_FLG` and `SCT_NO_MAINT_END_DT`.
- That logic is driven by `m.MAINT_FOLLOWS_SCT_FLG`, which comes from the separate maintenance-period view.
- `lot_program.R:1906-1910` then maps those cases directly to `SCT_AUTO`.

**Impact**
- The program still treats planned AUTO-without-maintenance as a special routing branch, even though the updated spec removed `SCT_NO_MAINT` as a final category.
- This can force patients into `SCT_AUTO` rather than classifying them under the final non-maintenance end rules based on the earliest applicable event.

**What needs to be fixed**
- Remove the dedicated `LOT1_SCT_NO_MAINT_FLG` / `SCT_NO_MAINT_END_DT` routing path.
- Reclassify former `SCT_NO_MAINT` patients under the final non-maintenance end-reason framework used by the updated spec.

### 3. Medium - The full maintenance-period subsystem is still active and exported, even though the Apr 19 spec now keeps maintenance as flag-only

**Spec basis**
- The updated end-spec extract retains `contains_mtx_reg` as the maintenance concept and frames it as descriptive only: `lot1baseendupdatedapr19.txt:291-305` and `334-365`.
- The Apr 19 end-spec extract no longer shows corresponding `LOT1_BASEMAINT_*` rows.

**Current code**
- `lot_program.R:1392-1755` still builds a full `lot1_maintenance` view with:
  - maintenance start/end dates,
  - maintenance regimen typing,
  - maintenance end reasons,
  - per-drug maintenance flags,
  - `MAINT_FOLLOWS_SCT_FLG`.
- `lot_program.R:1831-1840` still carries those `LOT1_BASEMAINT_*` outputs into `lot1_base_end`.
- `config_lot.R:45-51` still keeps maintenance-period parameters alive specifically for this subsystem.

**Impact**
- The final program output still carries a separate derived maintenance-period framework that the updated Apr 19 spec has demoted.
- This makes the code harder to reconcile with the current spec and is the reason the deprecated `SCT_NO_MAINT` routing still exists.

**What needs to be fixed**
- Decide whether `lot1_maintenance` is still needed anywhere outside historical reference/QC.
- If not, remove the unsupported `LOT1_BASEMAINT_*` outputs from the final LOT1 end dataset and sever the dependency from end-reason routing.
- If any maintenance-period outputs must stay temporarily, document them explicitly as legacy/non-spec outputs until removed.

### 4. Medium - `CART_INIT` tie-handling against discontinuation still uses the infusion date instead of the spec end date

**Spec basis**
- Under the Apr 19 spec, `CART_INIT` ends the prior LOT on `FIRST_CART_DT - 1`, not on the infusion date itself.
- The end reason is chosen from the earliest end date, with priority applied when two reasons share the same earliest date.

**Current code**
- `lot_program.R:1912-1913` checks `ec.FIRST_CART_DT <= ec.LOT1_BASE_DISCON_DT` before allowing `CART_INIT`.
- `lot_program.R:1955-1956` and `1972-1974` use the same infusion-date comparison inside the length logic.

**Impact**
- If discontinuation occurs on the day before CAR-T, the spec says the `CART_INIT` end date ties with discontinuation.
- The current code still compares against the infusion date, so those ties can incorrectly fall through to `DISCONTINUATION` instead of respecting the `CART_INIT` priority.

**What needs to be fixed**
- Compare discontinuation against the spec end date for `CART_INIT` (`FIRST_CART_DT - 1`), not the infusion date itself.
- Apply that same correction consistently anywhere `CART_INIT` is compared against discontinuation or other end candidates.

## Bottom line

The core remaining code/spec gaps are now concentrated in one area: LOT1 end routing still depends on an older maintenance-period framework.

The highest-priority fixes are:
1. Correct the `CART_INIT` end date and dependent length logic to `FIRST_CART_DT - 1`.
2. Remove the dedicated `SCT_NO_MAINT` / planned-AUTO routing branch from `lot1_base_end`.
3. Decouple final LOT1 end logic from the old `lot1_maintenance` subsystem, leaving `contains_mtx_reg` as the active maintenance concept.

Aside from those items, I did not find other major downstream end-reason mismatches elsewhere in the `Program` folder during this pass.
