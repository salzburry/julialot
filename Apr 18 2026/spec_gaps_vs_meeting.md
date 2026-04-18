# Meeting Minutes → Program Spec — Gap Analysis

**Review date:** 2026-04-18
**Scope:** Items discussed in the Apr 15 2026 call (Julia / Onker) that are **not yet reflected in the Apr 18 program spec**. Protocol is out of scope per user instruction.

**Documents reviewed:**
- Meeting minutes: `Apr 18 2026/meeting minutes apt 15`
- Program spec (Apr 18): `Apr 18 2026/Program Spec and Scenarios/*apr18.pdf`

**Baseline assumption (per user):** The Apr 18 spec is up to date on its own terms. This review only flags meeting decisions that are missing or ambiguous vs the current spec.

---

## Summary

| # | Severity | Meeting item | Spec status |
|---|----------|--------------|-------------|
| 1 | HIGH | `CART_INIT` end-reason naming — "their reason for LOT1 end shouldn't be a medication ad. It actually should be initiation of CAR-T therapy" | Spec has the 45-day CAR-T consolidation rule but does NOT define `CART_INIT` as an explicit `LOT1_BASE_END_REASON` value |
| 2 | HIGH | Re-classification of `MAINTENANCE_END` patients — "if those people are not having another medication added, I think that we would just say that they're discontinued" | Spec struck through Rule 8, but does NOT add a rule stating that patients previously routed to `MAINTENANCE_END` now become `DISCONTINUATION` (or a censoring reason) |
| 3 | HIGH | Re-classification of `SCT_NO_MAINT` patients — "those would be … either they're having a new agent probably introduced or they're having a 3rd or unplanned atologous happening" | Spec struck through Rule 4, but does NOT enumerate where these patients now land (MED_ADD / CART_INIT / SCT_AUTO / DISCONTINUATION) |
| 4 | HIGH | LOT 2–5 spec — "I can start up the lot 2 spec by next [week]" | The LOT 2–5 spec **does not exist** in the `Program Spec and Scenarios/` folder. Only LOT1 spec tabs are present |
| 5 | HIGH | LOT 2–5 start events — "people could start lot 2 … with a car or tea event or allogenic, or atologist transplant" | Not formalised anywhere in the spec. `lot1baseendapr18.pdf` mentions the 30-day induction window and ALLO/CAR-T as new-LOT triggers individually, but no consolidated "LOT ≥ 2 start date" definition |
| 6 | MED | `contains_mtx_reg` — BORT + DARA + LENA ambiguity, discussed explicitly — "Bort, Dara Len is a complicated situation because someone could theoretically have Bort monotherapy, Len monotherapy, or Len dual maintenance, or Dara Len" | Spec gives a prose definition and the mono/dual lists, but no worked examples covering the ambiguous 3+-drug case. No explicit statement on whether any subset that qualifies triggers the flag |
| 7 | MED | `contains_mtx_reg` priority vs anchor — "it has to be anchored to something so that you know when your maintenance period starts" | Spec says "It is thus imperative to include another agent, other than the drug(s) that transitions into a mtx regimen, to anchor." But does NOT say whether a corticosteroid can serve as the anchor. (In the code, steroids do NOT anchor, per protocol.) |

---

## 1. `CART_INIT` — missing as an explicit end-reason value

**Meeting (Julia, verbatim):**
> "if someone has a new medication added, but then it, like, within 45 days of that new agent, their starting car T, that their medic, their reason for law one end shouldn't be a medication ad. It actually should be initiation of Cart T therapy."

**What the spec has now (`lot1baseendapr18.pdf`, `CART_45D_CONSOLIDATION` row):**
> "CAR-T cellular therapy infusions are classified as their own line of therapy. Oncology therapies administered within 45 days of the CAR-T infusion are consolidated as part of the CAR-T LOT. … Would require checking T_MEDICAL/T_RX claims within 45 days of FIRST_CART_DT and reclassifying them from LOT1 to the CAR-T LOT. Affects MAP_END_DT for induction meds and MAP_START_DT for potential new [agents]."

**Gap:** The spec describes *consolidation behaviour within the CAR-T LOT*, but does not say what the preceding LOT1's `LOT1_BASE_END_REASON` variable should contain in this scenario. Julia's wording in the meeting ("should be initiation of CAR-T therapy") implies a distinct end-reason value — the code calls it `CART_INIT`. The spec needs to define this value explicitly.

**Required spec addition — new row under `LOT1_BASE_END_REASON` values:**

