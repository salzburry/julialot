#!/usr/bin/env Rscript
# Copy the CDM tables this study needs into the work schema, so the build
# stops re-scanning the shared quarterly tables.
#
#   Rscript "Jul 28/stage_cdm.R"
#   OPTUM_CDM_SCHEMA=osk02156 Rscript "Jul 28/overall/build.R"
#
# The copies keep the names cdm_src() builds, so pointing OPTUM_CDM_SCHEMA at
# them is the only change. Run once per data vintage.
#
# Claim tables use the study window. The other four are copied whole.

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

# Baseline looks back from the earliest possible index date. study_start only
# clears that by a day, so derive the bound instead of trusting it.
need_from <- as.Date(id_start) - baseline - gap
from <- format(min(as.Date(study_start), need_from))
to   <- study_end

if (!nzchar(target))
  stop("No work schema. Set DOMINO_USER_NAME or PROJECT_WORK_SCHEMA.", call. = FALSE)
if (identical(target, cdm_schema))
  stop("Target schema is the CDM schema. Refusing to write over the source.",
       call. = FALSE)

# Date column to bound on, or NA to copy the whole table.
# confinement joins on CONF_ID and a stay can start before the window.
# The enrollment tables carry the baseline coverage. dod is small.
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

  # Same filter both sides, or the copy is quietly short.
  n_src <- dbGetQuery(con, paste0("SELECT count(*) AS n FROM ", src, where))$n
  n_dst <- dbGetQuery(con, paste0("SELECT count(*) AS n FROM ", dst))$n
  secs  <- round(as.numeric(difftime(Sys.time(), t0, units = "secs")), 1)
  if (!identical(as.numeric(n_src), as.numeric(n_dst)))
    stop(base, ": staged ", n_dst, " rows, source has ", n_src, call. = FALSE)
  say("  ", format(n_dst, big.mark = ","), " rows in ", secs, "s -> ", dst)
}

cat("\n")
say("Done. Build against the copies with OPTUM_CDM_SCHEMA=", target)
