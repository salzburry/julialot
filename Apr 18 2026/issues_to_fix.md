# LOT Program — Issues to Fix

**Review date:** 2026-04-18
**Sources reviewed:**
- Meeting minutes: `Apr 18 2026/meeting minutes apt 15` (Julia / Onker call, Apr 15 2026)
- Output under review: `Apr 18 2026/lot output apr 14.pdf` (dashboard generated 2026-04-15 14:27 from Apr 14 run)
- Updated program spec (Apr 18): `Apr 18 2026/Program Spec and Scenarios/*apr18.pdf`
- Current code: `Apr 18 2026/Program/lot_program.R` + `Apr 18 2026/Program/R/*.R`

**Scope:** Static review only. No code changes made.

**Key framing (per Apr 15 meeting, LOT1):** The study does not derive a separate standalone maintenance period or maintenance regimen. Instead, it records whether LOT1 contains a valid maintenance-approved subset using `contains_mtx_reg`. The flag still requires identifying a valid subset with an anchor agent, but that is for flagging presence only — not for creating one official maintenance interval. Consequently, the old maintenance-based LOT-ending rules (Rule 4, Rule 8) no longer apply, and the former `MAINTENANCE_END` / `SCT_NO_MAINT` buckets need to be remapped.

---

## Summary Table

| # | Severity | Area | Issue | Status in current code |
|---|----------|------|-------|------------------------|
| 1 | HIGH | LOT1 end reason | `MAINTENANCE_END` still appears in Apr-14 output (n=2,555, 12%) — must be removed per Apr-15 meeting | Code updated; needs rerun |
| 2 | HIGH | LOT1 end reason | `SCT_NO_MAINT` (n=926, 4.4%) must be reclassified — per meeting "all autologous transplants, either new agent introduced or 3rd/unplanned autologous happening" | Code reclassifies to `SCT_AUTO`; verify against spec |
| 3 | HIGH | LOT1 end reason | `CART_INIT` rule: MED_ADD within 45 days of CAR-T must be reclassified as CAR-T initiation | Code implemented; needs rerun + QC |
| 4 | HIGH | Maintenance | Replace old maintenance-period logic with flag-only concept `contains_mtx_reg` (anchor-required) | Code has `S16b_lot1_contains_mtx_reg`; see §4 checks below |
| 5 | MED | Dashboard | Top-15 / Top-25 induction regimen table showed stale numbers in Apr-14 output vs figure | Data-refresh issue; verify on rerun |
| 6 | HIGH | Dual-maintenance definition | Dara + Len (and Len-as-partner row) must be present as a valid dual — already agreed in call | Verify `cl_mma_rollup.csv` has the row; see §6 |
| 7 | HIGH | LOT 2–5 | Not implemented yet — required next: 30-day induction window, and LOT can START on CAR-T / ALLO / AUTO SCT event | Not implemented |
| 8 | MED | End-reason ordering | Rule 4 ("SCT not followed by maintenance w/in 180d") and Rule 8 ("End of maintenance regimen") are **struck through** in Apr-18 spec; code's `LOT1_SCT_NO_MAINT_FLG` branch is now redundant | See §8 |
| 9 | MED | CAR-T as its own LOT | Spec: "CAR-T infusions are classified as their own LOT; therapies within 45d are consolidated as part of the CAR-T LOT" — only partially handled (reclassifies LOT1 end reason, does not yet roll forward into LOT2 CAR-T line) | Partial; needs LOT2 work |
| 10 | LOW | Naming | Spec `FIRST_ALLO_DT` / `FIRST_CART_DT` vs code `FIRST_ALLO_DT` / `FIRST_CART_DT`; spec naming for HSCT vs SCT — documented-only | OK |
| 11 | MED | SCT classification (old output) | Apr-14 output had only 4 SCT_AUTO, 42 SCT_ALLO, 926 SCT_NO_MAINT — suggests AUTO events were mostly routed through the NO_MAINT branch | Rerun + verify SCT_AUTO counts rise accordingly |
| 12 | LOW | QC / Descriptives | `descriptives_lot.R` has colors/labels for `CART_INIT`, `SCT_AUTO`, etc., but no surface for `contains_mtx_reg` flag (no figure / table) | Consider adding for next dashboard |

---

## 1. `MAINTENANCE_END` still present in Apr-14 output — must be removed

**Observed in `lot output apr 14.pdf` (pages 12–13):**

