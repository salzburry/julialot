#!/usr/bin/env Rscript
# Compare this run's distributions against published figures.
#
#   # check the reference file and print what would be measured - no connection
#   Rscript lot/validation/run_benchmarks.R
#
#   # measure this run and compare
#   DATABRICKS_PWD=... DOMINO_USER_NAME=usr00000 OBJECT_PREFIX=ndmm_ \
#     BENCH_EXECUTE=TRUE Rscript lot/validation/run_benchmarks.R
#
# The published numbers come from benchmarks.csv, which ships with every row
# present and `published_value` blank. Nothing here invents one: a figure with
# no source is refused when the file loads.
#
# The output is never a pass or a fail. A gap is two studies differing until
# `comparable` in the reference file says otherwise; an unmarked row scores
# nothing.

.script_dir <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(a)) dirname(normalizePath(sub("^--file=", "", a[1]))) else getwd()
})
source(file.path(.script_dir, "R", "benchmarks.R"))
source(file.path(.script_dir, "R", "run_binding.R"))

LOT_ROOT <- normalizePath(file.path(.script_dir, "..", "engine"), mustWork = TRUE)
env_flag <- function(nm) identical(toupper(trimws(Sys.getenv(nm, unset = ""))), "TRUE")
out_dir  <- Sys.getenv("OUTPUT_DIR", unset = file.path(.script_dir, "out"))
ref_path <- Sys.getenv("BENCHMARK_FILE", unset = file.path(.script_dir, "benchmarks.csv"))

report_refs <- function(refs) {
  supplied <- !is.na(refs$published_value)
  cmp <- tolower(trimws(ifelse(is.na(refs$comparable), "", refs$comparable)))
  cat("\nReference file: ", ref_path, "\n", sep = "")
  cat("  ", nrow(refs), " rows, ", sum(supplied), " with a published value.\n", sep = "")
  if (sum(supplied))
    cat("  of those: ", sum(supplied & cmp == "yes"), " comparable, ",
        sum(supplied & cmp == "caveat"), " with a caveat, ",
        sum(supplied & cmp %in% c("no", "")), " recorded only.\n", sep = "")
  if (!sum(supplied))
    cat("  Nothing to compare against yet. Fill published_value, source and\n",
        "  comparable for the rows you have figures for; the rest stay blank\n",
        "  and are reported as 'no reference supplied'.\n", sep = "")
  cat("\nWhat is measured, and on what definition:\n\n")
  for (nm in names(BENCHMARK_METRICS)) {
    m <- BENCHMARK_METRICS[[nm]]
    cat("  ", nm, "  (", m$unit, ")\n    ", m$what, "\n    ", m$defn, "\n\n", sep = "")
  }
}

