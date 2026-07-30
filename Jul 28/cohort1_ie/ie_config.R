# =============================================================================
# ie_config.R -- configuration + naming for the Cohort 1 (Overall) IE build
# -----------------------------------------------------------------------------
# Cohort 1 = the Overall cohort: every 1L-treated MM patient that clears the
# index-anchored IE funnel. This folder implements that funnel FROM THE CDM, so
# it runs on its own -- it does not read ELIG_COH_ALLFLAGS and does not need
# 01_cohort.R to have run first.
#
# ---------------------------------------------------------------------------
# WHERE THE STUDY PARAMETERS COME FROM
# ---------------------------------------------------------------------------
# NOT from this file. `ie_cfg()` loads pipeline_inputs.csv and then reads
# apr_30_2026/R/config_prompts.R's own `cfg_defaults`, so the study window, the
# baseline length, the outpatient window, MIN_AGE and all nine APPLY_* toggles
# are THE PROJECT'S VALUES, not a second copy of them. Change
# pipeline_inputs.csv and this build changes with it.
#
# That is deliberate. The one thing this folder duplicates is the criteria SQL
# (see README "The cost, stated plainly"); duplicating the configuration on top
# of that is how two builds silently end up being two different studies.
#
# ---------------------------------------------------------------------------
# WHAT IT WRITES, AND WHAT IT REFUSES TO WRITE
# ---------------------------------------------------------------------------
# Every temp view is prefixed (IE_VIEW_PREFIX, default `c1_`) so nothing here
# can collide with the legacy pipeline's unprefixed temp views. The persisted
# cohort goes to IE_FINAL_TABLE (default C1_ELIG_COH_FINAL) -- never to
# FINAL_TABLE_NAME, which is the legacy pipeline's output. Pointing the two at
# the same object is refused unless you say so explicitly.
# =============================================================================

# ---- {expr} interpolation, no glue dependency -------------------------------
# The SQL below is copied from pipeline_steps.R, which uses glue(). Rather than
# take on that dependency for a text substitution, `fmt()` does the same job for
# the one feature those templates use: {expr} evaluated in the calling frame.
# Templates therefore stay literally comparable to the legacy ones, which is
# what tests/test_cohort1_ie.R section 5 relies on.
fmt <- function(tmpl, envir = parent.frame()) {
  out <- character(length(tmpl))
  for (k in seq_along(tmpl)) {
    t <- tmpl[[k]]
    m <- gregexpr("\\{[^{}]+\\}", t)[[1]]
    if (m[1] == -1L) { out[k] <- t; next }
    len <- attr(m, "match.length")
    pieces <- character(0)
    pos <- 1L
    for (i in seq_along(m)) {
      pieces <- c(pieces, substr(t, pos, m[i] - 1L))
      expr <- substr(t, m[i] + 1L, m[i] + len[i] - 2L)
      val <- eval(parse(text = expr), envir = envir)
      pieces <- c(pieces, paste(as.character(val), collapse = ""))
      pos <- m[i] + len[i]
    }
    pieces <- c(pieces, substr(t, pos, nchar(t)))
    out[k] <- paste0(pieces, collapse = "")
  }
  out
}

# ---- locating apr_30_2026 ---------------------------------------------------
# READ-ONLY. This folder reads the project's config and DB plumbing from there
# and writes nothing into it (asserted by tests/test_equivalence.R section 1,
# which diffs the entire directory against the branch point).
ie_apr_dir <- function(here = NULL) {
  d <- Sys.getenv("APR30_DIR", unset = "")
  if (nzchar(d)) {
    if (!file.exists(file.path(d, "R", "config_prompts.R")))
      stop("APR30_DIR=", d, " does not look like apr_30_2026 ",
           "(no R/config_prompts.R).", call. = FALSE)
    return(d)
  }
  cands <- unique(c(if (!is.null(here)) c(dirname(dirname(here)), dirname(here)),
                    getwd(), dirname(getwd())))
  hit <- Filter(function(x) file.exists(file.path(x, "apr_30_2026", "R",
                                                  "config_prompts.R")), cands)
  if (!length(hit))
    stop("cannot find apr_30_2026 from ", paste(cands, collapse = ", "),
         " -- set APR30_DIR.", call. = FALSE)
  file.path(hit[1], "apr_30_2026")
}