| End reason | N | % | Avg days |
|---|---:|---:|---:|
| DISCONTINUATION | 5,247 | 24.7 | 253.3 |
| MED_ADD | 5,131 | 24.1 | 321.5 |
| **MAINTENANCE_END** | **2,555** | **12.0** | **851.5** |
| STUDY_END | 2,546 | 12.0 | 389.7 |
| DEATH | 2,535 | 11.9 | 226.0 |
| DISENROLLMENT | 2,288 | 10.8 | 261.2 |
| **SCT_NO_MAINT** | **926** | **4.4** | **186.4** |
| SCT_ALLO | 42 | 0.2 | 110.6 |
| SCT_AUTO | 4 | 0.0 | 541.5 |

**Meeting decision (Julia):**
> "maintenance end now? We might need to update that right now … if those people are not having another medication added, I think that we would just say that they're discontinued … we don't actually know if they're having a valid maintenance event happening."

**Fix:** Remove `MAINTENANCE_END` as an end-reason category. Patients formerly in this bucket should fall through to `DISCONTINUATION` (or `DEATH` / `DISENROLLMENT` / `STUDY_END` if applicable).

**Current code status — PARTIALLY DONE:**
- `lot_program.R:1810-1813` — comment `"Apr 15 meeting: MAINTENANCE_END removed; SCT_NO_MAINT reclassified to SCT_AUTO."`
- `S16_lot1_base_end` no longer emits `MAINTENANCE_END`.
- **But:** the old code path still computes `lot1_maintenance` (`S16a_lot1_maintenance`) and persists `LOT1_BASEMAINT_START`, `LOT1_BASEMAINT_END`, `LOT1_BASEMAINT_END_REASON`, `LOT1_BASEMAINT_MED_*`. Per Apr-18 spec (p.1 — Rule 4 and Rule 8 struck through), maintenance is **flag-only (`contains_mtx_reg`)**. Decide whether to drop the maintenance-period variables entirely or keep them as legacy reference only. If kept, document clearly that they do NOT drive end-reason.

**Action:** Rerun and confirm 0 patients with `MAINTENANCE_END`.

---

## 2. `SCT_NO_MAINT` (n=926) must be reclassified

**Observed:** 926 patients (4.4%) had end reason `SCT_NO_MAINT` on the Apr-14 run. Average LOT1 length 186.4 days (~6 months), consistent with a single AUTO SCT plus short follow-up.

**Meeting decision (Julia):**
> "SCT no maintenance … I think those also need to probably get reclassified. So those would be, um, either they're having a, um, stem cell, like they're either having a new agent probably introduced or they're having a 3rd or unplanned atologous happening."

**Mapping per meeting:**
- Single/tandem AUTO with no subsequent new agent → **`SCT_AUTO`** (i.e., the planned AUTO ends LOT1).
- Single/tandem AUTO followed by new agent → route to **`MED_ADD`** (or `CART_INIT` if CAR-T within 45d).
- 3rd AUTO / unplanned AUTO → already handled by existing Rule 3 → `SCT_AUTO` via `LOT1_TX_ENDDATE`.

**Current code status — IMPLEMENTED but needs audit:**
- `lot_program.R:1843-1852` — `LOT1_SCT_NO_MAINT_FLG` is still computed.
- `lot_program.R:1906-1910` — when `LOT1_SCT_NO_MAINT_FLG=1` the end reason is now emitted as `'SCT_AUTO'` (not `SCT_NO_MAINT`).

**Sanity checks needed after rerun:**
- (a) 0 patients with `SCT_NO_MAINT`.
- (b) `SCT_AUTO` count on new run ≈ old `SCT_NO_MAINT` + old `SCT_AUTO` (roughly 926 + 4 = 930) **minus** any that were consumed by MED_ADD / CART_INIT for having a new agent within follow-up.
- (c) Where `LOT1_BASE_1ST_ADD_MED_DT` exists AND falls BEFORE the planned AUTO date, the patient should end on `MED_ADD`, not `SCT_AUTO`.
- (d) Verify — per Julia — these are indeed all AUTO: no case where `FIRST_ALLO_DT`/`FIRST_CART_DT` is the actual end event.

**Residual risk:** the current gate `(m.MAINT_FOLLOWS_SCT_FLG IS NULL OR m.MAINT_FOLLOWS_SCT_FLG = 0)` depends on the existing maintenance computation. Since maintenance is no longer an end-reason driver, consider removing `MAINT_FOLLOWS_SCT_FLG` entirely and always route a planned AUTO (AUTO_DT_1 present, no ALLO/CART after, no excess AUTO) to `SCT_AUTO`.

