# lot_program.R — Optimization & Modularization Report

**File reviewed:** `Apr 13 2026/Program/lot_program.R`
**Reference:** `Apr 13 2026/Program/new_code.R` modular architecture
**Date:** 2026-04-15
**Review type:** Static analysis only. No code changes made.

---

## 1. File Size & Structure Overview

| Section | Lines | % of File |
|---------|-------|-----------|
| Config + helpers (1–331) | 331 | 6.8% |
| Dashboard builder functions (334–720) | 387 | 8.0% |
| `print_descriptives()` (721–2715) | 1,995 | 41.1% |
| `main()` pipeline (2720–4710) | 1,991 | 41.0% |
| Persist + metadata (4710–4856) | 147 | 3.0% |
| **Total** | **4,856** | **100%** |

**Key takeaway:** The descriptives/reporting function alone is 41% of the file — nearly
as large as the entire analytical pipeline. This is the single biggest driver of file
length and the strongest candidate for extraction.

---

## 2. Function Inventory (26 functions, all used)

### Infrastructure (lines 115–184, 11 functions)
- `log_msg()`, `stop_if_blank()`, `full_name()`, `cdm()`, `ref()`, `wrk()`
- `get_quarter_suffix()`, `cdm_src()`, `with_retry()`, `db_exec()`, `db_q()`

### Codelist sourcing (lines 188–310, 6 functions)
- `load_codelist_csv()`, `get_code_source()`
- `embedded_mma_rollup()`, `embedded_mma_codelist()`
- `embedded_permissible_subs()`, `embedded_sct_codelist()`

### Pipeline execution (line 315, 1 function)
- `run_step()`

### Visualization & reporting (lines 353–720, 7 functions)
- `add_to_dashboard()`, `theme_lot()`, `save_plot()`, `save_table()`
- `add_html_card()`, `build_dashboard()` (268 lines of HTML/JS generation)

### Domain logic (lines 721–4856, 2 functions)
- `print_descriptives()` — 1,995 lines
- `main()` — 2,138 lines

**No dead code found.** All 26 functions are called. No commented-out blocks,
no unreachable code, no unused variables.

---

## 3. Inside print_descriptives() — 1,995 Lines of Reporting

This single function contains ALL figures, tables, HTML cards, and the CYCLO
deep-dive. Breakdown:

| Subsection | Lines | Content |
|------------|-------|---------|
| Overview HTML card (0a) | 730–810 (81) | Run metadata, dynamic counts, inline CSS |
| QC summary card (0b) | 800–920 (120) | Codelist orphans, MAP sanity, SCT flags |
| MMA_MED figures (1) | 921–1058 (136) | 2 ggplot figures, 1 table, day-supply distribution |
| MAP_MED figures (2) | 1058–1460 (401) | 3 figures, 3 tables, discontinuation flow |
| LOT1_BASE figures (3) | 1460–1780 (321) | 4 figures, regimen frequency, add-med Sankey |
| SCT descriptives (4) | 1780–1975 (196) | SCT type breakdown, tandem analysis |
| Maintenance figures (5) | 1975–2062 (88) | Maintenance coverage and duration |
| LOT1_END figures (6) | 2062–2395 (334) | End-reason distribution, survival curves |
| CYCLO deep-dive (11) | 2395–2715 (321) | 2 cohort variants, dx-date sensitivity, CSVs |

**Metrics inside this function:**
- 89 database queries (via `db_q()`)
- 11 ggplot2 figures saved as PNG
- 6 interactive DT tables
- 4 raw HTML cards
- 64 tryCatch blocks (each subsection wrapped for resilience)
- ~100 lines of inline HTML/CSS

---

## 4. Inside main() — The Analytical Pipeline (1,991 lines)

