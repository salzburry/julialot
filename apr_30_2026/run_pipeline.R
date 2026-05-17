#!/usr/bin/env Rscript
# Top-level orchestrator. Runs the full MM LOT pipeline end-to-end:
#
#   Stage 1  Cohort attrition  main.R            -> personal_schema.<final_table>
#   Stage 2  LOT1              lot_program.R     -> work_schema.LOT1_BASE_END
#   Stage 3  LOT2-5            lot2_5_program.R  -> work_schema.LOT_LONG
#
# Each stage runs in its own Rscript subprocess so the entry scripts
# work unchanged. Between stages the orchestrator probes the schema each
# stage actually writes to and skips any stage whose output table
# already exists. If a stage exits 0 but its output table is missing
# afterward, the pipeline stop()s rather than cascading into a
# downstream TABLE_OR_VIEW_NOT_FOUND.
#
# Foot-gun guarded at startup: cohort attrition writes FINAL_TABLE_NAME
# (config_prompts.R) while LOT stages read INPUT_COHORT_TABLE
# (config_lot.R). Both default to ELIG_COH_FINAL; if overridden to
# diverge, LOT1 won't find the cohort and the orchestrator warns loudly.
#
# Run-control env vars:
#   FORCE_RERUN=TRUE   re-run every stage even if outputs exist
#   SKIP_COHORT=TRUE   skip Stage 1
#   SKIP_LOT1=TRUE     skip Stage 2
#   SKIP_LOT2_5=TRUE   skip Stage 3
#
# Path env vars (read here AND by the stage configs; every default
# below MUST match the fallback in config_lot.R / config_prompts.R):
#   DATABRICKS_PWD       connection password (required)
#   DATABRICKS_DSN       ODBC DSN (default RWDE)
#   DATABRICKS_CATALOG   catalog (default hive_metastore)
#   PROJECT_WORK_SCHEMA  LOT work schema; -> DOMINO_USER_NAME -> gsk_mm_lot_work
#   DOMINO_USER_NAME     cohort personal_schema; -> DOMINO_STARTING_USERNAME
#   FINAL_TABLE_NAME     cohort output table (default ELIG_COH_FINAL)
#   INPUT_COHORT_TABLE   LOT cohort input (default ELIG_COH_FINAL)
#
# Usage:
#   Rscript run_pipeline.R
#   FORCE_RERUN=TRUE Rscript run_pipeline.R
#   SKIP_COHORT=TRUE SKIP_LOT1=TRUE Rscript run_pipeline.R   # LOT2-5 only,
#     builds LOT2-5 only if LOT_LONG does not already exist; add
#     FORCE_RERUN to rebuild (the atomic LOT_LONG_STAGE publish keeps
#     the old LOT_LONG until a full rebuild succeeds).

# ---- Resolve script directory regardless of how invoked ----
.script_dir <- local({
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", args, value = TRUE)
  if (length(file_arg) > 0) {
    return(dirname(normalizePath(sub("^--file=", "", file_arg[1]))))
  }
  for (i in seq_len(sys.nframe())) {
    ofile <- tryCatch(sys.frame(i)$ofile, error = function(e) NULL)
    if (!is.null(ofile)) return(dirname(normalizePath(ofile)))
  }
  getwd()
})

# ---- Optional CSV-driven input overrides (before any env reads) ----
# Edit apr_30_2026/pipeline_inputs.csv to change/reset inputs without
# Sys.setenv juggling. Sys.setenv here propagates to the per-stage
# Rscript subprocesses too. Not a "stage module" - just a tiny loader.
local({
  li <- file.path(.script_dir, "R", "load_inputs.R")
  if (file.exists(li)) {
    source(li)
    load_pipeline_inputs(c(.script_dir, dirname(.script_dir)))
  }
})

