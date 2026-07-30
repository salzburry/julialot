# =============================================================================
# ie_config.R -- configuration, naming and object construction for cohort 1
# -----------------------------------------------------------------------------
# Cohort 1 = the Overall cohort: MM patients who clear the index-anchored IE
# funnel and have MM-agent evidence in follow-up. (NOT "1L-treated" -- see
# steps/04_therapy.R. Step 6 requires an MM-agent claim, not a LOT1 regimen.)
#
# This folder implements that funnel FROM THE CDM, so it runs on its own: it does
# not read ELIG_COH_ALLFLAGS and does not need 01_cohort.R to have run.
#
# ---------------------------------------------------------------------------
# EVERY OBJECT IS A REAL TABLE. NO TEMPORARY VIEWS.
# ---------------------------------------------------------------------------
# A Databricks SQL warehouse re-executes a view's definition on every reference,
# so a chain of views re-scans the claims tables once per downstream reader. Each
# step here writes a table in your own schema instead.
#
# The object name is declared ONCE, in a step's `name`, and the CREATE statement
# is generated from it by ie_stmt(). A step's SQL is only the SELECT body, so it
# is not possible for a step to create one object and for the runner to then
# reference or materialize a differently-named one. An earlier revision had
# exactly that bug: views were created prefixed and the checkpoint was
# materialized unprefixed, which fails at the first checkpoint.
#
# ---------------------------------------------------------------------------
# NOTHING OUTSIDE "Jul 28" IS READ AT RUN TIME
# ---------------------------------------------------------------------------
# "Jul 28" is the folder that ships. The plumbing it needs -- the
# pipeline_inputs.csv reader, cfg_defaults, quarterly table resolution -- lives in
# ../lib/ as a verbatim copy of apr_30_2026/R/, byte-identity asserted by
# ../tests/test_equivalence.R while that folder is still around. Configuration is
# ../pipeline_inputs.csv. No file in this folder resolves a path into
# apr_30_2026 -- only the dev-time drift test does, and it skips when that folder
# is absent (asserted by tests/test_cohort_overall.R section 9).
#
# ---------------------------------------------------------------------------
# WHERE THE STUDY PARAMETERS COME FROM -- READ THIS BEFORE CHANGING ANY
# ---------------------------------------------------------------------------
# ../lib/config_prompts.R's `cfg_defaults`, so they are the project's values and
# not a third copy of them. But only SOME are reachable from configuration:
#
#   CONFIGURABLE via env / pipeline_inputs.csv (cfg_defaults reads Sys.getenv):
#       OUTPATIENT_WINDOW  MIN_AGE  the nine APPLY_*  CENSOR_AT_DISENROLLMENT
#       schemas, catalog, DSN, USE_QUARTERLY_TABLES, CODELIST_DIR
#   HARDCODED as literals in cfg_defaults -- no env var reaches them:
#       study_start  study_end  id_start  id_end  baseline_days  gap_days
#       dx_window_30 / _60 / _90
#
# pipeline_inputs.csv's own STUDY_START row says as much: it feeds the NDMM
# dashboard's pregnancy scan, NOT the parent study window. Setting STUDY_END
# there logs "applied" and reaches nothing -- and since quarterly source tables
# resolve off cfg$study_end, a new data vintage would silently keep reading the
# old tables. Two things follow, and both are implemented below:
#
#   1. IE_STUDY_START / IE_STUDY_END / IE_ID_START / IE_ID_END /
#      IE_BASELINE_DAYS / IE_GAP_DAYS DO work here. They are named differently on
#      purpose: a distinct name cannot be confused with the inert one, and the
#      override is layered on top rather than patched into ../lib, which stays a
#      verbatim copy. Every value is validated, and the four dates must be
#      ordered study_start <= id_start <= id_end <= study_end.
#   2. Setting the INERT name (STUDY_END, ID_START, ...) to something that
#      disagrees is an ERROR naming the working variable -- not a silent no-op.
# =============================================================================

# ---- {expr} interpolation, no glue dependency -------------------------------
# The SELECT bodies below are copied from pipeline_steps.R, which uses glue().
# fmt() does the one thing those templates need -- {expr} evaluated in the
# calling frame -- so they stay literally comparable to the legacy ones, which is
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

# ---- locating the Jul 28 root and its lib ----------------------------------
# `here` is this folder (Jul 28/cohort_overall), so the root is its parent. No
# search, no fallback outside the shipped folder.
ie_root <- function(here = NULL) {
  d <- Sys.getenv("IE_ROOT_DIR", unset = "")
  if (!nzchar(d)) d <- if (!is.null(here)) dirname(here) else dirname(getwd())
  if (!file.exists(file.path(d, "lib", "config_prompts.R")))
    stop("cannot find the shipped lib/ at ", file.path(d, "lib"),
         " -- set IE_ROOT_DIR to the Jul 28 folder.", call. = FALSE)
  d
}

