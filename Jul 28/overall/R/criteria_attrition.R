# The IE criteria, in order. Feeds the Step 24 filter and the attrition
# report, which ANDs them on cumulatively - so this is also the attrition
# table's row order. Don't reorder it.
#
# Steps 0-1 are counted in run_attrition_report(); their SQL differs per
# 30/60/90-day window. Steps 2-10 are below.

build_criteria_catalog <- function(cfg) {
  list(
    # Step 2 - include: old enough at index
    list(attrition_id = "02_step2_age",
         label = glue("Step 2: Age >= {cfg$min_age} at index year"),
         filter_sql = glue("AND AGE_INDEX_YR >= {cfg$min_age}"),
         cfg_key = "apply_age_incl"),

    # Step 3 - include: covered through the whole 6-month baseline
    list(attrition_id = "03_step3_ce_baseline",
         label = "Step 3: 6-mo baseline enrollment",
         filter_sql = "AND CE_b = 1",
         cfg_key = "apply_ce_b_incl"),

    # Step 4 - include: covered on the index date (>=1 day of follow-up)
    list(attrition_id = "04_step4_ce_followup",
         label = "Step 4: 1+ day FU enrollment",
         filter_sql = "AND CE_f = 1",
         cfg_key = "apply_ce_f_incl"),

    # Step 5 - exclude: already on MM therapy in baseline (not naive)
    list(attrition_id = "05_step5_no_bl_therapy",
         label = "Step 5: No baseline therapy (excl)",
         filter_sql = "AND MM_bl_agents = 0",
         cfg_key = "apply_no_bl_agents_incl"),

    # Step 6 - include: at least one MM-agent claim in follow-up.
    # At least one MM-agent claim; not proof of a valid regimen.
    list(attrition_id = "06_step6_fu_therapy",
         label = "Step 6: FU therapy required",
         filter_sql = "AND MM_FU_agents = 1",
         cfg_key = "apply_fu_agents_incl"),

    # Step 7 - exclude: MM diagnosis already in baseline (not newly diagnosed)
    list(attrition_id = "07_step7_bl_mm_evidence",
         label = "Step 7: BL MM evidence (excl)",
         filter_sql = "AND MM_baseline_diag = 0",
         cfg_key = "apply_baseline_mm_excl"),

    # Step 8 - exclude: another active cancer
    list(attrition_id = "08_step8_other_cancer",
         label = "Step 8: Other cancer (excl)",
         filter_sql = "AND OTHER_MALIGN_FLAG = 0",
         cfg_key = "apply_other_malig_excl"),

    # Step 9 - exclude: pregnancy in baseline or follow-up
    list(attrition_id = "09_step9_pregnancy",
         label = "Step 9: Pregnancy (excl)",
         filter_sql = "AND PREGNANT_FLAG = 0",
         cfg_key = "apply_pregnancy_excl"),

    # Step 10 - exclude: clinical-trial participation in baseline or follow-up
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

# ---- Attrition reporting ----

# The three columns are the 30/60/90 sensitivity. Only one of them is the
# cohort that was actually built - the one matching cfg$outpatient_window.
# Mark it, or people read the row left to right and quote the 30-day number.
print_attrition_table <- function(rows, window = NULL) {
  sep <- strrep("=", 84)
  dash <- strrep("-", 84)
  hdr <- function(w) {
    if (!is.null(window) && as.character(window) == as.character(w))
      paste0(w, "-day *") else paste0(w, "-day")
  }
  cat("\n")
  cat(sep, "\n")
  cat("  ATTRITION TABLE\n")
  cat(sep, "\n")
  cat(sprintf("%-45s %12s %12s %12s\n", "Step", hdr(30), hdr(60), hdr(90)))
  cat(dash, "\n")

  for (row in rows) {
    cat(sprintf("%-45s %12s %12s %12s\n",
                substr(row$description, 1, 45),
                format(row$n_30, big.mark = ","),
                format(row$n_60, big.mark = ","),
                format(row$n_90, big.mark = ",")))
  }
  cat(sep, "\n")
  if (!is.null(window)) {
    cat("* configured outpatient window - this column is the cohort that was written.\n")
    cat("  The other two columns are sensitivity only; no table exists for them.\n")
  }
}

# Persist the attrition counts for this run. Overwrites each run; every row
# carries run_id, cohort name and build time.
persist_attrition_table <- function(rows, cfg, conn) {
  # CREATE OR REPLACE, so skipping the write leaves last run's rows looking
  # current. Fail instead.
  if (length(rows) == 0) stop("no attrition rows to persist", call. = FALSE)
  if (!nzchar(cfg$work_schema))
    stop("cfg$work_schema not set; cannot persist attrition_report", call. = FALSE)

  # Prefixed, so another cohort's build can't overwrite this one's.
  obj <- paste0(if (is.null(cfg$object_prefix)) "" else tolower(cfg$object_prefix),
                "attrition_report")
  tbl_name <- if (nzchar(cfg$catalog)) {
    paste0(cfg$catalog, ".", cfg$work_schema, ".", obj)
  } else {
    paste0(cfg$work_schema, ".", obj)
  }

  sql_int <- function(x) {
    if (is.null(x) || is.na(x)) "NULL"
    else format(as.integer(x), scientific = FALSE, trim = TRUE)
  }
  sql_str <- function(x) paste0("'", gsub("'", "''", as.character(x)), "'")

  # Run-scoped metadata written on every row. run_id comes from the
  # module-level run_id assigned in config_prompts.R.
  run_id_val   <- sql_str(get0("run_id", ifnotfound = ""))
  cohort_val   <- sql_str(cfg$final_table_name %||% "")
  created_val  <- sql_str(format(Sys.time(), "%Y-%m-%d %H:%M:%S"))

  value_rows <- vapply(seq_along(rows), function(i) {
    r <- rows[[i]]
    paste0("(", i, ", ",
           run_id_val, ", ",
           cohort_val, ", ",
           created_val, ", ",
           sql_str(r$step_id), ", ",
           sql_str(r$description), ", ",
           sql_int(r$n_30), ", ",
           sql_int(r$n_60), ", ",
           sql_int(r$n_90), ")")
  }, character(1))

  values_sql <- paste(value_rows, collapse = ",\n      ")

  sql <- glue("
    CREATE OR REPLACE TABLE {tbl_name} AS
    SELECT * FROM VALUES
      {values_sql}
    AS t(row_order, run_id, final_table_name, created_at,
         step_id, description, n_30, n_60, n_90)
  ")

  DBI::dbExecute(conn$con, sql)
  log_msg("Attrition table persisted to: ", tbl_name,
          " (", length(rows), " rows, run_id=", get0("run_id", ifnotfound = "?"),
          ", cohort=", cfg$final_table_name %||% "?", ")")
}

# Simple null-coalesce operator used above.
`%||%` <- function(a, b) if (is.null(a) || !nzchar(as.character(a))) b else a

# ---- Data-driven attrition counting ----

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

  # Step 0: Base cohort - all patients with >= 1 MM dx (any position)
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

  # Final cohort row. Steps 0-10 are recomputed three ways, but only the
  # configured window was written to a table. Count that column off the cohort
  # table itself so the printed number can't drift from the table people query.
  final <- count_3w(
    glue("{qual_30}{cum_cond}"),
    glue("{qual_60}{cum_cond}"),
    glue("{qual_90}{cum_cond}"))
  w <- cfg$outpatient_window
  final[[paste0("n_", w)]] <- DBI::dbGetQuery(conn$con, glue(
    "SELECT count(*) AS n FROM {work_tbl_fn(cfg$final_table_name)}"))$n
  record("99_final", glue("FINAL COHORT ({cfg$final_table_name}, {w}d)"),
                   final$n_30, final$n_60, final$n_90)

  print_attrition_table(rows, window = w)
  invisible(rows)
}

# ---- QC reporting ----

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

