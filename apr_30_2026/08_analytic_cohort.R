#!/usr/bin/env Rscript
# =============================================================================
# 08_analytic_cohort.R  --  materialise the ANALYTIC_COHORT that the
#                           cohort_explorer dashboard reads.
# -----------------------------------------------------------------------------
# *** DRAFT -- UNVALIDATED. NOT RUN IN THIS REPO (no warehouse). Needs a
#     Databricks connection + engineering AND clinical sign-off before use. ***
#
# WHAT IT DOES
#   Turns 06's ROW-FILTER model into the dashboard's FLAG-COLUMN model:
#   06_ndmm_dashboard.R already builds NDMM_FLAGS_ALL -- one row per
#   (ELIG_COH_FINAL x 1L-candidate) patient with the six NDMM IE criteria as
#   0/1 columns (CE_pre_lot1_12mo, CE_lot1_3mo_fu, NO_BELANTAMAB,
#   NO_PRIOR_MM_TX, NO_OTHER_CANCER_PRE_LOT1, NO_PREGNANCY). That IS the
#   "large cohort with flags" the dashboard wants -- flags emitted as columns,
#   nothing dropped. This script REUSES 06's functions verbatim (no IE SQL is
#   re-implemented here) and only PROJECTS the join into the dashboard's
#   published contract (cohort_explorer/R/build_flagged_cohort.R:
#   FLAGGED_COHORT_BASE_COLS + registry_flag_ids), then exports two CSVs the
#   dashboard consumes:
#       COHORT_EXPLORER_DATA     (one row per patient, flags + characteristics)
#       COHORT_EXPLORER_LOTLONG  (one row per patient x LOT_NUM)
#   The dashboard's validate_flagged_cohort() / validate_lot_long() fail closed
#   on any contract breach, so a bad projection is caught before it renders.
#
# CONFIG
#   Driven by the SAME env vars as the rest of apr_30 (STUDY_START/END,
#   NDMM_LOT1_FROM, NDMM_PRE_LOT1_DAYS, ...). Generate them from one
#   study_config with:
#     Rscript cohort_explorer/config/emit_pipeline_env.R pipeline_env.sh
#     source pipeline_env.sh && Rscript apr_30_2026/08_analytic_cohort.R
#
# EXPLICIT ASSUMPTIONS / TODOs (each must be reviewed):
#   [A] Overall IE flags (incl_qualifying_mm/adult/baseline_ce_6m/new_user/
#       fu_mm_agents) are 1 on this base by construction -- ELIG_COH_FINAL has
#       ALREADY applied them as row filters. To make them TOGGLEABLE too, point
#       the base at ELIG_COH_ALLFLAGS (pre-filter) and carry the per-criterion
#       flags it already computes; that is a separate, larger change. Marked [A].
#   [B] Optum demographics beyond GDR_CD/YRDOB (race, region, payer_type,
#       ethnicity) are NOT on ELIG_COH_FINAL -- join them from the Optum member/
#       enrollment tables. Emitted as 'Unknown' placeholders until wired. [B]
#   [C] Time-to-event (OS/TTD/TTNT + events + fu_potential_months) is DERIVED
#       here from LOT dates + DEATH_DT + observation end. This is an ANALYTIC
#       definition that needs clinical sign-off (esp. censoring + TTNT). [C]
#   [D] baseline_ce_months / followup_ce_months (continuous) and the safety-
#       event counts + baseline_py + HCRU counts are NOT produced by 06 --
#       derive from NDMM_ENROLL_SPANS + a claims scan. Placeholders until wired. [D]
#   [E] SOC regimen category uses the same regimen->category lookup 06 loads
#       (load_categories / REGIMEN_MODAL_MAP); confirm the 1L mapping. [E]
# =============================================================================

.script_dir <- local({
  args <- commandArgs(trailingOnly = FALSE)
  fa <- grep("^--file=", args, value = TRUE)
  if (length(fa)) return(dirname(normalizePath(sub("^--file=", "", fa[1]))))
  getwd()
})

