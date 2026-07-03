#!/usr/bin/env Rscript
# =============================================================================
# make_analytic_csv.R  --  build the two dashboard CSVs from the persisted
# warehouse tables (project-local adapter; see warehouse/08_analytic_cohort.R
# for the generic, source-agnostic version).
#
#   analytic_cohort.csv    (patient level, 57-col contract)
#   analytic_lot_long.csv  (per line, 13-col contract)
#
# Datasource config follows the SAME contract as config/warehouse_config.R:
#   WAREHOUSE_DSN / WAREHOUSE_PWD / WAREHOUSE_CATALOG / PROJECT_WORK_SCHEMA
# (this project: WAREHOUSE_CATALOG=hive_metastore PROJECT_WORK_SCHEMA=<your schema>)
#
#   export WAREHOUSE_PWD='<token>'; export WAREHOUSE_CATALOG=hive_metastore
#   export PROJECT_WORK_SCHEMA=<your schema>; export OUT_DIR=/tmp/cohort_data
#   Rscript make_analytic_csv.R
#
# Follow-up model (administrative, death-INDEPENDENT): the per-patient horizon is
# ENDDATE_CE (index->min(study end, disenrollment)). Only LOT lines that START
# on/before that horizon are "observable"; later lines are censored, NOT used to
# stretch follow-up. Observable lines are renumbered 1..n (contiguous), so the
# LOT-long line count == patient-level n_lines and the 1L row in LOT-long IS the
# patient-level 1L outcome (no divergence).
#
# REAL: cohort, gender, age, all 12 IE flags, LOT structure, SOC category,
#       OS/TTD/TTNT (administrative-horizon censored).
# PLACEHOLDER (no source table -> not protocol output): race/region/payer/
#       ethnicity='Unknown', cci=0, safety flags/counts=0, HCRU=0, baseline_py=1.
# =============================================================================

library(DBI)

# ---- datasource config: prefer warehouse_config.R, else same env contract ----
cfg <- local({
  d <- Sys.getenv("COHORT_EXPLORER_DIR", "")
  wf <- if (nzchar(d)) file.path(d, "config", "warehouse_config.R") else ""
  if (nzchar(wf) && file.exists(wf)) { source(wf, local = TRUE); return(warehouse_config()) }
  list(dsn     = Sys.getenv("WAREHOUSE_DSN", "RWDE"),
       pwd     = Sys.getenv("WAREHOUSE_PWD", ""),
       catalog = Sys.getenv("WAREHOUSE_CATALOG", "main"),
       schema  = Sys.getenv("PROJECT_WORK_SCHEMA",
                            Sys.getenv("DOMINO_USER_NAME", "mm_lot_work")))
})
out_dir   <- Sys.getenv("OUT_DIR", "/tmp/cohort_data")
lot1_from <- Sys.getenv("NDMM_LOT1_FROM", "2017-01-01")
if (!nzchar(cfg$pwd)) stop("Set WAREHOUSE_PWD (your databricks token).", call. = FALSE)
if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)

q <- function(t) sprintf("`%s`.`%s`.`%s`", cfg$catalog, cfg$schema, t)
T_lot <- q("lot_long"); T_elig <- q("elig_coh_final"); T_lb <- q("lot1_base_end"); T_flags <- q("ndmm_flags_all")

con <- dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
on.exit(try(dbDisconnect(con), silent = TRUE), add = TRUE)
message(sprintf("Connected (%s.%s). Querying (no temp views) ...", cfg$catalog, cfg$schema))

SOC_CASE <- "
    CASE
      WHEN coalesce(LOT_CART_LOT_FLG,0)=1 THEN 'CAR-T'
      WHEN coalesce(LOT_ALLO_LOT_FLG,0)=1 THEN 'Transplant'
      WHEN coalesce(LOT_MED_CNT,0)>=4 AND coalesce(LOT_CLASS_ACD38,0)=1 THEN 'Quadruplet with anti-CD38 backbone'
      WHEN coalesce(LOT_MED_CNT,0)=3  AND coalesce(LOT_CLASS_ACD38,0)=1 THEN 'Triplet with anti-CD38 backbone'
      WHEN coalesce(LOT_MED_CNT,0)=3 THEN 'Other triplet (non-anti-CD38)'
      WHEN coalesce(LOT_MED_CNT,0)=2 THEN 'Doublet'
      WHEN coalesce(LOT_MED_CNT,0)=1 THEN 'Monotherapy'
      ELSE 'Other' END"

