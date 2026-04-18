# Meeting Minutes ↔ Program Spec — Collated Gap Analysis

**Review date:** 2026-04-18
**Scope:** Identify decisions made in the Apr 15 2026 call (Julia / Onker) that are not yet reflected in the Apr 18 program spec. Protocol is out of scope. Prior `lot output apr 14` dashboard is out of scope.

**Sources collated:**
- **Review A** — line-by-line meeting-vs-spec review (this file, previous revision).
- **Review B** — independent second review supplied by the user.

**Overall verdict (both reviews agree):** The spec is **partially** updated. The Apr 15 decisions were added in some places (new `contains_mtx_reg` flag, CAR-T 45-day consolidation row, DARA/LENA dual in the rollup), but the LOT1 end-reason section still carries older maintenance-based language that contradicts the meeting decisions.

**Key framing (important — per Apr 15 meeting):** The study does NOT abandon maintenance as a clinical concept. What changed is that the LOT is now modelled as **one single continuous regimen** — no separate "induction period → maintenance period" split with their own dates or end reasons. Maintenance-type drugs are still captured, but via the `contains_mtx_reg` flag on the single LOT1 regimen. Rules 4 and 8 (which ended a LOT based on a separate maintenance phase) are therefore no longer applicable in this study.

---

## Section 1 — What both reviews agree IS already updated

| Item | Evidence in spec | Agreed by |
|---|---|---|
| `contains_mtx_reg` flag row is present | `lot1baseendapr18.pdf` page 3, last row | A + B |
| CAR-T 45-day consolidation rule is present | `lot1baseendapr18.pdf` page 2, `CART_45D_CONSOLIDATION` row + `FIRST_CART_DT` row | A + B |
| DARA/LENA dual maintenance is in the rollup | `clmmarolluoapr18.pdf` — DARA row shows `DUAL_MAINTENANCE_WITH = LENA`; LENA row shows `BORT, CARF, DARA` | A + B |
| THAL mono maintenance is in the rollup | `clmmarolluoapr18.pdf` — THAL row flagged YES under `MONO_MAINTENANCE` | B (A did not call out THAL explicitly) |
| ALLO immediately ends current LOT | `lot1baseendapr18.pdf` page 2, `ALLO_ALWAYS_ENDS_LOT` row | A + B |
| 30-day induction window for LOT 2-5 (parameter only) | `lot1baseendapr18.pdf` page 2, `INDUCTION_WINDOW_DAYS` row | A + B |

---

## Section 2 — Consolidated list of what still needs to be updated

Items are grouped and cross-referenced where the two reviews raised the same point.

### Summary table

| # | Severity | Gap | A | B |
|---|----------|-----|---|---|
| 1 | HIGH | Rules 4 and 8 still appear verbatim in the end-reason section despite being struck through above | implicit | § B.1 |
| 2 | HIGH | No explicit mapping rule for the patients who used to be `MAINTENANCE_END` → where do they now go? | § A.2 | § B.2 |
| 3 | HIGH | No explicit mapping rule for the patients who used to be `SCT_NO_MAINT` → where do they now go? | § A.3 | § B.3 |
| 4 | HIGH | `CART_INIT` is not defined as an explicit `LOT1_BASE_END_REASON` value (CAR-T precedence over MED_ADD) | § A.1 | § B.4 |
| 5 | MED | `contains_mtx_reg` explanatory text still reads operationally (uses "transitions", "anchor the start") — could be mistaken for a derivation rule | — | § B.5 |
| 6 | MED | `mtx scenarios.pdf` still frames maintenance as an operational concept ("Definition of a maintenance period", "mtx period starts...") | § A (v1) | § B.6 |
| 7 | HIGH | LOT 2–5 spec document does not exist yet | § A.4 | — (implicit in meeting) |
| 8 | HIGH | LOT ≥ 2 start events (CAR-T / ALLO / AUTO as line starts) not consolidated | § A.5 | — |
| 9 | MED | `contains_mtx_reg` BORT+DARA+LENA ambiguity — no worked-example table | § A.6 | — |
| 10 | MED | Steroid as anchor — spec does not explicitly exclude corticosteroids | § A.7 | — |