# ---- Minimal helpers (avoid sourcing stage modules into orchestrator) ----
# Resolve ONE run log file and export it as PIPELINE_LOG_FILE so every
# per-stage Rscript subprocess (which inherits this env) appends to the
# SAME combined log - one file to tail/track for the whole pipeline.
.resolve_log_file <- function() {
  lf <- getOption("pipeline_log_file", default = NULL)
  if (!is.null(lf)) return(lf)
  envf <- Sys.getenv("PIPELINE_LOG_FILE", unset = "")
  if (nzchar(envf)) {
    lf <- envf
  } else {
    base_dir <- Sys.getenv("OUTPUT_DIR", unset = "")
    if (!nzchar(base_dir)) base_dir <- "/mnt/artifacts/results"
    ok <- tryCatch({ dir.create(base_dir, showWarnings = FALSE, recursive = TRUE); dir.exists(base_dir) },
                   error = function(e) FALSE)
    if (!isTRUE(ok)) base_dir <- tempdir()
    lf <- file.path(base_dir, paste0("pipeline_run_",
            format(Sys.time(), "%Y%m%d_%H%M%S"), ".log"))
    Sys.setenv(PIPELINE_LOG_FILE = lf)   # share with stage subprocesses
  }
  options(pipeline_log_file = lf)
  cat(sprintf("[%s] [log] combined run log -> %s\n",
              format(Sys.time(), "%Y-%m-%d %H:%M:%S"), lf))
  lf
}

log_msg <- function(...) {
  prefix <- sprintf("[%s] ", format(Sys.time(), "%Y-%m-%d %H:%M:%S"))
  cat(prefix, ..., "\n", sep = "")
  flush.console()
  try({
    lf <- .resolve_log_file()
    cat(prefix, ..., "\n", sep = "", file = lf, append = TRUE)
  }, silent = TRUE)
}

sep_line <- function() {
  cat(strrep("=", 70), "\n", sep = "")
  try(cat(strrep("=", 70), "\n", sep = "",
          file = .resolve_log_file(), append = TRUE), silent = TRUE)
}

env_bool <- function(name, default = "FALSE") {
  val <- Sys.getenv(name, unset = default)
  if (!nzchar(val)) return(FALSE)
  isTRUE(suppressWarnings(as.logical(val)))
}

# ---- Read env vars directly so we know exactly what each stage will do ----
# IMPORTANT: every default below MUST match the corresponding fallback in
# config_lot.R (LOT stages) and config_prompts.R (cohort attrition). If
# they drift, the orchestrator's SHOW TABLES probe checks one location
# and the stages write to another, silently corrupting skip detection
# and post-stage verification.
db_pwd <- Sys.getenv("DATABRICKS_PWD", unset = "")

# Catalog: both configs default to hive_metastore (config_lot.R:21,
# config_prompts.R:35). Match that here.
catalog <- Sys.getenv("DATABRICKS_CATALOG", unset = "hive_metastore")

# Cohort attrition (config_prompts.R:138-139) personal_schema fallback:
#   DOMINO_USER_NAME -> DOMINO_STARTING_USERNAME -> ""
cohort_schema <- Sys.getenv("DOMINO_USER_NAME", unset = "")
if (!nzchar(cohort_schema)) {
  cohort_schema <- Sys.getenv("DOMINO_STARTING_USERNAME", unset = "")
}
cohort_table <- Sys.getenv("FINAL_TABLE_NAME", unset = "ELIG_COH_FINAL")

# LOT stages (config_lot.R:23-24) work_schema fallback:
#   PROJECT_WORK_SCHEMA -> DOMINO_USER_NAME -> gsk_mm_lot_work
lot_work_schema <- Sys.getenv("PROJECT_WORK_SCHEMA", unset = "")
if (!nzchar(lot_work_schema)) {
  lot_work_schema <- Sys.getenv("DOMINO_USER_NAME", unset = "gsk_mm_lot_work")
}
lot_input_table <- Sys.getenv("INPUT_COHORT_TABLE", unset = "ELIG_COH_FINAL")

if (!nzchar(db_pwd)) {
  stop("DATABRICKS_PWD environment variable is not set.")
}
if (!nzchar(lot_work_schema)) {
  stop("Cannot resolve LOT work schema. Set PROJECT_WORK_SCHEMA or DOMINO_USER_NAME.")
}
if (!nzchar(cohort_schema)) {
  stop("Cannot resolve cohort attrition output schema. Set DOMINO_USER_NAME or DOMINO_STARTING_USERNAME.")
}

