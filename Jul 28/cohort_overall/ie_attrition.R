# =============================================================================
# ie_attrition.R -- the attrition table, and the check that it landed
# -----------------------------------------------------------------------------
# The table is cumulative: each row is how many patients survive every gate up to
# and including that one, so a gate's drop is the difference from the row above.
# Counts are count(DISTINCT PATID), so a patient with several surviving candidate
# index dates counts once per row.
#
# The 30 / 60 / 90 columns come from one query per row. The three windows differ
# only in which outpt2_* column step 1 reads, and all three are on the flags
# table. The configured window is the build; the other two are free sensitivity
# numbers.
#
# Step 0 comes from mm_dx_events_id, not the flags table. The flags table only
# holds patients who already have a qualifying index date, so step 0 counted
# there would equal step 1 and the biggest drop in the study would disappear.
#
# The funnel does not check itself. Every row re-runs the predicates over the
# flags table and never reads the cohort table, so it cannot see a wrong object
# written, a wrong index date picked, duplicate PATIDs, or a failed write.
# ie_reconcile() does that, after every build.
# =============================================================================

ie_attrition_rows <- function(con, funnel) {
  cfg <- funnel$cfg; h <- funnel$h
  tbl      <- h$work(cfg$flags_view)
  base_tbl <- h$work("mm_dx_events_id")

  qual <- list(w30 = "(inpt_qual = 1 OR outpt2_30 = 1)",
               w60 = "(inpt_qual = 1 OR outpt2_60 = 1)",
               w90 = "(inpt_qual = 1 OR outpt2_90 = 1)")

  rows <- list()
  record <- function(step_id, description, n)
    rows[[length(rows) + 1L]] <<- list(step_id = step_id,
                                       description = description,
                                       n_30 = n$n_30, n_60 = n$n_60,
                                       n_90 = n$n_90)
  count_3w <- function(w30, w60, w90, from_tbl = tbl) {
    r <- DBI::dbGetQuery(con, paste0(
      "SELECT\n",
      "  count(DISTINCT CASE WHEN ", w30, " THEN PATID END) AS n_30,\n",
      "  count(DISTINCT CASE WHEN ", w60, " THEN PATID END) AS n_60,\n",
      "  count(DISTINCT CASE WHEN ", w90, " THEN PATID END) AS n_90\n",
      "FROM ", from_tbl))
    list(n_30 = r$n_30[1], n_60 = r$n_60[1], n_90 = r$n_90[1])
  }

  record("00_step0_base", "Step 0: >= 1 MM dx (any position)",
         count_3w("1=1", "1=1", "1=1", from_tbl = base_tbl))

  # Step 1 is the qualifying condition itself, so it is the first cumulative row
  # rather than a clause on top of one.
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
  attr(rows, "cum_where") <- paste0(qual[[paste0("w", cfg$outpatient_window)]],
                                    cum)
  rows
}

ie_print_attrition <- function(rows, cfg) {
  sep <- strrep("=", 84)
  cat("\n", sep, "\n", sep = "")
  cat("  ATTRITION -- OVERALL COHORT   (configured window ",
      cfg$outpatient_window, "d)\n", sep = "")
  cat(sep, "\n", sep = "")
  cat(sprintf("%-45s %12s %12s %12s\n", "Step", "30-day", "60-day", "90-day"))
  cat(strrep("-", 84), "\n", sep = "")
  for (r in rows)
    cat(sprintf("%-45s %12s %12s %12s\n", substr(r$description, 1, 45),
                format(r$n_30, big.mark = ","), format(r$n_60, big.mark = ","),
                format(r$n_90, big.mark = ",")))
  cat(sep, "\n", sep = "")
  invisible(rows)
}