---

## Section 3 — Detailed items

### Gap 1. Remove old maintenance-based end-reason rules from LOT1 end-reason section

**Raised by:** Review B (§ B.1)

**Meeting (Julia):**
> "I took out all of the maintenance language from our protocol, and I moved it to the limitations section."
>
> "Yeah, maybe looking at … I think that that should just get, if those people are not having another medication added, I think that we would just say that they're discontinued."

**Spec evidence (`lot1baseendapr18.pdf` page 1, main rules cell):**

The rules list appears TWICE in the same cell:
- **Top paragraph:** Rule 4 (`SGTs Het fella~. eel e·, rneif'lteAef'lee`) and Rule 8 (`ff!eIr,teF1eF1ee FBgiffleA`) are visually struck through.
- **Restated paragraph below:** Rule 4 (`SCTs not followed by maintenance within 180 days`) and Rule 8 (`End of maintenance regimen`) still appear verbatim in clean form.

**Impact:** A QA-ing reader sees both versions and cannot tell whether the team's final intent is to keep or drop these rules. This is the root cause behind Gaps 2–4.

**Required edit:**
- Remove Rules 4 and 8 from the restated paragraph, not just from the struck-through paragraph.
- Update `LOT1_END_REASON_TEMP`, `LOT1_BASE_END_DT`, and `LOT1_BASE_END_REASON` text so none of the end-reason mechanics depends on detecting a maintenance period.

---

### Gap 2. Map former `MAINTENANCE_END` patients to the new end reasons

**Raised by:** Review A § 2 + Review B § B.2

**Meeting (Julia):**
> "maintenance end now? We might need to update that right now. Is that just looking for if they're ending their lot one on a maintenance valid maintenance regimen? Is that what that's flagging? … I think … if those people are not having another medication added, I think that we would just say that they're discontinued, um, would be the idea."

**Spec evidence:** The spec strikes out Rule 8 at the top of the end-reason cell, but NEITHER the rules list NOR any other row explicitly states where the former `MAINTENANCE_END` patients now land.

**Required edit (add to `LOT1_BASE_END_REASON` row):**

> Patients whose LOT1 would previously have ended via Rule 8 (end of maintenance regimen) now fall through to Rule 2 (`DISCONTINUATION`) or Rules 5–7 (`DEATH` / `DISENROLLMENT` / `STUDY_END`), whichever applies first. There is no dedicated `MAINTENANCE_END` end reason in this study.

---

### Gap 3. Map former `SCT_NO_MAINT` patients to the new end reasons

**Raised by:** Review A § 3 + Review B § B.3

**Meeting (Julia):**
> "SCT no maintenance. I think that, um, also, presumably those are all atolicous transplants. I think … those also need to probably get reclassified. So those would be, um, Either they're having a, um, stem cell, like they're either having a new agent probably introduced or they're having a 3rd or unplanned atologist happening."

**Spec evidence:** The spec strikes out Rule 4 at the top of the end-reason cell, but the restated rules list still contains it and no sub-case mapping is provided.

**Required edit (add mapping table to `LOT1_BASE_END_REASON` row):**

| Former `SCT_NO_MAINT` sub-case | New end reason |
|---|---|
| Single/tandem AUTO, no subsequent MM agent, LOT1 runs out after 90-day gap | `DISCONTINUATION` |
| Single/tandem AUTO, then a new non-induction agent starts (≥ 46 d before any CAR-T) | `MED_ADD` |
| Single/tandem AUTO, then a new agent followed by CAR-T within 45 d | `CART_INIT` |
| 3rd AUTO / unplanned AUTO / ALLO follows the single/tandem AUTO | `SCT_AUTO` (Rule 3) or `SCT_ALLO` |
| Death / disenrollment / study-end intervenes first | `DEATH` / `DISENROLLMENT` / `STUDY_END` |

- Remove Rule 4 from the restated rules list.
- State explicitly: "Single/tandem AUTO SCTs are continuation of the line (per Rule 3) and do not, by themselves, end LOT1. LOT1 continues until one of Rules 2 / 5 / 6 / 7 applies."

