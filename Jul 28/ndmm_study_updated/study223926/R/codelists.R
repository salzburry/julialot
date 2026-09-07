# Code-list loading, and the guard that matters more than the loading.
#
# Every code list this package needs is a CSV under CODELIST_DIR. None of them
# is in version control - Jul 28/RUN_ON_PROD.md: "Code and docs only. No code
# lists". Four of them do not exist anywhere yet, because they come out of the
# protocol's Annex 2, Annex 3 and Annex 7, which were never delivered
# (../CODELISTS.md).
#
# The guard: a code list that exists but is UNFILLED stops the module that
# needs it. An unfilled row joins to nothing, and a rate of zero for want of a
# code list is indistinguishable in every downstream table from a rate of zero
# for want of events. The Aug 14 fork's safety loader takes the same line, and
# its wording is the right one: "a rate for them would be zero for want of a
# code list rather than for want of events".

# file -> the columns the loader requires. A file not named here cannot be
# loaded: a typo would otherwise read an unrelated file cleanly.
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

ICD_FAMILY_9  <- c("9", "ICD9", "ICD-9", "ICD9DIAG")
ICD_FAMILY_10 <- c("10", "ICD10", "ICD-10", "ICD10DIAG")

.codelist_seen <- new.env(parent = emptyenv())

# Reads one file, checks its shape, and refuses it if it carries no usable
# codes. Records the md5 and row count so a number can be traced to the file
# that produced it - the same contract the cohort build's loader keeps.
load_codelist <- function(csv_name, cfg, code_col = "code") {
  if (!csv_name %in% names(CODELIST_SPEC))
    stop("CODELIST ERROR: ", csv_name, " is not a file this package is defined ",
         "on. Known: ", paste(names(CODELIST_SPEC), collapse = ", "), ".",
         call. = FALSE)
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
  if (!code_col %in% names(df)) return(invisible(TRUE))
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
  keep <- !is.na(raw)
  ok <- toupper(c(ICD_FAMILY_9, ICD_FAMILY_10))
  bad <- keep & !(toupper(raw) %in% ok)
  if (any(bad))
    stop("CODELIST ERROR: ", csv_name, " has ", sum(bad),
         " row(s) whose icd_family this package does not recognise: ",
         paste(unique(raw[bad]), collapse = ", "),
         ". An unrecognised family is joined as neither, so the row matches no ",
         "claim and stops excluding or qualifying anyone, silently. Spell it ",
         "one of: ", paste(c(ICD_FAMILY_9, ICD_FAMILY_10), collapse = ", "), ".",
         call. = FALSE)
  invisible(TRUE)
}

# Checked before any module runs, so a run that cannot finish stops in the
# first second rather than after the expensive steps.
preflight_codelists <- function(mods, cfg) {
  want <- required_codelists(mods)
  if (!length(want)) return(invisible(character(0)))
  missing <- want[!file.exists(file.path(cfg$codelist_dir, want))]
  if (length(missing)) {
    detail <- vapply(missing, function(f)
      sprintf("  %-28s %s", f,
              if (f %in% names(CODELIST_SOURCE)) CODELIST_SOURCE[[f]] else "unknown source"),
      character(1))
    stop("CODELIST ERROR: ", length(missing), " code list(s) the selected ",
         "modules need are not in ", cfg$codelist_dir, ":\n",
         paste(detail, collapse = "\n"),
         "\n\nEither deliver them, or narrow MODULES so nothing needs them - ",
         "`Rscript build.R` with MODULES=spine,cohorts,periods,demographics,tte ",
         "runs the whole cohort and the time-to-event outcomes with no code ",
         "list this repo does not already have.", call. = FALSE)
  }
  invisible(want)
}

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
# which then fails the family join silently - a missed diagnosis on one code
# list, a missed exclusion on another. The CDM does carry blanks: the cohort
# build found 16 on its first production run (ndmm/DECISIONS.md section 11).
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

  esc <- function(x) gsub("'", "''", ifelse(is.na(x), "", as.character(x)))
  sel <- vapply(seq_len(nrow(keep)), function(i)
    paste0("SELECT ", paste(sprintf("'%s' AS %s", esc(keep[i, ]), cols),
                            collapse = ", ")), character(1))
  # Chunked so a long list does not become one unparseable statement.
  chunks <- split(sel, ceiling(seq_along(sel) / 500))
  stage <- paste0(view_name, "_RAW")
  first <- TRUE
  for (ch in chunks) {
    verb <- if (first) sprintf("CREATE OR REPLACE TEMPORARY VIEW %s AS", stage)
            else sprintf("INSERT INTO %s", stage)
    if (first) {
      db_exec(con, paste(verb, paste(ch, collapse = " UNION ALL ")))
      first <- FALSE
    } else {
      # A temporary view cannot be inserted into; materialise once it is big.
      db_exec(con, sprintf(
        "CREATE OR REPLACE TEMPORARY VIEW %s AS SELECT * FROM %s UNION ALL %s",
        stage, stage, paste(ch, collapse = " UNION ALL ")))
    }
  }
  norm_code <- if (code_col %in% cols)
    sprintf("upper(regexp_replace(trim(%s), '[^A-Za-z0-9]', '')) AS code_norm",
            code_col) else "cast(NULL as string) AS code_norm"
  norm_fam <- if (family_col %in% cols)
    sprintf("CASE WHEN upper(trim(%s)) IN ('9','ICD9','ICD-9','ICD9DIAG')
                  THEN 'ICD9' ELSE 'ICD10' END AS icd_norm", family_col)
    else "cast(NULL as string) AS icd_norm"
  db_exec(con, sprintf("CREATE OR REPLACE TEMPORARY VIEW %s AS
                        SELECT *, %s, %s FROM %s",
                       view_name, norm_code, norm_fam, stage))
  view_name
}