# ---- fail-closed reading of the configurable values -------------------------
# The project's own readers are lenient by design: validate_outpatient_window()
# silently substitutes 90 for anything invalid, and as.logical("Y") is NA, which
# isTRUE() then treats as FALSE. Both are fine for a pipeline whose operator is
# watching the prompts. Neither is fine for a governed IE definition run in
# batch: a typo would enlarge the cohort and log nothing. So the raw env values
# are re-read and rejected here, BEFORE any claim is scanned.
.ie_env <- function(k) Sys.getenv(k, unset = "")

.ie_check_bool <- function(k) {
  v <- .ie_env(k)
  if (!nzchar(v)) return(invisible(NULL))
  if (!toupper(trimws(v)) %in% c("TRUE", "FALSE"))
    stop(k, "='", v, "' is not TRUE or FALSE. as.logical() would make it NA, ",
         "isTRUE(NA) is FALSE, and the criterion would silently never apply -- ",
         "so the cohort would be quietly larger. Fix the value.", call. = FALSE)
  invisible(NULL)
}

.ie_check_frozen <- function(cfg, k, field, working) {
  v <- .ie_env(k)
  if (!nzchar(v)) return(invisible(NULL))
  if (!identical(trimws(v), as.character(cfg[[field]])))
    stop(k, "='", v, "' but cfg$", field, " is '", cfg[[field]],
         "'. ", k, " is INERT: cfg_defaults sets ", field, " as a literal and ",
         "reads no env var for it, so this run would silently use '",
         cfg[[field]], "'. Use ", working, " instead -- that one works, and it ",
         "is validated.", call. = FALSE)
  invisible(NULL)
}

