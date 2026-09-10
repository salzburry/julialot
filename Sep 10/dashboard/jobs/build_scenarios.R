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
pkg_dir  <- Sys.getenv("DASH_PACKAGE_DIR",
                       file.path(dirname(here), "ndmm_study_updated", "study223926"))

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

source(file.path(here, "jobs", "export_lib.R"))
# The reader's own binding rules - which metadata row is the current build,
# and whether a LOT prefix belongs to a run - so the job files a snapshot the
# way the app will read it.
source(file.path(here, "R", "sources.R"))
source(file.path(here, "R", "scenarios.R"))

# Which tables to export. Read off the package's own registry rather than
# listed, so a module added there is exported without editing this file.
local({
  for (f in c("config_223926.R", "db_utils_223926.R", "registry.R"))
    source(file.path(pkg_dir, "R", f))
})
EXPORT <- unique(c("S_RUN_METADATA",
                   unlist(lapply(MODULES, `[[`, "outputs"), use.names = FALSE)))

# The LOT build's own outputs, exported once per LOT RUN rather than once per
# scenario. Scenarios normally share a LOT run - none of the study's open
# questions changes how a line is counted - so a copy each would waste the
# space and, worse, suggest they differ.
LOT_EXPORT <- c("LOT_LONG_FINAL", "LOT_LONG", "LOT_ATTRITION",
                "LOT_FACE_VALIDITY", "LOT_QC_SUMMARY", "LOT_RUN_METADATA",
                "LOT_BUILD_STATUS")

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

run_one <- function(row, env) {
  prefix <- trimws(row[["prefix"]])
  message("\n=== ", prefix, " ===")
  for (k in names(env)) message("  ", k, "=", env[[k]])

  # A separate R process per scenario. In one process the package's config,
  # its code-list manifest and its input columns would have to be reset
  # between runs - reset_run_state() does that, but a scenario that dies
  # mid-run would still leave a session the next one inherits. A process per
  # run cannot.
  code <- sprintf("setwd(%s); source('build.R')", shQuote(pkg_dir))
  # The settings go into this process's environment for the duration, which
  # the child inherits everywhere; system2's env= is a command-line prefix
  # that Windows ignores.
  res <- with_env(env, system2("Rscript", c("-e", shQuote(code)),
                               stdout = TRUE, stderr = TRUE))
  status <- attr(res, "status")
  ok <- is.null(status) || identical(status, 0L)
  if (!ok) message("  FAILED: ", paste(utils::tail(res, 8), collapse = "\n  "))
  list(prefix = prefix, ok = ok, log = res)
}