# ---- configuration ----------------------------------------------------------
ie_cfg <- function(here = NULL, load_project = TRUE) {
  apr <- ie_apr_dir(here)
  e <- new.env(parent = globalenv())

  # pipeline_inputs.csv first: load_pipeline_inputs() only fills variables that
  # are UNSET, so an explicit env var still wins. Same precedence as every other
  # entry point in the repo.
  if (isTRUE(load_project)) {
    li <- file.path(apr, "R", "load_inputs.R")
    if (file.exists(li)) {
      sys.source(li, envir = e)
      e$load_pipeline_inputs(c(apr, dirname(apr)))
    } else {
      warning("apr_30_2026/R/load_inputs.R is missing; pipeline_inputs.csv was ",
              "NOT loaded, so this run uses env vars and code defaults only -- ",
              "it may not be the configured cohort.",
              call. = FALSE, immediate. = TRUE)
    }
  }

  # The project's own defaults. cfg_defaults is entirely Sys.getenv()-driven and
  # has no other dependency, so sourcing it in isolation is safe and gives the
  # exact values 01_cohort.R would run with in non-interactive mode.
  sys.source(file.path(apr, "R", "config_prompts.R"), envir = e)
  cfg <- e$cfg_defaults
  cfg$outpatient_window <- e$validate_outpatient_window(cfg$outpatient_window)

  # get_quarter_suffix() / get_quarterly_table(): four lines of pure date math
  # that resolve t_<table>_YYYYqQ. Sourced rather than copied.
  source(file.path(apr, "R", "codelists.R"))

  env <- function(k, d) { v <- Sys.getenv(k, unset = ""); if (nzchar(v)) v else d }
  cfg$apr_dir     <- apr
  cfg$view_prefix <- env("IE_VIEW_PREFIX", "c1_")
  cfg$flags_view  <- env("IE_FLAGS_VIEW", "ELIG_COH_ALLFLAGS")
  # The persisted cohort. NOT cfg$final_table_name -- that is the legacy
  # pipeline's table and overwriting it from here would silently replace the
  # cohort the LOT build consumes.
  cfg$ie_final_table <- env("IE_FINAL_TABLE", "C1_ELIG_COH_FINAL")
  cfg$ie_attrition_table <- env("IE_ATTRITION_TABLE", "C1_ATTRITION_REPORT")

  if (identical(toupper(cfg$ie_final_table), toupper(cfg$final_table_name)) &&
      !identical(toupper(env("IE_ALLOW_OVERWRITE_LEGACY", "FALSE")), "TRUE")) {
    stop("IE_FINAL_TABLE (", cfg$ie_final_table, ") is the legacy pipeline's ",
         "output table (FINAL_TABLE_NAME). Writing it from here would replace ",
         "the cohort the LOT build reads. Pick another name, or set ",
         "IE_ALLOW_OVERWRITE_LEGACY=TRUE if replacing it is what you mean.",
         call. = FALSE)
  }
  if (!cfg$outpatient_window %in% c(30L, 60L, 90L))
    stop("OUTPATIENT_WINDOW must be 30, 60 or 90; got ",
         cfg$outpatient_window, call. = FALSE)
  if (!nzchar(cfg$view_prefix))
    stop("IE_VIEW_PREFIX must not be empty -- an unprefixed temp view would ",
         "collide with the legacy pipeline's views of the same name.",
         call. = FALSE)
  cfg
}

# ---- naming -----------------------------------------------------------------
# Two rules, and they are not the same rule:
#   work()     temp views  -- UNQUALIFIED, prefixed. A temp view lives in the
#              session, so qualifying it with a schema does not resolve.
#   persist()  real tables -- catalog.schema.object.
ie_names <- function(cfg) {
  full_name <- function(schema, object) {
    if (nzchar(cfg$catalog)) paste0(cfg$catalog, ".", schema, ".", object)
    else paste0(schema, ".", object)
  }
  cdm <- function(tbl) full_name(cfg$cdm_schema, tbl)
  ref <- function(tbl) full_name(cfg$ref_schema, tbl)
  cdm_src <- function(base_table) {
    if (isTRUE(cfg$use_quarterly_tables))
      cdm(get_quarterly_table(base_table, cfg$study_end))
    else cdm(base_table)
  }
  work <- function(tbl) paste0(cfg$view_prefix, tbl)
  out_schema <- function() {
    if (nzchar(cfg$personal_schema)) cfg$personal_schema else cfg$work_schema
  }
  persist <- function(tbl) full_name(out_schema(), tbl)
  list(full_name = full_name, cdm = cdm, ref = ref, cdm_src = cdm_src,
       work = work, persist = persist, out_schema = out_schema)
}

