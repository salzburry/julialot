#!/usr/bin/env Rscript
# Julia June-5 Q4: same Q1/Q2/Q3 dashboards, but on Ashley's planned
# study cohort (= ELIG_COH_FINAL + the 12-mo CE pre-LOT1 check Julia
# confirmed on the June 5 PDF, which is not in the parent pipeline).
#
#   Rscript apr_30_2026/julia_q4_ashley/julia_q4.R
#
# Output: julia_q4_ashley_dashboard.html in cfg$output_dir.
#
# Reuses julia_q1_q3.R verbatim - all Q1/Q2/Q3 builders, steroid CSV,
# category CSV, coverage QC. The Q4 script just (a) computes Ashley's
# cohort, (b) writes a filtered LOT_LONG temp view, then (c) calls
# the Q1-Q3 helpers against that view.
#
# Why this lives in its own folder: cohort change vs Q1-Q3, so a
# user can compare {dashboard A on full cohort} vs {dashboard B on
# Ashley} without confusion. Parent pipeline files untouched.

.script_dir <- local({
  args <- commandArgs(trailingOnly = FALSE)
  fa <- grep("^--file=", args, value = TRUE)
  if (length(fa) > 0)
    return(dirname(normalizePath(sub("^--file=", "", fa[1]))))
  for (i in seq_len(sys.nframe())) {
    o <- tryCatch(sys.frame(i)$ofile, error = function(e) NULL)
    if (!is.null(o)) return(dirname(normalizePath(o)))
  }
  getwd()
})
.parent_dir <- dirname(.script_dir)

# Source julia_q1_q3.R WITHOUT triggering its auto-main() and WITHOUT
# letting its .script_dir auto-resolution latch on to commandArgs()
# "--file=julia_q4.R" (which would point its R/ helper sources at the
# wrong folder). The override option below tells julia_q1_q3.R where
# to find its R/ helpers, CSV inputs, and pipeline_inputs.csv.
options(julia_q1_q3.no_autorun  = TRUE)
options(julia_q1_q3.script_dir  = .parent_dir)
source(file.path(.parent_dir, "julia_q1_q3.R"))

# Q4-only constants. Distinct view names so this script can run
# concurrently with julia_q1_q3.R without clobbering its temp views.
Q4_LOT_LONG_FILT  <- "_jjq4_lot_long_ashley"
Q4_ENROLL_SPANS   <- "_jjq4_enroll_spans"
Q4_LOT1_STARTS    <- "_jjq4_lot1_starts"
Q4_ASHLEY_PATIDS  <- "_jjq4_ashley_patids"
Q4_PRE_LOT1_DAYS  <- 365L  # Julia June 5: 12-mo CE before 1L index date

# Cohort-pipeline knobs that julia_q1_q3.R's config_lot.R does NOT
# define (the cohort pipeline uses config_prompts.R instead). Defaults
# mirror config_prompts.R:43,90,98 verbatim, with env-var overrides
# matching the same env-var names so a user who already exports
# TBL_MEMBER_ENROLLMENT / GAP_DAYS / FINAL_TABLE_NAME for the parent
# cohort run picks up the same values here.
Q4_TBL_MEMBER_ENROLLMENT <- Sys.getenv("TBL_MEMBER_ENROLLMENT",
                                       unset = "member_enrollment")
Q4_GAP_DAYS              <- as.integer(Sys.getenv("GAP_DAYS",
                                                  unset = "30"))
Q4_FINAL_TABLE_NAME      <- Sys.getenv("FINAL_TABLE_NAME",
                                       unset = "ELIG_COH_FINAL")

