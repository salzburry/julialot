# =============================================================================
# ie_attrition.R -- the attrition table, and the reconciliation that checks it
# -----------------------------------------------------------------------------
# CUMULATIVE, not per-criterion. Each row is "how many patients survive every
# gate up to and including this one", so the drop attributable to a gate is the
# difference between its row and the one above it. A per-criterion count would
# say something much less useful (how many fail this gate in isolation, ignoring
# that most of them already failed an earlier one).
#
# THREE WINDOW COLUMNS FROM ONE PASS. 30 / 60 / 90-day outpatient confirmation
# differ only in which outpt2_* column Step 1 reads, and all three are on the
# flags table, so one query per row returns all three counts. The configured
# window's column is the build; the other two are free sensitivity numbers, not
# separate runs. That is why 01_index.R keeps all three flags.
#
# COUNTS ARE count(DISTINCT PATID). One patient with three surviving candidate
# index dates is one patient on every row.
#
# STEP 0 COMES FROM A DIFFERENT TABLE, and it has to. mm_dx_events_id is the
# identification-period pool; the flags table only contains patients who already
# have a qualifying index date, so Step 0 counted there would equal Step 1 and
# the first and largest drop in the study would vanish from the table.
#
# ---------------------------------------------------------------------------
# THE FUNNEL DOES NOT VALIDATE ITSELF
# ---------------------------------------------------------------------------
# Every row above, including the terminal one, is computed by re-running the
# cumulative predicates over the FLAGS table. An earlier revision claimed the
# terminal row let a reader confirm the funnel landed on the cohort that was
# written. It does not: it never reads the cohort table, so it cannot see a wrong
# object being written, a wrong index date being selected, duplicate PATIDs, or a
# failed write.
#
# ie_reconcile() is the part that actually checks, by querying the cohort table
# itself and comparing it to the funnel -- including that the selected index date
# is the EARLIEST SURVIVING one, which is the filter-then-rank property the whole
# design turns on. It runs after every build.
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

  record("00_step0_base", "Step 0: >= 1 MM dx (any position)",
         count_3w("1=1", "1=1", "1=1", from_tbl = base_tbl))

  # Step 1 IS the qualifying condition, so it is the first cumulative row rather
  # than an extra clause on top of one.
  cum <- ""
  for (cr in funnel$criteria) {
    if (!ie_is_active(cr, cfg)) next
    if (cr$step > 1L) cum <- paste0(cum, " AND ", cr$predicate)
    record(cr$attrition_id, cr$label,
           count_3w(paste0(qual$w30, cum), paste0(qual$w60, cum),
                    paste0(qual$w90, cum)))
  }
  record("99_funnel", "FUNNEL END (predicates over the flags table)",
         count_3w(paste0(qual$w30, cum), paste0(qual$w60, cum),
                  paste0(qual$w90, cum)))
  attr(rows, "cum_where") <- paste0(qual[[paste0("w", cfg$outpatient_window)]], cum)
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

