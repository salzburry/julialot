# =============================================================================
# pipeline_steps.R -- build the ordered list of CREATE-VIEW steps
# -----------------------------------------------------------------------------
# Same steps, same order, same SQL as apr_30_2026/R/pipeline_steps.R. The only
# change is that each phase now lives in its own file under steps/, so the IE
# criteria can be read one at a time.
#
#   steps/01_codelists.R      code lists
#   steps/02_dx_events.R      MM diagnosis events
#   steps/03_index_date.R     Step 1   qualifying dx, all candidate index dates
#   steps/04_enrollment.R     Steps 3-4 continuous enrollment
#   steps/05_demographics.R   Step 2   age at index, plus death date
#   steps/06_clinical_flags.R Steps 5-7 MM therapy, baseline MM dx
#   steps/07_exclusions.R     Steps 8-10 other cancer, pregnancy, clin trial
#   steps/08_assembly.R       join flags, apply criteria, earliest index
#
# The funnel itself is in criteria_attrition.R.
#
# The phases used to be closures inside build_steps(). They now take the helpers
# they used to capture: `h` (naming) and `ctx` (criteria SQL, follow-up cap,
# code-list sources).
# =============================================================================

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

build_steps <- function(cfg, mat_tables, phases = NULL) {
  h <- make_naming_helpers(cfg, mat_tables)

  # Code-list sources. With use_csv_codelists = TRUE the CSVs have already been
  # loaded into temp views by load_csv_codelists(), so reference them by name.
  if (isTRUE(cfg$use_csv_codelists)) {
    ctx <- list(mm_dx_source       = cfg$cl_mm_dx,
                mm_therapy_source  = cfg$cl_mm_therapy,
                preg_source        = cfg$cl_preg,
                clintrial_source   = cfg$cl_clintrial,
                other_malig_source = cfg$cl_other_malig)
  } else {
    ctx <- list(mm_dx_source       = h$ref(cfg$cl_mm_dx),
                mm_therapy_source  = h$ref(cfg$cl_mm_therapy),
                preg_source        = h$ref(cfg$cl_preg),
                clintrial_source   = h$ref(cfg$cl_clintrial),
                other_malig_source = h$ref(cfg$cl_other_malig))
  }

  # The Step 24 filter, built from the criteria catalog.
  ctx$criteria_sql <- build_criteria_sql(build_criteria_catalog(cfg), cfg)

  # Follow-up cap, used by therapy / pregnancy / clintrial so the IE window
  # matches whatever LOT's OBS_END_DT uses.
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

  if (is.null(phases)) {
    selected <- all_phases
  } else {
    bad <- setdiff(phases, names(all_phases))
    if (length(bad) > 0) {
      stop("Unknown phase(s): ", paste(bad, collapse = ", "),
           ". Valid phases: ", paste(names(all_phases), collapse = ", "))
    }
    phase_order <- names(all_phases)
    last_idx <- max(match(phases, phase_order))
    missing <- setdiff(phase_order[seq_len(last_idx)], phases)
    if (length(missing) > 0) {
      log_msg("WARN: Skipped prerequisite phase(s): ", paste(missing, collapse = ", "),
              ". Views from those phases must already exist.")
    }
    selected <- all_phases[phases]
  }
  do.call(c, lapply(selected, function(fn) fn()))
}