# ---- LOT-LONG (13 cols): observable lines only, renumbered 1..n, administrative
#      horizon = ENDDATE_CE. This is the single source of truth for per-line +
#      1L outcomes + n_lines. -----------------------------------------------------
sql_ll <- paste0("
WITH soc AS (SELECT cast(PATID as string) AS PATID, LOT_NUM,", SOC_CASE, " AS soc_category FROM ", T_lot, "),
obs AS (
  SELECT cast(ll.PATID as string) AS patient_id,
         row_number() OVER (PARTITION BY cast(ll.PATID as string) ORDER BY ll.LOT_NUM, ll.LOT_START_DT) AS lot_num,
         cast(ll.LOT_START_DT as date)    AS lot_start_dt,
         cast(ll.LOT_BASE_END_DT as date) AS lot_base_end_dt,
         ll.LOT_BASE_END_REASON           AS end_reason,
         coalesce(s.soc_category,'Other') AS lot_soc,
         cast(ec.DEATH_DT as date)        AS death_dt,
         cast(ec.ENDDATE_CE as date)      AS ce_end
  FROM ", T_lot, " ll
  INNER JOIN ", T_elig, " ec ON cast(ll.PATID as string)=cast(ec.PATID as string)
  LEFT  JOIN soc s ON cast(ll.PATID as string)=s.PATID AND s.LOT_NUM = ll.LOT_NUM
  WHERE ll.LOT_START_DT <= cast(ec.ENDDATE_CE as date)           -- observable within administrative follow-up
),
w AS (
  SELECT o.*,
         lead(lot_soc)       OVER (PARTITION BY patient_id ORDER BY lot_num) AS next_soc,
         lead(lot_start_dt)  OVER (PARTITION BY patient_id ORDER BY lot_num) AS next_start
  FROM obs o
)
SELECT patient_id, lot_num, lot_start_dt, lot_soc, next_soc, 'Unknown' AS payer_type,
  greatest(0, round(datediff(least(coalesce(death_dt, ce_end), ce_end), lot_start_dt)/30.44,1)) AS os_time,
  CASE WHEN death_dt IS NOT NULL AND death_dt <= ce_end THEN 1 ELSE 0 END AS os_event,
  greatest(0, round(datediff(least(coalesce(lot_base_end_dt, ce_end), ce_end), lot_start_dt)/30.44,1)) AS ttd_time,
  CASE WHEN lot_base_end_dt IS NOT NULL AND lot_base_end_dt <= ce_end
        AND upper(coalesce(end_reason,'')) NOT LIKE '%STUDY%'
        AND upper(coalesce(end_reason,'')) NOT LIKE '%DISENROLL%' THEN 1 ELSE 0 END AS ttd_event,
  greatest(0, round(datediff(coalesce(next_start, ce_end), lot_start_dt)/30.44,1)) AS ttnt_time,
  CASE WHEN next_start IS NOT NULL THEN 1 ELSE 0 END AS ttnt_event,
  greatest(0, round(datediff(ce_end, lot_start_dt)/30.44,1)) AS fu_potential_months
FROM w")

message("Querying per-line LOT-long ...")
ll <- dbGetQuery(con, sql_ll)
message(sprintf("  LOT-long rows: %s", format(nrow(ll), big.mark=",")))

# ---- PATIENT-LEVEL base (demographics, CE, flags, 1L anchor). TTE / n_lines /
#      soc_category are joined from the LOT-long 1L row below, NOT re-derived. ----
sql_pat <- paste0("
SELECT
  cast(ec.PATID as string) AS patient_id, ec.AGE_INDEX_YR AS age_index,
  CASE upper(ec.GDR_CD) WHEN 'M' THEN 'Male' WHEN 'F' THEN 'Female' ELSE 'Unknown' END AS gender,
  'Unknown' AS region, 'Unknown' AS race, 'Unknown' AS ethnicity, 'Unknown' AS payer_type,
  cast(ec.INDEX_DATE as date) AS index_date, cast(lb.LOT1_START_DT as date) AS lot1_start_dt,
  cast(ec.DEATH_DT as date) AS death_dt, coalesce(ec.INDEX_YR, year(ec.INDEX_DATE)) AS dx_year,
  year(lb.LOT1_START_DT) AS lot_init_year,
  round(datediff(lb.LOT1_START_DT, ec.INDEX_DATE)/30.44,1) AS dx_to_1l_months,
  round(coalesce(ec.FU_DAYS, datediff(ec.ENDDATE, ec.INDEX_DATE))/30.44,1) AS fu_from_dx_months,
  greatest(0, round(datediff(ec.INDEX_DATE, cast(ec.baseline_start as date))/30.44,1)) AS baseline_ce_months,
  greatest(0, round(datediff(cast(ec.ENDDATE_CE as date), ec.INDEX_DATE)/30.44,1)) AS followup_ce_months,
  cast(0 as int) AS cci,
  0 AS bl_hepatic,0 AS bl_renal,0 AS bl_infection,0 AS bl_ocular,0 AS bl_cv,0 AS bl_neuro,
  0 AS n_hepatic,0 AS n_renal,0 AS n_infection,0 AS n_ocular,0 AS n_cv,0 AS n_neuro,
  1.0 AS baseline_py, 0 AS ip_hosp_count, 0 AS er_visit_count, 0.0 AS ip_los_days,
  greatest(1, coalesce(lb.LOT1_BASE_LENGTH,1)) AS lot1_length,
  CASE WHEN coalesce(ec.inpt_qual,0)=1 OR coalesce(ec.outpt_qual,0)=1 THEN 1 ELSE 0 END AS incl_qualifying_mm,
  CASE WHEN lb.LOT1_START_DT >= date('", lot1_from, "') THEN 1 ELSE 0 END AS incl_eligible_1l_tx,
  CASE WHEN ec.AGE_INDEX_YR >= 18 THEN 1 ELSE 0 END AS incl_adult,
  greatest(coalesce(ec.CE_b,0), coalesce(f.CE_pre_lot1_12mo,0)) AS incl_baseline_ce_6m,
  coalesce(f.CE_pre_lot1_12mo,0) AS incl_baseline_ce_12m,
  coalesce(f.CE_lot1_3mo_fu, ec.CE_3mosf, 0) AS incl_fu_ce_3m,
  CASE WHEN coalesce(ec.MM_bl_agents,0)=0 THEN 1 ELSE 0 END AS incl_new_user,
  CASE WHEN coalesce(ec.MM_FU_agents,0)>=1 THEN 1 ELSE 0 END AS incl_fu_mm_agents,
  coalesce(f.NO_PRIOR_MM_TX,0) AS excl_prior_mm_tx,
  coalesce(f.NO_OTHER_CANCER_PRE_LOT1, 1 - coalesce(ec.OTHER_MALIGN_FLAG,0)) AS excl_other_cancer,
  coalesce(f.NO_BELANTAMAB,0) AS excl_belantamab,
  coalesce(f.NO_PREGNANCY, 1 - coalesce(ec.PREGNANT_FLAG,0)) AS excl_pregnancy
FROM ", T_elig, " ec
INNER JOIN ", T_lb, " lb ON cast(ec.PATID as string)=cast(lb.PATID as string)
LEFT  JOIN ", T_flags, " f ON cast(ec.PATID as string)=cast(f.PATID as string)")

message("Querying patient-level base ...")
pat <- dbGetQuery(con, sql_pat)
pat <- pat[!duplicated(pat$patient_id), , drop = FALSE]      # guard elig_coh_final rn duplicates
message(sprintf("  patient-level rows: %s", format(nrow(pat), big.mark=",")))

# ---- derive LOT summary from ll (single source of truth -> guaranteed consistent)
n_lines <- as.data.frame(table(patient_id = as.character(ll$patient_id)),
                         stringsAsFactors = FALSE); names(n_lines)[2] <- "n_lines"
ll1 <- ll[ll$lot_num == 1L, , drop = FALSE]                  # the 1L outcome row per patient
ll1 <- ll1[!duplicated(ll1$patient_id), , drop = FALSE]

pat <- merge(pat, n_lines, by = "patient_id", all.x = TRUE, sort = FALSE)
pat$n_lines[is.na(pat$n_lines)] <- 1L
one <- ll1[, c("patient_id","lot_soc","os_time","os_event","ttd_time","ttd_event",
               "ttnt_time","ttnt_event","fu_potential_months")]
names(one)[names(one) == "lot_soc"] <- "soc_category"
pat <- merge(pat, one, by = "patient_id", all.x = TRUE, sort = FALSE)
pat$pfs_time  <- pat$ttd_time                                # PFS exploratory = TTD proxy
pat$pfs_event <- pat$ttd_event

# keep only patients with a 1L observable row (they anchor the cohort)
pat <- pat[!is.na(pat$soc_category), , drop = FALSE]
ll  <- ll[as.character(ll$patient_id) %in% as.character(pat$patient_id), , drop = FALSE]

# ---- assemble the 57-col contract in order --------------------------------------
suppressWarnings(source(file.path(Sys.getenv("COHORT_EXPLORER_DIR",""), "R", "criteria_registry.R"),
                        local = TRUE))
base_cols <- c("patient_id","age_index","gender","region","race","ethnicity","payer_type",
  "index_date","lot1_start_dt","death_dt","dx_year","lot_init_year","dx_to_1l_months",
  "fu_from_dx_months","fu_potential_months","baseline_ce_months","followup_ce_months","cci",
  "bl_hepatic","bl_renal","bl_infection","bl_ocular","bl_cv","bl_neuro",
  "n_hepatic","n_renal","n_infection","n_ocular","n_cv","n_neuro","baseline_py",
  "ip_hosp_count","er_visit_count","ip_los_days","soc_category","n_lines","lot1_length",
  "os_time","os_event","ttd_time","ttd_event","ttnt_time","ttnt_event","pfs_time","pfs_event",
  "incl_qualifying_mm","incl_eligible_1l_tx","incl_adult","incl_baseline_ce_6m",
  "incl_baseline_ce_12m","incl_fu_ce_3m","incl_new_user","incl_fu_mm_agents",
  "excl_prior_mm_tx","excl_other_cancer","excl_belantamab","excl_pregnancy")
ac <- pat[, base_cols]

ap <- file.path(out_dir, "analytic_cohort.csv")
lp <- file.path(out_dir, "analytic_lot_long.csv")
write.csv(ac, ap, row.names = FALSE, na = "NA")
write.csv(ll, lp, row.names = FALSE, na = "NA")

# ---- self-validate against the REAL dashboard validators (fail closed) ----------
val_ok <- FALSE
cedir <- Sys.getenv("COHORT_EXPLORER_DIR", "")
vfile <- if (nzchar(cedir)) file.path(cedir, "R", "build_flagged_cohort.R") else ""
if (nzchar(vfile) && file.exists(vfile)) {
  local({
    source(file.path(cedir, "R", "criteria_registry.R"), local = TRUE)
    source(file.path(cedir, "R", "cohort_select.R"), local = TRUE)
    source(vfile, local = TRUE)
    FL <- read.csv(ap, stringsAsFactors = FALSE)
    for (d in c("index_date","lot1_start_dt","death_dt")) FL[[d]] <- as.Date(FL[[d]])
    validate_flagged_cohort(FL)
    L2 <- read.csv(lp, stringsAsFactors = FALSE); L2$lot_start_dt <- as.Date(L2$lot_start_dt)
    load_lot_long(lp, cohort = FL)
    message("Self-validation: PASSED (validate_flagged_cohort + load_lot_long).")
    val_ok <<- TRUE
  })
} else {
  message("NOTE: set COHORT_EXPLORER_DIR=<path to cohort_explorer> to self-validate ",
          "against the dashboard validators before use.")
}

message("\nDONE", if (val_ok) " (validated)" else " (NOT self-validated)")
message(sprintf("  %s  (%s patients)", ap, format(nrow(ac), big.mark=",")))
message(sprintf("  %s  (%s lines)",    lp, format(nrow(ll), big.mark=",")))
message(sprintf("  COHORT_EXPLORER_DATA=%s\n  COHORT_EXPLORER_LOTLONG=%s", ap, lp))
