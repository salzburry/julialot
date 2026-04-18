# ============================================================
# criteria_attrition.R — Unified criteria catalog, filter builder,
#                         attrition tracker, QC reporting
# ============================================================
# No module-level mutable state. All runtime state (connection,
# naming helpers) is passed through function arguments.

# ---- Canonical Criteria Catalog ----
# Single source of truth for all IE criteria. Drives:
#   - final filter SQL in build_steps() (Step 24)
#   - cumulative attrition counting in main()
#   - interactive prompt defaults (via config_prompts.R)
#
# Fields:
#   attrition_id    : sort key for attrition table output
#   label           : human-readable label for attrition table
#   filter_sql      : SQL WHERE fragment (applied cumulatively)
#   cfg_key         : name in cfg that toggles this criterion
#
# Step 1 is special (window-specific qualifying) and handled outside
# the catalog because it uses different SQL per 30/60/90d window.

build_criteria_catalog <- function(cfg) {
  list(
    list(attrition_id = "02_step2_age",
         label = glue("Step 2: Age >= {cfg$min_age} at index year"),
         filter_sql = glue("AND AGE_INDEX_YR >= {cfg$min_age}"),
         cfg_key = "apply_age_incl"),

    list(attrition_id = "03_step3_ce_baseline",
         label = "Step 3: 6-mo baseline enrollment",
         filter_sql = "AND CE_b = 1",
         cfg_key = "apply_ce_b_incl"),

    list(attrition_id = "04_step4_ce_followup",
         label = "Step 4: 1+ day FU enrollment",
         filter_sql = "AND CE_f = 1",
         cfg_key = "apply_ce_f_incl"),

    list(attrition_id = "05_step5_no_bl_therapy",
         label = "Step 5: No baseline therapy (excl)",
         filter_sql = "AND MM_bl_agents = 0",
         cfg_key = "apply_no_bl_agents_incl"),

    list(attrition_id = "06_step6_fu_therapy",
         label = "Step 6: FU therapy required",
         filter_sql = "AND MM_FU_agents = 1",
         cfg_key = "apply_fu_agents_incl"),

    list(attrition_id = "07_step7_bl_mm_evidence",
         label = "Step 7: BL MM evidence (excl)",
         filter_sql = "AND MM_baseline_diag = 0",
         cfg_key = "apply_baseline_mm_excl"),

    list(attrition_id = "08_step8_other_cancer",
         label = "Step 8: Other cancer (excl)",
         filter_sql = "AND OTHER_MALIGN_FLAG = 0",
         cfg_key = "apply_other_malig_excl"),

    list(attrition_id = "09_step9_pregnancy",
         label = "Step 9: Pregnancy (excl)",
         filter_sql = "AND PREGNANT_FLAG = 0",
         cfg_key = "apply_pregnancy_excl"),

    list(attrition_id = "10_step10_clintrial",
         label = "Step 10: Clinical trial (excl)",
         filter_sql = "AND CLINTRIAL_BASELINE = 0 AND CLINTRIAL_FOLLOWUP = 0",
         cfg_key = "apply_clintrial_excl")
  )
}

# ---- Build combined criteria SQL for Step 24 final filter ----
build_criteria_sql <- function(catalog, cfg) {
  clauses <- c()
  for (cr in catalog) {
    if (isTRUE(cfg[[cr$cfg_key]])) {
      clauses <- c(clauses, cr$filter_sql)
    }
  }
  paste(clauses, collapse = "\n          ")
}

# ============================================================
# ATTRITION REPORTING
# ============================================================
# print/export accept a rows list; no module-level state.

print_attrition_table <- function(rows) {
  sep <- strrep("=", 84)
  dash <- strrep("-", 84)
  cat("\n")
  cat(sep, "\n")
  cat("  ATTRITION TABLE\n")
  cat(sep, "\n")
  cat(sprintf("%-45s %12s %12s %12s\n", "Step", "30-day", "60-day", "90-day"))
  cat(dash, "\n")

  for (row in rows) {
    cat(sprintf("%-45s %12s %12s %12s\n",
                substr(row$description, 1, 45),
                format(row$n_30, big.mark = ","),
                format(row$n_60, big.mark = ","),
                format(row$n_90, big.mark = ",")))
  }
  cat(sep, "\n")
}

