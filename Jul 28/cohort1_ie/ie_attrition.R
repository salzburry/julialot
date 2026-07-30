# =============================================================================
# ie_attrition.R -- the attrition table
# -----------------------------------------------------------------------------
# CUMULATIVE, not per-criterion. Each row is "how many patients survive every
# gate up to and including this one", so the drop attributable to a gate is the
# difference between its row and the one above it. A per-criterion count would
# say something different and much less useful (how many fail this gate in
# isolation, ignoring that most of them already failed an earlier one).
#
# THREE WINDOW COLUMNS FROM ONE PASS. 30 / 60 / 90-day outpatient confirmation
# differ only in which outpt2_* column Step 1 reads, and all three are materialized
# on the flag table, so one query per row returns all three counts:
#
#     count(DISTINCT CASE WHEN <30d condition>  THEN PATID END) AS n_30, ...
#
# The 90-day column is the configured build (OUTPATIENT_WINDOW=90); the other two
# are free sensitivity numbers, not separate runs. Nothing is rebuilt to produce
# them -- which is exactly why 01_index.R keeps all three flags instead of the
# configured one.
#
# COUNTS ARE count(DISTINCT PATID). One patient with three surviving candidate
# index dates is one patient on every row. The distinct is what makes these rows
# comparable to the final cohort, which is one row per patient by construction.
#
# STEP 0 COMES FROM A DIFFERENT TABLE, and it has to. mm_dx_events_id is the
# identification-period pool; the flag table only ever contains patients who
# already have a qualifying index date, so Step 0 counted there would equal
# Step 1 and the first and largest drop in the study would vanish from the table.
#
# Row ids and labels match criteria_attrition.R, so this table and the legacy one
# line up row for row.
# =============================================================================

ie_attrition_rows <- function(con, funnel) {
  cfg <- funnel$cfg; h <- funnel$h
  tbl      <- h$work(cfg$flags_view)
  base_tbl <- h$work("mm_dx_events_id")

  qual <- list(w30 = "(inpt_qual = 1 OR outpt2_30 = 1)",
               w60 = "(inpt_qual = 1 OR outpt2_60 = 1)",
               w90 = "(inpt_qual = 1 OR outpt2_90 = 1)")

  rows <- list()
  record <- function(step_id, description, n) {
    rows[[length(rows) + 1L]] <<- list(step_id = step_id, description = description,
                                       n_30 = n$n_30, n_60 = n$n_60, n_90 = n$n_90)
  }
  count_3w <- function(w30, w60, w90, from_tbl = tbl) {
    sql <- paste0(
      "SELECT\n",
      "  count(DISTINCT CASE WHEN ", w30, " THEN PATID END) AS n_30,\n",
      "  count(DISTINCT CASE WHEN ", w60, " THEN PATID END) AS n_60,\n",
      "  count(DISTINCT CASE WHEN ", w90, " THEN PATID END) AS n_90\n",
      "FROM ", from_tbl)
    r <- DBI::dbGetQuery(con, sql)
    list(n_30 = r$n_30[1], n_60 = r$n_60[1], n_90 = r$n_90[1])
  }

  # Step 0: the starting pool, off the ID-period event table.
  record("00_step0_base", "Step 0: >= 1 MM dx (any position)",
         count_3w("1=1", "1=1", "1=1", from_tbl = base_tbl))

  # Step 1 onwards, cumulative. Step 1 IS the qualifying condition, so it is the
  # first cumulative row rather than an extra clause on top of one.
  cum <- ""
  for (cr in funnel$criteria) {
    if (!ie_is_active(cr, cfg)) next
    if (cr$step > 1L) cum <- paste0(cum, " AND ", cr$predicate)
    record(cr$attrition_id, cr$label,
           count_3w(paste0(qual$w30, cum), paste0(qual$w60, cum),
                    paste0(qual$w90, cum)))
  }

  # The terminal row. Same condition as the last gate -- it is here so a reader
  # can check the funnel actually lands on the cohort that got persisted, rather
  # than trusting that it did.
  record("99_final", paste0("FINAL COHORT (", cfg$ie_final_table, ")"),
         count_3w(paste0(qual$w30, cum), paste0(qual$w60, cum),
                  paste0(qual$w90, cum)))
  rows
}