---

## 3. `CART_INIT` (CAR-T consolidation within 45 days) — verify

**Meeting decision (Julia):**
> "if someone has a new medication added, but then it, like, within 45 days of that new agent, their starting car T, that their medic, their reason for law one end shouldn't be a medication ad. It actually should be initiation of Cart T therapy."

**Spec (lot1baseendapr18.pdf p.2):**
> "CAR-T cellular therapy infusions are classified as their own LOT. Therapies … given within 45 days of CAR-T cellular therapy are consolidated as part of the CAR-T LOT."

**Current code status — IMPLEMENTED (`S16_lot1_base_end`):**
- `lot_program.R:1866-1878` computes `CART_INIT_FLG = 1` when `FIRST_CART_DT - (LOT1_BASE_1ST_ADD_MED_DT + 1) BETWEEN 0 AND 45`.
- `cart_consolidation_days = 45` is configurable in `config_lot.R:62`.

**Open sub-issues to verify:**
- **3a.** The CART_INIT window is `[0, 45]` measured from the ADD_MED date to CART. Spec/meeting says "within 45 days of CAR-T", which is more naturally `CART_DT - 45 ≤ ADD_MED_DT ≤ CART_DT`. Logically identical, but document.
- **3b.** If both a CART event and a non-consolidation ADD_MED event occur, priority in S16 is SCT(non-CART) > planned-AUTO > CART_INIT > MED_ADD. Confirm with Julia that a patient with `MED_ADD ≥ 46 days before CART` should end on MED_ADD (LOT1 ends the day before the new med) and CAR-T becomes the LOT2/LOT3 event — not reclassified.
- **3c.** Spec also says corticosteroids inside the 45-day CAR-T window are consolidated. The MED_ADD-to-CART gate only looks at non-steroid ADD meds because `LOT1_BASE_1ST_ADD_MED_DT` excludes steroids — OK.
- **3d.** The output dashboard does NOT yet include `CART_INIT` because the old data was pre-change. Rerun, verify Fig 7 / Table includes `CART_INIT`.

---

## 4. `contains_mtx_reg` — anchor-required maintenance flag

**Spec (lot1baseendapr18.pdf p.3):**
> "If LOT1 contains any of the following, in combination with at least one other agent then flag =yes."
>
> Mono: Lenalidomide, Bortezomib, Daratumumab, Ixazomib, Thalidomide
> Dual: Bortezomib/lenalidomide, Carfilzomib/lenalidomide, Daratumumab/lenalidomide
>
> "It is thus imperative to include another agent, other than the drug(s) that transitions into a mtx regimen, to anchor the start of that mtx regimen."

**Meeting (Julia):**
> "we're adding a flag, but we're not going to define it for this study … the definition of maintenance actually is it has to be a maintenance regimen with an anchor agent."

**Current code status — IMPLEMENTED (`S16b_lot1_contains_mtx_reg`, `lot_program.R:1767-1808`):**

The code enumerates every valid mono/dual subset inside the induction regimen, then requires `NOT array_contains(split(vmr.REGIMEN_KEY, ' '), im.MED_ABBR)` — i.e., at least one induction drug outside the maintenance subset = **anchor**.

**Sub-issues / verification points:**
- **4a.** Dara-Len as dual maintenance is handled: mono-qualified members (LENA, DARA) can each pair via `DUALMAINTENANCEWITH` symmetrically.
- **4b.** Bort + Dara + Len example (Julia: "you don't know what the anchor agent is"): enumerating every valid subset of size 1 or 2 will find that `{BORT, LENA}` qualifies as a dual regimen and `DARA` is the anchor (or any other combination). Any one enumeration where the remaining drug is not in the subset is sufficient — correct.
- **4c.** Anchor logic currently uses the **actual** induction drug list (not permissible-substitute expanded), per code comment at `lot_program.R:1770-1773`. This is correct: permissible subs should not anchor a mono-induction.
- **4d.** Confirm the flag is persisted in the final dataset and surfaced in dashboard / Table 7 (currently only in QC): `lot_program.R:1988 qc = "... sum(contains_mtx_reg) AS n_contains_mtx_reg"`. **Descriptives_lot.R does not currently display this.** Needs a new cell in the output table/figure.
- **4e.** Per-med maintenance columns (`LOT1_BASEMAINT_MED_BORT`, …) and maintenance dates are still produced in `S16a`. Decide whether to drop them now that the concept is flag-only. If kept for legacy, clearly label in descriptives.


