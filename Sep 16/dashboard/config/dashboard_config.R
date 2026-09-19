# Every knob this dashboard has, in one place, and every one env-overridable.
#
# Nothing here is a clinical rule. The rules live in variables/R/registry.R
# and variables/R/config_223926.R, and the dashboard reads them from there so
# a module or an open question added to the package appears here without an
# edit.

# Trimmed, as the other four stages trim theirs. A Domino environment
# variable set through a form keeps the spaces around it, and untrimmed they
# became part of a schema name, a prefix, a directory - a value that looks
# right in the message and matches nothing.
.env_chr <- function(k, d) { v <- trimws(Sys.getenv(k, unset = "")); if (nzchar(v)) v else d }
# The first of several names that is set, for a fact more than one package
# reads under a name of its own.
.env_first <- function(..., default) {
  for (k in c(...)) { v <- trimws(Sys.getenv(k, unset = "")); if (nzchar(v)) return(v) }
  default
}
# A schema written as `catalog.schema`, read the way the study run reads it -
# variables/R/config_223926.R, resolve_work_schema(). That is how a schema
# reads on the warehouse, so a setting that carried that run arrives here in
# that form; taken whole it became a schema of its own, and every table was
# looked for under catalog.`catalog.schema`.
.schema_in <- function(catalog, v) {
  parts <- strsplit(v, ".", fixed = TRUE)[[1]]
  if (length(parts) != 2L) return(v)
  if (!identical(parts[1], catalog))
    stop("DASHBOARD ERROR: the work schema '", v, "' names catalog '",
         parts[1], "' but the catalog is '", catalog, "'. Give the schema ",
         "alone, or set DASH_CATALOG to match.", call. = FALSE)
  parts[2]
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
  # Both out here, because the schema is read against the catalog and a
  # list() cannot refer to an element of itself.
  .catalog <- .env_first("DASH_CATALOG", "DATABRICKS_CATALOG",
                         default = "hive_metastore")
  .work_schema <- .schema_in(.catalog,
    .env_first("DASH_WORK_SCHEMA", "WORK_SCHEMA", "PROJECT_WORK_SCHEMA",
               "DOMINO_USER_NAME", "DOMINO_STARTING_USERNAME", default = ""))
  list(
    # --- where the numbers come from ---------------------------------------
    # snapshot   CSVs a Domino Job exported (jobs/build_scenarios.R)
    # warehouse  read the S_* tables live over sparklyr/DBI
    # synthetic  generated in-process; no warehouse, no files
    source          = .env_chr("DASH_SOURCE", "synthetic"),
    snapshot_dir    = .env_chr("DASH_SNAPSHOT_DIR", "/mnt/data/NDMM"),
    # The warehouse the study run was given, by its names:
    # DATABRICKS_CATALOG, and the schema resolved the way that run resolves
    # it - variables/R/config_223926.R, resolve_work_schema(): WORK_SCHEMA,
    # else PROJECT_WORK_SCHEMA, else the Domino user's own schema. Almost
    # everything drawn here is an S_* table and that run is what wrote them,
    # so the order is its order rather than a preference: WORK_SCHEMA is its
    # own override, and where an environment sets both to different schemas
    # the study's tables are under WORK_SCHEMA. The DASH_* names still win
    # where set, so a dashboard can look elsewhere; unset, it reads where
    # that run wrote, and an environment that carried it carries this too.
    #
    # The LOT tables are the exception, and only where the two names differ:
    # the LOT build reads PROJECT_WORK_SCHEMA alone, so a split environment
    # needs DASH_WORK_SCHEMA to say which of the two this dashboard is
    # reading. Set to the same schema, which is the normal case, there is
    # nothing to choose.
    catalog         = .catalog,
    work_schema     = .work_schema,
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
    package_dir     = .env_chr("DASH_PACKAGE_DIR", "../variables"),
    # The table shells, which are a sibling folder like the package. Unset
    # means the one beside this one; a deployment without it loses that tab
    # and nothing else.
    tfls_dir        = .env_chr("DASH_TFLS_DIR", "../TFLS"),

    # --- provenance ---------------------------------------------------------
    allow_synthetic = .env_lgl("DASH_ALLOW_SYNTHETIC", TRUE),
    title           = .env_chr("DASH_TITLE", "GSK 223926 - NDMM / RRMM explorer")
  )
}
