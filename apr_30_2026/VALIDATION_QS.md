# MM LOT Validation next steps — study-team Q&A

Answers the six study-team follow-up questions. Two deliverables, one shared
logic module so they can never drift apart:

| File | What it is |
|------|------------|
| `R/validation_qs.R` | Shared logic (SQL → data.frame). Single source of truth for every definition. |
| `validation_qs.R` | **Standalone program.** Runs all six analyses, writes one CSV per result + a run log. |
| `07_combined_dashboard.R` | Renders the same six answers as labelled tables under a new **Exploratory analysis** cohort pill. |

**Cohorts (study-team follow-up):** every question is answered
**once per cohort** — the parent **Overall** `LOT_LONG` cohort always, and the
**NDMM** (1L newly-diagnosed) cohort when available. In the dashboard, titles
carry the cohort tag (`Q1 (Overall): …` / `Q1 (NDMM): …`); the NDMM answers
render when the NDMM cohort pass succeeded, otherwise a note card explains the
gap. The standalone answers NDMM when the persisted `NDMM_LOT_LONG_FILT`
work-schema table (materialized by the combined dashboard's NDMM pass) is
readable; its NDMM CSVs carry an `ndmm_` filename prefix (Overall filenames
are unchanged). The shared signal views (steroid claims, raw CAR-T dates) are
built once on the parent patient list — NDMM patients are a strict subset
(inner join to the NDMM patient set), and every per-question query joins back
to its own cohort's `LOT_LONG`, which applies the restriction.

## Run

```bash
# Standalone (CSVs in $OUTPUT_DIR):
Rscript validation_qs.R

# In the combined dashboard (Exploratory pill):
Rscript 07_combined_dashboard.R   # or the usual run_all.R
```

Requires `DATABRICKS_PWD`. Reads only the persisted work-schema tables
(`LOT_LONG`, `MAP_STACKED`, `LOT1_SCT`) and — for the raw-claim patient
examples — the raw CDM via `cdm_src()`. Builds nothing persistent.

## The questions

1. **Q1** — LOT1 regimens including pomalidomide / elotuzumab / panobinostat,
   split into mono- vs combination-therapy (and an "any of the three" total).
2. **Q2** — raw-claim patient examples (before MAPs were derived) for patients
   with pomalidomide in their LOT1 regimen, beside the MAP-derived journey.
3. **Q3** — among LOT1 patients with **no** steroid at LOT1, how many received
   a steroid within 7/14/30 days **before** LOT1 start and within 7/14/30 days
   **after** the 60-day induction window. Answered both as counts (the summary
   table) **and** patient-level ("who": one row per such patient with per-window
   flags + nearest steroid dates) — the standalone writes the full patient list;
   the dashboard shows a capped, full-only sample.
4. **Q4** — same as Q3 for LOT2 (30-day induction window), counts + "who".
5. **Q5** — patients with no steroid at LOT2 but a steroid in the 30 days
   before LOT2 start: is that pre-LOT2 steroid actually attributable to the
   LOT1 regimen? **Headline (direct test):** how many have the *pre-LOT2
   steroid date itself* fall inside LOT1's span `[LOT1_START, LOT_BASE_END_DT]`
   (vs. not within span). Two "had any steroid at LOT1 induction / during
   LOT1" rows are kept as supporting context — they are deliberately *not* the
   headline because a patient can have an earlier LOT1 steroid plus a separate
   pre-LOT2 steroid that lands after LOT1 ended.
6. **Q6** — patients with CAR-T prior to or during LOT1 (the LOT rules do not
   allow CAR-T during LOT1), with raw-claim journey examples.

## Operational definitions (stated on every output)

- **Steroid signal**: the codes in `steroid_codes.csv` (mapped to DEX/PRED
  tokens) scanned against medical (`PROC_CD`/`BILL_PROC_CD` HCPCS/CPT, `NDC`)
  and rx (`NDC`) — the **same source** `05_regimen_dashboard.R` uses
  (`load_steroid_codes` + `augment_lot_long`). This is the project's *only*
  steroid source: there is **no** `STEROID` class in `cl_mma_codelist.csv`, so a
  `MAP_STACKED` STEROID scan returns zero and would silently empty Q3/Q4/Q5.
  ⚠️ The tracked `steroid_codes.csv` currently ships only a few HCPCS codes and
  **0 NDC rows**, so oral-RX steroids are undercounted until NDC codes are added
  — Q3/Q4/Q5 are only as complete as that CSV. If the CSV is empty, Q3/Q4/Q5 are
  skipped with a note rather than reported as all-zero.
- **"Steroid classified as part of LOT*n*"** (the no-steroid **denominator**): a
  steroid **claim** within the *capped* induction window `[LOT_START_DT,
  LOT_INDUCTION_END_DT]`, where `LOT_INDUCTION_END_DT = least(LOT_BASE_END_DT,
  LOT_START_DT + W − 1)`, `W` = 60 (LOT1) / 45 (CART-started LOT*n*, i.e. the
  `cart_consolidation_days` default) / 30 (other LOT*n*); SCT_ALLO lines have no
  steroid membership. The displayed window values track config at runtime. This mirrors the Steroids
  panel's augmentation (`LOT_INDUCTION_END_DT`) **exactly**, so the no-steroid
  denominators reconcile with that panel. (Earlier versions used an uncapped
  fixed window, which over-counted "steroid at LOT" for short lines.)
- **Before / after windows** (7/14/30 d) are cumulative (≤ N days), measured
  from a steroid claim date. "Before" is relative to `LOT_START_DT`; "after" is
  relative to the **fixed** induction end `LOT_START_DT + W − 1` (the "60/30 day
  induction window" the study team named) — not the capped `LOT_INDUCTION_END_DT`. Steroid
  claims are scanned across all of a patient's history (matching the panel), not
  bounded to `[INDEX_DATE, OBS_END_DT]`, so a pre-index steroid can fall in a
  LOT1 "before" window.
- **CAR-T (Q6)** — two date sources, by necessity:
  - *During or closing LOT1*: `LOT1_SCT.FIRST_CART_DT` in `[LOT1_START,
    LOT_BASE_END_DT]`, **extended by +1 day only when the end reason is
    `SCT_CART`/`CART_INIT`** (i.e. CAR-T itself closed LOT1). The engine sets
    the LOT end to the CAR-T date − 1 day *for a CAR-T-ending LOT1*
    (`02_lot1.R` `LOT1_TX_ENDDATE`), so the closing CAR-T lands one day past
    `LOT_BASE_END_DT`; for any other end reason a CAR-T at `LOT_BASE_END_DT + 1`
    is post-LOT1 and is not counted. `FIRST_CART_DT` is itself always ≥
    `LOT1_START`.
  - *Before LOT1*: from **raw SCT CAR-T claims** (observation-window bounded),
    because `LOT1_SCT.FIRST_CART_DT` is derived only from CAR-T on/after LOT1
    start (`first_cart` filters `TX_DT >= LOT1_START_DT`) and so can never be
    before LOT1. If the raw scan / `ELIG_COH_FINAL` bounds are unavailable,
    the before-LOT1 rows are reported as `NA` (not a misleading `0`).
    Scope note: "before LOT1" here means a CAR-T claim in `[INDEX_DATE,
    LOT1_START − 1]` (the analytic post-index window), **not** lifetime
    pre-index history. If the study team wants any CAR-T ever before LOT1
    including pre-index claims, this would need a wider lookback than the
    pipeline's extraction window.
- **Agent tokens**: POMA / ELOT / PANO, best-effort resolved from
  `cl_mma_codelist.csv` by medication-full-name (override via
  `POMA_MED_ABBR` / `ELOT_MED_ABBR` / `PANO_MED_ABBR`). A zero count
  (e.g. panobinostat absent from the cohort) is itself a valid answer.

The raw-claim example pulls (Q2, Q6) are **bounded to each patient's
`[INDEX_DATE, OBS_END_DT]` window** (reconstructed from `ELIG_COH_FINAL` the
same way the pipeline builds `lot_patient_input`), so they mirror the
pipeline's S04/S12 raw extraction rather than a patient's whole claim history.
They are also **guarded**: if the CDM / codelist CSVs / `ELIG_COH_FINAL` are
unreachable they degrade to a note (in both the CSV log and a dashboard card)
and the reliable MAP-derived journey is shown instead; when bounds are
unavailable the examples fall back to full PATID history and say so. Raw
per-patient tables are tagged "(sample)" so the dashboard keeps them in the
full-only Patient-explorer view. The standalone program also writes a
`validation_qs_definitions_<stamp>.csv` sidecar with these definitions.

## Steroid source (resolved) + remaining data limitation

Q3–Q5 now use the **same** steroid source as the rest of the dashboard —
`steroid_codes.csv` scanned on medical+rx — so the numbers reconcile with the
existing Steroids section. (An earlier version used a `MAP_STACKED` STEROID
class, which does **not** exist in `cl_mma_codelist.csv`; that returned zero and
made Q3/Q4/Q5 read as "every patient has no steroid", which the first dashboard
run surfaced.)

**Remaining limitation — not a code issue:** `steroid_codes.csv` is still a
near-placeholder (a few HCPCS codes, **0 NDC**). So Q3/Q4/Q5 capture
medical/HCPCS steroid administrations but undercount oral-RX (NDC) steroids
until the full code list is dropped into that CSV. The standalone log and the
dashboard intro card state how many codes were loaded each run. Adding the NDC
steroid codes is the one outstanding input needed for complete Q3–Q5 answers.
