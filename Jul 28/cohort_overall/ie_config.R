# =============================================================================
# ie_config.R -- config, naming, and the two constructors
# -----------------------------------------------------------------------------
# The Overall cohort: MM patients who pass the index-anchored IE funnel and have
# an MM-agent claim in follow-up. Built from the Optum CDM, so it does not need
# 01_cohort.R to have run.
#
# Every object is a real table in your personal schema. No temp views -- a
# Databricks SQL warehouse re-runs a view's definition on every read.
#
# The IE switches are in cohort_config.csv (this folder) -- the operator edits
# that to shape the cohort. pipeline_inputs.csv and ../lib supply the rest.
# Nothing outside "Jul 28" is read.
# =============================================================================

# {expr} interpolation. The SELECTs are copied from pipeline_steps.R, which uses
# glue(); this does the same substitution without the dependency, so the
# templates stay comparable to the originals.
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
      val <- eval(parse(text = substr(t, m[i] + 1L, m[i] + len[i] - 2L)),
                  envir = envir)
      pieces <- c(pieces, paste(as.character(val), collapse = ""))
      pos <- m[i] + len[i]
    }
    out[k] <- paste0(c(pieces, substr(t, pos, nchar(t))), collapse = "")
  }
  out
}

# The Jul 28 folder. `here` is cohort_overall/, so the root is its parent.
ie_root <- function(here = NULL) {
  d <- Sys.getenv("IE_ROOT_DIR", unset = "")
  if (!nzchar(d)) d <- if (!is.null(here)) dirname(here) else dirname(getwd())
  if (!file.exists(file.path(d, "lib", "config_prompts.R")))
    stop("no lib/ under ", d, " -- set IE_ROOT_DIR to the Jul 28 folder.",
         call. = FALSE)
  d
}

.ie_env <- function(k) Sys.getenv(k, unset = "")

