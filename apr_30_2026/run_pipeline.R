#!/usr/bin/env Rscript
# ============================================================
# run_pipeline.R - Top-level orchestrator (Option 3)
# ============================================================
# Runs the full MM LOT pipeline end-to-end:
#
#   Stage 1: Cohort attrition       (main.R)            -> ELIG_COH_FINAL
#   Stage 2: LOT1                    (lot_program.R)     -> LOT1_BASE_END
#   Stage 3: LOT2-5                  (lot2_5_program.R)  -> LOT_LONG
#
# Each stage runs in its own Rscript subprocess so the existing entry
# scripts work unchanged. Between stages, this orchestrator inspects the
# work schema and skips any stage whose primary output table already
# exists (idempotent re-runs are free).
#
# Env-var controls:
#   FORCE_RERUN=TRUE      Re-run every stage even if outputs already exist
#   SKIP_COHORT=TRUE      Skip Stage 1 (assumes ELIG_COH_FINAL is there)
#   SKIP_LOT1=TRUE        Skip Stage 2 (assumes LOT1_BASE_END is there)
#   SKIP_LOT2_5=TRUE      Skip Stage 3
#
# Required env vars (read by the individual stage configs):
#   DATABRICKS_PWD        Connection password
#   plus whatever cfg expects (catalog, schemas, codelist dir, etc.)
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

# ---- Pre-flight: connect just enough to probe existing tables ----
source(file.path(.script_dir, "R", "config_lot.R"))

if (!nzchar(cfg$pwd)) {
  stop("DATABRICKS_PWD environment variable is not set.")
}
if (!nzchar(cfg$work_schema)) {
  stop("cfg$work_schema is empty - cannot probe existing tables.")
}

library(DBI)
library(odbc)

probe_con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 30)
on.exit(try(DBI::dbDisconnect(probe_con), silent = TRUE), add = TRUE)

table_exists <- function(con, schema, table) {
  full_qual <- if (nzchar(cfg$catalog)) {
    sprintf("%s.%s", cfg$catalog, schema)
  } else {
    schema
  }
  q <- sprintf("SHOW TABLES IN %s LIKE '%s'", full_qual, tolower(table))
  tryCatch(
    nrow(DBI::dbGetQuery(con, q)) > 0,
    error = function(e) FALSE
  )
}

# ---- Stage definitions ----
force_rerun <- env_bool("FORCE_RERUN")

stages <- list(
  list(
    name         = "Cohort attrition",
    script       = "main.R",
    output_table = cfg$input_cohort_table,   # e.g. ELIG_COH_FINAL
    skip_env     = "SKIP_COHORT"
  ),
  list(
    name         = "LOT1",
    script       = "lot_program.R",
    output_table = "LOT1_BASE_END",
    skip_env     = "SKIP_LOT1"
  ),
  list(
    name         = "LOT2-5",
    script       = "lot2_5_program.R",
    output_table = "LOT_LONG",
    skip_env     = "SKIP_LOT2_5"
  )
)

# ---- Banner ----
sep_line()
log_msg("GSK MM LOT - Pipeline Orchestrator")
log_msg("Working dir:    ", .script_dir)
log_msg("Catalog:        ", if (nzchar(cfg$catalog)) cfg$catalog else "(none)")
log_msg("Work schema:    ", cfg$work_schema)
log_msg("CDM schema:     ", cfg$cdm_schema)
log_msg("Force rerun:    ", force_rerun)
sep_line()

# ---- Stage execution loop ----
results <- list()

for (stage in stages) {
  user_skip <- env_bool(stage$skip_env)

  already_done <- table_exists(probe_con, cfg$work_schema, stage$output_table)

  should_skip <- isTRUE(user_skip) || (already_done && !isTRUE(force_rerun))

  if (should_skip) {
    reason <- if (isTRUE(user_skip)) sprintf("%s=TRUE", stage$skip_env)
              else                    "output table already exists"
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

  # Post-stage sanity: confirm the stage actually produced its output table.
  # Useful catch if a stage exits 0 but persistence silently failed.
  produced <- table_exists(probe_con, cfg$work_schema, stage$output_table)
  if (!isTRUE(produced)) {
    log_msg(sprintf("[%-20s] WARN: exit 0 but expected output '%s' not found in %s",
                    stage$name, stage$output_table, cfg$work_schema))
    log_msg("  Downstream stages may fail with TABLE_OR_VIEW_NOT_FOUND.")
    log_msg("  Common cause: materialize_to_personal_schema warned but did not write.")
  }

  log_msg(sprintf("[%-20s] DONE (%.1f s)", stage$name, elapsed))
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