---

## 5. Top-15 / Top-25 induction regimen table stale in output

**Observed in Apr-14 output (pp. 3-4, 9-10):**

Top 15 figure (Fig 5) and top-25 table both show:
```
BORT LENA           4,935
LENA                2,827
BORT                2,684
BORT DARA LENA      1,866
DARA LENA           1,303
BORT CYCL           1,279
BORT DARA           1,194
DARA                1,160
BORT CYCL DARA      486
CARF LENA           263
CARF                250
POMA                228
VENE                213
BORT CYCL LENA      188
CYCL                176
```

**Meeting (Julia & Onker):**
> "But if you look at the intention regiments, this table, this, I think still has the whole numbers. So probably I need to fix this one … So, so it is the correct number, is what it is."

**Root cause:** The patient-by-medication table (Fig 1) totals BORT ≈ 14,089 patients, which reconciles with the sum across BORT-containing regimens in Fig 5 — so the **numbers are arithmetically consistent**. The confusion was that the table hadn't been re-rendered; figure and table used the same underlying SQL.

**Current code status — OK (no code bug):** `descriptives_lot.R:577-629` produces Top-25 + Top-15 from `lot1_base_end.LOT1_BASE_MEDS` in a single query. Just make sure the dashboard/data is refreshed on the next run.

**Action:** Sanity check after rerun — confirm Top-15 table matches Fig 5 numerically (they read off the same `regimens` data frame, so only divergence possible is caching/rendering).

---

## 6. DARA + LENA as a valid dual — verify rollup CSV

**Spec (clmmarolluoapr18.pdf):** Dual maintenance column shows:
- BORT row: DUAL_MAINTENANCE_WITH = "LENA"
- CARF row: DUAL_MAINTENANCE_WITH = "LENA"
- DARA row: DUAL_MAINTENANCE_WITH = "LENA"
- LENA row: DUAL_MAINTENANCE_WITH = "BORT, CARF, DARA"

**Meeting (Julia):**
> "Yeah. And I think we added Dara and Len for this study, so I think that's why. So, yes, okay, I can sign off there then."

**Current code status — DEPENDS ON CSV:**
- `lot_program.R:96-121` loads `cl_mma_rollup.csv` → `mma_rollup` view.
- DUALMAINTENANCEWITH is handled symmetrically via the `reverse dual` branch at `lot_program.R:1427-1437` and `lot_program.R:1780-1792`. So the rollup file only needs the dual relationship on *one* side (e.g., DARA → LENA); LENA does not need to list DARA as a reciprocal for `contains_mtx_reg` to detect the pair. However, the `lot1_maintenance` regimen-level path does require the `DUALMAINTENANCEWITH` listing to include the partner drug on at least one side.

**Action:** Open `cl_mma_rollup.csv` and confirm the DARA row has `LENA` in `DUALMAINTENANCEWITH` column (and/or LENA row lists DARA). The codelist CSV is not in this repo — it lives at `/mnt/code/codelist/cl_mma_rollup.csv` per `config_lot.R:54`. This needs to be verified in the Domino environment before the next run.

---

## 7. LOT 2 – 5: not implemented

**Meeting (Julia):**
> "just as far as getting started on lots 2 through five … the only really main difference is are the induction window is 30 days instead of 60 days, like in lot one. And then people could start lot 2 or subsequent lots with a car or tea event or allogenic or atologist transplant. … we can basically copy the lot ones back. We can start with the Anchor version."
>
> "I sent this lot on cleaned up version by the end of the week, and then I can start up the lot 2 spec by next."

**Spec (lot1baseendapr18.pdf p.2, INDUCTION_WINDOW_DAYS row):**
> "For LOT2–LOT5, the LOT regimen includes all MM therapies received within 30 days on and following the LOT start date."

**Current code status — NOT IMPLEMENTED:**
- `config_lot.R:40` `induction_window_days = 60` (single config value — no LOT-specific override).
- No `lot2_*` views, no subsequent-LOT logic in `pipeline_steps.R` or `lot_program.R`. Search for `lot2|LOT2|subsequent_lot` returns 0 hits in program code.