export_attrition_csv <- function(rows) {
  if (length(rows) == 0) return(invisible(NULL))

  df <- do.call(rbind, lapply(rows, function(r) {
    data.frame(step = r$step_id, description = r$description,
               n_30 = r$n_30, n_60 = r$n_60, n_90 = r$n_90,
               stringsAsFactors = FALSE)
  }))

  csv_name <- paste0("attrition_", format(Sys.time(), "%Y%m%d_%H%M%S"), ".csv")
  tryCatch({
    write.csv(df, csv_name, row.names = FALSE)
    log_msg("Attrition table exported to: ", csv_name)
  }, error = function(e) {
    log_msg("WARN: Could not export attrition CSV: ", conditionMessage(e))
  })
}

# ============================================================
# DATA-DRIVEN ATTRITION COUNTING
# ============================================================
# Builds attrition rows locally and returns them. No global state.

run_attrition_report <- function(catalog, cfg, conn, work_tbl_fn) {
  rows <- list()
  record <- function(step_id, description, n_30, n_60, n_90) {
    rows[[length(rows) + 1]] <<- list(
      step_id = step_id, description = description,
      n_30 = n_30, n_60 = n_60, n_90 = n_90)
  }

  tbl <- work_tbl_fn("ELIG_COH_ALLFLAGS")
  qual_30 <- "(inpt_qual = 1 OR outpt2_30 = 1)"
  qual_60 <- "(inpt_qual = 1 OR outpt2_60 = 1)"
  qual_90 <- "(inpt_qual = 1 OR outpt2_90 = 1)"

  # Single query returns all three window counts at once
  count_3w <- function(w30, w60, w90, from_tbl = tbl) {
    sql <- glue("
      SELECT
        count(DISTINCT CASE WHEN {w30} THEN PATID END) AS n_30,
        count(DISTINCT CASE WHEN {w60} THEN PATID END) AS n_60,
        count(DISTINCT CASE WHEN {w90} THEN PATID END) AS n_90
      FROM {from_tbl}
    ")
    row <- DBI::dbGetQuery(conn$con, sql)
    list(n_30 = row$n_30, n_60 = row$n_60, n_90 = row$n_90)
  }

  # Step 0: Base cohort — all patients with >= 1 MM dx (any position)
  # Counts from mm_dx_events_id (identification-period events), not
  # mm_dx_events_all (full study period) which includes baseline lookback
  base_tbl <- work_tbl_fn("mm_dx_events_id")
  s0 <- count_3w("1=1", "1=1", "1=1", from_tbl = base_tbl)
  record("00_step0_base", "Step 0: >= 1 MM dx (any position)", s0$n_30, s0$n_60, s0$n_90)

  # Step 1: Qualifying (IP strict OR 2 OP broad in window)
  s1 <- count_3w(qual_30, qual_60, qual_90)
  record("01_step1_qualifying", "Step 1: Qualifying MM dx (IP/OP)", s1$n_30, s1$n_60, s1$n_90)

  # Steps 2-10: Data-driven from catalog
  cum_cond <- ""
  for (cr in catalog) {
    if (isTRUE(cfg[[cr$cfg_key]])) {
      cum_cond <- paste0(cum_cond, " ", cr$filter_sql)
      counts <- count_3w(
        glue("{qual_30}{cum_cond}"),
        glue("{qual_60}{cum_cond}"),
        glue("{qual_90}{cum_cond}"))
      record(cr$attrition_id, cr$label, counts$n_30, counts$n_60, counts$n_90)
    }
  }

  # Final cohort row
  final <- count_3w(
    glue("{qual_30}{cum_cond}"),
    glue("{qual_60}{cum_cond}"),
    glue("{qual_90}{cum_cond}"))
  record("99_final", glue("FINAL COHORT ({cfg$final_table_name})"),
                   final$n_30, final$n_60, final$n_90)

  print_attrition_table(rows)
  export_attrition_csv(rows)
  invisible(rows)
}

# ============================================================
# QC REPORTING
# ============================================================

print_cohort_characteristics <- function(cfg, conn, work_tbl_fn) {
  stats_sql <- glue("
    SELECT
      count(*)                AS n_patients,
      avg(AGE_INDEX_YR)       AS mean_age,
      sum(CASE WHEN GDR_CD = 'M' THEN 1 ELSE 0 END) AS n_male,
      sum(CASE WHEN GDR_CD = 'F' THEN 1 ELSE 0 END) AS n_female,
      avg(FU_DAYS)            AS mean_fu_days,
      min(INDEX_DATE)         AS min_index_date,
      max(INDEX_DATE)         AS max_index_date,
      sum(CASE WHEN index_source = 'INPATIENT' THEN 1 ELSE 0 END) AS n_inpatient_index,
      sum(CASE WHEN DEATH_DT IS NOT NULL THEN 1 ELSE 0 END) AS n_with_death
    FROM {work_tbl_fn(cfg$final_table_name)}
  ")
  stats <- DBI::dbGetQuery(conn$con, stats_sql)

  cat("\n", SEP_60, "\n")
  cat("                 COHORT CHARACTERISTICS\n")
  cat(SEP_60, "\n")
  cat(sprintf("Total patients:          %s\n",    format(stats$n_patients, big.mark = ",")))
  cat(sprintf("Mean age at index:       %.1f years\n", stats$mean_age))
  cat(sprintf("Male / Female:           %s / %s\n",
              format(stats$n_male, big.mark = ","), format(stats$n_female, big.mark = ",")))
  cat(sprintf("Inpatient index:         %s (%.1f%%)\n",
              format(stats$n_inpatient_index, big.mark = ","),
              100 * stats$n_inpatient_index / stats$n_patients))
  cat(sprintf("Mean follow-up:          %.1f days\n", stats$mean_fu_days))
  cat(sprintf("Index date range:        %s to %s\n", stats$min_index_date, stats$max_index_date))
  cat(sprintf("Patients with death:     %s (%.1f%%)\n",
              format(stats$n_with_death, big.mark = ","),
              100 * stats$n_with_death / stats$n_patients))
  cat(SEP_60, "\n")
}

print_dod_validation <- function(cfg, conn, cdm_src_fn, work_tbl_fn) {
  cat("\n", DASH_60, "\n  DOD JOINABILITY VALIDATION\n", DASH_60, "\n", sep = "")
  dod_qc <- DBI::dbGetQuery(conn$con, glue("
    WITH dod_ids AS (
      SELECT DISTINCT PATID FROM {cdm_src_fn(cfg$tbl_dod)}
      WHERE YMDOD IS NOT NULL AND LENGTH(TRIM(YMDOD)) >= 4
    )
    SELECT count(DISTINCT q.PATID) AS n_qualifying,
           count(DISTINCT d.PATID) AS n_dod_matched,
           ROUND(100.0 * count(DISTINCT d.PATID) / NULLIF(count(DISTINCT q.PATID), 0), 2) AS pct_matched
    FROM {work_tbl_fn('mm_qualifying')} q
    LEFT JOIN dod_ids d ON q.PATID = d.PATID
  "))
  cat(sprintf("Qualifying patients:     %s\n", format(dod_qc$n_qualifying, big.mark = ",")))
  cat(sprintf("DOD matches:             %s (%.2f%%)\n", format(dod_qc$n_dod_matched, big.mark = ","), dod_qc$pct_matched))
  if (dod_qc$pct_matched < 1) {
    cat("WARNING: DOD join rate < 1%%. Check PATID encryption mismatch.\n")
  } else if (dod_qc$pct_matched < 10) {
    cat("NOTE: Low DOD join rate may be expected for MM cohort.\n")
  } else {
    cat("DOD join rate looks reasonable.\n")
  }
  cat(DASH_60, "\n")
}

print_inpatient_validation <- function(conn, work_tbl_fn) {
  cat("\n", DASH_60, "\n  INPATIENT CLASSIFICATION VALIDATION (Approach 1 + 2)\n", DASH_60, "\n", sep = "")
  qc <- DBI::dbGetQuery(conn$con, glue("
    SELECT count(*) AS n_mm_dx_events,
           sum(inpatient_flg)  AS n_inpatient_total,
           sum(pos_tos_inpatient) AS n_via_pos_tos,
           sum(conf_validated) AS n_via_conf,
           sum(CASE WHEN pos_tos_inpatient=1 AND conf_validated=1 THEN 1 ELSE 0 END) AS n_both,
           sum(CASE WHEN pos_tos_inpatient=1 AND conf_validated=0 THEN 1 ELSE 0 END) AS n_pos_tos_only,
           sum(CASE WHEN pos_tos_inpatient=0 AND conf_validated=1 THEN 1 ELSE 0 END) AS n_conf_only
    FROM {work_tbl_fn('mm_dx_events_all')}
  "))
  cat(sprintf("MM dx events (total):    %s\n", format(qc$n_mm_dx_events, big.mark = ",")))
  cat(sprintf("Inpatient (combined):    %s (%.1f%%)\n", format(qc$n_inpatient_total, big.mark = ","),
              100 * qc$n_inpatient_total / qc$n_mm_dx_events))
  cat(sprintf("  Via POS/TOS (Appr 1):  %s\n", format(qc$n_via_pos_tos, big.mark = ",")))
  cat(sprintf("  Via CONF_ID (Appr 2):  %s\n", format(qc$n_via_conf, big.mark = ",")))
  cat(sprintf("  Both approaches:       %s\n", format(qc$n_both, big.mark = ",")))
  cat(sprintf("  POS/TOS only:          %s\n", format(qc$n_pos_tos_only, big.mark = ",")))
  cat(sprintf("  CONF_ID only:          %s\n", format(qc$n_conf_only, big.mark = ",")))
  cat(DASH_60, "\n")
}

# ============================================================
# PIPELINE INSPECTOR — Post-run diagnostic
# ============================================================
# Queries every intermediate view and prints row/patient counts.
# Useful for debugging: run the pipeline, then call inspect_pipeline()
# to see where patients are gained or lost.

inspect_pipeline <- function(conn, cfg, work_tbl_fn) {
  views <- c(
    # Phase 1: code lists
    "mm_dx_codes", "mm_therapy_codes", "preg_codes", "clintrial_codes", "other_malig_codes",
    # Phase 2: dx events
    "med_claim_header", "confinement", "mm_dx_events_all", "mm_dx_events_id",
    # Phase 3: index date
    "mm_inpatient_potential", "mm_outpatient_pairs", "mm_outpatient_potential", "mm_qualifying",
    # Phase 4+5: enrollment + CE
    "enrollment_spans", "enrollment_spans_strict", "ce_flags",
    # Phase 6: demographics + death
    "member_demo", "death_dt",
    # Phase 7+8: clinical flags
    "mm_baseline_evidence_flag", "therapy_events", "therapy_flags",
    # Phase 9: exclusions
    "pregnancy_flag", "clintrial_flag", "other_malig_flag",
    # Phase 10: assembly + final cohort
    "ELIG_COH_ALLFLAGS",
    cfg$final_table_name
  )

  sep <- strrep("=", 70)
  dash <- strrep("-", 70)
  cat("\n", sep, "\n", sep = "")
  cat("  PIPELINE VIEW INSPECTOR\n")
  cat(sep, "\n")
  cat(sprintf("%-35s %14s %14s\n", "View", "Rows", "Patients"))
  cat(dash, "\n")

  for (v in views) {
    tbl <- work_tbl_fn(v)
    tryCatch({
      res <- DBI::dbGetQuery(conn$con, glue(
        "SELECT count(*) AS n_rows, count(DISTINCT PATID) AS n_patients FROM {tbl}"))
      cat(sprintf("%-35s %14s %14s\n", v,
                  format(res$n_rows, big.mark = ","),
                  format(res$n_patients, big.mark = ",")))
    }, error = function(e) {
      # Code-list views lack PATID — fall back to row count only
      tryCatch({
        res <- DBI::dbGetQuery(conn$con, glue("SELECT count(*) AS n_rows FROM {tbl}"))
        cat(sprintf("%-35s %14s %14s\n", v, format(res$n_rows, big.mark = ","), "-"))
      }, error = function(e2) {
        cat(sprintf("%-35s %14s %14s\n", v, "(missing)", "-"))
      })
    })
  }
  cat(sep, "\n")
}
