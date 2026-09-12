# Code-list loading, and the guard that matters more than the loading.
#
# Every code list this package needs is a CSV under CODELIST_DIR, and none of
# them is in version control. Four have no codes yet: they come out of the
# protocol's Annex 2, Annex 3 and Annex 7 (../CODELISTS.md).
#
# The guard: a code list that exists but is UNFILLED stops the module that
# needs it. A rate of zero for want of a code list is indistinguishable in
# every downstream table from a rate of zero for want of events.

# file -> the columns the loader requires. A file not named here cannot be
# loaded: a typo would otherwise read an unrelated file cleanly.
#
# CODELIST_CODE_COL names which of those columns carries the code, because the
# unfilled-row guard turns on it. It is data rather than a caller argument, so
# a call site naming a column the file does not have cannot disable the guard.
CODELIST_CODE_COL <- c(
  "mm_dx.csv"                  = "dx",
  "cl_mma_codelist.csv"        = "CL_CODE",
  "cl_mma_rollup.csv"          = "CL_MED_ABBR",
  "cl_sct_codelist.csv"        = "CL_CODE",
  "safety_events.csv"          = "code",
  "secondary_malig.csv"        = "code",
  "charlson_quan2011.csv"      = "code",
  "frailty_kim2018.csv"        = "code",
  "hcru.csv"                   = "code",
  "soc_regimen_categories.csv" = "CL_MED_ABBR",
  "comorbid_subgroups.csv"     = "code"
)

CODELIST_SPEC <- list(
  # Already on production, read by the cohort and LOT builds.
  "mm_dx.csv"                 = c("dx", "icd_family"),
  "cl_mma_codelist.csv"       = c("CL_CODE_TYPE", "CL_CODE", "CL_MEDICATION_FULL",
                                  "CL_MED_CLASS", "CL_MED_ABBR"),
  "cl_mma_rollup.csv"         = c("CL_MEDICATION_FULL", "CL_MED_CLASS",
                                  "CL_MED_ABBR"),
  "cl_sct_codelist.csv"       = c("CL_CODE_TYPE", "CL_CODE", "SCT_TYPE"),
  # To be authored. ../CODELISTS.md section 4 proposes each shape.
  "safety_events.csv"         = c("condition", "domain", "acute_chronic",
                                  "code_type", "code", "icd_family"),
  "secondary_malig.csv"       = c("category", "subtype", "code_type", "code",
                                  "icd_family"),
  "charlson_quan2011.csv"     = c("condition", "weight", "code_type", "code",
                                  "icd_family"),
  "frailty_kim2018.csv"       = c("variable", "coefficient", "code_type",
                                  "code", "icd_family"),
  "hcru.csv"                  = c("concept", "code_type", "code"),
  "soc_regimen_categories.csv" = c("line_scope", "soc_category", "CL_MED_ABBR",
                                   "role"),
  "comorbid_subgroups.csv"    = c("concept", "code_type", "code", "icd_family")
)

# Which annex owes each file, so a missing one names what to ask for.
CODELIST_SOURCE <- c(
  safety_events.csv          = "Annex 3 (codelists to define study outcomes)",
  secondary_malig.csv        = "Annex 3, with Table 2's ten categories",
  charlson_quan2011.csv      = "Quan et al. 2011 - no annex supplies it",
  frailty_kim2018.csv        = "Annex 7 (claims-based frailty algorithm)",
  hcru.csv                   = "no annex - the ED construction is undecided (../OPEN_QUESTIONS.md Q11)",
  soc_regimen_categories.csv = "Annex 2 (categorization of SOC regimens)",
  comorbid_subgroups.csv     = "Annex 3"
)

# The two tables have to agree, and a mismatch is a coding error rather than a
# data one - so it is caught when the file is sourced, not when a run reaches
# the module that reads it.
local({
  missing <- setdiff(names(CODELIST_SPEC), names(CODELIST_CODE_COL))
  if (length(missing))
    stop("CODELIST_CODE_COL does not name a code column for: ",
         paste(missing, collapse = ", "), call. = FALSE)
  for (f in names(CODELIST_SPEC))
    if (!CODELIST_CODE_COL[[f]] %in% CODELIST_SPEC[[f]])
      stop("CODELIST_CODE_COL says ", f, "'s code column is '",
           CODELIST_CODE_COL[[f]], "', which is not one of its required ",
           "columns: ", paste(CODELIST_SPEC[[f]], collapse = ", "),
           call. = FALSE)
})