# The date / window overrides that DO work here. Layered on top of cfg_defaults
# rather than patched into ../lib, which stays a verbatim copy.
.ie_date_override <- function(cfg, k, field) {
  v <- trimws(.ie_env(k))
  if (!nzchar(v)) return(cfg)
  if (!grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", v))
    stop(k, "='", v, "' is not YYYY-MM-DD.", call. = FALSE)
  d <- suppressWarnings(as.Date(v))
  if (is.na(d)) stop(k, "='", v, "' is not a real date.", call. = FALSE)
  cfg[[field]] <- v
  cfg
}
.ie_int_override <- function(cfg, k, field, min_val = 0L) {
  v <- trimws(.ie_env(k))
  if (!nzchar(v)) return(cfg)
  n <- suppressWarnings(as.integer(v))
  if (is.na(n) || n < min_val)
    stop(k, "='", v, "' is not an integer >= ", min_val, ".", call. = FALSE)
  cfg[[field]] <- n
  cfg
}

# ---- configuration ----------------------------------------------------------
ie_cfg <- function(here = NULL, load_project = TRUE) {
  root <- ie_root(here)
  lib  <- file.path(root, "lib")
  e <- new.env(parent = globalenv())

  # pipeline_inputs.csv first: load_pipeline_inputs() only fills variables that
  # are UNSET, so an explicit env var still wins -- same precedence as every
  # other entry point in the repo.
  if (isTRUE(load_project)) {
    sys.source(file.path(lib, "load_inputs.R"), envir = e)
    if (!isTRUE(e$load_pipeline_inputs(root)))
      stop("could not read ", file.path(root, "pipeline_inputs.csv"),
           ". That file IS the configuration -- running without it would use ",
           "code defaults and quietly build a different cohort.", call. = FALSE)
  }

  # cfg_defaults is entirely Sys.getenv()-driven and has no other dependency, so
  # sourcing it in isolation gives the exact values 01_cohort.R runs with in
  # non-interactive mode.
  sys.source(file.path(lib, "config_prompts.R"), envir = e)
  cfg <- e$cfg_defaults

  # get_quarter_suffix() / get_quarterly_table(): four lines of pure date math.
  # Sourced, not copied.
  source(file.path(lib, "codelists.R"))

  # ---- reject what would otherwise be applied silently ----------------------
  raw_win <- .ie_env("OUTPATIENT_WINDOW")
  if (nzchar(raw_win)) {
    n <- suppressWarnings(as.integer(trimws(raw_win)))
    if (is.na(n) || !n %in% c(30L, 60L, 90L))
      stop("OUTPATIENT_WINDOW='", raw_win, "' is not 30, 60 or 90. ",
           "validate_outpatient_window() would silently substitute 90 and the ",
           "run would look configured. Fix the value.", call. = FALSE)
  }
  cfg$outpatient_window <- e$validate_outpatient_window(cfg$outpatient_window)
  if (!cfg$outpatient_window %in% c(30L, 60L, 90L))
    stop("outpatient_window resolved to ", cfg$outpatient_window, call. = FALSE)

  raw_age <- .ie_env("MIN_AGE")
  if (nzchar(raw_age)) {
    a <- suppressWarnings(as.integer(trimws(raw_age)))
    if (is.na(a) || a < 0L)
      stop("MIN_AGE='", raw_age, "' is not a non-negative integer.",
           call. = FALSE)
  }
  if (is.na(cfg$min_age)) stop("min_age resolved to NA.", call. = FALSE)

  for (k in c("APPLY_AGE_INCL", "APPLY_CE_B_INCL", "APPLY_CE_F_INCL",
              "APPLY_NO_BL_AGENTS_INCL", "APPLY_FU_AGENTS_INCL",
              "APPLY_BASELINE_MM_EXCL", "APPLY_OTHER_MALIG_EXCL",
              "APPLY_PREGNANCY_EXCL", "APPLY_CLINTRIAL_EXCL",
              "CENSOR_AT_DISENROLLMENT", "USE_QUARTERLY_TABLES",
              "USE_CSV_CODELISTS"))
    .ie_check_bool(k)
  for (nm in names(cfg)) {
    if (startsWith(nm, "apply_") && is.na(cfg[[nm]]))
      stop("cfg$", nm, " is NA, so the criterion behind it would never apply. ",
           "Check the corresponding APPLY_* value.", call. = FALSE)
  }
  # ---- the study window ------------------------------------------------------
  # cfg_defaults hardcodes these, so the working knob is the IE_-prefixed name.
  # A conflicting value under the INERT name is an error naming the working one.
  for (p in list(c("STUDY_START", "study_start", "IE_STUDY_START"),
                 c("STUDY_END",   "study_end",   "IE_STUDY_END"),
                 c("ID_START",    "id_start",    "IE_ID_START"),
                 c("ID_END",      "id_end",      "IE_ID_END")))
    .ie_check_frozen(cfg, p[1], p[2], p[3])
  for (p in list(c("IE_STUDY_START", "study_start"),
                 c("IE_STUDY_END",   "study_end"),
                 c("IE_ID_START",    "id_start"),
                 c("IE_ID_END",      "id_end")))
    cfg <- .ie_date_override(cfg, p[1], p[2])
  cfg <- .ie_int_override(cfg, "IE_BASELINE_DAYS", "baseline_days", 1L)
  cfg <- .ie_int_override(cfg, "IE_GAP_DAYS",      "gap_days",      0L)
  # An out-of-order window silently produces an empty or nonsensical cohort:
  # baseline before the data starts, or an ID period outside the study.
  d <- lapply(c(cfg$study_start, cfg$id_start, cfg$id_end, cfg$study_end),
              as.Date)
  if (!all(diff(as.numeric(unlist(d))) >= 0))
    stop("the study window is out of order: study_start ", cfg$study_start,
         " <= id_start ", cfg$id_start, " <= id_end ", cfg$id_end,
         " <= study_end ", cfg$study_end, " does not hold.", call. = FALSE)

  # ---- this folder's own settings -------------------------------------------
  env <- function(k, d) { v <- .ie_env(k); if (nzchar(v)) v else d }
  cfg$root       <- root
  cfg$lib        <- lib
  cfg$obj_prefix <- env("IE_OBJ_PREFIX", "ovr_")
  cfg$flags_view <- env("IE_FLAGS_TABLE", "ELIG_COH_ALLFLAGS")
  # Where every table goes. One schema for everything, unlike the legacy split
  # (checkpoints + cohort to personal_schema, attrition to work_schema).
  cfg$out_schema <- env("IE_OUT_SCHEMA",
                        if (nzchar(cfg$personal_schema)) cfg$personal_schema
                        else cfg$work_schema)

  # An empty IE_OBJ_PREFIX is indistinguishable from unset, so it falls back to
  # the default above rather than erroring. Anything else has to be a usable
  # identifier fragment: a prefix with a space or a dot in it produces an object
  # name that either fails to parse or resolves somewhere unintended.
  if (!grepl("^[A-Za-z][A-Za-z0-9_]*$", cfg$obj_prefix))
    stop("IE_OBJ_PREFIX='", cfg$obj_prefix, "' is not a usable identifier ",
         "prefix (letters, digits and underscore, starting with a letter). It ",
         "is prepended to every object name, and it is the only thing keeping ",
         "these tables from overwriting the legacy pipeline's objects of the ",
         "same name.", call. = FALSE)
  if (!nzchar(cfg$out_schema))
    stop("no output schema: set IE_OUT_SCHEMA, DOMINO_USER_NAME or ",
         "PROJECT_WORK_SCHEMA. Every object here is a real table, so there is ",
         "nowhere to build without one.", call. = FALSE)
  if (identical(tolower(cfg$out_schema), tolower(cfg$cdm_schema)))
    stop("IE_OUT_SCHEMA (", cfg$out_schema, ") is the CDM schema. This build ",
         "creates tables; it must not write into the source schema.",
         call. = FALSE)
  # The prefix guarantees the final table cannot BE the legacy cohort table, but
  # assert it rather than infer it -- this is the object the LOT build reads.
  if (identical(toupper(paste0(cfg$obj_prefix, cfg$final_table_name)),
                toupper(cfg$final_table_name)))
    stop("the prefix does not distinguish the final table from ",
         cfg$final_table_name, call. = FALSE)
  cfg
}

# ---- naming -----------------------------------------------------------------
# ONE rule, because there is one kind of object: catalog.schema.<prefix><name>.
# work() is the only place an object name is formed, and ie_stmt() is the only
# place a CREATE is formed, both from a step's `name`.
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
  work <- function(tbl) full_name(cfg$out_schema, paste0(cfg$obj_prefix, tbl))
  list(full_name = full_name, cdm = cdm, ref = ref, cdm_src = cdm_src,
       work = work, out_schema = function() cfg$out_schema,
       qualifier = function() {
         full_name(cfg$out_schema, cfg$obj_prefix)   # the prefix to canonicalize
       })
}

