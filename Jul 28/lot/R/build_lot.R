# Runner for the LOT build. One module, run once per cohort.
#
# The rules are the same for every cohort. What changes per run is which cohort
# table is read and which prefix the outputs carry - both come from
# cohorts/<cohort>.csv. Everything else is pinned below and checked before the
# first query.

# Settings that decide what a LOT run means. A different value here is a
# different result, so they are checked rather than defaulted. Change a value
# here and in config.csv together, deliberately.
CONTRACT <- list(
  catalog                     = "hive_metastore",
  cdm_schema                  = "clnprw_optum",
  codelist_dir                = "/mnt/code/codelist",
  use_quarterly_tables        = TRUE,
  censor_at_disenrollment     = FALSE,
  induction_window_days       = 60L,
  lot_n_induction_window_days = 30L,
  map_discon_gap_days         = 90L,
  medical_day_supply          = 28L,
  sct_auto_window_days        = 13L,
  sct_auto_gap_days           = 60L,
  sct_tandem_days             = 180L,
  cart_consolidation_days     = 45L,
  dsn                         = "RWDE",
  tbl_medical                 = "medical",
  tbl_med_proc                = "med_procedure",
  tbl_med_diag                = "med_diagnosis",
  tbl_rx                      = "rx"
)

# The cohorts this build knows how to run, and what each one reads and writes.
# A cohort has to be declared here before it can be built: an unknown name is
# a typo, not a new cohort.
COHORTS <- list(
  overall = list(input_cohort_table = "OVERALL_COH_FINAL", object_prefix = "overall_")
)

# Bad values fail open: as.logical("Y") is NA, which reads as FALSE. An
# integer setting that will not parse becomes NA and silently widens a window.
BOOL_SETTINGS <- c("USE_QUARTERLY_TABLES", "CENSOR_AT_DISENROLLMENT",
                   "PERSIST_TO_SCHEMA")
INT_SETTINGS  <- c("INDUCTION_WINDOW_DAYS", "INDUCTION_WINDOW_DAYS_LOT_N",
                   "MAP_DISCON_GAP_DAYS", "MEDICAL_DAY_SUPPLY",
                   "SCT_AUTO_WINDOW_DAYS", "SCT_AUTO_GAP_DAYS",
                   "SCT_TANDEM_DAYS", "CART_CONSOLIDATION_DAYS")

check_settings <- function() {
  bad <- character(0)
  for (v in BOOL_SETTINGS) {
    x <- Sys.getenv(v, unset = "")
    if (nzchar(x) && !(toupper(x) %in% c("TRUE", "FALSE")))
      bad <- c(bad, paste0(v, "='", x, "' (want TRUE or FALSE)"))
  }
  for (v in INT_SETTINGS) {
    x <- Sys.getenv(v, unset = "")
    if (nzchar(x) && is.na(suppressWarnings(as.integer(x))))
      bad <- c(bad, paste0(v, "='", x, "' (want a whole number)"))
  }
  s <- Sys.getenv("PROJECT_WORK_SCHEMA", unset = "")
  if (grepl(".", s, fixed = TRUE))
    bad <- c(bad, paste0("PROJECT_WORK_SCHEMA='", s,
                         "' is catalog.schema; it wants a schema name"))
  e <- Sys.getenv("STUDY_END", unset = "")
  if (nzchar(e) && !grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", e))
    bad <- c(bad, paste0("STUDY_END='", e, "' (want YYYY-MM-DD)"))

  if (length(bad))
    stop("Settings that would build a different LOT:\n  ",
         paste(bad, collapse = "\n  "), call. = FALSE)
  invisible(TRUE)
}

# One schema for everything: <catalog>.<schema>. No schema is an error rather
# than a silently skipped write.
pin_output_schema <- function(cfg) {
  schema <- Sys.getenv("PROJECT_WORK_SCHEMA",
              unset = Sys.getenv("DOMINO_USER_NAME",
                unset = Sys.getenv("DOMINO_STARTING_USERNAME", unset = "")))
  if (!nzchar(schema))
    stop("No output schema. Set DOMINO_USER_NAME to your personal schema ",
         "(e.g. osk02156), or PROJECT_WORK_SCHEMA to override.", call. = FALSE)
  cfg$work_schema <- schema
  cfg
}

# The cohort decides only what is read and what the outputs are called. It
# cannot reach the rules.
pin_cohort <- function(cfg, cohort) {
  if (!nzchar(cohort))
    stop("No cohort. Run: Rscript \"Jul 28/lot/build.R\" <",
         paste(names(COHORTS), collapse = "|"), ">", call. = FALSE)
  if (!cohort %in% names(COHORTS))
    stop("Unknown cohort '", cohort, "'. This build knows: ",
         paste(names(COHORTS), collapse = ", "),
         ". Add it to COHORTS in R/build_lot.R first.", call. = FALSE)
  c_def <- COHORTS[[cohort]]
  cfg$cohort             <- cohort
  cfg$input_cohort_table <- c_def$input_cohort_table
  cfg$object_prefix      <- c_def$object_prefix
  cfg
}

check_lot_contract <- function(cfg) {
  wrong <- Filter(Negate(is.null), lapply(names(CONTRACT), function(k) {
    got <- cfg[[k]]
    if (isTRUE(all.equal(got, CONTRACT[[k]]))) NULL
    else paste0(k, " = ", format(got), " (want ", format(CONTRACT[[k]]), ")")
  }))
  if (length(wrong))
    stop("This build is defined as:\n  ", paste(unlist(wrong), collapse = "\n  "),
         call. = FALSE)
  # Without a prefix every cohort writes the same table names, so a second run
  # would overwrite the first instead of sitting beside it.
  if (!nzchar(cfg$object_prefix))
    stop("No object_prefix for cohort '", cfg$cohort,
         "'. LOT outputs would collide with another cohort's.", call. = FALSE)
  if (!nzchar(cfg$input_cohort_table))
    stop("No input_cohort_table for cohort '", cfg$cohort, "'.", call. = FALSE)
  if (!isTRUE(cfg$persist_to_schema))
    stop("PERSIST_TO_SCHEMA is FALSE, so nothing would be written. ",
         "Set it TRUE to build LOT.", call. = FALSE)
  invisible(TRUE)
}

# config.csv has to load before config_lot.R, which reads Sys.getenv() at
# source time.
load_lot_modules <- function(here) {
  source(file.path(here, "R", "load_inputs.R"))
  load_pipeline_inputs(here, "config.csv")
  for (f in c("config_lot.R", "db_utils_lot.R", "codelists_lot.R"))
    source(file.path(here, "R", f))
  steps <- sort(list.files(file.path(here, "R", "steps"), "\\.R$", full.names = TRUE))
  for (f in steps) source(f)
  invisible(TRUE)
}
