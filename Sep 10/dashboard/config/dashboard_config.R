# Every knob this dashboard has, in one place, and every one env-overridable.
#
# Nothing here is a clinical rule. The rules live in study223926/R/registry.R
# and study223926/R/config_223926.R, and the dashboard reads them from there so
# a module or an open question added to the package appears here without an
# edit.

.env_chr <- function(k, d) { v <- Sys.getenv(k, unset = ""); if (nzchar(v)) v else d }
.env_int <- function(k, d) {
  v <- suppressWarnings(as.integer(.env_chr(k, NA_character_)))
  if (is.na(v)) d else v
}
.env_lgl <- function(k, d) {
  v <- toupper(.env_chr(k, NA_character_))
  if (is.na(v)) d else v %in% c("TRUE", "T", "1", "YES")
}
.env_vec <- function(k, d) {
  v <- .env_chr(k, "")
  if (!nzchar(v)) d else trimws(strsplit(v, "[,|]")[[1]])
}

dashboard_config <- function() {
  list(
    # --- where the numbers come from ---------------------------------------
    # snapshot   CSVs a Domino Job exported (jobs/build_scenarios.R)
    # warehouse  read the S_* tables live over sparklyr/DBI
    # synthetic  generated in-process; no warehouse, no files
    source          = .env_chr("DASH_SOURCE", "synthetic"),
    snapshot_dir    = .env_chr("DASH_SNAPSHOT_DIR", "/mnt/artifacts/results"),
    catalog         = .env_chr("DASH_CATALOG", "hive_metastore"),
    work_schema     = .env_chr("DASH_WORK_SCHEMA", ""),
    # Scenario prefixes to offer. Empty means discover them.
    prefixes        = .env_vec("DASH_PREFIXES", character(0)),
    prefix_pattern  = .env_chr("DASH_PREFIX_PATTERN", "^s223926"),
    # Where the LOT build wrote. S_RUN_METADATA records which LOT RUN a
    # scenario read, not where that run wrote, so warehouse mode needs telling.
    # The snapshot does not: the export job files LOT tables by run id.
    lot_prefix      = .env_chr("DASH_LOT_PREFIX", ""),

    # --- what is shown ------------------------------------------------------
    # The floor the dashboard applies on top of what it reads. The package
    # already suppresses into S_*_RELEASE; this is a second, tighter floor a
    # viewer can raise but NEVER lower below the package's own.
    suppress_min_n  = .env_int("DASH_SUPPRESS_MIN_N", 25L),
    prefer_release  = .env_lgl("DASH_PREFER_RELEASE", TRUE),
    default_cohort  = .env_chr("DASH_DEFAULT_COHORT", "1L"),
    max_rows        = .env_int("DASH_MAX_ROWS", 5000L),

    # --- how a viewer asks for a scenario that does not exist ---------------
    # The dashboard never writes to the warehouse. It prints the command.
    run_cmd         = .env_chr("DASH_RUN_CMD", "Rscript build.R"),
    package_dir     = .env_chr("DASH_PACKAGE_DIR",
                              "../ndmm_study_updated/study223926"),

    # --- provenance ---------------------------------------------------------
    allow_synthetic = .env_lgl("DASH_ALLOW_SYNTHETIC", TRUE),
    title           = .env_chr("DASH_TITLE", "GSK 223926 - NDMM / RRMM explorer")
  )
}