export_one <- function(prefix, env) {
  # Read back what the run wrote and put it beside the others as CSV, which is
  # what a Domino App can read without a warehouse session per viewer.
  #
  # Written to a STAGING directory and swapped in at the end. Writing into the
  # live one meant a refresh that failed halfway left the new tables it had
  # managed beside the old ones it had not, under one run's metadata - and the
  # app, which reads the metadata at startup and the tables later, presented
  # that mixture as one run.
  d     <- file.path(out_dir, prefix)
  stage <- file.path(out_dir, paste0(".", prefix, ".staging"))
  unlink(stage, recursive = TRUE)
  dir.create(stage, recursive = TRUE, showWarnings = FALSE)
  on.exit(unlink(stage, recursive = TRUE), add = TRUE)
  # The row's own settings, exactly as the child build received them, plus the
  # package's config.csv defaults - which the child gets from
  # load_pipeline_inputs() and this did not load at all.
  cfg <- with_env(env, local({
    for (f in c("load_inputs.R", "config_223926.R", "db_utils_223926.R",
                "registry.R"))
      source(file.path(pkg_dir, "R", f))
    load_pipeline_inputs(pkg_dir, "config.csv")
    cfg_defaults()
  }))
  con <- connect_db(cfg)
  on.exit(try(disconnect_db(con), silent = TRUE), add = TRUE)
  # WORK_SCHEMA unset means "wherever the session lands", and the build
  # resolves it that way too (run_223926.R). Left blank, wrk() built a name
  # with an empty schema in it.
  if (!nzchar(cfg$work_schema)) cfg$work_schema <- current_work_schema(con)
  set_study_config(cfg)
  # The build being exported, pinned BEFORE any table is read: the newest
  # metadata row, and it has to be complete. Every table is read against
  # that pin and the row is read again after the last one. Metadata used to
  # be exported first and re-read only to see that A row existed, so a
  # rebuild landing mid-export published one build's metadata beside
  # another's rows - and the app, which binds a snapshot to the identity its
  # own metadata carries, read that mixture as one run.
  meta_src <- list(read = function(prefix, table)
    tryCatch(db_q(con, sprintf("SELECT * FROM %s", wrk(table))),
             error = function(e) NULL))
  pin <- newest_metadata_row(meta_src, prefix)
  if (is.null(pin))
    stop("the run wrote no S_RUN_METADATA, so this snapshot cannot be ",
         "attributed to a run", call. = FALSE)
  gen <- run_identity(pin)
  if (!identical(tolower(gen$state), "complete"))
    stop("the newest run under ", prefix, " is '", gen$state, "', not ",
         "complete, so there is nothing finished to export", call. = FALSE)
  # What the run WROTE, off its own row: the modules it ran and the cohorts
  # it built. A run writes only those and leaves the rest of the prefix as
  # the previous run left it, so a table its metadata does not claim, and
  # rows of cohorts it did not select, are not this run's and do not enter
  # its snapshot - whatever sits under the prefix. The same rules the app
  # reads by (scenario_wrote, restrict_to_cohorts in R/sources.R).
  scen <- scenario_from_row(prefix, pin)
  if (!length(scen$modules) || !length(scen$cohorts))
    stop("the run under ", prefix, " recorded no modules or no cohorts, so ",
         "nothing under the prefix can be attributed to it", call. = FALSE)
  n <- 0L; bad <- character(0); not_this_run <- character(0)
  for (tb in EXPORT) {
    if (!scenario_wrote(scen, tb)) { not_this_run <- c(not_this_run, tb); next }
    r <- read_export(con, wrk(tb), optional = TRUE)
    if (identical(r$state, "failed")) { bad <- c(bad, paste0(tb, ": ", r$why)); next }
    if (identical(r$state, "absent")) next
    # A table that legitimately holds no rows is exported as its header, so
    # the snapshot says "none" rather than saying nothing.
    utils::write.csv(restrict_to_cohorts(r$data, scen),
                     file.path(stage, paste0(tb, ".csv")),
                     row.names = FALSE, na = "")
    n <- n + 1L
  }
  if (length(not_this_run))
    message("  ", length(not_this_run), " table(s) left out as not written by ",
            "this run (modules: ", paste(scen$modules, collapse = ", "), ")")
  if (length(bad))
    stop("could not read ", length(bad), " table(s): ",
         paste(utils::head(bad, 3), collapse = "; "), call. = FALSE)
  # Still the build that was pinned? Any rebuild moves UPDATED_AT, and a
  # build in progress moves STATE, so a change in either means the tables
  # above are not one build's.
  now <- run_identity(newest_metadata_row(meta_src, prefix))
  if (!identical(now, gen))
    stop("the run under ", prefix, " changed while its tables were being ",
         "read (", gen$run_id, " ", gen$state, " ", gen$updated_at, " -> ",
         now$run_id, " ", now$state, " ", now$updated_at, "), so what was ",
         "read is not one build's", call. = FALSE)
  message("  exported ", n, " table(s) for ", prefix)

  # The lines this scenario read: the LOT run, and the BUILD of it, off the
  # pinned row. Filed by both, and skipped when another scenario already
  # exported that build.
  lot_id <- trimws(as.character(pin$LOT_RUN_ID[1] %||% ""))
  lot_version <- if ("LOT_RUN_VERSION" %in% names(pin))
    trimws(as.character(pin$LOT_RUN_VERSION[1] %||% "")) else ""
  if (identical(lot_version, "NA")) lot_version <- ""
  if (!nzchar(lot_id) || identical(lot_id, "NA") || identical(lot_id, "unproven")) {
    message("  no LOT run recorded, so no LOT tables exported")
    return(publish(stage, d, n, prefix, ""))
  }
  # The prefix has to be owned by THIS run - this build of it - before a
  # table is copied under its name, and still owned by it afterwards; a
  # rebuild landing between the two reads would otherwise file the new lines
  # under the old id.
  owner <- function() lot_prefix_owner_ok(con, lot_tbl("LOT_BUILD_STATUS"),
                                          lot_id, lot_version)
  ld <- file.path(out_dir, "lot", lot_dir_name(lot_id, lot_version))
  if (dir.exists(ld) && length(list.files(ld, pattern = "[.]csv$"))) {
    # A directory named by run AND build is that build, whoever exported it,
    # and cannot be anything else. One named by run alone was written before
    # builds were recorded; the prefix may since have been rebuilt under the
    # same id, so it is reused only while the prefix still belongs to that
    # run, and the run is re-exported into a build-named directory otherwise.
    if (nzchar(lot_version) || owner()) {
      message("  LOT run ", lot_id, if (nzchar(lot_version))
        paste0(" build ", lot_version) else "",
        " already exported by an earlier scenario")
      return(publish(stage, d, n, prefix, lot_id))
    }
  }
  if (!owner())
    stop("the LOT prefix does not currently belong to run ", lot_id,
         if (nzchar(lot_version)) paste0(" build ", lot_version) else "",
         " (its newest status row names another run or another build of it, ",
         "or is not complete), so its tables cannot be filed under that ",
         "run's name", call. = FALSE)
  lstage <- file.path(out_dir, "lot",
                      paste0(".", lot_dir_name(lot_id, lot_version), ".staging"))
  unlink(lstage, recursive = TRUE)
  dir.create(lstage, recursive = TRUE, showWarnings = FALSE)
  on.exit(unlink(lstage, recursive = TRUE), add = TRUE)
  ln <- 0L; lbad <- character(0)
  for (tb in LOT_EXPORT) {
    r <- read_export(con, lot_tbl(tb), optional = TRUE)
    if (identical(r$state, "failed")) { lbad <- c(lbad, tb); next }
    if (identical(r$state, "absent")) next
    utils::write.csv(r$data, file.path(lstage, paste0(tb, ".csv")),
                     row.names = FALSE, na = "")
    ln <- ln + 1L
  }
  if (length(lbad))
    stop("could not read ", length(lbad), " LOT table(s) for run ", lot_id,
         ": ", paste(lbad, collapse = ", "), call. = FALSE)
  if (!owner())
    stop("the LOT prefix was rebuilt while run ", lot_id, "'s tables were ",
         "being read, so what was read is not one run's", call. = FALSE)
  message("  read ", ln, " LOT table(s) for run ", lot_id)
  publish(stage, d, n, prefix, lot_id, lstage, ld)
}