# ---- reconciliation ---------------------------------------------------------
# Does the cohort table match the funnel? Five checks, each of which can fail
# while every attrition row still looks fine.
#
# The index-date check is the one no text comparison can make. If the ranking ran
# before the filter, or over the wrong order, the first three checks could pass
# while patients carried the wrong index date -- and every LOT number downstream
# is computed from that date.
# final_tbl defaults to the published cohort. The runner passes the STAGED table,
# so the build is checked before it is published under the real name.
ie_reconcile <- function(con, funnel, cum_where,
                         final_tbl = funnel$h$work(funnel$cfg$final_table_name)) {
  cfg <- funnel$cfg; h <- funnel$h
  flags <- h$work(cfg$flags_view)
  final <- final_tbl
  q <- function(sql) DBI::dbGetQuery(con, sql)
  out <- list()
  add <- function(name, ok, detail)
    out[[length(out) + 1L]] <<- list(name = name, ok = isTRUE(ok),
                                     detail = detail)

  g <- q(paste0("SELECT count(*) AS n_rows, count(DISTINCT PATID) AS n_pat,",
                " sum(CASE WHEN PATID IS NULL THEN 1 ELSE 0 END) AS n_null_pat,",
                " sum(CASE WHEN INDEX_DATE IS NULL THEN 1 ELSE 0 END) AS n_null_idx",
                " FROM ", final))
  add("one row per PATID", g$n_rows[1] == g$n_pat[1],
      paste0(format(g$n_rows[1], big.mark = ","), " rows / ",
             format(g$n_pat[1], big.mark = ","), " patients"))
  add("no NULL PATID or INDEX_DATE",
      g$n_null_pat[1] == 0 && g$n_null_idx[1] == 0,
      paste0(g$n_null_pat[1], " / ", g$n_null_idx[1]))

  f <- q(paste0("SELECT count(DISTINCT PATID) AS n FROM ", flags, " WHERE ",
                cum_where))
  add("count == funnel end", g$n_pat[1] == f$n[1],
      paste0("cohort ", format(g$n_pat[1], big.mark = ","), " vs funnel ",
             format(f$n[1], big.mark = ",")))

  surviving <- paste0("SELECT PATID, INDEX_DATE FROM ", flags, " WHERE ",
                      cum_where)
  for (d in list(list(lab = "in cohort but not surviving the funnel",
                      x = paste0("SELECT DISTINCT PATID FROM ", final),
                      y = paste0("SELECT DISTINCT PATID FROM (", surviving, ")")),
                 list(lab = "surviving the funnel but not in cohort",
                      x = paste0("SELECT DISTINCT PATID FROM (", surviving, ")"),
                      y = paste0("SELECT DISTINCT PATID FROM ", final)))) {
    n <- q(paste0("SELECT count(*) AS n FROM (", d$x, " EXCEPT ", d$y, ")"))$n[1]
    add(d$lab, n == 0, format(n, big.mark = ","))
  }

  n_wrong <- q(paste0(
    "WITH surv AS (", surviving, "),\n",
    "     earliest AS (SELECT PATID, min(INDEX_DATE) AS min_idx FROM surv",
    " GROUP BY PATID)\n",
    "SELECT count(*) AS n FROM ", final, " c\n",
    "JOIN earliest e ON c.PATID = e.PATID\n",
    "WHERE c.INDEX_DATE <> e.min_idx"))$n[1]
  add("INDEX_DATE == earliest surviving candidate", n_wrong == 0,
      paste0(format(n_wrong, big.mark = ","), " differ"))

  out
}

ie_print_reconcile <- function(results, funnel) {
  cat("\n", strrep("=", 84), "\n", sep = "")
  cat("  RECONCILIATION -- ", funnel$h$work(funnel$cfg$final_table_name), "\n",
      sep = "")
  cat(strrep("=", 84), "\n", sep = "")
  for (r in results)
    cat(sprintf("  %-4s %-52s %s\n", if (r$ok) "ok" else "FAIL", r$name,
                r$detail))
  bad <- sum(!vapply(results, function(r) r$ok, logical(1)))
  cat(strrep("=", 84), "\n", sep = "")
  cat(if (bad) paste0("  ", bad, " check(s) FAILED.\n")
      else "  The cohort table matches the funnel.\n")
  cat("  Internal consistency only -- not a comparison with the legacy cohort.\n")
  invisible(bad)
}

# Persist the attrition rows so the numbers outlive the run. Best-effort: a
# failure here must not lose a cohort table that was already written.
ie_persist_attrition <- function(con, rows, funnel) {
  cfg <- funnel$cfg; h <- funnel$h
  if (!length(rows)) return(invisible(NULL))
  tbl <- h$work("ATTRITION_REPORT")
  q <- function(x) paste0("'", gsub("'", "''", as.character(x)), "'")
  i <- function(x) if (is.null(x) || is.na(x)) "NULL" else
    format(as.integer(x), scientific = FALSE, trim = TRUE)
  created <- q(format(Sys.time(), "%Y-%m-%d %H:%M:%S"))
  cohort  <- q(h$work(cfg$final_table_name))
  vals <- vapply(seq_along(rows), function(k) {
    r <- rows[[k]]
    paste0("(", k, ", ", created, ", ", cohort, ", ",
           i(cfg$outpatient_window), ", ", q(r$step_id), ", ",
           q(r$description), ", ", i(r$n_30), ", ", i(r$n_60), ", ",
           i(r$n_90), ")")
  }, character(1))
  sql <- paste0("CREATE OR REPLACE TABLE ", tbl, " AS\nSELECT * FROM VALUES\n  ",
                paste(vals, collapse = ",\n  "),
                "\nAS t(row_order, created_at, cohort_table, outpatient_window,",
                "\n     step_id, description, n_30, n_60, n_90)")
  tryCatch({
    DBI::dbExecute(con, sql)
    message("attrition -> ", tbl, " (", length(rows), " rows)")
  }, error = function(e)
    message("WARN: could not write ", tbl, ": ", conditionMessage(e)))
  invisible(tbl)
}