# ---- Pre-flight consistency check ----
# If cohort attrition writes a table that LOT1 won't look for, fail loudly
# at startup rather than mid-run. The two configs use different env vars
# for the same logical thing; this is a known foot-gun.
config_mismatch <- !identical(tolower(cohort_table), tolower(lot_input_table))
schema_mismatch <- !identical(tolower(cohort_schema), tolower(lot_work_schema))

# ---- Connection (one fresh connection per probe call) ----
# We deliberately do NOT hold a long-lived connection here. On Domino, the
# parent R session's ODBC state can invalidate a top-level handle between
# when we open it and when we first use it (symptom: "external pointer is
# not valid"). The previous version masked this by wrapping every probe in
# tryCatch(... error = FALSE), which made the false-negative
# indistinguishable from "table missing". Opening per-call is ~1-2 s
# extra per probe (9 probes per full run), trivial vs. the cost of a wrong
# decision.
library(DBI)
library(odbc)

dsn <- Sys.getenv("DATABRICKS_DSN", unset = "RWDE")

table_exists <- function(schema, table) {
  full_qual <- if (nzchar(catalog)) sprintf("%s.%s", catalog, schema) else schema
  con <- DBI::dbConnect(odbc::odbc(), dsn = dsn, pwd = db_pwd, timeout = 30)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)
  # SHOW TABLES IN <schema> with no LIKE: returns every table in the schema.
  # We then match in R, case-insensitively, to avoid Databricks footguns:
  #   1) SHOW TABLES ... LIKE 'foo_bar': `_` can be treated as a single-char
  #      SQL-LIKE wildcard depending on runtime, so an exact-name pattern
  #      is not reliable.
  #   2) Hive metastore case-sensitivity: persisted names are usually
  #      lowercased server-side, but the caller may pass uppercase
  #      (FINAL_TABLE_NAME default is 'ELIG_COH_FINAL').
  # Connection-level errors are intentionally re-thrown so a dropped
  # connection cannot be mistaken for "table missing".
  q <- sprintf("SHOW TABLES IN %s", full_qual)
  res <- DBI::dbGetQuery(con, q)
  if (is.null(res) || !is.data.frame(res) || nrow(res) == 0) return(FALSE)
  name_col <- intersect(c("tableName", "TABLENAME", "table_name", "TABLE_NAME"),
                        names(res))
  if (length(name_col) == 0) {
    guess <- grep("table", names(res), ignore.case = TRUE, value = TRUE)
    if (length(guess) == 0) return(FALSE)
    name_col <- guess[1]
  } else {
    name_col <- name_col[1]
  }
  tolower(table) %in% tolower(as.character(res[[name_col]]))
}

# ---- Stage definitions ----
# Each stage carries the schema AND table to probe, so the orchestrator
# does not assume a single shared schema. Cohort attrition's location
# is taken from FINAL_TABLE_NAME + DOMINO_USER_NAME (the env vars
# config_prompts.R reads). LOT stages use PROJECT_WORK_SCHEMA.
force_rerun <- env_bool("FORCE_RERUN")