# The CREATE statement for a step. Generated, never written in a step file.
ie_stmt <- function(v, cfg, h) {
  paste0("CREATE OR REPLACE TABLE ", h$work(v$name), " AS\n", v$select)
}

# ---- the follow-up cap ------------------------------------------------------
# Steps 5/6 (therapy), 9 (pregnancy) and 10 (clinical trial) each need an upper
# bound on follow-up, and it has to be the SAME bound the LOT build uses or the
# IE window and OBS_END_DT disagree.
#   PRIMARY      least(study_end, death)
#   SENSITIVITY  least(study_end, death, ENDDATE_CE)   (CENSOR_AT_DISENROLLMENT)
# Every step that uses it already joins death_dt as `d`; under the sensitivity
# flag it additionally joins ce_flags as `ce`, which ce_join_for_fu_cap supplies.
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
# A STEP is one table.
#   select    the SELECT body ONLY. No CREATE -- see ie_stmt().
#   qc        the headline metric, run after the table is built.
#   qc_extra  optional diagnostics that are NOT compared to the legacy step, for
#             questions the legacy QC does not ask (see 00_inputs.R's
#             unknown-care-setting count).
#   legacy    the step in pipeline_steps.R this reproduces. Compared by
#             tests/test_cohort1_ie.R section 5. NA is allowed but listed, so an
#             addition is visible at review.
ie_view <- function(name, description, select, qc = NULL, qc_extra = NULL,
                    source_tables = NULL, legacy = NA_character_) {
  if (!is.character(name) || !nzchar(name))
    stop("ie_view(): name is required", call. = FALSE)
  if (!is.character(select) || !nzchar(select))
    stop("ie_view(", name, "): select is required", call. = FALSE)
  if (grepl("CREATE\\s+OR\\s+REPLACE", select, ignore.case = TRUE))
    stop("ie_view(", name, "): `select` must be the SELECT body only. The ",
         "CREATE is generated by ie_stmt() from `name`, so an object cannot be ",
         "created under one name and referenced under another.", call. = FALSE)
  list(name = name, description = description, select = select, qc = qc,
       qc_extra = qc_extra, source_tables = source_tables, legacy = legacy)
}

# A CRITERION is one gate in the funnel.
#   step          position in the IE funnel (0-10). NOT the build order.
#   attrition_id  row id in the attrition table -- matches
#                 criteria_attrition.R's ids so the two tables line up.
#   flag_col      the column(s) on the flags table it reads.
#   predicate     the WHERE fragment, ANDed on cumulatively.
#   cfg_key       the toggle that turns it on. NA = always applied.
#   anchor        "index" for every criterion in cohort 1. Recorded rather than
#                 assumed: an anchor is part of a criterion's identity, and the
#                 Overall/NDMM confusion began with treating a re-anchored
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