# Build enrollment_spans (with Q4_GAP_DAYS allowance) directly from
# member_enrollment - the parent's temp view isn't persisted, so we
# rebuild it inside this script. SQL mirrors pipeline_steps.R:382-421
# verbatim so the gap semantics stay identical to CE_b/CE_f.
build_enrollment_spans_q4 <- function(con) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {Q4_ENROLL_SPANS} AS
    WITH base AS (
      SELECT PATID,
             cast(ELIGEFF as date) AS elig_eff,
             cast(ELIGEND as date) AS elig_end
      FROM {cdm_src(Q4_TBL_MEMBER_ENROLLMENT)}
      WHERE ELIGEFF IS NOT NULL AND ELIGEND IS NOT NULL
    ),
    ordered AS (
      SELECT *,
        max(elig_end) OVER (
          PARTITION BY PATID
          ORDER BY elig_eff, elig_end
          ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ) AS max_end_so_far
      FROM base
    ),
    flagged AS (
      SELECT *,
        CASE WHEN max_end_so_far IS NULL THEN 1
             WHEN elig_eff <= date_add(max_end_so_far, {Q4_GAP_DAYS} + 1) THEN 0
             ELSE 1 END AS new_grp
      FROM ordered
    ),
    grouped AS (
      SELECT *,
        sum(new_grp) OVER (PARTITION BY PATID ORDER BY elig_eff, elig_end
                           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS grp_id
      FROM flagged
    )
    SELECT PATID, grp_id,
           min(elig_eff) AS cov_start,
           max(elig_end) AS cov_end
    FROM grouped
    GROUP BY PATID, grp_id
  "))
}

# LOT1_START_DT per patient (Julia's '1L cohort index date').
build_lot1_starts_q4 <- function(con, lot_long) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {Q4_LOT1_STARTS} AS
    SELECT cast(PATID as string) AS PATID,
           LOT_START_DT AS LOT1_START_DT
    FROM {lot_long}
    WHERE LOT_NUM = 1 AND LOT_START_DT IS NOT NULL
  "))
}

# Ashley cohort = ELIG_COH_FINAL INNER JOIN LOT1 INNER JOIN
# enrollment_spans where at least one span covers
# [LOT1_START_DT - Q4_PRE_LOT1_DAYS, LOT1_START_DT - 1].
# Same gap semantics as CE_b (<=30 days absorbed) via Q4_ENROLL_SPANS.
build_ashley_patids <- function(con, elig_coh_final) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {Q4_ASHLEY_PATIDS} AS
    WITH ec AS (
      SELECT cast(PATID as string) AS PATID
      FROM {elig_coh_final}
    ),
    l1 AS (
      SELECT cast(PATID as string) AS PATID, LOT1_START_DT
      FROM {Q4_LOT1_STARTS}
    ),
    ec_l1 AS (
      SELECT ec.PATID, l1.LOT1_START_DT,
             date_sub(l1.LOT1_START_DT, {Q4_PRE_LOT1_DAYS}) AS pre_lot1_start,
             date_sub(l1.LOT1_START_DT, 1)                  AS pre_lot1_end
      FROM ec JOIN l1 ON ec.PATID = l1.PATID
    ),
    covered AS (
      SELECT ec_l1.PATID,
             max(CASE WHEN s.cov_start <= ec_l1.pre_lot1_start
                       AND s.cov_end   >= ec_l1.pre_lot1_end
                      THEN 1 ELSE 0 END) AS CE_pre_lot1_12mo
      FROM ec_l1
      LEFT JOIN {Q4_ENROLL_SPANS} s ON s.PATID = ec_l1.PATID
      GROUP BY ec_l1.PATID
    )
    SELECT PATID FROM covered WHERE CE_pre_lot1_12mo = 1
  "))
}

# Filtered LOT_LONG view feeding the Q1/Q2/Q3 helpers.
build_lot_long_filtered <- function(con, lot_long) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {Q4_LOT_LONG_FILT} AS
    SELECT l.*
    FROM {lot_long} l
    INNER JOIN {Q4_ASHLEY_PATIDS} a
            ON cast(l.PATID as string) = a.PATID
  "))
}

