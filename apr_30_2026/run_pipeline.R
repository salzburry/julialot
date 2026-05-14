#!/usr/bin/env Rscript
# ============================================================
# run_pipeline.R - Top-level orchestrator (Option 3)
# ============================================================
# Runs the full MM LOT pipeline end-to-end:
#
#   Stage 1: Cohort attrition       (main.R)            -> personal_schema.final_table_name
#   Stage 2: LOT1                    (lot_program.R)     -> work_schema.LOT1_BASE_END
#   Stage 3: LOT2-5                  (lot2_5_program.R)  -> work_schema.LOT_LONG
#
# Each stage runs in its own Rscript subprocess so the existing entry
# scripts work unchanged. Between stages, this orchestrator probes the
# schema each stage actually writes to (NOT a single schema) and skips
# any stage whose primary output table already exists.
#
# Post-stage verification: if a stage exits 0 but its expected output
# table is NOT in the schema afterward, the orchestrator FAILS the
# pipeline with stop() rather than warning and continuing. The whole
# point of this check is to catch "exit 0 but persistence silently
# failed" before the next stage hits TABLE_OR_VIEW_NOT_FOUND.
#
# Pre-flight consistency check: cohort attrition uses FINAL_TABLE_NAME
# (config_prompts.R) while LOT pipelines use INPUT_COHORT_TABLE
# (config_lot.R). Defaults are both "ELIG_COH_FINAL" so they normally
# match. If they diverge (override env vars), LOT1 will not find the
# cohort attrition output. The orchestrator warns loudly at startup.
#
# Env-var controls:
#   FORCE_RERUN=TRUE      Re-run every stage even if outputs already exist
#   SKIP_COHORT=TRUE      Skip Stage 1 (assumes cohort output is there)
#   SKIP_LOT1=TRUE        Skip Stage 2 (assumes LOT1_BASE_END is there)
#   SKIP_LOT2_5=TRUE      Skip Stage 3
#
# Env vars affecting paths (read directly here AND by stage configs):
#   DATABRICKS_PWD        Connection password (required)
#   PROJECT_WORK_SCHEMA   Where LOT1 / LOT2-5 persist
#   DOMINO_USER_NAME      personal_schema; where cohort attrition persists
#   FINAL_TABLE_NAME      Cohort output table (default ELIG_COH_FINAL)
#   INPUT_COHORT_TABLE    LOT pipelines' cohort input (default ELIG_COH_FINAL)
#
# Usage:
#   Rscript run_pipeline.R
#   FORCE_RERUN=TRUE Rscript run_pipeline.R
#   SKIP_COHORT=TRUE SKIP_LOT1=TRUE Rscript run_pipeline.R   # LOT2-5 only
# ============================================================

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

# ---- Minimal helpers (avoid sourcing stage modules into orchestrator) ----
log_msg <- function(...) {
  cat(sprintf("[%s] ", format(Sys.time(), "%Y-%m-%d %H:%M:%S")), ..., "\n", sep = "")
  flush.console()
}

sep_line <- function() cat(strrep("=", 70), "\n", sep = "")

env_bool <- function(name, default = "FALSE") {
  val <- Sys.getenv(name, unset = default)
  if (!nzchar(val)) return(FALSE)
  isTRUE(suppressWarnings(as.logical(val)))
}

# ---- Read env vars directly so we know exactly what each stage will do ----
# Cohort attrition (config_prompts.R) writes here:
cohort_table  <- Sys.getenv("FINAL_TABLE_NAME",   unset = "ELIG_COH_FINAL")
cohort_schema <- Sys.getenv("DOMINO_USER_NAME",   unset = "")
# Some Domino setups set personal_schema = work_schema. config_prompts.R
# falls back to PROJECT_WORK_SCHEMA when DOMINO_USER_NAME is unset.
if (!nzchar(cohort_schema)) {
  cohort_schema <- Sys.getenv("PROJECT_WORK_SCHEMA", unset = "")
}

# LOT1 (lot_program.R / config_lot.R) reads cohort from / writes to:
lot_work_schema   <- Sys.getenv("PROJECT_WORK_SCHEMA", unset = "")
lot_input_table   <- Sys.getenv("INPUT_COHORT_TABLE",  unset = "ELIG_COH_FINAL")
db_pwd            <- Sys.getenv("DATABRICKS_PWD",      unset = "")