ie_print_attrition <- function(rows, cfg) {
  sep <- strrep("=", 84); dash <- strrep("-", 84)
  cat("\n", sep, "\n", sep = "")
  cat("  ATTRITION TABLE -- COHORT 1 (OVERALL)\n")
  cat("  configured window: ", cfg$outpatient_window,
      "d  (the other two columns are sensitivity, not separate runs)\n", sep = "")
  cat(sep, "\n", sep = "")
  cat(sprintf("%-45s %12s %12s %12s\n", "Step", "30-day", "60-day", "90-day"))
  cat(dash, "\n", sep = "")
  for (r in rows) {
    cat(sprintf("%-45s %12s %12s %12s\n", substr(r$description, 1, 45),
                format(r$n_30, big.mark = ","), format(r$n_60, big.mark = ","),
                format(r$n_90, big.mark = ",")))
  }
  cat(sep, "\n", sep = "")
  invisible(rows)
}

# Persist so the numbers survive the session. Best-effort: a failure here must
# not lose a cohort that was already built and persisted, so it warns rather than
# aborting -- the opposite call from the cohort table itself.
ie_persist_attrition <- function(con, rows, funnel) {
  cfg <- funnel$cfg; h <- funnel$h
  if (!length(rows)) return(invisible(NULL))
  if (!nzchar(h$out_schema())) {
    message("no output schema set; skipping attrition persist")
    return(invisible(NULL))
  }
  tbl <- h$persist(cfg$ie_attrition_table)
  q <- function(x) paste0("'", gsub("'", "''", as.character(x)), "'")
  i <- function(x) if (is.null(x) || is.na(x)) "NULL" else
    format(as.integer(x), scientific = FALSE, trim = TRUE)
  created <- q(format(Sys.time(), "%Y-%m-%d %H:%M:%S"))
  vals <- vapply(seq_along(rows), function(k) {
    r <- rows[[k]]
    paste0("(", k, ", ", created, ", ", q(cfg$ie_final_table), ", ",
           i(cfg$outpatient_window), ", ", q(r$step_id), ", ",
           q(r$description), ", ", i(r$n_30), ", ", i(r$n_60), ", ",
           i(r$n_90), ")")
  }, character(1))
  sql <- paste0(
    "CREATE OR REPLACE TABLE ", tbl, " AS\nSELECT * FROM VALUES\n  ",
    paste(vals, collapse = ",\n  "),
    "\nAS t(row_order, created_at, cohort_table, outpatient_window,\n",
    "     step_id, description, n_30, n_60, n_90)")
  tryCatch({
    DBI::dbExecute(con, sql)
    message("attrition persisted to ", tbl, " (", length(rows), " rows)")
  }, error = function(e)
    message("WARN: could not persist attrition to ", tbl, ": ",
            conditionMessage(e)))
  invisible(tbl)
}

ie_export_attrition_csv <- function(rows, dir = Sys.getenv("OUTPUT_DIR", unset = "")) {
  if (!length(rows) || !nzchar(dir)) return(invisible(NULL))
  df <- do.call(rbind, lapply(rows, function(r) data.frame(
    step = r$step_id, description = r$description,
    n_30 = r$n_30, n_60 = r$n_60, n_90 = r$n_90, stringsAsFactors = FALSE)))
  f <- file.path(dir, paste0("c1_attrition_",
                             format(Sys.time(), "%Y%m%d_%H%M%S"), ".csv"))
  tryCatch({
    dir.create(dir, showWarnings = FALSE, recursive = TRUE)
    utils::write.csv(df, f, row.names = FALSE)
    message("attrition CSV -> ", f)
    f
  }, error = function(e) {
    message("WARN: could not write attrition CSV: ", conditionMessage(e))
    invisible(NULL)
  })
}