stages <- list(
  list(
    name          = "Cohort attrition",
    script        = "main.R",
    required_inputs = list(),                # nothing to pre-check
    output_schema = cohort_schema,
    output_table  = cohort_table,
    skip_env      = "SKIP_COHORT"
  ),
  list(
    name          = "LOT1",
    script        = "lot_program.R",
    # LOT1 reads cohort from lot_work_schema.lot_input_table. If cohort
    # attrition wrote to cohort_schema and no view bridges the two,
    # this probe is what catches it BEFORE LOT1 hits
    # TABLE_OR_VIEW_NOT_FOUND.
    required_inputs = list(
      list(schema = lot_work_schema, table = lot_input_table)
    ),
    output_schema = lot_work_schema,
    output_table  = "LOT1_BASE_END",
    skip_env      = "SKIP_LOT1"
  ),
  list(
    name          = "LOT2-5",
    script        = "lot2_5_program.R",
    # LOT2-5 needs every persisted LOT1 table that prepare_lot_inputs()
    # rebinds AS the temp views lot2_5_base.R reads, PLUS the cohort
    # table (lot2_5_inputs.R rebuilds lot_patient_input from it).
    # Concretely lot2_5_base.R reads:
    #   - map_stacked     (used at multiple FROMs)
    #   - lot1_sct        (LEFT JOIN at the LOT1 row init)
    #   - lot1_base_end   (FROM at the LOT1 row init)
    # plus lot_patient_input <- cfg$input_cohort_table.
    # Checking only LOT1_BASE_END would let SKIP_COHORT=TRUE SKIP_LOT1=TRUE
    # pass the pre-check, then fail inside prepare_lot_inputs() if any of
    # the LOT1 outputs is missing.
    required_inputs = list(
      list(schema = lot_work_schema, table = "LOT1_BASE_END"),
      list(schema = lot_work_schema, table = "MAP_STACKED"),
      list(schema = lot_work_schema, table = "LOT1_SCT"),
      list(schema = lot_work_schema, table = lot_input_table)
    ),
    output_schema = lot_work_schema,
    output_table  = "LOT_LONG",
    skip_env      = "SKIP_LOT2_5"
  )
)

# ---- Banner ----
sep_line()
log_msg("GSK MM LOT - Pipeline Orchestrator")
log_msg("Working dir:           ", .script_dir)
log_msg("Catalog:               ", if (nzchar(catalog)) catalog else "(none)")
log_msg("Cohort output:         ", cohort_schema, ".", cohort_table)
log_msg("LOT work schema:       ", lot_work_schema)
log_msg("LOT cohort input:      ", lot_work_schema, ".", lot_input_table)
log_msg("Force rerun:           ", force_rerun)
sep_line()

if (config_mismatch) {
  log_msg("CONFIG WARNING (table): cohort attrition writes '", cohort_table,
          "' but LOT pipelines read INPUT_COHORT_TABLE='", lot_input_table, "'.")
  log_msg("Unless an alias/view bridges the two names, LOT1 will not find",
          " the cohort table. Set FINAL_TABLE_NAME == INPUT_COHORT_TABLE,",
          " OR pre-create an alias before re-running.")
  # Not a hard stop: the per-stage input probe (below) is what actually
  # halts the pipeline if no alias bridges FINAL_TABLE_NAME and
  # INPUT_COHORT_TABLE. Hard-stopping here made the "pre-create an
  # alias" remediation unreachable.
}
if (schema_mismatch) {
  log_msg("CONFIG WARNING (schema): cohort attrition persists to '",
          cohort_schema, "' but LOT pipelines read from '", lot_work_schema, "'.")
  log_msg("Unless an alias/view bridges the two schemas, LOT1 will not find",
          " the cohort table. Set DOMINO_USER_NAME == PROJECT_WORK_SCHEMA",
          " (or pre-create a view) before re-running.")
  # Not a hard stop because some setups DO bridge via grants/views.
  # The pre-run input check inside the stage loop will catch a missing
  # bridge BEFORE LOT1 runs (so the user sees a clear orchestrator
  # message instead of a downstream TABLE_OR_VIEW_NOT_FOUND).
}

# ---- Stage execution loop ----
results <- list()

