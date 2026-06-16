# NDMM (newly-diagnosed) cohort dashboard

`06_ndmm_dashboard.R` builds the **regimen-transition + steroid dashboards on the NDMM
cohort** (IE-filtered 1L newly-diagnosed population) rather than on the
whole `LOT_LONG` cohort.

> Source: the NDMM cohort spec PDF, page 1 yellow
> highlight ("Can we also have a look at all of these new IE criteria
> being implemented, please show bullets 1-3 above amongst the whole
> cohort and the planned study cohort.")

The whole-cohort view is produced by `../05_regimen_dashboard.R`. This script
reuses every helper from that file verbatim - no logic is forked.

> **Cohort label:** in dashboard output this planned cohort is labelled
> **NDMM** (1L newly-diagnosed). Internal symbols use the `NDMM_`
> prefix (e.g. the `_ndmm_patids` temp view, the `ndmm_dashboard.html`
> filename).

## One combined dashboard (both cohorts + exploratory)

`../07_combined_dashboard.R` produces a **single** HTML
(`combined_dashboard.html`) whose left sidebar has three
top-level groups:

```
Overall                whole parent LOT_LONG cohort
                       (regimen transitions + steroids + QC + full LOT1-5 detail + Debug/Drilldown)
NDMM                   this planned 1L cohort
                       (regimen transitions + steroids + QC + full LOT1-5 detail, on filtered LOT_LONG)
Exploratory analysis   ad-hoc / one-off requests
```

Inside a cohort, items are clustered by title prefix: `Transitions: / Steroids: / QC:`
for the regimen-transition builders, and `FUNNEL: / START_TYPE: / END_REASON:
/ LENGTH: / REGIMENS: / PROGRESSION: / GAPS: / TRANSITIONS: / SANKEY: /
MEDCOUNT: / MTX: / TREND: / MED JOURNEY:` for the LOT1-5 detail.

It reuses `prepare_overall_cohort()` (from `../05_regimen_dashboard.R`),
`prepare_ndmm_cohort()` (this file, extracted from `main_ndmm()`), and
`collect_lot_long_views()` (`../04_lot_detail_dashboard.R`, extracted from
its `main()`), running everything into one accumulating
`dashboard_items` and writing once. The three standalone dashboards
still build exactly as before - nothing is forked.

**Adding a new LOT1-5 view:** drop a builder call inside
`collect_lot_long_views()` in `../04_lot_detail_dashboard.R` using the same
`save_table` / `save_plot` / `add_html_card` / `add_to_dashboard`
sinks. The standalone dashboard picks it up automatically, and the
combined dashboard also picks it up under both cohorts (it gets
re-sectioned to "Overall" / "NDMM" by `resection_recent_items` in the
orchestrator, with the original section name folded into the title).

**Where an ad-hoc ask goes** : if it reuses the Overall
or NDMM denominator (same patient counts) it is added *under that
cohort* as a `QC:` / `Sensitivity:` item; if it changes the cohort (a
different denominator, e.g. a POMA subset) it goes under **Exploratory
analysis**. No different-cohort asks exist yet, so that group currently
ships as a scaffold describing the rule.

## Cohort definition

The NDMM cohort is layered on top of the parent pipeline:

```
LOT_LONG                                          # whole cohort
  + in ELIG_COH_FINAL                             # parent IE (Step 6 for this project)
  + LOT1_START_DT >= NDMM_LOT1_FROM (default 2017-01-01)  # NDMM cutoff
  + 12-mo CE before LOT1_START_DT                 # NDMM filter
  + 3-mo follow-up CE from LOT1 (strict no-gap)   # NDMM filter
  + no belantamab in any LOT                      # NDMM filter
  + no MM oncology Tx in [LOT1-365, LOT1-1]       # NDMM filter
  + no other active cancer in [LOT1-365, LOT1-1]  # NDMM filter
  + no pregnancy                                  # NDMM filter (re-scan pregnancy.csv)
  = NDMM_PATIDS
```

Counts at each step are printed as the OVERVIEW attrition table in the
output dashboard and to stdout when the script runs.

### Why these NDMM filters live here and not in the parent

Each is a wording change in the spec that does **not** match
what the May 12 program spec (the parent's source of truth)
implements. We add them only for this NDMM view so the parent
pipeline and its persisted tables stay untouched.

| NDMM filter                                | spec wording                                                                                                                                | Parent (May-12 spec) equivalent                                  | What's different                                                                                          |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| LOT1 start >= 2017-01-01                 | "Received an eligible treatment for MM ... on or after 01 Jan 2017"                                                                               | Parent's `id_start` defaults to 2016-01-01                       | NDMM hard-enforces the 2017 cutoff regardless of upstream `id_start`. Env-overridable via `NDMM_LOT1_FROM`.    |
| 12-mo CE before LOT1                     | "CE of at least 12-months ... before the 1L cohort index date and at least 6 months before the MM diagnosis"                                      | `CE_b` = 6-mo CE before `INDEX_DATE` (MM dx)                     | Spec adds a second window with a different anchor (1L treatment start). Parent already enforces 6-mo MM-dx anchor. |
| No belantamab in any LOT                 | "Eligible 1L treatment: Received an eligible treatment for MM (other than belantamab)" + "Received belantamab (i.e., an ADC) in any LOT"          | Not present                                                      | Net-new exclusion.                                                                                        |
| No MM oncology Tx in 12-mo pre-LOT1      | "Evidence of treatment with another MM oncology therapy during the 12-month 1L baseline period"                                                   | `MM_BASELINE_EVIDENCE` from `therapy_flags` = 6-mo before MM dx  | Same intent, different window and anchor: 12-mo before LOT1 vs. 6-mo before MM dx.                        |
| No other active cancer in 12-mo pre-LOT1 | "Evidence of another active cancer ... during the 1L baseline period"                                                                             | `OTHER_MALIGN_FLAG` from parent step 22 = 6-mo before MM dx       | Same intent, different window and anchor: 12-mo before LOT1 vs. 6-mo before MM dx.                        |
| 3-mo follow-up CE from LOT1 (no gaps)    | "CE of at least 3-months during follow-up or death with no gaps in enrollment"                                                                    | `CE_3mosf` = no-gap 90-day CE from `INDEX_DATE` (MM dx)           | Re-derived anchored at LOT1 (the 1L index) using a strict no-gap spans view + carried-forward `DEATH_DT`. |
| No pregnancy                             | "Evidence of pregnancy ... during the study period"                                                                                               | `PREGNANT_FLAG` from parent step (gate off for this project)      | Re-scanned in the NDMM layer from `pregnancy.csv` (dx / proc / revenue) over the study period, restricted to NDMM LOT1 candidates. |

## How the NDMM filters are implemented

All six filters are computed as flags in a single per-PATID temp
view (`_ndmm_flags_all`) so the attrition card can count each step
independently. Final NDMM membership requires all six flags set
(the LOT1 cutoff is enforced upstream in `NDMM_LOT1_STARTS` and so
appears in the funnel as the `LOT1 >= NDMM_LOT1_FROM` row rather than
as a flag column).

### LOT1 start cutoff (>= 2017-01-01)
`build_lot1_starts_ndmm()` adds `LOT_START_DT >= date('{NDMM_LOT1_FROM}')`
to the LOT1 view. Default `2017-01-01`, env-overridable via
`NDMM_LOT1_FROM`. The cutoff is independent of the parent's `id_start`
(which defaults to 2016-01-01 in `config_prompts.R:87`), so NDMM enforces
the spec wording regardless of how the upstream cohort was built.
Because every downstream NDMM filter joins from `NDMM_LOT1_STARTS`, the
cutoff propagates automatically.

### 12-mo CE before LOT1
Built from `member_enrollment` raw eligibility records with
**identical** span SQL as the parent's `enrollment_spans` view
(`R/pipeline_steps.R:382-421`). Gap absorption is configurable via
`GAP_DAYS` env var (default 30, matches `config_prompts.R:90`). A
patient passes if at least one merged span covers
`[LOT1_START_DT - 365, LOT1_START_DT - 1]`.

### No belantamab in any LOT
Data-driven detection on the parent's persisted `MAP_STACKED`:
```sql
upper(MAP_MED_TYPE) LIKE 'BEL%'
```
Narrower than the inventory predicate in `lot1_studyteam_qs.R:395-407`
(which also matches `MAP_MED_CLASS LIKE '%BCMA%'` for counting all
BCMA-directed agents). the exclusion is belantamab specifically,
so the class match is dropped to avoid over-excluding BCMA bispecifics
(teclistamab / elranatamab) and BCMA CAR-T (ide-cel / cilta-cel).

Because `MAP_STACKED` only contains agents on the parent's MMA
codelist, `BEL%` within `MAP_STACKED` reliably means belantamab: any
other BEL-prefixed drug is not on the MM codelist and therefore not
in `MAP_STACKED`. The exclusion drops PATIDs with **any** matching
segment regardless of LOT number (matches "in any LOT").

At study lockup belantamab was the only ADC in use for MM. If a
non-belantamab ADC is added to the codelist later, prefer matching
on its specific `MED_ABBR` value (or move to a CSV-backed list).

### No MM oncology therapy in 12-mo pre-LOT1
Scans the **raw** `medical` (`PROC_CD` / `BILL_PROC_CD` / `NDC`) and
`rx` (`NDC`) tables joined to a NDMM-side MMA codelist built from
`cl_mma_codelist.csv` (the same CSV the parent uses for `mma_codelist`
in `S01` / `mm_therapy_codes` in `pipeline_steps.R:67-81`). The
codelist view drops steroid `MED_ABBR` values (DEX / DEXA /
DEXAMETHASONE / PRED / PREDNISONE - same tokens as
`05_regimen_dashboard.R::STEROID_TOKENS`) before any join, so every downstream
scan inherits the steroid exclusion. NDC11 normalisation
(`lpad(...,11,'0')`) is identical to the parent join logic in
`pipeline_steps.R:646-696` and `02_lot1.R:300-388`.

**Why not `MMA_MED_PROCESSED`:** the parent's persisted MMA table is
bounded at `FST_DT >= p.INDEX_DATE` on every source branch
(`02_lot1.R:316`, `:336`, `:359`, `:386`), where `INDEX_DATE` is
the MM-diagnosis qualifying date. That means it cannot see any claim
in the `[LOT1_START - 365, INDEX_DATE - 1]` portion of the 12-month
1L baseline. For an NDMM patient whose LOT1 starts shortly after
MM-dx (the typical case), `INDEX_DATE ~= LOT1_START`, so the visible
window collapses to days/weeks of the intended 12-month one. The NDMM
raw-claim scan covers the full window by joining `LOT1_START_DT` per
PATID and bounding the date range there:

```sql
WHERE cast(m.FST_DT as date)
        BETWEEN date_sub(l1.LOT1_START_DT, 365)
            AND date_sub(l1.LOT1_START_DT, 1)
```

### No other active cancer in 12-mo pre-LOT1
Direct port of parent step 22 (`OTHER_MALIGN_FLAG`,
`pipeline_steps.R:858-947`) but with the date window re-anchored to
`[LOT1_START - 365, LOT1_START - 1]` instead of
`[INDEX_DATE - 183, INDEX_DATE - 1]` and the tumor-group codelist
loaded from `cl_other_malignancies` (default file: `other_malig.csv`,
per `config_prompts.R:76`). Logic preserved verbatim:

- **Path A:** >=1 inpatient claim for a tumor group in baseline.
- **Path B:** >=2 outpatient claims on separate days within 30 days
  for the same tumor group, where the **first** claim falls in the
  baseline window. The paired second claim can land after LOT1 start,
  matching the parent's `op.diff_days <= 30 AND op.first_dt BETWEEN ...`
  predicate at `pipeline_steps.R:935-937`.

IP/OP classification mirrors the parent:
`POS IN ('21','51','61') OR TOS_CD IN ('FAC_IP.ACUTE','FAC_IP.REHSNF','PROF.INPVIS','FAC_IP.SNF') OR CONF_ID IS NOT NULL`
on the 5-column claim grain `(PATID, PAT_PLANID, CLMID, FST_DT, LOC_CD)`.
Both `med_claim_header` and `confinement` are rebuilt NDMM-side with a
wider lower date bound (`NDMM_LOT1_FROM - 365 = 2016-01-01` by default)
so the full pre-LOT1 baseline is visible even for patients whose LOT1
is at the cutoff.

#### NDMM-only MM-adjacent tumor-group override 

For the NDMM other-cancer exclusion only, the highlighted
plasma-cell / MM-adjacent tumor groups are treated as
**non-exclusionary**. Parent pipeline logic and shared codelists are
unchanged. This aligns the NDMM filter with the protocol intent: the
"another cancer" exclusion (study-pop Criterion 7) targets a cancer
*distinct from* the index MM, not the MM disease itself, its precursor,
or MM bone disease. Without this override the filter was dropping ~63%
of NDMM candidates, the large majority for plasma-cell / MM-adjacent
codes (see the dashboard's "Other-cancer override impact" QC card).

The five tumor-group labels treated as non-exclusionary
(`NDMM_MM_ADJACENT_OVERRIDE` in `06_ndmm_dashboard.R`):

```
MONOCLONAL GAMMOPATHY                                    (MGUS, D47.2 - MM precursor)
SECONDARY MALIGNANT NEOPLASM OF BONE                     (C79.5x - MM bone disease)
SOLITARY PLASMACYTOMA NOT HAVING ACHIEVED REMISSION      (C90.3x - plasma cell)
PLASMA CELL LEUKEMIA NOT HAVING ACHIEVED REMISSION       (C90.1x - plasma cell)
EXTRAMEDULLARY PLASMACYTOMA NOT HAVING ACHIEVED REMISSION(C90.2x - plasma cell)
```

Mechanism: `build_ndmm_other_malig_codes()` tags each codelist row with
`is_mm_adjacent_override`; the exclusion scan reads only
`is_mm_adjacent_override = 0` rows, while the QC card scans all rows so
the overridden groups stay auditable. The shared `other_malig.csv` is
not edited — the override is a load-time flag, NDMM-only. On each run the
log prints `NDMM other-cancer override: matched N of 5 expected
MM-adjacent tumor_group labels`; **`N < 5` is a run-review blocker**
(the codelist's stored labels differ from the wording above — inspect
`SELECT DISTINCT tumor_group` on the warehouse and align the list).

> **Footnotes / open items.**
> 1. **Remission variants not included.** Only the five
>    `NOT HAVING ACHIEVED REMISSION` labels named in the spec are overridden.
>    Any `… IN REMISSION` variants of the same diseases remain in the
>    NDMM filter. Confirm if the whole disease family
>    (regardless of remission status) should be non-exclusionary.
> 2. **Bone group is a judgement call.** `SECONDARY MALIGNANT NEOPLASM
>    OF BONE` (C79.5x) can represent true non-MM solid-tumor bone
>    metastasis, not only MM bone disease. The override-impact QC card
>    separates patients re-included on MM-adjacent codes alone from
>    those who also carry a genuine other-cancer signal (who stay
>    excluded), so the relaxation is visible and quantified.

## Running it

```sh
Rscript apr_30_2026/06_ndmm_dashboard.R
```

Same connection environment as the parent pipeline. Required env vars:

| Env var                 | Default                  | Used by                                                  |
| ----------------------- | ------------------------ | -------------------------------------------------------- |
| `DATABRICKS_DSN`        | `RWDE`                   | ODBC connect                                             |
| `DATABRICKS_PWD`        | (required)               | ODBC connect                                             |
| `OUTPUT_DIR`            | `/mnt/artifacts/results` | Dashboard output                                         |
| `TBL_MEMBER_ENROLLMENT` | `member_enrollment`      | NDMM enrollment-span build                                 |
| `GAP_DAYS`              | `30`                     | NDMM CE gap allowance (matches parent `cfg$gap_days`)      |
| `FINAL_TABLE_NAME`      | `ELIG_COH_FINAL`         | Parent IE-flagged cohort table name                      |
| `TBL_CONFINEMENT`       | `confinement`            | NDMM IP/OP classification for other-cancer filter          |
| `NDMM_LOT1_FROM`          | `2017-01-01`             | LOT1 eligible-treatment cutoff (spec: "on/after 01 Jan 2017") |

All cohort-pipeline-equivalent env-var names match the corresponding
`config_prompts.R` keys so a run that already exports them for the
parent picks them up identically here. `NDMM_LOT1_FROM` is NDMM-only.

### Required parent work tables

The script reads (does not write) these persisted parent tables:

- `LOT_LONG`        - LOT derivation per patient
- `ELIG_COH_FINAL`  - parent IE-filtered cohort
- `MAP_STACKED`     - per-medication exposure (belantamab filter)

Plus these raw CDM tables:

- `member_enrollment` (CE span rebuild)
- `medical`           (MM-Tx pre-LOT1 four-source scan, steroid augmentation,
                       other-cancer IP/OP claim-header rebuild)
- `rx`                (MM-Tx pre-LOT1 four-source scan and steroid augmentation)
- `med_diagnosis`     (other-cancer diagnosis scan)
- `confinement`       (other-cancer Optum Approach 2 IP detection)

And these codelist CSVs in `cfg$codelist_dir` (loaded via
`load_codelist_csv()` from `R/codelists_lot.R`):

- `cl_mma_codelist.csv` (MM-Tx pre-LOT1 four-source scan; same CSV
                         the parent uses for `mma_codelist` in `S01`
                         and `mm_therapy_codes` in `pipeline_steps.R:67-81`)
- `other_malig.csv`     (other-cancer tumor-group codelist; same CSV
                         the parent uses for `other_malig_codes` in
                         `pipeline_steps.R:109-122`)

If a required input is unreadable the corresponding filter is
**skipped** rather than aborting the run:

- `MAP_STACKED` missing -> belantamab filter skipped.
- raw `medical`/`rx` missing -> MM-Tx-pre-LOT1 filter skipped (and steroid
  steroid augmentation also degrades to no-op).
- `med_diagnosis`, `medical`, or `confinement` missing -> other-cancer
  pre-LOT1 filter skipped.

Each skip is logged to stdout and surfaced as a note in the OVERVIEW
card; the script still produces a dashboard with the filters that did
apply.

## Output

`ndmm_dashboard.html` written to `OUTPUT_DIR`. Structure
matches `regimen_dashboard.html` (same OVERVIEW, steroid
prevalence card, category-pair Sankeys, focused-regimen Sankeys,
category coverage QC) but every section is computed on the NDMM
cohort. The cohort and the dashboard heading both read as
"NDMM planned cohort".

## Reuse policy

`06_ndmm_dashboard.R` calls `source("../05_regimen_dashboard.R")` with two `options()`
that the parent script honours:

- `regimen_dashboard.no_autorun = TRUE` - skip its `main()` so sourcing
  does not trigger the whole-cohort dashboard.
- `regimen_dashboard.script_dir = .parent_dir` - tell its `.script_dir`
  resolver to look in `apr_30_2026/` for the parent `R/` helpers and
  CSV inputs (otherwise `commandArgs("--file=")` makes it look in
  `apr_30_2026/` and the source fails).

Both options are NULL by default so the standalone
`Rscript apr_30_2026/05_regimen_dashboard.R` invocation is unchanged.

No parent pipeline files are written or modified.

## Known gaps vs the spec

- **MM dx in baseline** (`MM_baseline_diag` in the May 12 spec). The
  spec does not separately call this out; NDMM identification
  rests on the "first MM treatment claim" inclusion criterion. Parent
  `ELIG_COH_FINAL` still applies its own `MM_BASELINE_EVIDENCE` flag
  at the MM-dx anchor; NDMM does not re-derive it at the LOT1 anchor.

This is visible only as an auditability caveat, not a silent failure:
the OVERVIEW card states exactly which filters NDMM applies and the
attrition table reports the cohort size at each step.
