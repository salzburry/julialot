#!/usr/bin/env Rscript
# Compare this run's distributions against published figures.
#
#   # check the reference file and print what would be measured - no connection
#   Rscript lot_validation/run_benchmarks.R
#
#   # measure this run and compare
#   DATABRICKS_PWD=... DOMINO_USER_NAME=usr00000 OBJECT_PREFIX=ndmm_ \
#     BENCH_EXECUTE=TRUE Rscript lot_validation/run_benchmarks.R
#
# The published numbers come from benchmarks.csv, which ships with every row
# present and `published_value` blank. Nothing here invents one: a figure with
# no source is refused when the file loads, so a convenient number cannot
# become a citation.
#
# The output is never a pass or a fail. A gap between this cohort and a
# published one is a difference between two studies until somebody says which,
# and `comparable` in the reference file is where they say it. An unmarked row
# is reported and scored as nothing.

.script_dir <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(a)) dirname(normalizePath(sub("^--file=", "", a[1]))) else getwd()
})
source(file.path(.script_dir, "R", "benchmarks.R"))

LOT_ROOT <- normalizePath(file.path(.script_dir, "..", "lot"), mustWork = TRUE)
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
    add(db_q(con, bench_reaching_sql(final, cfg$max_lot))),
    add(db_q(con, bench_duration_sql(final))),
    add(db_q(con, bench_regimen_sql(final, top_n))))
  # TTNT is one statement per line: the risk set changes with the line, and one
  # combined query would need a curve per group and the same window trick per
  # partition. Clearer as a loop, and a line that fails costs only itself.
  for (l in seq_len(max(1L, as.integer(cfg$max_lot) - 1L))) {
    r <- tryCatch(db_q(con, bench_ttnt_sql(final, patients, l)),
                  error = function(e) { cat("  TTNT line ", l, " failed: ",
                                            conditionMessage(e), "\n", sep = ""); NULL })
    obs[[length(obs) + 1L]] <- add(r)
  }
  obs <- do.call(rbind, Filter(Negate(is.null), obs))
  if (is.null(obs) || !nrow(obs)) { cat("\nNo observations.\n"); return(invisible(NULL)) }

  res <- compare_benchmarks(obs, refs)
  if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  f <- file.path(out_dir, "benchmarks_observed_vs_published.csv")
  write.csv(res, f, row.names = FALSE)

  cat("\n", nrow(res), " measurements.\n", sep = "")
  for (v in c("compared", "compared with caveat", "recorded, not comparable",
              "no reference supplied", "no observation"))
    cat(sprintf("  %-26s %d\n", v, sum(res$verdict == v)))
  # Censoring is the number that decides whether a duration means anything.
  cn <- res[res$metric == "median_line_duration_days" & !is.na(res$censored), ]
  if (nrow(cn))
    for (i in seq_len(nrow(cn)))
      cat("  LOT", cn$line[i], " duration: ", cn$denom[i], " completed, ",
          cn$censored[i], " still open at study end and excluded.\n", sep = "")
  cat("\nWrote ", f, "\n", sep = "")
  cat("No row here is a pass or a fail. A difference is two studies differing ",
      "until the `comparable` column says otherwise.\n", sep = "")
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
  main()
}
