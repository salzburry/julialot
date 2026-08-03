# Runner for the NDMM (1L newly-diagnosed) cohort. Standalone: one module,
# pointed at a cohort prefix.
#
# R/steps holds the rules; this file is the runner around them. It stops when
# an input is missing rather than skipping the filter that needed it - a count
# nobody can reproduce is worse than no count.

`%||%` <- function(a, b) if (is.null(a)) b else a

# Settings that decide what the cohort means. A different value here is a
# different cohort, so they are checked rather than defaulted.
CONTRACT <- list(
  catalog              = "hive_metastore",
  cdm_schema           = "clnprw_optum",
  codelist_dir         = "/mnt/code/codelist",
  use_quarterly_tables = TRUE,
  study_end            = "2026-03-31",
  # Earliest date an eligible 1L treatment can count.
  lot1_from            = "2017-01-01",
  # 12 months of CE and of baseline before the 1L index date.
  pre_lot1_days        = 365L,
  # Days after index a no-gap span must cover for the follow-up CE. Zero is
  # the index date itself - one day - which the study team confirmed for 1L,
  # rather than the three months written elsewhere. See README.
  fu_ce_days           = 0L,
  gap_days             = 30L,
  # The pregnancy scan runs over [study_start, study_end], so this moves who is
  # excluded. It reaches the SQL through NDMM_STUDY_START, which reads the same
  # environment variable.
  study_start          = "2016-01-01",
  # Two outpatient MM claims within this many days confirm a diagnosis, and
  # and the minimum age at that diagnosis.
  outpatient_window    = 90L,
  min_age              = 18L,
  belantamab_abbr      = "BELA",
  tbl_medical          = "medical",
  tbl_med_proc         = "med_procedure",
  tbl_med_diag         = "med_diagnosis",
  tbl_rx               = "rx",
  tbl_confinement      = "confinement",
  tbl_member_enroll    = "member_enrollment",
  tbl_member_elig      = "member_cont_enrollment",
  tbl_dod              = "dod"
)

# Decisions a run may make differently, and what each may be set to.
#
# CONTRACT is what the cohort IS - change one and it is a different cohort, so
# those are rejected. These are the choices nobody has settled, or that only
# the data can answer, and the build writes a review table for each.
#
# Still guarded: each is checked against the values it may take, and all of
# them are recorded in NDMM_RUN_METADATA, so a cohort says which choices
# produced it.
CHOICES <- list(
  mm_adjacent_states   = c("override", "exclude"),
  # Free text: names and codes, validated against the code list at run time by
  # build_ndmm_index_ineligible_codes(), which stops on one that matches
  # nothing. Shape only here.
  index_excluded_abbrs = NULL,
  index_excluded_codes = NULL
)

check_choices <- function(cfg) {
  bad <- character(0)
  for (k in names(CHOICES)) {
    v <- as.character(cfg[[k]] %||% "")
    allowed <- CHOICES[[k]]
    if (is.null(allowed)) {
      if (grepl("[^A-Za-z0-9_,:|%. -]", v))
        bad <- c(bad, paste0(k, " = '", v, "' has characters that would not ",
                             "survive being put in a query"))
    } else if (!(v %in% allowed)) {
      bad <- c(bad, paste0(k, " = '", v, "' (one of: ",
                           paste(allowed, collapse = ", "), ")"))
    }
  }
  if (length(bad))
    stop("Run choices that are not choices:\n  ", paste(bad, collapse = "\n  "),
         call. = FALSE)
  invisible(TRUE)
}

# Tables this build needs from elsewhere. There are none: it reads raw CDM and
# its own code lists and nothing else, which is what lets it be handed over on
# its own.
upstream_tables <- function(cfg) list()

# A temporary view is a query, not a result: Spark re-runs it on every read.
# These are read more than once, and they sit on top of each other - every one
# of the thirteen reads of NDMM_LOT1_STARTS would re-run the whole
# MM-diagnosis chain underneath it, twice over the raw claim tables. Each is
# written to the work schema once and the view is repointed at the table, so
# every later read is a table scan. The steps are untouched: they still name
# the view.
#
# tests/test_runner.R counts the reads in the SQL and fails if anything read
# more than once is missing from here. Two entries the count cannot see are
# BASE_COHORT and BELANTAMAB_PATIDS - the flags step takes those as parameters,
# so they reach the SQL as {elig_coh_final} and {map_stacked}.
#
# NDMM_FLAGS_ALL is checkpointed inside 06_flags.R rather than here, because
# NDMM_PATIDS is defined over it in the same function and Spark inlines a temp
# view's plan: repointing after NDMM_PATIDS exists would leave that view on the
# old query. It is a deliverable as well as a checkpoint.
CHECKPOINTS <- c("NDMM_FLAGS_ALL", "NDMM_CLINTRIAL_FLAGS", "NDMM_MM_DX_CODES",
                 "NDMM_MM_DX_EVENTS", "NDMM_MM_QUALIFYING", "NDMM_BASE_COHORT",
                 "NDMM_ENROLL_SPANS", "NDMM_ENROLL_SPANS_STRICT",
                 "NDMM_MMA_CODELIST",
                 "NDMM_BELANTAMAB_CODES", "NDMM_LOT1_STARTS",
                 "NDMM_OTHER_MALIG_CODES", "NDMM_OTHER_MALIG_EVENTS",
                 "NDMM_PREG_CODES",
                 "NDMM_BELANTAMAB_PATIDS",
                 "NDMM_INDEX_TX", "NDMM_BELANTAMAB_TX", "NDMM_PATIDS",
                 "NDMM_INDEX_INELIGIBLE")

# What the run writes. All prefixed, so two cohorts sit side by side.
DELIVERABLES <- c("NDMM_COHORT", "NDMM_ATTRITION", "NDMM_INDEX_AGENTS",
                  "NDMM_MM_ADJACENT_GROUPS",
                  "NDMM_MM_ADJACENT_CODES", "NDMM_FU_CE_COUNTS",
                  "NDMM_OTHER_MALIG_GROUPS", "NDMM_OTHER_MALIG_GRAIN",
                  "NDMM_OTHER_MALIG_CODES",
                  "NDMM_BELANTAMAB_RECONCILE",
                  "NDMM_CODELIST_METADATA", "NDMM_RUN_METADATA",
                  "NDMM_BUILD_STATUS")
OUTPUTS <- c(DELIVERABLES, CHECKPOINTS)

# Conditions the study team can accept for a given data set. Nothing else can
# be waived, and a waiver naming something not here is a typo, not a decision.
WAIVABLE_CHECKS <- c("claim_ndc_shape", "claim_ndc_short",
                     "codelist_ndc_shape", "codelist_ndc_short",
                     "raw_icd_flag")

waivers_named <- function() {
  v <- trimws(strsplit(Sys.getenv("NDMM_WAIVERS", unset = ""), "[,|]")[[1]])
  v[nzchar(v)]
}

# Never hands back something outside the waivable set, whatever the environment
# says, so a bypassed check_settings cannot widen it.
waivers <- function() intersect(waivers_named(), WAIVABLE_CHECKS)

# Write a view's rows to the schema, then point the view at the table. Nothing
# that reads it has to know: the name is unchanged, and every read after this
# is a scan of a table rather than a re-run of the query.
#
# No fallback. The source degraded to the in-place view on a write failure,
# which is correct but can turn minutes into hours without saying so, and a
# table this build declares as an output would then not be there.
checkpoint <- function(con, name) {
  view <- get(name, envir = globalenv())
  tbl  <- wrk(name)
  t0   <- proc.time()
  db_exec(con, glue("CREATE OR REPLACE TABLE {tbl} AS SELECT * FROM {view}"))
  db_exec(con, glue("CREATE OR REPLACE TEMPORARY VIEW {view} AS SELECT * FROM {tbl}"))
  log_msg("  checkpoint ", name, " -> ", tbl, " (",
          round((proc.time() - t0)[["elapsed"]], 1), "s)")
  invisible(TRUE)
}