# ---- run status, staging, cleanup -------------------------------------------
# This build has been run many times against the same personal schema, so the
# controls below are about telling one run's output from another's and not
# leaving a half-built or stale cohort looking current.

# A run id: DOMINO_RUN_ID if set, else a timestamp. Passed in, because a
# timestamp read here would differ between the "started" and "complete" rows.
ie_run_id <- function()
  Sys.getenv("DOMINO_RUN_ID",
             unset = format(Sys.time(), "%Y%m%d_%H%M%S"))

# One row per build attempt, overwritten each run. It records who wrote the
# current tables and whether the run finished, so a reader can tell whether
# ovr_ELIG_COH_FINAL belongs to a completed build or an abandoned one.
ie_write_status <- function(con, funnel, run_id, state, n_final = NA,
                            started = "") {
  cfg <- funnel$cfg; h <- funnel$h
  tbl <- h$work("RUN_STATUS")
  q <- function(x) paste0("'", gsub("'", "''", as.character(x)), "'")
  now <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
  n <- if (is.na(n_final)) "NULL" else
    format(as.integer(n_final), scientific = FALSE, trim = TRUE)
  sql <- paste0(
    "CREATE OR REPLACE TABLE ", tbl, " AS SELECT ",
    q(run_id), " AS run_id, ", q(state), " AS state, ",
    q(if (nzchar(started)) started else now), " AS started_at, ",
    q(now), " AS updated_at, ", q(h$work(cfg$final_table_name)), " AS cohort_table, ",
    q(cfg$out_schema), " AS out_schema, ", q(cfg$study_start), " AS study_start, ",
    q(cfg$study_end), " AS study_end, ", q(cfg$id_start), " AS id_start, ",
    q(cfg$id_end), " AS id_end, ", cfg$outpatient_window, " AS outpatient_window, ",
    cfg$min_age, " AS min_age, ", n, " AS n_final")
  tryCatch(DBI::dbExecute(con, sql),
           error = function(e)
             message("WARN: could not write ", tbl, ": ", conditionMessage(e)))
  invisible(tbl)
}

# Publish the staged cohort under its real name, then drop the staging table.
# Only called after reconciliation passes, so the published cohort is only ever
# replaced by a reconciled build.
ie_publish_final <- function(con, funnel) {
  h <- funnel$h; cfg <- funnel$cfg
  final <- h$work(cfg$final_table_name)
  stg   <- paste0(final, "__stg")
  DBI::dbExecute(con, paste0("CREATE OR REPLACE TABLE ", final,
                             " AS SELECT * FROM ", stg))
  try(DBI::dbExecute(con, paste0("DROP TABLE IF EXISTS ", stg)), silent = TRUE)
  log_msg("published ", final)
  invisible(final)
}

# Drop the intermediate tables after a clean build. Deliverables stay. Set
# IE_KEEP_INTERMEDIATE=TRUE to keep them for debugging.
ie_cleanup_intermediates <- function(con, funnel) {
  if (identical(toupper(Sys.getenv("IE_KEEP_INTERMEDIATE", unset = "FALSE")),
                "TRUE")) {
    message("IE_KEEP_INTERMEDIATE=TRUE; leaving intermediates in place")
    return(invisible(NULL))
  }
  cfg <- funnel$cfg; h <- funnel$h
  keep <- IE_DELIVERABLES(cfg)
  dropped <- 0L
  for (v in funnel$views) {
    if (v$name %in% keep) next
    try({ DBI::dbExecute(con, paste0("DROP TABLE IF EXISTS ", h$work(v$name)))
          dropped <- dropped + 1L }, silent = TRUE)
  }
  log_msg("dropped ", dropped, " intermediate table(s); kept ",
          paste(paste0(cfg$obj_prefix, keep), collapse = ", "))
  invisible(dropped)
}