# ---- the follow-up cap ------------------------------------------------------
# Steps 5/6 (therapy), 9 (pregnancy) and 10 (clinical trial) all need an upper
# bound on follow-up, and it has to be the SAME bound the LOT build uses or the
# IE window and OBS_END_DT disagree.
#   PRIMARY      least(study_end, death)
#   SENSITIVITY  least(study_end, death, ENDDATE_CE)   (CENSOR_AT_DISENROLLMENT)
# Every step that uses it already joins death_dt as `d`; under the sensitivity
# flag it additionally joins ce_flags as `ce`, which is what ce_join_for_fu_cap
# supplies.
ie_fu_cap <- function(cfg, h) {
  if (isTRUE(cfg$censor_at_disenrollment)) {
    list(
      fu_cap_expr = fmt("least(date('{cfg$study_end}'), coalesce(d.DEATH_DT, date('{cfg$study_end}')), coalesce(ce.ENDDATE_CE, date('{cfg$study_end}')))"),
      ce_join_for_fu_cap = fmt("LEFT JOIN {h$work('ce_flags')} ce ON q.PATID = ce.PATID AND q.index_date = ce.index_date"))
  } else {
    list(
      fu_cap_expr = fmt("least(date('{cfg$study_end}'), coalesce(d.DEATH_DT, date('{cfg$study_end}')))"),
      ce_join_for_fu_cap = "")
  }
}

# ---- the two object constructors -------------------------------------------
# A VIEW is one SQL object. `legacy` names the step in pipeline_steps.R that it
# reproduces; tests/test_cohort1_ie.R section 5 renders both and compares them
# token for token, so a divergence is a test failure rather than a silent change
# in who is in the cohort. NA means "no legacy counterpart" -- allowed, but the
# test lists it so an addition is visible at review.
ie_view <- function(name, description, sql, qc = NULL,
                    source_tables = NULL, legacy = NA_character_) {
  if (!is.character(name) || !nzchar(name))
    stop("ie_view(): name is required", call. = FALSE)
  if (!is.character(sql) || !nzchar(sql))
    stop("ie_view(", name, "): sql is required", call. = FALSE)
  list(name = name, description = description, sql = sql, qc = qc,
       source_tables = source_tables, legacy = legacy)
}

# A CRITERION is one gate in the funnel.
#   step          position in the IE funnel (0-10). NOT the build order.
#   attrition_id  row id in the attrition table -- matches
#                 criteria_attrition.R's ids so the two tables line up.
#   flag_col      the 0/1 column on ELIG_COH_ALLFLAGS it reads.
#   predicate     the WHERE fragment, ANDed on cumulatively.
#   cfg_key       the toggle that turns it on. NA = always applied.
#   anchor        "index" for every criterion in cohort 1. Recorded rather than
#                 assumed: an anchor is part of a criterion's identity, and the
#                 Overall/NDMM confusion started with treating a re-anchored
#                 criterion as the same criterion.
ie_criterion <- function(step, id, label, flag_col, predicate,
                         cfg_key = NA_character_, polarity = "include",
                         attrition_id = NA_character_, anchor = "index",
                         note = NULL) {
  if (!polarity %in% c("include", "exclude"))
    stop("ie_criterion(", id, "): polarity must be include or exclude",
         call. = FALSE)
  if (!identical(anchor, "index"))
    stop("ie_criterion(", id, "): cohort 1 is index-anchored throughout. A ",
         "LOT1-anchored criterion belongs to the NDMM cohort, not here.",
         call. = FALSE)
  list(step = as.integer(step), id = id, label = label, flag_col = flag_col,
       predicate = predicate, cfg_key = cfg_key, polarity = polarity,
       attrition_id = attrition_id, anchor = anchor, note = note)
}