check_settings <- function() {
  bad <- character(0)
  unknown <- setdiff(waivers_named(), WAIVABLE_CHECKS)
  if (length(unknown))
    bad <- c(bad, paste0("NDMM_WAIVERS names no such check: ",
                         paste(unknown, collapse = ", "),
                         " (waivable: ", paste(WAIVABLE_CHECKS, collapse = ", "), ")"))
  for (v in c("STUDY_END", "LOT1_FROM", "STUDY_START")) {
    x <- trimws(Sys.getenv(v, unset = ""))
    if (nzchar(x) && !grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", x))
      bad <- c(bad, paste0(v, "='", x, "' (want YYYY-MM-DD)"))
  }
  for (v in c("PRE_LOT1_DAYS", "FU_CE_DAYS", "GAP_DAYS")) {
    x <- trimws(Sys.getenv(v, unset = ""))
    # The text, not what coercion makes of it: as.integer("60.5") is 60.
    if (nzchar(x) && !grepl("^[0-9]+$", x))
      bad <- c(bad, paste0(v, "='", x, "' (want a whole number)"))
  }
  r <- Sys.getenv("DOMINO_RUN_ID", unset = "")
  if (nzchar(r) && !grepl("^[A-Za-z0-9_.-]+$", r))
    bad <- c(bad, paste0("DOMINO_RUN_ID='", r, "' (want letters, digits, _ . -)"))
  if (length(bad))
    stop("Settings that would build a different cohort:\n  ",
         paste(bad, collapse = "\n  "), call. = FALSE)
  invisible(TRUE)
}

pin_output_schema <- function(cfg) {
  schema <- Sys.getenv("PROJECT_WORK_SCHEMA",
              unset = Sys.getenv("DOMINO_USER_NAME",
                unset = Sys.getenv("DOMINO_STARTING_USERNAME", unset = "")))
  if (!nzchar(schema))
    stop("No output schema. Set DOMINO_USER_NAME to your personal schema, ",
         "or PROJECT_WORK_SCHEMA to override.", call. = FALSE)
  if (!grepl("^[A-Za-z_][A-Za-z0-9_]*$", schema))
    stop("Output schema '", schema, "' is not a schema name.", call. = FALSE)
  cfg$work_schema <- schema
  cfg
}

# The caller says which cohort. Every table read and written carries the
# prefix, so this folder names no cohort of its own.
pin_prefix <- function(cfg, prefix) {
  prefix <- trimws(as.character(prefix %||% ""))
  if (!nzchar(prefix))
    stop("NDMM needs an output prefix.\n",
         "  Rscript build.R <prefix_>\n",
         "  or set OBJECT_PREFIX.", call. = FALSE)
  if (!grepl("^[A-Za-z][A-Za-z0-9_]*_$", prefix))
    stop("Prefix '", prefix, "' should be a name ending in '_', e.g. mystudy_.",
         call. = FALSE)
  cfg$object_prefix <- prefix
  cfg
}

check_contract <- function(cfg) {
  wrong <- Filter(Negate(is.null), lapply(names(CONTRACT), function(k) {
    if (isTRUE(all.equal(cfg[[k]], CONTRACT[[k]]))) NULL
    else paste0(k, " = ", format(cfg[[k]]), " (want ", format(CONTRACT[[k]]), ")")
  }))
  if (length(wrong))
    stop("This cohort is defined as:\n  ", paste(unlist(wrong), collapse = "\n  "),
         call. = FALSE)
  invisible(TRUE)
}

# Every raw CDM table a step reads. member_enrollment is the first one used -
# both enrollment-span builds sit on it - and it was missing from this list,
# so the preflight passed and the run then failed inside phase one.
raw_tables <- function(cfg) {
  c(cfg$tbl_medical, cfg$tbl_rx, cfg$tbl_med_diag, cfg$tbl_med_proc,
    cfg$tbl_confinement, cfg$tbl_member_enroll, cfg$tbl_member_elig, cfg$tbl_dod)
}

# Every input table, before any work. Skipping a filter whose
# inputs it could not read and carried on, which produces a cohort that is
# smaller than it should be with nothing in the output saying so.
check_upstream <- function(con, cfg) {
  missing <- character(0)
  up <- upstream_tables(cfg)
  for (t in names(up)) {
    got <- tryCatch({ db_q(con, glue("SELECT 1 FROM {wrk(t)} LIMIT 1")); TRUE },
                    error = function(e) FALSE)
    if (!got) missing <- c(missing, paste0(wrk(t), " (built by ", up[[t]], ")"))
  }
  raw <- raw_tables(cfg)
  for (t in raw) {
    got <- tryCatch({ db_q(con, glue("SELECT 1 FROM {cdm_src(t)} LIMIT 1")); TRUE },
                    error = function(e) FALSE)
    if (!got) missing <- c(missing, cdm_src(t))
  }
  if (length(missing))
    stop("Cannot read:\n  ", paste(missing, collapse = "\n  "),
         "\nEvery NDMM filter needs its input. Skipping one would drop patients ",
         "the criteria do not exclude, and the attrition would not say so.",
         call. = FALSE)
  log_msg("Inputs present (", length(up), " built, ",
          length(raw), " raw)")
  invisible(TRUE)
}

# The SQL does not read cfg. It reads the NDMM_* constants in
# nndm_constants.R, which carries its own environment variables -
# NDMM_LOT1_FROM among them. So a contract checked against cfg proves nothing
# about the query that runs. This compares the constants themselves, after the
# modules are loaded, and is the only check that speaks for the SQL.
CONSTANT_SETTINGS <- list(
  list(const = "NDMM_LOT1_FROM",     cfg = "lot1_from",
       note = "set by NDMM_LOT1_FROM, not LOT1_FROM"),
  list(const = "NDMM_PRE_LOT1_DAYS", cfg = "pre_lot1_days", note = ""),
  list(const = "NDMM_FU_CE_DAYS",    cfg = "fu_ce_days",    note = ""),
  list(const = "NDMM_GAP_DAYS",      cfg = "gap_days",      note = ""),
  list(const = "NDMM_STUDY_START",   cfg = "study_start",
       note = "set by STUDY_START"),
  # Table names are settings too: an ambient TBL_CONFINEMENT changes what the
  # other-cancer rule reads while cfg, and so the contract, is unmoved.
  list(const = "NDMM_TBL_CONFINEMENT",       cfg = "tbl_confinement",   note = ""),
  list(const = "NDMM_TBL_MEMBER_ENROLLMENT", cfg = "tbl_member_enroll", note = ""),
  list(const = "NDMM_OUTPATIENT_WINDOW",       cfg = "outpatient_window",  note = ""),
  list(const = "NDMM_MIN_AGE",                 cfg = "min_age",            note = ""),
  # Which agents may not set the index. Empty by default; a value here shrinks
  # the cohort, so it is pinned like any other thing that does.
  # The run choices are here too. Not to pin them to a default - CHOICES does
  # the allowing - but because the SQL reads the constants, so the value cfg
  # was checked for has to be the value the query gets.
  list(const = "NDMM_INDEX_EXCLUDED_ABBRS",   cfg = "index_excluded_abbrs", note = ""),
  list(const = "NDMM_INDEX_EXCLUDED_CODES",   cfg = "index_excluded_codes", note = ""),
  list(const = "NDMM_MM_ADJACENT_STATES",     cfg = "mm_adjacent_states", note = ""),
  # Not a cohort window but a code-list assumption, and just as able to change
  # the count: it is what identifies belantamab, and belantamab is exclusion 4.
  list(const = "NDMM_BELANTAMAB_ABBR",        cfg = "belantamab_abbr",    note = "")
  # NDMM_FINAL_TABLE_NAME is defined in the constants file and read by
  # nothing - the runner passes the cohort table in. Nothing to check, because
  # nothing uses it; the test below only requires constants the steps read.

)

check_constants <- function(cfg) {
  wrong <- character(0)
  for (s in CONSTANT_SETTINGS) {
    if (!exists(s$const, envir = globalenv()))
      stop("Module constant ", s$const, " is not loaded; the modules must be ",
           "sourced before the settings can be checked.", call. = FALSE)
    got <- get(s$const, envir = globalenv())
    if (!isTRUE(all.equal(as.character(got), as.character(cfg[[s$cfg]]))))
      wrong <- c(wrong, paste0(s$const, " = ", format(got), " but ", s$cfg,
                               " = ", format(cfg[[s$cfg]]),
                               if (nzchar(s$note)) paste0(" (", s$note, ")") else ""))
  }
  if (length(wrong))
    stop("The SQL would not use the settings this run checked:\n  ",
         paste(wrong, collapse = "\n  "),
         "\nThese constants are what the queries read. A cohort built from ",
         "them is not the cohort the contract describes.", call. = FALSE)
  invisible(TRUE)
}

# The six flag criteria, in the study's own order: the enrollment inclusions,
# then the four exclusions as they are listed, belantamab last.
# Don't reorder it - this is the funnel's order.
#
# One list, three readers. NDMM_PATIDS ANDs the whole set, ndmm_counts() walks a
# prefix of it per funnel row, and ATTRITION_STEPS below takes the labels. Each
# reader used to spell the predicates out for itself: six flags in the view and
# fifteen more in the counts, kept in step by hand. Nothing said when they
# stopped agreeing, and a flag added to the view alone would drop the last row
# of the funnel under a label that named a different criterion.
NDMM_CRITERIA <- list(
  list(key = "ce12",           flag = "CE_pre_lot1_12mo",
       label = "+ 12-month CE before index"),
  list(key = "ce12_fuce",      flag = "CE_lot1_fu",
       label = "+ CE during follow-up"),
  list(key = "fuce_nopriortx", flag = "NO_PRIOR_MM_TX",
       label = "+ no MM oncology therapy in 12-month baseline"),
  list(key = "noother",        flag = "NO_OTHER_CANCER_PRE_LOT1",
       label = "+ no other cancer in 12-month baseline"),
  list(key = "noother_nopreg", flag = "NO_PREGNANCY",
       label = "+ no pregnancy in study period"),
  list(key = "nopreg_nobela",  flag = "NO_BELANTAMAB_PRE_LOT1",
       label = "+ no belantamab before the 1L index")
)
# The belantamab exclusion - "in any LOT" - is split, because no one
# package can see the whole of it.
#
# The half that is here is belantamab BEFORE the 1L index. The lot package
# cannot see it at any price: map_stacked is built from claims on or after the
# cohort's INDEX_DATE, so a belantamab treatment earlier in the patient's
# history is not in the data lot reads. It is also not a proxy for anything -
# a belantamab claim before the index is a belantamab line before the index -
# so the objection that removed the old cohort-time rule does not apply.
#
# The half that is not here is belantamab from the index onward, which is the
# no_belantamab line criterion in lot, asked of map_stacked over the patient's
# whole LOT span. Together the two halves cover the whole rule.
#
# Note this criterion overlaps NO_PRIOR_MM_TX, deliberately: that one already
# removes any MM oncology therapy in the 12-month baseline, belantamab
# included. Its incremental drop in the attrition is therefore exactly the
# patients whose belantamab predates the baseline - the window nothing covered.
# The other three exclusions name a period; this one names only
# as "in any LOT"; read as post-index it would do nothing the first bullet had
# not already done for the window they share. See DECISIONS.md #2.
#
# NO_BELANTAMAB - the whole-study-period flag - is still computed and still
# ships on the cohort table as an advisory; nothing filters on it. So this table
# is the NDMM cohort pending only lot's half, and the funnel has nine steps.

# The first n criteria as a WHERE body, in the funnel's order.
#
#   all of them          the cohort itself, which is what NDMM_PATIDS asks for
#   a prefix (n)         one row of the funnel, which is what ndmm_counts() asks
#   one dropped (except) a sensitivity report, which recomputes that criterion
#                        its own way and ANDs the rest - so the row it prints is
#                        a cohort size and not one criterion's count
#
# alias qualifies the columns where the flags arrive through a join. except is
# checked rather than filtered: a mistyped flag would silently leave the
# criterion in, and the report would then say the cohort is bigger than it is.
ndmm_criteria_where <- function(n = length(NDMM_CRITERIA), except = character(0),
                                alias = "") {
  flags <- vapply(NDMM_CRITERIA[seq_len(n)], function(cr) cr$flag, character(1))
  unknown <- setdiff(except, flags)
  if (length(unknown))
    stop("Not a criterion of this cohort: ", paste(unknown, collapse = ", "),
         ". The flags are ", paste(flags, collapse = ", "), ".", call. = FALSE)
  paste(paste0(alias, setdiff(flags, except), " = 1"), collapse = " AND ")
}

# The nine rows of the attrition. The first three count off their own tables -
# a qualifying MM diagnosis, then age, then an eligible 1L treatment - so they
# are named here; the rest are the flag criteria above. Names are the criterion,
# not the column, because this table is what gets read.
ATTRITION_STEPS <- c(
  list(
    list(key = "whole",     label = "Patients with a qualifying MM diagnosis"),
    list(key = "elig",      label = "+ aged 18 or over at diagnosis"),
    list(key = "elig_lot1", label = "+ eligible 1L treatment on or after LOT1_FROM")),
  lapply(NDMM_CRITERIA, function(cr) list(key = cr$key, label = cr$label)))

ATTRITION_COLS <- c(RUN_ID = "STRING", STEP_NUM = "INT", CRITERION = "STRING",
                    N_PATIENTS = "BIGINT", PCT_OF_START = "DOUBLE",
                    RECORDED_AT = "TIMESTAMP")

# The attrition as a table, not only a log line. It is the deliverable here -
# the request was the count and the funnel that reaches it.
write_attrition <- function(con, cfg, counts) {
  tbl <- wrk("NDMM_ATTRITION")
  cols <- names(ATTRITION_COLS)
  db_exec(con, glue("CREATE TABLE IF NOT EXISTS {tbl} (",
                    paste(cols, ATTRITION_COLS, collapse = ", "), ")"))
  start <- counts[[ATTRITION_STEPS[[1]]$key]]
  vals <- vapply(seq_along(ATTRITION_STEPS), function(i) {
    s <- ATTRITION_STEPS[[i]]
    n <- counts[[s$key]]
    pct <- if (is.null(start) || is.na(start) || start == 0) "NULL"
           else sql_count(round(100 * n / start, 2))
    glue("('{run_id}', {i}, {sql_text(s$label)}, {sql_count(n)}, {pct}, current_timestamp())")
  }, character(1), USE.NAMES = FALSE)
  db_replace(con,
    glue("DELETE FROM {tbl} WHERE RUN_ID = '{run_id}'"),
    glue("INSERT INTO {tbl} ({paste(cols, collapse = ', ')}) VALUES ",
         paste(vals, collapse = ", ")))
  log_msg("Attrition written to ", tbl)
  invisible(TRUE)
}

# The funnel only ever narrows. A step larger than the one above it means a
# join fanned out or a filter was applied to the wrong population.
check_attrition_monotonic <- function(counts) {
  n <- vapply(ATTRITION_STEPS, function(s) as.numeric(counts[[s$key]]), numeric(1))
  bad <- which(n[-1] > n[-length(n)])
  if (length(bad))
    stop("The attrition grows at step ", bad[1] + 1L, " (",
         ATTRITION_STEPS[[bad[1] + 1L]]$label, "): ", n[bad[1]], " -> ",
         n[bad[1] + 1L], ". Each step is a subset of the one above it, so this ",
         "is a fan-out, not a count.", call. = FALSE)
  if (n[length(n)] == 0)
    stop("The NDMM cohort is empty. Every patient was excluded by some ",
         "criterion; the attrition above says which one.", call. = FALSE)
  invisible(TRUE)
}

# The prior-therapy scan matches an NDC by stripping non-digits and left-padding
# to eleven. That is the 4-4-2 layout; 5-3-2 and 5-4-1 ten-digit NDCs pad to a
# different key, so a genuine prior therapy can be missed or the wrong drug
# matched - and the patient's inclusion turns on it. Nothing downstream can see
# that happen, so profile the values first and say what is there.
#
# Both sides, because the join pads both: a ten-digit code list has the same
# problem as a ten-digit claim.
#
# Scoped to the base cohort rather than to the 1L starts. The starts do not
# exist yet - the scan that builds them matches NDCs itself, so the profile has
# to come first, and reading NDMM_LOT1_STARTS here made the build stop with a
# missing view.
#
# The window is the whole study period, or a year before the patient's
# diagnosis if that is earlier. That covers every NDC any scan in this build
# matches: the index scan and the baseline scan sit inside the year-before
# window, and the belantamab exclusion runs over the study period - a patient
# diagnosed in 2025 can have a 2016 belantamab NDC that the exclusion reads and
# a diagnosis-anchored profile would never have looked at.
check_ndc_shape <- function(con, cfg) {
  log_msg("Checking NDC shape...")
  # Every non-blank value, including ones that cannot join. A profile that
  # skipped them would report "all eleven digits" without having looked.
  shape_cols <- "
           count(*) AS n_ndc,
           sum(CASE WHEN d = 11 THEN 1 ELSE 0 END) AS n_11,
           sum(CASE WHEN d = 10 THEN 1 ELSE 0 END) AS n_10,
           sum(CASE WHEN d NOT IN (10, 11) THEN 1 ELSE 0 END) AS n_other,
           sum(CASE WHEN v RLIKE '[A-Za-z]' THEN 1 ELSE 0 END) AS n_alpha,
           sum(CASE WHEN d = 0 THEN 1 ELSE 0 END) AS n_nodigit,
           sum(CASE WHEN d > 0 AND digits RLIKE '^0+$' THEN 1 ELSE 0 END) AS n_zero"
  claim_sql <- function(src, tbl, dt) glue("
    SELECT '{src}' AS SOURCE, {shape_cols}
    FROM (
      SELECT v, digits, length(digits) AS d
      FROM (
        SELECT v, regexp_replace(v, '[^0-9]', '') AS digits
        FROM (
          SELECT cast(t.NDC as string) AS v
          FROM {tbl} t
          INNER JOIN {NDMM_BASE_COHORT} b ON cast(t.PATID as string) = b.PATID
          WHERE cast(t.NDC as string) IS NOT NULL
            AND trim(cast(t.NDC as string)) <> ''
            AND cast(t.{dt} AS date)
                  BETWEEN least(date('{NDMM_STUDY_START}'),
                                date_sub(b.MM_DX_DT, {NDMM_PRE_LOT1_DAYS}))
                      AND date('{cfg$study_end}'))))")
  codelist_sql <- glue("
    SELECT 'codelist' AS SOURCE, {shape_cols}
    FROM (
      SELECT v, digits, length(digits) AS d
      FROM (
        SELECT v, regexp_replace(v, '[^0-9]', '') AS digits
        FROM (
          SELECT code AS v FROM {NDMM_MMA_CODELIST}
          WHERE code_type = 'NDC' AND code IS NOT NULL AND trim(code) <> '')))")
  prof <- rbind(db_q(con, claim_sql("medical", cdm_src(cfg$tbl_medical), "FST_DT")),
                db_q(con, claim_sql("rx",      cdm_src(cfg$tbl_rx),      "FILL_DT")),
                db_q(con, codelist_sql))
  print(prof)

  detail <- function(d) paste(vapply(seq_len(nrow(d)), function(i) with(d[i, ],
    paste0(SOURCE, ": ", n_ndc, " NDCs, ", n_11, " eleven-digit, ", n_10,
           " ten-digit, ", n_other, " other length, ", n_alpha, " with letters, ",
           n_nodigit, " with no digits, ", n_zero, " all zeros")),
    character(1)), collapse = "; ")

  # Four conditions, split claim side from code list side. Accepting one does
  # not accept the others, and the two sides have different remedies: a bad
  # code list can be corrected, the CDM's own values cannot.
  decide <- function(d, name, msg) {
    if (nrow(d) == 0) return(invisible(FALSE))
    if (!(name %in% waivers())) stop(msg, call. = FALSE)
    log_msg("WAIVED (", name, "): ", detail(d))
    options(nndm_waivers_applied = union(getOption("nndm_waivers_applied",
                                                   character(0)), name))
    invisible(TRUE)
  }
  is_cl  <- prof$SOURCE == "codelist"
  bad    <- prof$n_ndc > 0 & (prof$n_alpha > 0 | prof$n_other > 0 | prof$n_zero > 0)
  ten    <- prof$n_ndc > 0 & prof$n_10 > 0

  d <- prof[!is_cl & bad, , drop = FALSE]
  decide(d, "claim_ndc_shape",
         paste0("Claim NDCs that cannot be an NDC: ", detail(d),
                ".\nThe join strips non-digits and pads to eleven, so ABC123 ",
                "arrives as 00000000123 and can match a real code - and this ",
                "build would read that patient as previously treated and drop ",
                "them. If the CDM really carries these, the join has to ",
                "exclude them or the study team has to accept the risk: ",
                "NDMM_WAIVERS=claim_ndc_shape."))
  d <- prof[!is_cl & ten, , drop = FALSE]
  decide(d, "claim_ndc_short",
         paste0("Ten-digit claim NDCs: ", detail(d),
                ".\nLeft-padding to eleven is right only for the 4-4-2 layout; ",
                "a 5-3-2 or 5-4-1 code pads to a different key, so genuine ",
                "prior therapy can be missed or the wrong drug matched. ",
                "Confirm how this CDM represents NDC, or convert with an ",
                "approved NDC10-to-NDC11 crosswalk. Once the study team has ",
                "established the padding is right for this data: ",
                "NDMM_WAIVERS=claim_ndc_short."))
  d <- prof[is_cl & bad, , drop = FALSE]
  decide(d, "codelist_ndc_shape",
         paste0("Code list NDCs that cannot be an NDC: ", detail(d),
                ".\nThis one is fixable at source - correct ",
                "cl_mma_codelist.csv. NDMM_WAIVERS=codelist_ndc_shape to ",
                "proceed without."))
  d <- prof[is_cl & ten, , drop = FALSE]
  decide(d, "codelist_ndc_short",
         paste0("Ten-digit code list NDCs: ", detail(d),
                ".\nThe join pads these the same way it pads claims, so they ",
                "match only claims written in the same layout. Write them as ",
                "NDC11 in cl_mma_codelist.csv, or ",
                "NDMM_WAIVERS=codelist_ndc_short."))

  if (!any(bad) && !any(ten))
    log_msg("  OK: every NDC, on both sides, is eleven digits.")
  invisible(TRUE)
}

# The md5 of every R file this package ships, so two runs can be told apart by
# the code that made them. Radix sort, not the default: character collation is
# locale-dependent and a hash meaning "the same code" must not be.
code_fingerprint <- function(here) {
  fs <- sort(c(list.files(file.path(here, "R"), "\\.R$", full.names = TRUE,
                          recursive = TRUE),
               file.path(here, "build.R")), method = "radix")
  fs <- fs[file.exists(fs)]
  if (!length(fs)) return(NA_character_)
  tmp <- tempfile(); on.exit(unlink(tmp), add = TRUE)
  writeLines(unlist(lapply(fs, readLines, warn = FALSE)), tmp)
  unname(tools::md5sum(tmp))
}

# Sorted, so two runs with the same settings produce the same string and it can
# be compared as one value.
contract_settings <- function() {
  k <- sort(names(CONTRACT), method = "radix")
  paste(paste0(k, "=", vapply(CONTRACT[k], function(v) as.character(v)[1],
                              character(1))), collapse = "|")
}

RUN_METADATA_COLS <- c(RUN_ID = "STRING", OBJECT_PREFIX = "STRING",
                       BELANTAMAB_ABBR = "STRING", INDEX_EXCLUDED = "STRING",
                       INDEX_EXCLUDED_CODES = "STRING",
                       MM_ADJACENT_STATES = "STRING",
                       CODE_MD5 = "STRING",
                       CONTRACT_SETTINGS = "STRING",
                       WAIVERS_REQUESTED = "STRING", WAIVERS_APPLIED = "STRING",
                       N_NDMM = "BIGINT", RECORDED_AT = "TIMESTAMP")

# What made this cohort, beside the cohort. NDMM_BUILD_STATUS says a run
# finished; this says which code and which settings finished it, so an
# NDMM_COHORT found later can be matched to a build rather than guessed at.
# REQUESTED is what the run was given, APPLIED what actually fired - a run can
# ask for a waiver on a condition that never occurs.
write_run_metadata <- function(con, cfg, here, n) {
  tbl  <- wrk("NDMM_RUN_METADATA")
  cols <- names(RUN_METADATA_COLS)
  db_exec(con, glue("CREATE TABLE IF NOT EXISTS {tbl} (",
                    paste(cols, RUN_METADATA_COLS, collapse = ", "), ")"))
  db_replace(con,
    glue("DELETE FROM {tbl} WHERE RUN_ID = '{run_id}'"),
    glue("INSERT INTO {tbl} ({paste(cols, collapse = ', ')}) VALUES (",
         "{sql_text(run_id)}, {sql_text(cfg$object_prefix)}, ",
         "{sql_text(NDMM_BELANTAMAB_ABBR)}, {sql_text(NDMM_INDEX_EXCLUDED_ABBRS)}, ",
         "{sql_text(NDMM_INDEX_EXCLUDED_CODES)}, ",
         "{sql_text(NDMM_MM_ADJACENT_STATES)}, ",
         "{sql_text(code_fingerprint(here))}, ",
         "{sql_text(contract_settings())}, ",
         "{sql_text(paste(sort(waivers_named(), method = 'radix'), collapse = ','))}, ",
         "{sql_text(paste(sort(getOption('nndm_waivers_applied', character(0)), ",
         "method = 'radix'), collapse = ','))}, ",
         "{sql_count(n)}, current_timestamp())"))
  log_msg("Run recorded in ", tbl)
  invisible(TRUE)
}

# NDMM_COHORT is written to be a cohort the lot build can be pointed at, so the
# LOT algorithm can be run over the NDMM patients without anything in between.
# These are the columns that build reads off whatever cohort it is given
# (its REQUIRED_COHORT_COLS). PATID alone would stop
# that build at its own input check.
NDMM_COHORT_COLS <- c("PATID", "INDEX_DATE", "ENDDATE", "ENDDATE_CE",
                      "DEATH_DT", "GDR_CD", "YRDOB", "AGE_INDEX_YR",
                      "FU_DAYS", "FU_DAYS_CE")

# INDEX_DATE is LOT1_START_DT - the NDMM index. Everything that depends on an
# anchor is re-derived from it: age at index, follow-up, and where continuous
# enrollment ends. Carrying values measured elsewhere would describe the
# MM-diagnosis index, and a LOT run over this table would measure its lines
# from the wrong day. Only the demographics are inherited, because a patient's
# sex, birth year and date of death do not move with an anchor.
build_ndmm_cohort_table <- function(con, cfg) {
  se <- glue("date('{cfg$study_end}')")
  run_step(con, "N90_ndmm_cohort", glue("
    CREATE OR REPLACE TABLE {wrk('NDMM_COHORT')} AS
    WITH idx AS (
      SELECT DISTINCT cast(p.PATID as string) AS PATID, l1.LOT1_START_DT AS INDEX_DATE
      FROM {NDMM_PATIDS} p
      INNER JOIN {NDMM_LOT1_STARTS} l1 ON l1.PATID = cast(p.PATID as string)
    ),
    -- Where continuous enrollment ends: the end of the span covering the index
    -- date, with the same gap allowance the 12-month baseline CE uses. This is
    -- ENDDATE_CE, measured at this cohort's own anchor.
    ce AS (
      SELECT i.PATID, max(s.cov_end) AS ENDDATE_CE
      FROM idx i
      INNER JOIN {NDMM_ENROLL_SPANS} s
              ON s.PATID = i.PATID
             AND s.cov_start <= i.INDEX_DATE
             AND s.cov_end   >= i.INDEX_DATE
      GROUP BY i.PATID
    ),
    dem AS (
      SELECT cast(PATID as string) AS PATID, GDR_CD, YRDOB
      FROM {NDMM_BASE_COHORT}
    ),
    -- The death date was imputed against the MM diagnosis, and the cohort is
    -- anchored at the 1L start, which is later. A month-only or year-only
    -- death that lands between the two would give an ENDDATE before the index
    -- and a negative FU_DAYS. Re-clamp at the anchor that is actually used -
    -- the same rule, applied to the right date.
    dth AS (
      SELECT b.PATID,
             CASE WHEN b.DEATH_DT IS NOT NULL AND b.DEATH_DT < i.INDEX_DATE
                  THEN i.INDEX_DATE ELSE b.DEATH_DT END AS DEATH_DT
      FROM idx i
      INNER JOIN {NDMM_BASE_COHORT} b ON b.PATID = i.PATID
    )
    SELECT i.PATID,
           i.INDEX_DATE,
           least({se}, coalesce(dd.DEATH_DT, {se}))                   AS ENDDATE,
           least({se}, coalesce(dd.DEATH_DT, {se}),
                 coalesce(ce.ENDDATE_CE, {se}))                       AS ENDDATE_CE,
           dd.DEATH_DT,
           d.GDR_CD,
           d.YRDOB,
           (year(i.INDEX_DATE) - d.YRDOB)                             AS AGE_INDEX_YR,
           datediff(least({se}, coalesce(dd.DEATH_DT, {se})),
                    date_add(i.INDEX_DATE, 1)) + 1                    AS FU_DAYS,
           datediff(least({se}, coalesce(dd.DEATH_DT, {se}),
                          coalesce(ce.ENDDATE_CE, {se})),
                    date_add(i.INDEX_DATE, 1)) + 1                    AS FU_DAYS_CE
    FROM idx i
    LEFT JOIN dem d  ON d.PATID  = i.PATID
    LEFT JOIN dth dd ON dd.PATID = i.PATID
    LEFT JOIN ce     ON ce.PATID = i.PATID"),
    qc = glue("SELECT count(*) AS n_rows, count(DISTINCT PATID) AS n_patients ",
              "FROM {wrk('NDMM_COHORT')}"))
  invisible(TRUE)
}

# The table that gets handed on, checked before anything reads it. One row per
# patient, because a cohort with a duplicated PATID fans out every join a LOT
# build makes over it; the same count the attrition published, because a cohort
# that disagrees with its own funnel is not a cohort; and every column that
# build needs, so a missing one is named here rather than at the far end.
check_ndmm_cohort <- function(con, cfg, n_expected) {
  tbl  <- wrk("NDMM_COHORT")
  d    <- db_q(con, glue("DESCRIBE {tbl}"))
  cn   <- intersect(c("col_name", "COL_NAME", "name", "NAME"), names(d))
  cols <- if (length(cn)) toupper(trimws(as.character(d[[cn[1]]]))) else character(0)
  miss <- setdiff(NDMM_COHORT_COLS, cols)
  if (length(miss))
    stop(tbl, " is missing ", paste(miss, collapse = ", "),
         ".\nIt is written to be a cohort the lot build can be pointed at, and ",
         "that build reads these columns off whatever cohort it is given.",
         call. = FALSE)
  q <- db_q(con, glue("SELECT count(*) AS n_rows, count(DISTINCT PATID) AS n_pat, ",
                      "sum(CASE WHEN INDEX_DATE IS NULL THEN 1 ELSE 0 END) AS n_noidx, ",
                      "sum(CASE WHEN ENDDATE < INDEX_DATE THEN 1 ELSE 0 END) AS n_backwards, ",
                      "sum(CASE WHEN FU_DAYS < {NDMM_FU_CE_DAYS} THEN 1 ELSE 0 END) AS n_nofu ",
                      "FROM {tbl}"))
  if (q$n_rows != q$n_pat)
    stop(tbl, " has ", q$n_rows, " rows for ", q$n_pat, " patients. A cohort ",
         "with a repeated PATID fans out every join made over it.", call. = FALSE)
  if (isTRUE(q$n_noidx > 0))
    stop(q$n_noidx, " rows in ", tbl, " have no INDEX_DATE. It is the 1L start, ",
         "and every window a LOT build measures runs from it.", call. = FALSE)
  # Death dates are imputed - a month-only date becomes the 15th, a year-only
  # one July 15 - and the cohort is anchored at the 1L start, which is later
  # than the diagnosis they were imputed against. A death that lands between
  # the two would end follow-up before it began.
  if (isTRUE(q$n_backwards > 0))
    stop(q$n_backwards, " rows in ", tbl, " end before they begin: ENDDATE is ",
         "earlier than INDEX_DATE. Death is imputed against the diagnosis and ",
         "the index is the 1L start, so a partial death date between the two ",
         "does this. build_ndmm_cohort_table() re-clamps it at the index; if ",
         "this fires, that clamp is not working.", call. = FALSE)
  # The floor is NDMM_FU_CE_DAYS, not 1. FU_DAYS counts days after the index,
  # and criterion 5 requires enrolment through index + NDMM_FU_CE_DAYS, so a
  # patient who passes it has at least that many. Hard-coding 1 contradicted
  # the one-day rule: with FU_CE_DAYS = 0 the index date alone is enough
  # follow-up, but a patient whose ENDDATE lands on the index - death clamped
  # there, or an index on the study end - has FU_DAYS = 0 and stopped the run
  # after passing every criterion.
  if (isTRUE(q$n_nofu > 0))
    stop(q$n_nofu, " rows in ", tbl, " have less follow-up than criterion 5 ",
         "requires (FU_DAYS < ", NDMM_FU_CE_DAYS, "). A LOT run over this ",
         "cohort would measure lines in a window that does not exist.",
         call. = FALSE)
  if (!is.na(n_expected) && q$n_pat != n_expected)
    stop(tbl, " holds ", q$n_pat, " patients but the attrition ends at ",
         n_expected, ". The cohort and the funnel that reaches it must agree.",
         call. = FALSE)
  log_msg("  ", tbl, ": ", q$n_pat, " patients, indexed at the 1L start")
  invisible(TRUE)
}

CODELIST_METADATA_COLS <- c(RUN_ID = "STRING", CSV_NAME = "STRING",
                            MD5 = "STRING", N_ROWS = "BIGINT",
                            RECORDED_AT = "TIMESTAMP")

# load_codelist_csv() hashes every CSV it reads, because the code lists live
# outside version control and the file name alone does not say which version a run used.
# Those hashes were being collected into an option and then dropped. Written
# here, so the outputs say which code lists built them.
write_codelist_metadata <- function(con, cfg) {
  seen <- getOption("nndm_codelist_md5", list())
  # All of them, not merely some. "None recorded" was the only thing this
  # stopped on, so a run that read three of the four would have published a
  # cohort traceable to three.
  miss <- setdiff(CODELIST_FILES, names(seen))
  if (length(miss))
    stop("No hash recorded for ", paste(miss, collapse = ", "),
         ". Every run reads all ", length(CODELIST_FILES), " code lists, and a ",
         "cohort that cannot be traced to each of them is not reproducible.",
         call. = FALSE)
  bad <- names(seen)[!vapply(seen, function(x)
    is.character(x$md5) && grepl("^[0-9a-f]{32}$", x$md5), logical(1))]
  if (length(bad))
    stop("Hash not usable for ", paste(bad, collapse = ", "),
         ". It is what says which version of the file was read.", call. = FALSE)
  tbl  <- wrk("NDMM_CODELIST_METADATA")
  cols <- names(CODELIST_METADATA_COLS)
  db_exec(con, glue("CREATE TABLE IF NOT EXISTS {tbl} (",
                    paste(cols, CODELIST_METADATA_COLS, collapse = ", "), ")"))
  vals <- vapply(names(seen), function(nm)
    glue("('{run_id}', {sql_text(nm)}, {sql_text(seen[[nm]]$md5)}, ",
         "{sql_count(seen[[nm]]$n_rows)}, current_timestamp())"),
    character(1), USE.NAMES = FALSE)
  db_replace(con,
    glue("DELETE FROM {tbl} WHERE RUN_ID = '{run_id}'"),
    glue("INSERT INTO {tbl} ({paste(cols, collapse = ', ')}) VALUES ",
         paste(vals, collapse = ", ")))
  log_msg("Codelist versions written to ", tbl, " (", length(seen), ")")
  invisible(TRUE)
}

BUILD_STATUS_COLS <- c(RUN_ID = "STRING", OBJECT_PREFIX = "STRING",
                       STATE = "STRING", N_NDMM = "BIGINT",
                       UPDATED_AT = "TIMESTAMP")

write_build_status <- function(con, cfg, state, n = NA) {
  tbl <- wrk("NDMM_BUILD_STATUS")
  cols <- names(BUILD_STATUS_COLS)
  db_exec(con, glue("CREATE TABLE IF NOT EXISTS {tbl} (",
                    paste(cols, BUILD_STATUS_COLS, collapse = ", "), ")"))
  db_replace(con,
    glue("DELETE FROM {tbl} WHERE RUN_ID = '{run_id}'"),
    glue("INSERT INTO {tbl} ({paste(cols, collapse = ', ')}) VALUES (",
         "'{run_id}', '{cfg$object_prefix}', '{state}', {sql_count(n)}, ",
         "current_timestamp())"))
  log_msg("Build status: ", state, " (run ", run_id, ")")
  invisible(TRUE)
}

# Every output name is work schema + prefix + table, with no run id in it - see
# wrk(). checkpoint() then repoints each session view at the prefixed table it
# has just replaced, so from that moment a run reads its own intermediate
# results out of shared storage: NDMM_BASE_COHORT is literally
# "SELECT * FROM <schema>.<prefix>NDMM_BASE_COHORT". Two runs on one prefix
# therefore interleave. The second replaces a table the first has already
# pointed a view at, and the first reads the second's rows from there on -
# through fourteen checkpoints and five deliverables. Both can still reach
# "complete", each having published a cohort that is partly the other's.
#
# Different prefixes are safe, and that is how two cohorts are meant to run at
# once. This refuses the same-prefix case.
#
# A check, not a lock: two runs starting in the same moment can both pass it,
# because there is nothing here that could hold a lock. It catches the case
# worth catching - starting a second run while one is going - and says so.
# Claims whose ICD_FLAG names neither family - restricted to the ones that could
# matter. icd_family_sql() yields NULL for an unrecognised flag, so such a claim
# now matches no code list entry instead of being mis-classed as ICD-10. That is
# the safe direction, but it is still silent: this is what makes it visible.
#
# Relevant means the normalised code is on one of the three diagnosis lists, or
# on the pregnancy procedure list. The CDM is full of claims this cohort never
# reads, and a malformed flag on one of those is not this build's problem.
#
# Waivable like the NDC shape checks and for the same reason - the values are
# the CDM's and cannot be corrected here. A waiver accepts that those rows match
# nothing. It does not reclassify them: putting the ICD-10 guess back would
# suppress the report and keep the error, which is the opposite of a decision.
check_icd_flag <- function(con, cfg) {
  fam <- icd_family_sql("t.ICD_FLAG")
  probe <- function(tbl, code_col, lists) glue("
    SELECT concat_ws(', ', collect_set(
             coalesce(nullif(trim(t.ICD_FLAG), ''), '<blank>'))) AS vals,
           count(*) AS n
    FROM {tbl} t
    WHERE ({fam}) IS NULL
      AND upper(regexp_replace(t.{code_col}, '[^A-Za-z0-9]', '')) IN (
        SELECT code FROM ({lists}))")
  dx_lists <- glue("
        SELECT dx AS code FROM {NDMM_MM_DX_CODES}
        UNION SELECT dx FROM {NDMM_OTHER_MALIG_CODES}
        UNION SELECT code FROM {NDMM_PREG_CODES} WHERE code_type LIKE '%DIAG'
        UNION SELECT code FROM {NDMM_CLINTRIAL_CODES} WHERE code_type LIKE '%DIAG'")
  pr_lists <- glue("
        SELECT code FROM {NDMM_PREG_CODES} WHERE code_type LIKE '%PROC'
        UNION SELECT code FROM {NDMM_CLINTRIAL_CODES} WHERE code_type LIKE '%PROC'")
  found <- character(0)
  for (p in list(list(t = cdm_src(cfg$tbl_med_diag), c = "DIAG", l = dx_lists),
                 list(t = cdm_src(cfg$tbl_med_proc), c = "PROC", l = pr_lists))) {
    r <- db_q(con, probe(p$t, p$c, p$l))
    n <- suppressWarnings(as.integer(r$n))
    if (length(n) == 1L && !is.na(n) && n > 0)
      found <- c(found, paste0(p$t, ": ", format(n, big.mark = ","),
                               " row(s), ICD_FLAG in {", r$vals, "}"))
  }
  if (!length(found)) {
    log_msg("  ICD_FLAG: every claim carrying a code this cohort reads names a family")
    return(invisible(FALSE))
  }
  msg <- paste0("Claims carrying a code this cohort reads, whose ICD_FLAG names ",
                "neither ICD-9 nor ICD-10:\n  ", paste(found, collapse = "\n  "),
                "\nThose rows match no code list entry, so an MM diagnosis is ",
                "missed, or an other-cancer or pregnancy claim stops excluding ",
                "the patient it should. Profile the values and decide. To accept ",
                "that they match nothing, set NDMM_WAIVERS=raw_icd_flag - they ",
                "stay unmatched; nothing reclassifies them.")
  if (!("raw_icd_flag" %in% waivers())) stop(msg, call. = FALSE)
  log_msg("WAIVED (raw_icd_flag): ", paste(found, collapse = "; "))
  options(nndm_waivers_applied = union(getOption("nndm_waivers_applied",
                                                 character(0)), "raw_icd_flag"))
  invisible(TRUE)
}


check_no_active_run <- function(con, cfg) {
  d <- tryCatch(db_q(con, glue("
    SELECT RUN_ID, UPDATED_AT FROM {wrk('NDMM_BUILD_STATUS')}
    WHERE OBJECT_PREFIX = '{cfg$object_prefix}' AND STATE = 'started'
      AND RUN_ID <> '{run_id}'")), error = function(e) NULL)
  # No table yet on a first run, and nothing to collide with.
  if (is.null(d) || !nrow(d)) return(invisible(TRUE))
  # When each started, so the operator can tell a run that is going from one a
  # killed process left behind months ago.
  who <- paste(paste0(d$RUN_ID, " (started ", d$UPDATED_AT, ")"), collapse = ", ")
  if (identical(toupper(Sys.getenv("NDMM_IGNORE_ACTIVE_RUN", unset = "")), "TRUE")) {
    log_msg("WARNING: run(s) ", who, " are marked started on prefix ",
            cfg$object_prefix, " and NDMM_IGNORE_ACTIVE_RUN is set. If they ",
            "are still running, both cohorts will be wrong.")
    return(invisible(TRUE))
  }
  stop("Run(s) ", who, " are already building prefix ", cfg$object_prefix,
       ". Every output name is the prefix plus the table, so two runs would ",
       "replace each other's tables while the other is reading them, and both ",
       "could still finish. Use a different prefix, or wait. If those runs are ",
       "not actually running - a killed process leaves 'started' behind - set ",
       "NDMM_IGNORE_ACTIVE_RUN=TRUE.", call. = FALSE)
}

# A re-run in the same session keeps run_id - it is fixed when config.R is
# sourced, and DOMINO_RUN_ID pins it across sessions besides - so a second
# attempt writes under the first attempt's id. Each writer clears its own rows,
# but only when it is reached: an attempt that fails before write_run_metadata
# leaves the first attempt's row saying which code and which code lists built
# this cohort, which by then they did not. That is the one claim these tables
# exist to make, and NDMM_BUILD_STATUS marking the run failed does not unmake
# it - the rows are still there, under an id that now means something else.
# Cleared up front instead, so nothing under this run's id describes work this
# run did not do.
#
# NDMM_BUILD_STATUS is deliberately not here. Its row for this run is written
# immediately before this runs, so nothing stale can survive in it, and
# clearing it would delete the "started" row check_no_active_run shows to the
# next run - turning the concurrency check off for exactly as long as the build
# takes. NDMM_COHORT is not here either: it is replaced whole, not appended to.
#
# The tables need not exist yet, and on a first run they do not, so a delete
# that cannot find its table is not a failure. TABLE_OR_VIEW_NOT_FOUND is one
# of with_retry's permanent errors, so this does not sit through four attempts.
# Anything else is said out loud rather than swallowed: a DELETE that was
# refused leaves exactly the rows this exists to remove, and a silent try()
# would let the run publish them as its own.
RUN_SCOPED_TABLES <- c("NDMM_ATTRITION", "NDMM_RUN_METADATA",
                       "NDMM_CODELIST_METADATA")

clear_run_rows <- function(con, cfg) {
  bad <- character(0)
  for (t in RUN_SCOPED_TABLES) {
    tbl <- wrk(t)
    err <- tryCatch({
      db_exec(con, glue("DELETE FROM {tbl} WHERE RUN_ID = '{run_id}'")); NULL
    }, error = function(e) conditionMessage(e))
    # A table that is not there yet is the first run on this prefix. There is
    # nothing under this run id to leave behind, so it is not a failure.
    if (!is.null(err) &&
        !grepl("TABLE_OR_VIEW_NOT_FOUND|Table or view not found", err,
               ignore.case = TRUE))
      bad <- c(bad, paste0(tbl, ": ", err))
  }
  # All of them, then stop once: a permission or a lock that stopped one delete
  # has usually stopped the others, and naming one at a time would take three
  # runs to find out.
  if (length(bad))
    stop("Could not clear run ", run_id, " from:\n  ",
         paste(bad, collapse = "\n  "),
         "\nA re-run keeps its run id, so rows an earlier attempt wrote under ",
         "it are still there. Each writer clears its own rows before it ",
         "writes, so a run that reaches all of them would republish correctly ",
         "- but one that stops before a writer leaves that attempt's rows ",
         "standing under this run's id, describing a cohort this run did not ",
         "build, and nothing downstream can tell them apart. Fix the ",
         "permission or the lock and start again.", call. = FALSE)
  invisible(TRUE)
}

load_nndm_modules <- function(here) {
  source(file.path(here, "R", "load_inputs.R"))
  load_pipeline_inputs(here, "config.csv")
  for (f in c("config.R", "db_utils.R", "codelists.R", "nndm_constants.R",
              "standalone_constants.R"))
    source(file.path(here, "R", f))
  for (f in sort(list.files(file.path(here, "R", "steps"), "\\.R$", full.names = TRUE)))
    source(f)
  invisible(TRUE)
}

build_nndm <- function(here, prefix) {
  check_settings()
  cfg <- pin_output_schema(cfg_defaults)
  cfg <- pin_prefix(cfg, prefix)
  check_contract(cfg)
  check_choices(cfg)
  check_constants(cfg)
  set_lot_config(cfg)

  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")
  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  log_msg(SEP)
  log_msg("NDMM 1L cohort - prefix ", cfg$object_prefix, " - run ", run_id)
  log_msg("  1L start on or after: ", cfg$lot1_from)
  log_msg("  Baseline / CE before index: ", cfg$pre_lot1_days, " days")
  log_msg("  Follow-up CE: ", cfg$fu_ce_days, " day(s) after index")
  log_msg(SEP)

  # First, and before this run writes anything at all: one query, against a
  # table check_upstream does not look at, and a refused run leaves the prefix
  # exactly as it found it. The query excludes this run's own id, so it would
  # give the same answer later - it just would not be true any more that
  # nothing had been written, nor that nothing had been waited for.
  check_no_active_run(con, cfg)
  check_upstream(con, cfg)
  write_build_status(con, cfg, "started")
  # Registered the moment the run is marked started, and before anything that
  # can stop - clear_run_rows() does. A stop between the two would leave the
  # status at "started" for ever, and check_no_active_run() would then refuse
  # every later run on this prefix until someone overrode it by hand.
  #
  # after = FALSE, or this fires after the disconnect above and writes to a
  # closed connection.
  on.exit(if (!isTRUE(getOption("nndm_complete", FALSE)))
            try(write_build_status(con, cfg, "failed"), silent = TRUE),
          add = TRUE, after = FALSE)
  options(nndm_complete = FALSE, nndm_codelist_md5 = list(),
          nndm_waivers_applied = character(0))
  # After the status row, so a run is marked started whatever this does, and
  # before the first step, so no writer can be reached with the previous
  # attempt's rows still under this run's id.
  clear_run_rows(con, cfg)

  log_msg("MM diagnosis over the study period, and who is old enough")
  build_ndmm_mm_dx_codes(con)
  checkpoint(con, "NDMM_MM_DX_CODES")
  build_ndmm_mm_claim_header(con, cdm_src(cfg$tbl_medical),
                             cdm_src(cfg$tbl_confinement))
  build_ndmm_mm_dx_events(con, cdm_src(cfg$tbl_med_diag))
  checkpoint(con, "NDMM_MM_DX_EVENTS")
  build_ndmm_mm_qualifying(con)
  checkpoint(con, "NDMM_MM_QUALIFYING")
  build_ndmm_demographics(con, cdm_src(cfg$tbl_member_elig), cdm_src(cfg$tbl_dod))
  build_ndmm_base_cohort(con)
  checkpoint(con, "NDMM_BASE_COHORT")

  log_msg("Enrollment spans (gap_days=", cfg$gap_days, ", and a no-gap set)")
  build_enrollment_spans_ndmm(con)
  build_enrollment_spans_ndmm(con, NDMM_ENROLL_SPANS_STRICT, 0L)
  checkpoint(con, "NDMM_ENROLL_SPANS")
  checkpoint(con, "NDMM_ENROLL_SPANS_STRICT")

  log_msg("MM therapy code list, and the belantamab rows of it")
  db_exec(con, build_ndmm_mma_codelist())
  checkpoint(con, "NDMM_MMA_CODELIST")
  check_ndc_shape(con, cfg)
  build_ndmm_belantamab_codes(con)
  checkpoint(con, "NDMM_BELANTAMAB_CODES")
  build_ndmm_index_ineligible_codes(con)
  checkpoint(con, "NDMM_INDEX_INELIGIBLE")

  log_msg("1L index: first eligible MM treatment claim on or after ",
          NDMM_LOT1_FROM)
  build_ndmm_lot1_index(con, cdm_src(cfg$tbl_medical), cdm_src(cfg$tbl_rx),
                        cdm_src(cfg$tbl_med_proc))
  checkpoint(con, "NDMM_INDEX_TX")
  checkpoint(con, "NDMM_LOT1_STARTS")
  build_ndmm_index_agents(con, cfg)

  log_msg("MM therapy in the ", NDMM_PRE_LOT1_DAYS, " days before 1L")
  build_ndmm_therapy_pre_lot1(con, cdm_src(cfg$tbl_medical), cdm_src(cfg$tbl_rx),
                              cdm_src(cfg$tbl_med_proc))

  log_msg("Other cancer in the ", NDMM_PRE_LOT1_DAYS, " days before 1L")
  build_ndmm_other_malig_codes(con)
  checkpoint(con, "NDMM_OTHER_MALIG_CODES")
  build_ndmm_mm_adjacent_groups(con, cfg)
  build_ndmm_mm_adjacent_codes(con, cfg)
  build_ndmm_other_malig_groups(con, cfg)
  build_ndmm_med_claim_header_and_confinement(con, cdm_src(cfg$tbl_medical),
                                              cdm_src(cfg$tbl_confinement))
  build_ndmm_other_malig_pre_lot1(con, cdm_src(cfg$tbl_med_diag))
  checkpoint(con, "NDMM_OTHER_MALIG_EVENTS")
  build_ndmm_other_malig_grain(con, cfg)

  log_msg("Pregnancy across the study period")
  build_ndmm_preg_codes(con)
  checkpoint(con, "NDMM_PREG_CODES")
  # Before the ICD-flag check, not with the flag build that uses it. The check
  # asks which claims carry a code this cohort reads but name no ICD family,
  # and trial codes are codes this cohort reads - a trial diagnosis or
  # procedure claim with a blank flag matches nothing and is missed silently,
  # which is the exact condition the check exists to surface. It only reads the
  # CSV, so it can be built here; the flag itself needs LOT1 and the base
  # cohort and stays where it is.
  build_ndmm_clintrial_codes(con)
  check_icd_flag(con, cfg)
  build_ndmm_pregnancy_patids(con, cdm_src(cfg$tbl_med_diag),
                              cdm_src(cfg$tbl_medical), cdm_src(cfg$tbl_med_proc))

  log_msg("Belantamab in any line, from claims")
  build_ndmm_belantamab_patids(con, cdm_src(cfg$tbl_medical), cdm_src(cfg$tbl_rx),
                               cdm_src(cfg$tbl_med_proc))
  checkpoint(con, "NDMM_BELANTAMAB_TX")
  checkpoint(con, "NDMM_BELANTAMAB_PATIDS")

  log_msg("Per-patient filter flags")
  # The flags step takes the cohort and the belantamab source as
  # parameters, so it needs no change: the base cohort answers for
  # ELIG_COH_FINAL (it carries PATID and DEATH_DT, which is all that step
  # reads), and the belantamab view answers in MAP_STACKED's shape.
  build_ndmm_flags(con, NDMM_BASE_COHORT, NDMM_BELANTAMAB_PATIDS,
                   TRUE, TRUE, TRUE, TRUE)
  checkpoint(con, "NDMM_PATIDS")

  # Descriptive, not a criterion - it is built after the flags and joins
  # nothing into them, so the cohort is the same with it as without.
  log_msg("Clinical-trial evidence around the 1L index")
  build_ndmm_clintrial_flags(con, cdm_src(cfg$tbl_med_diag),
                             cdm_src(cfg$tbl_medical), cdm_src(cfg$tbl_med_proc))
  checkpoint(con, "NDMM_CLINTRIAL_FLAGS")
  report_ndmm_clintrial(con)
  # After the flags: each scope is costed against the whole conjunction, so it
  # needs every other criterion already decided.
  build_ndmm_fu_ce_counts(con, cfg)
  # build_lot_long_filtered() is not called. It joins LOT_LONG to the cohort
  # for reporting views, and neither the cohort nor the attrition reads it.
  # Left in 07_cohort.R for anyone who wants it.

  counts <- ndmm_counts(con, NDMM_MM_QUALIFYING, NDMM_BASE_COHORT)
  for (i in seq_along(ATTRITION_STEPS))
    log_msg("  ", i, ". ", ATTRITION_STEPS[[i]]$label, ": ",
            format(counts[[ATTRITION_STEPS[[i]]$key]], big.mark = ","))
  # Before it is written, so a fanned-out funnel is not published as a count.
  check_attrition_monotonic(counts)

  build_ndmm_cohort_table(con, cfg)
  check_ndmm_cohort(con, cfg, ndmm_final_count(counts))
  build_ndmm_belantamab_reconcile(con, cfg)
  write_attrition(con, cfg, counts)
  write_codelist_metadata(con, cfg)
  write_run_metadata(con, cfg, here, ndmm_final_count(counts))

  write_build_status(con, cfg, "complete", ndmm_final_count(counts))
  options(nndm_complete = TRUE)
  log_msg(SEP)
  log_msg("NDMM 1L cohort: ", format(ndmm_final_count(counts), big.mark = ","),
          " patients -> ", wrk("NDMM_COHORT"))
  # After the count, because which of these were supplied is part of reading it.
  log_msg(SEP)
  invisible(counts)
}
