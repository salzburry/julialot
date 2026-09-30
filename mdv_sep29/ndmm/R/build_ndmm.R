# Runner for the NDMM (1L newly-diagnosed) cohort, built from MDV. Standalone:
# one module, pointed at a cohort prefix.
#
# This is the Optum cohort build with its extraction rewritten for MDV (see
# ../MDV_RULES.md). The runner's machinery - the contract, the checks before
# anything is written, the attrition, the status and metadata tables - is the
# Optum build's, so a reader of one can read the other.
#
# R/steps holds the rules; this file is the runner around them. It stops when
# an input is missing rather than skipping the filter that needed it - a count
# nobody can reproduce is worse than no count.

`%||%` <- function(a, b) if (is.null(a)) b else a

# Settings that decide what the cohort means. A different value here is a
# different cohort, so they are checked rather than defaulted.
CONTRACT <- list(
  catalog              = "hive_metastore",
  cdm_schema           = "clnprw_mdv_all_use",
  codelist_dir         = "/mnt/code/codelist_mdv",
  use_quarterly_tables = TRUE,
  # The MDV extract, named apart from the study window: MDV's quarter and the
  # study's end need not be the same quarter.
  mdv_vintage          = "2026q2",
  study_end            = "2026-03-31",
  # Earliest date an eligible 1L treatment can count.
  lot1_from            = "2019-01-01",
  # 12 months of lookback and of baseline before the 1L index date.
  pre_lot1_days        = 365L,
  # Days after index the patient must still be observed. Zero is the index
  # date itself - one day - which the study team confirmed for 1L.
  fu_ce_days           = 0L,
  # The pregnancy scan runs over [study_start, study_end], so this moves who is
  # excluded. It reaches the SQL through NDMM_STUDY_START.
  study_start          = "2018-01-01",
  # The Optum rule's 90 and 30 days, at the month grain MDV dates a diagnosis
  # to, and the minimum age at the diagnosis.
  outpatient_window_months  = 3L,
  other_malig_window_months = 1L,
  min_age              = 18L,
  belantamab_abbr      = "BELA"
)

