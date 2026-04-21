# LOT 1 finalization — meeting transcript vs code check

**Date:** 2026-04-21
**Transcript:** `Apr 18 2026/meeting minutes apt 15` (discussion between Julia and Onkar, Apr 15)
**Code reviewed:** `Apr 18 2026/Program/` on branch `claude/review-r-code-optimization-ksBNf`
**Scope:** verify that every LOT 1 decision / action item from the Apr 15 meeting is reflected in the current code. Report only — no code changes in this pass.

---

## TL;DR

Every LOT 1 code-level decision from the Apr 15 meeting is implemented in the current code. Two items are worth flagging before you finalize:

1. **`contains_mtx_reg` is in the final dataset but not shown in the descriptives/dashboard.** Julia said "this is a new flag that I want to see in the final data set" — the column IS there (verified at `lot_program.R:1462`); it's just not summarized anywhere in `descriptives_lot.R` / `dashboard_lot.R`. If Julia/Vicki want to see counts or a chart of it in the QC dashboard, that's a small addition, not a code-correctness issue.
2. **Codelist CSV content not verifiable from the repo.** Thal as valid mono maintenance + Dara/Len as dual maintenance were discussed as additions to the `mma_rollup` CSV. The code reads these columns correctly; whether the actual CSV file has the right rows is a data-side check that needs the CSV itself (lives at `/mnt/code/codelist/…` per `config_lot.R`, not in the repo).

Everything else — CART_INIT reclassification, SCT_NO_MAINT reclassification, removal of MAINTENANCE_END, the anchor rule for `contains_mtx_reg` — lines up with what was agreed in the meeting.

---

## Action items from the transcript, cross-checked against code

### 1. Maintenance becomes a flag-only concept (`contains_mtx_reg`) with an anchor rule
**From transcript (Julia):**
> "we're just going to add a flag for the inclusion of if a regimen is included, if a valid maintenance regimen is included in part of the induction medication … definition of maintenance actually is it has to be a maintenance regimen with an anchor agent … we're just trying to see if there's a valid rate maintenance regimen contained within the lot one induction regimen"

**Code:** `lot_program.R:1389-1434` (`S16b_lot1_contains_mtx_reg`). Implements the anchor rule exactly as described:
- Build valid mono regimens from `MONOMAINTENANCE=1` in `mma_rollup`, restricted to actual induction drugs (not substitution-expanded).
- Build valid dual regimens from `DUALMAINTENANCEWITH`, both drugs required in induction.
- Anchor check: at least one induction drug outside the maintenance subset.
- Flag = 1 iff an anchor exists.

**Bort+Dara+Len example walk-through (the case Julia called "complicated"):** valid mono regimens from the rollup include BORT, DARA, LENA individually. For a patient with induction meds {BORT, DARA, LENA}, each mono regimen finds an anchor (the other two drugs). Dual regimens (DARA/LENA etc.) also anchor on BORT. Flag → 1. Matches Julia's statement: *"if Dara fell away, you could have Bort and Len left alone. Or it could be Dara and then fall away and then board is left alone, but you just need to have some … qualifying agent to sort of anchor your regiment."*

**LENA monotherapy example:** valid mono regimen = LENA; no other induction drug to anchor; flag = 0. Matches intent.

**Status:** ✅ Implemented and aligned.

### 2. Remove MAINTENANCE_END as a LOT1 end reason
**From transcript (Julia):**
> "if those people are not having another medication added, I think that we would just say that they're discontinued … we don't actually know if they're having a valid maintenance event happening"

**Code:** no occurrences of `'MAINTENANCE_END'` in any `THEN` branch of the `LOT1_BASE_END_REASON` CASE tree (verified via `grep`). Former maintenance-end patients now route via the ordinary earliest-event logic (to `DISCONTINUATION`, `MED_ADD`, `CART_INIT`, etc.).

**Status:** ✅ Removed.

### 3. Reclassify SCT_NO_MAINT patients (it was an artifact of the old maintenance framework)
**From transcript (Julia):**
> "SCT no maintenance … I think those also need to probably get reclassified … Either they're having a … new agent probably introduced or they're having a 3rd or unplanned atologous happening … if someone had an atologous, but they don't have a maintenance period to follow … So they're probably all going to be SCT auto this time"

**Code:** `LOT1_SCT_NO_MAINT_FLG` and `SCT_NO_MAINT_END_DT` derivations + all three "Rule 4" CASE branches (in end-reason, end-date, length) removed in pass 1 of the alignment work. `grep` for `SCT_NO_MAINT` returns zero matches across `Program/`.

**Status:** ✅ Removed. Former SCT_NO_MAINT patients now fall to `SCT_AUTO` (via the ordinary Rule 2 unplanned-AUTO path), `DISCONTINUATION`, `MED_ADD`, `CART_INIT`, or censoring, driven by their actual earliest end event — which matches Julia's intent.