main <- function() {
  refs <- read_benchmarks(ref_path)
  report_refs(refs)

  if (!env_flag("BENCH_EXECUTE")) {
    cat("Nothing was measured. Set BENCH_EXECUTE=TRUE to run against a warehouse.\n")
    return(invisible(NULL))
  }
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")
  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  # One run owns these tables, and it has to have finished. "Median 2.1 lines"
  # carries nothing about where it came from, so the run is resolved first and
  # named in the output beside the numbers.
  run <- require_lot_run(con, cfg$object_prefix, "BENCH_IGNORE_BUILD_STATE")
  cat("\nMeasuring run ", run$run, " (prefix '", cfg$object_prefix,
      "'), built from ", run$cohort,
      if (!is.na(run$study_end) && nzchar(trimws(run$study_end)))
        paste0(", STUDY_END ", run$study_end) else "", ".\n", sep = "")

  # How many lines to ask for is the MEASURED RUN's max_lot, not this
  # package's. Point this at a run built with a different cap and cfg's value
  # asks for lines it never built, or leaves out lines it did.
  max_lot <- suppressWarnings(as.integer(
    lot_run_contract(con, cfg$object_prefix, "max_lot")))
  if (is.na(max_lot) || max_lot < 2L) {
    max_lot <- as.integer(cfg$max_lot)
    cat("  No max_lot recorded for that run (an older lot, or no metadata row) ",
        "- measuring to MAX_LOT=", max_lot, " from this package's config.\n", sep = "")
  } else if (!identical(max_lot, as.integer(cfg$max_lot))) {
    cat("  That run was built with max_lot=", max_lot, "; this package is ",
        "configured for ", cfg$max_lot, ". Measuring to the run's own value.\n",
        sep = "")
  }

  final    <- lot_out("LOT_LONG_FINAL")
  patients <- lot_out("LOT_PATIENT_INPUT")
  top_n    <- suppressWarnings(as.integer(Sys.getenv("BENCH_TOP_N", unset = "5")))
  if (is.na(top_n) || top_n < 1) top_n <- 5L

  add <- function(df, extra = character(0)) {
    if (is.null(df) || !nrow(df)) return(NULL)
    for (nm in c("line", "regimen", "denom", "censored", "events"))
      if (!nm %in% names(df)) df[[nm]] <- NA
    df[, c("metric", "line", "regimen", "observed", "denom", "censored", "events")]
  }
  obs <- list(
    add(db_q(con, bench_distribution_sql(final))),
    add(db_q(con, bench_reaching_sql(final, max_lot))),
    add(db_q(con, bench_duration_sql(final))),
    add(db_q(con, bench_regimen_sql(final, top_n))))
  # One statement per line: the risk set changes with the line. A loop is
  # clearer than a curve per group, and a line that fails costs only itself.
  # A line that fails costs only itself - but it must cost that visibly. This
  # used to print the error, contribute nothing, and let the run write the CSV
  # and exit 0: a measurement that was attempted and failed came out
  # indistinguishable from one nobody asked for, in a file whose whole purpose
  # is to say what was measured against what.
  failed <- integer(0)
  for (l in seq_len(max(1L, max_lot - 1L))) {
    r <- tryCatch(db_q(con, bench_ttnt_sql(final, patients, l)),
                  error = function(e) { cat("  TTNT line ", l, " failed: ",
                                            conditionMessage(e), "\n", sep = "")
                                        failed <<- c(failed, l); NULL })
    obs[[length(obs) + 1L]] <- add(r)
  }
  obs <- do.call(rbind, Filter(Negate(is.null), obs))
  if (is.null(obs) || !nrow(obs)) { cat("\nNo observations.\n"); return(invisible(NULL)) }

  res <- compare_benchmarks(obs, refs)
  # The run travels with the numbers - a benchmark table outlives its session.
  res$run_id <- run$run
  res$input_cohort_table <- run$cohort
  if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  # The canonical name is for a complete run. A run that lost a TTNT line is
  # not one, and it used to write this file anyway - so the artifact on disk
  # looked finished and only the exit status and the log said otherwise, which
  # is exactly the state a file outlives. A partial run writes a differently
  # named file that cannot be mistaken for the deliverable, and carries the
  # reason in a column so it travels with the rows rather than in a terminal.
  if (length(failed)) {
    res$incomplete <- paste0("TTNT failed for line(s) ",
                             paste(failed, collapse = ", "))
    f <- file.path(out_dir, "benchmarks_observed_vs_published.PARTIAL.csv")
  } else {
    f <- file.path(out_dir, "benchmarks_observed_vs_published.csv")
  }
  write.csv(res, f, row.names = FALSE)

  cat("\n", nrow(res), " measurements.\n", sep = "")
  for (v in c("compared", "compared with caveat", "recorded, not comparable",
              "no reference supplied", "no observation"))
    cat(sprintf("  %-26s %d\n", v, sum(res$verdict == v)))
  # Censoring decides whether a duration means anything.
  cn <- res[res$metric == "median_line_duration_days" & !is.na(res$censored), ]
  if (nrow(cn))
    for (i in seq_len(nrow(cn)))
      cat("  LOT", cn$line[i], " duration: ", cn$denom[i], " completed, ",
          cn$censored[i], " still open at study end and excluded.\n", sep = "")
  cat("\nWrote ", f, "\n", sep = "")
  cat("No row here is a pass or a fail. A difference is two studies differing ",
      "until the `comparable` column says otherwise.\n", sep = "")
  # The run is incomplete, and the file it just wrote does not say so - every
  # verdict in it is about the metrics that DID measure. Saying it here and in
  # the exit status is what keeps "we did not measure this" from being read as
  # "there was nothing to measure".
  if (length(failed)) {
    cat("\nINCOMPLETE: TTNT failed for line(s) ", paste(failed, collapse = ", "),
        ". Those rows carry no observation, and a reference sitting on one ",
        "reads 'no observation' - the same words as a metric nobody ran. ",
        "This is not a complete benchmark run, so it was written as ",
        basename(f), " rather than under the canonical name, and every row ",
        "carries an `incomplete` column saying why.\n", sep = "")
    return(invisible(structure(f, incomplete = failed)))
  }
  invisible(f)
}

if (!interactive()) {
  if (env_flag("BENCH_EXECUTE")) {
    library(DBI); library(odbc); library(glue)
    e <- new.env(parent = globalenv())
    sys.source(file.path(LOT_ROOT, "R", "load_inputs.R"), envir = e)
    e$load_pipeline_inputs(LOT_ROOT, "config.csv")
    for (f in c("config_lot.R", "db_utils_lot.R")) source(file.path(LOT_ROOT, "R", f))
    set_lot_config(modifyList(cfg_defaults, list(
      work_schema = Sys.getenv("PROJECT_WORK_SCHEMA",
                      unset = Sys.getenv("DOMINO_USER_NAME", unset = "")),
      object_prefix = Sys.getenv("OBJECT_PREFIX", unset = ""))))
  }
  r <- main()
  # Non-zero, so a scheduled run cannot report success on a partial measurement.
  if (length(attr(r, "incomplete"))) quit(status = 1L)
}
