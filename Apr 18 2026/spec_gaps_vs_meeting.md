# Program Spec vs Apr 15 Meeting — Gap Analysis

**Review date:** 2026-04-18
**Purpose:** Identify where the Apr 18 program spec and Apr 13 protocol are **not yet aligned** with the decisions made in the Apr 15 call (Julia / Onker). The lot-output PDF is intentionally excluded from scope per user instruction.

**Documents reviewed:**
- Meeting minutes: `Apr 18 2026/meeting minutes apt 15`
- Program spec (Apr 18): `Apr 18 2026/Program Spec and Scenarios/`
  - `lot1baseendapr18.pdf` (10. LOT1_BASE_END)
  - `lot1baseapr18.pdf` (6. LOT1_BASE)
  - `sctapr18.pdf` (7. SCT)
  - `clmmarolluoapr18.pdf` (40. CL_MMA_ROLLUP)
  - `mtx scenarios.pdf` (maintenance scenarios)
  - `mmamedapr18.pdf` (5A. MMA_MED), `mapmedapr18.pdf` (5B. MAP_MED)
  - `dataprepapr18.pdf`, `studypopapr18.pdf`
- Protocol: `Apr 18 2026/Protocol/Lot protocol Apr 13.pdf`

---

## Summary of gaps

| # | Severity | Area | Spec gap |
|---|----------|------|----------|
| 1 | HIGH | Protocol (Apr 13) | Maintenance Rules 4 and 8 still present; Julia said she moved maintenance language to "Limitations" and the current PDF is pre-move |
| 2 | HIGH | lot1baseendapr18 | `LOT1_BASE_END_REASON` has no explicit enumerated list of allowed values (`DISCONTINUATION` / `MED_ADD` / `SCT_AUTO` / `SCT_ALLO` / `SCT_CART` / `CART_INIT` / `DEATH` / `DISENROLLMENT` / `STUDY_END`) |
| 3 | HIGH | lot1baseendapr18 | `CART_INIT` end reason (MED_ADD → CAR-T within 45 days) not explicitly defined as an end-reason value |
| 4 | HIGH | lot1baseendapr18 | Strike-through edits (old Rules 4 & 8) are only partial — "(Rule 4) SCTs not followed by maintenance within 180 days" and "(Rule 8) End of maintenance regimen" still appear verbatim later in the same cell |
| 5 | HIGH | lot1baseendapr18 | Single / tandem AUTO SCT treatment post-maintenance-removal is under-specified. Protocol says these are "continuation of the line", but without maintenance there is no mechanism to end LOT1 for an AUTO-only patient |
| 6 | HIGH | LOT 2–5 spec | Not yet written. Julia: "I can start up the lot 2 spec by next [week]" |
| 7 | MED | lot1baseendapr18 | LOT 2–5 start events not formalised — Julia: "people could start lot 2 … with a car or tea event or allogenic, or atologist transplant" |
| 8 | MED | sctapr18 | Spec uses `HSCT_*` variable naming (`LOT1_HSCT_AUTO_SING_FLG`, etc.) while code + protocol use `SCT_*`; spec flags this but does not resolve |
| 9 | MED | clmmarolluoapr18 | OCR of rollup table is ambiguous — confirm `DARA` row has `DUAL_MAINTENANCE_WITH = "LENA"` and `LENA` row has `"BORT, CARF, DARA"` |
| 10 | MED | lot1baseendapr18 | `contains_mtx_reg` row defines the flag, but does NOT list the required allowed mono/dual regimens as a structured table — hard for QA to verify |
| 11 | MED | mtx scenarios.pdf | Examples are pre-decision — they show a `mtx period` timeline, but team has now agreed NOT to define a maintenance period. Needs a header note |
| 12 | LOW | lot1baseendapr18 | Inconsistency between cells on `LOT1_TX_AUTO_MAX_DT` definition (tandem date vs single AUTO date) and the newly de-weighted role of maintenance |
| 13 | LOW | Across specs | No spec version number / change log — hard to confirm which edits Julia made on Apr 15 vs Apr 6 |

---

## 1. Protocol (Apr 13) — maintenance rules not yet moved to Limitations

**Meeting (Julia):**
> "I actually, um, have updated the protocol after me and Vicki's discussion, and I kind of put it like really robust definition of what maintenance, like, probably is, but I took out all of the maintenance language from our protocol, and I moved it to the limitations section just as a discussion point of like, we're adding a flag, but we're not going to define it for this study."