**Important nuance for the Vicki review:** Julia's quick final summary in the meeting was *"probably all going to be SCT auto this time"*, but that's a simplification of what she said a minute earlier: *"Either they're having a new agent probably introduced **or** they're having a 3rd or unplanned autologous happening"*. The code matches the fuller version, not the simplification.

Per the spec (and per `lot_program.R:1286-1294`), `LOT1_TX_ENDDATE` is set only by **LOT-ending** SCT events — `ENDING_AUTO_DT` is the 3rd AUTO after a tandem pair, or the 2nd AUTO after a single. A clean single/tandem AUTO with no excess is **not** LOT-ending; the transplant is part of LOT1.

So former SCT_NO_MAINT patients now split across categories based on what actually ended their LOT1:

| Former SCT_NO_MAINT subgroup | Now classified as | Why |
|---|---|---|
| Single/tandem AUTO + later new med | `MED_ADD` (or `CART_INIT` if CAR-T within 45 days) | Transplant wasn't LOT-ending; the med add is |
| Single/tandem AUTO + 3rd/excess AUTO | `SCT_AUTO` (Rule 2 excess) | `ENDING_AUTO_DT` set; `LOT1_TX_ENDDATE_REASON = 1` |
| Single/tandem AUTO, no follow-up | `DISCONTINUATION` / `DEATH` / `DISENROLLMENT` / `STUDY_END` | LOT continued past the transplant; ended by another cause |

`SCT_AUTO` will still be the majority of the SCT-end bar (AUTO > ALLO > CART in MM), but not every former SCT_NO_MAINT patient ends up there. Worth mentioning to Vicki so the bar chart comparison against the old run doesn't look surprising.

### 4. CART_INIT rule — if CAR-T starts within 45 days of a new agent, end reason is CART_INIT not MED_ADD
**From transcript (Julia):**
> "if someone has a new medication added, but then it, like, within 45 days of that new agent, their starting car T, that their medic, their reason for law one end shouldn't be a medication ad. It actually should be initiation of Cart T therapy"

**Code:**
- Flag at `lot_program.R:1488-1494` (`CART_INIT_FLG`): `datediff(FIRST_CART_DT, ADD_START_DT) BETWEEN 0 AND {cfg$cart_consolidation_days}` with `cart_consolidation_days = 45` in `config_lot.R`.
- Routing branches in all three CASE trees (`:1528-1531`, `:1555-1557`, `:1583-1585`): `WHEN ec.CART_INIT_FLG = 1 … THEN 'CART_INIT'` / `THEN date_sub(ec.FIRST_CART_DT, 1)`.
- CART_INIT end date = `FIRST_CART_DT − 1` per the Apr 19 spec follow-up (applied in pass 1 of alignment work).

**Status:** ✅ Implemented with the 45-day window and day-before-CAR-T end date.

### 5. Top 15 / Top 25 induction regimens table — Onkar said he'd fix it; Julia said the underlying figures are accurate
**From transcript:**
> Onkar: *"it's just the top 15 regiments, right?"*
> Julia: *"No, I think the figures are accurate … It's just the induction regimen is, I thought, I thought, when I'm looking at, when I saw the numbers initially, 5000, it kind of triggered a bit, but … I think it makes, it is the correct number"*

**Code:** `descriptives_lot.R:577-628`. The regimens table groups by `LOT1_BASE_MEDS` and shows `n_patients`, `avg_base_length`; chart variant at `:601-624` is "Top 15 Induction Regimens". Structurally sound.

**Status:** ✅ Code is fine; any stale-looking numbers in a specific dashboard output are a data-refresh artifact, not a code issue. Per the transcript, Julia herself concluded the numbers are correct once recalculated.

### 6. Dashboard support for the Apr 19 end-reason categories
**From transcript (Julia):**
> "it looks like just the end reason is mostly the thing that is weird, if I had to guess"

**Code:** color mapping + Sankey node labels at `descriptives_lot.R:675-680` and `:1644-1648` cover every current final category: `DISCONTINUATION`, `MED_ADD`, `CART_INIT`, `SCT_AUTO`, `SCT_ALLO`, `SCT_CART`, `DEATH`, `DISENROLLMENT`, `STUDY_END`. No leftover colors for `MAINTENANCE_END` or `SCT_NO_MAINT` that would misleadingly render empty bars.

**Status:** ✅ Aligned.

### 7. `contains_mtx_reg` should appear in the final dataset
**From transcript (Julia):**
> "this is a new flag that I want to see in the final data set"