# ---- config -----------------------------------------------------------------
# Study parameters come from ../lib/config_prompts.R's cfg_defaults, so they are
# the project's values, not a second copy.
#
# Only some are reachable from config. cfg_defaults reads Sys.getenv for
# OUTPATIENT_WINDOW, MIN_AGE, the nine APPLY_*, CENSOR_AT_DISENROLLMENT and the
# schemas. The study window is set as literals there, so STUDY_END and friends do
# nothing -- use IE_STUDY_END etc., handled below.
ie_cfg <- function(here = NULL, load_project = TRUE) {
  root <- ie_root(here)
  lib  <- file.path(root, "lib")
  e <- new.env(parent = globalenv())

  # Config precedence: exported env var > cohort_config.csv > pipeline_inputs.csv
  # > code default. Both loaders only fill variables that are unset, so loading
  # cohort_config.csv FIRST lets it win over the shared file, and a real env var
  # (set before either) wins over both.
  #
  # cohort_config.csv is the operator surface -- the nine IE switches and the
  # handful of parameters that shape the cohort. pipeline_inputs.csv supplies the
  # rest (connection, schemas, CDM source, code-list dir).
  if (isTRUE(load_project)) {
    sys.source(file.path(lib, "load_inputs.R"), envir = e)
    if (!is.null(here) && file.exists(file.path(here, "cohort_config.csv")))
      e$load_pipeline_inputs(here, filename = "cohort_config.csv")
    if (!isTRUE(e$load_pipeline_inputs(root)))
      stop("cannot read ", file.path(root, "pipeline_inputs.csv"),
           " -- that file is the config; without it this builds a different ",
           "cohort.", call. = FALSE)
  }
  sys.source(file.path(lib, "config_prompts.R"), envir = e)
  cfg <- e$cfg_defaults
  source(file.path(lib, "codelists.R"))   # get_quarterly_table()

  # Reject bad values before anything is scanned. The project's own readers are
  # lenient on purpose, which is fine with an operator watching and not fine in
  # batch: validate_outpatient_window() swaps in 90 for anything invalid, and
  # as.logical("Y") is NA, which isTRUE() reads as FALSE -- so a criterion would
  # never apply and the cohort would come out larger.
  w <- .ie_env("OUTPATIENT_WINDOW")
  if (nzchar(w) &&
      !identical(suppressWarnings(as.integer(trimws(w))) %in% c(30L, 60L, 90L),
                 TRUE))
    stop("OUTPATIENT_WINDOW='", w, "' is not 30, 60 or 90. It would silently ",
         "become 90.", call. = FALSE)
  cfg$outpatient_window <- e$validate_outpatient_window(cfg$outpatient_window)

  a <- .ie_env("MIN_AGE")
  if (nzchar(a) && is.na(suppressWarnings(as.integer(trimws(a)))))
    stop("MIN_AGE='", a, "' is not an integer.", call. = FALSE)
  if (is.na(cfg$min_age)) stop("min_age is NA.", call. = FALSE)

  for (k in c("APPLY_AGE_INCL", "APPLY_CE_B_INCL", "APPLY_CE_F_INCL",
              "APPLY_NO_BL_AGENTS_INCL", "APPLY_FU_AGENTS_INCL",
              "APPLY_BASELINE_MM_EXCL", "APPLY_OTHER_MALIG_EXCL",
              "APPLY_PREGNANCY_EXCL", "APPLY_CLINTRIAL_EXCL",
              "CENSOR_AT_DISENROLLMENT", "USE_QUARTERLY_TABLES",
              "USE_CSV_CODELISTS")) {
    v <- .ie_env(k)
    if (nzchar(v) && !toupper(trimws(v)) %in% c("TRUE", "FALSE"))
      stop(k, "='", v, "' is not TRUE or FALSE. It would read as FALSE.",
           call. = FALSE)
  }

  # The study window. cfg_defaults hardcodes it, so IE_STUDY_END is the name that
  # works. A conflicting value under the dead name is an error, not a no-op:
  # quarterly source tables resolve off study_end, so a silent miss would keep
  # reading last vintage's data.
  for (p in list(c("STUDY_START", "study_start"), c("STUDY_END", "study_end"),
                 c("ID_START", "id_start"), c("ID_END", "id_end"))) {
    v <- trimws(.ie_env(p[1]))
    if (nzchar(v) && !identical(v, as.character(cfg[[p[2]]])))
      stop(p[1], "='", v, "' has no effect (cfg_defaults sets ", p[2],
           " as a literal). Use IE_", p[1], " instead.", call. = FALSE)
    v <- trimws(.ie_env(paste0("IE_", p[1])))
    if (nzchar(v)) {
      if (!grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", v) ||
          is.na(suppressWarnings(as.Date(v))))
        stop("IE_", p[1], "='", v, "' is not a YYYY-MM-DD date.", call. = FALSE)
      cfg[[p[2]]] <- v
    }
  }
  d <- as.numeric(as.Date(c(cfg$study_start, cfg$id_start, cfg$id_end,
                            cfg$study_end)))
  if (!all(diff(d) >= 0))
    stop("study window out of order: need study_start <= id_start <= id_end ",
         "<= study_end, got ", cfg$study_start, " / ", cfg$id_start, " / ",
         cfg$id_end, " / ", cfg$study_end, call. = FALSE)

  # ---- this folder's settings ----
  env <- function(k, d) { v <- .ie_env(k); if (nzchar(v)) v else d }
  cfg$root       <- root
  cfg$lib        <- lib
  cfg$obj_prefix <- env("IE_OBJ_PREFIX", "ovr_")
  cfg$flags_view <- env("IE_FLAGS_TABLE", "ELIG_COH_ALLFLAGS")
  # Personal schema, the same way the rest of the pipeline does it:
  # DOMINO_USER_NAME, falling back to the work schema.
  cfg$out_schema <- env("IE_OUT_SCHEMA",
                        if (nzchar(cfg$personal_schema)) cfg$personal_schema
                        else cfg$work_schema)

  # The prefix keeps these tables off the legacy pipeline's names, so it has to
  # be a usable identifier fragment. Empty means unset and takes the default.
  if (!grepl("^[A-Za-z][A-Za-z0-9_]*$", cfg$obj_prefix))
    stop("IE_OBJ_PREFIX='", cfg$obj_prefix, "' must be letters, digits and ",
         "underscore, starting with a letter.", call. = FALSE)
  if (!nzchar(cfg$out_schema))
    stop("no output schema: set DOMINO_USER_NAME or IE_OUT_SCHEMA.",
         call. = FALSE)
  if (identical(tolower(cfg$out_schema), tolower(cfg$cdm_schema)))
    stop("IE_OUT_SCHEMA is the CDM schema. This build writes tables.",
         call. = FALSE)
  cfg
}