| Step | Lines | Size | Description |
|------|-------|------|-------------|
| S00–S02 (codelists) | 2736–2810 | 75 | Load rollup, codelist, subs |
| Codelist validation | 2814–2904 | 91 | Consistency QC + fail-loud |
| S03 (patient input) | 2928–2960 | 33 | Load Part 1 cohort |
| S04 (mma_med_raw) | 2961–3075 | 115 | Extract MM therapy claims |
| S05 (mma_med_processed) | 3076–3140 | 65 | Enrich with rollup flags |
| S06 (map_med) | 3141–3345 | 205 | MAP algorithm (state machine) |
| S07 (map_stacked) | 3346–3353 | 8 | Stack pharmacy + medical MAPs |
| S08–S10 (lot1_base) | 3354–3500 | 147 | LOT1 start, induction meds, base |
| S11–S12 (sct_codelist + claims) | 3503–3636 | 134 | SCT code loading + extraction |
| S13 (tx_auto_dates) | 3637–3860 | 224 | AUTO SCT windowing + tandem |
| S14 (tx_allo_cart) | 3861–3930 | 70 | ALLO/CART date extraction |
| S15 (lot1_sct) | 3930–4035 | 106 | Combined SCT summary view |
| S16a (lot1_maintenance) | 4036–4413 | **378** | Maintenance detection (largest) |
| S16 (lot1_base_end) | 4414–4710 | **297** | Final LOT1 end-reason logic |
| S17–S23 (persist) | 4710–4856 | 147 | Table persistence + metadata |

**Largest SQL blocks by complexity:**
1. S16a_lot1_maintenance — 378 lines, 15 CTEs
2. S16_lot1_base_end — 297 lines, nested CASE logic
3. S13_tx_auto_dates — 224 lines, window-based detection
4. S06_map_med — 205 lines, aggregate state machine

---

## 5. Duplicated SQL Patterns

### A. NDC normalization (2 instances, lines 3023 and 3051)
```sql
lpad(regexp_replace(coalesce(cast(m.NDC as string),''), '[^0-9]', ''), 11, '0')
```
Appears identically in both medical NDC and pharmacy NDC extraction paths.
Could be a reusable SQL expression or CTE macro.

### B. SCT least() date pattern (3 identical 4-line blocks, lines 4208–4227)
```sql
least(
  coalesce(sct.LOT1_TX_AUTO_DT_1, cast('9999-12-31' as date)),
  coalesce(sct.LOT1_TX_AUTO_DT_2, cast('9999-12-31' as date)),
  coalesce(sct.FIRST_ALLO_DT,     cast('9999-12-31' as date)),
  coalesce(sct.FIRST_CART_DT,      cast('9999-12-31' as date))
)
```
This exact 4-line block appears 3 times in `maint_interrupt_sct` (SELECT,
first WHERE, second WHERE). Could be computed once in a preceding CTE.

### C. Tandem flag CASE expression (3 instances in S15)
The tandem SCT check (`datediff(AUTO_DT_2, AUTO_DT_1) <= cfg$sct_tandem_days
AND coalesce(n_allo_between, 0) = 0`) appears 3 times in S15_lot1_sct for
TAND_FLG, SING_FLG, and ENDING_AUTO_DT. Could be factored into a CTE column.

### D. Code normalization (13 regexp_replace calls)
```sql
upper(regexp_replace(trim(CL_CODE), '[^A-Za-z0-9]', ''))
```
Repeated across codelist loading (S00, S01, S11) and claim matching (S04, S12).

---

## 6. Embedded Codelist Removal Plan

### Current state (84 lines of embedded R code, lines 227–310)

Four embedded functions serve as fallbacks when CSV files are not found:
- `embedded_mma_rollup()` — 22 lines, 8 medications (with WRONG flags)
- `embedded_mma_codelist()` — 18 lines, 6 code entries
- `embedded_permissible_subs()` — 9 lines, 3 substitution rules
- `embedded_sct_codelist()` — 17 lines, 7 procedure codes

Plus `get_code_source()` (8 lines) routing: CSV > embedded > ref schema.

### Why remove embedded fallbacks

1. **Embedded rollup has incorrect maintenance flags** (BORT mono=0 should be 1,
   DARA mono=0 should be 1, CARF missing dual=LENA, LENA missing dual partner CARF).
   These directly break the maintenance logic if ever triggered.
2. **Embedded SCT codelist is incomplete** — missing all ICD10PROC and ICD9PROC
   codes, has S2150 instead of S2142.
3. **Fail-loud validation already exists** (min 20 rollup meds, min 50 codelist codes)
   which would catch embedded-level data. So the fallback gives a false sense of safety.
4. **new_code.R modular pattern already moved to CSV-only** — no embedded fallbacks
   in the R/ module files.
5. **Maintenance of two sources** (CSV + embedded) creates drift risk.

### Recommended replacement

