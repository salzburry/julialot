#!/usr/bin/env Rscript
# =============================================================================
# stage_cdm.R -- copy the CDM tables this study needs into the work schema
# -----------------------------------------------------------------------------
#   DATABRICKS_PWD=... Rscript "Jul 28/stage_cdm.R"
#
# then build against the copies:
#
#   OPTUM_CDM_SCHEMA=osk02156 DATABRICKS_PWD=... Rscript "Jul 28/overall/build.R"
#
# The staged tables keep the names cdm_src() already builds -- t_medical_2025q2
# and so on -- so pointing OPTUM_CDM_SCHEMA at the work schema is the whole
# change. No step SQL moves, and the equivalence test is untouched.
#
# Run it once per data vintage. Both cohorts and LOT can read the same copies.
#
# Rows only, every column. Dropping columns saves little and a missing one
# breaks a step at runtime.
#
# THE WINDOW HAS TO COVER EVERY LOOKBACK AND LOOK-AFTER:
#   baseline lookback   index - baseline_days, and index can be as early as
#                       id_start, so the copy must start at
#                       id_start - baseline_days - gap_days.
#                       With the shipped dates that is 2015-06-02, which is
#                       BEFORE study_start (2015-07-01) - the study window on
#                       its own leaves only one day of slack.
#   30/60/90-day pair   both claims come from mm_dx_events_id, so both sit
#                       inside the ID period. Nothing spills past id_end.
#   other cancer 30d    the second claim is already truncated at study_end by
#                       the step itself, so the copy loses nothing.
#   follow-up           ends at min(death, study_end). Nothing past study_end.
#
# So: lower bound is the earliest of study_start and the baseline requirement,
# upper bound is study_end. Every claim-table read in steps/ is itself bounded
# by study_start..study_end, which is what makes the copy a superset.
#
# WHICH TABLES GET A DATE FILTER MATTERS:
#   medical / med_diagnosis / med_procedure   FST_DT in the study window
#   rx                                        FILL_DT in the study window
#     - every step that reads these bounds itself the same way, so the window
#       is a superset of what any of them ask for.
#   confinement                               NO FILTER
#     - joined on CONF_ID, not on date. A stay that began before study_start
#       can still cover an in-window claim, and dropping it would silently
#       lose inpatient_flg.
#   member_enrollment / member_cont_enrollment  NO FILTER
#     - baseline needs coverage from before study_start.
#   dod                                       NO FILTER (small)
# =============================================================================

here <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (!length(a)) getwd()
  else dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]), fixed = TRUE)))
})
library(DBI); library(odbc)

source(file.path(here, "overall", "R", "load_inputs.R"))
load_pipeline_inputs(here)

catalog    <- Sys.getenv("DATABRICKS_CATALOG", unset = "hive_metastore")
cdm_schema <- Sys.getenv("OPTUM_CDM_SCHEMA", unset = "clnprw_optum")
target     <- Sys.getenv("PROJECT_WORK_SCHEMA",
                unset = Sys.getenv("DOMINO_USER_NAME",
                  unset = Sys.getenv("DOMINO_STARTING_USERNAME", unset = "")))
study_start <- Sys.getenv("STUDY_START", unset = "2015-07-01")
study_end   <- Sys.getenv("STUDY_END",   unset = "2025-06-30")
id_start    <- Sys.getenv("ID_START",    unset = "2016-01-01")
baseline    <- as.integer(Sys.getenv("BASELINE_DAYS", unset = "183"))
gap         <- as.integer(Sys.getenv("GAP_DAYS", unset = "30"))
quarterly   <- !identical(toupper(Sys.getenv("USE_QUARTERLY_TABLES", unset = "TRUE")), "FALSE")

# Earliest date any step can ask for, and the copy has to reach it.
need_from <- as.Date(id_start) - baseline - gap
from <- format(min(as.Date(study_start), need_from))
to   <- study_end

if (!nzchar(target))
  stop("No work schema. Set DOMINO_USER_NAME or PROJECT_WORK_SCHEMA.", call. = FALSE)
if (identical(target, cdm_schema))
  stop("Target schema is the CDM schema. Refusing to write over the source.",
       call. = FALSE)

# base table -> the column to bound on, or NA to copy whole
TABLES <- list(
  medical                = "FST_DT",
  med_diagnosis          = "FST_DT",
  med_procedure          = "FST_DT",
  rx                     = "FILL_DT",
  confinement            = NA_character_,
  member_enrollment      = NA_character_,
  member_cont_enrollment = NA_character_,
  dod                    = NA_character_
)

quarter <- local({
  d <- as.Date(study_end)
  paste0(format(d, "%Y"), "q", ceiling(as.integer(format(d, "%m")) / 3))
})
staged_name <- function(base) if (quarterly) paste0("t_", base, "_", quarter) else base
qualify <- function(schema, obj) if (nzchar(catalog))
  paste0(catalog, ".", schema, ".", obj) else paste0(schema, ".", obj)

say <- function(...) cat(format(Sys.time(), "[%H:%M:%S] "), ..., "\n", sep = "")

con <- dbConnect(odbc::odbc(), dsn = Sys.getenv("DATABRICKS_DSN", unset = "RWDE"),
                 pwd = Sys.getenv("DATABRICKS_PWD", unset = ""))
on.exit(try(dbDisconnect(con), silent = TRUE), add = TRUE)

say("source  ", qualify(cdm_schema, "<table>"))
say("target  ", qualify(target, "<table>"))
say("study   ", study_start, " .. ", study_end)
say("copy    ", from, " .. ", to, "   quarter ", quarter)
say("        earliest baseline start is ", format(need_from),
    " (id_start ", id_start, " - ", baseline, " - ", gap, ")")
if (as.Date(from) < as.Date(study_start))
  say("        copy starts before study_start to cover it")
cat("\n")

for (base in names(TABLES)) {
  date_col <- TABLES[[base]]
  src <- qualify(cdm_schema, staged_name(base))
  dst <- qualify(target,     staged_name(base))
  where <- if (is.na(date_col)) "" else
    paste0(" WHERE ", date_col, " BETWEEN date('", from, "') AND date('", to, "')")

  t0 <- Sys.time()
  say(base, if (is.na(date_col)) "  (whole table)" else paste0("  ", date_col, " in window"))
  dbExecute(con, paste0("CREATE OR REPLACE TABLE ", dst, " AS SELECT * FROM ", src, where))

  # The copy has to match what the source holds under the same filter, or a
  # step reading it will quietly see fewer rows than it should.
  n_src <- dbGetQuery(con, paste0("SELECT count(*) AS n FROM ", src, where))$n
  n_dst <- dbGetQuery(con, paste0("SELECT count(*) AS n FROM ", dst))$n
  secs  <- round(as.numeric(difftime(Sys.time(), t0, units = "secs")), 1)
  if (!identical(as.numeric(n_src), as.numeric(n_dst)))
    stop(base, ": staged ", n_dst, " rows, source has ", n_src, call. = FALSE)
  say("  ", format(n_dst, big.mark = ","), " rows in ", secs, "s -> ", dst)
}

cat("\n")
say("Done. Build against the copies with OPTUM_CDM_SCHEMA=", target)
