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

# A stub result wide enough for every column a module reads off db_q().
#
# `n` walks 1, 2, 3, 4, 5, 5, 5... rather than staying constant. The acute
# washout is a convergence loop - it re-runs a round until the counted-event
# count stops changing - so a constant makes it converge after ONE round, and
# only one round of its SQL is ever emitted. The executing harness then counts
# one event where the protocol's chain counts several, and the whole washout
# is untested past its first step. Five rounds is more than the fixtures need
# and the round is idempotent, so extra rounds cost nothing.
#
# `parts` and `whole` stay equal: mod_patterns STOPS when they differ, and that
# is a real guard about real data, not something to trip with a stub.
.stub_counter <- new.env(parent = emptyenv())
.stub_counter$seen <- list()
.stub_result <- function(sql = "") {
  # Counted per call SITE, not globally: the washout asks the same question
  # each round, and a global counter is exhausted by the modules that ran
  # before it. Reset per cohort by the prepare_table stub.
  k <- sql
  v <- if (is.null(.stub_counter$seen[[k]])) 1L else .stub_counter$seen[[k]] + 1L
  .stub_counter$seen[[k]] <- v
  data.frame(n = min(v, 5L), k = 1L, r = 0L, e = 0L,
             unmatched = 0L, n_rows = 1L, parts = 1L, whole = 1L,
             LOT_NUM = 1L, s = "wk", stringsAsFactors = FALSE)
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
  # SEC2L refuses to build from a primary-cohort input unless told the input is
  # the wide one. Asserted here so the harness exercises all four cohorts; the
  # refusal itself is checked in run_tests.R.
  cfg$sec2l_input_is_wide <- TRUE
  cfg$modules <- names(env$MODULES)
  cfg <- cfg_edit(cfg)
  env$set_study_config(cfg)

  .stub_counter$seen <- list()
  rec <- new.env(parent = emptyenv())
  rec$out <- vector("list", 0)
  add <- function(tag, sql) {
    for (s in env$split_statements(sql))
      rec$out[[length(rec$out) + 1L]] <- list(tag = tag, sql = s)
  }

  env$db_exec <- function(con, sql) { add("exec", sql); invisible(0L) }
  env$db_q    <- function(con, sql) { add("query", sql); .stub_result(sql) }
  env$run_step <- function(con, name, sql, qc = NULL, allow_empty = FALSE) {
    add(paste0("step:", name), sql)
    if (!is.null(qc)) add(paste0("qc:", name), qc)
    invisible(NULL)
  }
  # prepare_table, ensure_table and clear_scope are NOT stubbed. They reach the
  # warehouse only through db_exec, which is, so the real ones run and emit
  # their real SQL. Stubbing them meant the harness fabricated the DDL for
  # every table a module DECLARED - so "every declared output is written"
  # passed on the stub's own output, and a prepare_table that stopped clearing
  # its scope (a second run doubling every count in the study) was invisible.
  # Only copy_to needs a session. The column check and the normalisation SQL
  # do not, so both run for real: the check is exactly the kind of thing this
  # harness is for, and the SQL is what every code-driven join depends on.
  # The staged frame is recorded so an executing harness can materialise it.
  rec$staged <- list()
  env$register_codelist_view <- function(con, df, view_name, cols,
                                         code_col = "code",
                                         family_col = "icd_family") {
    missing <- setdiff(cols, names(df))
    if (length(missing))
      stop("CODELIST ERROR: view ", view_name, " asked for column(s) the file ",
           "does not have: ", paste(missing, collapse = ", "), ".", call. = FALSE)
    keep <- df[, cols, drop = FALSE]
    keep[] <- lapply(keep, function(x) ifelse(is.na(x), "", as.character(x)))
    stage <- paste0(tolower(view_name), "_raw")
    rec$staged[[stage]] <- keep
    add("codelist", env$codelist_view_sql(stage, view_name, cols, code_col,
                                          family_col))
    view_name
  }
  env$log_msg <- function(...) invisible(NULL)

  cohorts <- env$resolve_cohorts(cfg)
  mods    <- env$resolve_modules(cfg)

  errors <- character(0)
  note <- function(what, e)
    errors[[what]] <<- conditionMessage(e)

  # The runner's OWN pre-module path, called rather than re-implemented. This
  # harness used to list the builders by hand and call build_fu_claims()
  # directly - which is the one branch of that if/else that works - so the
  # branch the shipped default takes was never emitted, and the statement it
  # emitted could not run on Spark at all. A harness that paraphrases the code
  # it is testing tests the paraphrase.
  tryCatch(env$build_inputs(NULL, cfg, mods),
           error = function(e) note("build_inputs", e))

  for (m in mods) {
    fn <- env[[m$fn]]
    if (isTRUE(m$per_cohort)) {
      for (co in cohorts) {
        # Per cohort, so the washout's convergence counter starts fresh.
        .stub_counter$seen <- list()
        tryCatch(fn(NULL, cfg, co),
                 error = function(e) note(paste0(m$key, "/", co$key), e))
      }
    } else {
      tryCatch(fn(NULL, cfg, cohorts), error = function(e) note(m$key, e))
    }
  }

  list(sql = rec$out, errors = errors, staged = rec$staged,
       cohorts = names(cohorts), modules = names(mods))
}