ICD_FAMILY_9  <- c("9", "ICD9", "ICD-9", "ICD9DIAG")
ICD_FAMILY_10 <- c("10", "ICD10", "ICD-10", "ICD10DIAG")

# What each file this build read actually was, so a number can be traced to it.
# Package-level, so a second build in the same R session does not inherit the
# first's entries. Cleared per build by reset_run_state().
.codelist_seen <- new.env(parent = emptyenv())

reset_codelist_manifest <- function() {
  rm(list = ls(.codelist_seen), envir = .codelist_seen)
  invisible(TRUE)
}

# Reads one file, checks its shape, and refuses it if it carries no usable
# codes. Records the md5 and row count so a number can be traced to the file
# that produced it - the same contract the cohort build's loader keeps.
load_codelist <- function(csv_name, cfg) {
  if (!csv_name %in% names(CODELIST_SPEC))
    stop("CODELIST ERROR: ", csv_name, " is not a file this package is defined ",
         "on. Known: ", paste(names(CODELIST_SPEC), collapse = ", "), ".",
         call. = FALSE)
  code_col <- CODELIST_CODE_COL[[csv_name]]
  path <- file.path(cfg$codelist_dir, csv_name)
  if (!file.exists(path))
    stop("CODELIST ERROR: ", path, " does not exist.",
         if (csv_name %in% names(CODELIST_SOURCE))
           paste0("\nIt comes from ", CODELIST_SOURCE[[csv_name]],
                  ", which has not been delivered - see ../CODELISTS.md.")
         else "", call. = FALSE)

  md5 <- unname(tools::md5sum(path))
  df <- utils::read.csv(path, stringsAsFactors = FALSE,
                        na.strings = c("", "NA", "NaN"), colClasses = "character")
  if (!identical(md5, unname(tools::md5sum(path))))
    stop("CODELIST ERROR: ", csv_name, " changed while it was being read.",
         call. = FALSE)

  need <- CODELIST_SPEC[[csv_name]]
  missing <- setdiff(need, names(df))
  if (length(missing))
    stop("CODELIST ERROR: ", csv_name, " is missing required column(s): ",
         paste(missing, collapse = ", "), ". Found: ",
         paste(names(df), collapse = ", "), ".", call. = FALSE)
  if (!nrow(df))
    stop("CODELIST ERROR: ", csv_name, " has no data rows.", call. = FALSE)

  check_unfilled(df, csv_name, code_col)
  if ("icd_family" %in% names(df)) check_icd_family(df, csv_name)

  assign(csv_name, list(md5 = md5, n_rows = nrow(df),
                        n_codes = sum(nzchar(trimws(
                          ifelse(is.na(df[[code_col]]), "", df[[code_col]]))))),
         envir = .codelist_seen)
  log_msg("  codelist ", csv_name, ": ", nrow(df), " row(s), md5 ", md5)
  df
}

# The guard. A file whose code column is blank on some rows is a file that is
# still being written, and the concepts on those rows would silently report
# zero.
check_unfilled <- function(df, csv_name, code_col) {
  # Not a silent pass: a code column that is not there means the spec and the
  # file disagree, and the guard cannot run. That is worse than a blank row.
  if (!code_col %in% names(df))
    stop("CODELIST ERROR: ", csv_name, " has no '", code_col, "' column, so ",
         "the unfilled-row guard cannot run. CODELIST_CODE_COL names it; ",
         "either the file or that entry is wrong.", call. = FALSE)
  code <- trimws(ifelse(is.na(df[[code_col]]), "", as.character(df[[code_col]])))
  blank <- !nzchar(code)
  if (!any(blank)) return(invisible(TRUE))
  concept_col <- intersect(c("condition", "concept", "category", "variable",
                             "soc_category"), names(df))
  concepts <- if (length(concept_col))
    sort(unique(as.character(df[[concept_col[1]]][blank]))) else character(0)
  stop("CODELIST ERROR: ", csv_name, " has ", sum(blank), " of ", nrow(df),
       " row(s) with no code",
       if (length(concepts))
         paste0(", covering: ", paste(utils::head(concepts, 12), collapse = ", "),
                if (length(concepts) > 12) sprintf(" (+%d more)",
                                                   length(concepts) - 12) else "")
       else "",
       ".\nA rate for those would be zero for want of a code list rather than ",
       "for want of events, and nothing downstream could tell the two apart. ",
       "Fill them, or drop the rows and lose the concept honestly.",
       call. = FALSE)
}