**Current protocol (`Lot protocol Apr 13.pdf`, pages ~12-13):**
```
3. Unplanned SCTs ...
4. SCTs not followed by maintenance: If an SCT is not followed by a
   maintenance regimen within 180 days, then the last day of the LOT is the
   date of the SCT.
5. Death ...
6. Health plan disenrollment ...
7. End of the study period ...
8. End of maintenance regimen: The LOT will end after a maintenance
   regimen ends due to ...
```

Rules 4 and 8 are still in the active rules list, not in the Limitations section.

**Required update to protocol:**
- Delete Rules 4 and 8 from Section 5.1.1.
- Renumber remaining rules 2-3-5-6-7 as 2-6 (or keep numbering for continuity).
- Add new paragraph to Section 5.2 (Limitations) along the lines of:

> "The team has decided not to define a maintenance period for this study. Instead, a binary flag (`contains_mtx_reg`) records whether the LOT1 induction regimen contains a valid mono- or dual-maintenance subset together with at least one additional 'anchor' agent. The following is an example of what maintenance *could* look like in this population … [the robust definition Julia wrote]."

**Action:** Julia to re-share "version 6" of the protocol (mentioned in call) — current Apr 13 PDF is pre-move.

---

## 2. `LOT1_BASE_END_REASON` — allowed values not enumerated

**Spec (`lot1baseendapr18.pdf` Variable table):** The `LOT1_BASE_END_REASON` row gives only a narrative definition ("Final LOT1 base period end reason") and references the protocol rules. It does NOT list the allowed character values that the variable will take.

**Meeting decisions imply the following enumeration:**

| Value | Triggered when | Source |
|---|---|---|
| `DISCONTINUATION` | All agents run-out, no new agent, no SCT/CAR-T (Rule 2) | Protocol |
| `MED_ADD` | New non-induction agent added; no CAR-T within 45 d of that add | Protocol Rule 2 + Apr 15 call |
| `SCT_AUTO` | Unplanned / excess autologous SCT (3rd AUTO, or AUTO inconsistent with tandem window) | Protocol Rule 3 |
| `SCT_ALLO` | Any allogeneic SCT | Protocol Rule 3 |
| `SCT_CART` | CAR-T infusion without a preceding non-induction agent within 45 d | Apr 15 call, spec `CART_45D_CONSOLIDATION` |
| `CART_INIT` | MED_ADD event followed by CAR-T within 45 days — LOT1 ends the day before the MED_ADD, but reason is CART_INIT | Apr 15 call (Julia) |
| `DEATH` | Patient died on/before `OBS_END_DT` (Rule 5) | Protocol |
| `DISENROLLMENT` | Disenrolled before study-end (Rule 6) | Protocol |
| `STUDY_END` | Reached study end with no other event (Rule 7) | Protocol |

**Required spec update:**
- Add a **Values** sub-cell to the `LOT1_BASE_END_REASON` row listing the nine allowed strings above (or agree on final naming — see §8).
- State priority order explicitly:
  `SCT (Rule 3) > CART_INIT > MED_ADD > DISCONTINUATION > DEATH > DISENROLLMENT > STUDY_END`
- This priority is currently only in the *code* (`lot_program.R:1886-1926`) — it should be in the spec so QC can verify.

---

## 3. `CART_INIT` end reason — not explicitly specified

**Meeting (Julia, verbatim):**
> "if someone has a new medication added, but then it, like, within 45 days of that new agent, their starting car T, that their medic, their reason for law one end shouldn't be a medication ad. It actually should be initiation of Cart T therapy."

**Spec (`lot1baseendapr18.pdf`):** Has a `CART_45D_CONSOLIDATION` row that describes consolidation of therapies *within* the CAR-T LOT, but does **not** say how this consolidation affects the preceding LOT's end-reason variable.

**Required spec update — new or expanded row:**

