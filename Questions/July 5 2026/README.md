# Julia's July 5 2026 questions — two artifacts, one is the real one

There are **two** things here with the same tab layout but very different status.
Read this before forwarding anything to Julia.

## 1. `apr_30_2026/julia_july5_qs.R` — the REAL generator (send Julia its output)

An R script (sibling of `lot1_studyteam_qs.R` / `validation_qs.R`) that runs
against Databricks and writes the real-cohort workbook:

```
cd apr_30_2026
Rscript julia_july5_qs.R          # -> $OUTPUT_DIR/julia_july5_answers_<stamp>.xlsx
```

- Answers Q1–Q5 on the delivered LOT cohort (real PATIDs, real counts) and the
  Optum coverage validation.
- Reuses the shared `R/validation_qs.R` helpers so nothing drifts from the
  dashboard.
- Requires `openxlsx` (writes one styled `.xlsx`). It **fails closed** if
  `openxlsx` is missing — set `ALLOW_CSV_FALLBACK=TRUE` only if you knowingly
  want one CSV per table instead.
- Any table it cannot produce is surfaced as a `NOTE:` line inside the workbook
  and the run log — an empty sheet never reads as "answered".

**The file you send Julia is the `.xlsx` this script produces**, not the file below.

## 2. `julia_july5_answers.xlsx` (+ `build_workbook.py`, `patient_journey_examples/`) — SYNTHETIC method demo

A self-contained, offline demonstration of the exact tab layout, built by
`build_workbook.py` from **synthetic, rule-faithful** patient journeys (reserved
IDs `9000000000+`). It contains **no real patient data or counts** — the
patient-level numbers require the warehouse run above. Use it to preview the
format and review the method; do **not** send it to Julia as the answer set.

---

If you only want one path, keep #1 and delete #2 — say the word and it goes.
