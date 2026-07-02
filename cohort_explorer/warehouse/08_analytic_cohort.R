#!/usr/bin/env Rscript
# =============================================================================
# 08_analytic_cohort.R  --  materialise the ANALYTIC_COHORT the dashboard reads.
# -----------------------------------------------------------------------------
# *** DRAFT / SKELETON -- UNVALIDATED. NOT RUN IN THIS REPO (no warehouse).
#     Refuses to run unless ANALYTIC_COHORT_ALLOW_PLACEHOLDER=TRUE (guard below)
#     because the [B]-[E] real-data derivations are not yet wired. Needs a
#     warehouse connection + engineering AND clinical sign-off. ***
#
# DESIGN (decoupled from the upstream pipeline -- it modifies NOTHING there):
#   It does NOT source or edit any upstream pipeline code. It READS the PERSISTED
#   tables that a prior pipeline run already wrote to the work schema:
#     ELIG_COH_FINAL   (cohort build)     -- the Overall Step-6 superset
#     LOT_LONG         (LOT build)        -- broad, unfiltered (NOT the filtered NDMM LOT-long)
#     NDMM_FLAGS_ALL   (NDMM flag build)  -- the 6 NDMM IE criteria as 0/1 columns
#   PRECONDITION: run the upstream LOT pipeline + NDMM flag build first (they persist those tables).
#   This turns the NDMM build's ROW-FILTER model into the dashboard's FLAG-COLUMN model by
#   PROJECTING the join into the dashboard contract (FLAGGED_COHORT_BASE_COLS +
#   registry_flag_ids), then exporting two CSVs:
#     COHORT_EXPLORER_DATA (patient-level) / COHORT_EXPLORER_LOTLONG (per line).
#   validate_flagged_cohort()/validate_lot_long() fail closed on any breach.
#
# CONFIG (env vars; generate from one study_config via ../config/emit_pipeline_env.R):
#   Datasource (DSN/PWD/CATALOG/SCHEMA) is defined in ONE place:
#     ../config/warehouse_config.R  (WAREHOUSE_DSN / WAREHOUSE_PWD /
#     WAREHOUSE_CATALOG / PROJECT_WORK_SCHEMA)
#   Study/output: STUDY_END / NDMM_LOT1_FROM / OUTPUT_DIR
#
# ASSUMPTIONS / TODOs (each must be reviewed):
#   [A] Overall IE flags are 1 on the ELIG_COH_FINAL base (already row-filtered);
#       to make them TOGGLEABLE, read a pre-filter ELIG_COH_ALLFLAGS base instead.
#   [B] race/region/payer/ethnicity are NOT on ELIG_COH_FINAL -> join the source
#       member/enrollment tables. 'Unknown' placeholders until wired.
#   [C] OS/TTD/TTNT + fu_potential are DERIVED -> clinical sign-off (censoring, TTNT).
#   [D] continuous CE months, safety counts + PY, HCRU -> derive from spans + claims.
#   [E] SOC category uses a PLACEHOLDER start-type/med-count rule -> replace with
#       the authoritative regimen_categories map.
# =============================================================================

suppressWarnings(suppressMessages({ ok_dbi <- requireNamespace("DBI", quietly = TRUE) }))

.autorun <- !interactive() && !isTRUE(getOption("analytic_cohort.no_autorun"))
if (.autorun && toupper(Sys.getenv("ANALYTIC_COHORT_ALLOW_PLACEHOLDER", "")) != "TRUE")
  stop("08_analytic_cohort.R is a SKELETON: the [B]-[E] real-data derivations ",
       "(demographics/payer, CCI, continuous CE, safety, HCRU, production SOC map) ",
       "are not yet wired. Set ANALYTIC_COHORT_ALLOW_PLACEHOLDER=TRUE to emit a ",
       "contract-valid PLACEHOLDER cohort for wiring/validation tests only.",
       call. = FALSE)

.script_dir <- local({
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(fa)) dirname(normalizePath(sub("^--file=", "", fa[1]))) else getwd()
})

