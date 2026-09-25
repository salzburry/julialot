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
# gsub("~+~"), as every other entry point here does: Rscript writes a space
# in the script's path as "~+~" on some platforms, and undecoded this job
# could not find its own folder whenever the delivery was unpacked under a
# name with a space in it.
here <- normalizePath(file.path(dirname(gsub("~+~", " ",
  sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1]),
  fixed = TRUE)), ".."), mustWork = FALSE)
if (!nzchar(here) || is.na(here)) here <- getwd()

grid_csv <- if (length(args) >= 1) args[1] else file.path(here, "scenarios.csv")
out_dir  <- if (length(args) >= 2) args[2] else
  Sys.getenv("DASH_SNAPSHOT_DIR", "/mnt/data/NDMM")
pkg_dir  <- Sys.getenv("DASH_PACKAGE_DIR",
                       file.path(dirname(here), "variables"))

if (!file.exists(grid_csv)) stop("No scenario grid at ", grid_csv, call. = FALSE)
grid <- utils::read.csv(grid_csv, stringsAsFactors = FALSE)
if (!"prefix" %in% names(grid)) stop("scenarios.csv needs a `prefix` column.",
                                     call. = FALSE)
# Trimmed HERE, before anything reads it. run_one() trimmed its own copy and
# this test did not, so "s1_" and "s1_ " were two scenarios to the duplicate
# check and one prefix to every run and every path built from it: the second
# scenario's build log overwrote the first's, and its export overwrote the
# first's snapshot under a directory neither row names.
grid$prefix <- trimws(as.character(grid$prefix))
if (any(!nzchar(grid$prefix)))
  stop("A scenario has an empty prefix (row ",
       paste(which(!nzchar(grid$prefix)), collapse = ", "),
       "). Every table this job writes carries it, so it cannot be blank.",
       call. = FALSE)