> **LOT1_BASE_END_REASON value: `CART_INIT`**
>
> **Definition:** If a patient's LOT1 ends via `MED_ADD` (i.e., a non-induction agent is added before any other LOT-ending event), and that patient receives a CAR-T infusion within 45 days of the added agent's start date, then `LOT1_BASE_END_REASON = 'CART_INIT'` (not `MED_ADD`). The LOT1 end date remains the day before the added agent's start date.
>
> **Rationale:** Per the Apr 15 meeting, CAR-T cellular therapy is classified as its own LOT. Agents given within 45 days before a CAR-T infusion are understood as part of the bridging/conditioning for CAR-T rather than a new MM regimen. Reclassifying the LOT1 end reason preserves the clinical interpretation.
>
> **Formula:** `CART_INIT = 1` when `FIRST_CART_DT - LOT1_BASE_1ST_ADD_MED_DT BETWEEN 0 AND 45` (inclusive).

---

## 4. Strike-through text is only partial in `lot1baseendapr18.pdf`

**Spec (page 1, main rules cell):** The first instance of the rules list has Rule 4 ("SGTs Het fella~. eel e·, rneif'lteAef'lee …") and Rule 8 ("ff!eIr,teF1eF1ee FBgiffleA") visually struck through. But later in the SAME cell the list is re-stated in clean form:
```
(Rule 2) Discontinuation of all agents
(Rule 3) Unplanned SCTs
(Rule 4) SCTs not followed by maintenance within 180days
(Rule 5) Death
(Rule 6) Health plan disenrollment
(Rule 7) End of the study period
(Rule 8) End of maintenance regimen.
```

A QA-ing reader will see both the struck-through version AND the clean-restated version and will not know the team's final intent.

**Required update:**
- Remove the struck-through Rule 4 / Rule 8 entirely.
- Rewrite the restated list to only include Rules 2, 3, 5, 6, 7 (and the new `CART_INIT` exception — see §3).
- Add a one-line note: "Per Apr 15 2026 decision, maintenance is no longer used as an LOT-ending event; see `contains_mtx_reg` flag and protocol Limitations section."

---

## 5. Single / tandem AUTO treatment is ambiguous now

**Protocol + spec (both):** "Single autologous SCTs and tandem SCTs are not unplanned SCTs and are considered a continuation of the line of therapy."

**Problem:** Under the old spec, such a patient's LOT1 ended via Rule 4 (no maintenance within 180 d) or Rule 8 (end of maintenance regimen). With Rules 4 and 8 removed, a patient with a single/tandem AUTO and no other event has **no mechanism to end LOT1** unless they hit DISCONTINUATION, DEATH, DISENROLLMENT, or STUDY_END.

**Implication:** LOT1 will routinely extend years past the AUTO SCT for patients who simply stop receiving treatment claims — this may be intentional (those LOT1s are long and end on DISCONTINUATION) but it needs to be stated clearly.