---

### Gap 4. `CART_INIT` — make CAR-T precedence over MED_ADD explicit

**Raised by:** Review A § 1 + Review B § B.4

**Meeting (Julia, verbatim):**
> "if someone has a new medication added, but then it, like, within 45 days of that new agent, their starting car T, that their medic, their reason for law one end shouldn't be a medication ad. It actually should be initiation of Cart T therapy."

**Spec evidence (`lot1baseendapr18.pdf`):**
- The `CART_45D_CONSOLIDATION` row describes consolidation of therapies **into the CAR-T LOT** (i.e., forward-looking into LOT2).
- Neither that row nor the main `LOT1_BASE_END_REASON` row states that the preceding LOT1's end-reason value changes to a CAR-T-named value.

**Required edit — new row (or expansion of the `LOT1_BASE_END_REASON` row):**

> **`CART_INIT`** — LOT1 end reason when: `LOT1_BASE_1ST_ADD_MED_DT` is not missing, AND `FIRST_CART_DT - LOT1_BASE_1ST_ADD_MED_DT` is between 0 and 45 days inclusive. In this case:
> - `LOT1_BASE_END_REASON = 'CART_INIT'` (not `'MED_ADD'`).
> - `LOT1_BASE_END_DT` remains the day before the added agent's start date (unchanged from MED_ADD logic).
>
> Priority order for `LOT1_BASE_END_REASON`:
> `SCT_ALLO / SCT_CART / SCT_AUTO (Rule 3) > CART_INIT > MED_ADD > DISCONTINUATION > DEATH > DISENROLLMENT > STUDY_END`

This priority currently lives only in the code (`lot_program.R:1886-1926`) and should live in the spec.

---

### Gap 5. `contains_mtx_reg` text reads operationally — should read as flag-only

**Raised by:** Review B § B.5

**Meeting (Julia):**
> "we're adding a flag, but we're not going to define it for this study. … the definition of maintenance actually is it has to be a maintenance regimen with an anchor agent, which could be a valid maintenance medication, actually, but it has to be just a, it has to be anchored to something so that you know when your maintenance period starts"

**Spec evidence (`lot1baseendapr18.pdf` page 3, `contains_mtx_reg` row):** The explanatory text still uses operational wording: *"The LOT's initial regimen transitions into a maintenance regimen, such that non-maintenance medications present during the initial regimen are discontinued leaving only maintenance medications … It is thus imperative to include another agent, other than the drug(s) that transitions into a mtx regimen, to anchor the start of that mtx regimen."*

This can be misread as an algorithm that derives a maintenance start date.

**Required edit:** Keep the anchor explanation as background, but add a clear framing sentence at the top of the row:

> "Under this study, LOT1 is treated as a single continuous regimen — we do NOT split it into a separate induction period and a separate maintenance period with their own start/end dates or end reasons. Maintenance as a clinical concept still applies (patients do receive maintenance-type drugs), but it is captured ONLY via the `contains_mtx_reg` flag on the single LOT1 regimen: it records whether that regimen contains a valid mono- or dual-maintenance subset with at least one additional non-steroid induction drug acting as an anchor. The flag does not create a separate maintenance start date, maintenance end date, or LOT-ending event."

Then retain the existing "imperative to include another agent" paragraph as clarification.

---


### Gap 6. `mtx scenarios.pdf` — label as reference material

**Raised by:** Review A (v1) + Review B § B.6

**Meeting (Julia):**
> "we're adding a flag, but we're not going to define [maintenance] for this study."

**Spec evidence (`mtx scenarios.pdf`):** The file still opens with an operational heading — *"Definition of a maintenance period: The LOT's initial regimen transitions into a maintenance regimen…"* — followed by worked examples (Example 1 / 1b / 2 / 2b / 3 / 3b) that show `mtx period starts`, `mtx period unknown`, etc. This reads as an operational derivation spec.