# Compared without case, because the warehouse does not distinguish one: two
# rows writing S223926_A_ and s223926_a_ are two directories under the
# snapshot and ONE set of tables on the warehouse, so the second run
# overwrites the first's tables and the snapshot files each under its own
# name - a grid that looks like two scenarios and holds one.
if (anyDuplicated(toupper(grid$prefix)))
  stop("Two scenarios share a prefix: ",
       paste(unique(grid$prefix[duplicated(toupper(grid$prefix))]),
             collapse = ", "),
       ". Each writes under its own, so one would overwrite the other - and ",
       "the warehouse does not tell two spellings of one name apart.",
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

# A prefix names a directory under the snapshot as well as a set of tables, so
# it is held to what a directory name may be - the same test the app's reader
# applies before it opens one. Without it a prefix carrying a separator or a
# ".." wrote outside the snapshot directory the job was given.
#
# AFTER the package is sourced, not with the checks above it: safe_segment()
# is the reader's own and uses `%||%`, which base R supplies only from 4.4.
# The package defines it for older ones, and this job runs on whatever R the
# platform has - so read before that source, the gate did not merely fail to
# fire, it stopped the job from starting at all. Nothing between here and
# the checks above writes anything, so the gate is still ahead of every
# write.
local({
  bad <- grid$prefix[!vapply(grid$prefix, safe_segment, logical(1))]
  if (length(bad))
    stop("A scenario prefix is not a name this job can write under: ",
         paste(bad, collapse = ", "),
         ". It becomes a directory beside the others, so it may hold ",
         "letters, digits, '.', '_' and '-' only, and must begin with a ",
         "letter or a digit.", call. = FALSE)
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
  # The child's whole output, kept beside the snapshot: eight lines in the
  # summary say what failed, the file says why.
  log_file <- file.path(out_dir, paste0(prefix, "build.log"))
  writeLines(as.character(res), log_file)
  if (!ok) message("  FAILED: ", paste(utils::tail(res, 8), collapse = "\n  "),
                   "\n  full output: ", log_file)
  list(prefix = prefix, ok = ok, log = res)
}

export_one <- function(prefix, env) {
  # Read back what the run wrote and put it beside the others as CSV, which is
  # what a Domino App can read without a warehouse session per viewer.
  #
  # Written to a staging directory and swapped in at the end: a refresh that
  # fails halfway would otherwise leave the new tables it managed beside the
  # old ones it did not, under one run's metadata, and the app would present
  # that mixture as one run.
  d     <- file.path(out_dir, prefix)
  stage <- file.path(out_dir, paste0(".", prefix, ".staging"))
  # Before the stage is cleared: that is the first thing a second Job into
  # the same Dataset would take from a running one.
  unlock <- snapshot_lock(out_dir)
  on.exit(unlock(), add = TRUE)
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
  # No schema from the environment - WORK_SCHEMA, PROJECT_WORK_SCHEMA, the
  # Domino user - means "wherever the session lands", and the build resolves
  # it that way too (run_223926.R). Left blank, wrk() built a name with an
  # empty schema in it.
  if (!nzchar(cfg$work_schema)) cfg$work_schema <- current_work_schema(con)
  set_study_config(cfg)
  # The build being exported, pinned before any table is read: the newest
  # metadata row, and it has to be complete. Every table is read against that
  # pin and the row is read again after the last one, so a rebuild landing
  # mid-export stops the export rather than publishing one build's metadata
  # beside another's rows.
  meta_src <- list(read = function(prefix, table)
    tryCatch(db_q(con, sprintf("SELECT * FROM %s", wrk(table))),
             error = function(e) NULL))
  pin <- newest_metadata_row(meta_src, prefix)
  if (is.null(pin))
    stop("the run wrote no S_RUN_METADATA, so this snapshot cannot be ",
         "attributed to a run", call. = FALSE)
  # The run as the app will read it: its identity, and what it WROTE - the
  # modules it ran and the cohorts it built. A run writes only those and
  # leaves the rest of the prefix as the previous run left it, so a table its
  # metadata does not claim, and rows of cohorts it did not select, are not
  # this run's and do not enter its snapshot - whatever sits under the prefix.
  # The same rules the app reads by (scenario_wrote, restrict_to_cohorts).
  scen <- scenario_from_row(prefix, pin)
  # Not complete, or driven by a contract this registry cannot describe - the
  # sentence is the app's, so the job and the page refuse the same run in the
  # same words.
  if (!scenario_is_usable(scen))
    stop("the newest run under ", prefix, " cannot be exported. ",
         scenario_unusable_why(scen), call. = FALSE)
  if (!length(scen$modules) || !length(scen$cohorts))
    stop("the run under ", prefix, " recorded no modules or no cohorts, so ",
         "nothing under the prefix can be attributed to it", call. = FALSE)
  # THE PUBLICATION GATE.
  #
  # This job is where a run's tables stop being the warehouse's and become a
  # Dataset other people read, so it is where the release has to be checked.
  # mod_release() withholds every cell under the floor and then records, in
  # the run's own metadata, the groups where one withheld cell is still the
  # group's total less the published rest. Whether to regroup or withhold a
  # second stratum is the analyst's call and the package does not make it -
  # but exporting a run whose own record says a withheld cell is recoverable
  # would make that call by default, and in the one direction that cannot be
  # taken back.
  #
  # "release module did not run" is refused for the same reason and is not the
  # same answer: that run has not been shown to have no recoverable cell, it
  # has not looked.
  #
  # Note what the snapshot carries. Every table the run wrote goes into it,
  # the raw ones beside the released ones, because a table with no released
  # copy has only its raw form and the app needs it. The Dataset is therefore
  # as sensitive as the raw tables, and the gate below is about the released
  # ones being sound - not about the Dataset being publishable to anyone.
  blocked <- release_recoverable_blocks(row_field(pin, "RELEASE_RECOVERABLE"))
  allowed <- isTRUE(as.logical(Sys.getenv("SNAPSHOT_ALLOW_RECOVERABLE", "FALSE")))
  if (nzchar(blocked) && !allowed)
    stop("the run under ", prefix, " is not exportable: its own metadata says ",
         "'", blocked, "'. A released table with exactly one withheld row in ",
         "a group gives that row away - the group's total less the published ",
         "rest is it. Regroup, or withhold a second stratum, and re-run the ",
         "release module. To export anyway, knowing that, set ",
         "SNAPSHOT_ALLOW_RECOVERABLE=TRUE.", call. = FALSE)
  if (nzchar(blocked))
    message("  WARNING: exporting under SNAPSHOT_ALLOW_RECOVERABLE=TRUE, and ",
            "this run's metadata says: ", blocked)
  # Said out loud on every export, because it is the one thing about this
  # Dataset that a reader cannot see by looking at it: the snapshot holds the
  # RAW tables beside the released ones, and several of them are one row per
  # patient. The App drops identifiers and prefers released copies; a person
  # with filesystem access to the Dataset is not going through the App.
  message("  the snapshot holds this run's raw tables as well as its released ",
          "copies, and the per-patient ones among them carry PATID. It is as ",
          "sensitive as the warehouse tables it came from: keep the Dataset ",
          "private to the App and Job, and do not share it as a published ",
          "extract. Cutting it down to the S_*_RELEASE tables does not make ",
          "one - six tables have a released copy and the rest of what a panel ",
          "draws has none, so that extract is incomplete AND still ",
          "unsuppressed. TFLS/run_tfls.R fills the shells from this run at a ",
          "floor that may only rise and writes tables carrying no identifier: ",
          "those are the shareable artefact. DEPLOY_DOMINO.md says the same ",
          "under Deployment controls.")
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
  # build in progress moves STATE - the reader's own currency check.
  if (!isTRUE(scenario_is_current(meta_src, scen))) {
    now <- newest_metadata_row(meta_src, prefix)
    stop("the run under ", prefix, " changed while its tables were being ",
         "read (", scen$run_id, " ", scen$state, " ", scen$updated_at, " -> ",
         row_field(now, "RUN_ID"), " ", row_field(now, "STATE"), " ",
         row_field(now, "UPDATED_AT"), "), so what was read is not one build's",
         call. = FALSE)
  }
  message("  exported ", n, " table(s) for ", prefix)

  # The lines this scenario read: the LOT run, and the BUILD of it. Filed by
  # both, and skipped when another scenario already exported that build.
  lot_id <- scen$lot_run_id
  lot_version <- scen$lot_run_version
  if (!nzchar(lot_id) || identical(lot_id, "unproven")) {
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
  cached <- dir.exists(ld) && length(list.files(ld, pattern = "[.]csv$")) > 0
  reuse <- function() {
    message("  LOT run ", lot_id, if (nzchar(lot_version))
      paste0(" build ", lot_version) else "",
      " already exported by an earlier scenario")
    publish(stage, d, n, prefix, lot_id)
  }
  # A directory named by run AND build is that build, whoever exported it,
  # and cannot be anything else. One named by run alone was written before
  # builds were recorded; the prefix may since have been rebuilt under the
  # same id, so it is reused only while the prefix still belongs to that
  # run, and the run is re-exported into a build-named directory otherwise.
  if (cached && nzchar(lot_version)) return(reuse())
  if (!owner())
    stop("the LOT prefix does not currently belong to run ", lot_id,
         if (nzchar(lot_version)) paste0(" build ", lot_version) else "",
         " (its newest status row names another run or another build of it, ",
         "or is not complete), so its tables cannot be filed under that ",
         "run's name", call. = FALSE)
  if (cached) return(reuse())
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

envs     <- lapply(seq_len(nrow(grid)), function(i) scenario_env(grid[i, ], set_cols))
# Before any build: what every scenario reads (export_lib.R).
gaps <- shared_inputs_missing(envs, grid$prefix, file.path(pkg_dir, "config.csv"))
if (length(gaps))
  stop("Nothing was built. Every scenario reads one cohort and one LOT run, ",
       "and where they are is not set: ", paste(gaps, collapse = "; "),
       ". Give this Job what step 3 was given - INPUT_COHORT_TABLE, LOT_PREFIX ",
       "and COHORT_PREFIX, such as ndmm_NDMM_COHORT, ndmm_ and ndmm_ - or a ",
       "scenarios.csv column of the same name. A prefix left blank would be ",
       "read as each scenario's own, which is where it writes, not where the ",
       "cohort and LOT builds wrote.", call. = FALSE)
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
# An export that failed is a failed job, not a zero-table count: the footer
# must not report success for a scenario that published nothing, or that left
# the previous snapshot in place under the new run's name.
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