`%||%` <- function(a, b) if (is.null(a)) b else a

envs     <- lapply(seq_len(nrow(grid)), function(i) scenario_env(grid[i, ], set_cols))
results  <- lapply(seq_len(nrow(grid)), function(i) run_one(grid[i, ], envs[[i]]))
exports  <- lapply(seq_along(results), function(i) {
  r <- results[[i]]
  if (!r$ok) return(list(ok = FALSE, n = 0L, why = "the build failed"))
  tryCatch(list(ok = TRUE, n = export_one(r$prefix, envs[[i]]), why = ""),
           error = function(e) {
             message("  export FAILED: ", conditionMessage(e))
             list(ok = FALSE, n = 0L, why = conditionMessage(e))
           })
})

message("\n", strrep("-", 60))
for (i in seq_along(results))
  message(sprintf("%-16s %-8s %-9s %d table(s)", results[[i]]$prefix,
                  if (results[[i]]$ok) "built" else "FAILED",
                  if (exports[[i]]$ok) "exported" else "NOT PUBLISHED",
                  exports[[i]]$n))
# An export that failed is a failed job. It used to become a zero-table count,
# and the footer then said "built and exported" and exited 0 while a scenario
# had published nothing - or, worse, had left the previous snapshot in place
# under the new run's name.
failed <- vapply(results, function(r) !r$ok, logical(1))
ex_failed <- vapply(exports, function(e) !e$ok, logical(1)) & !failed
if (any(failed) || any(ex_failed)) {
  if (any(failed))
    message(sum(failed), " scenario(s) failed to build.")
  if (any(ex_failed))
    message(sum(ex_failed), " scenario(s) built but were NOT published; the ",
            "snapshot each would have replaced is unchanged and still carries ",
            "its own run.")
  message("The dashboard will show the ones that published and mark the rest.")
  quit(status = 1L)
}
message("All ", nrow(grid), " scenario(s) built and published to ", out_dir)
