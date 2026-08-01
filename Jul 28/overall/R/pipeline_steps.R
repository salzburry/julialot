# The ordered list of CREATE-VIEW steps. One file per phase under steps/, so
# the IE criteria can be read a step at a time.

PHASE_FILES <- c(
  codelists      = "01_codelists.R",
  dx_events      = "02_dx_events.R",
  index_date     = "03_index_date.R",
  enrollment     = "04_enrollment.R",
  demographics   = "05_demographics.R",
  clinical_flags = "06_clinical_flags.R",
  exclusions     = "07_exclusions.R",
  assembly       = "08_assembly.R"
)

PHASE_FNS <- c(
  codelists      = "phase_codelists",
  dx_events      = "phase_dx_events",
  index_date     = "phase_index_date",
  enrollment     = "phase_enrollment",
  demographics   = "phase_demographics",
  clinical_flags = "phase_clinical_flags",
  exclusions     = "phase_exclusions",
  assembly       = "phase_assembly"
)

# Source the phase files. Call once, before build_steps().
load_phase_steps <- function(dir) {
  for (f in PHASE_FILES) {
    p <- file.path(dir, f)
    if (!file.exists(p)) stop("missing phase file: ", p, call. = FALSE)
    source(p)
  }
  invisible(TRUE)
}

build_steps <- function(cfg, mat_tables) {
  h <- make_naming_helpers(cfg, mat_tables)

  # The code lists are loaded as views by load_csv_codelists(), so the steps
  # reference them by name.
  ctx <- list(mm_dx_source       = cfg$cl_mm_dx,
              mm_therapy_source  = cfg$cl_mm_therapy,
              preg_source        = cfg$cl_preg,
              clintrial_source   = cfg$cl_clintrial,
              other_malig_source = cfg$cl_other_malig)

  # The Step 24 filter, built from the criteria catalog.
  ctx$criteria_sql <- build_criteria_sql(build_criteria_catalog(cfg), cfg)

  # Step 1's gate, from the same function run_attrition_report() counts with.
  # Passed through ctx rather than read as a global: the step files see only
  # their arguments, so a step can be sourced and driven on its own.
  ctx$step1_sql <- qualifying_sql(cfg$outpatient_window)

  # Follow-up cap, used by therapy / pregnancy / clintrial so the IE window
  # ends at death or study end.
  #   primary      least(study_end, death)
  #   sensitivity  also cap at last enrollment (censor_at_disenrollment)
  if (isTRUE(cfg$censor_at_disenrollment)) {
    ctx$fu_cap_expr <- glue("least(date('{cfg$study_end}'), coalesce(d.DEATH_DT, date('{cfg$study_end}')), coalesce(ce.ENDDATE_CE, date('{cfg$study_end}')))")
    ctx$ce_join_for_fu_cap <- glue("LEFT JOIN {h$work('ce_flags')} ce ON q.PATID = ce.PATID AND q.index_date = ce.index_date")
  } else {
    ctx$fu_cap_expr <- glue("least(date('{cfg$study_end}'), coalesce(d.DEATH_DT, date('{cfg$study_end}')))")
    ctx$ce_join_for_fu_cap <- ""
  }

  all_phases <- lapply(PHASE_FNS, function(fn)
    function() do.call(fn, list(cfg = cfg, h = h, ctx = ctx)))

  do.call(c, lapply(all_phases, function(fn) fn()))
}
