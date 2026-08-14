# Settings. Everything here is about which run to read; nothing defines a
# clinical rule, because this package applies none of its own - the lines are
# lot's and the population is the cohort's.
cfg_defaults <- list(
  dsn = Sys.getenv("DATABRICKS_DSN", unset = "RWDE"),
  pwd = Sys.getenv("DATABRICKS_PWD", unset = ""),
  catalog = Sys.getenv("DATABRICKS_CATALOG", unset = "hive_metastore"),
  work_schema = "",
  input_cohort_table = trimws(Sys.getenv("INPUT_COHORT_TABLE", unset = "")),
  object_prefix      = trimws(Sys.getenv("OBJECT_PREFIX", unset = "")),
  # The cohort build's prefix, for its tables. Defaults to this run's own -
  # one study, one prefix - so it is only set when the two differ.
  cohort_prefix      = trimws(Sys.getenv("COHORT_PREFIX", unset = "")),
  # The only clinical setting here, and it is checked against the LOT run
  # rather than trusted: the attrition split turns on it.
  study_end   = Sys.getenv("STUDY_END", unset = "2026-03-31"),
  max_retries = 4,
  base_sleep  = 5
)

run_id <- Sys.getenv("DOMINO_RUN_ID",
                     unset = format(Sys.time(), "%Y%m%d%H%M%S"))
