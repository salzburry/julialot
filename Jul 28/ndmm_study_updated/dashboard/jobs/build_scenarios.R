#!/usr/bin/env Rscript
# Run the study package once per scenario, then export what each run wrote.
#
# One Domino Job. It is the only thing here that writes: the dashboard reads.
#
#   Rscript dashboard/jobs/build_scenarios.R [scenarios.csv] [out_dir]
#
# Each row of scenarios.csv is one run. `prefix` is the OBJECT_PREFIX it writes
# under, and every other column whose name is upper case is set as an
# environment variable for that run and nothing else. So a scenario is added by
# adding a row, and a NEW open question becomes available the moment the
# package reads it - the column name is the variable name.
#
# A scenario whose run fails does not stop the others. Its tables are left
# alone and the summary at the end says which failed, because a grid that
# quietly came back four-of-five would be read as five.

args <- commandArgs(trailingOnly = TRUE)
here <- normalizePath(file.path(dirname(sub("^--file=", "", grep("^--file=",
  commandArgs(FALSE), value = TRUE)[1])), ".."), mustWork = FALSE)
if (!nzchar(here) || is.na(here)) here <- getwd()

grid_csv <- if (length(args) >= 1) args[1] else file.path(here, "scenarios.csv")
out_dir  <- if (length(args) >= 2) args[2] else
  Sys.getenv("DASH_SNAPSHOT_DIR", "/mnt/artifacts/results")
pkg_dir  <- Sys.getenv("DASH_PACKAGE_DIR", file.path(dirname(here), "study223926"))

if (!file.exists(grid_csv)) stop("No scenario grid at ", grid_csv, call. = FALSE)
grid <- utils::read.csv(grid_csv, stringsAsFactors = FALSE)
if (!"prefix" %in% names(grid)) stop("scenarios.csv needs a `prefix` column.",
                                     call. = FALSE)
if (anyDuplicated(grid$prefix))
  stop("Two scenarios share a prefix: ",
       paste(unique(grid$prefix[duplicated(grid$prefix)]), collapse = ", "),
       ". Each writes under its own, so one would overwrite the other.",
       call. = FALSE)

# The columns that are settings. Upper case by convention, which is also how
# the package names its environment variables.
set_cols <- grep("^[A-Z][A-Z0-9_]*$", names(grid), value = TRUE)
message("Scenario grid: ", nrow(grid), " run(s), ", length(set_cols),
        " setting(s) each: ", paste(set_cols, collapse = ", "))

# Which tables to export. Read off the package's own registry rather than
# listed, so a module added there is exported without editing this file.
local({
  for (f in c("config_223926.R", "db_utils_223926.R", "registry.R"))
    source(file.path(pkg_dir, "R", f))
})
EXPORT <- unique(c("S_RUN_METADATA",
                   unlist(lapply(MODULES, `[[`, "outputs"), use.names = FALSE)))

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

run_one <- function(row) {
  prefix <- trimws(row[["prefix"]])
  env <- character(0)
  for (k in set_cols) {
    v <- trimws(as.character(row[[k]]))
    if (nzchar(v) && !identical(v, "NA")) env[[k]] <- v
  }
  env[["OBJECT_PREFIX"]] <- prefix
  message("\n=== ", prefix, " ===")
  for (k in names(env)) message("  ", k, "=", env[[k]])

  # A separate R process per scenario. In one process the package's config,
  # its code-list manifest and its input columns would have to be reset
  # between runs - reset_run_state() does that, but a scenario that dies
  # mid-run would still leave a session the next one inherits. A process per
  # run cannot.
  code <- sprintf("setwd(%s); source('build.R')", shQuote(pkg_dir))
  res <- system2("Rscript", c("-e", shQuote(code)), env = paste0(names(env), "=", env),
                 stdout = TRUE, stderr = TRUE)
  status <- attr(res, "status")
  ok <- is.null(status) || identical(status, 0L)
  if (!ok) message("  FAILED: ", paste(utils::tail(res, 8), collapse = "\n  "))
  list(prefix = prefix, ok = ok, log = res)
}

export_one <- function(prefix) {
  # Read back what the run wrote and put it beside the others as CSV, which is
  # what a Domino App can read without a warehouse session per viewer.
  d <- file.path(out_dir, prefix)
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
  cfg <- local({
    Sys.setenv(OBJECT_PREFIX = prefix)
    for (f in c("config_223926.R", "db_utils_223926.R", "registry.R"))
      source(file.path(pkg_dir, "R", f))
    cfg_defaults()
  })
  con <- connect_db(cfg)
  on.exit(try(disconnect_db(con), silent = TRUE), add = TRUE)
  set_study_config(cfg)
  n <- 0L
  for (tb in EXPORT) {
    got <- tryCatch(db_q(con, sprintf("SELECT * FROM %s", wrk(tb))),
                    error = function(e) NULL)
    if (is.null(got) || !nrow(got)) next
    utils::write.csv(got, file.path(d, paste0(tb, ".csv")), row.names = FALSE,
                     na = "")
    n <- n + 1L
  }
  message("  exported ", n, " table(s) to ", d)
  n
}

results <- lapply(seq_len(nrow(grid)), function(i) run_one(grid[i, ]))
exported <- lapply(results, function(r)
  if (r$ok) tryCatch(export_one(r$prefix), error = function(e) {
    message("  export failed: ", conditionMessage(e)); 0L }) else 0L)

message("\n", strrep("-", 60))
for (i in seq_along(results))
  message(sprintf("%-16s %-8s %d table(s)", results[[i]]$prefix,
                  if (results[[i]]$ok) "ok" else "FAILED", exported[[i]]))
failed <- vapply(results, function(r) !r$ok, logical(1))
if (any(failed)) {
  message(sum(failed), " scenario(s) failed. The dashboard will show the ones ",
          "that finished and mark the rest.")
  quit(status = 1L)
}
message("All ", nrow(grid), " scenario(s) built and exported to ", out_dir)