check_icd_family <- function(df, csv_name) {
  raw <- trimws(as.character(df$icd_family))
  ok <- toupper(c(ICD_FAMILY_9, ICD_FAMILY_10))
  # A blank cell is NA after read.csv's na.strings, and a blank family is
  # exactly as unmatchable as a misspelled one - so it is bad, not skipped.
  bad <- is.na(raw) | !nzchar(raw) | !(toupper(raw) %in% ok)
  if (any(bad))
    stop("CODELIST ERROR: ", csv_name, " has ", sum(bad),
         " row(s) whose icd_family this package does not recognise: ",
         paste(unique(ifelse(is.na(raw[bad]) | !nzchar(raw[bad]),
                             "<blank>", raw[bad])), collapse = ", "),
         ". An unrecognised family is joined as neither, so the row matches no ",
         "claim and stops excluding or qualifying anyone, silently. Spell it ",
         "one of: ", paste(c(ICD_FAMILY_9, ICD_FAMILY_10), collapse = ", "), ".",
         call. = FALSE)
  invisible(TRUE)
}

# Table 3 types two conditions "Acute or chronic" and "Acute/Chronic", and a
# LIKE '%acute%' test and a LIKE '%chronic%' test both match those - the
# condition would be counted once through the acute washout chain and once as a
# chronic first occurrence. So the column is canonicalised to exactly one rule:
# s7.8.1's own chronic list resolves what it names, and the rest stops the run.
canonical_acute_chronic <- function(x, condition = NULL) {
  v <- tolower(trimws(ifelse(is.na(x), "", as.character(x))))
  has_a <- grepl("acute", v, fixed = TRUE)
  has_c <- grepl("chronic", v, fixed = TRUE)
  out <- ifelse(has_a & !has_c, "acute",
         ifelse(has_c & !has_a, "chronic", NA_character_))
  both <- has_a & has_c
  if (any(both) && !is.null(condition)) {
    cond <- tolower(trimws(as.character(condition)))
    out[both & cond %in% PROTOCOL_CHRONIC_CONDITIONS] <- "chronic"
  }
  unresolved <- is.na(out)
  if (any(unresolved)) {
    lbl <- if (is.null(condition)) unique(x[unresolved]) else
      unique(sprintf("%s (%s)", condition[unresolved], x[unresolved]))
    stop("CODELIST ERROR: acute_chronic could not be resolved to one rule for: ",
         paste(lbl, collapse = "; "),
         ".\nA value naming both is counted twice - once through the acute ",
         "washout chain and once as a chronic first occurrence - so it has to ",
         "say which. s7.8.1's chronic list resolves the ones it names; type ",
         "the rest explicitly.", call. = FALSE)
  }
  out
}

# Where the code lists are. An unset CODELIST_DIR means this package's own
# codelists/ - the folder ships every shape it reads, so it is complete without
# anything outside it. Production sets CODELIST_DIR to the real directory.
resolve_codelist_dir <- function(cfg, here) {
  d <- if (nzchar(cfg$codelist_dir)) cfg$codelist_dir
       else file.path(here, "codelists")
  if (!dir.exists(d))
    stop("CODELIST ERROR: ", d, " is not a directory. Set CODELIST_DIR, or ",
         "restore this package's own codelists/.", call. = FALSE)
  normalizePath(d, mustWork = TRUE)
}