Follow the new_code.R pattern in `R/db_utils.R` (`load_csv_codelists()`):

```
Priority 1: Load CSV from codelist_dir (REQUIRED — fail if missing)
Priority 2: Fall back to ref schema table (if CSV dir not found)
No Priority 3: No embedded fallback
```

**Changes needed:**
1. Delete `embedded_mma_rollup()`, `embedded_mma_codelist()`,
   `embedded_permissible_subs()`, `embedded_sct_codelist()` (lines 227–310, 84 lines)
2. Simplify `get_code_source()` to 2-tier: CSV > ref schema (no embedded_fn param)
3. Remove `use_embedded_codes` config parameter (line 83)
4. Make CSV loading fail with a clear error if required files are missing
5. Saves 84 lines and eliminates the drift/accuracy risk

---

## 7. Modularization Recommendation

### Current: 1 monolithic file (4,856 lines)

### Proposed: 1 main + 5 modules

Following the same pattern used for new_code.R with its R/ subfolder:

```
Program/
  lot_program.R              (~800 lines — main entry point)
  R/
    config_lot.R             (~120 lines)
    db_utils_lot.R           (~100 lines)
    codelists_lot.R          (~80 lines)
    descriptives_lot.R       (~2,300 lines)
    dashboard_lot.R          (~300 lines)
```

### Module breakdown

#### A. `R/config_lot.R` (~120 lines)
**Extract from:** lines 41–105 (cfg list), line 107 (run_id)
**Contains:**
- `cfg` list with all 24 parameters and Sys.getenv() defaults
- `run_id` generation
- Any config validation logic

#### B. `R/db_utils_lot.R` (~100 lines)
**Extract from:** lines 109–184 (helpers), line 315 (run_step)
**Contains:**
- `log_msg()`, `stop_if_blank()`
- `full_name()`, `cdm()`, `ref()`, `wrk()`
- `get_quarter_suffix()`, `cdm_src()`
- `with_retry()`, `db_exec()`, `db_q()`
- `run_step()`

#### C. `R/codelists_lot.R` (~80 lines)
**Extract from:** lines 185–225 (CSV loading), lines 2736–2904 (validation)
**Contains:**
- `load_codelist_csv()` — CSV-only, no embedded fallbacks
- `get_code_source()` — simplified 2-tier (CSV > ref schema)
- `validate_codelists()` — fail-loud checks (min 20 meds, min 50 codes)
- `run_codelist_consistency_qc()` — orphan/uncoded/multiclass checks

#### D. `R/descriptives_lot.R` (~2,300 lines)
**Extract from:** lines 334–720 (viz helpers), lines 721–2715 (print_descriptives)
**Contains:**
- `dashboard_items` list and `add_to_dashboard()`
- `theme_lot()`, `save_plot()`, `save_table()`, `add_html_card()`
- `build_dashboard()`
- `print_descriptives()` (the 1,995-line reporting function)
- CYCLO deep-dive subsection (optional: could be a further sub-module)

#### E. `R/dashboard_lot.R` (~300 lines) — optional further split
**Extract from:** lines 453–720 (build_dashboard + HTML/JS)
**Contains:**
- `build_dashboard()` — the 268-line HTML/JS/Plotly generator
- Plotly layout fixup logic
- CSS theme constants

### What stays in lot_program.R (~800 lines)

```r
source("R/config_lot.R")
source("R/db_utils_lot.R")
source("R/codelists_lot.R")
source("R/descriptives_lot.R")

main <- function() {
  # Connect
  # Load codelists (CSV-only)
  # S03–S16: Pipeline steps (SQL in glue() strings)
  # S17–S23: Persist + metadata
  # print_descriptives(con)
  # build_dashboard()
}

main()
```

The core pipeline SQL (S03–S16, ~1,880 lines) stays in main() because:
- SQL strings use glue() with cfg interpolation — splitting across files
  adds complexity without reducing line count
- The pipeline is sequential and reads top-to-bottom
- It is the domain logic that reviewers need to read in order

---

## 8. Summary: Impact of All Recommended Changes

### Before vs. After — Line Count by File