> **`CART_INIT`:** If `LOT1_BASE_1ST_ADD_MED_DT` is not missing, and `FIRST_CART_DT - LOT1_BASE_1ST_ADD_MED_DT ≤ 45` (inclusive of 0 and 45), then `LOT1_BASE_END_REASON = 'CART_INIT'` instead of `'MED_ADD'`. `LOT1_BASE_END_DT` remains the day before the added agent's start date.

---

## 2. `MAINTENANCE_END` → what now?

**Meeting (Julia, on the old MAINTENANCE_END bucket):**
> "maintenance end now? We might need to update that right now. Is that just looking for if they're ending their lot one on a maintenance valid maintenance regimen? Is that what that's flagging? … I think, Yeah, I'm wondering where that is in the spec. Maybe, I think that that should just get, if those people are not having another medication added, I think that we would just say that they're discontinued, um, would be the idea."

**What the spec shows (`lot1baseendapr18.pdf`, page 1):** Rule 8 ("End of maintenance regimen") is visually struck through in the paragraph on top of the main rules cell. But:
- The restated rules list further down in the same cell still includes "(Rule 8) End of maintenance regimen".
- The spec does **not** explicitly state where the patients who would previously have been labelled `MAINTENANCE_END` now go (`DISCONTINUATION`? `MED_ADD`? `STUDY_END`? `DEATH`?).

**Required spec addition:**
- Remove the restated Rule 8 (not just the struck version at the top).
- Add an explicit mapping note: "Patients whose LOT1 would previously have been closed on Rule 8 (end of maintenance) now fall through to Rule 2 (DISCONTINUATION) or Rules 5–7 (DEATH / DISENROLLMENT / STUDY_END), whichever comes first."

---

## 3. `SCT_NO_MAINT` → what now?

**Meeting (Julia):**
> "And then study in, so that's, like, a censory reason. Okay, death, disenrolment. So, yeah, and then SCT no maintenance. I think that, um, also, presumably those are all atolicous transplants. I think, um, if there's a stem, I think those also need to probably get reclassified. So those would be, um, Either they're having a, um, stem cell, like they're either having a new agent probably introduced or they're having a 3rd or unplanned atologist happening."

**What the spec shows:** Rule 4 ("SCTs not followed by maintenance within 180 days") is struck through at the top of the main cell, but the restated rules list further down still contains "(Rule 4) SCTs not followed by maintenance within 180 days". The spec does not map the former `SCT_NO_MAINT` patients to new end reasons.

**Required spec addition (mapping note):**

For patients who previously landed in `SCT_NO_MAINT`:

| Sub-case | New end reason |
|---|---|
| Single/tandem AUTO + a new non-induction agent starts before any censoring event | `MED_ADD` (or `CART_INIT` if the new agent precedes CAR-T by ≤ 45 days) |
| 3rd AUTO / unplanned AUTO / ALLO follows the single/tandem AUTO | `SCT_AUTO` (via Rule 3, excess AUTO) or `SCT_ALLO` |
| Single/tandem AUTO and no subsequent MM event — LOT1 just runs out | `DISCONTINUATION` after the 90-day gap |
| Death / disenrollment / study-end intervenes | `DEATH` / `DISENROLLMENT` / `STUDY_END` |

- Remove the restated Rule 4 from the rules list in `lot1baseendapr18.pdf`.
- Note that single/tandem AUTOs are not by themselves LOT-ending (consistent with Rule 3: "Single autologous SCTs and tandem SCTs are not unplanned SCTs and are considered a continuation of the line of therapy").

---

## 4. LOT 2–5 spec — not yet written

**Meeting (Julia):**
> "just as far as getting started on lots 2 through five, um, the spec, like how we did it last time, we had 2 specs and I was, we never got onto lots 2 through five. I might have told you that before … we can basically copy the lot ones back. We can start with the Anchor version."
>
> "I can start up the lot 2 spec by next [week]."

**What the spec has now:**
- `lot1baseapr18.pdf` and `lot1baseendapr18.pdf` only cover LOT1.
- `lot1baseendapr18.pdf` mentions the 30-day induction window parameter in the `INDUCTION_WINDOW_DAYS` row ("For LOT2-LOT5, the LOT regimen includes all MM therapies received within 30 days on and following the LOT start date"), but there is no dedicated LOT2–5 spec tab.

**Required:** New spec tabs (or a single parameterised tab for LOT ≥ 2):
- `lot2baseapr18.pdf` / `lot2baseendapr18.pdf` (analogous to LOT1 pair)
- Or a unified `lotnbaseapr18.pdf` with `LOT_NUM ∈ {2,3,4,5}` as a parameter

Julia committed to producing this next week.

---

## 5. LOT ≥ 2 start events — not formalised

**Meeting (Julia):**
> "people could start lot 2 or uh, subsequent lots with a car or tea event or allogenic, uh, or atologist transplant"