# Checked before any module runs, so a run that cannot finish stops in the
# first second rather than after the expensive steps. Each list is LOADED
# rather than stat-ed: codelists/ ships templates with the right columns and no
# codes, which a path check would accept.
#
# MODULES=all asks for everything that CAN run: a module whose list is unusable
# is left out by name, along with anything that needs it, and the run carries
# on - the plan, the log and S_RUN_METADATA all name it. A module named in
# MODULES was asked for, so its list is required and the run stops here. Either
# way no module runs on an unusable list.
#
# Each list is also put through the module's own registry `check` against the
# settings - an ED definition the HCRU list has no rows for, a SOC category the
# protocol does not name, a safety condition defined by an admission - so a
# list the module would refuse is found before the connection is opened.
# Returns the modules that will run.
preflight_codelists <- function(mods, cfg) {
  want <- required_codelists(mods)
  if (!length(want)) return(invisible(mods))

  unusable <- list()
  for (f in want) {
    err <- tryCatch({ load_codelist(f, cfg); NULL },
                    error = function(e) conditionMessage(e))
    if (!is.null(err)) unusable[[f]] <- sub("^CODELIST ERROR: ", "", err)
  }
  refused <- list()
  for (k in names(mods)) {
    chk <- mods[[k]]$check
    if (is.null(chk) || any(mods[[k]]$codelists %in% names(unusable))) next
    if (!exists(chk, mode = "function"))
      stop("BUILD ERROR: module '", k, "' registers ", chk, "() as its check ",
           "and it is not defined.", call. = FALSE)
    err <- tryCatch({ get(chk, mode = "function")(cfg); NULL },
                    error = function(e) conditionMessage(e))
    if (!is.null(err)) refused[[k]] <- sub("^[A-Z]+ ERROR: ", "", err)
  }
  if (!length(unusable) && !length(refused)) return(invisible(mods))

  if (!identical(tolower(cfg$modules), "all")) {
    indent <- function(x) gsub("\n", "\n    ", unlist(x, use.names = FALSE))
    problems <- c(sprintf("  %s\n    %s", names(unusable), indent(unusable)),
                  sprintf("  module %s\n    %s", names(refused), indent(refused)))
    stop("CODELIST ERROR: ", length(problems), " code list(s) the selected ",
         "modules need are not usable:\n",
         paste(problems, collapse = "\n"),
         "\n\nEither fill them, or narrow MODULES so nothing needs them - ",
         "MODULES=spine,cohorts,attrition,periods,demographics,tte runs the whole ",
         "cohort and the time-to-event outcomes with no code list at all - or ",
         "run with MODULES=all, which leaves out by name whatever has no ",
         "usable list.", call. = FALSE)
  }

  # Left out: the modules on an unusable list or refusing their own, then
  # whatever needs one of those, to a fixed point.
  dropped <- character(0)
  repeat {
    more <- names(Filter(function(m)
      any(m$codelists %in% names(unusable)) || m$key %in% names(refused) ||
        any(m$needs %in% dropped), mods))
    more <- setdiff(more, dropped)
    if (!length(more)) break
    dropped <- c(dropped, more)
  }
  # The plan names the files; the log carries each list's reason in full.
  first_line <- function(x) sub("\n.*$", "", x)
  why <- vapply(dropped, function(k) {
    lists <- intersect(mods[[k]]$codelists, names(unusable))
    if (length(lists)) paste(lists, collapse = ", ")
    else if (k %in% names(refused)) first_line(refused[[k]])
    else paste0("needs ", paste(intersect(mods[[k]]$needs, dropped), collapse = ", "))
  }, character(1))
  for (k in dropped) {
    lists <- intersect(mods[[k]]$codelists, names(unusable))
    log_msg("module ", k, " left out - ", if (length(lists))
      paste(sprintf("%s: %s", lists, first_line(unlist(unusable[lists]))), collapse = "; ")
      else why[[k]])
  }
  keep <- mods[setdiff(names(mods), dropped)]
  attr(keep, "left_out") <- why
  invisible(keep)
}

# One row per file THIS build read. Empty is a real answer: a module selection
# needing no code list reads none.
codelist_metadata <- function() {
  ks <- ls(.codelist_seen)
  if (!length(ks)) return(data.frame())
  do.call(rbind, lapply(ks, function(k) {
    v <- get(k, envir = .codelist_seen)
    data.frame(CODELIST = k, MD5 = v$md5, N_ROWS = v$n_rows,
               N_CODES = v$n_codes, stringsAsFactors = FALSE)
  }))
}

# A claim's ICD_FLAG, normalised to the two families and nothing else.
#
# Anything that is not one of the ICD-9 spellings yields NULL rather than
# ICD-10. Reading a blank flag as ICD-10 mis-classes a genuine ICD-9 claim,
# which then fails the family join silently. The CDM does carry blanks - the
# cohort build found 16 on its first production run.
icd_family_sql <- function(col) {
  q <- function(v) paste(sprintf("'%s'", v), collapse = ",")
  sprintf("CASE WHEN upper(trim(%s)) IN (%s) THEN 'ICD9'
                WHEN upper(trim(%s)) IN (%s) THEN 'ICD10' END",
          col, q(c("9", "ICD9", "ICD-9")), col, q(c("10", "ICD10", "ICD-10")))
}

