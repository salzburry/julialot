# The harness that runs the modules without a warehouse.
#
# Every other test in tests/run_tests.R reads the package's source text. Source
# text does not tell you whether a module's SQL parses, or whether its R even
# reaches the end of the function - and a suite that cannot tell you that will
# pass over a statement chopped in half by a stray semicolon, a CTE list with a
# comma missing, and a `[[` on a name the vector does not carry. All three of
# those shipped.
#
# So: load the package into a private environment, replace the handful of
# functions that touch Spark with recorders, and run every module for every
# cohort. What comes back is every statement the run would have issued, tagged,
# plus whatever R errors the modules raised on the way.

# A stub result wide enough for every column a module reads off db_q(). The
# counts are constant so the acute washout loop converges on its first round.
.stub_result <- function() {
  data.frame(n = 1L, k = 1L, r = 0L, e = 0L, unmatched = 0L, n_rows = 1L,
             parts = 1L, whole = 1L, LOT_NUM = 1L, s = "wk",
             stringsAsFactors = FALSE)
}

# Loads the package into a fresh environment. Functions sourced into `env` look
# their callees up in `env`, so assigning a stub there overrides the real one
# for every module without touching the global environment.
load_package_env <- function(here) {
  env <- new.env(parent = globalenv())
  files <- c("config_223926.R", "db_utils_223926.R", "registry.R", "windows.R",
             "person_time.R", "suppression.R", "codelists.R", "lineage.R",
             "run_223926.R")
  for (f in files) sys.source(file.path(here, "R", f), envir = env)
  for (f in env$MODULE_FILES)
    sys.source(file.path(here, "R", "modules", f), envir = env)
  env
}

# Runs every module for every cohort against the recorders.
#
# `cfg_edit` is applied to the configuration before the run, so a caller can
# exercise a setting other than the shipped default - the follow-up readings
# and the treatment-pattern switches each emit different SQL.
capture_emitted_sql <- function(here = ".", cfg_edit = identity) {
  env <- load_package_env(here)

  cfg <- env$cfg_defaults()
  cfg$work_schema  <- "wk"
  cfg$dry_run      <- FALSE
  cfg$codelist_dir <- normalizePath(file.path(here, "tests", "fixtures",
                                              "codelists"), mustWork = TRUE)
  cfg$cohorts <- names(env$COHORTS)
  cfg$modules <- names(env$MODULES)
  cfg <- cfg_edit(cfg)
  env$set_study_config(cfg)

  rec <- new.env(parent = emptyenv())
  rec$out <- vector("list", 0)
  add <- function(tag, sql) {
    for (s in env$split_statements(sql))
      rec$out[[length(rec$out) + 1L]] <- list(tag = tag, sql = s)
  }

  env$db_exec <- function(con, sql) { add("exec", sql); invisible(0L) }
  env$db_q    <- function(con, sql) { add("query", sql); .stub_result() }
  env$run_step <- function(con, name, sql, qc = NULL, allow_empty = FALSE) {
    add(paste0("step:", name), sql)
    if (!is.null(qc)) add(paste0("qc:", name), qc)
    invisible(NULL)
  }
  # prepare_table's own SQL is db_utils' business and is covered by its unit
  # tests; what matters here is the DDL shape each module declares.
  env$prepare_table <- function(con, name, schema_sql, cohort_key) {
    add("ddl", sprintf("CREATE TABLE IF NOT EXISTS %s (%s)", name, schema_sql))
    add("ddl", sprintf("DELETE FROM %s WHERE COHORT = '%s'", name, cohort_key))
    invisible(name)
  }
  env$ensure_table <- function(con, name, schema_sql) {
    add("ddl", sprintf("CREATE TABLE IF NOT EXISTS %s (%s)", name, schema_sql))
    invisible(name)
  }
  env$clear_scope <- function(con, name, cohort_key) {
    add("ddl", sprintf("DELETE FROM %s WHERE COHORT = '%s'", name, cohort_key))
    invisible(name)
  }
  # copy_to needs a session; the view name is all the modules use.
  env$register_codelist_view <- function(con, df, view_name, cols,
                                         code_col = "code",
                                         family_col = "icd_family") {
    # The real one stages the frame with copy_to, which needs a session. The
    # column check does not, and a module asking for a column its code list
    # lacks is exactly the kind of thing this harness is for.
    missing <- setdiff(cols, names(df))
    if (length(missing))
      stop("CODELIST ERROR: view ", view_name, " asked for column(s) the file ",
           "does not have: ", paste(missing, collapse = ", "), ".", call. = FALSE)
    view_name
  }
  env$log_msg <- function(...) invisible(NULL)

  cohorts <- env$resolve_cohorts(cfg)
  mods    <- env$resolve_modules(cfg)

  errors <- character(0)
  note <- function(what, e)
    errors[[what]] <<- conditionMessage(e)

  # The inputs the runner builds once, before the module loop.
  for (b in c("build_enroll_spans", "build_fu_claims", "build_mm_dx_view"))
    tryCatch(env[[b]](NULL, cfg), error = function(e) note(b, e))

  for (m in mods) {
    fn <- env[[m$fn]]
    if (isTRUE(m$per_cohort)) {
      for (co in cohorts)
        tryCatch(fn(NULL, cfg, co),
                 error = function(e) note(paste0(m$key, "/", co$key), e))
    } else {
      tryCatch(fn(NULL, cfg, cohorts), error = function(e) note(m$key, e))
    }
  }

  list(sql = rec$out, errors = errors,
       cohorts = names(cohorts), modules = names(mods))
}