# Source 06 WITHOUT running its dashboard (we only want its cohort-prep +
# view-builder functions + cfg). This reuses the validated NDMM flag SQL.
options(ndmm_dashboard.no_autorun = TRUE)
source(file.path(.script_dir, "06_ndmm_dashboard.R"), local = FALSE)

ANALYTIC_COHORT_TBL <- Sys.getenv("ANALYTIC_COHORT_TBL", "ANALYTIC_COHORT")
OUT_DIR <- Sys.getenv("OUTPUT_DIR", file.path(.script_dir, "..", "artifacts"))

main_analytic <- function() {
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")
  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  # 1) reuse 06's cohort prep -> builds NDMM_FLAGS_ALL (+ persisted twin) and
  #    the filtered LOT_LONG. No IE logic is duplicated here.
  prepare_ndmm_cohort(con)

  elig <- wrk(cfg$final_table_name)   # ELIG_COH_FINAL (the Overall superset)
  flags <- NDMM_FLAGS_ALL             # per-PATID NDMM flag view built by 06
  lot  <- NDMM_LOT_LONG_FILT          # LOT_LONG for the 1L-candidate cohort

  # 2) per-patient LOT-derived rollup (1L anchor + line count + 1L length)
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW _ac_lotroll AS
    SELECT cast(PATID as string) AS PATID,
           max(LOT_NUM)                                   AS n_lines,
           max(CASE WHEN LOT_NUM = 1 THEN LOT_START_DT END)  AS lot1_start_dt,
           max(CASE WHEN LOT_NUM = 1 THEN LOT_BASE_LENGTH END) AS lot1_length,
           max(CASE WHEN LOT_NUM = 1 THEN LOT_BASE_MEDS END)   AS lot1_meds
    FROM {lot}
    GROUP BY cast(PATID as string)
  "))

  # 3) ANALYTIC_COHORT projection into the dashboard contract.
  #    Column names on the RIGHT are the dashboard contract; comments tag each
  #    against the assumption list above.
  db_exec(con, glue("
    CREATE OR REPLACE TABLE {wrk(ANALYTIC_COHORT_TBL)} AS
    SELECT
      cast(ec.PATID as string)                       AS patient_id,
      ec.AGE_INDEX_YR                                AS age_index,
      CASE ec.GDR_CD WHEN 'M' THEN 'Male' WHEN 'F' THEN 'Female'
           ELSE 'Unknown' END                        AS gender,
      'Unknown'                                       AS region,        -- [B]
      'Unknown'                                       AS race,          -- [B]
      'Unknown'                                       AS ethnicity,     -- [B]
      'Unknown'                                       AS payer_type,    -- [B]
      cast(ec.INDEX_DATE as date)                     AS index_date,
      lr.lot1_start_dt                                AS lot1_start_dt,
      cast(ec.DEATH_DT as date)                        AS death_dt,
      year(ec.INDEX_DATE)                             AS dx_year,
      year(lr.lot1_start_dt)                          AS lot_init_year,
      round(datediff(lr.lot1_start_dt, ec.INDEX_DATE)/30.44, 1) AS dx_to_1l_months,
      -- [C] OS = time to death, else censor at observation end
      round(datediff(coalesce(ec.DEATH_DT, ec.OBS_END_DT), lr.lot1_start_dt)/30.44,1) AS os_time,
      CASE WHEN ec.DEATH_DT IS NOT NULL
            AND ec.DEATH_DT <= ec.OBS_END_DT THEN 1 ELSE 0 END        AS os_event,
      -- [C] potential (administrative, death-INDEPENDENT) follow-up from 1L
      round(datediff(ec.OBS_END_DT, lr.lot1_start_dt)/30.44,1)        AS fu_potential_months,
      round(datediff(coalesce(ec.DEATH_DT, ec.OBS_END_DT), ec.INDEX_DATE)/30.44,1) AS fu_from_dx_months,
      cast(NULL as double)                            AS baseline_ce_months,  -- [D]
      cast(NULL as double)                            AS followup_ce_months,  -- [D]
      cast(NULL as int)                               AS cci,                 -- [D]
      0 AS bl_hepatic, 0 AS bl_renal, 0 AS bl_infection,                      -- [D]
      0 AS bl_ocular, 0 AS bl_cv, 0 AS bl_neuro,                             -- [D]
      0 AS n_hepatic, 0 AS n_renal, 0 AS n_infection,                        -- [D]
      0 AS n_ocular, 0 AS n_cv, 0 AS n_neuro, 1.0 AS baseline_py,            -- [D]
      0 AS ip_hosp_count, 0 AS er_visit_count, 0.0 AS ip_los_days,           -- [D]
      coalesce(cat.soc_category, 'Other')             AS soc_category,   -- [E]
      lr.n_lines                                      AS n_lines,
      lr.lot1_length                                  AS lot1_length,
      -- [C] TTD (1L discontinuation) from the 1L LOT row's end date
      round(datediff(l1.LOT_BASE_END_DT, lr.lot1_start_dt)/30.44,1)   AS ttd_time,
      CASE WHEN l1.LOT_BASE_END_REASON IS NOT NULL
            AND upper(l1.LOT_BASE_END_REASON) NOT LIKE '%STUDY_END%'
            AND upper(l1.LOT_BASE_END_REASON) NOT LIKE '%DISENROLL%'
           THEN 1 ELSE 0 END                          AS ttd_event,
      -- [C] TTNT = start of LOT2 (or death) from 1L start
      round(datediff(coalesce(l2.LOT_START_DT, ec.DEATH_DT, ec.OBS_END_DT),
                     lr.lot1_start_dt)/30.44,1)        AS ttnt_time,
      CASE WHEN lr.n_lines > 1 THEN 1 ELSE 0 END      AS ttnt_event,
      -- [C] PFS is EXPLORATORY only (protocol: not ascertainable) -- proxy = TTD
      round(datediff(l1.LOT_BASE_END_DT, lr.lot1_start_dt)/30.44,1)   AS pfs_time,
      CASE WHEN l1.LOT_BASE_END_REASON IS NOT NULL THEN 1 ELSE 0 END  AS pfs_event,
      -- ===== NDMM IE flags (from 06's NDMM_FLAGS_ALL -- verbatim) =====
      coalesce(f.CE_pre_lot1_12mo, 0)                 AS incl_baseline_ce_12m,
      coalesce(f.CE_lot1_3mo_fu, 0)                   AS incl_fu_ce_3m,
      coalesce(f.NO_PRIOR_MM_TX, 0)                   AS excl_prior_mm_tx,
      coalesce(f.NO_OTHER_CANCER_PRE_LOT1, 0)         AS excl_other_cancer,
      coalesce(f.NO_BELANTAMAB, 0)                    AS excl_belantamab,
      coalesce(f.NO_PREGNANCY, 0)                     AS excl_pregnancy,
      -- ===== Overall IE flags: 1 by construction on ELIG_COH_FINAL [A] =====
      1 AS incl_qualifying_mm, 1 AS incl_adult, 1 AS incl_baseline_ce_6m,
      1 AS incl_new_user, 1 AS incl_fu_mm_agents,
      -- eligible-1L>=2017 is a real, movable date fact:
      CASE WHEN lr.lot1_start_dt >= date('{NDMM_LOT1_FROM}') THEN 1 ELSE 0 END
                                                      AS incl_eligible_1l_tx
    FROM {elig} ec
    INNER JOIN _ac_lotroll lr ON cast(ec.PATID as string) = lr.PATID
    LEFT JOIN {flags} f      ON cast(ec.PATID as string) = f.PATID
    LEFT JOIN {lot} l1       ON cast(ec.PATID as string) = cast(l1.PATID as string) AND l1.LOT_NUM = 1
    LEFT JOIN {lot} l2       ON cast(ec.PATID as string) = cast(l2.PATID as string) AND l2.LOT_NUM = 2
    LEFT JOIN _ac_socmap cat ON cast(ec.PATID as string) = cat.PATID   -- [E] build _ac_socmap from load_categories()/REGIMEN_MODAL_MAP
  "))

  # 4) LOT-long export (one row per patient x line) for the per-LOT / regimen /
  #    pathway views. Per-line TTE is derived [C]; SOC per line via the lookup [E].
  db_exec(con, glue("
    CREATE OR REPLACE TABLE {wrk('ANALYTIC_LOT_LONG')} AS
    SELECT cast(ll.PATID as string) AS patient_id, ll.LOT_NUM AS lot_num,
           cast(ll.LOT_START_DT as date) AS lot_start_dt,
           coalesce(cat.soc_category, 'Other') AS lot_soc,            -- [E]
           'Unknown' AS payer_type,                                    -- [B]
           round(datediff(coalesce(ec.DEATH_DT, ec.OBS_END_DT), ll.LOT_START_DT)/30.44,1) AS os_time,
           CASE WHEN ec.DEATH_DT IS NOT NULL AND ec.DEATH_DT <= ec.OBS_END_DT THEN 1 ELSE 0 END AS os_event,
           round(datediff(ll.LOT_BASE_END_DT, ll.LOT_START_DT)/30.44,1) AS ttd_time,
           CASE WHEN ll.LOT_BASE_END_REASON IS NOT NULL THEN 1 ELSE 0 END AS ttd_event,
           round(datediff(coalesce(nx.LOT_START_DT, ec.DEATH_DT, ec.OBS_END_DT), ll.LOT_START_DT)/30.44,1) AS ttnt_time,
           CASE WHEN nx.LOT_START_DT IS NOT NULL THEN 1 ELSE 0 END AS ttnt_event,
           round(datediff(ec.OBS_END_DT, ll.LOT_START_DT)/30.44,1) AS fu_potential_months
    FROM {lot} ll
    INNER JOIN {elig} ec ON cast(ll.PATID as string) = cast(ec.PATID as string)
    LEFT JOIN {lot} nx   ON cast(ll.PATID as string) = cast(nx.PATID as string) AND nx.LOT_NUM = ll.LOT_NUM + 1
    LEFT JOIN _ac_socmap cat ON cast(ll.PATID as string) = cat.PATID   -- [E] (per-line SOC: extend the map to all lines)
  "))

  # 5) export both to CSV for the dashboard (COHORT_EXPLORER_DATA / LOTLONG)
  if (!dir.exists(OUT_DIR)) dir.create(OUT_DIR, recursive = TRUE)
  ac <- db_q(con, glue("SELECT * FROM {wrk(ANALYTIC_COHORT_TBL)}"))
  ll <- db_q(con, glue("SELECT * FROM {wrk('ANALYTIC_LOT_LONG')}"))
  ac_path <- file.path(OUT_DIR, "analytic_cohort.csv")
  ll_path <- file.path(OUT_DIR, "analytic_lot_long.csv")
  write.csv(ac, ac_path, row.names = FALSE)
  write.csv(ll, ll_path, row.names = FALSE)
  log_msg("Wrote ", nrow(ac), " analytic-cohort rows -> ", ac_path)
  log_msg("Wrote ", nrow(ll), " LOT-long rows -> ", ll_path)
  log_msg("Point the dashboard at them:")
  log_msg("  COHORT_EXPLORER_DATA=", ac_path,
          " COHORT_EXPLORER_LOTLONG=", ll_path,
          " R -e 'shiny::runApp(\"cohort_explorer\")'")
  invisible(list(analytic = ac_path, lot_long = ll_path))
}

if (!interactive() && !isTRUE(getOption("analytic_cohort.no_autorun"))) main_analytic()
