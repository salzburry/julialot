# Shared setup for the question scripts in this folder.
#
# They read the same warehouse tables the lot build writes, so they use the lot
# package's own modules rather than a second copy of them - one definition of
# wrk(), cdm_src() and the code-list loaders.
#
# The one thing that needs bridging: lot's config_lot.R defines cfg_defaults and
# leaves the build to pin a config, so sourcing it alone leaves no `cfg` and the
# first wrk() call stops with "No LOT config". This does what the build does -
# resolves the work schema, then pins it - and set_lot_config() puts `cfg` in
# the global environment, which is where these scripts read it from.

.qs_root <- normalizePath(file.path(
  dirname(sys.frame(1)$ofile %||% "."), ".."), mustWork = FALSE)

qs_setup <- function(script_dir) {
  lot_r <- normalizePath(file.path(script_dir, "..", "lot", "R"), mustWork = TRUE)
  for (f in c("load_inputs.R", "config_lot.R", "codelists_lot.R", "db_utils_lot.R"))
    source(file.path(lot_r, f))
  # config.csv sits beside the lot package, the same way the build reads it.
  if (exists("load_pipeline_inputs"))
    try(load_pipeline_inputs(dirname(lot_r), "config.csv"), silent = TRUE)

  cfg <- get("cfg_defaults", envir = globalenv())
  schema <- Sys.getenv("PROJECT_WORK_SCHEMA",
              unset = Sys.getenv("DOMINO_USER_NAME",
                unset = Sys.getenv("DOMINO_STARTING_USERNAME", unset = "")))
  if (!nzchar(schema))
    stop("No work schema. Set DOMINO_USER_NAME to the schema the LOT build ",
         "wrote into, or PROJECT_WORK_SCHEMA to override.", call. = FALSE)
  if (!grepl("^[A-Za-z_][A-Za-z0-9_]*$", schema))
    stop("Work schema '", schema, "' is not a schema name.", call. = FALSE)
  cfg$work_schema <- schema

  # These read what a run produced, so the prefix is the one that run used.
  cfg$object_prefix <- Sys.getenv("OBJECT_PREFIX", unset = cfg$object_prefix %||% "")
  set_lot_config(cfg)
  invisible(cfg)
}
