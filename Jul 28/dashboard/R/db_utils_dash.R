# Reading only. This package writes no warehouse table: it renders what the
# cohort and LOT builds already produced. Nothing here creates, replaces or
# drops anything, which is what makes it safe to re-run against a finished
# study whenever somebody wants the numbers again.

with_retry <- function(fn, max_retries = dash_config()$max_retries,
                       base_sleep = dash_config()$base_sleep) {
  permanent <- c("TABLE_OR_VIEW_NOT_FOUND", "AnalysisException",
                 "PARSE_SYNTAX_ERROR", "UNRESOLVED_COLUMN",
                 "does not exist", "cannot be found")
  attempt <- 1L
  repeat {
    out <- tryCatch(fn(), error = function(e) e)
    if (!inherits(out, "error")) return(out)
    msg <- conditionMessage(out)
    if (attempt >= max_retries || any(vapply(permanent, grepl, logical(1),
                                             x = msg, fixed = TRUE)))
      stop(msg, call. = FALSE)
    Sys.sleep(base_sleep * 2^(attempt - 1L))
    attempt <- attempt + 1L
  }
}

db_q <- function(con, sql) with_retry(function() DBI::dbGetQuery(con, sql))

# <catalog>.<schema>.<table>, or <schema>.<table> when no catalog is set. The
# schema is the work schema the cohort and LOT builds wrote into.
full_name <- function(schema, object) {
  cfg <- dash_config()
  if (nzchar(cfg$catalog)) paste0(cfg$catalog, ".", schema, ".", object)
  else paste0(schema, ".", object)
}

wrk <- function(tbl) full_name(dash_config()$work_schema, tbl)

# The tables a section may name. Every one is resolved once, up front, so a
# section cannot invent a name and a missing table is reported against the
# input rather than against whichever panel happened to read it first.
dashboard_inputs <- function(cfg) {
  lp <- cfg$lot_prefix
  cp <- if (nzchar(cfg$cohort_prefix)) cfg$cohort_prefix else lp
  list(
    cohort    = wrk(cfg$input_cohort_table),
    patients  = wrk(paste0(lp, "LOT_PATIENT_INPUT")),
    lot_long  = wrk(paste0(lp, "LOT_LONG")),
    lot_final = wrk(paste0(lp, "LOT_LONG_FINAL")),
    run_meta  = wrk(paste0(lp, "LOT_RUN_METADATA")),
    attrition = wrk(paste0(cp, "NDMM_ATTRITION"))
  )
}

# Which of them are actually there. A study that ran the LOT build but not the
# cohort build has no attrition table, and that is a section to skip with a
# note rather than a run to fail: the rest of the dashboard is still true.
probe_inputs <- function(con, inputs) {
  vapply(inputs, function(tbl)
    isTRUE(tryCatch({ db_q(con, paste0("SELECT 1 FROM ", tbl, " LIMIT 1")); TRUE },
                    error = function(e) FALSE)),
    logical(1))
}