# Datasource connection comes from the ONE shared config file (../config/
# warehouse_config.R); study/output params stay local to this job.
source(file.path(.script_dir, "..", "config", "warehouse_config.R"))
.wcfg <- warehouse_config()
cfg <- list(
  dsn         = .wcfg$dsn,
  pwd         = .wcfg$pwd,
  catalog     = .wcfg$catalog,
  work_schema = .wcfg$schema,
  study_end   = Sys.getenv("STUDY_END", "2025-06-30"),
  lot1_from   = Sys.getenv("NDMM_LOT1_FROM", "2017-01-01"),
  out_dir     = Sys.getenv("OUTPUT_DIR", file.path(.script_dir, "artifacts")))

fq <- function(t) sprintf("`%s`.`%s`.`%s`", cfg$catalog, cfg$work_schema, t)

main_analytic <- function() {
  if (!ok_dbi) stop("DBI/odbc required (warehouse run).", call. = FALSE)
  if (!nzchar(cfg$pwd)) stop("WAREHOUSE_PWD not set.", call. = FALSE)
  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)
  db_exec <- function(sql) DBI::dbExecute(con, sql)
  db_q    <- function(sql) DBI::dbGetQuery(con, sql)
  g <- function(sql) glue::glue(sql, .envir = parent.frame())

  elig <- fq("ELIG_COH_FINAL"); lot <- fq("LOT_LONG"); flags <- fq("NDMM_FLAGS_ALL")

  # per-patient LOT rollup (1L anchor + line count) over the FULL Overall pop.
  db_exec(g("
    CREATE OR REPLACE TEMPORARY VIEW _ac_lotroll AS
    SELECT cast(PATID as string) AS PATID,
           max(LOT_NUM) AS n_lines,
           max(CASE WHEN LOT_NUM=1 THEN LOT_START_DT END)   AS lot1_start_dt,
           max(CASE WHEN LOT_NUM=1 THEN LOT_BASE_LENGTH END) AS lot1_length
    FROM {lot} GROUP BY cast(PATID as string)"))

  # SOC map per (PATID, LOT_NUM). [E] PLACEHOLDER rule (production: regimen map).
  db_exec(g("
    CREATE OR REPLACE TEMPORARY VIEW _ac_socmap AS
    SELECT cast(PATID as string) AS PATID, LOT_NUM AS lot_num,
      CASE WHEN upper(coalesce(LOT_START_TYPE,'')) LIKE 'CART%' THEN 'CAR-T'
           WHEN upper(coalesce(LOT_START_TYPE,'')) LIKE 'SCT%'  THEN 'Transplant'
           WHEN size(split(trim(coalesce(LOT_BASE_MEDS,'')),' '))>=4 THEN 'Quadruplet'
           WHEN size(split(trim(coalesce(LOT_BASE_MEDS,'')),' '))=3 THEN 'Triplet'
           WHEN size(split(trim(coalesce(LOT_BASE_MEDS,'')),' '))=2 THEN 'Doublet'
           WHEN length(trim(coalesce(LOT_BASE_MEDS,'')))>0 THEN 'Monotherapy'
           ELSE 'Other' END AS soc_category
    FROM {lot}"))

  # ANALYTIC_COHORT projection into the dashboard contract.
  #   ENDDATE = min(death, study_end) is the real ELIG_COH_FINAL column (there is
  #   NO OBS_END_DT here). Endpoint dates are capped at ENDDATE (least(...)) so no
  #   time exceeds follow-up; fu_potential is the DEATH-INDEPENDENT study-end
  #   horizon so early deaths survive the >=N-mo TTE filter [C/D]. Censoring
  #   reasons (STUDY_END/DISENROLL) are NOT events [C].
  db_exec(g("
    CREATE OR REPLACE TABLE {fq('ANALYTIC_COHORT')} AS
    SELECT cast(ec.PATID as string) AS patient_id, ec.AGE_INDEX_YR AS age_index,
      CASE ec.GDR_CD WHEN 'M' THEN 'Male' WHEN 'F' THEN 'Female' ELSE 'Unknown' END AS gender,
      'Unknown' AS region, 'Unknown' AS race, 'Unknown' AS ethnicity, 'Unknown' AS payer_type,  -- [B]
      cast(ec.INDEX_DATE as date) AS index_date, lr.lot1_start_dt AS lot1_start_dt,
      cast(ec.DEATH_DT as date) AS death_dt, year(ec.INDEX_DATE) AS dx_year,
      year(lr.lot1_start_dt) AS lot_init_year,
      round(datediff(lr.lot1_start_dt, ec.INDEX_DATE)/30.44,1) AS dx_to_1l_months,
      round(datediff(least(coalesce(ec.DEATH_DT, cast(ec.ENDDATE as date)), cast(ec.ENDDATE as date)), lr.lot1_start_dt)/30.44,1) AS os_time,
      CASE WHEN ec.DEATH_DT IS NOT NULL AND ec.DEATH_DT <= cast(ec.ENDDATE as date) THEN 1 ELSE 0 END AS os_event,
      round(datediff(date('{cfg$study_end}'), lr.lot1_start_dt)/30.44,1) AS fu_potential_months,  -- [C/D] death-INDEPENDENT
      round(datediff(least(coalesce(ec.DEATH_DT, cast(ec.ENDDATE as date)), cast(ec.ENDDATE as date)), ec.INDEX_DATE)/30.44,1) AS fu_from_dx_months,
      CASE WHEN coalesce(f.CE_pre_lot1_12mo,0)=1 THEN 12.0 ELSE 6.0 END AS baseline_ce_months,  -- [D] flag-derived proxy
      CASE WHEN coalesce(f.CE_lot1_3mo_fu,0)=1  THEN 3.0  ELSE 1.0 END AS followup_ce_months,   -- [D]
      cast(0 as int) AS cci,                                                                      -- [D] TODO Charlson
      0 AS bl_hepatic,0 AS bl_renal,0 AS bl_infection,0 AS bl_ocular,0 AS bl_cv,0 AS bl_neuro,   -- [D]
      0 AS n_hepatic,0 AS n_renal,0 AS n_infection,0 AS n_ocular,0 AS n_cv,0 AS n_neuro,1.0 AS baseline_py,  -- [D]
      0 AS ip_hosp_count,0 AS er_visit_count,0.0 AS ip_los_days,                                 -- [D]
      coalesce(cat.soc_category,'Other') AS soc_category, lr.n_lines AS n_lines, lr.lot1_length AS lot1_length,
      round(datediff(least(coalesce(l1.LOT_BASE_END_DT, cast(ec.ENDDATE as date)), cast(ec.ENDDATE as date)), lr.lot1_start_dt)/30.44,1) AS ttd_time,
      CASE WHEN l1.LOT_BASE_END_REASON IS NOT NULL
            AND upper(l1.LOT_BASE_END_REASON) NOT LIKE '%STUDY_END%'
            AND upper(l1.LOT_BASE_END_REASON) NOT LIKE '%DISENROLL%' THEN 1 ELSE 0 END AS ttd_event,
      round(datediff(least(coalesce(l2.LOT_START_DT, ec.DEATH_DT, cast(ec.ENDDATE as date)), cast(ec.ENDDATE as date)), lr.lot1_start_dt)/30.44,1) AS ttnt_time,
      CASE WHEN lr.n_lines>1 THEN 1 ELSE 0 END AS ttnt_event,
      round(datediff(least(coalesce(l1.LOT_BASE_END_DT, cast(ec.ENDDATE as date)), cast(ec.ENDDATE as date)), lr.lot1_start_dt)/30.44,1) AS pfs_time,  -- exploratory
      CASE WHEN l1.LOT_BASE_END_REASON IS NOT NULL
            AND upper(l1.LOT_BASE_END_REASON) NOT LIKE '%STUDY_END%'
            AND upper(l1.LOT_BASE_END_REASON) NOT LIKE '%DISENROLL%' THEN 1 ELSE 0 END AS pfs_event,
      coalesce(f.CE_pre_lot1_12mo,0) AS incl_baseline_ce_12m, coalesce(f.CE_lot1_3mo_fu,0) AS incl_fu_ce_3m,
      coalesce(f.NO_PRIOR_MM_TX,0) AS excl_prior_mm_tx, coalesce(f.NO_OTHER_CANCER_PRE_LOT1,0) AS excl_other_cancer,
      coalesce(f.NO_BELANTAMAB,0) AS excl_belantamab, coalesce(f.NO_PREGNANCY,0) AS excl_pregnancy,
      1 AS incl_qualifying_mm,1 AS incl_adult,1 AS incl_baseline_ce_6m,1 AS incl_new_user,1 AS incl_fu_mm_agents,  -- [A]
      CASE WHEN lr.lot1_start_dt >= date('{cfg$lot1_from}') THEN 1 ELSE 0 END AS incl_eligible_1l_tx
    FROM {elig} ec
    INNER JOIN _ac_lotroll lr ON cast(ec.PATID as string)=lr.PATID
    LEFT JOIN {flags} f ON cast(ec.PATID as string)=f.PATID
    LEFT JOIN {lot} l1 ON cast(ec.PATID as string)=cast(l1.PATID as string) AND l1.LOT_NUM=1
    LEFT JOIN {lot} l2 ON cast(ec.PATID as string)=cast(l2.PATID as string) AND l2.LOT_NUM=2
    LEFT JOIN _ac_socmap cat ON cast(ec.PATID as string)=cat.PATID AND cat.lot_num=1"))

  db_exec(g("
    CREATE OR REPLACE TABLE {fq('ANALYTIC_LOT_LONG')} AS
    SELECT cast(ll.PATID as string) AS patient_id, ll.LOT_NUM AS lot_num,
      cast(ll.LOT_START_DT as date) AS lot_start_dt, coalesce(cat.soc_category,'Other') AS lot_soc,
      nxc.soc_category AS next_soc, 'Unknown' AS payer_type,   -- [B]
      round(datediff(least(coalesce(ec.DEATH_DT, cast(ec.ENDDATE as date)), cast(ec.ENDDATE as date)), ll.LOT_START_DT)/30.44,1) AS os_time,
      CASE WHEN ec.DEATH_DT IS NOT NULL AND ec.DEATH_DT <= cast(ec.ENDDATE as date) THEN 1 ELSE 0 END AS os_event,
      round(datediff(least(coalesce(ll.LOT_BASE_END_DT, cast(ec.ENDDATE as date)), cast(ec.ENDDATE as date)), ll.LOT_START_DT)/30.44,1) AS ttd_time,
      CASE WHEN ll.LOT_BASE_END_REASON IS NOT NULL
            AND upper(ll.LOT_BASE_END_REASON) NOT LIKE '%STUDY_END%'
            AND upper(ll.LOT_BASE_END_REASON) NOT LIKE '%DISENROLL%' THEN 1 ELSE 0 END AS ttd_event,
      round(datediff(least(coalesce(nx.LOT_START_DT, ec.DEATH_DT, cast(ec.ENDDATE as date)), cast(ec.ENDDATE as date)), ll.LOT_START_DT)/30.44,1) AS ttnt_time,
      CASE WHEN nx.LOT_START_DT IS NOT NULL THEN 1 ELSE 0 END AS ttnt_event,
      round(datediff(date('{cfg$study_end}'), ll.LOT_START_DT)/30.44,1) AS fu_potential_months  -- [C/D] death-INDEPENDENT
    FROM {lot} ll
    INNER JOIN {elig} ec ON cast(ll.PATID as string)=cast(ec.PATID as string)
    LEFT JOIN {lot} nx  ON cast(ll.PATID as string)=cast(nx.PATID as string) AND nx.LOT_NUM=ll.LOT_NUM+1
    LEFT JOIN _ac_socmap cat ON cast(ll.PATID as string)=cat.PATID AND cat.lot_num=ll.LOT_NUM
    LEFT JOIN _ac_socmap nxc ON cast(ll.PATID as string)=nxc.PATID AND nxc.lot_num=ll.LOT_NUM+1"))

  if (!dir.exists(cfg$out_dir)) dir.create(cfg$out_dir, recursive = TRUE)
  ac <- db_q(g("SELECT * FROM {fq('ANALYTIC_COHORT')}"))
  ll <- db_q(g("SELECT * FROM {fq('ANALYTIC_LOT_LONG')}"))
  ap <- file.path(cfg$out_dir, "analytic_cohort.csv")
  lp <- file.path(cfg$out_dir, "analytic_lot_long.csv")
  write.csv(ac, ap, row.names = FALSE); write.csv(ll, lp, row.names = FALSE)
  message(sprintf("Wrote %d cohort rows -> %s", nrow(ac), ap))
  message(sprintf("Wrote %d LOT-long rows -> %s", nrow(ll), lp))
  message(sprintf("Point the dashboard at them:\n  COHORT_EXPLORER_DATA=%s COHORT_EXPLORER_LOTLONG=%s", ap, lp))
  invisible(list(analytic = ap, lot_long = lp))
}

if (.autorun) main_analytic()