# A code list as a temporary view, with both join keys normalised the same way
# the claim side is: punctuation stripped, uppercased. Done here so no module
# writes its own normalisation and the two sides cannot drift.
register_codelist_view <- function(con, df, view_name, cols,
                                   code_col = "code",
                                   family_col = "icd_family") {
  missing <- setdiff(cols, names(df))
  if (length(missing))
    stop("CODELIST ERROR: view ", view_name, " asked for column(s) the file ",
         "does not have: ", paste(missing, collapse = ", "), ".", call. = FALSE)
  keep <- df[, cols, drop = FALSE]
  keep[] <- lapply(keep, function(x) ifelse(is.na(x), "", as.character(x)))

  # Over a Spark session, sparklyr::copy_to - and a Spark session inherits
  # DBIConnection, which is why it is tested for first. Over the ODBC driver
  # there is no copy_to, so the list is one VALUES statement behind a temporary
  # view, the way the cohort build loads its own lists over the same driver.
  # Never chunked: a temporary view cannot be appended to, and the obvious
  # workaround defines the view in terms of itself.
  stage <- paste0(tolower(view_name), "_raw")
  if (is_spark_con(con) || !is_dbi_con(con))
    sparklyr::copy_to(con, keep, name = stage, overwrite = TRUE, memory = FALSE)
  else db_exec(con, codelist_stage_sql(stage, keep))

  db_exec(con, codelist_view_sql(stage, view_name, cols, code_col, family_col))
  view_name
}

# A code list as one statement: a temporary view over a VALUES list, every
# cell a string literal, in the frame's column order. An empty list is an
# empty view of the same shape rather than a VALUES with nothing in it, which
# is a syntax error.
#
# The literal follows Spark's rules, not the SQL standard's. Spark reads two
# adjacent literals as one string joined, so 'Alzheimer''s' is Alzheimers, with
# no error to say so. Its escape is the backslash: \' for a quote, \\ for a
# backslash itself (spark.sql.parser.escapedStringLiterals=false).
codelist_stage_sql <- function(stage, df) {
  lit  <- function(x) paste0("'", gsub("'", "\\'", gsub("\\", "\\\\", as.character(x), fixed = TRUE),
                                       fixed = TRUE), "'")
  cols <- paste(names(df), collapse = ", ")
  if (!nrow(df))
    return(sprintf("CREATE OR REPLACE TEMPORARY VIEW %s AS\nSELECT * FROM (VALUES (%s)) AS t(%s) WHERE 1 = 0",
                   stage, paste(rep("''", ncol(df)), collapse = ", "), cols))
  rows <- paste0("(", do.call(paste, c(lapply(df, lit), sep = ", ")), ")")
  sprintf("CREATE OR REPLACE TEMPORARY VIEW %s AS\nSELECT * FROM (VALUES\n  %s\n) AS t(%s)",
          stage, paste(rows, collapse = ",\n  "), cols)
}

# The normalisation, as SQL, separate from the staging that needs a session, so
# the same statement is emitted whether or not a session is there to stage
# into. Every code-driven join depends on it: without the upper() here, every
# rate in the study would be zero.
codelist_view_sql <- function(stage, view_name, cols, code_col = "code",
                              family_col = "icd_family") {
  norm_code <- if (code_col %in% cols)
    sprintf("upper(regexp_replace(trim(%s), '[^A-Za-z0-9]', '')) AS code_norm",
            code_col) else "cast(NULL as string) AS code_norm"
  # The SAME strictness as the claim side. An unrecognised or blank family
  # yields NULL and matches neither, rather than defaulting to ICD-10 and
  # quietly failing to match a genuine ICD-9 row.
  norm_fam <- if (family_col %in% cols)
    sprintf("CASE WHEN upper(trim(%s)) IN ('9','ICD9','ICD-9','ICD9DIAG')
                  THEN 'ICD9'
                  WHEN upper(trim(%s)) IN ('10','ICD10','ICD-10','ICD10DIAG')
                  THEN 'ICD10' END AS icd_norm", family_col, family_col)
    else "cast(NULL as string) AS icd_norm"
  # Code types are compared case-insensitively everywhere, so they are
  # normalised here rather than in each module's join.
  norm_type <- if ("code_type" %in% cols)
    "upper(trim(code_type)) AS code_type_norm"
    else "cast(NULL as string) AS code_type_norm"

  sprintf("CREATE OR REPLACE TEMPORARY VIEW %s AS
           SELECT *, %s, %s, %s FROM %s",
          view_name, norm_code, norm_fam, norm_type, stage)
}
