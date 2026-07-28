# =============================================================================
# load_tables_spec.R -- the registry and the pure SQL builders
# -----------------------------------------------------------------------------
# Sourced by load_tables.R (which adds the connection and execution) and by
# tools/tests/test_load_tables.R (which exercises it with no warehouse and no
# packages). No library() calls, no source(), no DB access, no side effects --
# that separation is what makes the column list and the date rules testable.
#
# Callers must provide: glue(), cfg, wrk(), cdm_src().
# =============================================================================

PREFIX       <- Sys.getenv("SRC_PREFIX", unset = "")
PATIENTS_TBL <- paste0(PREFIX, "src_patients")
MANIFEST_TBL <- paste0(PREFIX, "src_manifest")
target <- function(base) wrk(paste0(PREFIX, base))

# =============================================================================
# The registry: what each table is for, which columns are read, how to window it
# =============================================================================
#   cols   the columns the pipeline actually reads. Verified before copying.
#   date   NULL          -> copy every row for the selected patients
#          list(col=)    -> BETWEEN the window on that column
#          list(from=,to=) -> keep spans OVERLAPPING the window
SOURCE_TABLES <- list(
  list(name = "medical",
       why  = "claim lines: MM agents (PROC_CD/BILL_PROC_CD/NDC), IP/OP setting, pregnancy REV",
       cols = c("PATID", "FST_DT", "PROC_CD", "BILL_PROC_CD", "NDC", "RVNU_CD",
                "POS", "TOS_CD", "CONF_ID", "PAT_PLANID", "CLMID", "LOC_CD"),
       date = list(col = "FST_DT")),

  list(name = "med_diagnosis",
       why  = "diagnoses: MM index, other malignancy, pregnancy",
       cols = c("PATID", "FST_DT", "DIAG", "ICD_FLAG", "PAT_PLANID", "CLMID", "LOC_CD"),
       date = list(col = "FST_DT")),

  list(name = "med_procedure",
       why  = "ICD procedure codes (pregnancy)",
       cols = c("PATID", "FST_DT", "PROC", "ICD_FLAG"),
       date = list(col = "FST_DT")),

  list(name = "rx",
       why  = "pharmacy fills: MM agents + day supply for the MAP build",
       cols = c("PATID", "FILL_DT", "NDC", "DAYS_SUP"),
       date = list(col = "FILL_DT")),

  list(name = "confinement",
       why  = "inpatient stays -> IP/OP classification",
       cols = c("PATID", "CONF_ID", "ADMIT_DATE", "DISCH_DATE"),
       date = list(col = "ADMIT_DATE")),

  list(name = "member_enrollment",
       why  = "enrollment spans -> every CE criterion",
       cols = c("PATID", "ELIGEFF", "ELIGEND"),
       # OVERLAP, not start-date. See the header.
       date = list(from = "ELIGEFF", to = "ELIGEND")),

  list(name = "member_cont_enrollment",
       why  = "demographics (GDR_CD, YRDOB), picked by latest ELIGEND",
       cols = c("PATID", "GDR_CD", "YRDOB", "ELIGEND"),
       date = NULL),                      # filtering would change which row wins

  list(name = "dod",
       why  = "date of death -> ENDDATE and death-aware CE",
       cols = c("PATID", "YMDOD"),
       date = NULL)                       # death can fall after study_end
)

# =============================================================================
parse_args <- function(argv = commandArgs(trailingOnly = TRUE)) {
  get1 <- function(f, d) {
    h <- grep(paste0("^", f, "="), argv, value = TRUE)
    if (length(h)) sub(paste0("^", f, "="), "", h[1]) else d
  }
  a <- list(
    years       = get1("--years", ""),         # "2018:2022" or "" = study window
    patients    = get1("--patients", "all"),   # N | all | from:<table>
    only        = get1("--only", ""),
    dry_run     = "--dry-run"     %in% argv,
    refresh     = "--refresh"     %in% argv,
    all_columns = "--all-columns" %in% argv,   # escape hatch: copy SELECT *
    all_years   = "--all-years"   %in% argv    # escape hatch: no date filter
  )
  if (!grepl("^(all|from:.+|[0-9]+)$", a$patients))
    stop("--patients must be N, 'all', or 'from:<table>'; got '", a$patients, "'",
         call. = FALSE)
  if (nzchar(a$years) && !grepl("^[0-9]{4}:[0-9]{4}$", a$years))
    stop("--years must look like 2018:2022; got '", a$years, "'", call. = FALSE)
  a
}

# The window every date filter uses. Defaults to the configured study period, so
# a default run is an exact copy of what the pipeline scans -- not a sample.
window_bounds <- function(args) {
  if (nzchar(args$years)) {
    p <- strsplit(args$years, ":", fixed = TRUE)[[1]]
    if (as.integer(p[1]) > as.integer(p[2]))
      stop("--years start is after its end: ", args$years, call. = FALSE)
    list(lo = paste0(p[1], "-01-01"), hi = paste0(p[2], "-12-31"),
         label = paste0(args$years, " (narrower than the study window)"))
  } else {
    list(lo = as.character(cfg$study_start), hi = as.character(cfg$study_end),
         label = "configured study window")
  }
}

copy_sql <- function(t, args, win, use_patients) {
  sel <- if (args$all_columns) "s.*"
         else paste0("s.", t$cols, collapse = ", ")
  wh <- character(0)
  if (use_patients)
    wh <- c(wh, glue("cast(s.PATID as string) IN (SELECT PATID FROM {wrk(PATIENTS_TBL)})"))
  if (!args$all_years && !is.null(t$date)) {
    wh <- c(wh, if (!is.null(t$date$col))
      glue("cast(s.{t$date$col} as date) BETWEEN date('{win$lo}') AND date('{win$hi}')")
    else
      # overlap: keep a span if any part of it falls inside the window
      glue("cast(s.{t$date$to} as date) >= date('{win$lo}')
      AND cast(s.{t$date$from} as date) <= date('{win$hi}')"))
  }
  glue("
    CREATE OR REPLACE TABLE {target(t$name)} AS
    SELECT {sel}
    FROM {cdm_src(t$name)} s
    {if (length(wh)) paste0('WHERE ', paste(wh, collapse = '\n      AND ')) else ''}")
}

