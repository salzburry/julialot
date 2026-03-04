#!/usr/bin/env Rscript
# ============================================================
# GSK MM LOT - Part 2: Lines of Therapy (LOT) Analysis
#
# Implements Part 2 specifications (based on provided PDFs):
#   5A. MMA_MED    - MM-approved + steroid medication claims pull
#   5B. MAP_MED    - Medication Available Period algorithm (pushout/runout)
#   6.  LOT1_BASE  - LOT1 induction regimen identification
#   7.  SCT        - Stem Cell Transplant detection (AUTO/ALLO/CART)
#
# Key references (provided by user):
#   - mma med.pdf
#   - map med.pdf        (pushout/runout logic + Figure 3 example)
#   - lot1base.pdf
#   - sct.pdf            (SCT detection: AUTO/ALLO/CART)
#   - tab 40.pdf         (CL_MMA_ROLLUP)
#   - tab 41 sample.pdf  (CL_MMA_CODELIST)
#   - optum data dict.pdf (field validation)
#   - optum business rules.pdf (join/filter logic guidance)
#
# Input:  ELIG_COH_FINAL (output of Part 1 attrition pipeline, new_code.R)
# Output: MAP_STACKED, LOT1_BASE, LOT1_SCT, LOT1_BASE_END
#
# IMPORTANT - MAP algorithm corrections vs prior versions:
#   1. Medical claims: NO pushout (per map med.pdf page 5: "Pushout is
#      not implemented"). Medical runout always = DATE_SERVICE + DAY_SUPPLY - 1.
#   2. Pharmacy claims: pushout only when new claim arrives BEFORE current
#      rx_runout. When pharmacy claim arrives AFTER rx_runout (but within
#      med_runout), pharmacy resets without pushout (per Figure 3, iter 4).
#   3. The simplified "sum pharmacy day supply" approach is incorrect when
#      pharmacy expires mid-MAP (kept alive by medical) and later resets.
#      The aggregate() state machine handles this correctly.
# ============================================================
suppressPackageStartupMessages({
  library(DBI)
  library(odbc)
  library(glue)
  library(dplyr)
})

# ============================================================
# CONFIGURATION
# ============================================================
cfg <- list(
  # Connection
  dsn = Sys.getenv("DATABRICKS_DSN", unset = "RWDE"),
  pwd = Sys.getenv("DATABRICKS_PWD", unset = ""),

  # Databricks catalog + schemas
  catalog     = Sys.getenv("DATABRICKS_CATALOG", unset = "hive_metastore"),
  cdm_schema  = Sys.getenv("OPTUM_CDM_SCHEMA", unset = "clnprw_optum"),
  ref_schema  = Sys.getenv("PROJECT_REF_SCHEMA",
                           unset = Sys.getenv("DOMINO_USER_NAME", unset = "gsk_mm_lot_ref")),
  work_schema = Sys.getenv("PROJECT_WORK_SCHEMA",
                           unset = Sys.getenv("DOMINO_USER_NAME", unset = "gsk_mm_lot_work")),

  # Clinformatics CDM base tables (validated against optum data dict.pdf)
  tbl_medical  = "medical",
  tbl_med_proc = "med_procedure",
  tbl_rx       = "rx",

  # Use cumulative quarterly tables (t_<table>_YYYYqQ) like Part 1
  use_quarterly_tables = as.logical(Sys.getenv("USE_QUARTERLY_TABLES", unset = "TRUE")),
  study_end            = Sys.getenv("STUDY_END", unset = "2025-06-30"),

  # Cohort input (Part 1 output)
  input_cohort_table = Sys.getenv("INPUT_COHORT_TABLE", unset = "ELIG_COH_FINAL"),

  # Part 2 parameters
  induction_window_days = as.integer(Sys.getenv("INDUCTION_WINDOW_DAYS", unset = "60")),
  map_discon_gap_days   = as.integer(Sys.getenv("MAP_DISCON_GAP_DAYS", unset = "90")),
  lot_discon_gap_days   = as.integer(Sys.getenv("LOT_DISCON_GAP_DAYS", unset = "90")),
  medical_day_supply    = as.integer(Sys.getenv("MEDICAL_DAY_SUPPLY", unset = "28")),

  # Code list sourcing (priority: CSV > embedded > ref_schema table)
  codelist_dir         = Sys.getenv("CODELIST_DIR", unset = "/mnt/code/codelist"),
  use_embedded_codes   = as.logical(Sys.getenv("USE_EMBEDDED_CODES", unset = "FALSE")),
  cl_mma_rollup_tbl    = Sys.getenv("CL_MMA_ROLLUP_TBL", unset = "cl_mma_rollup"),
  cl_mma_codelist_tbl  = Sys.getenv("CL_MMA_CODELIST_TBL", unset = "cl_mma_codelist"),
  permissible_subs_tbl = Sys.getenv("PERMISSIBLE_SUBS_TBL", unset = "permissible_subs"),
  cl_sct_codelist_tbl  = Sys.getenv("CL_SCT_CODELIST_TBL", unset = "cl_sct_codelist"),

  # SCT parameters (per sct.pdf spec section 7)
  # Per sct.pdf: window is earliest_date through earliest_date + 13 (14-day span)
  # datediff(x, cur_start) <= 13 means days 0..13 inclusive = 14-day window
  sct_auto_window_days = as.integer(Sys.getenv("SCT_AUTO_WINDOW_DAYS", unset = "13")),
  sct_auto_gap_days    = as.integer(Sys.getenv("SCT_AUTO_GAP_DAYS", unset = "60")),
  sct_tandem_days      = as.integer(Sys.getenv("SCT_TANDEM_DAYS", unset = "180")),

  # Persist outputs
  persist_to_schema = as.logical(Sys.getenv("PERSIST_TO_SCHEMA", unset = "TRUE")),

  # Output directory for figures
  output_dir = Sys.getenv("OUTPUT_DIR", unset = "/mnt/results"),

  # Retry controls
  max_retries = 4,
  base_sleep  = 5
)

run_id <- Sys.getenv("DOMINO_RUN_ID", unset = format(Sys.time(), "%Y%m%d%H%M%S"))

# ============================================================
# LOGGING + HELPERS
# ============================================================
SEP   <- strrep("=", 70)
DASH  <- strrep("-", 70)

log_msg <- function(...) {
  cat(sprintf("[%s] ", format(Sys.time(), "%Y-%m-%d %H:%M:%S")), ..., "\n")
  flush.console()
}

stop_if_blank <- function(x, msg) {
  if (!nzchar(x)) stop(msg)
}

full_name <- function(schema, object) {
  paste0(cfg$catalog, ".", schema, ".", object)
}

cdm <- function(tbl) full_name(cfg$cdm_schema, tbl)
ref <- function(tbl) full_name(cfg$ref_schema, tbl)
wrk <- function(tbl) full_name(cfg$work_schema, tbl)

get_quarter_suffix <- function(end_date) {
  dt <- as.Date(end_date)
  year <- as.integer(format(dt, "%Y"))
  qtr  <- ceiling(as.integer(format(dt, "%m")) / 3)
  sprintf("%dq%d", year, qtr)
}

cdm_src <- function(base_tbl) {
  if (isTRUE(cfg$use_quarterly_tables)) {
    qsuffix <- get_quarter_suffix(cfg$study_end)
    cdm(paste0("t_", base_tbl, "_", qsuffix))
  } else {
    cdm(base_tbl)
  }
}

with_retry <- function(fn, max_retries = cfg$max_retries, base_sleep = cfg$base_sleep) {
  attempt <- 1
  repeat {
    out <- tryCatch(fn(), error = function(e) e)
    if (!inherits(out, "error")) return(out)
    if (attempt >= max_retries) stop(out)
    sleep_s <- base_sleep * (2^(attempt - 1))
    log_msg("Retryable failure: ", conditionMessage(out))
    log_msg("Retrying in ", sleep_s, "s (attempt ", attempt + 1, "/", max_retries, ")")
    Sys.sleep(sleep_s)
    attempt <- attempt + 1
  }
}

db_exec <- function(con, sql) {
  with_retry(function() DBI::dbExecute(con, sql))
}

db_q <- function(con, sql) {
  with_retry(function() DBI::dbGetQuery(con, sql))
}

# ============================================================
# CODE LIST SOURCING (CSV > embedded > ref schema tables)
# ============================================================
load_codelist_csv <- function(csv_name, col_spec) {
  csv_path <- file.path(cfg$codelist_dir, csv_name)
  if (!file.exists(csv_path)) return(NULL)
  tryCatch({
    df <- read.csv(csv_path, stringsAsFactors = FALSE, na.strings = c("", "NA", "NaN"))
    missing <- setdiff(col_spec, names(df))
    if (length(missing) > 0) {
      stop(glue("CSV {csv_name} missing columns: {paste(missing, collapse=', ')}"))
    }
    df <- df[, col_spec, drop = FALSE]
    esc <- function(x) {
      if (is.na(x) || is.null(x) || x == "") return("NULL")
      x <- gsub("'", "''", as.character(x))
      paste0("'", x, "'")
    }
    rows <- apply(df, 1, function(r) paste0("(", paste(vapply(r, esc, character(1)), collapse = ", "), ")"))
    sql <- paste0("SELECT * FROM (VALUES\n  ", paste(rows, collapse = ",\n  "), "\n) AS t(",
                  paste(col_spec, collapse = ", "), ")")
    log_msg("Loaded codelist from CSV: ", csv_path, " (", nrow(df), " rows)")
    sql
  }, error = function(e) {
    log_msg("WARNING: Failed to load CSV ", csv_path, ": ", e$message)
    NULL
  })
}

get_code_source <- function(embedded_fn, external_tbl, csv_name = NULL, col_spec = NULL) {
  if (!is.null(csv_name) && !is.null(col_spec) && dir.exists(cfg$codelist_dir)) {
    csv_sql <- load_codelist_csv(csv_name, col_spec)
    if (!is.null(csv_sql)) return(paste0("(", csv_sql, ") src"))
  }
  if (isTRUE(cfg$use_embedded_codes)) return(paste0("(", embedded_fn(), ") src"))
  ref(external_tbl)
}

# ------------------------------------------------------------
# Embedded Tab 40 (rollup) - minimal fallback only
# ------------------------------------------------------------
embedded_mma_rollup <- function() {
  "
  SELECT * FROM (VALUES
    ('bortezomib',      'PROTINHIB', 'BORT', 0, NULL, 0, 0),
    ('carfilzomib',     'PROTINHIB', 'CARF', 0, NULL, 0, 0),
    ('ixazomib',        'PROTINHIB', 'IXAZ', 1, NULL, 0, 0),
    ('lenalidomide',    'IMMUNOMOD', 'LENA', 1, 'BORT', 0, 0),
    ('pomalidomide',    'IMMUNOMOD', 'POMA', 1, NULL, 0, 0),
    ('daratumumab',     'ACD38',     'DARA', 0, NULL, 0, 0),
    ('dexamethasone',   'STEROID',   'DEXA', 0, NULL, 0, 0),
    ('prednisone',      'STEROID',   'PRED', 0, NULL, 0, 0)
  ) AS t(
    CL_MEDICATION_FULL,
    CL_MED_CLASS,
    CL_MED_ABBR,
    MONOMAINTENANCE,
    DUALMAINTENANCEWITH,
    CONDITIONING,
    USED_FOR_OTHER_CANCERS
  )
  "
}

# ------------------------------------------------------------
# Embedded Tab 41 (code list) - minimal fallback only
# ------------------------------------------------------------
embedded_mma_codelist <- function() {
  "
  SELECT * FROM (VALUES
    ('HCPCS', 'J9041',       'bortezomib',   'PROTINHIB', 'BORT'),
    ('HCPCS', 'J9047',       'carfilzomib',  'PROTINHIB', 'CARF'),
    ('NDC',   '00409170001', 'bortezomib',   'PROTINHIB', 'BORT'),
    ('NDC',   '76075010101', 'carfilzomib',  'PROTINHIB', 'CARF'),
    ('NDC',   '59572050121', 'lenalidomide', 'IMMUNOMOD', 'LENA'),
    ('NDC',   '00054413025', 'prednisone',  'STEROID',   'PRED')
  ) AS t(
    CL_CODE_TYPE,
    CL_CODE,
    CL_MEDICATION_FULL,
    CL_MED_CLASS,
    CL_MED_ABBR
  )
  "
}

# ------------------------------------------------------------
# Permissible substitutions
# ------------------------------------------------------------
embedded_permissible_subs <- function() {
  "
  SELECT * FROM (VALUES
    ('DARA', 'DARA'),
    ('BORT', 'IXAZ'),
    ('IXAZ', 'BORT')
  ) AS t(original_med, substitute_med)
  "
}

# ------------------------------------------------------------
# Embedded SCT codelist (Tab 47 - SCT procedure codes)
# AUTO = autologous, ALLO = allogeneic, CART = CAR-T
# Note: CPT 38241 = autologous (AUTO), CPT 38240 = allogeneic (ALLO)
# per AMA CPT definitions. This is correct despite appearing reversed.
# ------------------------------------------------------------
embedded_sct_codelist <- function() {
  "
  SELECT * FROM (VALUES
    ('HCPCS', '38241',  'AUTO'),
    ('HCPCS', '38240',  'ALLO'),
    ('HCPCS', 'S2150',  'ALLO'),
    ('HCPCS', 'Q2042',  'CART'),
    ('HCPCS', 'Q2054',  'CART'),
    ('HCPCS', 'Q2055',  'CART'),
    ('HCPCS', 'Q2056',  'CART')
  ) AS t(
    CL_CODE_TYPE,
    CL_CODE,
    SCT_TYPE
  )
  "
}

# ============================================================
# PIPELINE STEP RUNNER
# ============================================================
run_step <- function(con, name, sql, qc = NULL) {
  log_msg(SEP)
  log_msg("STEP ", name)
  log_msg(SEP)
  t0 <- proc.time()
  db_exec(con, sql)
  elapsed <- (proc.time() - t0)[["elapsed"]]
  log_msg("  Completed in ", round(elapsed, 1), "s")
  if (!is.null(qc) && nzchar(qc)) {
    out <- db_q(con, qc)
    print(out)
  }
  invisible(TRUE)
}

# ============================================================
# DESCRIPTIVES + FIGURES
# ============================================================
# Generates summary tables + ggplot2 figures for QC and reporting.
# Figures saved to cfg$output_dir as PNG.
# If ggplot2 is not available, figures are skipped gracefully.

has_ggplot2 <- requireNamespace("ggplot2", quietly = TRUE)
if (has_ggplot2) {
  suppressPackageStartupMessages(library(ggplot2))
}

save_plot <- function(p, filename, width = 10, height = 6) {
  if (!has_ggplot2) return(invisible(NULL))
  dir.create(cfg$output_dir, showWarnings = FALSE, recursive = TRUE)
  out_path <- file.path(cfg$output_dir, filename)
  tryCatch({
    ggsave(out_path, plot = p, width = width, height = height, dpi = 150)
    log_msg("  Figure saved: ", out_path)
  }, error = function(e) {
    log_msg("  WARNING: Could not save figure ", filename, ": ", e$message)
  })
}