# Output-schema enforcement, checked at build time. The build has been run many
# times against osk, so these make sure it keeps writing there.
ie_require_output <- function(cfg) {
  env <- function(k, d) { v <- .ie_env(k); if (nzchar(v)) v else d }

  # Don't fall back to the shared work schema just because DOMINO_USER_NAME was
  # unset -- that would scatter the outputs somewhere unintended.
  if (!nzchar(cfg$personal_schema) && !nzchar(.ie_env("IE_OUT_SCHEMA")) &&
      !identical(toupper(env("IE_ALLOW_WORK_SCHEMA", "FALSE")), "TRUE"))
    stop("DOMINO_USER_NAME is not set, so the output would default to the ",
         "shared work schema '", cfg$work_schema, "'. Set DOMINO_USER_NAME, ",
         "or IE_OUT_SCHEMA=<schema>, or IE_ALLOW_WORK_SCHEMA=TRUE.",
         call. = FALSE)

  # Name the schema you expect and the build refuses to write anywhere else --
  # for a scheduled run where a wrong target should stop everything.
  req <- env("IE_REQUIRE_SCHEMA", "")
  if (nzchar(req) && !identical(tolower(req), tolower(cfg$out_schema)))
    stop("IE_REQUIRE_SCHEMA='", req, "' but the output resolved to '",
         cfg$out_schema, "'. Nothing was written.", call. = FALSE)

  # PERSIST_TO_SCHEMA governs the legacy pipeline's optional persist step. This
  # builder always writes tables, so a FALSE here would look like an off switch
  # that does nothing.
  if (!isTRUE(cfg$persist_to_schema))
    stop("PERSIST_TO_SCHEMA=FALSE has no effect here -- every step writes a ",
         "table. Set it TRUE if you want the outputs written.",
         call. = FALSE)
  invisible(TRUE)
}

# ---- naming -----------------------------------------------------------------
# work() is the only place an object name is built, and it is a pure function of
# the logical name, so two steps naming the same object cannot disagree.
#
# Deliverables are kept after a clean build; everything else is an intermediate
# and dropped (IE_KEEP_INTERMEDIATE=TRUE keeps them for debugging).
IE_DELIVERABLES <- function(cfg)
  c(cfg$flags_view, cfg$final_table_name, "ATTRITION_REPORT", "RUN_STATUS")

ie_names <- function(cfg) {
  full_name <- function(schema, object) {
    if (nzchar(cfg$catalog)) paste0(cfg$catalog, ".", schema, ".", object)
    else paste0(schema, ".", object)
  }
  list(full_name = full_name,
       ref = function(tbl) full_name(cfg$ref_schema, tbl),
       cdm_src = function(base_table)
         full_name(cfg$cdm_schema,
                   if (isTRUE(cfg$use_quarterly_tables))
                     get_quarterly_table(base_table, cfg$study_end)
                   else base_table),
       work = function(tbl) full_name(cfg$out_schema,
                                      paste0(cfg$obj_prefix, tbl)),
       out_schema = function() cfg$out_schema,
       # The leading part of every object name, for the drift test to strip.
       qualifier = function() full_name(cfg$out_schema, cfg$obj_prefix))
}