**Required edit:** Either
1. Add a prominent banner on page 1: *"These scenarios are retained for reference only. The study no longer derives a maintenance period. See `contains_mtx_reg` row in `lot1baseendapr18.pdf` page 3 for the flag-only definition used in this study,"* OR
2. Move the file to an `archive/` or `reference/` sub-folder and rename it `mtx_scenarios_REFERENCE_ONLY.pdf`, OR
3. Repurpose the file to host the worked-example table for `contains_mtx_reg` (see Gap 9 below).

---

### Gap 7. LOT 2–5 spec — does not exist

**Raised by:** Review A § 4

**Meeting (Julia):**
> "just as far as getting started on lots 2 through five … we never got onto lots 2 through five … we can basically copy the lot ones back. We can start with the Anchor version. And, um, I think the only really main difference is are the induction window is 30 days instead of 60 days."
>
> "I sent this lot on cleaned up version by the end of the week, and then I can start up the lot 2 spec by next [week]."

**Spec evidence:** `Program Spec and Scenarios/` contains only LOT1 tabs (`lot1baseapr18.pdf`, `lot1baseendapr18.pdf`). No `lot2*.pdf` or equivalent parameterised spec.

**Required deliverable:** LOT 2–5 analog spec tabs (Julia owes this next week). Must include:
- `LOT_START_DT` definition for LOT ≥ 2 (see Gap 8).
- 30-day induction window (vs 60 days for LOT1).
- Same Rules 2, 3, 5, 6, 7 plus `CART_INIT` exception (Gap 4).
- Confirm whether `contains_mtx_reg` applies to LOT ≥ 2.

---

### Gap 8. LOT ≥ 2 start events — not consolidated anywhere in the spec

**Raised by:** Review A § 5

**Meeting (Julia):**
> "people could start lot 2 or uh, subsequent lots with a car or tea event or allogenic, uh, or atologist transplant."

**Spec evidence:** `lot1baseendapr18.pdf` mentions the individual triggers (ALLO always starts a new LOT; CAR-T is its own LOT), but there is no single row or sub-section defining `LOT_START_DT` for LOT ≥ 2.

**Required edit (belongs in the new LOT 2–5 spec per Gap 7):**

> **`LOT_{N+1}_START_DT`** is the earliest of:
> 1. First MM oncology agent MAP_START_DT after LOT_N ends (non-steroid).
> 2. First CAR-T infusion date, if LOT_N ended via `CART_INIT` or `SCT_CART`.
> 3. First allogeneic SCT date (ALLO immediately starts a new LOT — the ALLO date IS the start).
> 4. Next autologous SCT date, if LOT_N ended via unplanned AUTO (Rule 3).
>
> Induction window for LOT ≥ 2 is 30 days from `LOT_START_DT`.

---

### Gap 9. `contains_mtx_reg` — BORT + DARA + LENA ambiguity (worked examples)

**Raised by:** Review A § 6

**Meeting (Julia):**
> "something like Bort, Dara Len is a complicated situation because someone could theoretically have Bort monotherapy, Len monotherapy, or Len dual maintenance, or Dara Len, I think, is the other combination possibility. So there's a few possibilities … in real world, hence why it's complicated to make a rule."

**Spec evidence (`lot1baseendapr18.pdf` page 3):** Provides a prose definition and the mono/dual lists. Does NOT say what happens when multiple valid subsets exist (e.g., BORT+DARA+LENA could host BORT+LENA dual with DARA as anchor, or DARA+LENA dual with BORT as anchor, or any single mono with the other two as anchors).

**Required edit — add a worked-example table to the `contains_mtx_reg` row:**

| Induction regimen (non-steroid) | Qualifying mtx subset(s) | Anchor candidate(s) | `contains_mtx_reg` |
|---|---|---|---|
| BORT + LENA | BORT+LENA (dual); BORT (mono); LENA (mono) | none outside any subset | 0 |
| BORT + LENA + CYCL | BORT+LENA (dual); BORT, LENA monos | CYCL (not maintenance-eligible) | 1 |
| BORT + LENA + DEXA | BORT+LENA (dual); BORT, LENA monos | none (DEXA is steroid — see Gap 10) | 0 |
| BORT + DARA + LENA | Multiple: {BORT+LENA}, {DARA+LENA}, {BORT}, {LENA}, {DARA} | always ≥ 1 other induction drug | 1 |
| DARA alone | DARA mono | none | 0 |
| CYCL alone | none (CYCL not in mtx list) | — | 0 |