**Code:**
- Column is present in `lot1_base_end`: `lot_program.R:1462` — `COALESCE(cmr.contains_mtx_reg, 0) AS contains_mtx_reg`.
- S16 QC summary counts it: `:1583` — `sum(contains_mtx_reg) AS n_contains_mtx_reg`.

**Status:** ⚠️ Column is in the final dataset and the pipeline QC, but **not surfaced anywhere in `descriptives_lot.R` / `dashboard_lot.R`**. `grep -i contains_mtx_reg` across `Program/R/` returns zero matches. If Julia expects to see a distribution (count / % with `contains_mtx_reg = 1`, perhaps broken down by `LOT1_BASE_END_REASON`) in the QC dashboard for next week's Vicki review, that's worth adding before handoff. If seeing it only in the persisted table is enough, this is fine as-is.

### 8. Codelist additions discussed at end of meeting — Thal (mono), Dara/Len (dual)
**From transcript:** discussion of whether `DUALMAINTENANCEWITH` column for DARA should list LENA (and vice versa); Julia confirmed "Dara and Len" was added for this study; Thal as valid mono was also added.

**Code:** `mma_rollup` is loaded from CSV at S00 (`lot_program.R:96`). `MONOMAINTENANCE` and `DUALMAINTENANCEWITH` columns are consumed by `S16b_lot1_contains_mtx_reg` exactly as the meeting described. The code is fully parameterized — whatever the CSV says becomes the operative definition.

**Status:** ✅ Code is correct. ⚠️ **Cannot verify from the repo whether the actual CSV file has the agreed rows** (Thal with `MONOMAINTENANCE=1`; DARA's `DUALMAINTENANCEWITH` including LENA and vice versa). The codelist files live at `cfg$codelist_dir = /mnt/code/codelist/` (per `config_lot.R:27`), outside the repo. Worth an eyeball check on the `mma_rollup.csv` before the Vicki review.

### 9. LOT 2–5 programming
**From transcript:** explicitly agreed to start after LOT 1 is cleaned up; induction window shrinks 60 → 30 days; subsequent lots may start with CAR-T or transplant event.

**Code:** not implemented — LOT 2–5 is out of scope as agreed.

**Status:** 🔜 Out of scope. No action needed in LOT 1 finalization.

### 10. Ancillary analyses (cyclophosphamide deep-dive, BEND, Dara+Pom) — separate work
**From transcript:** Onkar already has cyclophosphamide-specific analysis (files shared via Domino); Peter (medical consultant) flagged BEND as unusual in 1st-line and Dara+Pom as typically 2nd-line. Julia said "wait till we get a more extensive list … we need to see their 2nd line before we start getting into patient examples".

**Code:** cyclophosphamide appendix at `R/cyclo_appendix_lot.R` exists and pulls the subcohort with `LOT1_BASE_MEDS = 'CYCL'` and single-med. BEND / Dara+Pom are not separately surfaced; those are awaiting a broader list.

**Status:** ✅ Existing; 🔜 broader list deferred per meeting.

---

## Items worth addressing before the Vicki review (optional)

| # | Item | Effort | Why |
|---|---|---|---|
| 1 | Surface `contains_mtx_reg` in the QC dashboard (count + % with flag = 1, ideally cross-tabbed against `LOT1_BASE_END_REASON`) | ~30 min | Julia said she wants to see it in the final dataset; it's there, but not visible from the dashboard she'll review |
| 2 | Eyeball `mma_rollup.csv` in the codelist directory to confirm Thal has `MONOMAINTENANCE=1` and DARA ↔ LENA appear symmetrically in `DUALMAINTENANCEWITH` | ~5 min | Data-side check, not code; matches the end-of-meeting discussion |
| 3 | Sanity-run the pipeline on a small cohort after the 3 alignment passes and compare `LOT1_BASE_END_REASON` counts against the pre-alignment run. Expect: zero `SCT_NO_MAINT` / `MAINTENANCE_END`; CART_INIT patients' `LOT1_BASE_END_DT` one day earlier; Step 6 → Step 10 cohort size drop from exclusion defaults now being `TRUE` | ~pipeline-run-time | Validates the alignment-pass behavioural changes before Vicki sees the numbers |

None of these are correctness issues — they're finalization polish. The LOT 1 code as it stands on the current branch addresses every LOT 1 decision from the Apr 15 meeting.

---

## What's deliberately NOT in this review

- **LOT 2–5**: out of scope per meeting.
- **Cyclophosphamide / BEND / Dara+Pom ancillary analyses**: awaiting a broader medical-consultant list.
- **Persisted-table content** (codelist CSV, patient counts): requires access to the actual data files, which aren't in the repo.
- **Protocol Section 5.1.1 wording**: Julia moved maintenance language to the limitations section — that's a protocol document edit, not a code action.

---

*End of LOT 1 finalization check.*