# Where a step writes. The final cohort is staged, then published only after
# reconciliation passes, so a failed run cannot leave a stale table under the
# published name looking current. Everything else writes to its own name.
ie_target <- function(v, cfg, h)
  if (isTRUE(v$stage)) paste0(h$work(v$name), "__stg") else h$work(v$name)

# A step's CREATE. Built from `name`, never written in a step file.
ie_stmt <- function(v, cfg, h)
  paste0("CREATE OR REPLACE TABLE ", ie_target(v, cfg, h), " AS\n", v$select)

# ---- the follow-up cap ------------------------------------------------------
# Steps 5/6, 9 and 10 need an upper bound on follow-up, and it has to match the
# LOT build's OBS_END_DT.
#   primary      least(study_end, death)
#   sensitivity  also cap at last enrolment (CENSOR_AT_DISENROLLMENT)
# Those steps already join death_dt as `d`; the sensitivity branch also needs
# ce_flags as `ce`, which ce_join_for_fu_cap adds.
ie_fu_cap <- function(cfg, h) {
  if (isTRUE(cfg$censor_at_disenrollment))
    list(fu_cap_expr = fmt("least(date('{cfg$study_end}'), coalesce(d.DEATH_DT, date('{cfg$study_end}')), coalesce(ce.ENDDATE_CE, date('{cfg$study_end}')))"),
         ce_join_for_fu_cap = fmt("LEFT JOIN {h$work('ce_flags')} ce ON q.PATID = ce.PATID AND q.index_date = ce.index_date"))
  else
    list(fu_cap_expr = fmt("least(date('{cfg$study_end}'), coalesce(d.DEATH_DT, date('{cfg$study_end}')))"),
         ce_join_for_fu_cap = "")
}

# ---- constructors -----------------------------------------------------------
# A step is one table.
#   select    the SELECT body only. The CREATE comes from ie_stmt().
#   qc        headline metric, run after the table is built.
#   qc_extra  optional diagnostic; not compared to the legacy step.
#   legacy    the pipeline_steps.R step this reproduces, for the drift test.
ie_view <- function(name, description, select, qc = NULL, qc_extra = NULL,
                    source_tables = NULL, legacy = NA_character_,
                    stage = FALSE) {
  if (!is.character(name) || !nzchar(name))
    stop("ie_view(): name is required", call. = FALSE)
  if (!is.character(select) || !nzchar(select))
    stop("ie_view(", name, "): select is required", call. = FALSE)
  if (grepl("CREATE\\s+OR\\s+REPLACE", select, ignore.case = TRUE))
    stop("ie_view(", name, "): give the SELECT body only. The CREATE is built ",
         "from `name`, so a step cannot create one object and reference ",
         "another.", call. = FALSE)
  list(name = name, description = description, select = select, qc = qc,
       qc_extra = qc_extra, source_tables = source_tables, legacy = legacy,
       stage = stage)
}

# A criterion is one gate.
#   step      place in the funnel, 1-10. Not the build order.
#   flag_col  the column(s) on the flags table it reads.
#   predicate the WHERE fragment, ANDed on cumulatively.
#   cfg_key   the toggle. NA means it always applies.
#   anchor    always "index" here. A LOT1-anchored criterion is a different
#             criterion, not the same one re-parameterised.
ie_criterion <- function(step, id, label, flag_col, predicate,
                         cfg_key = NA_character_, polarity = "include",
                         attrition_id = NA_character_, anchor = "index",
                         note = NULL) {
  if (!polarity %in% c("include", "exclude"))
    stop("ie_criterion(", id, "): polarity must be include or exclude",
         call. = FALSE)
  if (!identical(anchor, "index"))
    stop("ie_criterion(", id, "): this cohort is index-anchored. A ",
         "LOT1-anchored criterion belongs to NDMM.", call. = FALSE)
  list(step = as.integer(step), id = id, label = label, flag_col = flag_col,
       predicate = predicate, cfg_key = cfg_key, polarity = polarity,
       attrition_id = attrition_id, anchor = anchor, note = note)
}