# Decisions a run may make differently, and what each may be set to.
#
# CONTRACT is what the cohort IS, so those are rejected. These are the open
# choices, and the build writes a review table for each.
#
# Still guarded: each is checked against its allowed values, and all go into
# NDMM_RUN_METADATA, so a cohort says which choices made it.
CHOICES <- list(
  mm_adjacent_states   = c("override", "exclude", "mgus_only", "none"),
  # What makes an MDV diagnosis inpatient for criterion 1, and whether MDV's
  # cancer flag is required. Open MDV readings, each priced in
  # NDMM_MM_DX_RULES on every run.
  mdv_ip_rule          = c("none", "ff1", "ff1_chemo"),
  mdv_require_cancerflg = c("TRUE", "FALSE"),
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

# A temporary view is a query, not a result - Spark re-runs it on every read.
# These stack, so the thirteen reads of NDMM_LOT1_STARTS would each re-run the
# whole MM-diagnosis chain under it. Writing each to the work schema once and
# repointing the view makes every later read a table scan. Steps still name
# the view.
#
# tests/test_runner.R counts reads and fails if anything read twice is missing
# here. It cannot see BASE_COHORT or BELANTAMAB_PATIDS, which arrive as
# parameters.
#
# NDMM_FLAGS_ALL is checkpointed inside 06_flags.R instead: NDMM_PATIDS is
# defined over it there, and repointing after would leave that view on the old
# query.
CHECKPOINTS <- c("NDMM_FLAGS_ALL", "NDMM_CLINTRIAL_FLAGS", "NDMM_MM_DX_CODES",
                 "NDMM_MM_DX_EVENTS", "NDMM_MM_QUALIFYING", "NDMM_BASE_COHORT",
                 "NDMM_OBS_PERIOD",
                 "NDMM_MMA_CODELIST", "NDMM_MMA_RECEIPTS", "NDMM_MM_TX",
                 "NDMM_BELANTAMAB_CODES", "NDMM_LOT1_STARTS",
                 "NDMM_OTHER_MALIG_CODES", "NDMM_OTHER_MALIG_EVENTS",
                 "NDMM_PREG_CODES", "NDMM_PREGNANCY_EVENTS",
                 "NDMM_CLINTRIAL_CODES",
                 "NDMM_BELANTAMAB_PATIDS",
                 "NDMM_INDEX_TX", "NDMM_BELANTAMAB_TX", "NDMM_PATIDS",
                 "NDMM_INDEX_INELIGIBLE")

# The two staged MDV sources (R/mdv_source.R), read by several steps and left
# as views on purpose. Each is the whole warehouse table - every patient's
# diagnoses, every inpatient episode - and each reader filters it its own way,
# so a checkpoint would copy the table to read a sliver of it; Spark pushes
# each reader's filter into the scan instead. Everything built from them is
# checkpointed as usual.
SOURCE_VIEWS <- c("NDMM_DX", "NDMM_FF1")

# What the run writes. All prefixed, so two cohorts sit side by side.
DELIVERABLES <- c("NDMM_COHORT", "NDMM_ATTRITION", "NDMM_INDEX_AGENTS",
                  "NDMM_MM_DX_RULES", "NDMM_MDV_SOURCE_PROFILE",
                  "NDMM_MM_ADJACENT_GROUPS",
                  "NDMM_MM_ADJACENT_CODES", "NDMM_FU_CE_COUNTS",
                  "NDMM_OTHER_MALIG_GROUPS", "NDMM_OTHER_MALIG_GRAIN",
                  "NDMM_PREG_WINDOW_COUNTS",
                  "NDMM_OTHER_MALIG_CODES",
                  "NDMM_BELANTAMAB_RECONCILE",
                  "NDMM_CODELIST_METADATA", "NDMM_RUN_METADATA",
                  "NDMM_BUILD_STATUS")
OUTPUTS <- c(DELIVERABLES, CHECKPOINTS)

# Conditions the study team can accept for a given data set. Nothing else can
# be waived, and a waiver naming something not here is a typo, not a decision.
#
# One, on MDV: mdv_values, the value-code profile (check_mdv_values()). It
# stops a run whose MM diagnoses carry no inpatient, outpatient, confirmed or
# cancer value at all - the sign that a code in config.csv is not the one this
# delivery uses - and a study team that has looked at the profile and knows the
# subset really has none can say so. The Optum build's NDC and ICD_FLAG
# conditions have nothing to be about here.
WAIVABLE_CHECKS <- c("mdv_values")

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
# No fallback. Degrading to the in-place view on a write failure is correct
# arithmetic but can turn minutes into hours without saying so, and a table
# this build declares as an output would then not be there.
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
  # NDMM_LOT1_FROM is not a setting: ndmm_constants.R reads LOT1_FROM like
  # everything else. A run that exports it would silently get the config's
  # value instead of the one it meant, so it is refused rather than ignored.
  old_l1 <- trimws(Sys.getenv("NDMM_LOT1_FROM", unset = ""))
  if (nzchar(old_l1))
    bad <- c(bad, paste0("NDMM_LOT1_FROM='", old_l1, "' is not a setting - ",
                         "the 1L index floor is LOT1_FROM, in config.csv or ",
                         "the environment, and it reaches the SQL. Unset ",
                         "NDMM_LOT1_FROM and set LOT1_FROM."))
  for (v in c("STUDY_END", "LOT1_FROM", "STUDY_START")) {
    x <- trimws(Sys.getenv(v, unset = ""))
    if (nzchar(x) && !grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", x))
      bad <- c(bad, paste0(v, "='", x, "' (want YYYY-MM-DD)"))
  }
  # Empty means no ceiling, which is the default. A value has to be a
  # whole number, because "500 rows" or "5e2" would silently become something
  # else and the ceiling is the whole point of setting it.
  # Every whole-number setting that reaches the cohort. config.R and the
  # constants coerce them with as.integer(), so MIN_AGE=18.5 would become 18L,
  # match CONTRACT$min_age and check_constants(), and filter at 18 while the
  # operator had asked for 18.5 - with nothing recorded to say so.
  for (v in c("PRE_LOT1_DAYS", "FU_CE_DAYS", "OUTPATIENT_WINDOW_MONTHS",
              "OTHER_MALIG_WINDOW_MONTHS", "MIN_AGE")) {
    x <- trimws(Sys.getenv(v, unset = ""))
    # The text, not what coercion makes of it: as.integer("60.5") is 60.
    if (nzchar(x) && !grepl("^[0-9]+$", x))
      bad <- c(bad, paste0(v, "='", x, "' (want a whole number)"))
  }
  r <- Sys.getenv("DOMINO_RUN_ID", unset = "")
  if (nzchar(r) && !grepl("^[A-Za-z0-9_.-]+$", r))
    bad <- c(bad, paste0("DOMINO_RUN_ID='", r, "' (want letters, digits, _ . -)"))
  # Read as.logical() in config.R, so a typo would become NA and read as FALSE.
  for (v in c("USE_QUARTERLY_TABLES", "NDMM_MDV_REQUIRE_CANCERFLG")) {
    x <- trimws(Sys.getenv(v, unset = ""))
    if (nzchar(x) && !(toupper(x) %in% c("TRUE", "FALSE")))
      bad <- c(bad, paste0(v, "='", x, "' (want TRUE or FALSE)"))
  }
  # The vintage picks every table this build reads.
  x <- trimws(Sys.getenv("MDV_VINTAGE", unset = ""))
  if (nzchar(x) && !grepl("^[0-9]{4}[qQ][1-4]$", x))
    bad <- c(bad, paste0("MDV_VINTAGE='", x, "' (want a quarter, e.g. 2026q2, ",
                         "or blank to derive it from STUDY_END)"))
  # Optum names that no longer mean anything here, refused rather than ignored,
  # so a command carried over from the Optum build does not look as though it
  # set something.
  for (v in c("OPTUM_CDM_SCHEMA", "OUTPATIENT_WINDOW", "GAP_DAYS",
              "TBL_CONFINEMENT", "TBL_MEMBER_ENROLLMENT", "TBL_MEMBER_ELIG",
              "TBL_DOD", "NDMM_ICD_FLAG_MAX_ROWS")) {
    x <- trimws(Sys.getenv(v, unset = ""))
    if (nzchar(x))
      bad <- c(bad, paste0(v, "='", x, "' is an Optum setting and this build ",
                           "reads MDV; see ndmm/config.csv for the ",
                           "MDV names"))
  }
  # The MDV table names, column names and value codes, which go straight
  # into SQL.
  bad <- c(bad, check_mdv_settings())
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

# A cohort built to different windows is a different cohort, and it is
# refused. NDMM_CONTRACT_OVERRIDE is the one way past, and it exists so that
# moving the study window is an edit to config.csv and one acknowledgement -
# not an edit to this file. Before it, CONTRACT was the only place a date
# could be changed, so a sensitivity run meant editing bundled R, and the
# cohort's own definition and the run's settings drifted by hand.
#
# A deviating run cannot pass for the study's: the deviations go into
# NDMM_BUILD_STATUS.FINDINGS and NDMM_RUN_METADATA.FINDINGS, CONTRACT_SETTINGS
# records what the run used rather than what CONTRACT pins, and a study
# package reading the cohort compares its own window against that column and
# refuses a disagreement.
#
# Same shape and the same bargain as LOT_CONTRACT_OVERRIDE in
# lot/engine/R/build_lot.R. Unset, which is every production run, nothing here
# changes.
check_contract <- function(cfg) {
  options(ndmm_contract_deviations = character(0))
  wrong <- unlist(Filter(Negate(is.null), lapply(names(CONTRACT), function(k) {
    if (isTRUE(all.equal(cfg[[k]], CONTRACT[[k]]))) NULL
    else paste0(k, " = ", format(cfg[[k]]), " (want ", format(CONTRACT[[k]]), ")")
  })))
  if (length(wrong)) {
    if (!identical(toupper(trimws(Sys.getenv("NDMM_CONTRACT_OVERRIDE", unset = ""))),
                   "TRUE"))
      stop("This cohort is defined as:\n  ", paste(wrong, collapse = "\n  "),
           "\nA different value is a different cohort, not a setting. Change it ",
           "in config.csv (or the environment) and set ",
           "NDMM_CONTRACT_OVERRIDE=TRUE to say you meant to: the deviations ",
           "are then recorded against the run, CONTRACT_SETTINGS carries what ",
           "the run used, and the study package refuses a window that does ",
           "not match this cohort's.", call. = FALSE)
    options(ndmm_contract_deviations = wrong)
    log_msg("WARNING: NDMM_CONTRACT_OVERRIDE is set. This is NOT the contract ",
            "cohort:\n  ", paste(wrong, collapse = "\n  "))
    log_msg("  Recorded against this run in NDMM_BUILD_STATUS.FINDINGS and ",
            "NDMM_RUN_METADATA. Downstream packages read CONTRACT_SETTINGS, ",
            "so they will hold the study to these values and not the ",
            "contract's.")
  }
  invisible(TRUE)
}

# Every MDV table a step reads, and every column it reads off each: a name
# wrong for this delivery stops here, by name, rather than inside a step.
# DESCRIBE rather than a SELECT, so the check scans nothing.
raw_tables <- function(cfg) unname(vapply(names(MDV_TABLES), mdv_tbl, character(1),
                                          cfg = cfg))

# Every input table, before any work. A filter whose inputs could not be read
# would otherwise be skipped, producing a cohort smaller than it should be with
# nothing in the output saying so. This build reads raw MDV and its own code
# lists and nothing built by another package, which is what lets it run on its
# own.
check_upstream <- function(con, cfg) {
  missing <- character(0)
  raw <- raw_tables(cfg)
  for (t in raw) {
    got <- tryCatch({ db_q(con, glue("SELECT 1 FROM {t} LIMIT 1")); TRUE },
                    error = function(e) FALSE)
    if (!got) missing <- c(missing, t)
  }
  if (length(missing))
    stop("Cannot read:\n  ", paste(missing, collapse = "\n  "),
         "\nEvery NDMM filter needs its input. Skipping one would drop patients ",
         "the criteria do not exclude, and the attrition would not say so.",
         call. = FALSE)
  cols <- check_mdv_columns(con)
  if (length(cols))
    stop("The MDV columns this build reads are not all there:\n  ",
         paste(cols, collapse = "\n  "),
         "\nThe names are MDV_COL_* in config.csv. The ones marked (confirm) ",
         "in R/mdv_source.R were not in the OC business rules and have to be ",
         "checked against the MDV data dictionary; set each to this ",
         "delivery's name.", call. = FALSE)
  log_msg("Inputs present (", length(raw), " MDV tables, every column read)")
  invisible(TRUE)
}

# The SQL does not read cfg. It reads the NDMM_* constants in
# ndmm_constants.R, which carries its own environment variables -
# NDMM_LOT1_FROM among them. So a contract checked against cfg proves nothing
# about the query that runs. This compares the constants themselves, after the
# modules are loaded, and is the only check that speaks for the SQL.
CONSTANT_SETTINGS <- list(
  list(const = "NDMM_LOT1_FROM",     cfg = "lot1_from",
       note = "both set by LOT1_FROM"),
  list(const = "NDMM_PRE_LOT1_DAYS", cfg = "pre_lot1_days", note = ""),
  list(const = "NDMM_FU_CE_DAYS",    cfg = "fu_ce_days",    note = ""),
  list(const = "NDMM_STUDY_START",   cfg = "study_start",
       note = "set by STUDY_START"),
  list(const = "NDMM_OUTPATIENT_WINDOW_MONTHS",  cfg = "outpatient_window_months",  note = ""),
  list(const = "NDMM_OTHER_MALIG_WINDOW_MONTHS", cfg = "other_malig_window_months", note = ""),
  list(const = "NDMM_MIN_AGE",                 cfg = "min_age",            note = ""),
  # Which agents may not set the index. Empty by default; a value here shrinks
  # the cohort, so it is pinned like any other thing that does. The run choices
  # are here too: the SQL reads the constants, so the value cfg was checked for
  # has to be the value the query gets.
  list(const = "NDMM_INDEX_EXCLUDED_ABBRS",   cfg = "index_excluded_abbrs", note = ""),
  list(const = "NDMM_INDEX_EXCLUDED_CODES",   cfg = "index_excluded_codes", note = ""),
  list(const = "NDMM_MM_ADJACENT_STATES",     cfg = "mm_adjacent_states", note = ""),
  list(const = "NDMM_MDV_IP_RULE",            cfg = "mdv_ip_rule",        note = ""),
  list(const = "NDMM_MDV_REQUIRE_CANCERFLG",  cfg = "mdv_require_cancerflg", note = ""),
  # Not a cohort window but a code-list assumption, and just as able to change
  # the count: it is what identifies belantamab, and belantamab is exclusion 4.
  list(const = "NDMM_BELANTAMAB_ABBR",        cfg = "belantamab_abbr",    note = "")
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
# One list, three readers: NDMM_PATIDS ANDs the whole set, ndmm_counts() walks
# a prefix per funnel row, ATTRITION_STEPS takes the labels. Spelled out three
# times they would drift, and a flag added to the view alone would shift the
# funnel's last row under a label naming another criterion.
NDMM_CRITERIA <- list(
  list(key = "ce12",           flag = "CE_pre_lot1_12mo",
       label = "+ 12 months of MDV records before index"),
  list(key = "ce12_fuce",      flag = "CE_lot1_fu",
       label = "+ observed during follow-up"),
  list(key = "fuce_nopriortx", flag = "NO_PRIOR_MM_TX",
       label = "+ no MM oncology therapy in 12-month baseline"),
  list(key = "noother",        flag = "NO_OTHER_CANCER_PRE_LOT1",
       label = "+ no other cancer in 12-month baseline"),
  list(key = "noother_nopreg", flag = "NO_PREGNANCY",
       label = "+ no pregnancy in study period"),
  list(key = "nopreg_nobela",  flag = "NO_BELANTAMAB_PRE_LOT1",
       label = "+ no belantamab before the 1L index")
)
# The belantamab exclusion - "in any LOT" - is split, because no one package
# can see the whole of it.
#
# This half is belantamab before the 1L index. lot cannot see it - map_stacked
# starts at INDEX_DATE, so earlier treatment is not in what it reads. The other
# half is the no_belantamab line criterion in lot, from the index onward.
#
# It overlaps NO_PRIOR_MM_TX on purpose: that already removes MM therapy in the
# 12-month baseline, belantamab included, so what this drops on top is the
# patients whose belantamab predates the baseline. DECISIONS.md #2.
#
# NO_BELANTAMAB, the whole-study-period flag, is advisory - nothing filters on
# it.

# The first n criteria as a WHERE body, in the funnel's order.
#
#   All of them          the cohort itself, which is what NDMM_PATIDS asks for
#   a prefix (n)         one row of the funnel, which is what ndmm_counts() asks
#   one dropped (except) a sensitivity report, which recomputes that criterion
#                        its own way and ANDs the rest - so the row it prints is
#                        a cohort size and not one criterion's count
#
# alias qualifies the columns where flags arrive through a join. except is
# checked, not filtered - a mistyped flag would leave the criterion in, and the
# report would call the cohort bigger than it is.
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

# CREATE TABLE IF NOT EXISTS does nothing to a table an earlier run left, so a
# column added to a *_COLS list reaches a fresh prefix and no other, and the
# INSERT naming it fails at the end of the run. Each table is created and then
# brought up to its column list.
#
# Look before adding - ADD COLUMNS on a column that exists is an error. The
# table was created two statements ago, so a DESCRIBE that fails is a real
# fault and stops with its own message rather than deferring to the INSERT.
ensure_cols <- function(con, tbl, spec) {
  d    <- db_q(con, glue("DESCRIBE {tbl}"))
  cn   <- intersect(c("col_name", "COL_NAME", "name", "NAME"), names(d))
  have <- if (length(cn)) toupper(trimws(as.character(d[[cn[1]]]))) else character(0)
  for (m in setdiff(names(spec), have)) {
    tryCatch({
      db_exec(con, glue("ALTER TABLE {tbl} ADD COLUMNS ({m} {spec[[m]]})"))
      log_msg("  schema evolution on ", tbl, ": added ", m)
    }, error = function(e) {
      # Every column here is named in the INSERT that follows, so one that
      # could not be added is a failure now rather than a surprise later.
      if (!grepl("already exists|AlreadyExists|FIELD_ALREADY_EXISTS",
                 conditionMessage(e), ignore.case = TRUE))
        stop("Could not add column ", m, " to ", tbl, ": ", conditionMessage(e),
             call. = FALSE)
    })
  }
  invisible(TRUE)
}

# The attrition as a table, not only a log line: the count and the funnel that
# reaches it are what this build produces.
write_attrition <- function(con, cfg, counts) {
  tbl <- wrk("NDMM_ATTRITION")
  cols <- names(ATTRITION_COLS)
  db_exec(con, glue("CREATE TABLE IF NOT EXISTS {tbl} (",
                    paste(cols, ATTRITION_COLS, collapse = ", "), ")"))
  ensure_cols(con, tbl, ATTRITION_COLS)
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

# What MDV's value codes actually are, on the records this cohort reads.
#
# Every rule here compares a column with a code config.csv names - nyugaikbn 2
# is inpatient, utagaiflg 0 is confirmed, cancerflg 1 is cancer - and a code
# that is not this delivery's does not fail: it matches nothing. No inpatient
# record means no inpatient path; no confirmed one means no diagnosis at all.
# So the codes are profiled on the MM diagnosis records and the MM therapy
# acts, written to NDMM_MDV_SOURCE_PROFILE, and a profile in which a code
# matches none of them stops the run. So does a date column this build could
# not read on any record: dates that do not parse are NULL, and a NULL date
# falls out of every window without a word.
#
# The Optum build's NDC-shape and ICD_FLAG checks have nothing to be about on
# MDV - receipt codes are not padded and there is one ICD family - and this is
# the check in their place.
check_mdv_values <- function(con, cfg) {
  v <- MDV_VALUES
  read_as <- function(col, pairs) paste0("CASE ", paste(vapply(names(pairs), function(k)
    sprintf("WHEN %s = '%s' THEN '%s'", col, pairs[[k]], k), character(1)),
    collapse = " "), " ELSE 'neither' END")
  field <- function(src, fld, col, pairs) glue("
    SELECT '{src}' AS SOURCE, '{fld}' AS FIELD,
           coalesce({col}, '<null>') AS VALUE,
           {read_as(col, pairs)} AS READ_AS,
           count(*) AS N_RECORDS, count(DISTINCT PATID) AS N_PATIENTS
    FROM mmdx GROUP BY coalesce({col}, '<null>'), {read_as(col, pairs)}")
  # "\n" outside the glue: glue trims a leading newline, and the statement
  # came out as "...ENDUNION ALL".
  died <- if (nzchar(MDV_COLS$ff1_outcome)) paste0("\n", glue("
    UNION ALL
    SELECT 'ff1 of MM patients', 'died', cast(f.DIED as string),
           CASE WHEN f.DIED = 1 THEN 'death' ELSE 'not a death' END,
           count(*), count(DISTINCT f.PATID)
    FROM {NDMM_FF1} f
    INNER JOIN (SELECT DISTINCT PATID FROM mmdx) p ON p.PATID = f.PATID
    GROUP BY f.DIED")) else ""
  db_exec(con, glue("
    CREATE OR REPLACE TABLE {wrk('NDMM_MDV_SOURCE_PROFILE')} AS
    WITH mmdx AS (
      SELECT m.PATID, m.DX_MONTH, m.INOUT_RAW, m.SUSPECT_RAW, m.CANCER_RAW
      FROM {ndmm_dx_join(NDMM_MM_DX_CODES, 'c.code AS matched_code')} m
    ),
    tx AS (
      SELECT a.PATID, a.ACT_DT, a.INPT, a.ACT_DAYS
      FROM ({mdv_act_select()}
      ) a
      INNER JOIN (SELECT DISTINCT PATID FROM mmdx) p ON p.PATID = a.PATID
      INNER JOIN (SELECT DISTINCT RECEIPTCODE FROM {NDMM_MMA_RECEIPTS}) r
              ON r.RECEIPTCODE = a.RECEIPTCODE
    )
    SELECT r.*, {sql_text(run_id)} AS RUN_ID, current_timestamp() AS RECORDED_AT
    FROM (
      {field('mm diagnosis', 'nyugaikbn', 'INOUT_RAW',
             list(inpatient = v$inpatient, outpatient = v$outpatient))}
      UNION ALL
      {field('mm diagnosis', 'utagaiflg', 'SUSPECT_RAW', list(confirmed = v$confirmed))}
      UNION ALL
      {field('mm diagnosis', 'cancerflg', 'CANCER_RAW', list(cancer = v$cancer))}
      UNION ALL
      SELECT 'mm diagnosis', 'datamonth',
             CASE WHEN DX_MONTH IS NULL THEN 'unreadable' ELSE 'read' END,
             CASE WHEN DX_MONTH IS NULL THEN 'neither' ELSE 'date' END,
             count(*), count(DISTINCT PATID)
      FROM mmdx GROUP BY CASE WHEN DX_MONTH IS NULL THEN 'unreadable' ELSE 'read' END,
                         CASE WHEN DX_MONTH IS NULL THEN 'neither' ELSE 'date' END
      UNION ALL
      SELECT 'mm therapy act', 'actdate',
             CASE WHEN ACT_DT IS NULL THEN 'unreadable' ELSE 'read' END,
             CASE WHEN ACT_DT IS NULL THEN 'neither' ELSE 'date' END,
             count(*), count(DISTINCT PATID)
      FROM tx GROUP BY CASE WHEN ACT_DT IS NULL THEN 'unreadable' ELSE 'read' END,
                       CASE WHEN ACT_DT IS NULL THEN 'neither' ELSE 'date' END
      UNION ALL
      SELECT 'mm therapy act', 'setting',
             CASE WHEN INPT = 1 THEN 'inpatient' WHEN INPT = 0 THEN 'outpatient'
                  ELSE '<not carried>' END,
             CASE WHEN INPT = 1 THEN 'inpatient' WHEN INPT = 0 THEN 'outpatient'
                  ELSE 'neither' END,
             count(*), count(DISTINCT PATID)
      FROM tx GROUP BY CASE WHEN INPT = 1 THEN 'inpatient' WHEN INPT = 0 THEN 'outpatient'
                            ELSE '<not carried>' END,
                       CASE WHEN INPT = 1 THEN 'inpatient' WHEN INPT = 0 THEN 'outpatient'
                            ELSE 'neither' END
      UNION ALL
      SELECT 'mm therapy act', 'days supplied',
             CASE WHEN ACT_DAYS IS NULL THEN '<not carried>' WHEN ACT_DAYS < 1 THEN 'under 1'
                  ELSE 'carried' END,
             CASE WHEN ACT_DAYS >= 1 THEN 'days' ELSE 'neither' END,
             count(*), count(DISTINCT PATID)
      FROM tx GROUP BY CASE WHEN ACT_DAYS IS NULL THEN '<not carried>' WHEN ACT_DAYS < 1 THEN 'under 1'
                            ELSE 'carried' END,
                       CASE WHEN ACT_DAYS >= 1 THEN 'days' ELSE 'neither' END{died}
    ) r"))
  prof <- db_q(con, glue("SELECT * FROM {wrk('NDMM_MDV_SOURCE_PROFILE')}
                          ORDER BY SOURCE, FIELD, N_RECORDS DESC"))
  log_msg("MDV value codes on the records this cohort reads -> ",
          wrk("NDMM_MDV_SOURCE_PROFILE"), ":")
  for (i in seq_len(nrow(prof)))
    log_msg("    ", prof$SOURCE[i], " / ", prof$FIELD[i], " = ", prof$VALUE[i],
            " (read as ", prof$READ_AS[i], "): ",
            format(prof$N_RECORDS[i], big.mark = ","), " record(s), ",
            format(prof$N_PATIENTS[i], big.mark = ","), " patient(s)")
  n_as <- function(src, fld, as) sum(as.numeric(prof$N_RECORDS[
    prof$SOURCE == src & prof$FIELD == fld & prof$READ_AS == as]))
  n_dx <- sum(as.numeric(prof$N_RECORDS[prof$SOURCE == "mm diagnosis" &
                                          prof$FIELD == "datamonth"]))
  bad <- character(0)
  if (n_dx == 0)
    bad <- c(bad, "no diagnosis record carries a code on mm_dx.csv")
  else {
    if (n_as("mm diagnosis", "datamonth", "date") == 0)
      bad <- c(bad, paste0("no MM diagnosis record's ", MDV_COLS$datamonth,
                           " could be read as a month"))
    if (n_as("mm diagnosis", "nyugaikbn", "inpatient") == 0)
      bad <- c(bad, paste0("no MM diagnosis record has ", MDV_COLS$nyugaikbn,
                           " = '", v$inpatient, "' (MDV_INPATIENT)"))
    if (n_as("mm diagnosis", "nyugaikbn", "outpatient") == 0)
      bad <- c(bad, paste0("no MM diagnosis record has ", MDV_COLS$nyugaikbn,
                           " = '", v$outpatient, "' (MDV_OUTPATIENT)"))
    if (n_as("mm diagnosis", "utagaiflg", "confirmed") == 0)
      bad <- c(bad, paste0("no MM diagnosis record has ", MDV_COLS$utagaiflg,
                           " = '", v$confirmed, "' (MDV_CONFIRMED)"))
    if (NDMM_MDV_REQUIRE_CANCERFLG && n_as("mm diagnosis", "cancerflg", "cancer") == 0)
      bad <- c(bad, paste0("no MM diagnosis record has ", MDV_COLS$cancerflg,
                           " = '", v$cancer, "' (MDV_CANCER), and it is required"))
  }
  n_tx <- sum(as.numeric(prof$N_RECORDS[prof$SOURCE == "mm therapy act" &
                                          prof$FIELD == "actdate"]))
  if (n_tx > 0 && n_as("mm therapy act", "actdate", "date") == 0)
    bad <- c(bad, paste0("no MM therapy act's ", MDV_COLS$actdate,
                         " could be read as a date"))
  if (length(bad)) {
    msg <- paste0("MDV's value codes do not match config.csv on the records this ",
                  "cohort reads:\n  ", paste(bad, collapse = "\n  "),
                  "\nA code that is not this delivery's matches nothing, so the ",
                  "rule reading it silently stops applying. Read ",
                  wrk("NDMM_MDV_SOURCE_PROFILE"), " for the values that are there ",
                  "and set MDV_INPATIENT, MDV_OUTPATIENT, MDV_CONFIRMED or ",
                  "MDV_CANCER to them. NDMM_WAIVERS=mdv_values proceeds anyway.")
    if (!("mdv_values" %in% waivers())) stop(msg, call. = FALSE)
    log_msg("WAIVED (mdv_values): ", paste(bad, collapse = "; "))
    options(ndmm_waivers_applied = union(getOption("ndmm_waivers_applied",
                                                   character(0)), "mdv_values"))
  }
  # Two conditions that are findings rather than faults: the delivery does not
  # record death, or does not say how many days an act supplies. Each changes
  # what a number means, so it goes on the run's own row.
  if (!nzchar(MDV_COLS$ff1_outcome)) {
    log_msg("  Death is not observed: MDV_COL_FF1_OUTCOME is blank, so ENDDATE ",
            "is the study end for everyone and no line ends in death.")
    options(ndmm_findings = union(getOption("ndmm_findings", character(0)),
                                  "death_not_observed"))
  }
  invisible(prof)
}

# The md5 of every R file in this package, so two runs can be told apart by
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
contract_settings <- function(cfg = NULL) {
  k <- sort(names(CONTRACT), method = "radix")
  # The RUN's value, falling back to the contract's. The two are the same on a
  # contract build; on an overridden one this has to say what the cohort was
  # actually built from, because a study package reads this very column back
  # and refuses a study whose window disagrees with the cohort's. Recording CONTRACT here would have had it
  # compare against a value the run did not use.
  val <- function(key) {
    v <- if (!is.null(cfg) && !is.null(cfg[[key]])) cfg[[key]] else CONTRACT[[key]]
    as.character(v)[1]
  }
  paste(paste0(k, "=", vapply(k, val, character(1))), collapse = "|")
}

# check_contract() runs before the connection, and the findings list is reset
# after it - a second attempt in one session must not open carrying the first
# one's. So the deviations live in an option of their own and are folded back
# in at the reset: they belong to THIS run, and they are the one finding that
# is known before anything is read.
contract_deviation_findings <- function() {
  d <- getOption("ndmm_contract_deviations", character(0))
  if (!length(d)) character(0) else paste0("contract deviation: ", d)
}

RUN_METADATA_COLS <- c(RUN_ID = "STRING", OBJECT_PREFIX = "STRING",
                       BELANTAMAB_ABBR = "STRING", INDEX_EXCLUDED = "STRING",
                       INDEX_EXCLUDED_CODES = "STRING",
                       MM_ADJACENT_STATES = "STRING",
                       MM_ADJACENT_LABELS = "STRING",
                       # The MDV readings, and every table, column and value
                       # code the run read (R/mdv_source.R), so a count can be
                       # traced to the names that produced it.
                       MDV_VINTAGE = "STRING", MDV_IP_RULE = "STRING",
                       MDV_REQUIRE_CANCERFLG = "STRING", MDV_SOURCE = "STRING",
                       CODE_MD5 = "STRING",
                       CONTRACT_SETTINGS = "STRING",
                       WAIVERS_REQUESTED = "STRING", WAIVERS_APPLIED = "STRING",
                       FINDINGS = "STRING",
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
  ensure_cols(con, tbl, RUN_METADATA_COLS)
  db_replace(con,
    glue("DELETE FROM {tbl} WHERE RUN_ID = '{run_id}'"),
    glue("INSERT INTO {tbl} ({paste(cols, collapse = ', ')}) VALUES (",
         "{sql_text(run_id)}, {sql_text(cfg$object_prefix)}, ",
         "{sql_text(NDMM_BELANTAMAB_ABBR)}, {sql_text(NDMM_INDEX_EXCLUDED_ABBRS)}, ",
         "{sql_text(NDMM_INDEX_EXCLUDED_CODES)}, ",
         "{sql_text(NDMM_MM_ADJACENT_STATES)}, ",
         # The labels themselves, not just the mode: the list is settable, so
         # the mode alone does not say which codes were kept.
         "{sql_text(paste(ndmm_mm_adjacent_groups(), collapse = '|'))}, ",
         "{sql_text(mdv_vintage(cfg))}, {sql_text(NDMM_MDV_IP_RULE)}, ",
         "{sql_text(as.character(NDMM_MDV_REQUIRE_CANCERFLG))}, ",
         "{sql_text(mdv_source_settings())}, ",
         "{sql_text(code_fingerprint(here))}, ",
         "{sql_text(contract_settings(cfg))}, ",
         "{sql_text(paste(sort(waivers_named(), method = 'radix'), collapse = ','))}, ",
         "{sql_text(paste(sort(getOption('ndmm_waivers_applied', character(0)), ",
         "method = 'radix'), collapse = ','))}, ",
         "{sql_text(paste(sort(getOption('ndmm_findings', character(0)), ",
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
# anchor is re-derived from it: age at index, follow-up, and where observation
# ends. Carrying values measured elsewhere would describe the
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
    -- Where observation ends: the last day the patient is seen at the
    -- hospital (01_observation.R). This is ENDDATE_CE - the Optum cohort's
    -- end of enrollment, and on MDV the last record - so a LOT run censoring
    -- at it censors at loss to follow-up.
    ce AS (
      SELECT i.PATID, max(o.OBS_END_DT) AS ENDDATE_CE
      FROM idx i
      INNER JOIN {NDMM_OBS_PERIOD} o ON o.PATID = i.PATID
      GROUP BY i.PATID
    ),
    dem AS (
      SELECT cast(PATID as string) AS PATID, GDR_CD, YRDOB, MM_DX_DT
      FROM {NDMM_BASE_COHORT}
    ),
    -- The death date was clamped against the MM diagnosis, and the cohort is
    -- anchored at the 1L start, which is later. A death recorded between the
    -- two would give an ENDDATE before the index and a negative FU_DAYS.
    -- Re-clamp at the anchor that is actually used.
    dth AS (
      SELECT b.PATID,
             CASE WHEN b.DEATH_DT IS NOT NULL AND b.DEATH_DT < i.INDEX_DATE
                  THEN i.INDEX_DATE ELSE b.DEATH_DT END AS DEATH_DT
      FROM idx i
      INNER JOIN {NDMM_BASE_COHORT} b ON b.PATID = i.PATID
    )
    SELECT i.PATID,
           i.INDEX_DATE,
           -- The qualifying MM diagnosis date, carried so a reader can report
           -- diagnosis and treatment start as the two different dates they
           -- are. INDEX_DATE is the 1L treatment start, not the diagnosis.
           d.MM_DX_DT,
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
  # A death recorded between the diagnosis and the 1L start would end
  # follow-up before it began. build_ndmm_cohort_table() re-clamps it.
  if (isTRUE(q$n_backwards > 0))
    stop(q$n_backwards, " rows in ", tbl, " end before they begin: ENDDATE is ",
         "earlier than INDEX_DATE. build_ndmm_cohort_table() re-clamps death at ",
         "the index; if this fires, that clamp is not working.", call. = FALSE)
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
  seen <- getOption("ndmm_codelist_md5", list())
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
  ensure_cols(con, tbl, CODELIST_METADATA_COLS)
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
                       FINDINGS = "STRING",
                       # Which cohort table this row is the status OF.
                       #
                       # Without it, LOT's check_cohort_build() can read a
                       # status row here and still not know whether it belongs
                       # to the cohort table it was handed - its ownership test
                       # is "yes / no / it does not say". Without the column
                       # the only answer available is "it does not say", and a
                       # mismatched cohort then passes as verified.
                       # ensure_cols() adds the column to a table written by an
                       # earlier run.
                       FINAL_TABLE_NAME = "STRING",
                       UPDATED_AT = "TIMESTAMP")

# FINDINGS here as well as on NDMM_RUN_METADATA, because the two survive
# different things. The metadata row is written at the end and its previous
# attempt cleared up front, so a run that STOPS records nothing there - and a
# stopped run is the one worth reading. This row is rewritten on every state
# change and on failure through on.exit, so it is where a ceiling stop lands.
write_build_status <- function(con, cfg, state, n = NA) {
  tbl <- wrk("NDMM_BUILD_STATUS")
  cols <- names(BUILD_STATUS_COLS)
  db_exec(con, glue("CREATE TABLE IF NOT EXISTS {tbl} (",
                    paste(cols, BUILD_STATUS_COLS, collapse = ", "), ")"))
  ensure_cols(con, tbl, BUILD_STATUS_COLS)
  db_replace(con,
    glue("DELETE FROM {tbl} WHERE RUN_ID = '{run_id}'"),
    glue("INSERT INTO {tbl} ({paste(cols, collapse = ', ')}) VALUES (",
         "'{run_id}', '{cfg$object_prefix}', '{state}', {sql_count(n)}, ",
         "{sql_text(paste(sort(getOption('ndmm_findings', character(0)), ",
         "method = 'radix'), collapse = ','))}, ",
         # The prefixed name, which is what LOT is given and what it compares
         # against - not the bare NDMM_COHORT.
         "{sql_text(paste0(cfg$object_prefix, 'NDMM_COHORT'))}, ",
         "current_timestamp())"))
  log_msg("Build status: ", state, " (run ", run_id, ")")
  invisible(TRUE)
}

# Output names carry no run id, and checkpoint() repoints each view at the
# table it just replaced - so a run reads its own intermediates out of shared
# storage. Two runs on one prefix interleave through the checkpoints and
# deliverables, and both can reach "complete" having published a cohort
# partly the other's. Different prefixes are safe.
#
# A check, not a lock: two runs starting at once both pass it. It catches the
# case worth catching - starting a second while one is going.
check_no_active_run <- function(con, cfg) {
  # Not excluding this run's own id. run_id comes from DOMINO_RUN_ID, so a
  # second attempt in one Domino execution shares it - and excluding it hid the
  # collision most worth catching. Safe because this runs before
  # write_build_status marks this attempt started, so a 'started' row under
  # this id is always another attempt's.
  d <- tryCatch(db_q(con, glue("
    SELECT RUN_ID, UPDATED_AT FROM {wrk('NDMM_BUILD_STATUS')}
    WHERE OBJECT_PREFIX = '{cfg$object_prefix}'
      AND STATE = 'started'")), error = function(e) e)
  # No table is the first run on this prefix. Any other failure is this check
  # not running, which is not this check passing - clear_run_rows() below draws
  # the same line.
  ignoring <- identical(toupper(Sys.getenv("NDMM_IGNORE_ACTIVE_RUN", unset = "")),
                        "TRUE")
  if (inherits(d, "condition")) {
    if (missing_object_error(d)) return(invisible(TRUE))
    # The same override the found-a-run branch takes, or the message below
    # names a way out that does not exist.
    if (ignoring) {
      log_msg("WARNING: ", wrk("NDMM_BUILD_STATUS"), " could not be read (",
              conditionMessage(d), ") and NDMM_IGNORE_ACTIVE_RUN is set, so ",
              "nothing checked whether another run is building this prefix.")
      return(invisible(TRUE))
    }
    stop("Could not read ", wrk("NDMM_BUILD_STATUS"), " to check for a run ",
         "already building prefix ", cfg$object_prefix, ": ",
         conditionMessage(d),
         "\nThis is the check that stops two runs sharing one prefix, and it ",
         "did not run. It is not a first run - a missing table says so ",
         "specifically, and this did not. Fix the read and start again, or set ",
         "NDMM_IGNORE_ACTIVE_RUN=TRUE if you know no other run is going.",
         call. = FALSE)
  }
  if (!nrow(d)) return(invisible(TRUE))
  # When each started, so the operator can tell a run that is going from one a
  # killed process left behind months ago.
  who <- paste(paste0(d$RUN_ID, " (started ", d$UPDATED_AT, ")"), collapse = ", ")
  if (ignoring) {
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
       "NDMM_IGNORE_ACTIVE_RUN=TRUE.",
       # Said out loud, or a shared DOMINO_RUN_ID reads as the run blocking
       # itself.
       if (any(as.character(d$RUN_ID) == run_id))
         paste0("\nOne of those is this run's own id (", run_id, "), which a ",
                "second attempt in the same Domino execution shares. This ",
                "attempt has not written its own row yet, so that one is ",
                "another attempt still marked started.") else "",
       call. = FALSE)
}

# A re-run keeps run_id, so a second attempt writes under the first's id. Each
# writer clears its own rows, but only if it is reached - an attempt that dies
# before write_run_metadata leaves the first attempt's row claiming to describe
# this cohort. So they are cleared up front instead.
#
# NDMM_BUILD_STATUS is not here on purpose: its row is written just before
# this, and clearing it would delete the "started" row the next run looks for.
# NDMM_COHORT is not here either - it is replaced whole.
#
# A delete that cannot find its table is the first run, and fine. Anything else
# is said out loud: a refused DELETE leaves exactly the rows this removes.
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

load_ndmm_modules <- function(here) {
  source(file.path(here, "R", "load_inputs.R"))
  load_pipeline_inputs(here, "config.csv")
  for (f in c("config.R", "db_utils.R", "mdv_source.R", "codelists.R",
              "ndmm_constants.R", "standalone_constants.R"))
    source(file.path(here, "R", f))
  for (f in sort(list.files(file.path(here, "R", "steps"), "\\.R$", full.names = TRUE)))
    source(f)
  invisible(TRUE)
}

# con is for the test suite, which hands in a connection to a local DuckDB
# holding synthetic MDV tables (tests/run_mdv_ndmm.R). A production run passes
# none and connects to the warehouse here.
build_ndmm <- function(here, prefix, con = NULL) {
  check_settings()
  cfg <- pin_output_schema(cfg_defaults)
  cfg <- pin_prefix(cfg, prefix)
  check_contract(cfg)
  check_choices(cfg)
  check_constants(cfg)
  set_lot_config(cfg)

  if (is.null(con)) {
    stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")
    con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
    on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)
  }

  log_msg(SEP)
  log_msg("NDMM 1L cohort - prefix ", cfg$object_prefix, " - run ", run_id)
  log_msg("  1L start on or after: ", cfg$lot1_from)
  log_msg("  Source: ", mdv_tbl("disease", cfg), " and its siblings (MDV ",
          mdv_vintage(cfg), ")")
  log_msg("  Baseline / lookback before index: ", cfg$pre_lot1_days, " days")
  log_msg("  Follow-up observed: ", cfg$fu_ce_days, " day(s) after index")
  log_msg("  Inpatient MM diagnosis: ", cfg$mdv_ip_rule, "; cancerflg ",
          if (isTRUE(cfg$mdv_require_cancerflg)) "required" else "not required")
  log_msg(SEP)

  # Before this run writes anything, so a refused run leaves the prefix as it
  # found it. The query does not exclude this run's id, so it has to run before
  # write_build_status marks the attempt started or the run finds itself.
  check_no_active_run(con, cfg)
  check_upstream(con, cfg)
  # Before the first status row, which now carries findings: run_id is fixed at
  # config load, so a second attempt in one session would otherwise open by
  # writing the first attempt's findings under the same id.
  options(ndmm_complete = FALSE, ndmm_codelist_md5 = list(),
          ndmm_waivers_applied = character(0),
          ndmm_findings = contract_deviation_findings())
  write_build_status(con, cfg, "started")
  # Registered the moment the run is marked started, and before anything that
  # can stop - clear_run_rows() does. A stop between the two would leave the
  # status at "started" for ever, and check_no_active_run() would then refuse
  # every later run on this prefix until someone overrode it by hand.
  #
  # After = FALSE, or this fires after the disconnect above and writes to a
  # closed connection.
  on.exit(if (!isTRUE(getOption("ndmm_complete", FALSE)))
            try(write_build_status(con, cfg, "failed"), silent = TRUE),
          add = TRUE, after = FALSE)
  # After the status row, so a run is marked started whatever this does, and
  # before the first step, so no writer can be reached with the previous
  # attempt's rows still under this run's id.
  clear_run_rows(con, cfg)

  log_msg("MM diagnosis over the study period, and who is old enough")
  build_ndmm_mdv_views(con)
  build_ndmm_mm_dx_codes(con)
  checkpoint(con, "NDMM_MM_DX_CODES")
  build_ndmm_mm_dx_events(con)
  checkpoint(con, "NDMM_MM_DX_EVENTS")
  build_ndmm_mm_qualifying(con)
  checkpoint(con, "NDMM_MM_QUALIFYING")
  build_ndmm_demographics(con)
  build_ndmm_base_cohort(con)
  checkpoint(con, "NDMM_BASE_COHORT")

  log_msg("Observation at the hospital: each candidate's first and last MDV record")
  build_ndmm_obs_period(con)
  checkpoint(con, "NDMM_OBS_PERIOD")

  log_msg("MM therapy code list, the receipt codes it resolves to, and every MM therapy act")
  db_exec(con, build_ndmm_mma_codelist())
  checkpoint(con, "NDMM_MMA_CODELIST")
  build_ndmm_mma_receipts(con)
  checkpoint(con, "NDMM_MMA_RECEIPTS")
  check_ndmm_mma_code_types(con)
  build_ndmm_mm_tx(con)
  checkpoint(con, "NDMM_MM_TX")
  # After the scans it profiles exist, and before any criterion reads them.
  check_mdv_values(con, cfg)
  build_ndmm_belantamab_codes(con)
  checkpoint(con, "NDMM_BELANTAMAB_CODES")
  build_ndmm_index_ineligible_codes(con)
  checkpoint(con, "NDMM_INDEX_INELIGIBLE")

  log_msg("1L index: first eligible MM treatment act on or after ",
          NDMM_LOT1_FROM)
  build_ndmm_lot1_index(con)
  checkpoint(con, "NDMM_INDEX_TX")
  checkpoint(con, "NDMM_LOT1_STARTS")
  build_ndmm_index_agents(con, cfg)

  log_msg("MM therapy in the ", NDMM_PRE_LOT1_DAYS, " days before 1L")
  build_ndmm_therapy_pre_lot1(con)

  log_msg("Other cancer in the ", NDMM_PRE_LOT1_DAYS, " days before 1L")
  build_ndmm_other_malig_codes(con)
  checkpoint(con, "NDMM_OTHER_MALIG_CODES")
  build_ndmm_mm_adjacent_groups(con, cfg)
  build_ndmm_mm_adjacent_codes(con, cfg)
  build_ndmm_other_malig_groups(con, cfg)
  build_ndmm_other_malig_pre_lot1(con)
  checkpoint(con, "NDMM_OTHER_MALIG_EVENTS")
  build_ndmm_other_malig_grain(con, cfg)

  log_msg("Pregnancy across the study period")
  build_ndmm_preg_codes(con)
  checkpoint(con, "NDMM_PREG_CODES")
  build_ndmm_clintrial_codes(con)
  checkpoint(con, "NDMM_CLINTRIAL_CODES")
  build_ndmm_pregnancy_patids(con)

  log_msg("Belantamab in any line, from acts")
  build_ndmm_belantamab_patids(con)
  checkpoint(con, "NDMM_BELANTAMAB_TX")
  checkpoint(con, "NDMM_BELANTAMAB_PATIDS")

  log_msg("Per-patient filter flags")
  # The flags step takes the cohort and the belantamab source as parameters:
  # the base cohort answers for ELIG_COH_FINAL (it carries PATID and
  # DEATH_DT, which is all that step reads), and the belantamab view answers
  # in MAP_STACKED's shape.
  build_ndmm_flags(con, NDMM_BASE_COHORT, NDMM_BELANTAMAB_PATIDS)
  checkpoint(con, "NDMM_PATIDS")

  # Descriptive, not a criterion - it is built after the flags and joins
  # nothing into them, so the cohort is the same with it as without.
  log_msg("Clinical-trial evidence around the 1L index")
  build_ndmm_clintrial_flags(con)
  checkpoint(con, "NDMM_CLINTRIAL_FLAGS")
  report_ndmm_clintrial(con)
  # After the flags: each scope is costed against the whole conjunction, so it
  # needs every other criterion already decided.
  build_ndmm_fu_ce_counts(con, cfg)
  build_ndmm_preg_window_counts(con, cfg)
  # After NDMM_MM_TX, which the OC outpatient treatment link reads.
  build_ndmm_mm_dx_rules(con, cfg)

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
  options(ndmm_complete = TRUE)
  log_msg(SEP)
  log_msg("NDMM 1L cohort: ", format(ndmm_final_count(counts), big.mark = ","),
          " patients -> ", wrk("NDMM_COHORT"))
  # After the count, because which of these were supplied is part of reading it.
  log_msg(SEP)
  invisible(counts)
}