# =============================================================================
# Reconciliation: does the cohort table match the funnel?
# -----------------------------------------------------------------------------
# Five checks, each of which can fail while every attrition row still looks fine:
#
#   1 grain         one row per PATID in the cohort table
#   2 count         cohort patients == funnel end (configured window)
#   3 membership    PATID sets identical, BOTH directions
#   4 index date    the selected INDEX_DATE is the EARLIEST SURVIVING candidate
#                   -- the filter-then-rank property, checked on real rows
#   5 no nulls      no NULL PATID or INDEX_DATE
#
# Check 4 is the one no text comparison can make. If the ranking were applied
# before the filter, or over the wrong ordering, checks 1-3 could all pass while
# patients carried the wrong index date -- and every downstream LOT number is
# computed from that date.
# =============================================================================
ie_reconcile <- function(con, funnel, cum_where) {
  cfg <- funnel$cfg; h <- funnel$h
  flags <- h$work(cfg$flags_view)
  final <- h$work(cfg$final_table_name)
  q <- function(sql) DBI::dbGetQuery(con, sql)
  results <- list()
  add <- function(name, ok, detail) {
    results[[length(results) + 1L]] <<- list(name = name, ok = isTRUE(ok),
                                             detail = detail)
  }

  g <- q(paste0("SELECT count(*) AS n_rows, count(DISTINCT PATID) AS n_pat,",
                " sum(CASE WHEN PATID IS NULL THEN 1 ELSE 0 END) AS n_null_pat,",
                " sum(CASE WHEN INDEX_DATE IS NULL THEN 1 ELSE 0 END) AS n_null_idx",
                " FROM ", final))
  add("grain: one row per PATID", g$n_rows[1] == g$n_pat[1],
      paste0(format(g$n_rows[1], big.mark = ","), " rows / ",
             format(g$n_pat[1], big.mark = ","), " patients"))
  add("no NULL PATID or INDEX_DATE", g$n_null_pat[1] == 0 && g$n_null_idx[1] == 0,
      paste0(g$n_null_pat[1], " null PATID, ", g$n_null_idx[1], " null INDEX_DATE"))

  f <- q(paste0("SELECT count(DISTINCT PATID) AS n FROM ", flags,
                " WHERE ", cum_where))
  add("count == funnel end", g$n_pat[1] == f$n[1],
      paste0("cohort ", format(g$n_pat[1], big.mark = ","), " vs funnel ",
             format(f$n[1], big.mark = ",")))

  surviving <- paste0("SELECT PATID, INDEX_DATE FROM ", flags,
                      " WHERE ", cum_where)
  for (d in list(list(lab = "in cohort but not surviving the funnel",
                      x = paste0("SELECT DISTINCT PATID FROM ", final),
                      y = paste0("SELECT DISTINCT PATID FROM (", surviving, ")")),
                 list(lab = "surviving the funnel but not in cohort",
                      x = paste0("SELECT DISTINCT PATID FROM (", surviving, ")"),
                      y = paste0("SELECT DISTINCT PATID FROM ", final)))) {
    n <- q(paste0("SELECT count(*) AS n FROM (", d$x, " EXCEPT ", d$y, ")"))$n[1]
    add(paste0("membership: ", d$lab, " = 0"), n == 0,
        format(n, big.mark = ","))
  }

  # Filter-then-rank, on the data: the cohort's INDEX_DATE must equal the
  # minimum SURVIVING candidate index for that patient.
  n_wrong <- q(paste0(
    "WITH surv AS (", surviving, "),\n",
    "     earliest AS (SELECT PATID, min(INDEX_DATE) AS min_idx FROM surv GROUP BY PATID)\n",
    "SELECT count(*) AS n FROM ", final, " c\n",
    "JOIN earliest e ON c.PATID = e.PATID\n",
    "WHERE c.INDEX_DATE <> e.min_idx"))$n[1]
  add("index date == earliest SURVIVING candidate", n_wrong == 0,
      paste0(format(n_wrong, big.mark = ","), " patient(s) differ"))

  results
}

ie_print_reconcile <- function(results, funnel) {
  cat("\n", strrep("=", 84), "\n", sep = "")
  cat("  RECONCILIATION -- ", funnel$h$work(funnel$cfg$final_table_name), "\n",
      sep = "")
  cat(strrep("=", 84), "\n", sep = "")
  for (r in results)
    cat(sprintf("  %-4s %-52s %s\n", if (r$ok) "ok" else "FAIL", r$name, r$detail))
  bad <- sum(!vapply(results, function(r) r$ok, logical(1)))
  cat(strrep("=", 84), "\n", sep = "")
  if (bad) {
    cat("  ", bad, " reconciliation check(s) FAILED. The cohort table does not ",
        "match the funnel.\n", sep = "")
  } else {
    cat("  The cohort table matches the funnel, one row per patient, on the ",
        "earliest surviving index.\n", sep = "")
  }
  cat("  This is internal consistency. It says nothing about agreement with the\n",
      "  legacy cohort -- that is tests/verify_cohort1.R.\n", sep = "")
  invisible(bad)
}

# Persist the attrition rows. Best-effort: a failure here must not lose a cohort
# table that was already written, so it warns rather than aborting -- the opposite
# call from the build steps, which are fatal.
ie_persist_attrition <- function(con, rows, funnel) {
  cfg <- funnel$cfg; h <- funnel$h
  if (!length(rows)) return(invisible(NULL))
  tbl <- h$work("ATTRITION_REPORT")
  q <- function(x) paste0("'", gsub("'", "''", as.character(x)), "'")
  i <- function(x) if (is.null(x) || is.na(x)) "NULL" else
    format(as.integer(x), scientific = FALSE, trim = TRUE)
  created <- q(format(Sys.time(), "%Y-%m-%d %H:%M:%S"))
  cohort <- q(h$work(cfg$final_table_name))
  vals <- vapply(seq_along(rows), function(k) {
    r <- rows[[k]]
    paste0("(", k, ", ", created, ", ", cohort, ", ",
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
