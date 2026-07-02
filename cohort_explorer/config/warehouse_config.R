# =============================================================================
# warehouse_config.R  --  the ONE place the analytic-cohort warehouse
# connection is defined.
# -----------------------------------------------------------------------------
# Both consumers read from here, so pointing the tool at a different datasource
# is a SINGLE-FILE edit (or, better, just env vars -- nothing in code changes):
#   * warehouse/08_analytic_cohort.R      (the materialisation job)
#   * build_flagged_cohort.R::.warehouse_read (the programmatic read path)
#
# Every value is env-overridable; the defaults are neutral placeholders. A real
# deployment sets the env vars (e.g. as Domino secrets / project env), so the
# defaults never fire and no datasource name is baked into the code.
#
#   WAREHOUSE_DSN        odbc DSN                       (default: RWDE)
#   WAREHOUSE_PWD        connection secret              (default: "" -> must set)
#   WAREHOUSE_CATALOG    three-part-name catalog        (default: main)
#   PROJECT_WORK_SCHEMA  work schema holding the tables (default: DOMINO_USER_NAME
#                        else mm_lot_work)
# =============================================================================

warehouse_config <- function() {
  list(
    dsn     = Sys.getenv("WAREHOUSE_DSN", "RWDE"),
    pwd     = Sys.getenv("WAREHOUSE_PWD", ""),
    catalog = Sys.getenv("WAREHOUSE_CATALOG", "main"),
    schema  = Sys.getenv("PROJECT_WORK_SCHEMA",
                         Sys.getenv("DOMINO_USER_NAME", "mm_lot_work"))
  )
}