State explicitly: "The flag = 1 if ANY valid mono or dual maintenance subset exists within the induction regimen AND at least one other non-steroid induction drug is available to act as the anchor."

---

### Gap 10. Steroid as anchor — spec does not explicitly exclude corticosteroids

**Raised by:** Review A § 7

**Meeting:** Not explicitly discussed, but the team's position on steroids in LOT logic is clear (protocol treats them as non-oncology).

**Spec evidence:** The `contains_mtx_reg` anchor definition says "include another agent, other than the drug(s) that transitions into a mtx regimen." It does NOT say whether corticosteroids count as "another agent."

**Why this matters:** Dexamethasone is routinely co-administered with BORT and LENA. If DEXA can anchor, then nearly every patient on BORT+LENA will get `contains_mtx_reg = 1`. That would defeat the purpose of the flag.

**Required edit — add one sentence to the `contains_mtx_reg` row:**

> "Corticosteroids (e.g., dexamethasone, prednisone; any drug with `CL_MED_CLASS = 'STEROID'` in `CL_MMA_ROLLUP`) do NOT qualify as an anchor agent. Only non-steroid MM oncology agents count."

This matches the current code behaviour (`lot_program.R:1475`, steroid class filter in `tagged_maps`).

---

## Section 4 — Action checklist for Julia (spec owner)

### Single-cell edits in `lot1baseendapr18.pdf`

1. **Main rules cell (page 1):** Delete struck-through Rules 4 and 8 from the top paragraph; delete the restated Rules 4 and 8 from the clean paragraph below. (Gap 1)
2. **`LOT1_BASE_END_REASON` row (page 1):**
   - Add enumerated allowed values: `DISCONTINUATION`, `MED_ADD`, `SCT_AUTO`, `SCT_ALLO`, `SCT_CART`, `CART_INIT`, `DEATH`, `DISENROLLMENT`, `STUDY_END`. (Gap 4)
   - Add priority order. (Gap 4)
   - Add mapping note for former `MAINTENANCE_END`. (Gap 2)
   - Add mapping table for former `SCT_NO_MAINT`. (Gap 3)
3. **Add or expand `CART_INIT` definition row** (Gap 4).
4. **`contains_mtx_reg` row (page 3):**
   - Add flag-only framing sentence at top. (Gap 5)
   - Add worked-example table for ambiguous multi-drug regimens. (Gap 9)
   - Add steroid-as-anchor exclusion. (Gap 10)

### New documents

5. **LOT 2–5 spec tabs** — copy of LOT1 tabs with 30-day window and multi-event start definition. (Gaps 7, 8)

### Reference-only label

6. **`mtx scenarios.pdf`** — banner or rename to clarify it is background, not an operational derivation. (Gap 6)

---

## Section 5 — What does NOT need a meeting-driven change right now

Per Review B (agreed by A):
- The `CL_MMA_ROLLUP` tab looks updated for DARA/LENA dual and THAL mono.
- The CAR-T row in `lot1baseendapr18.pdf` reflects the 45-day consolidation text discussed in the meeting.
- The new `contains_mtx_reg` variable exists (even if its text needs the clarifications in Gap 5).

---

## Bottom line

The spec is **not fully aligned** with the Apr 15 meeting yet. Both reviews converge on the same core problem: **the LOT1 end-reason section still carries the old maintenance-based language in the restated rules list and does not explicitly map the former `MAINTENANCE_END` and `SCT_NO_MAINT` patients to new end reasons, nor explicitly name `CART_INIT` as a new end-reason value.**

If Gaps 1–4 alone are addressed, the spec will be substantively consistent with the Apr 15 decisions. Gaps 5–10 are clarifications / completeness items, and Gaps 7–8 are blocked on Julia's promised LOT 2–5 spec delivery next week.

*End of collated gap analysis.*