**Required spec update (`lot1baseendapr18.pdf` or new note):**
- Explicit sentence: "For a patient with a single or tandem autologous SCT and no subsequent MM oncology agent, LOT1 continues until all induction-regimen run-outs + 90-day discontinuation gap are satisfied (ending as `DISCONTINUATION`), or until a censoring event (`DEATH` / `DISENROLLMENT` / `STUDY_END`), whichever comes first."
- Note that the AUTO SCT itself does not end LOT1.
- Consider whether `LOT1_TX_AUTO_FLG` and `LOT1_TX_AUTO_MAX_DT` should still be persisted (they don't drive the end reason but are analytically useful); clarify their role.

**Open question for Julia:** In the meeting she also said: "those would be, um, either they're having a, um, stem cell, like they're either having a new agent probably introduced or they're having a 3rd or unplanned atologist happening." This suggests that in practice she expects most `SCT_NO_MAINT` patients to fall into MED_ADD, CART_INIT, or (excess AUTO → SCT_AUTO) buckets, and the residual — AUTO + nothing — to be truly tiny. Spec should confirm this expectation and add a sensitivity check for the residual count.


## 6. LOT 2–5 spec — does not exist

**Meeting (Julia):**
> "just as far as getting started on lots 2 through five, um, the spec, like how we did it last time, we had 2 specs and I was, we never got onto lots 2 through five. … the only really main difference is are the induction window is 30 days instead of 60 days, like in lot one. And then people could start lot 2 … with a car or tea event or allogenic, uh, or atologist transplant."
>
> "I can start up the lot 2 spec by next, we, do we have the, I think the protocol is done, right? … I can, if you want the old lot 2 through 5 spec just to see what was done previously, let me also share that with you right now."

**Current spec folder (`Program Spec and Scenarios/`):** Contains `lot1baseendapr18.pdf` but NO `lot2baseapr18.pdf`, `lot2baseendapr18.pdf`, or equivalent for LOT 2–5.

**Required deliverable (Julia to produce):**
- `lot2baseapr18.pdf` (analog of `lot1baseapr18.pdf`) with:
  - `LOT2_START_DT` definition — earliest of:
    - First MM oncology agent after LOT1 ends, OR
    - First CAR-T infusion (if LOT1 ended via CART_INIT or MED_ADD preceded by CAR-T within 45 d), OR
    - First allogeneic SCT after LOT1 ends (ALLO immediately starts new LOT), OR
    - First autologous SCT after LOT1 ends (if LOT1 ended on unplanned AUTO → Rule 3 → next LOT begins on that AUTO date)
  - **Induction window: 30 days** (vs 60 days for LOT1)
  - `LOT2_MED_[MED]`, `LOT2_BASE_DISCON_DT`, `LOT2_BASE_MEDS`, `LOT2_BASE_1ST_ADD_MED_DT` (analogs of LOT1)
- `lot2baseendapr18.pdf` (analog of `lot1baseendapr18.pdf`) with the same Rules 2, 3, 5, 6, 7 plus CART_INIT logic.
- Same spec replicated for LOT3, LOT4, LOT5 (or a single parameterised spec with `LOT_NUM ∈ {2,3,4,5}`).

**Open question:** Does the `contains_mtx_reg` flag apply to LOT ≥ 2 as well? In theory patients can be on maintenance-style regimens after LOT2 too. Confirm with Julia before writing the LOT2 spec.

---

## 7. LOT 2–5 start events — not formalised in spec

**Meeting (Julia):** "people could start lot 2 or uh, subsequent lots with a car or tea event or allogenic, uh, or atologist transplant."

**Spec (`lot1baseendapr18.pdf` page 2):** `ALLO_ALWAYS_ENDS_LOT` row says an allogeneic SCT ends current LOT and starts a new one. `CART_45D_CONSOLIDATION` row says CAR-T is its own LOT. But:

- No explicit row defining **"LOT ≥ 2 start date"** candidates.
- No definition of LOT start when LOT1 ends via `SCT_AUTO` (an unplanned AUTO) — does LOT2 start on the AUTO date, or the day after, or only on the next MM agent?

**Required spec update:**
Add a new row (or sub-section in `dataprepapr18.pdf`):

> **LOT_START_DT (for LOT ≥ 2):** For each patient whose prior LOT has ended, the start date of the next LOT is the earliest of:
> 1. First MM oncology agent MAP_START_DT after prior LOT end
> 2. First CAR-T infusion date (if preceding LOT ended via CART_INIT / SCT_CART)
> 3. First allogeneic SCT date (ALLO starts a new LOT; the ALLO date itself is the LOT start)
> 4. Next autologous SCT date (if preceding LOT ended via unplanned AUTO — Rule 3)
>
> Induction window for LOT ≥ 2 is 30 days from LOT_START_DT.

---

## 8. Variable naming: `HSCT_*` vs `SCT_*`

**Spec (`lot1baseendapr18.pdf` header row):**
```
LOT1_HSCT_AUTO_SING_FLG   Flag: base period had single valid autologous HSCT
LOT1_HSCT_AUTO_TAND_FLG   Flag: base period had tandem valid autologous HSCT
```

**Spec note (same file, `NAMING_DISCREPANCY_SCT_VS_HSCT` row):**
> "The protocol uses 'SCT' (Stem Cell Transplant) terminology consistently. The original program spec uses 'HSCT' (Hematopoietic Stem Cell Transplant) prefix for variable names. Both abbreviations refer to the same medical concept."

**Current code (`lot_program.R`):** Uses `LOT1_SCT_AUTO_SING_FLG`, `LOT1_SCT_AUTO_TAND_FLG`, `LOT1_SCT_NO_MAINT_FLG`, `SCT_TYPE`, `lot1_sct` — **SCT only**.

**Required decision (Julia / Onker):** Pick one. Either:
- Update the spec column names to `LOT1_SCT_*` (protocol-aligned, matches code, lose continuity with older spec).
- Leave spec at `LOT1_HSCT_*` and rename code variables (more work, but preserves spec history).

**Recommendation:** Align spec with code and protocol → `LOT1_SCT_*`. Low effort, single source of truth.

---

## 9. `cl_mma_rollup.csv` — verify DARA/LENA dual rows

**Spec (`clmmarolluoapr18.pdf`, page 1):** The rollup table is rendered with OCR noise, but reads approximately:

```
| CL_MED_ABBR | CL_MED_CLASS | MONO_MAINTENANCE | DUAL_MAINTENANCE_WITH |
| BORT        | PROTINHIB    | YES              | LENA                  |
| CARF        | PROTINHIB    |                  | LENA                  |
| DARA        | ACD38        | YES              | LENA                  |
| IXAZ        | PROTINHIB    | YES              |                       |
| LENA        | IMMUNOMOD    | YES              | BORT, CARF, DARA      |
| THAL        | IMMUNOMOD    | YES              |                       |
```

**Meeting confirmation (Julia):** "if Dara and Len, I'm now forgetting what is about maintenance combination. Is Dara and Len one of them? Yeah, yeah, thank you. Then that's a good idea. … And I think we added Dara and Len for this study, so I think that's why. So, yes, okay, I can sign off there then."

**Required spec / CSV update:**
- Confirm the DARA row in both the spec PDF and the mounted CSV (`/mnt/code/codelist/cl_mma_rollup.csv`) has `DUAL_MAINTENANCE_WITH = "LENA"`.
- Confirm LENA row has `DUAL_MAINTENANCE_WITH = "BORT, CARF, DARA"` (all three partners).
- Spec OCR should be cleaned up so the rollup table is readable without guessing.

**Also (re-read meeting):** Onker mentioned adding LENA as a dual partner for DARA per AI-agent review ("Len probably is uh, to your maintenance agent, which go with Dara as well"). Julia agreed. That reciprocal entry (DARA in LENA's row) is the key check.

---

## 10. `contains_mtx_reg` — needs a structured allowed-regimens table

**Spec (`lot1baseendapr18.pdf` page 3):** Defines the flag:
> "If LOT1 contains any of the following, in combination with at least one other agent then flag = yes."
>
> Mono: Lenalidomide, Bortezomib, Daratumumab, Ixazomib, Thalidomide
> Dual: Bortezomib/lenalidomide, Carfilzomib/lenalidomide, Daratumumab/lenalidomide
>
> "It is thus imperative to include another agent, other than the drug(s) that transitions into a mtx regimen, to anchor the start of that mtx regimen."

**Gap:** The definition gives a prose list, but does not clarify:
- **Ambiguous case: BORT + DARA + LENA.** Which subset counts as the "maintenance regimen" and which drug is the "anchor"? Julia acknowledged this in the call: "someone could theoretically have Bort monotherapy, led monotherapy, or Len, dual maintenance, or Dara Len." The algorithm must consider any valid subset of size 1 or 2; if any subset qualifies and the remaining drug acts as an anchor, the flag is 1.
- **What if every drug in the induction is maintenance-eligible?** (e.g., BORT + LENA + DARA — all three individually mono-qualify). Then there is no "anchor" outside the mono subset. Is the flag still 1 via the dual interpretation? Clarify.
- **Steroids:** Do corticosteroids count as an anchor? Per protocol, steroids are excluded from oncology regimen, so they should NOT anchor. The code at `lot_program.R:1475` enforces `MAP_MED_CLASS <> 'STEROID'` — spec should state this explicitly.

**Required spec update:** Add a worked-example subsection or a second table showing:

| Induction regimen | Qualifying maintenance subset | Anchor agent(s) | `contains_mtx_reg` |
|---|---|---|---|
| BORT + LENA | BORT+LENA (dual) | none outside subset | 0 (no anchor) |
| BORT + LENA + CYCL | BORT+LENA (dual) | CYCL | 1 |
| BORT + LENA + DEXA | BORT+LENA (dual) | none (DEXA is steroid, not an anchor) | 0 |
| BORT + DARA + LENA | BORT+LENA, DARA+LENA, or any single mono | always another drug acts as anchor | 1 |
| DARA alone | DARA mono | none | 0 |

This removes ambiguity and is the test matrix QC will need.

---

## 11. `mtx scenarios.pdf` — now obsolete as a computation spec

**Current content of `mtx scenarios.pdf`:** Examples showing a "mtx period" timeline — when does maintenance start and end, when does LENA mono maintenance begin, etc. These are the old spec for computing a maintenance *period*.

**Meeting decision:** Team has agreed NOT to define a maintenance period. Only the `contains_mtx_reg` flag matters.

**Required update:**
- Add a header note on the first page of `mtx scenarios.pdf`: "These scenarios are retained for reference only. The team has decided NOT to compute a maintenance period for this study; see `lot1baseendapr18.pdf` page 3 for the `contains_mtx_reg` flag definition."
- OR rename the file to `mtx scenarios_DEPRECATED.pdf` and move to an archive folder.
- OR repurpose the file to show the test matrix from §10 above.

---

## 12. `LOT1_TX_AUTO_MAX_DT` — role de-weighted

**Spec:** `LOT1_TX_AUTO_MAX_DT` is defined as "Latest date of patient's valid HSCT — 2nd tandem AUTO date, else single AUTO date."

**Pre-Apr-15:** This date was used to decide whether maintenance started within 180 days of the last AUTO (Rule 4 window).

**Post-Apr-15:** Rule 4 is removed. `LOT1_TX_AUTO_MAX_DT` no longer drives an end reason. It may still be useful as an analytic variable (reporting on when AUTO occurred relative to LOT1 end), but this should be stated.

**Required spec update:**
- Add note: "Retained as analytic/reporting variable. No longer drives `LOT1_BASE_END_REASON`."

Same applies to `LOT1_TX_AUTO_FLG`.

---

## 13. Version numbers / change log missing

Every tab in `lot1baseendapr18.pdf` shows initials + date (e.g., "JM 15Apr2026", "JM 06Apr2026") in the rightmost column — but there is no top-level change log. Given the volume of edits Julia is making in-call, a single cover page that lists "version 6, changes from version 5:" would massively reduce the chance of a reader missing a decision.

**Required:**
- Add a **Cover** / **Change log** sub-page to the spec workbook listing the Apr-15 decisions and the cells that were edited.
- Mirror this in the protocol (Julia mentioned "version 6").

---

## Appendix A — Items from the meeting that ARE already in the Apr 18 spec

| Decision (Apr 15) | Spec location | Status |
|---|---|---|
| `contains_mtx_reg` flag (mono + dual list, anchor requirement) | `lot1baseendapr18.pdf` p.3 last row | Present, needs clarifications per §10 |
| 30-day induction window for LOT 2–5 | `lot1baseendapr18.pdf` p.2 `INDUCTION_WINDOW_DAYS` row | Present (as parameter) |
| 45-day CAR-T consolidation | `lot1baseendapr18.pdf` p.2 `CART_45D_CONSOLIDATION` row | Present |
| CAR-T is its own LOT | `lot1baseendapr18.pdf` p.2 `FIRST_CART_DT` row | Present |
| ALLO always starts new LOT | `lot1baseendapr18.pdf` p.2 `ALLO_ALWAYS_ENDS_LOT` row | Present |
| DARA/LENA as dual maintenance | `clmmarolluoapr18.pdf` row "daratumumab" DUAL col | Present (pending CSV verification — §9) |

---

## Appendix B — Action checklist for Julia (spec owner)

1. **Protocol v6:** Re-share the post-Apr-15 protocol with maintenance moved to Limitations. (§1)
2. **`lot1baseendapr18.pdf`:**
   - Delete struck-through Rules 4 and 8 from both the pre-list and the restated list. (§4)
   - Add enumerated `LOT1_BASE_END_REASON` values table with priority order. (§2)
   - Add explicit `CART_INIT` definition row. (§3)
   - Clarify single/tandem AUTO fate post-maintenance-removal. (§5)
   - Note `LOT1_TX_AUTO_MAX_DT` is analytic-only now. (§12)
   - Decide on `SCT_*` vs `HSCT_*` naming. (§8)
3. **Write LOT 2–5 spec** (promised for next week). Include start-event definition and 30-day window. (§6, §7)
4. **Verify rollup CSV** on `/mnt/code/codelist/` matches spec DARA/LENA dual row. (§9)
5. **`contains_mtx_reg`:** Add worked-example test matrix. (§10)
6. **`mtx scenarios.pdf`:** Add deprecation note. (§11)
7. **Add cover/change-log page** with version number. (§13)

---

*End of gap analysis.*
