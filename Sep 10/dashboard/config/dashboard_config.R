# Every knob this dashboard has, in one place, and every one env-overridable.
#
# Nothing here is a clinical rule. The rules live in study223926/R/registry.R
# and study223926/R/config_223926.R, and the dashboard reads them from there so
# a module or an open question added to the package appears here without an
# edit.

.env_chr <- function(k, d) { v <- Sys.getenv(k, unset = ""); if (nzchar(v)) v else d }
# The first of several names that is set, for a fact more than one package
# reads under a name of its own.
.env_first <- function(..., default) {
  for (k in c(...)) { v <- Sys.getenv(k, unset = ""); if (nzchar(v)) return(v) }
  default
}
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
    snapshot_dir    = .env_chr("DASH_SNAPSHOT_DIR", "/mnt/data/NDMM"),
    # The warehouse the LOT build and the study run were given, by their
    # names: DATABRICKS_CATALOG, and PROJECT_WORK_SCHEMA or the Domino user's
    # own schema where that is unset - the rule the LOT engine resolves its
    # output schema by. The DASH_* names still win where set, so a dashboard
    # can look elsewhere; unset, it reads where those two wrote, and an
    # environment that carried them carries this too.
    catalog         = .env_first("DASH_CATALOG", "DATABRICKS_CATALOG",
                                 default = "hive_metastore"),
    work_schema     = .env_first("DASH_WORK_SCHEMA", "PROJECT_WORK_SCHEMA",
                                 "WORK_SCHEMA", "DOMINO_USER_NAME",
                                 "DOMINO_STARTING_USERNAME", default = ""),
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

    # --- the command a scenario needs, for whoever owns the schema ----------
    # The dashboard never writes to the warehouse. scenario_command() builds
    # the shell lines a run needs from this; it is a tested helper, not a
    # control on the page, and a scenario nobody has run does not appear.
    run_cmd         = .env_chr("DASH_RUN_CMD", "Rscript build.R"),
    package_dir     = .env_chr("DASH_PACKAGE_DIR",
                              "../variables/study223926"),
    # The table shells, which are a sibling folder like the package. Unset
    # means the one beside this one; a deployment without it loses that tab
    # and nothing else.
    tfls_dir        = .env_chr("DASH_TFLS_DIR", "../TFLS"),

    # --- provenance ---------------------------------------------------------
    allow_synthetic = .env_lgl("DASH_ALLOW_SYNTHETIC", TRUE),
    title           = .env_chr("DASH_TITLE", "GSK 223926 - NDMM / RRMM explorer")
  )
}