**What the spec has now:** `lot1baseendapr18.pdf` has individual rows that imply the starters, but never consolidates them:
- `ALLO_ALWAYS_ENDS_LOT` row — "Presence of an allogeneic SCT immediately ends a LOT and starts a new LOT."
- `CART_45D_CONSOLIDATION` row — "CAR-T cellular therapy infusions are classified as their own line of therapy."
- `FIRST_CART_DT`, `FIRST_ALLO_DT`, `LOT1_TX_AUTO_DT_*` rows — dates only.

**Required spec addition (belongs in the new LOT 2–5 spec per §4):**

> **LOT_START_DT (for LOT ≥ 2):** The LOT_{N+1}_START_DT is the earliest of:
> 1. First MM oncology agent MAP_START_DT after LOT_N ends (non-steroid).
> 2. First CAR-T infusion date, if LOT_N ended via `CART_INIT` or `SCT_CART`.
> 3. First allogeneic SCT date (ALLO immediately starts a new LOT — the ALLO date is the start).
> 4. Next autologous SCT date, if LOT_N ended via unplanned AUTO (Rule 3).
>
> Induction window for LOT ≥ 2 is 30 days from LOT_START_DT.

---

## 6. `contains_mtx_reg` — BORT + DARA + LENA ambiguity

**Meeting (Julia):**
> "something like Bort, Dara Len is a complicated situation because someone could theoretically have Bort monotherapy, Len monotherapy, or Len dual maintenance, or Dara Len, I think, is the other combination possibility. So there's a few possibilities … in real world, hence why it's complicated to make a rule … we're adding a flag, but we're not going to define it for this study."

**What the spec has now (`lot1baseendapr18.pdf` page 3):** Prose definition and the mono/dual lists:

> Mono: Lenalidomide, Bortezomib, Daratumumab, Ixazomib, Thalidomide
> Dual: Bortezomib/lenalidomide, Carfilzomib/lenalidomide, Daratumumab/lenalidomide
> "It is thus imperative to include another agent, other than the drug(s) that transitions into a mtx regimen, to anchor the start of that mtx regimen."

**Gap:** Given a 3-drug induction like BORT+DARA+LENA, the spec does not say whether the flag is 1. The ambiguity is:
- Any of {BORT}, {LENA}, {DARA} alone could be the mono-maintenance subset → an anchor exists in the other two drugs → flag = 1.
- {BORT+LENA} could be the dual subset → DARA is the anchor → flag = 1.
- {DARA+LENA} could be the dual subset → BORT is the anchor → flag = 1.
- Etc.

The spec does not explicitly say "flag = 1 if **any** valid subset (mono or dual) has at least one remaining induction drug outside the subset." This is the rule the code follows (`lot_program.R:1793-1799`).

**Required spec addition — worked-example table:**

| Induction regimen | Subset(s) that qualify as maintenance | Anchor candidate(s) | `contains_mtx_reg` |
|---|---|---|---|
| BORT + LENA | BORT+LENA dual, BORT mono, LENA mono | none outside each subset | 0 |
| BORT + LENA + CYCL | BORT+LENA dual | CYCL | 1 |
| BORT + LENA + DEXA (steroid) | BORT+LENA dual | none (steroid doesn't anchor — see §7) | 0 |
| BORT + DARA + LENA | Any mono or dual listed | always another drug is available | 1 |
| DARA | DARA mono | none | 0 |
| CYCL alone | none (CYCL not in list) | — | 0 |

---

## 7. Steroid as anchor — not stated in spec

**Meeting:** Not explicitly discussed, but implied by the protocol's treatment of steroids as non-oncology.

**What the spec has now:** The anchor definition says "include another agent, other than the drug(s) that transitions into a mtx regimen." It does NOT clarify whether corticosteroids (DEXA, PRED) count as "another agent."

**Gap:** In clinical practice, dexamethasone is routinely co-administered with BORT and LENA. If DEXA counts as an anchor, then nearly every patient on a BORT+LENA regimen will have `contains_mtx_reg = 1`, which is not what Julia intends ("we're adding a flag, but we're not going to define [maintenance] for this study").

**Required spec addition:** Add one sentence to the `contains_mtx_reg` definition:

> "Corticosteroids (e.g., dexamethasone, prednisone) do not qualify as an anchor agent. Only MM oncology agents listed in `CL_MMA_ROLLUP` with `CL_MED_CLASS <> 'STEROID'` can anchor a maintenance subset."

This matches the current code behaviour at `lot_program.R:1475` (`MAP_MED_CLASS <> 'STEROID'`).

---

*End of gap analysis.*