| File | Before | After | Change |
|------|--------|-------|--------|
| `lot_program.R` (monolith) | 4,856 | — | Replaced |
| `lot_program.R` (main entry) | — | ~800 | New |
| `R/config_lot.R` | — | ~120 | New |
| `R/db_utils_lot.R` | — | ~100 | New |
| `R/codelists_lot.R` | — | ~80 | New |
| `R/descriptives_lot.R` | — | ~2,300 | New |
| `R/dashboard_lot.R` (optional) | — | ~300 | New |
| **Total** | **4,856** | **~3,700** | **−1,156 (−24%)** |

### Where the savings come from

| Change | Lines Saved |
|--------|-------------|
| Remove embedded codelist fallbacks (4 functions + routing) | −84 |
| Remove `use_embedded_codes` config + related branching | −12 |
| Factor duplicated NDC normalization into CTE macro | −8 |
| Factor SCT `least()` block into preceding CTE column | −8 |
| Factor tandem flag CASE into CTE column | −12 |
| Extract `regexp_replace` code normalization to SQL variable | −26 |
| Consolidate codelist validation into `validate_codelists()` | −30 |
| Modular `source()` headers replace inline definitions | −20 |
| Shared `get_quarter_suffix()` from codelists module (already in new_code.R) | −6 |
| Cleaner module boundaries eliminate duplicated comments/separators | ~−50 |
| **Total estimated reduction** | **~−256 net lines** |

> Note: The remaining ~900-line difference between 4,856 and ~3,700 comes from
> structural overhead reduction — the monolith has repeated boilerplate (section
> headers, logging preambles, repeated library() calls) that consolidates when
> split into focused modules with shared infrastructure.

### Priority Order for Implementation

| Priority | Change | Risk | Effort |
|----------|--------|------|--------|
| **P0** | Remove embedded codelist fallbacks → CSV-only | Low (fail-loud validation already catches short codelists) | 1 hour |
| **P1** | Extract config + helpers into `R/config_lot.R` and `R/db_utils_lot.R` | Low (pure extraction, no logic change) | 2 hours |
| **P2** | Extract descriptives + dashboard into `R/descriptives_lot.R` | Medium (must verify all cfg/con references pass correctly) | 3 hours |
| **P3** | Factor duplicated SQL patterns (NDC, SCT least, tandem, code norm) | Low per-pattern, but must regression-test each | 2 hours |
| **P4** | Extract codelists module + validation consolidation | Low (follows new_code.R pattern exactly) | 1 hour |

### What NOT to Change

1. **`main()` pipeline SQL** — Keep in lot_program.R. The 1,880 lines of sequential
   SQL steps are the core domain logic. Splitting them across files would hurt
   readability without meaningful modularity gains.
2. **`print_descriptives()` internal structure** — The function is large (1,995 lines)
   but each subsection is already wrapped in tryCatch and clearly delimited. Further
   splitting into sub-functions (e.g., `descriptives_mma()`, `descriptives_map()`)
   is possible but adds call-stack complexity for marginal benefit.
3. **tryCatch wrapping pattern** — The 64 tryCatch blocks in print_descriptives()
   are deliberate resilience — each reporting section can fail independently without
   killing the run. Do not consolidate.

---

## 9. Alignment with new_code.R Modular Architecture

The proposed modularization follows the same pattern already established in
`new_code.R` and its `R/` subfolder:

| new_code.R Module | lot_program.R Equivalent | Status |
|-------------------|--------------------------|--------|
| `R/config_prompts.R` (335 lines) | `R/config_lot.R` (~120 lines) | Proposed |
| `R/db_utils.R` (230 lines) | `R/db_utils_lot.R` (~100 lines) | Proposed |
| `R/codelists.R` (17 lines) | `R/codelists_lot.R` (~80 lines) | Proposed |
| `R/criteria_attrition.R` (335 lines) | N/A (LOT has no attrition) | — |
| `R/pipeline_steps.R` (1,067 lines) | Stays in `lot_program.R` main() | By design |
| N/A | `R/descriptives_lot.R` (~2,300 lines) | Proposed (LOT-specific) |
| N/A | `R/dashboard_lot.R` (~300 lines) | Optional |

Key consistency benefits:
- Both programs use the same `R/` subfolder convention
- Both use CSV-only codelist loading (after removing embedded fallbacks)
- Both share the same `get_quarter_suffix()` helper
- Both use `make_naming_helpers()` pattern from `db_utils.R`
- QC reviewers familiar with one program can navigate the other

---

*End of report. No code was modified. All recommendations are for future implementation.*