for (stage in stages) {
  user_skip <- env_bool(stage$skip_env)

  already_done <- table_exists(stage$output_schema, stage$output_table)

  should_skip <- isTRUE(user_skip) || (already_done && !isTRUE(force_rerun))

  if (should_skip) {
    reason <- if (isTRUE(user_skip)) sprintf("%s=TRUE", stage$skip_env)
              else                    sprintf("%s.%s already exists",
                                              stage$output_schema, stage$output_table)
    log_msg(sprintf("[%-20s] SKIP (%s)", stage$name, reason))
    results[[stage$name]] <- list(status = "SKIPPED", elapsed_s = 0)
    next
  }

  # Pre-run input check: confirm every required input table is visible
  # at the schema the stage will look in. This catches the
  # "schema_mismatch + no bridging view" case (and the analogous
  # SKIP_COHORT=TRUE SKIP_LOT1=TRUE case where the cohort table is
  # also missing) BEFORE the stage script bombs with
  # TABLE_OR_VIEW_NOT_FOUND.
  for (req in stage$required_inputs) {
    if (is.null(req$schema) || is.null(req$table) ||
        !nzchar(req$schema) || !nzchar(req$table)) next
    has_input <- table_exists(req$schema, req$table)
    if (!isTRUE(has_input)) {
      log_msg(sprintf("[%-20s] FAIL: required input '%s.%s' not visible from probe DSN",
                      stage$name, req$schema, req$table))
      log_msg("  Cohort attrition may have persisted to a different schema or table. Either:")
      log_msg("    - set DOMINO_USER_NAME == PROJECT_WORK_SCHEMA so cohort lands in the LOT schema, OR")
      log_msg("    - set FINAL_TABLE_NAME == INPUT_COHORT_TABLE, OR")
      log_msg("    - create a view/alias '", req$schema, ".", req$table,
              "' that points at the cohort table.")
      results[[stage$name]] <- list(status = "MISSING_INPUT", elapsed_s = 0)
      sep_line()
      log_msg("Pipeline halted. Subsequent stages will not run.")
      stop(sprintf("Stage '%s' cannot start: required input '%s.%s' not found.",
                   stage$name, req$schema, req$table))
    }
  }

  log_msg(sprintf("[%-20s] RUN   -> %s", stage$name, stage$script))
  started <- Sys.time()

  # Each stage runs in its own R subprocess so the existing entry scripts
  # work unchanged. Env vars (DATABRICKS_PWD etc.) are inherited.
  rc <- system2(
    "Rscript",
    args = file.path(.script_dir, stage$script),
    stdout = "", stderr = ""    # stream child output to parent stdout/stderr
  )

  elapsed <- as.numeric(difftime(Sys.time(), started, units = "secs"))

  if (rc != 0) {
    log_msg(sprintf("[%-20s] FAIL (exit code %d, %.1f s)", stage$name, rc, elapsed))
    results[[stage$name]] <- list(status = "FAILED", elapsed_s = elapsed, rc = rc)
    sep_line()
    log_msg("Pipeline halted. Subsequent stages will not run.")
    stop(sprintf("Stage '%s' failed (exit %d).", stage$name, rc))
  }

  # Post-stage verification: confirm the stage actually produced its
  # output table. FAILS FAST with stop() rather than warning and
  # continuing, so a silent persistence bug halts the pipeline at the
  # offending stage instead of cascading into TABLE_OR_VIEW_NOT_FOUND.
  produced <- table_exists(stage$output_schema, stage$output_table)
  if (!isTRUE(produced)) {
    log_msg(sprintf("[%-20s] FAIL: exit 0 but expected output '%s.%s' not found",
                    stage$name, stage$output_schema, stage$output_table))
    log_msg("  Common cause: materialize_to_personal_schema warned but did not write.")
    log_msg("  Check the stage's log for a 'WARN: Materialization failed' line.")
    results[[stage$name]] <- list(status = "MISSING_OUTPUT", elapsed_s = elapsed)
    sep_line()
    log_msg("Pipeline halted. Subsequent stages will not run.")
    stop(sprintf("Stage '%s' completed but did not persist '%s.%s'.",
                 stage$name, stage$output_schema, stage$output_table))
  }

  log_msg(sprintf("[%-20s] DONE (%.1f s) -> %s.%s",
                  stage$name, elapsed, stage$output_schema, stage$output_table))
  results[[stage$name]] <- list(status = "OK", elapsed_s = elapsed)
}

# ---- Summary ----
sep_line()
log_msg("Pipeline summary:")
for (nm in names(results)) {
  r <- results[[nm]]
  log_msg(sprintf("  %-20s  %-8s  %6.1f s",
                  nm, r$status, r$elapsed_s))
}
sep_line()
log_msg("Done.")
