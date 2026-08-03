# Settings, read once. The environment wins over config.csv, which build.R
# loads before this file is sourced.

`%||%` <- function(a, b) if (is.null(a)) b else a

run_id <- Sys.getenv("DOMINO_RUN_ID", unset = "local")

cfg_defaults <- list(
  dsn        = Sys.getenv("DATABRICKS_DSN", unset = "RWDE"),
  pwd        = Sys.getenv("DATABRICKS_PWD", unset = ""),
  catalog    = Sys.getenv("DATABRICKS_CATALOG", unset = "hive_metastore"),

  # What the run was pointed at. Supplied per run, never defaulted to a real
  # name: this folder holds no cohort of its own, the same way lot does not.
  input_cohort_table = Sys.getenv("INPUT_COHORT_TABLE", unset = ""),
  lot_prefix         = Sys.getenv("LOT_PREFIX", unset = ""),
  # The cohort build's prefix, for its attrition table. Usually the same as
  # lot_prefix - one study, one prefix - so it defaults to it rather than being
  # a second thing to remember.
  cohort_prefix      = Sys.getenv("COHORT_PREFIX", unset = ""),

  # The highest line the LOT build was told to build. It decides how many
  # transition Sankeys there are - LOT1 to LOT2, LOT2 to LOT3, and so on - so
  # a dashboard pinned to five would miss LOT5 to LOT6 on a run that built six,
  # and draw two empty panels on a run that built three. Same name and default
  # as lot's own setting, and checked against the lines the run actually built
  # rather than trusted (see check_max_lot).
  max_lot            = as.integer(Sys.getenv("MAX_LOT", unset = "5")),

  # What the cohort build calls its attrition table, before the prefix. nndm
  # writes NDMM_ATTRITION; a different cohort build writes a different name, or
  # none - in which case the panel is skipped and says so. The columns it must
  # carry are RUN_ID, STEP_NUM, CRITERION, N_PATIENTS and RECORDED_AT.
  attrition_table = Sys.getenv("ATTRITION_TABLE", unset = "NDMM_ATTRITION"),

  # Only for a funnel in the "overall" layout, which carries all three
  # outpatient-window counts side by side and no record of which one the build
  # was configured with. Only that column describes the cohort that was
  # actually written; the other two are sensitivity, with no table behind them.
  # Ignored by layouts that have one count column. 90 is overall's own default.
  attrition_window = as.integer(Sys.getenv("ATTRITION_WINDOW", unset = "90")),

  # Where the HTML goes, and what it is called.
  output_dir  = Sys.getenv("OUTPUT_DIR",  unset = "/mnt/artifacts/dashboard"),
  output_file = Sys.getenv("OUTPUT_FILE", unset = "dashboard.html"),

  # How many rows a "top N" section shows. A dashboard that lists 400 regimens
  # is a table, not a dashboard.
  top_n = as.integer(Sys.getenv("TOP_N", unset = "10")),

  # How many patients each journey scenario shows. Examples, so a handful: a
  # gallery of thirty is a table nobody reads line by line.
  journeys_per_category = as.integer(Sys.getenv("JOURNEYS_PER_CATEGORY", unset = "3")),

  # Every panel that produced rows, written beside the HTML as CSV. On by
  # default - the numbers are wanted in a spreadsheet often enough that having
  # to remember a switch is the wrong way round.
  export_csv = as.logical(Sys.getenv("EXPORT_CSV", unset = "TRUE")),
  csv_dir    = Sys.getenv("CSV_DIR", unset = "csv"),

  # Retry, same shape as the other packages.
  max_retries = as.integer(Sys.getenv("MAX_RETRIES", unset = "4")),
  base_sleep  = as.numeric(Sys.getenv("BASE_SLEEP",  unset = "2"))
)

.dash_cfg <- new.env(parent = emptyenv())
set_dash_config <- function(cfg) assign("cfg", cfg, envir = .dash_cfg)
dash_config     <- function() get("cfg", envir = .dash_cfg)

SEP <- strrep("=", 70)

log_msg <- function(...) {
  cat(format(Sys.time(), "%Y-%m-%d %H:%M:%S"), " ", ..., "\n", sep = "")
  flush(stdout())
}

stop_if_blank <- function(x, msg) if (!nzchar(x)) stop(msg, call. = FALSE)