**What needs to be added:**
1. New pipeline step(s) `S17_lot2_start` … `S20_lotN_base_end` modelled on `S15-S16`.
2. Second induction-window constant (e.g., `cfg$induction_window_days_lot2 = 30`).
3. Starting event for LOT ≥ 2 is the **max of**:
   - next LOT's first MM oncology agent (non-steroid), **or**
   - an ALLO SCT (immediately starts a new LOT, per spec), **or**
   - an AUTO SCT (planned AUTO that ended prior LOT via Rule 3), **or**
   - a CAR-T infusion (CAR-T is its own LOT, spec).
4. Carry forward all the new decisions:
   - `contains_mtx_reg` flag (anchor-required)
   - `CART_INIT` consolidation (45-day window of next LOT's first med BEFORE CART)
   - No `MAINTENANCE_END` end reason
   - Planned AUTO → `SCT_AUTO`
5. Wait for Julia's LOT2 spec before coding (she is sending "end of the week").

**Action:** Blocked on LOT2 spec. Start with scaffolding/parameterising current LOT1 code so a `lot_num` parameter switches the induction window 60 → 30 and allows SCT/CAR-T as a line-start event.

---

## 8. `SCT_NO_MAINT` code-path is now dead logic

**Spec (lot1baseendapr18.pdf p.1):** The protocol text has Rule 4 ("SCTs not followed by maintenance within 180 days") and Rule 8 ("End of maintenance regimen") struck through (garbled OCR: "SGTs Het fella~, eel e·, rneif'lteAef'lee"; "ff!eIr,teF1eF1ee FBgiffleA"). Those rules are deleted.

**Current code status:**
- `lot_program.R:1843-1852` still computes `LOT1_SCT_NO_MAINT_FLG`, and the main CASE (1906-1910) labels those patients `SCT_AUTO`. This works but carries duplicate logic: `LOT1_TX_ENDDATE` branch (Rule 3, unplanned/excess AUTO) and `LOT1_SCT_NO_MAINT_FLG` branch (former Rule 4) can both label a patient `SCT_AUTO`.
- `MAINT_FOLLOWS_SCT_FLG` (from `S16a_lot1_maintenance`) is still a gate in the NO_MAINT branch, making the end-reason dependent on maintenance detection that is no longer supposed to drive the outcome.

**Recommendation:**
- Simplify: route planned AUTO SCT → `SCT_AUTO` whenever a patient has `LOT1_TX_AUTO_FLG=1` and no ALLO/CART terminated the LOT first and no MED_ADD occurred before the AUTO date. Drop the `MAINT_FOLLOWS_SCT_FLG` gate.
- This removes an implicit dependency of `LOT1_BASE_END_REASON` on the (legacy-only) maintenance computation.

---

## 9. CAR-T as its own LOT — spec not fully realised yet

**Spec (lot1baseendapr18.pdf p.2):** "CAR-T cellular therapy infusions are classified as their own LOT. Therapies (including supportive agents, e.g., corticosteroids) given within 45 days of CAR-T cellular therapy are consolidated as part of the CAR-T LOT."

**What current code does:** Only terminates LOT1 (with `CART_INIT` or `SCT_CART` end reason, as appropriate). It does **not** roll the CAR-T into LOT2.

**What's missing:**
- CAR-T infusion should become **LOT2 start date** (if LOT1 was terminated by CAR-T-related event).
- All agents in the 45-day window BEFORE CAR-T (and any supportive steroids) should be absorbed into the CAR-T LOT line, not counted in LOT1.

**Action:** To be handled as part of LOT2-5 implementation (see §7).

---

## 10. Naming discrepancy: HSCT vs SCT

**Spec (lot1baseendapr18.pdf p.2):**
> "NAMING_DISCREPANCY_SCT_VS_HSCT — protocol uses 'SCT' (Stem Cell Transplant) consistently; the original program spec uses 'HSCT' (Hematopoietic Stem Cell Transplant) prefix for variable names. Both abbreviations refer to the same medical concept."

**Current code:** Uses `SCT` prefix throughout (`LOT1_TX_ENDDATE`, `LOT1_SCT_*`, `SCT_TYPE`, etc.). Consistent with protocol, inconsistent with older spec rows labelled `LOT1_HSCT_AUTO_SING_FLG`, `LOT1_HSCT_AUTO_TAND_FLG`. **Documentation-only; no code change needed.**

**Action:** Confirm with Julia that she wants the final dataset columns named `LOT1_SCT_*` (protocol-aligned) — current code — rather than `LOT1_HSCT_*` (spec-aligned).

---

## 11. AUTO-SCT count discrepancy (Apr-14 output)

**Observed:** The Apr-14 end-reason chart shows:
- `SCT_AUTO` = 4 (0.0%)
- `SCT_NO_MAINT` = 926 (4.4%)
- `SCT_ALLO` = 42 (0.2%)

**Interpretation:** 4 patients had an excess/unplanned AUTO (Rule 3 in the old code) and 926 had a planned AUTO + no subsequent maintenance (old Rule 4). After the Apr-15 changes, all 930 should land in `SCT_AUTO`. On the next run:

- If the combined `SCT_AUTO` is significantly < 930, investigate where they went (possibly consumed by MED_ADD / CART_INIT — which may be correct if a new agent was added post-AUTO).
- If significantly > 930, investigate whether a gate has inverted.

`SCT_ALLO` = 42 and `SCT_CART` = 0 should stay essentially unchanged (no logic change for ALLO/CART end reasons).

Also verify `n_auto_before_lot1` QC (lot_program.R:2126) is 0 and `both tandem AND single` is 0.

---

## 12. `contains_mtx_reg` not exposed in descriptives/dashboard

The QC query persists `n_contains_mtx_reg` at `lot_program.R:1988`. But:
- `descriptives_lot.R` has NO figure/table that surfaces `contains_mtx_reg` by itself, by regimen, or by end-reason.
- The dashboard therefore doesn't show the new flag Julia is specifically asking for.

**Action:** Add a small table/figure: "LOT1 patients with `contains_mtx_reg=1` broken down by regimen / by end reason / by SCT status." Likely add under the LOT1 section after Fig 7 (End Reasons).

---

## Appendix A — Items already carried forward correctly

These came from the Apr-13 static review (`lot_program_review.md` in repo root) and appear resolved in the current code:

| Old finding | Location in current code | Status |
|---|---|---|
| C1 parse error (unescaped quote) | Not present in `lot_program.R` (2,273 lines) | Resolved |
| C2 DAY_SUPPLY dropped instead of imputed to 28 | `lot_program.R:425-437` now imputes 28 when pharmacy DAY_SUPPLY NULL or < 1 | Resolved |
| C3 Maintenance not implemented | `S16a` + `S16b` now implement full maintenance + `contains_mtx_reg` | Resolved (but see §4 and §8) |
| C4 Rule 4 (SCT + no maint) | Now rolled into Rule 3 + reclassified — per Apr-18 spec Rule 4 struck through | Resolved by spec change |
| H1 Steroid leakage | `lot_program.R:1475` `MAP_MED_CLASS <> 'STEROID'` filter applied in `tagged_maps` | Resolved — verify also for `lot1_induction_meds` and `first_add_candidates` |
| H2 Tandem off-by-one | `lot_program.R:1268,1276,1284,1298` — `datediff(...) <= sct_tandem_days` with explicit `# H2 fix` comment | Resolved |
| H3 END_REASON granularity | `S16` now emits `DEATH`, `DISENROLLMENT`, `STUDY_END` distinctly | Resolved |
| H4 Codelist fail-loud | `lot_program.R:224-227` validates `mma_rollup` row count with abort on threshold failure | Resolved |

---

## Appendix B — Concrete action checklist (in priority order)

1. **Rerun LOT pipeline against Apr-14 data snapshot** and verify new end-reason distribution: `MAINTENANCE_END`=0, `SCT_NO_MAINT`=0, `CART_INIT` > 0, `SCT_AUTO` ≈ 900+.
2. **Audit** `contains_mtx_reg` distribution (Julia will look at dashboard).
3. **Verify `cl_mma_rollup.csv` on the mount** has the DARA / LENA dual-maintenance row (§6).
4. **Simplify** `SCT_NO_MAINT` logic — drop `MAINT_FOLLOWS_SCT_FLG` gate now that Rule 4 is removed (§8).
5. **Expose `contains_mtx_reg`** in the dashboard (§12).
6. **Wait on LOT2 spec** from Julia (promised next week); in the meantime scaffold a `lot_num`-parameterised version of `S15/S16` (§7, §9).
7. **Confirm** with Julia the desired variable naming convention (`SCT` vs `HSCT` — §10).

---

*End of review.*