# Counts at each filter step for the attrition card.
q4_counts <- function(con, lot_long, elig_coh_final) {
  whole <- db_q(con, glue(
    "SELECT count(DISTINCT PATID) AS n FROM {lot_long}"))$n
  elig <- db_q(con, glue(
    "SELECT count(DISTINCT PATID) AS n FROM {elig_coh_final}"))$n
  elig_lot1 <- db_q(con, glue(
    "SELECT count(DISTINCT ec.PATID) AS n
     FROM {elig_coh_final} ec
     INNER JOIN {Q4_LOT1_STARTS} l1
             ON cast(ec.PATID as string) = l1.PATID"))$n
  ashley <- db_q(con, glue(
    "SELECT count(DISTINCT PATID) AS n FROM {Q4_ASHLEY_PATIDS}"))$n
  list(whole = whole, elig = elig, elig_lot1 = elig_lot1, ashley = ashley)
}

build_q4_overview_card <- function(counts, n_ster_codes, n_cat_rules) {
  pct <- function(num, den)
    if (den > 0) sprintf("%.1f%%", 100 * num / den) else "-"
  add_html_card(paste0(
    '<div style="font-family:system-ui;padding:14px;max-width:900px">',
    '<h3>Julia June 5 Q4 - Ashley planned study cohort</h3>',
    '<p style="color:#555;font-size:13px">Q1 / Q2 / Q3 dashboards on ',
    'Julia&apos;s planned cohort: parent <code>ELIG_COH_FINAL</code> ',
    '(all default IE flags applied) plus a Q4-only post-filter for ',
    'the June 5 PDF criterion <b>12-mo CE before LOT1 start</b>. The ',
    'parent already enforces 6-mo CE before MM dx via <code>CE_b</code>; ',
    'this script adds the second window (anchor: <code>LOT1_START_DT</code> ',
    'from <code>LOT_LONG</code>) using the parent&apos;s ',
    '<code>gap_days = ', Q4_GAP_DAYS, '</code> gap allowance.</p>',
    '<table style="font-size:13px;border-collapse:collapse;margin-top:8px">',
    '<tr style="background:#eef"><th style="text-align:left;padding:6px 12px">Filter step</th>',
    '<th style="text-align:right;padding:6px 12px">n patients</th>',
    '<th style="text-align:right;padding:6px 12px">% of whole</th></tr>',
    '<tr><td style="padding:6px 12px">Whole LOT_LONG cohort</td>',
    '<td style="text-align:right;padding:6px 12px">', format(counts$whole, big.mark = ","), '</td>',
    '<td style="text-align:right;padding:6px 12px">100.0%</td></tr>',
    '<tr><td style="padding:6px 12px">+ in ELIG_COH_FINAL (parent IE)</td>',
    '<td style="text-align:right;padding:6px 12px">', format(counts$elig, big.mark = ","), '</td>',
    '<td style="text-align:right;padding:6px 12px">', pct(counts$elig, counts$whole), '</td></tr>',
    '<tr><td style="padding:6px 12px">+ has LOT1 start in LOT_LONG</td>',
    '<td style="text-align:right;padding:6px 12px">', format(counts$elig_lot1, big.mark = ","), '</td>',
    '<td style="text-align:right;padding:6px 12px">', pct(counts$elig_lot1, counts$whole), '</td></tr>',
    '<tr style="background:#efe"><td style="padding:6px 12px"><b>+ 12-mo CE pre-LOT1 (Ashley final)</b></td>',
    '<td style="text-align:right;padding:6px 12px"><b>', format(counts$ashley, big.mark = ","), '</b></td>',
    '<td style="text-align:right;padding:6px 12px"><b>', pct(counts$ashley, counts$whole), '</b></td></tr>',
    '</table>',
    '<ul style="font-size:13px;color:#1a7a3a;margin-top:10px">',
    '<li><b>Q1</b>: regimen-category Sankeys per LOT pair (',
    n_cat_rules, ' regimen rules loaded).</li>',
    '<li><b>Q2</b>: steroid tokens appended to <code>LOT_BASE_MEDS</code> ',
    'inside the parent induction window (', n_ster_codes, ' codes loaded; ',
    '<code>SCT_ALLO</code>-started LOTs suppressed).</li>',
    '<li><b>Q3</b>: non-progressors dropped (inner-join LOTn &rarr; LOTn+1).</li>',
    '</ul></div>'),
    section = "OVERVIEW", title = "What this dashboard shows")
}

main_q4 <- function() {
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")
  cfg$build_dashboard <<- TRUE

  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn,
                        pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  lot_long       <- wrk("LOT_LONG")
  elig_coh_final <- wrk(Q4_FINAL_TABLE_NAME)
  rx_tbl         <- cdm_src(cfg$tbl_rx)
  medical_tbl    <- cdm_src(cfg$tbl_medical)

  ok <- function(t) isTRUE(tryCatch(
    nrow(db_q(con, glue("SELECT 1 FROM {t} LIMIT 1"))) >= 0,
    error = function(e) FALSE))
  if (!ok(lot_long))       stop("Cannot read ", lot_long)
  if (!ok(elig_coh_final)) stop("Cannot read ", elig_coh_final,
                                " - Ashley cohort needs parent ELIG_COH_FINAL.")
  q2_ok <- ok(rx_tbl) && ok(medical_tbl)
  if (!q2_ok) {
    log_msg("  WARN: rx or medical unreadable; Q2 steroid augmentation ",
            "skipped. Q1+Q3 still run.")
  }

  log_msg("Building enrollment spans (gap_days=", Q4_GAP_DAYS, ")")
  build_enrollment_spans_q4(con)

  log_msg("Pulling LOT1 starts from ", lot_long)
  build_lot1_starts_q4(con, lot_long)

  log_msg("Applying Ashley filter: ELIG_COH_FINAL + 12-mo CE pre-LOT1")
  build_ashley_patids(con, elig_coh_final)

  log_msg("Building filtered LOT_LONG -> ", Q4_LOT_LONG_FILT)
  build_lot_long_filtered(con, lot_long)

  if (q2_ok) {
    log_msg("Loading steroid codes")
    n_ster <- load_steroid_codes(con)
    log_msg("  ", n_ster, " codes loaded")
  } else {
    n_ster <- 0L
  }

  log_msg("Augmenting filtered LOT_LONG with steroid tokens")
  augment_lot_long(con, Q4_LOT_LONG_FILT, rx_tbl, medical_tbl, n_ster)

  log_msg("Loading categories")
  lookups <- load_categories()
  n_rules <- length(lookups$lookup_1L) + length(lookups$lookup_2L)
  log_msg("  ", length(lookups$lookup_1L), " 1L rules, ",
          length(lookups$lookup_2L), " 2L+ rules loaded")

  counts <- q4_counts(con, lot_long, elig_coh_final)
  log_msg("Cohort sizes - whole: ", counts$whole,
          " | ELIG_COH_FINAL: ", counts$elig,
          " | + LOT1: ", counts$elig_lot1,
          " | Ashley (final): ", counts$ashley)
  if (counts$ashley == 0)
    stop("Ashley cohort is empty - check ELIG_COH_FINAL and LOT_LONG inputs.")

  dashboard_items <<- list()
  build_q4_overview_card(counts, n_ster, n_rules)
  build_steroid_prevalence(con)
  for (n in 1:4) build_focused_pair(con, n, n + 1L)
  for (n in 1:4) build_category_pair(con, n, n + 1L, lookups)
  build_category_coverage(con, lookups)

  build_dashboard(
    out_name     = "julia_q4_ashley_dashboard.html",
    header_title = "MM LOT &mdash; Julia June 5 Q4 (Ashley planned cohort)",
    header_sub   = paste0("ELIG_COH_FINAL + 12-mo CE pre-LOT1 &bull; ",
                          format(counts$ashley, big.mark = ","), " patients")
  )
  log_msg("Wrote ", file.path(cfg$output_dir,
                              "julia_q4_ashley_dashboard.html"))
}

if (!interactive()) main_q4()
