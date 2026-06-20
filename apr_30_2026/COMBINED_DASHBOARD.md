# Combined LOT dashboard (`07_combined_dashboard.R`)

One self-contained HTML (`combined_dashboard.html`) covering both cohorts.

```
Rscript apr_30_2026/07_combined_dashboard.R
```

The two standalone dashboards still build unchanged:
`05_regimen_dashboard.R` (Overall) and `06_ndmm_dashboard.R` (NDMM).

## Layout

The left sidebar has **cohort pills**, each a different accent colour:

| Pill | Accent | Contents |
|------|--------|----------|
| **Summary** | slate | Executive landing page (opens first) |
| **Overall** | teal | Whole parent LOT_LONG cohort |
| **NDMM** | orange | 1L newly-diagnosed cohort (IE gates) |

Within Overall and NDMM, views are grouped into collapsible **buckets**
(`tag_and_order()` in `07`, by title prefix):

- **Cohort & attrition** — KPIs, overview, attrition, funnel
- **Treatment patterns** — start/end type, length, regimens, transitions, Sankeys, gaps, med count, maintenance, trend
- **Steroids & payer** — steroid prevalence/timing aggregates, pre-LOT steroid summaries, payer mix
- **Patient explorer** — *full-only* — patient gallery, med journeys, and every raw-PATID example/sample table
- **Validation** — *full-only* — QC and validation tables
- **Debug** — *full-only* — table inventory, the any-PATID drilldown

The empty "Exploratory" group is intentionally **not** built; it returns
only when a real different-denominator analysis exists.

## Stakeholder vs Full toggle

A topbar **`View: Stakeholder / Full`** button (default **Stakeholder**)
hides the three full-only buckets, leaving a clean three-bucket nav per
cohort. Each item carries an `audience` tag (`classify_item()`); the
classifier **fails closed** — an unrecognized title is treated as full and
hidden from Stakeholder mode.

This is a **presentation cut, not a data-removal boundary**: all data is
still embedded in the file regardless of mode. That is acceptable for the
stated internal-GSK distribution, where recipients have equivalent data
access. A deep link / URL hash to a full-only view auto-switches to Full
mode so the toggle, sidebar and panel always agree.

## Summary landing page

Built after both cohort passes (so it can compare them), then sorted to the
front. All figures are computed at build time — nothing is hard-coded:

- **Headline stat cards** — Overall and NDMM patient counts, NDMM as % of Overall
- **Comparison table** — patients, LOT2+/LOT3+ reach, median LOT1 length, date range
- **Key findings** — payer mix, pre-LOT steroid N-of-M + mean lead time, DEXA-vs-LENA timing, for both cohorts (reused from the detail builders, never re-derived)
- **Run & data quality strip** — study end, **steroid codes by type (HCPCS, CPT when present, NDC)**, category rules, generated time, and per-cohort build status (`built` / `built with warnings` / `unavailable`)
- **Steroid codelist state** (one shared `steroid_state()` drives the Summary, the overview banner, and the per-cohort steroid section identically) — three states:
  1. **unavailable** — no usable codes loaded (CSV missing/empty/wrong-schema, or rx/medical unreadable): red alert, steroid findings suppressed and the detail steroid builders skipped, so nothing reads as a real zero
  2. **procedure_only** — HCPCS/CPT codes present but **0 NDC**: amber undercount caveat (oral-RX steroids not captured), findings kept
  3. **ndc_present** — at least one NDC code present: no warning. (Named `ndc_present`, not `complete` — it does not prove the DEXA/PRED value set is fully covered; that needs a validated value-set check.)
- **NDMM warning** — an amber **built with warnings** box when configured NDMM gates were skipped (a required source was unavailable); warnings render before the findings

NDMM degrades to `n/a` across the page when that cohort cannot be built.