print_descriptives <- function(con) {
  cat("\n")
  cat(SEP, "\n")
  cat("        PART 2 DESCRIPTIVE SUMMARY                    \n")
  cat(SEP, "\n")

  tryCatch({
    # --------------------------------------------------------
    # 1. MMA_MED Summary
    # --------------------------------------------------------
    cat("\n", DASH, "\n")
    cat("  5A. MMA_MED (Medication Claims) Summary\n")
    cat(DASH, "\n")

    mma_stats <- db_q(con, "
      SELECT
        count(*)                                     AS n_rows,
        count(DISTINCT PATID)                        AS n_patients,
        count(DISTINCT MED_ABBR)                     AS n_meds,
        sum(case when CLAIM_TYPE='pharmacy' then 1 else 0 end) AS n_pharmacy,
        sum(case when CLAIM_TYPE='medical'  then 1 else 0 end) AS n_medical,
        min(DATE_SERVICE) AS min_date,
        max(DATE_SERVICE) AS max_date,
        avg(DAY_SUPPLY)   AS avg_day_supply,
        percentile_approx(DAY_SUPPLY, 0.5) AS median_day_supply
      FROM mma_med_processed
    ")
    cat(sprintf("  Total claims (de-duped):     %s\n", format(mma_stats$n_rows, big.mark = ",")))
    cat(sprintf("  Distinct patients:           %s\n", format(mma_stats$n_patients, big.mark = ",")))
    cat(sprintf("  Distinct medications:        %s\n", format(mma_stats$n_meds, big.mark = ",")))
    cat(sprintf("  Pharmacy claims:             %s\n", format(mma_stats$n_pharmacy, big.mark = ",")))
    cat(sprintf("  Medical claims:              %s\n", format(mma_stats$n_medical, big.mark = ",")))
    cat(sprintf("  Date range:                  %s to %s\n", mma_stats$min_date, mma_stats$max_date))
    cat(sprintf("  Avg day supply:              %.1f (median: %.0f)\n",
                mma_stats$avg_day_supply, mma_stats$median_day_supply))

    # Claims by medication
    med_dist <- db_q(con, "
      SELECT MED_ABBR, MED_CLASS,
             count(*) AS n_claims,
             count(DISTINCT PATID) AS n_patients,
             sum(case when CLAIM_TYPE='pharmacy' then 1 else 0 end) AS n_rx,
             sum(case when CLAIM_TYPE='medical' then 1 else 0 end) AS n_med
      FROM mma_med_processed
      GROUP BY MED_ABBR, MED_CLASS
      ORDER BY count(DISTINCT PATID) DESC
    ")
    cat("\n")
    cat(sprintf("  %-8s %-12s %10s %10s %8s %8s\n", "Med", "Class", "Claims", "Patients", "RX", "Medical"))
    cat(strrep("-", 62), "\n")
    for (i in seq_len(nrow(med_dist))) {
      r <- med_dist[i, ]
      cat(sprintf("  %-8s %-12s %10s %10s %8s %8s\n",
                  r$MED_ABBR, r$MED_CLASS,
                  format(r$n_claims, big.mark = ","),
                  format(r$n_patients, big.mark = ","),
                  format(r$n_rx, big.mark = ","),
                  format(r$n_med, big.mark = ",")))
    }

    # Figure 1: Claims by medication (bar chart)
    if (has_ggplot2 && nrow(med_dist) > 0) {
      p1 <- ggplot(med_dist, aes(x = reorder(MED_ABBR, -n_patients), y = n_patients, fill = MED_CLASS)) +
        geom_bar(stat = "identity") +
        labs(title = "MMA_MED: Patients by Medication",
             x = "Medication", y = "Distinct Patients", fill = "Drug Class") +
        theme_minimal(base_size = 12) +
        theme(axis.text.x = element_text(angle = 45, hjust = 1))
      save_plot(p1, "fig01_mma_patients_by_med.png")
    }

    # Figure 2: Pharmacy vs Medical claims stacked bar
    if (has_ggplot2 && nrow(med_dist) > 0) {
      claim_long <- rbind(
        data.frame(MED_ABBR = med_dist$MED_ABBR, CLAIM_TYPE = "Pharmacy", N = med_dist$n_rx),
        data.frame(MED_ABBR = med_dist$MED_ABBR, CLAIM_TYPE = "Medical",  N = med_dist$n_med)
      )
      p2 <- ggplot(claim_long, aes(x = reorder(MED_ABBR, -N), y = N, fill = CLAIM_TYPE)) +
        geom_bar(stat = "identity", position = "stack") +
        labs(title = "MMA_MED: Claims by Type and Medication",
             x = "Medication", y = "Claim Count", fill = "Claim Type") +
        scale_fill_manual(values = c("Pharmacy" = "#4E79A7", "Medical" = "#E15759")) +
        theme_minimal(base_size = 12) +
        theme(axis.text.x = element_text(angle = 45, hjust = 1))
      save_plot(p2, "fig02_mma_claims_by_type.png")
    }

    # Day supply distribution
    ds_dist <- db_q(con, "
      SELECT CLAIM_TYPE,
             min(DAY_SUPPLY) AS min_ds,
             percentile_approx(DAY_SUPPLY, 0.25) AS p25_ds,
             percentile_approx(DAY_SUPPLY, 0.5)  AS median_ds,
             percentile_approx(DAY_SUPPLY, 0.75) AS p75_ds,
             max(DAY_SUPPLY) AS max_ds,
             avg(DAY_SUPPLY) AS mean_ds
      FROM mma_med_processed
      GROUP BY CLAIM_TYPE
    ")
    cat("\n  Day Supply Distribution:\n")
    cat(sprintf("  %-10s %6s %6s %6s %6s %6s %8s\n", "Type", "Min", "P25", "Med", "P75", "Max", "Mean"))
    cat(strrep("-", 55), "\n")
    for (i in seq_len(nrow(ds_dist))) {
      r <- ds_dist[i, ]
      cat(sprintf("  %-10s %6.0f %6.0f %6.0f %6.0f %6.0f %8.1f\n",
                  r$CLAIM_TYPE, r$min_ds, r$p25_ds, r$median_ds, r$p75_ds, r$max_ds, r$mean_ds))
    }

    # --------------------------------------------------------
    # 2. MAP Summary
    # --------------------------------------------------------
    cat("\n", DASH, "\n")
    cat("  5B. MAP_MED (Medication Available Periods) Summary\n")
    cat(DASH, "\n")

    map_stats <- db_q(con, "
      SELECT
        count(*)               AS n_maps,
        count(DISTINCT PATID)  AS n_patients,
        count(DISTINCT MAP_MED_TYPE) AS n_meds,
        avg(datediff(MAP_END_DT, MAP_START_DT) + 1) AS avg_map_length,
        percentile_approx(datediff(MAP_END_DT, MAP_START_DT) + 1, 0.5) AS median_map_length,
        min(datediff(MAP_END_DT, MAP_START_DT) + 1) AS min_map_length,
        max(datediff(MAP_END_DT, MAP_START_DT) + 1) AS max_map_length,
        sum(MAP_DISCON_FLG) AS n_discon
      FROM map_stacked
    ")
    cat(sprintf("  Total MAPs:                  %s\n", format(map_stats$n_maps, big.mark = ",")))
    cat(sprintf("  Distinct patients:           %s\n", format(map_stats$n_patients, big.mark = ",")))
    cat(sprintf("  Distinct medications:        %s\n", format(map_stats$n_meds, big.mark = ",")))
    cat(sprintf("  MAP length (days):           mean=%.1f, median=%.0f, range=[%s, %s]\n",
                map_stats$avg_map_length, map_stats$median_map_length,
                format(map_stats$min_map_length, big.mark = ","),
                format(map_stats$max_map_length, big.mark = ",")))
    cat(sprintf("  MAPs with discontinuation:   %s (%.1f%%)\n",
                format(map_stats$n_discon, big.mark = ","),
                100 * map_stats$n_discon / max(map_stats$n_maps, 1)))

    # MAPs per patient distribution
    maps_per_pt <- db_q(con, "
      SELECT n_maps, count(*) AS n_patients
      FROM (SELECT PATID, count(*) AS n_maps FROM map_stacked GROUP BY PATID)
      GROUP BY n_maps
      ORDER BY n_maps
    ")
    cat("\n  MAPs per patient distribution:\n")
    cat(sprintf("  %-8s %10s\n", "# MAPs", "Patients"))
    cat(strrep("-", 22), "\n")
    for (i in seq_len(min(nrow(maps_per_pt), 15))) {
      r <- maps_per_pt[i, ]
      cat(sprintf("  %-8d %10s\n", r$n_maps, format(r$n_patients, big.mark = ",")))
    }
    if (nrow(maps_per_pt) > 15) cat("  ... (truncated)\n")

    # MAP by medication
    map_by_med <- db_q(con, "
      SELECT
        MAP_MED_TYPE AS med,
        MAP_MED_CLASS AS class,
        count(*) AS n_maps,
        count(DISTINCT PATID) AS n_patients,
        avg(datediff(MAP_END_DT, MAP_START_DT) + 1) AS avg_map_days,
        sum(MAP_DISCON_FLG) AS n_discon,
        sum(CASE WHEN MAP_RX_RUNOUT_DT IS NOT NULL AND MAP_MED_RUNOUT_DT IS NOT NULL THEN 1 ELSE 0 END) AS n_both_types
      FROM map_stacked
      GROUP BY MAP_MED_TYPE, MAP_MED_CLASS
      ORDER BY count(DISTINCT PATID) DESC
    ")
    cat("\n")
    cat(sprintf("  %-8s %-12s %6s %8s %10s %7s %9s\n",
                "Med", "Class", "MAPs", "Patients", "Avg Days", "Discon", "Both Src"))
    cat(strrep("-", 66), "\n")
    for (i in seq_len(nrow(map_by_med))) {
      r <- map_by_med[i, ]
      cat(sprintf("  %-8s %-12s %6s %8s %9.1f %7s %9s\n",
                  r$med, r$class,
                  format(r$n_maps, big.mark = ","),
                  format(r$n_patients, big.mark = ","),
                  r$avg_map_days,
                  format(r$n_discon, big.mark = ","),
                  format(r$n_both_types, big.mark = ",")))
    }

    # Figure 3: MAP length distribution (histogram via SQL-binned counts to avoid OOM)
    if (has_ggplot2) {
      map_bins <- db_q(con, "
        SELECT floor((datediff(MAP_END_DT, MAP_START_DT) + 1) / 30) * 30 AS bin_start,
               count(*) AS n
        FROM map_stacked
        GROUP BY floor((datediff(MAP_END_DT, MAP_START_DT) + 1) / 30) * 30
        ORDER BY bin_start
      ")
      if (nrow(map_bins) > 0) {
        p3 <- ggplot(map_bins, aes(x = bin_start, y = n)) +
          geom_bar(stat = "identity", width = 28, fill = "#4E79A7", alpha = 0.8) +
          labs(title = "MAP Length Distribution",
               x = "MAP Length (days, 30-day bins)", y = "Count") +
          theme_minimal(base_size = 12) +
          scale_x_continuous(breaks = seq(0, max(map_bins$bin_start, na.rm = TRUE), by = 90))
        save_plot(p3, "fig03_map_length_distribution.png")
      }
    }

    # Figure 4: MAP count by medication (bar)
    if (has_ggplot2 && nrow(map_by_med) > 0) {
      p4 <- ggplot(map_by_med, aes(x = reorder(med, -n_patients), y = n_patients, fill = class)) +
        geom_bar(stat = "identity") +
        labs(title = "MAP: Patients by Medication",
             x = "Medication", y = "Distinct Patients", fill = "Drug Class") +
        theme_minimal(base_size = 12) +
        theme(axis.text.x = element_text(angle = 45, hjust = 1))
      save_plot(p4, "fig04_map_patients_by_med.png")
    }

    # --------------------------------------------------------
    # 3. LOT1 Summary
    # --------------------------------------------------------
    cat("\n", DASH, "\n")
    cat("  6. LOT1_BASE Summary\n")
    cat(DASH, "\n")

    lot1_stats <- db_q(con, "
      SELECT
        count(*) AS n_patients,
        avg(datediff(LOT1_START_DT, INDEX_DATE)) AS avg_days_to_lot1,
        avg(LOT1_MED_CNT) AS avg_induction_meds,
        avg(LOT1_BASE_LENGTH) AS avg_lot1_length,
        percentile_approx(LOT1_BASE_LENGTH, 0.5) AS median_lot1_length,
        min(LOT1_BASE_LENGTH) AS min_lot1_length,
        max(LOT1_BASE_LENGTH) AS max_lot1_length,
        sum(case when LOT1_BASE_DISCON_DT is not null then 1 else 0 end) AS n_discon,
        sum(case when LOT1_BASE_1ST_ADD_MED_DT is not null then 1 else 0 end) AS n_add_med
      FROM lot1_base
    ")
    cat(sprintf("  Total LOT1 patients:         %s\n", format(lot1_stats$n_patients, big.mark = ",")))
    cat(sprintf("  Avg days index->LOT1:        %.1f\n", lot1_stats$avg_days_to_lot1))
    cat(sprintf("  Avg induction meds:          %.1f\n", lot1_stats$avg_induction_meds))
    cat(sprintf("  LOT1 length (days):          mean=%.1f, median=%.0f, range=[%s, %s]\n",
                lot1_stats$avg_lot1_length, lot1_stats$median_lot1_length,
                format(lot1_stats$min_lot1_length, big.mark = ","),
                format(lot1_stats$max_lot1_length, big.mark = ",")))
    cat(sprintf("  With discontinuation date:   %s (%.1f%%)\n",
                format(lot1_stats$n_discon, big.mark = ","),
                100 * lot1_stats$n_discon / max(lot1_stats$n_patients, 1)))
    cat(sprintf("  With medication add:         %s (%.1f%%)\n",
                format(lot1_stats$n_add_med, big.mark = ","),
                100 * lot1_stats$n_add_med / max(lot1_stats$n_patients, 1)))

    # LOT1 end reasons
    end_reasons <- db_q(con, "
      SELECT LOT1_BASE_END_REASON, count(*) AS n,
             avg(datediff(LOT1_BASE_END_DT, LOT1_START_DT) + 1) AS avg_length
      FROM lot1_base_end
      GROUP BY LOT1_BASE_END_REASON
      ORDER BY count(*) DESC
    ")
    total_lot1 <- lot1_stats$n_patients
    cat("\n  LOT1 BASE End Reasons:\n")
    cat(sprintf("  %-20s %10s %8s %10s\n", "Reason", "N", "%", "Avg Days"))
    cat(strrep("-", 52), "\n")
    for (i in seq_len(nrow(end_reasons))) {
      r <- end_reasons[i, ]
      cat(sprintf("  %-20s %10s %7.1f%% %10.1f\n",
                  r$LOT1_BASE_END_REASON,
                  format(r$n, big.mark = ","),
                  100 * r$n / max(total_lot1, 1),
                  r$avg_length))
    }

    # Induction regimen distribution (Top 25)
    regimens <- db_q(con, "
      SELECT
        LOT1_BASE_MEDS AS regimen,
        count(*) AS n_patients,
        avg(LOT1_BASE_LENGTH) AS avg_length,
        avg(LOT1_MED_CNT) AS avg_meds
      FROM lot1_base
      GROUP BY LOT1_BASE_MEDS
      ORDER BY count(*) DESC
      LIMIT 25
    ")
    cat("\n  Top 25 LOT1 Induction Regimens:\n")
    cat(sprintf("  %-40s %8s %7s %9s\n", "Regimen", "N", "%", "Avg Days"))
    cat(strrep("-", 68), "\n")
    for (i in seq_len(nrow(regimens))) {
      r <- regimens[i, ]
      cat(sprintf("  %-40s %8s %6.1f%% %8.1f\n",
                  substr(r$regimen, 1, 40),
                  format(r$n_patients, big.mark = ","),
                  100 * r$n_patients / max(total_lot1, 1),
                  r$avg_length))
    }

    # Figure 5: LOT1 induction regimen frequency (top 15 horizontal bar)
    if (has_ggplot2 && nrow(regimens) > 0) {
      top15 <- head(regimens, 15)
      top15$regimen <- factor(top15$regimen, levels = rev(top15$regimen))
      p5 <- ggplot(top15, aes(x = regimen, y = n_patients)) +
        geom_bar(stat = "identity", fill = "#59A14F") +
        coord_flip() +
        labs(title = "LOT1: Top 15 Induction Regimens",
             x = NULL, y = "Number of Patients") +
        theme_minimal(base_size = 12)
      save_plot(p5, "fig05_lot1_top_regimens.png", width = 12, height = 7)
    }

    # Figure 6: LOT1 base length distribution (SQL-binned to avoid OOM)
    if (has_ggplot2) {
      lot1_bins <- db_q(con, "
        SELECT floor(LOT1_BASE_LENGTH / 30) * 30 AS bin_start,
               count(*) AS n,
               percentile_approx(LOT1_BASE_LENGTH, 0.5) AS median_val
        FROM lot1_base
        WHERE LOT1_BASE_LENGTH IS NOT NULL
        GROUP BY floor(LOT1_BASE_LENGTH / 30) * 30
        ORDER BY bin_start
      ")
      if (nrow(lot1_bins) > 0) {
        median_len <- lot1_bins$median_val[1]  # same for all rows
        p6 <- ggplot(lot1_bins, aes(x = bin_start, y = n)) +
          geom_bar(stat = "identity", width = 28, fill = "#59A14F", alpha = 0.8) +
          labs(title = "LOT1 BASE Length Distribution",
               x = "LOT1 BASE Length (days, 30-day bins)", y = "Count") +
          theme_minimal(base_size = 12) +
          geom_vline(xintercept = median_len,
                     linetype = "dashed", color = "red", linewidth = 1) +
          annotate("text", x = median_len + 20, y = Inf, vjust = 2, hjust = 0,
                   label = paste0("Median: ", round(median_len)),
                   color = "red", size = 4)
        save_plot(p6, "fig06_lot1_base_length.png")
      }
    }

    # Figure 7: LOT1 end reason pie / bar
    if (has_ggplot2 && nrow(end_reasons) > 0) {
      end_reasons$pct <- 100 * end_reasons$n / sum(end_reasons$n)
      end_reasons$label <- paste0(end_reasons$LOT1_BASE_END_REASON, "\n",
                                  format(end_reasons$n, big.mark = ","),
                                  " (", round(end_reasons$pct, 1), "%)")
      p7 <- ggplot(end_reasons, aes(x = reorder(LOT1_BASE_END_REASON, -n), y = n, fill = LOT1_BASE_END_REASON)) +
        geom_bar(stat = "identity") +
        geom_text(aes(label = paste0(format(n, big.mark = ","), "\n(", round(pct, 1), "%)")),
                  vjust = -0.3, size = 3.5) +
        labs(title = "LOT1 BASE End Reasons",
             x = NULL, y = "Number of Patients") +
        scale_fill_manual(values = c("DISCONTINUATION" = "#E15759",
                                     "MED_ADD" = "#F28E2B",
                                     "CENSORED" = "#76B7B2",
                                     "SCT_AUTO" = "#B07AA1",
                                     "SCT_ALLO" = "#9C755F",
                                     "SCT_CART" = "#FF9DA7",
                                     "SCT" = "#BAB0AC")) +
        theme_minimal(base_size = 12) +
        theme(legend.position = "none")
      save_plot(p7, "fig07_lot1_end_reasons.png", width = 8, height = 6)
    }

    # Figure 8: Induction med count distribution
    if (has_ggplot2) {
      med_cnt <- db_q(con, "
        SELECT LOT1_MED_CNT, count(*) AS n
        FROM lot1_base
        GROUP BY LOT1_MED_CNT
        ORDER BY LOT1_MED_CNT
      ")
      if (nrow(med_cnt) > 0) {
        med_cnt$pct <- 100 * med_cnt$n / sum(med_cnt$n)
        p8 <- ggplot(med_cnt, aes(x = factor(LOT1_MED_CNT), y = n)) +
          geom_bar(stat = "identity", fill = "#4E79A7") +
          geom_text(aes(label = paste0(format(n, big.mark = ","), "\n(", round(pct, 1), "%)")),
                    vjust = -0.3, size = 3.5) +
          labs(title = "LOT1: Number of Induction Medications per Patient",
               x = "Number of Induction Meds", y = "Patients") +
          theme_minimal(base_size = 12)
        save_plot(p8, "fig08_lot1_med_count.png", width = 8, height = 6)
      }
    }

    # Drug class distribution
    cat("\n  LOT1 Drug Class Distribution (from induction meds):\n")
    class_dist <- db_q(con, "
      SELECT MED_CLASS, count(DISTINCT PATID) AS n_patients
      FROM lot1_induction_meds
      GROUP BY MED_CLASS
      ORDER BY count(DISTINCT PATID) DESC
    ")
    cat(sprintf("  %-20s %10s %8s\n", "Class", "Patients", "%"))
    cat(strrep("-", 42), "\n")
    for (i in seq_len(nrow(class_dist))) {
      r <- class_dist[i, ]
      cat(sprintf("  %-20s %10s %7.1f%%\n",
                  r$MED_CLASS, format(r$n_patients, big.mark = ","),
                  100 * r$n_patients / max(total_lot1, 1)))
    }

    # --------------------------------------------------------
    # 4. SCT Summary
    # --------------------------------------------------------
    cat("\n", DASH, "\n")
    cat("  7. SCT (Stem Cell Transplant) Summary\n")
    cat(DASH, "\n")

    sct_raw_stats <- tryCatch(db_q(con, "
      SELECT SCT_TYPE, count(*) AS n_claims, count(DISTINCT PATID) AS n_patients
      FROM sct_claims_raw
      GROUP BY SCT_TYPE
      ORDER BY SCT_TYPE
    "), error = function(e) data.frame())
    if (nrow(sct_raw_stats) > 0) {
      cat("  Raw SCT claims by type:\n")
      cat(sprintf("  %-8s %10s %10s\n", "Type", "Claims", "Patients"))
      cat(strrep("-", 32), "\n")
      for (i in seq_len(nrow(sct_raw_stats))) {
        r <- sct_raw_stats[i, ]
        cat(sprintf("  %-8s %10s %10s\n",
                    r$SCT_TYPE, format(r$n_claims, big.mark = ","),
                    format(r$n_patients, big.mark = ",")))
      }
    } else {
      cat("  No SCT claims found.\n")
    }

    sct_lot1_stats <- tryCatch(db_q(con, "
      SELECT
        count(*) AS n_patients,
        sum(CASE WHEN LOT1_TX_AUTO_DT_1 IS NOT NULL THEN 1 ELSE 0 END) AS n_with_auto,
        sum(CASE WHEN FIRST_ALLO_DT IS NOT NULL THEN 1 ELSE 0 END) AS n_with_allo,
        sum(CASE WHEN FIRST_CART_DT IS NOT NULL THEN 1 ELSE 0 END) AS n_with_cart,
        sum(LOT1_SCT_AUTO_TAND_FLG) AS n_tandem,
        sum(LOT1_SCT_AUTO_SING_FLG) AS n_single_auto,
        sum(CASE WHEN LOT1_TX_ENDDATE IS NOT NULL THEN 1 ELSE 0 END) AS n_sct_end
      FROM lot1_sct
    "), error = function(e) data.frame())
    if (nrow(sct_lot1_stats) > 0) {
      cat(sprintf("\n  LOT1 SCT Summary (of %s LOT1 patients):\n",
                  format(sct_lot1_stats$n_patients, big.mark = ",")))
      cat(sprintf("    With AUTO SCT:      %s (%.1f%%)\n",
                  format(sct_lot1_stats$n_with_auto, big.mark = ","),
                  100 * sct_lot1_stats$n_with_auto / max(sct_lot1_stats$n_patients, 1)))
      cat(sprintf("      Tandem AUTO:      %s\n", format(sct_lot1_stats$n_tandem, big.mark = ",")))
      cat(sprintf("      Single AUTO:      %s\n", format(sct_lot1_stats$n_single_auto, big.mark = ",")))
      cat(sprintf("    With ALLO SCT:      %s (%.1f%%)\n",
                  format(sct_lot1_stats$n_with_allo, big.mark = ","),
                  100 * sct_lot1_stats$n_with_allo / max(sct_lot1_stats$n_patients, 1)))
      cat(sprintf("    With CAR-T:         %s (%.1f%%)\n",
                  format(sct_lot1_stats$n_with_cart, big.mark = ","),
                  100 * sct_lot1_stats$n_with_cart / max(sct_lot1_stats$n_patients, 1)))
      cat(sprintf("    SCT ending LOT1:    %s (%.1f%%)\n",
                  format(sct_lot1_stats$n_sct_end, big.mark = ","),
                  100 * sct_lot1_stats$n_sct_end / max(sct_lot1_stats$n_patients, 1)))
    }

    # SCT end reason breakdown
    sct_end_reasons <- tryCatch(db_q(con, "
      SELECT
        CASE LOT1_TX_ENDDATE_REASON
          WHEN 1 THEN 'AUTO' WHEN 2 THEN 'ALLO' WHEN 3 THEN 'CART' ELSE 'NONE'
        END AS SCT_END_TYPE,
        count(*) AS n
      FROM lot1_sct
      WHERE LOT1_TX_ENDDATE IS NOT NULL
      GROUP BY LOT1_TX_ENDDATE_REASON
      ORDER BY LOT1_TX_ENDDATE_REASON
    "), error = function(e) data.frame())
    if (nrow(sct_end_reasons) > 0) {
      cat("\n  SCT End Reason (within patients whose LOT1 ends due to SCT):\n")
      cat(sprintf("  %-8s %10s\n", "Type", "N"))
      cat(strrep("-", 20), "\n")
      for (i in seq_len(nrow(sct_end_reasons))) {
        r <- sct_end_reasons[i, ]
        cat(sprintf("  %-8s %10s\n", r$SCT_END_TYPE, format(r$n, big.mark = ",")))
      }
    }

    cat("\n", SEP, "\n")
    cat("  END OF DESCRIPTIVE SUMMARY\n")
    cat(SEP, "\n")

  }, error = function(e) {
    log_msg("WARN: Could not generate descriptive summary: ", conditionMessage(e))
  })
}

# ============================================================
# MAIN
# ============================================================
main <- function() {
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")

  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  log_msg("Connected. Run ID: ", run_id)
  log_msg("Configuration:")
  log_msg("  CDM Schema:        ", cfg$cdm_schema)
  log_msg("  Work Schema:       ", cfg$work_schema)
  log_msg("  Input Cohort:      ", cfg$input_cohort_table)
  log_msg("  Induction Window:  ", cfg$induction_window_days, " days")
  log_msg("  MAP Discon Gap:    ", cfg$map_discon_gap_days, " days")
  log_msg("  Medical Day Supply:", cfg$medical_day_supply, " days")
  log_msg("  LOT Discon Gap:    ", cfg$lot_discon_gap_days, " days")

  # ----------------------------------------------------------
  # STEP 0: Register code lists as TEMP views
  # ----------------------------------------------------------
  rollup_src <- get_code_source(
    embedded_fn = embedded_mma_rollup,
    external_tbl = cfg$cl_mma_rollup_tbl,
    csv_name = "cl_mma_rollup.csv",
    col_spec = c("CL_MEDICATION_FULL", "CL_MED_CLASS", "CL_MED_ABBR",
                 "MONOMAINTENANCE", "DUALMAINTENANCEWITH", "CONDITIONING", "USED_FOR_OTHER_CANCERS")
  )

  codelist_src <- get_code_source(
    embedded_fn = embedded_mma_codelist,
    external_tbl = cfg$cl_mma_codelist_tbl,
    csv_name = "cl_mma_codelist.csv",
    col_spec = c("CL_CODE_TYPE", "CL_CODE", "CL_MEDICATION_FULL", "CL_MED_CLASS", "CL_MED_ABBR")
  )

  subs_src <- get_code_source(
    embedded_fn = embedded_permissible_subs,
    external_tbl = cfg$permissible_subs_tbl,
    csv_name = "permissible_subs.csv",
    col_spec = c("original_med", "substitute_med")
  )

  sct_src <- get_code_source(
    embedded_fn = embedded_sct_codelist,
    external_tbl = cfg$cl_sct_codelist_tbl,
    csv_name = "cl_sct_codelist.csv",
    col_spec = c("CL_CODE_TYPE", "CL_CODE", "SCT_TYPE")
  )

  run_step(con, "S00_mma_rollup", glue("
    CREATE OR REPLACE TEMPORARY VIEW mma_rollup AS
    SELECT
      lower(trim(CL_MEDICATION_FULL)) AS CL_MEDICATION_FULL,
      upper(trim(CL_MED_CLASS))       AS CL_MED_CLASS,
      upper(trim(CL_MED_ABBR))        AS CL_MED_ABBR,
      -- Tab 40 fields can be 'YES', 'YES mainly...', 1, 0, or NULL.
      -- Robust parsing: treat 'YES%' or '1' as 1, everything else as 0.
      CASE WHEN upper(trim(cast(MONOMAINTENANCE AS string))) LIKE 'YES%'
            OR  trim(cast(MONOMAINTENANCE AS string)) = '1'
           THEN 1 ELSE 0 END AS MONOMAINTENANCE,
      CASE
        WHEN DUALMAINTENANCEWITH IS NULL
          OR upper(trim(cast(DUALMAINTENANCEWITH AS string))) IN ('', 'NULL', 'NONE', 'NA', 'N/A')
          THEN NULL
        ELSE upper(trim(cast(DUALMAINTENANCEWITH AS string)))
      END AS DUALMAINTENANCEWITH,
      CASE WHEN upper(trim(cast(CONDITIONING AS string))) LIKE 'YES%'
            OR  trim(cast(CONDITIONING AS string)) = '1'
           THEN 1 ELSE 0 END AS CONDITIONING,
      CASE WHEN upper(trim(cast(USED_FOR_OTHER_CANCERS AS string))) LIKE 'YES%'
            OR  trim(cast(USED_FOR_OTHER_CANCERS AS string)) = '1'
           THEN 1 ELSE 0 END AS USED_FOR_OTHER_CANCERS
    FROM {rollup_src}
  "), qc = "SELECT count(*) AS n_rows, count(DISTINCT CL_MED_ABBR) AS n_meds,
            sum(MONOMAINTENANCE) AS n_monomaint, sum(CONDITIONING) AS n_conditioning,
            sum(USED_FOR_OTHER_CANCERS) AS n_other_cancer FROM mma_rollup")

  run_step(con, "S01_mma_codelist", glue("
    CREATE OR REPLACE TEMPORARY VIEW mma_codelist AS
    SELECT
      upper(trim(CL_CODE_TYPE)) AS CL_CODE_TYPE,
      upper(regexp_replace(trim(CL_CODE), '[^A-Za-z0-9]', '')) AS CL_CODE,
      lower(trim(CL_MEDICATION_FULL)) AS CL_MEDICATION_FULL,
      upper(trim(CL_MED_CLASS))       AS CL_MED_CLASS,
      upper(trim(CL_MED_ABBR))        AS CL_MED_ABBR
    FROM {codelist_src}
    WHERE CL_CODE IS NOT NULL AND trim(CL_CODE) <> ''
      AND CL_CODE_TYPE IS NOT NULL AND trim(CL_CODE_TYPE) <> ''
  "), qc = "SELECT count(*) AS n_rows, count(DISTINCT CL_MED_ABBR) AS n_meds, count(DISTINCT CL_CODE_TYPE) AS n_code_types FROM mma_codelist")

  run_step(con, "S02_permissible_subs", glue("
    CREATE OR REPLACE TEMPORARY VIEW permissible_subs AS
    SELECT
      upper(trim(original_med))   AS original_med,
      upper(trim(substitute_med)) AS substitute_med
    FROM {subs_src}
    WHERE original_med IS NOT NULL AND substitute_med IS NOT NULL
  "), qc = "SELECT count(*) AS n_rows, count(DISTINCT original_med) AS n_orig_meds FROM permissible_subs")

  # ----------------------------------------------------------
  # Codelist <-> Rollup consistency QC
  # ----------------------------------------------------------
  log_msg("Checking codelist <-> rollup consistency...")
  tryCatch({
    # Codelist meds not in rollup (will be missing class/flag info)
    orphan_meds <- db_q(con, "
      SELECT c.CL_MED_ABBR, count(*) AS n_codes
      FROM mma_codelist c
      LEFT JOIN mma_rollup r ON c.CL_MED_ABBR = r.CL_MED_ABBR
      WHERE r.CL_MED_ABBR IS NULL
      GROUP BY c.CL_MED_ABBR
      ORDER BY n_codes DESC
    ")
    if (nrow(orphan_meds) > 0) {
      log_msg("  WARNING: Codelist meds NOT in rollup (will have NULL class/flags):")
      print(orphan_meds)
    } else {
      log_msg("  OK: All codelist meds found in rollup.")
    }

    # Reverse check: rollup meds with ZERO codes in codelist (therapy would be
    # completely undetectable — silent drop of an entire medication)
    uncoded_meds <- db_q(con, "
      SELECT r.CL_MED_ABBR, r.CL_MED_CLASS
      FROM mma_rollup r
      LEFT JOIN mma_codelist c ON r.CL_MED_ABBR = c.CL_MED_ABBR
      WHERE c.CL_MED_ABBR IS NULL
      ORDER BY r.CL_MED_CLASS, r.CL_MED_ABBR
    ")
    if (nrow(uncoded_meds) > 0) {
      log_msg("  WARNING: Rollup meds with ZERO codes in codelist (will never be extracted!):")
      print(uncoded_meds)
    } else {
      log_msg("  OK: All rollup meds have at least one code in codelist.")
    }

    # Validate CL_CODE_TYPE values are exactly the expected set
    code_types <- db_q(con, "
      SELECT CL_CODE_TYPE, count(*) AS n_codes
      FROM mma_codelist
      GROUP BY CL_CODE_TYPE
      ORDER BY CL_CODE_TYPE
    ")
    log_msg("  Code type distribution in codelist:")
    print(code_types)
    unexpected_types <- setdiff(code_types$CL_CODE_TYPE, c("NDC", "HCPCS", "ICD"))
    if (length(unexpected_types) > 0) {
      log_msg("  WARNING: Unexpected CL_CODE_TYPE values: ", paste(unexpected_types, collapse = ", "))
      log_msg("  These codes will NOT be matched by the extraction logic!")
    }

    # MED_ABBR mapping to >1 class (min() will hide this)
    multi_class <- db_q(con, "
      SELECT CL_MED_ABBR, count(DISTINCT CL_MED_CLASS) AS n_classes,
             concat_ws(', ', collect_set(CL_MED_CLASS)) AS classes
      FROM mma_codelist
      GROUP BY CL_MED_ABBR
      HAVING count(DISTINCT CL_MED_CLASS) > 1
    ")
    if (nrow(multi_class) > 0) {
      log_msg("  WARNING: MED_ABBR maps to multiple classes (min() will pick one):")
      print(multi_class)
    } else {
      log_msg("  OK: Each MED_ABBR maps to exactly one class.")
    }
  }, error = function(e) {
    log_msg("  WARNING: Codelist consistency QC failed: ", e$message)
  })

  # Fetch med/class lists for dynamic flag generation
  meds <- db_q(con, "SELECT DISTINCT CL_MED_ABBR FROM mma_rollup ORDER BY CL_MED_ABBR")$CL_MED_ABBR
  classes <- db_q(con, "SELECT DISTINCT CL_MED_CLASS FROM mma_rollup ORDER BY CL_MED_CLASS")$CL_MED_CLASS
  if (length(meds) == 0) stop("mma_rollup has 0 medications after load/clean.")
  if (length(classes) == 0) stop("mma_rollup has 0 classes after load/clean.")
  log_msg("Rollup meds: ", paste(meds, collapse = ", "))
  log_msg("Rollup classes: ", paste(classes, collapse = ", "))

  # Dynamic flag expressions
  # Sanitize both med abbreviations and class names for safe SQL column names
  sanitize_col <- function(x) gsub("[^A-Za-z0-9]+", "_", toupper(x))
  med_flag_exprs <- paste0(
    vapply(meds, function(m) glue("max(case when im.MED_ABBR = '{m}' then 1 else 0 end) as LOT1_MED_{sanitize_col(m)}"), character(1)),
    collapse = ",\n      "
  )
  sanitize_class <- sanitize_col  # alias for backward compatibility
  class_flag_exprs <- paste0(
    vapply(classes, function(cl) glue("max(case when im.MED_CLASS = '{cl}' then 1 else 0 end) as LOT1_CLASS_{sanitize_class(cl)}"), character(1)),
    collapse = ",\n      "
  )

  # ----------------------------------------------------------
  # STEP 1: Load Part 1 cohort
  # ----------------------------------------------------------
  # OBS_END_DT = observable follow-up end = min(study_end, death, disenrollment)
  # This is ENDDATE_CE from Part 1, NOT ENDDATE (which ignores disenrollment).
  # Using ENDDATE would create fake follow-up after disenrollment, causing:
  #   - false "confirmed" discontinuations (appear to have 90 days post-runout)
  #   - detecting add-meds/claims during unobservable periods
  run_step(con, "S03_patient_input", glue("
    CREATE OR REPLACE TEMPORARY VIEW lot_patient_input AS
    SELECT
      PATID,
      cast(INDEX_DATE AS date) AS INDEX_DATE,
      cast(ENDDATE AS date)    AS ENDDATE,
      cast(ENDDATE_CE AS date) AS ENDDATE_CE,
      -- OBS_END_DT: canonical observation end for all LOT/MAP logic
      -- Prefers ENDDATE_CE (accounts for disenrollment); falls back to ENDDATE
      coalesce(cast(ENDDATE_CE AS date), cast(ENDDATE AS date)) AS OBS_END_DT,
      cast(DEATH_DT AS date)   AS DEATH_DT,
      GDR_CD,
      YRDOB,
      AGE_INDEX_YR,
      FU_DAYS,
      FU_DAYS_CE
    FROM {wrk(cfg$input_cohort_table)}
  "), qc = "
    SELECT count(*) AS n_patients, min(INDEX_DATE) AS min_index, max(OBS_END_DT) AS max_obs_end,
           sum(case when ENDDATE_CE < ENDDATE then 1 else 0 end) AS n_disenrolled_before_enddate
    FROM lot_patient_input")

  # ----------------------------------------------------------
  # STEP 2 (5A): MMA_MED - Raw extraction
  # Sources: medical (PROC_CD, BILL_PROC_CD, NDC), med_procedure (PROC), rx (NDC)
  # ----------------------------------------------------------
  run_step(con, "S04_mma_med_raw", glue("
    CREATE OR REPLACE TEMPORARY VIEW mma_med_raw AS
    WITH codelist AS (
      SELECT /*+ BROADCAST */ * FROM mma_codelist
    ),
    -- 1) Medical claims - PROC_CD (HCPCS)
    med_proc_cd AS (
      SELECT
        m.PATID,
        cast(m.FST_DT AS date) AS DATE_SERVICE,
        {cfg$medical_day_supply} AS DAY_SUPPLY,
        'medical' AS CLAIM_TYPE,
        'med_proc_cd' AS CLAIM_SOURCE,
        c.CL_CODE AS CODE,
        c.CL_CODE_TYPE AS CODE_TYPE,
        c.CL_MED_ABBR AS MED_ABBR,
        c.CL_MED_CLASS AS MED_CLASS
      FROM {cdm_src(cfg$tbl_medical)} m
      INNER JOIN lot_patient_input p ON m.PATID = p.PATID
      INNER JOIN codelist c
        ON c.CL_CODE_TYPE = 'HCPCS'
       AND upper(regexp_replace(coalesce(cast(m.PROC_CD as string),''), '[^A-Za-z0-9]', '')) = c.CL_CODE
      WHERE cast(m.FST_DT AS date) >= p.INDEX_DATE
        AND cast(m.FST_DT AS date) <= p.OBS_END_DT
    ),
    -- 2) Medical claims - BILL_PROC_CD (HCPCS)
    med_bill_proc_cd AS (
      SELECT
        m.PATID,
        cast(m.FST_DT AS date) AS DATE_SERVICE,
        {cfg$medical_day_supply} AS DAY_SUPPLY,
        'medical' AS CLAIM_TYPE,
        'med_bill_proc' AS CLAIM_SOURCE,
        c.CL_CODE AS CODE,
        c.CL_CODE_TYPE AS CODE_TYPE,
        c.CL_MED_ABBR AS MED_ABBR,
        c.CL_MED_CLASS AS MED_CLASS
      FROM {cdm_src(cfg$tbl_medical)} m
      INNER JOIN lot_patient_input p ON m.PATID = p.PATID
      INNER JOIN codelist c
        ON c.CL_CODE_TYPE = 'HCPCS'
       AND upper(regexp_replace(coalesce(cast(m.BILL_PROC_CD as string),''), '[^A-Za-z0-9]', '')) = c.CL_CODE
      WHERE cast(m.FST_DT AS date) >= p.INDEX_DATE
        AND cast(m.FST_DT AS date) <= p.OBS_END_DT
    ),
    -- 3) Medical claims - NDC field (NDC-coded drug administrations on medical)
    med_ndc AS (
      SELECT
        m.PATID,
        cast(m.FST_DT AS date) AS DATE_SERVICE,
        {cfg$medical_day_supply} AS DAY_SUPPLY,
        'medical' AS CLAIM_TYPE,
        'med_ndc' AS CLAIM_SOURCE,
        c.CL_CODE AS CODE,
        c.CL_CODE_TYPE AS CODE_TYPE,
        c.CL_MED_ABBR AS MED_ABBR,
        c.CL_MED_CLASS AS MED_CLASS
      FROM {cdm_src(cfg$tbl_medical)} m
      INNER JOIN lot_patient_input p ON m.PATID = p.PATID
      INNER JOIN codelist c
        ON c.CL_CODE_TYPE = 'NDC'
       -- Normalize both sides to NDC11 (lpad stripped value to 11 digits with zeros)
       AND lpad(regexp_replace(coalesce(cast(m.NDC as string),''), '[^0-9]', ''), 11, '0')
         = lpad(regexp_replace(c.CL_CODE, '[^0-9]', ''), 11, '0')
      WHERE cast(m.NDC as string) IS NOT NULL AND trim(cast(m.NDC as string)) <> ''
        AND cast(m.FST_DT AS date) >= p.INDEX_DATE
        AND cast(m.FST_DT AS date) <= p.OBS_END_DT
    ),
    -- 4) med_procedure table (additional HCPCS procedure codes)
    -- NOTE: MED_PROCEDURE.PROC contains ICD codes per Optum data dict.
    -- Matching HCPCS here is a safety net; expect ~0 matches from this source.
    medproc AS (
      SELECT
        mp.PATID,
        cast(mp.FST_DT AS date) AS DATE_SERVICE,
        {cfg$medical_day_supply} AS DAY_SUPPLY,
        'medical' AS CLAIM_TYPE,
        'med_procedure' AS CLAIM_SOURCE,
        c.CL_CODE AS CODE,
        c.CL_CODE_TYPE AS CODE_TYPE,
        c.CL_MED_ABBR AS MED_ABBR,
        c.CL_MED_CLASS AS MED_CLASS
      FROM {cdm_src(cfg$tbl_med_proc)} mp
      INNER JOIN lot_patient_input p ON mp.PATID = p.PATID
      INNER JOIN codelist c
        ON c.CL_CODE_TYPE = 'HCPCS'
       AND upper(regexp_replace(coalesce(cast(mp.PROC as string),''), '[^A-Za-z0-9]', '')) = c.CL_CODE
      WHERE cast(mp.FST_DT AS date) >= p.INDEX_DATE
        AND cast(mp.FST_DT AS date) <= p.OBS_END_DT
    ),
    -- 5) Pharmacy (rx) claims (NDC)
    rx_claims AS (
      SELECT
        r.PATID,
        cast(r.FILL_DT AS date) AS DATE_SERVICE,
        cast(r.DAYS_SUP AS int) AS DAY_SUPPLY,
        'pharmacy' AS CLAIM_TYPE,
        'rx_ndc' AS CLAIM_SOURCE,
        c.CL_CODE AS CODE,
        c.CL_CODE_TYPE AS CODE_TYPE,
        c.CL_MED_ABBR AS MED_ABBR,
        c.CL_MED_CLASS AS MED_CLASS
      FROM {cdm_src(cfg$tbl_rx)} r
      INNER JOIN lot_patient_input p ON r.PATID = p.PATID
      INNER JOIN codelist c
        ON c.CL_CODE_TYPE = 'NDC'
       -- Normalize both sides to NDC11 (lpad stripped value to 11 digits with zeros)
       AND lpad(regexp_replace(coalesce(cast(r.NDC as string),''), '[^0-9]', ''), 11, '0')
         = lpad(regexp_replace(c.CL_CODE, '[^0-9]', ''), 11, '0')
      WHERE cast(r.FILL_DT AS date) >= p.INDEX_DATE
        AND cast(r.FILL_DT AS date) <= p.OBS_END_DT
    )
    SELECT * FROM med_proc_cd
    UNION ALL SELECT * FROM med_bill_proc_cd
    UNION ALL SELECT * FROM med_ndc
    UNION ALL SELECT * FROM medproc
    UNION ALL SELECT * FROM rx_claims
  "), qc = "
    SELECT
      count(*) AS n_rows,
      count(DISTINCT PATID) AS n_patients,
      count(DISTINCT MED_ABBR) AS n_meds,
      sum(case when CLAIM_TYPE='pharmacy' then 1 else 0 end) AS n_pharmacy_rows,
      sum(case when CLAIM_TYPE='medical' then 1 else 0 end) AS n_medical_rows,
      -- Source contribution audit (Item 9B: confirms each source path is active)
      sum(case when CLAIM_SOURCE='med_proc_cd' then 1 else 0 end) AS n_from_proc_cd,
      sum(case when CLAIM_SOURCE='med_bill_proc' then 1 else 0 end) AS n_from_bill_proc,
      sum(case when CLAIM_SOURCE='med_ndc' then 1 else 0 end) AS n_from_med_ndc,
      sum(case when CLAIM_SOURCE='med_procedure' then 1 else 0 end) AS n_from_med_procedure,
      sum(case when CLAIM_SOURCE='rx_ndc' then 1 else 0 end) AS n_from_rx_ndc
    FROM mma_med_raw")

  # Enrich + dedup (mma med.pdf spec)
  run_step(con, "S05_mma_med_processed", glue("
    CREATE OR REPLACE TEMPORARY VIEW mma_med_processed AS
    WITH enriched AS (
      SELECT
        r.PATID,
        r.CODE,
        r.CODE_TYPE,
        r.CLAIM_TYPE,
        r.DATE_SERVICE,
        r.DAY_SUPPLY,
        r.MED_ABBR,
        r.MED_CLASS,
        CASE WHEN coalesce(ru.CONDITIONING,0) = 1 THEN 'Yes' ELSE 'No' END AS MED_COND,
        CASE WHEN coalesce(ru.USED_FOR_OTHER_CANCERS,0) = 1 THEN 'Yes' ELSE 'No' END AS MED_OTHER_CANCER
      FROM mma_med_raw r
      LEFT JOIN mma_rollup ru
        ON r.MED_ABBR = ru.CL_MED_ABBR
    ),
    filtered AS (
      SELECT *
      FROM enriched
      WHERE NOT (CLAIM_TYPE = 'pharmacy' AND (DAY_SUPPLY IS NULL OR DAY_SUPPLY < 1))
    ),
    dedup AS (
      -- Dedup per spec: within (PATID, MED_ABBR, DATE_SERVICE, CLAIM_TYPE)
      -- keep max DAY_SUPPLY (pharmacy) or single row (medical, all 28)
      SELECT
        PATID,
        MED_ABBR,
        DATE_SERVICE,
        CLAIM_TYPE,
        max(DAY_SUPPLY) AS DAY_SUPPLY,
        -- Deterministic dedup: min() for reproducibility across runs
        min(CODE) AS CODE,
        min(CODE_TYPE) AS CODE_TYPE,
        min(MED_CLASS) AS MED_CLASS,
        min(MED_COND) AS MED_COND,
        min(MED_OTHER_CANCER) AS MED_OTHER_CANCER
      FROM filtered
      GROUP BY PATID, MED_ABBR, DATE_SERVICE, CLAIM_TYPE
    )
    SELECT * FROM dedup
  "), qc = "
    SELECT
      count(*) AS n_rows,
      sum(case when CLAIM_TYPE='pharmacy' then 1 else 0 end) AS n_pharmacy_rows,
      sum(case when CLAIM_TYPE='medical' then 1 else 0 end) AS n_medical_rows,
      min(DAY_SUPPLY) AS min_day_supply,
      max(DAY_SUPPLY) AS max_day_supply
    FROM mma_med_processed")

  # Sanity check
  bad_ds <- db_q(con, "SELECT count(*) AS n_bad FROM mma_med_processed WHERE CLAIM_TYPE='pharmacy' AND (DAY_SUPPLY IS NULL OR DAY_SUPPLY < 1)")$n_bad
  if (bad_ds > 0) stop(glue("Post-filter: found {bad_ds} pharmacy rows with invalid DAY_SUPPLY."))

  # ----------------------------------------------------------
  # STEP 3 (5B): MAP_MED - Medication Available Period algorithm
  #
  # CORRECTED per map med.pdf (page 5):
  #   "Medical runout date ... Pushout is not implemented."
  #
  # Pharmacy pushout rules (per Figure 3):
  #   - If new pharmacy claim DATE_SERVICE <= current rx_runout:
  #     pushout = rx_runout - DATE_SERVICE + 1
  #     new rx_runout = DATE_SERVICE + DAY_SUPPLY - 1 + pushout
  #   - If new pharmacy claim DATE_SERVICE > current rx_runout
  #     (but still within MAP via med_runout):
  #     rx_runout RESETS to DATE_SERVICE + DAY_SUPPLY - 1 (NO pushout)
  #
  # Medical: ALWAYS DATE_SERVICE + DAY_SUPPLY - 1 (no pushout ever)
  #
  # MAP boundary: new MAP when DATE_SERVICE > max(rx_runout, med_runout)
  # ----------------------------------------------------------
  map_struct_type <- "array<struct<MAP_CNT:int,MAP_START_DT:date,MAP_RX_RUNOUT_DT:date,MAP_MED_RUNOUT_DT:date,MAP_END_DT:date>>"
  min_date <- "cast('1900-01-01' as date)"

  run_step(con, "S06_map_med", glue("
    CREATE OR REPLACE TEMPORARY VIEW map_med AS
    WITH claims AS (
      SELECT
        PATID,
        MED_ABBR,
        MED_CLASS,
        DATE_SERVICE AS dt,
        CLAIM_TYPE  AS claim_type,
        cast(DAY_SUPPLY as int) AS ds
      FROM mma_med_processed
    ),
    grouped AS (
      SELECT
        PATID,
        MED_ABBR,
        min(MED_CLASS) AS MED_CLASS,  -- deterministic; should be 1:1 with MED_ABBR via rollup
        -- Sort: by date, then pharmacy before medical on same date (type_ord=0 for rx).
        -- Design choice: pharmacy processed first on same-day ties. This is safe because:
        --   rx pushout only depends on rx_runout (not med_runout),
        --   and medical never has pushout, so order on same day doesn't distort either.
        -- Spec doesn't mandate tie-break order; this choice is documented and deterministic.
        sort_array(collect_list(named_struct(
          'dt', dt,
          'type_ord', case when claim_type='pharmacy' then 0 else 1 end,
          'type', claim_type,
          'ds', ds
        ))) AS claims_arr
      FROM claims
      GROUP BY PATID, MED_ABBR
    ),
    maps AS (
      SELECT
        PATID,
        MED_ABBR,
        MED_CLASS,
        explode(
          aggregate(
            claims_arr,
            -- Accumulator: current MAP state
            named_struct(
              'map_cnt', 0,
              'cur_start', cast(null as date),
              'rx_runout', cast(null as date),
              'med_runout', cast(null as date),
              'maps', cast(array() as {map_struct_type})
            ),
            -- Merge function: process each claim
            (s, x) -> CASE
              -- CASE 1: First claim ever (no current MAP open)
              WHEN s.cur_start IS NULL THEN
                named_struct(
                  'map_cnt', 1,
                  'cur_start', x.dt,
                  'rx_runout', CASE WHEN x.type='pharmacy' THEN date_add(x.dt, x.ds - 1) ELSE NULL END,
                  'med_runout', CASE WHEN x.type='medical' THEN date_add(x.dt, x.ds - 1) ELSE NULL END,
                  'maps', s.maps
                )
              -- CASE 2: Claim beyond both runouts -> close current MAP, start new
              WHEN x.dt > greatest(coalesce(s.rx_runout, {min_date}), coalesce(s.med_runout, {min_date})) THEN
                named_struct(
                  'map_cnt', s.map_cnt + 1,
                  'cur_start', x.dt,
                  'rx_runout', CASE WHEN x.type='pharmacy' THEN date_add(x.dt, x.ds - 1) ELSE NULL END,
                  'med_runout', CASE WHEN x.type='medical' THEN date_add(x.dt, x.ds - 1) ELSE NULL END,
                  'maps', array_append(
                    s.maps,
                    named_struct(
                      'MAP_CNT', s.map_cnt,
                      'MAP_START_DT', s.cur_start,
                      'MAP_RX_RUNOUT_DT', s.rx_runout,
                      'MAP_MED_RUNOUT_DT', s.med_runout,
                      'MAP_END_DT', greatest(coalesce(s.rx_runout, {min_date}), coalesce(s.med_runout, {min_date}))
                    )
                  )
                )
              -- CASE 3: Claim within current MAP -> update runouts
              ELSE
                named_struct(
                  'map_cnt', s.map_cnt,
                  'cur_start', s.cur_start,
                  -- PHARMACY RUNOUT UPDATE
                  'rx_runout', CASE
                    WHEN x.type='pharmacy' THEN
                      CASE
                        -- First pharmacy claim in this MAP
                        WHEN s.rx_runout IS NULL THEN date_add(x.dt, x.ds - 1)
                        -- Pharmacy claim WITHIN current rx coverage -> PUSHOUT
                        -- pushout = rx_runout - DATE_SERVICE + 1
                        -- new rx_runout = DATE_SERVICE + DS - 1 + pushout = rx_runout + DS
                        WHEN x.dt <= s.rx_runout THEN
                          date_add(s.rx_runout, x.ds)
                        -- Pharmacy claim AFTER rx_runout but still in MAP (via med_runout)
                        -- -> RESET without pushout (per Figure 3, iteration 4)
                        ELSE
                          date_add(x.dt, x.ds - 1)
                      END
                    -- Not a pharmacy claim: rx_runout unchanged
                    ELSE s.rx_runout
                  END,
                  -- MEDICAL RUNOUT UPDATE
                  -- Per map med.pdf page 5: "Pushout is not implemented" for medical.
                  -- Always: DATE_SERVICE + DAY_SUPPLY - 1.
                  -- greatest() is a safety belt: if a same-day or out-of-order claim
                  -- produces an earlier runout, we keep the existing later one.
                  'med_runout', CASE
                    WHEN x.type='medical' THEN
                      CASE
                        WHEN s.med_runout IS NULL THEN date_add(x.dt, x.ds - 1)
                        ELSE greatest(s.med_runout, date_add(x.dt, x.ds - 1))
                      END
                    ELSE s.med_runout
                  END,
                  'maps', s.maps
                )
            END,
            -- Finalize: flush the last open MAP
            s -> CASE
              WHEN s.cur_start IS NULL THEN cast(array() as {map_struct_type})
              ELSE array_append(
                s.maps,
                named_struct(
                  'MAP_CNT', s.map_cnt,
                  'MAP_START_DT', s.cur_start,
                  'MAP_RX_RUNOUT_DT', s.rx_runout,
                  'MAP_MED_RUNOUT_DT', s.med_runout,
                  'MAP_END_DT', greatest(coalesce(s.rx_runout, {min_date}), coalesce(s.med_runout, {min_date}))
                )
              )
            END
          )
        ) AS map_rec
      FROM grouped
    ),
    base AS (
      SELECT
        m.PATID,
        m.MED_ABBR,
        m.MED_CLASS,
        map_rec.MAP_CNT           AS MAP_CNT,
        map_rec.MAP_START_DT      AS MAP_START_DT,
        map_rec.MAP_RX_RUNOUT_DT  AS MAP_RX_RUNOUT_DT,
        map_rec.MAP_MED_RUNOUT_DT AS MAP_MED_RUNOUT_DT,
        CASE WHEN map_rec.MAP_END_DT = {min_date} THEN NULL ELSE map_rec.MAP_END_DT END AS MAP_END_DT
      FROM maps m
    ),
    with_next AS (
      SELECT
        b.*,
        lead(MAP_START_DT) OVER (PARTITION BY PATID, MED_ABBR ORDER BY MAP_CNT) AS NEXT_MAP_START_DT
      FROM base b
    )
    SELECT
      w.PATID,
      w.MED_ABBR,
      w.MED_CLASS,
      w.MAP_CNT,
      w.MAP_START_DT,
      w.MAP_RX_RUNOUT_DT,
      w.MAP_MED_RUNOUT_DT,
      w.MAP_END_DT,
      w.MED_ABBR AS MAP_MED_TYPE,
      w.MED_CLASS AS MAP_MED_CLASS,
      CASE
        WHEN w.NEXT_MAP_START_DT IS NOT NULL
          AND datediff(w.NEXT_MAP_START_DT, w.MAP_END_DT) >= {cfg$map_discon_gap_days}
          THEN 1
        WHEN w.NEXT_MAP_START_DT IS NULL
          AND datediff(p.OBS_END_DT, w.MAP_END_DT) >= {cfg$map_discon_gap_days}
          THEN 1
        ELSE 0
      END AS MAP_DISCON_FLG
    FROM with_next w
    INNER JOIN lot_patient_input p ON w.PATID = p.PATID
    WHERE w.MAP_END_DT IS NOT NULL
  "), qc = "
    SELECT
      count(*) AS n_maps,
      count(DISTINCT PATID) AS n_patients,
      count(DISTINCT MED_ABBR) AS n_meds,
      avg(datediff(MAP_END_DT, MAP_START_DT) + 1) AS avg_map_len_days,
      sum(MAP_DISCON_FLG) AS n_discontinuations
    FROM map_med")

  # ----------------------------------------------------------
  # STEP 4: MAP_STACKED
  # ----------------------------------------------------------
  run_step(con, "S07_map_stacked", "
    CREATE OR REPLACE TEMPORARY VIEW map_stacked AS
    SELECT * FROM map_med
  ", qc = "SELECT count(*) AS n_rows FROM map_stacked")

  # ----------------------------------------------------------
  # STEP 5 (6): LOT1_BASE
  # ----------------------------------------------------------
  run_step(con, "S08_lot1_start", "
    CREATE OR REPLACE TEMPORARY VIEW lot1_start AS
    SELECT
      ms.PATID,
      min(ms.MAP_START_DT) AS LOT1_START_DT
    FROM map_stacked ms
    WHERE ms.MAP_MED_CLASS <> 'STEROID'
    GROUP BY ms.PATID
  ", qc = "SELECT count(*) AS n_patients_with_lot1, min(LOT1_START_DT) AS min_lot1_start, max(LOT1_START_DT) AS max_lot1_start FROM lot1_start")

  run_step(con, "S09_lot1_induction_meds", glue("
    CREATE OR REPLACE TEMPORARY VIEW lot1_induction_meds AS
    SELECT DISTINCT
      ms.PATID,
      l1.LOT1_START_DT,
      ms.MAP_MED_TYPE AS MED_ABBR,
      ms.MAP_MED_CLASS AS MED_CLASS
    FROM map_stacked ms
    INNER JOIN lot1_start l1
      ON ms.PATID = l1.PATID
    WHERE ms.MAP_START_DT >= l1.LOT1_START_DT
      AND ms.MAP_START_DT <= date_add(l1.LOT1_START_DT, {cfg$induction_window_days - 1})
  "), qc = "
    SELECT count(*) AS n_rows, count(DISTINCT PATID) AS n_patients, avg(cnt) AS avg_induction_meds
    FROM (SELECT PATID, count(DISTINCT MED_ABBR) AS cnt FROM lot1_induction_meds GROUP BY PATID)")

  # LOT1 BASE: induction meds + permissible subs, discon, first add
  run_step(con, "S10_lot1_base", glue("
    CREATE OR REPLACE TEMPORARY VIEW lot1_base AS
    WITH base_meds AS (
      SELECT PATID, MED_ABBR
      FROM lot1_induction_meds
      UNION
      SELECT im.PATID, ps.substitute_med AS MED_ABBR
      FROM lot1_induction_meds im
      INNER JOIN permissible_subs ps
        ON im.MED_ABBR = ps.original_med
    ),
    -- DECISION: Steroid MAPs are included in base_meds (per spec: induction includes
    -- all meds in the window including steroids). This means steroid MAPs can extend
    -- LOT1_BASE_DISCON_DT. If stakeholders prefer to exclude steroids from the
    -- discontinuation computation (common analytic tweak), filter base_meds above
    -- to exclude steroid MED_CLASS, but keep steroid flags in LOT1_BASE_MEDS.
    discon_raw AS (
      SELECT
        ms.PATID,
        max(ms.MAP_END_DT) AS RAW_DISCON_DT
      FROM map_stacked ms
      INNER JOIN lot1_start l1 ON ms.PATID = l1.PATID
      INNER JOIN base_meds bm
        ON ms.PATID = bm.PATID
       AND ms.MAP_MED_TYPE = bm.MED_ABBR
      WHERE ms.MAP_START_DT >= l1.LOT1_START_DT
      GROUP BY ms.PATID
    ),
    discon AS (
      SELECT
        p.PATID,
        CASE
          WHEN d.RAW_DISCON_DT IS NOT NULL AND datediff(p.OBS_END_DT, d.RAW_DISCON_DT) >= {cfg$lot_discon_gap_days}
            THEN d.RAW_DISCON_DT
          ELSE NULL
        END AS LOT1_BASE_DISCON_DT
      FROM lot_patient_input p
      LEFT JOIN discon_raw d ON p.PATID = d.PATID
    ),
    med_summary AS (
      SELECT
        im.PATID,
        min(im.LOT1_START_DT) AS LOT1_START_DT,  -- same for all rows per PATID; min for determinism
        count(DISTINCT im.MED_ABBR) AS LOT1_MED_CNT,
        concat_ws(' ', sort_array(collect_set(im.MED_ABBR))) AS LOT1_BASE_MEDS,
        {med_flag_exprs},
        {class_flag_exprs}
      FROM lot1_induction_meds im
      GROUP BY im.PATID
    ),
    base_core AS (
      SELECT
        p.PATID,
        p.INDEX_DATE,
        p.ENDDATE,
        p.OBS_END_DT,
        p.DEATH_DT,
        p.GDR_CD,
        p.YRDOB,
        p.AGE_INDEX_YR,
        ms.LOT1_START_DT,
        ms.LOT1_MED_CNT,
        ms.LOT1_BASE_MEDS,
        d.LOT1_BASE_DISCON_DT,
        CASE
          WHEN d.LOT1_BASE_DISCON_DT IS NOT NULL THEN datediff(d.LOT1_BASE_DISCON_DT, ms.LOT1_START_DT) + 1
          ELSE datediff(p.OBS_END_DT, ms.LOT1_START_DT) + 1
        END AS LOT1_BASE_LENGTH,
        {paste0('ms.', paste(c(paste0('LOT1_MED_', vapply(meds, sanitize_col, character(1))), paste0('LOT1_CLASS_', vapply(classes, sanitize_class, character(1)))), collapse = ', ms.'))}
      FROM lot_patient_input p
      INNER JOIN med_summary ms ON p.PATID = ms.PATID
      LEFT JOIN discon d ON p.PATID = d.PATID
    ),
    first_add_candidates AS (
      SELECT
        ms.PATID,
        ms.MAP_START_DT,
        ms.MAP_MED_TYPE
      FROM map_stacked ms
      INNER JOIN base_core bc ON ms.PATID = bc.PATID
      LEFT JOIN base_meds bm
        ON ms.PATID = bm.PATID AND ms.MAP_MED_TYPE = bm.MED_ABBR
      WHERE bm.MED_ABBR IS NULL
        AND ms.MAP_START_DT >= bc.LOT1_START_DT
        AND ms.MAP_START_DT <= coalesce(bc.LOT1_BASE_DISCON_DT, bc.OBS_END_DT)
        -- NOTE: Steroids excluded as add-meds per clinical convention; confirm with spec owner
        AND ms.MAP_MED_CLASS <> 'STEROID'
    ),
    first_add_dt AS (
      SELECT PATID, min(MAP_START_DT) AS ADD_START_DT
      FROM first_add_candidates
      GROUP BY PATID
    ),
    first_add_pick AS (
      SELECT
        c.PATID,
        date_sub(d.ADD_START_DT, 1) AS LOT1_BASE_1ST_ADD_MED_DT,
        -- Spec says "random" for same-day ties; we use min() for determinism (deliberate deviation)
        min(c.MAP_MED_TYPE) AS LOT1_BASE_1ST_ADD_MED
      FROM first_add_candidates c
      INNER JOIN first_add_dt d
        ON c.PATID = d.PATID AND c.MAP_START_DT = d.ADD_START_DT
      GROUP BY c.PATID, d.ADD_START_DT
    )
    SELECT
      bc.*,
      fa.LOT1_BASE_1ST_ADD_MED_DT,
      fa.LOT1_BASE_1ST_ADD_MED
    FROM base_core bc
    LEFT JOIN first_add_pick fa
      ON bc.PATID = fa.PATID
  "), qc = "
    SELECT
      count(*) AS n_patients,
      avg(LOT1_MED_CNT) AS avg_induction_meds,
      avg(LOT1_BASE_LENGTH) AS avg_base_length,
      sum(case when LOT1_BASE_DISCON_DT is not null then 1 else 0 end) as n_with_discon_dt,
      sum(case when LOT1_BASE_1ST_ADD_MED_DT is not null then 1 else 0 end) as n_with_add_med
    FROM lot1_base")

  # ----------------------------------------------------------
  # STEP 7 (SCT): Stem Cell Transplant detection
  # Per sct.pdf spec section 7:
  #   - AUTO: 14-day window grouping + 60-day gap + 180-day tandem
  #   - ALLO/CART: simple sequential dates
  #   - ALLO/CART immediately end LOT1
  #   - Single AUTO allowed; tandem pair allowed; excess AUTO ends LOT1
  #
  # NOTE: Maintenance (mono/dual) specs not yet provided.
  # ----------------------------------------------------------

  # S11: Register SCT codelist
  run_step(con, "S11_sct_codelist", glue("
    CREATE OR REPLACE TEMPORARY VIEW sct_codelist AS
    SELECT
      upper(trim(CL_CODE_TYPE)) AS CL_CODE_TYPE,
      upper(regexp_replace(trim(CL_CODE), '[^A-Za-z0-9]', '')) AS CL_CODE,
      upper(trim(SCT_TYPE)) AS SCT_TYPE
    FROM {sct_src}
    WHERE CL_CODE IS NOT NULL AND trim(CL_CODE) <> ''
      AND SCT_TYPE IS NOT NULL AND trim(SCT_TYPE) <> ''
  "), qc = "SELECT SCT_TYPE, count(*) AS n_codes FROM sct_codelist GROUP BY SCT_TYPE ORDER BY SCT_TYPE")

  # S12: Extract raw SCT claims from MEDICAL + MED_PROCEDURE
  run_step(con, "S12_sct_claims_raw", glue("
    CREATE OR REPLACE TEMPORARY VIEW sct_claims_raw AS
    WITH sct_codes AS (
      SELECT /*+ BROADCAST */ * FROM sct_codelist
    ),
    -- Medical PROC_CD (contains CPT/HCPCS per Optum business rules)
    med_proc AS (
      SELECT m.PATID, cast(m.FST_DT AS date) AS DATE_SERVICE,
             s.SCT_TYPE, s.CL_CODE AS CODE, 'med_proc_cd' AS SRC
      FROM {cdm_src(cfg$tbl_medical)} m
      INNER JOIN lot_patient_input p ON m.PATID = p.PATID
      INNER JOIN sct_codes s
        ON s.CL_CODE_TYPE = 'HCPCS'
       AND upper(regexp_replace(coalesce(cast(m.PROC_CD as string),''), '[^A-Za-z0-9]', '')) = s.CL_CODE
      WHERE cast(m.FST_DT AS date) >= p.INDEX_DATE
        AND cast(m.FST_DT AS date) <= p.OBS_END_DT
    ),
    -- Medical BILL_PROC_CD (also CPT/HCPCS per Optum business rules)
    med_bill AS (
      SELECT m.PATID, cast(m.FST_DT AS date) AS DATE_SERVICE,
             s.SCT_TYPE, s.CL_CODE AS CODE, 'med_bill_proc' AS SRC
      FROM {cdm_src(cfg$tbl_medical)} m
      INNER JOIN lot_patient_input p ON m.PATID = p.PATID
      INNER JOIN sct_codes s
        ON s.CL_CODE_TYPE = 'HCPCS'
       AND upper(regexp_replace(coalesce(cast(m.BILL_PROC_CD as string),''), '[^A-Za-z0-9]', '')) = s.CL_CODE
      WHERE cast(m.FST_DT AS date) >= p.INDEX_DATE
        AND cast(m.FST_DT AS date) <= p.OBS_END_DT
    ),
    -- MED_PROCEDURE PROC
    -- NOTE: Per Optum business rules, MED_PROCEDURE.PROC typically contains
    -- ICD-9/ICD-10 procedure codes, not CPT/HCPCS. Matching HCPCS SCT codes
    -- here is a safety net (consistent with MMA_MED extraction) but may not
    -- produce matches. If ICD-10-PCS SCT codes are needed (e.g. 30233G1 for
    -- autologous SCT), add them to the SCT codelist with CL_CODE_TYPE='ICD'.
    medproc AS (
      SELECT mp.PATID, cast(mp.FST_DT AS date) AS DATE_SERVICE,
             s.SCT_TYPE, s.CL_CODE AS CODE, 'med_procedure' AS SRC
      FROM {cdm_src(cfg$tbl_med_proc)} mp
      INNER JOIN lot_patient_input p ON mp.PATID = p.PATID
      INNER JOIN sct_codes s
        ON s.CL_CODE_TYPE IN ('HCPCS', 'ICD')
       AND upper(regexp_replace(coalesce(cast(mp.PROC as string),''), '[^A-Za-z0-9]', '')) = s.CL_CODE
      WHERE cast(mp.FST_DT AS date) >= p.INDEX_DATE
        AND cast(mp.FST_DT AS date) <= p.OBS_END_DT
    ),
    combined AS (
      SELECT * FROM med_proc
      UNION ALL SELECT * FROM med_bill
      UNION ALL SELECT * FROM medproc
    )
    -- Deduplicate: one record per (PATID, DATE_SERVICE, SCT_TYPE)
    SELECT PATID, DATE_SERVICE, SCT_TYPE, min(CODE) AS CODE
    FROM combined
    GROUP BY PATID, DATE_SERVICE, SCT_TYPE
  "), qc = "
    SELECT SCT_TYPE, count(*) AS n_claims, count(DISTINCT PATID) AS n_patients,
           min(DATE_SERVICE) AS min_date, max(DATE_SERVICE) AS max_date
    FROM sct_claims_raw
    GROUP BY SCT_TYPE
    ORDER BY SCT_TYPE")

  # NOTE: SCT CTEs include SRC column for debug traceability (dropped during dedup).
  # To audit source contributions, query the combined CTE directly before dedup.

  # S13: AUTO SCT date processing (per sct.pdf)
  #
  # Step 1: Group AUTO claims into 14-day windows (claims within 14 days of
  #         window start are in same window). Per spec, select the LAST (max)
  #         date in each window, NOT the first -- first claims are workup
  #         activity, last claim is the actual transplant.
  #
  # Tandem boundary adjustment: when a 14-day window overlaps the 180-day
  # tandem boundary (from the previous finalized TX date), select the date
  # closest to the boundary rather than the window max. This ensures accurate
  # tandem determination. Computed as min |date - boundary| over all dates
  # in the window. (See sct.pdf example: TX_AUTO1=09MAY2018, 180-day mark
  # ~05NOV2018, window 06NOV-20NOV picks 07NOV instead of 20NOV.)
  #
  # Step 2: Apply 60-day minimum gap between events (merge if < 60 days apart).
  # Result: finalized TX dates for AUTO SCT per patient.
  run_step(con, "S13_tx_auto_dates", glue("
    CREATE OR REPLACE TEMPORARY VIEW tx_auto_dates AS
    WITH auto_dates AS (
      SELECT DISTINCT PATID, DATE_SERVICE AS dt
      FROM sct_claims_raw
      WHERE SCT_TYPE = 'AUTO'
    ),
    grouped AS (
      SELECT PATID,
             sort_array(collect_list(dt)) AS dates_arr
      FROM auto_dates
      GROUP BY PATID
    ),
    -- Phase 1 + 2 combined: 14-day windowing with tandem-aware date selection
    -- + 60-day gap merging in a single pass.
    --
    -- State tracks:
    --   tx_dates: finalized TX dates array
    --   cur_start: start of current 14-day window (first date in window)
    --   cur_max_dt: last (max) date in current window (default selection)
    --   cur_boundary_dt: date in window closest to tandem boundary
    --   cur_boundary_dist: abs distance of cur_boundary_dt to tandem boundary
    --   last_tx_dt: last finalized TX date (for tandem boundary + 60-day gap)
    processed AS (
      SELECT PATID,
        aggregate(
          dates_arr,
          named_struct(
            'tx_dates', cast(array() as array<date>),
            'cur_start', cast(null as date),
            'cur_max_dt', cast(null as date),
            'cur_boundary_dt', cast(null as date),
            'cur_boundary_dist', cast(null as int),
            'last_tx_dt', cast(null as date)
          ),
          (s, x) -> CASE
            -- First claim ever: start first window
            WHEN s.cur_start IS NULL THEN
              named_struct(
                'tx_dates', s.tx_dates,
                'cur_start', x,
                'cur_max_dt', x,
                'cur_boundary_dt', cast(null as date),
                'cur_boundary_dist', cast(null as int),
                'last_tx_dt', s.last_tx_dt
              )
            -- Within 14-day window: update max + tandem boundary tracking
            WHEN datediff(x, s.cur_start) <= {cfg$sct_auto_window_days} THEN
              named_struct(
                'tx_dates', s.tx_dates,
                'cur_start', s.cur_start,
                'cur_max_dt', x,  -- x >= cur_max_dt since sorted
                -- Track date closest to tandem boundary, BUT only when date is
                -- within window_days of the boundary (i.e., window overlaps or
                -- is adjacent to the 180-day mark). When far from boundary,
                -- cur_boundary_dt stays NULL so coalesce() falls back to max.
                'cur_boundary_dt', CASE
                  WHEN s.last_tx_dt IS NULL THEN NULL
                  WHEN abs(datediff(x, date_add(s.last_tx_dt, {cfg$sct_tandem_days} - 1)))
                       <= {cfg$sct_auto_window_days}
                   AND (s.cur_boundary_dist IS NULL
                        OR abs(datediff(x, date_add(s.last_tx_dt, {cfg$sct_tandem_days} - 1)))
                           < s.cur_boundary_dist)
                    THEN x
                  WHEN s.cur_boundary_dt IS NOT NULL THEN s.cur_boundary_dt
                  ELSE NULL
                END,
                'cur_boundary_dist', CASE
                  WHEN s.last_tx_dt IS NULL THEN NULL
                  WHEN abs(datediff(x, date_add(s.last_tx_dt, {cfg$sct_tandem_days} - 1)))
                       <= {cfg$sct_auto_window_days}
                   AND (s.cur_boundary_dist IS NULL
                        OR abs(datediff(x, date_add(s.last_tx_dt, {cfg$sct_tandem_days} - 1)))
                           < s.cur_boundary_dist)
                    THEN abs(datediff(x, date_add(s.last_tx_dt, {cfg$sct_tandem_days} - 1)))
                  WHEN s.cur_boundary_dist IS NOT NULL THEN s.cur_boundary_dist
                  ELSE NULL
                END,
                'last_tx_dt', s.last_tx_dt
              )
            -- Beyond 14-day window: finalize current window, start new
            ELSE
              -- Select date: use boundary-closest if tandem boundary active, else max
              -- Then apply 60-day gap: only keep if >= 60 days from last_tx_dt
              CASE
                WHEN s.last_tx_dt IS NOT NULL
                 AND datediff(
                       coalesce(s.cur_boundary_dt, s.cur_max_dt),
                       s.last_tx_dt
                     ) < {cfg$sct_auto_gap_days}
                THEN
                  -- Too close to last TX: discard window, start new
                  named_struct(
                    'tx_dates', s.tx_dates,
                    'cur_start', x,
                    'cur_max_dt', x,
                    -- Only init boundary tracking if x is near the boundary
                    'cur_boundary_dt', CASE
                      WHEN s.last_tx_dt IS NOT NULL
                       AND abs(datediff(x, date_add(s.last_tx_dt, {cfg$sct_tandem_days} - 1)))
                           <= {cfg$sct_auto_window_days}
                      THEN x
                      ELSE NULL
                    END,
                    'cur_boundary_dist', CASE
                      WHEN s.last_tx_dt IS NOT NULL
                       AND abs(datediff(x, date_add(s.last_tx_dt, {cfg$sct_tandem_days} - 1)))
                           <= {cfg$sct_auto_window_days}
                      THEN abs(datediff(x, date_add(s.last_tx_dt, {cfg$sct_tandem_days} - 1)))
                      ELSE NULL
                    END,
                    'last_tx_dt', s.last_tx_dt
                  )
                ELSE
                  -- Valid TX: finalize and start new window
                  named_struct(
                    'tx_dates', array_append(
                      s.tx_dates,
                      coalesce(s.cur_boundary_dt, s.cur_max_dt)
                    ),
                    'cur_start', x,
                    'cur_max_dt', x,
                    -- Init boundary tracking relative to newly finalized TX
                    'cur_boundary_dt', CASE
                      WHEN abs(datediff(
                             x,
                             date_add(coalesce(s.cur_boundary_dt, s.cur_max_dt), {cfg$sct_tandem_days} - 1)
                           )) <= {cfg$sct_auto_window_days}
                      THEN x
                      ELSE NULL
                    END,
                    'cur_boundary_dist', CASE
                      WHEN abs(datediff(
                             x,
                             date_add(coalesce(s.cur_boundary_dt, s.cur_max_dt), {cfg$sct_tandem_days} - 1)
                           )) <= {cfg$sct_auto_window_days}
                      THEN abs(datediff(
                             x,
                             date_add(coalesce(s.cur_boundary_dt, s.cur_max_dt), {cfg$sct_tandem_days} - 1)
                           ))
                      ELSE NULL
                    END,
                    'last_tx_dt', coalesce(s.cur_boundary_dt, s.cur_max_dt)
                  )
                END
          END,
          -- Finalize: flush last open window
          s -> CASE
            WHEN s.cur_start IS NULL THEN s.tx_dates
            -- Apply 60-day gap check for last window
            WHEN s.last_tx_dt IS NOT NULL
             AND datediff(
                   coalesce(s.cur_boundary_dt, s.cur_max_dt),
                   s.last_tx_dt
                 ) < {cfg$sct_auto_gap_days}
            THEN s.tx_dates
            ELSE array_append(
              s.tx_dates,
              coalesce(s.cur_boundary_dt, s.cur_max_dt)
            )
          END
        ) AS tx_dates
      FROM grouped
    ),
    exploded AS (
      SELECT PATID, posexplode(tx_dates) AS (pos, TX_DT)
      FROM processed
    )
    SELECT PATID, pos + 1 AS TX_SEQ, TX_DT
    FROM exploded
  "), qc = "
    SELECT count(*) AS n_auto_tx_events, count(DISTINCT PATID) AS n_patients,
           min(TX_SEQ) AS min_seq, max(TX_SEQ) AS max_seq
    FROM tx_auto_dates")

  # S14: ALLO and CART sequential dates (simple ordering)
  run_step(con, "S14_tx_allo_cart_dates", "
    CREATE OR REPLACE TEMPORARY VIEW tx_allo_cart_dates AS
    WITH allo_dates AS (
      SELECT DISTINCT PATID, DATE_SERVICE AS dt
      FROM sct_claims_raw
      WHERE SCT_TYPE = 'ALLO'
    ),
    cart_dates AS (
      SELECT DISTINCT PATID, DATE_SERVICE AS dt
      FROM sct_claims_raw
      WHERE SCT_TYPE = 'CART'
    ),
    allo_seq AS (
      SELECT PATID, 'ALLO' AS SCT_TYPE, dt AS TX_DT,
             row_number() OVER (PARTITION BY PATID ORDER BY dt) AS TX_SEQ
      FROM allo_dates
    ),
    cart_seq AS (
      SELECT PATID, 'CART' AS SCT_TYPE, dt AS TX_DT,
             row_number() OVER (PARTITION BY PATID ORDER BY dt) AS TX_SEQ
      FROM cart_dates
    )
    SELECT * FROM allo_seq
    UNION ALL
    SELECT * FROM cart_seq
  ", qc = "
    SELECT SCT_TYPE, count(*) AS n_events, count(DISTINCT PATID) AS n_patients
    FROM tx_allo_cart_dates
    GROUP BY SCT_TYPE
    ORDER BY SCT_TYPE")

  # S15: LOT1 SCT variables
  # Derives: LOT1_TX_AUTO_DT_1/2, TAND_FLG, SING_FLG,
  #          LOT1_TX_ENDDATE, LOT1_TX_ENDDATE_REASON, LOT1_1ST_SCT_DT
  run_step(con, "S15_lot1_sct", glue("
    CREATE OR REPLACE TEMPORARY VIEW lot1_sct AS
    WITH lot1 AS (
      SELECT PATID, LOT1_START_DT, OBS_END_DT FROM lot1_base
    ),
    -- AUTO dates within LOT1 observation window
    auto_in_lot1 AS (
      SELECT a.PATID, a.TX_DT,
             row_number() OVER (PARTITION BY a.PATID ORDER BY a.TX_DT) AS LOT1_SEQ
      FROM tx_auto_dates a
      INNER JOIN lot1 l ON a.PATID = l.PATID
      WHERE a.TX_DT >= l.LOT1_START_DT
        AND a.TX_DT <= l.OBS_END_DT
    ),
    auto_pivot AS (
      SELECT PATID,
        max(CASE WHEN LOT1_SEQ = 1 THEN TX_DT END) AS AUTO_DT_1,
        max(CASE WHEN LOT1_SEQ = 2 THEN TX_DT END) AS AUTO_DT_2,
        max(CASE WHEN LOT1_SEQ = 3 THEN TX_DT END) AS AUTO_DT_3
      FROM auto_in_lot1
      GROUP BY PATID
    ),
    -- First ALLO date within LOT1
    first_allo AS (
      SELECT ac.PATID, min(ac.TX_DT) AS ALLO_DT
      FROM tx_allo_cart_dates ac
      INNER JOIN lot1 l ON ac.PATID = l.PATID
      WHERE ac.SCT_TYPE = 'ALLO'
        AND ac.TX_DT >= l.LOT1_START_DT
        AND ac.TX_DT <= l.OBS_END_DT
      GROUP BY ac.PATID
    ),
    -- First CART date within LOT1
    first_cart AS (
      SELECT ac.PATID, min(ac.TX_DT) AS CART_DT
      FROM tx_allo_cart_dates ac
      INNER JOIN lot1 l ON ac.PATID = l.PATID
      WHERE ac.SCT_TYPE = 'CART'
        AND ac.TX_DT >= l.LOT1_START_DT
        AND ac.TX_DT <= l.OBS_END_DT
      GROUP BY ac.PATID
    ),
    -- Check for ALLO between AUTO_DT_1 and AUTO_DT_2 (tandem disqualifier)
    allo_between AS (
      SELECT ap.PATID,
        sum(CASE WHEN ac.TX_DT > ap.AUTO_DT_1 AND ac.TX_DT < ap.AUTO_DT_2
                 THEN 1 ELSE 0 END) AS n_allo_between
      FROM auto_pivot ap
      LEFT JOIN tx_allo_cart_dates ac
        ON ap.PATID = ac.PATID AND ac.SCT_TYPE = 'ALLO'
      WHERE ap.AUTO_DT_2 IS NOT NULL
      GROUP BY ap.PATID
    ),
    -- Derive tandem flag and LOT-ending AUTO date
    sct_derived AS (
      SELECT
        l.PATID,
        ap.AUTO_DT_1 AS LOT1_TX_AUTO_DT_1,
        ap.AUTO_DT_2 AS LOT1_TX_AUTO_DT_2,
        -- Tandem: two AUTO SCTs within 180 days, no ALLO between
        CASE
          WHEN ap.AUTO_DT_2 IS NOT NULL
           AND datediff(ap.AUTO_DT_2, ap.AUTO_DT_1) + 1 <= {cfg$sct_tandem_days}
           AND coalesce(ab.n_allo_between, 0) = 0
          THEN 1 ELSE 0
        END AS LOT1_SCT_AUTO_TAND_FLG,
        -- Single AUTO: has first AUTO but not a valid tandem
        CASE
          WHEN ap.AUTO_DT_1 IS NOT NULL
           AND NOT (ap.AUTO_DT_2 IS NOT NULL
                    AND datediff(ap.AUTO_DT_2, ap.AUTO_DT_1) + 1 <= {cfg$sct_tandem_days}
                    AND coalesce(ab.n_allo_between, 0) = 0)
          THEN 1 ELSE 0
        END AS LOT1_SCT_AUTO_SING_FLG,
        -- LOT-ending AUTO: excess AUTO beyond what's allowed
        -- Tandem -> 3rd AUTO ends LOT1; Single -> 2nd AUTO ends LOT1
        CASE
          WHEN ap.AUTO_DT_2 IS NOT NULL
           AND datediff(ap.AUTO_DT_2, ap.AUTO_DT_1) + 1 <= {cfg$sct_tandem_days}
           AND coalesce(ab.n_allo_between, 0) = 0
          THEN ap.AUTO_DT_3
          WHEN ap.AUTO_DT_1 IS NOT NULL
          THEN ap.AUTO_DT_2
          ELSE NULL
        END AS ENDING_AUTO_DT,
        fa.ALLO_DT AS FIRST_ALLO_DT,
        fc.CART_DT AS FIRST_CART_DT
      FROM lot1 l
      LEFT JOIN auto_pivot ap ON l.PATID = ap.PATID
      LEFT JOIN allo_between ab ON l.PATID = ab.PATID
      LEFT JOIN first_allo fa ON l.PATID = fa.PATID
      LEFT JOIN first_cart fc ON l.PATID = fc.PATID
    )
    SELECT
      sd.*,
      -- LOT1_TX_ENDDATE: earliest LOT-ending SCT event - 1 day
      CASE
        WHEN coalesce(sd.ENDING_AUTO_DT, sd.FIRST_ALLO_DT, sd.FIRST_CART_DT) IS NOT NULL
        THEN date_sub(
          least(
            coalesce(sd.ENDING_AUTO_DT, cast('9999-12-31' as date)),
            coalesce(sd.FIRST_ALLO_DT,  cast('9999-12-31' as date)),
            coalesce(sd.FIRST_CART_DT,   cast('9999-12-31' as date))
          ), 1)
        ELSE NULL
      END AS LOT1_TX_ENDDATE,
      -- LOT1_TX_ENDDATE_REASON: 1=AUTO, 2=ALLO, 3=CART (whichever is earliest)
      CASE
        WHEN coalesce(sd.ENDING_AUTO_DT, sd.FIRST_ALLO_DT, sd.FIRST_CART_DT) IS NULL THEN NULL
        WHEN coalesce(sd.ENDING_AUTO_DT, cast('9999-12-31' as date))
             <= coalesce(sd.FIRST_ALLO_DT, cast('9999-12-31' as date))
         AND coalesce(sd.ENDING_AUTO_DT, cast('9999-12-31' as date))
             <= coalesce(sd.FIRST_CART_DT, cast('9999-12-31' as date))
        THEN 1
        WHEN coalesce(sd.FIRST_ALLO_DT, cast('9999-12-31' as date))
             <= coalesce(sd.FIRST_CART_DT, cast('9999-12-31' as date))
        THEN 2
        ELSE 3
      END AS LOT1_TX_ENDDATE_REASON,
      -- LOT1_1ST_SCT_DT: first SCT of any type during LOT1
      CASE
        WHEN coalesce(sd.LOT1_TX_AUTO_DT_1, sd.FIRST_ALLO_DT, sd.FIRST_CART_DT) IS NOT NULL
        THEN least(
          coalesce(sd.LOT1_TX_AUTO_DT_1, cast('9999-12-31' as date)),
          coalesce(sd.FIRST_ALLO_DT,     cast('9999-12-31' as date)),
          coalesce(sd.FIRST_CART_DT,      cast('9999-12-31' as date))
        )
        ELSE NULL
      END AS LOT1_1ST_SCT_DT
    FROM sct_derived sd
  "), qc = "
    SELECT
      count(*) AS n_patients,
      sum(CASE WHEN LOT1_TX_AUTO_DT_1 IS NOT NULL THEN 1 ELSE 0 END) AS n_with_auto,
      sum(CASE WHEN FIRST_ALLO_DT IS NOT NULL THEN 1 ELSE 0 END) AS n_with_allo,
      sum(CASE WHEN FIRST_CART_DT IS NOT NULL THEN 1 ELSE 0 END) AS n_with_cart,
      sum(LOT1_SCT_AUTO_TAND_FLG) AS n_tandem,
      sum(LOT1_SCT_AUTO_SING_FLG) AS n_single_auto,
      sum(CASE WHEN LOT1_TX_ENDDATE IS NOT NULL THEN 1 ELSE 0 END) AS n_with_sct_end
    FROM lot1_sct")

  # S16: LOT1_BASE_END - Final end reason incorporating SCT
  # End reason priority: SCT > MED_ADD > DISCONTINUATION > CENSORED
  # SCT takes highest priority because it definitively ends the LOT.
  run_step(con, "S16_lot1_base_end", "
    CREATE OR REPLACE TEMPORARY VIEW lot1_base_end AS
    SELECT
      lb.*,
      sct.LOT1_TX_AUTO_DT_1,
      sct.LOT1_TX_AUTO_DT_2,
      sct.LOT1_SCT_AUTO_TAND_FLG,
      sct.LOT1_SCT_AUTO_SING_FLG,
      sct.LOT1_TX_ENDDATE,
      sct.LOT1_TX_ENDDATE_REASON,
      sct.LOT1_1ST_SCT_DT,
      sct.FIRST_ALLO_DT,
      sct.FIRST_CART_DT,
      -- End reason: SCT > MED_ADD (at or before discon) > DISCONTINUATION > CENSORED
      CASE
        WHEN sct.LOT1_TX_ENDDATE IS NOT NULL
         AND (lb.LOT1_BASE_1ST_ADD_MED_DT IS NULL OR sct.LOT1_TX_ENDDATE <= lb.LOT1_BASE_1ST_ADD_MED_DT)
         AND (lb.LOT1_BASE_DISCON_DT IS NULL OR sct.LOT1_TX_ENDDATE <= lb.LOT1_BASE_DISCON_DT)
        THEN CASE sct.LOT1_TX_ENDDATE_REASON
               WHEN 1 THEN 'SCT_AUTO'
               WHEN 2 THEN 'SCT_ALLO'
               WHEN 3 THEN 'SCT_CART'
               ELSE 'SCT'
             END
        WHEN lb.LOT1_BASE_1ST_ADD_MED_DT IS NOT NULL
         AND (lb.LOT1_BASE_DISCON_DT IS NULL OR lb.LOT1_BASE_1ST_ADD_MED_DT <= lb.LOT1_BASE_DISCON_DT)
        THEN 'MED_ADD'
        WHEN lb.LOT1_BASE_DISCON_DT IS NOT NULL THEN 'DISCONTINUATION'
        ELSE 'CENSORED'
      END AS LOT1_BASE_END_REASON,
      CASE
        WHEN sct.LOT1_TX_ENDDATE IS NOT NULL
         AND (lb.LOT1_BASE_1ST_ADD_MED_DT IS NULL OR sct.LOT1_TX_ENDDATE <= lb.LOT1_BASE_1ST_ADD_MED_DT)
         AND (lb.LOT1_BASE_DISCON_DT IS NULL OR sct.LOT1_TX_ENDDATE <= lb.LOT1_BASE_DISCON_DT)
        THEN sct.LOT1_TX_ENDDATE
        WHEN lb.LOT1_BASE_1ST_ADD_MED_DT IS NOT NULL
         AND (lb.LOT1_BASE_DISCON_DT IS NULL OR lb.LOT1_BASE_1ST_ADD_MED_DT <= lb.LOT1_BASE_DISCON_DT)
        THEN lb.LOT1_BASE_1ST_ADD_MED_DT
        WHEN lb.LOT1_BASE_DISCON_DT IS NOT NULL THEN lb.LOT1_BASE_DISCON_DT
        ELSE lb.OBS_END_DT
      END AS LOT1_BASE_END_DT
    FROM lot1_base lb
    LEFT JOIN lot1_sct sct ON lb.PATID = sct.PATID
  ", qc = "
    SELECT LOT1_BASE_END_REASON, count(*) AS n
    FROM lot1_base_end
    GROUP BY LOT1_BASE_END_REASON
    ORDER BY LOT1_BASE_END_REASON")

  log_msg("NOTE: Maintenance (mono/dual) specs not yet provided; LOT1_BASE_END_REASON")
  log_msg("      does not yet include MAINTENANCE_START. Will need integration when available.")

  # ----------------------------------------------------------
  # NDC Format QC (Fix #5 from review)
  # Validates NDC length match between codelist and claims
  # ----------------------------------------------------------
  log_msg("Running NDC format QC...")
  tryCatch({
    ndc_qc_codelist <- db_q(con, "
      SELECT length(CL_CODE) AS ndc_len, count(*) AS n
      FROM mma_codelist
      WHERE CL_CODE_TYPE = 'NDC'
      GROUP BY length(CL_CODE)
      ORDER BY length(CL_CODE)
    ")
    log_msg("  NDC length distribution in codelist:")
    print(ndc_qc_codelist)

    # Restrict to cohort PATIDs + date window to avoid full RX scan
    ndc_qc_rx <- db_q(con, glue("
      SELECT length(upper(regexp_replace(coalesce(cast(r.NDC as string),''), '[^A-Za-z0-9]', ''))) AS ndc_len,
             count(*) AS n
      FROM {cdm_src(cfg$tbl_rx)} r
      INNER JOIN lot_patient_input p ON r.PATID = p.PATID
      WHERE cast(r.NDC as string) IS NOT NULL AND trim(cast(r.NDC as string)) <> ''
        AND cast(r.FILL_DT AS date) >= p.INDEX_DATE
        AND cast(r.FILL_DT AS date) <= p.OBS_END_DT
      GROUP BY length(upper(regexp_replace(coalesce(cast(r.NDC as string),''), '[^A-Za-z0-9]', '')))
      ORDER BY ndc_len
    "))
    log_msg("  NDC length distribution in RX claims:")
    print(ndc_qc_rx)

    # Check for mismatches
    codelist_lens <- ndc_qc_codelist$ndc_len
    rx_lens <- ndc_qc_rx$ndc_len
    if (length(intersect(codelist_lens, rx_lens)) == 0 && length(codelist_lens) > 0 && length(rx_lens) > 0) {
      log_msg("  WARNING: NDC lengths in codelist and RX table DO NOT OVERLAP!")
      log_msg("  This may cause silent misses in pharmacy claim matching.")
      log_msg("  Codelist lengths: ", paste(codelist_lens, collapse = ", "))
      log_msg("  RX table lengths: ", paste(rx_lens, collapse = ", "))
    }
  }, error = function(e) {
    log_msg("  WARNING: NDC QC failed: ", e$message)
  })

  # ----------------------------------------------------------
  # Validation QC Suite (Fix #10 from review)
  # Must-run validations for MAP + LOT correctness
  # ----------------------------------------------------------
  log_msg("Running validation QC suite...")
  tryCatch({
    # A) MMA_MED coverage by source
    log_msg("  [A] MMA_MED extraction coverage:")
    coverage <- db_q(con, "
      SELECT CODE_TYPE, CLAIM_TYPE, count(*) AS n_claims, count(DISTINCT PATID) AS n_patients, count(DISTINCT MED_ABBR) AS n_meds
      FROM mma_med_processed
      GROUP BY CODE_TYPE, CLAIM_TYPE
      ORDER BY CODE_TYPE, CLAIM_TYPE
    ")
    print(coverage)

    # B) MAP correctness spot checks
    log_msg("  [B] MAP algorithm spot checks:")
    # Check no MAP has end < start
    bad_maps <- db_q(con, "SELECT count(*) AS n_bad FROM map_stacked WHERE MAP_END_DT < MAP_START_DT")$n_bad
    log_msg("    MAPs with END < START: ", bad_maps, if (bad_maps > 0) " ** INVESTIGATE **" else " (OK)")

    # Check MAP_END_DT = max(rx_runout, med_runout)
    runout_check <- db_q(con, "
      SELECT count(*) AS n_mismatch
      FROM map_stacked
      WHERE MAP_END_DT <> greatest(
        coalesce(MAP_RX_RUNOUT_DT, cast('1900-01-01' as date)),
        coalesce(MAP_MED_RUNOUT_DT, cast('1900-01-01' as date))
      )
      AND MAP_END_DT IS NOT NULL
    ")$n_mismatch
    log_msg("    MAPs where END_DT != max(rx_runout, med_runout): ", runout_check,
            if (runout_check > 0) " ** INVESTIGATE **" else " (OK)")

    # MAPs with both rx and med sources (mixed claim type coverage)
    both_src <- db_q(con, "
      SELECT count(*) AS n_maps_both_sources
      FROM map_stacked
      WHERE MAP_RX_RUNOUT_DT IS NOT NULL AND MAP_MED_RUNOUT_DT IS NOT NULL
    ")$n_maps_both_sources
    log_msg("    MAPs with both pharmacy + medical sources: ", format(both_src, big.mark = ","))

    # C) ENDDATE_CE vs ENDDATE sensitivity
    log_msg("  [C] OBS_END_DT (ENDDATE_CE) sensitivity:")
    ce_sens <- db_q(con, "
      SELECT
        sum(case when ENDDATE_CE < ENDDATE then 1 else 0 end) AS n_disenrolled_early,
        count(*) AS n_total,
        avg(case when ENDDATE_CE < ENDDATE then datediff(ENDDATE, ENDDATE_CE) else 0 end) AS avg_gap_days
      FROM lot_patient_input
    ")
    log_msg("    Patients disenrolled before study ENDDATE: ",
            format(ce_sens$n_disenrolled_early, big.mark = ","),
            " / ", format(ce_sens$n_total, big.mark = ","),
            " (", round(100 * ce_sens$n_disenrolled_early / max(ce_sens$n_total, 1), 1), "%)")
    log_msg("    Avg gap (ENDDATE - ENDDATE_CE): ", round(ce_sens$avg_gap_days, 1), " days")

    # D) LOT1 completeness
    log_msg("  [D] LOT1 completeness:")
    lot1_check <- db_q(con, "
      SELECT
        count(*) AS n_lot1,
        sum(case when LOT1_BASE_END_DT > OBS_END_DT then 1 else 0 end) AS n_end_past_obs
      FROM lot1_base_end lb
      INNER JOIN lot_patient_input p ON lb.PATID = p.PATID
    ")
    log_msg("    LOT1 patients: ", format(lot1_check$n_lot1, big.mark = ","))
    log_msg("    LOT1_BASE_END_DT > OBS_END_DT: ", lot1_check$n_end_past_obs,
            if (lot1_check$n_end_past_obs > 0) " ** INVESTIGATE **" else " (OK)")

    # E) Rollup flag sanity
    log_msg("  [E] Rollup flag validation:")
    flag_check <- db_q(con, "
      SELECT CL_MED_ABBR, CL_MED_CLASS, MONOMAINTENANCE, CONDITIONING, USED_FOR_OTHER_CANCERS
      FROM mma_rollup
      ORDER BY CL_MED_CLASS, CL_MED_ABBR
    ")
    print(flag_check)

    # F) SCT consistency
    log_msg("  [F] SCT validation:")
    sct_check <- db_q(con, "
      SELECT
        sum(CASE WHEN LOT1_TX_ENDDATE IS NOT NULL AND LOT1_TX_ENDDATE > lb.OBS_END_DT THEN 1 ELSE 0 END)
          AS n_sct_end_past_obs,
        sum(CASE WHEN LOT1_SCT_AUTO_TAND_FLG = 1 AND LOT1_SCT_AUTO_SING_FLG = 1 THEN 1 ELSE 0 END)
          AS n_both_tandem_and_single,
        sum(CASE WHEN LOT1_TX_AUTO_DT_1 IS NOT NULL AND LOT1_TX_AUTO_DT_1 < lb.LOT1_START_DT THEN 1 ELSE 0 END)
          AS n_auto_before_lot1
      FROM lot1_sct sct
      INNER JOIN lot1_base lb ON sct.PATID = lb.PATID
    ")
    log_msg("    SCT end date past OBS_END_DT: ", sct_check$n_sct_end_past_obs,
            if (sct_check$n_sct_end_past_obs > 0) " ** INVESTIGATE **" else " (OK)")
    log_msg("    Both tandem AND single flag: ", sct_check$n_both_tandem_and_single,
            if (sct_check$n_both_tandem_and_single > 0) " ** BUG **" else " (OK)")
    log_msg("    AUTO DT_1 before LOT1_START: ", sct_check$n_auto_before_lot1,
            if (sct_check$n_auto_before_lot1 > 0) " ** INVESTIGATE **" else " (OK)")

    log_msg("Validation QC suite complete.")
  }, error = function(e) {
    log_msg("WARNING: Validation QC suite failed: ", e$message)
  })

  # ----------------------------------------------------------
  # Descriptives + Figures
  # ----------------------------------------------------------
  log_msg("Generating descriptive summary and figures...")
  print_descriptives(con)

  # ----------------------------------------------------------
  # Persist outputs
  # ----------------------------------------------------------
  if (isTRUE(cfg$persist_to_schema)) {
    run_step(con, "S17_persist_map_stacked", glue("
      CREATE OR REPLACE TABLE {wrk('MAP_STACKED')} AS
      SELECT * FROM map_stacked
    "), qc = glue("SELECT count(*) AS n_rows FROM {wrk('MAP_STACKED')}"))

    run_step(con, "S18_persist_lot1_base", glue("
      CREATE OR REPLACE TABLE {wrk('LOT1_BASE')} AS
      SELECT * FROM lot1_base
    "), qc = glue("SELECT count(*) AS n_rows FROM {wrk('LOT1_BASE')}"))

    run_step(con, "S19_persist_lot1_sct", glue("
      CREATE OR REPLACE TABLE {wrk('LOT1_SCT')} AS
      SELECT * FROM lot1_sct
    "), qc = glue("SELECT count(*) AS n_rows FROM {wrk('LOT1_SCT')}"))

    run_step(con, "S20_persist_lot1_base_end", glue("
      CREATE OR REPLACE TABLE {wrk('LOT1_BASE_END')} AS
      SELECT * FROM lot1_base_end
    "), qc = glue("SELECT count(*) AS n_rows FROM {wrk('LOT1_BASE_END')}"))
  } else {
    log_msg("Persist disabled (PERSIST_TO_SCHEMA=FALSE).")
  }

  log_msg(SEP)
  log_msg("LOT Part 2 complete.")
  log_msg("Temporary views: mma_med_processed, map_stacked, lot1_base, lot1_sct, lot1_base_end")
  if (isTRUE(cfg$persist_to_schema)) {
    log_msg("Persisted tables in work schema: MAP_STACKED, LOT1_BASE, LOT1_SCT, LOT1_BASE_END")
  }
  if (has_ggplot2) {
    log_msg("Figures saved to: ", cfg$output_dir)
  }
  log_msg(SEP)

  invisible(TRUE)
}

if (sys.nframe() == 0) {
  main()
}