# Optional: catalog (Unity Catalog). config_lot.R sets cfg$catalog from
# the same env var.
catalog <- Sys.getenv("DATABRICKS_CATALOG", unset = "")

if (!nzchar(db_pwd)) {
  stop("DATABRICKS_PWD environment variable is not set.")
}
if (!nzchar(lot_work_schema)) {
  stop("PROJECT_WORK_SCHEMA is empty - cannot probe LOT outputs.")
}
if (!nzchar(cohort_schema)) {
  stop("Cannot resolve cohort attrition output schema. Set DOMINO_USER_NAME or PROJECT_WORK_SCHEMA.")
}

# ---- Pre-flight consistency check ----
# If cohort attrition writes a table that LOT1 won't look for, fail loudly
# at startup rather than mid-run. The two configs use different env vars
# for the same logical thing; this is a known foot-gun.
config_mismatch <- !identical(tolower(cohort_table), tolower(lot_input_table))
schema_mismatch <- !identical(tolower(cohort_schema), tolower(lot_work_schema))

# ---- Connection (single probe, used only for SHOW TABLES) ----
library(DBI)
library(odbc)

dsn <- Sys.getenv("DSN", unset = "RWDE")
probe_con <- DBI::dbConnect(odbc::odbc(), dsn = dsn, pwd = db_pwd, timeout = 30)
on.exit(try(DBI::dbDisconnect(probe_con), silent = TRUE), add = TRUE)

table_exists <- function(con, schema, table) {
  full_qual <- if (nzchar(catalog)) sprintf("%s.%s", catalog, schema) else schema
  q <- sprintf("SHOW TABLES IN %s LIKE '%s'", full_qual, tolower(table))
  tryCatch(
    nrow(DBI::dbGetQuery(con, q)) > 0,
    error = function(e) FALSE
  )
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
    output_schema = cohort_schema,
    output_table  = cohort_table,
    skip_env      = "SKIP_COHORT"
  ),
  list(
    name          = "LOT1",
    script        = "lot_program.R",
    output_schema = lot_work_schema,
    output_table  = "LOT1_BASE_END",
    skip_env      = "SKIP_LOT1"
  ),
  list(
    name          = "LOT2-5",
    script        = "lot2_5_program.R",
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
  log_msg("CONFIG MISMATCH (table): cohort attrition writes '", cohort_table,
          "' but LOT pipelines read INPUT_COHORT_TABLE='", lot_input_table, "'.")
  log_msg("LOT1 will not find the cohort output. Set FINAL_TABLE_NAME and",
          " INPUT_COHORT_TABLE to the same value, OR pre-create an alias.")
  stop("Pipeline halted: cohort table name vs LOT input table name diverge.")
}
if (schema_mismatch) {
  log_msg("CONFIG WARNING (schema): cohort attrition persists to '",
          cohort_schema, "' but LOT pipelines read from '", lot_work_schema, "'.")
  log_msg("Unless an alias/view bridges the two schemas, LOT1 will not find",
          " the cohort table. Set DOMINO_USER_NAME == PROJECT_WORK_SCHEMA",
          " (or pre-create a view) before re-running.")
  # Not a hard stop because some setups DO bridge via grants/views.
  # If post-stage verification fails, that error will halt the pipeline.
}

# ---- Stage execution loop ----
results <- list()

for (stage in stages) {
  user_skip <- env_bool(stage$skip_env)

  already_done <- table_exists(probe_con, stage$output_schema, stage$output_table)

  should_skip <- isTRUE(user_skip) || (already_done && !isTRUE(force_rerun))

  if (should_skip) {
    reason <- if (isTRUE(user_skip)) sprintf("%s=TRUE", stage$skip_env)
              else                    sprintf("%s.%s already exists",
                                              stage$output_schema, stage$output_table)
    log_msg(sprintf("[%-20s] SKIP (%s)", stage$name, reason))
    results[[stage$name]] <- list(status = "SKIPPED", elapsed_s = 0)
    next
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
  produced <- table_exists(probe_con, stage$output_schema, stage$output_table)
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
