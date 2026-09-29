# CSV-only code list loading.
# The CSV in cfg$codelist_dir is required; there is no embedded fallback.
#
# These are the MDV code lists, written in MDV's vocabulary: disease codes (or
# ICD-10, where the delivery carries it), receipt codes, and English drug-name
# patterns. The Optum lists of the same names cannot be pointed at: every
# HCPCS, NDC and ICD-9 row in them would stop the run at check_code_types().
# codelists/README.md has each file's columns.

# The five files this build reads: mm_dx.csv identifies the MM diagnosis
# that defines the population, cl_mma_codelist.csv drives the index, the
# prior-MM-therapy scan and belantamab, other_malig.csv the other-cancer
# exclusion, and pregnancy.csv the pregnancy exclusion. Anything else is a
# typo, not a code list.
CODELIST_FILES <- c("cl_mma_codelist.csv", "mm_dx.csv", "other_malig.csv",
                    "pregnancy.csv", "clintrial.csv")
# clintrial.csv drives no exclusion - it is the descriptive trial flag in
# 08_clintrial.R. It is here because every file this build reads must be, so
# its md5 is recorded beside the others: a trial count is quoted like any
# other number and means little without the version behind it.

# The code types an MDV code list may carry, and what each is matched against.
#
#   DISEASECODE  diseasedata.diseasecode, equal after normalising
#   ICD10        the diagnosis table's ICD-10 column, equal after normalising -
#                only where the delivery has one (MDV_COL_ICD10)
#   RECEIPTCODE  actdata.receiptcode, equal after normalising: a drug given or
#                a procedure done
#   NAME_ENG     a LIKE pattern over the drug master's English name, resolved
#                to receipt codes - '%bortezomib%'. Drugs only.
#
# Each list names the types its scan reads (below), and a row of any other type
# stops the run: the join is on type and code, so a row typed something no scan
# reads loads cleanly and matches nothing, and on an exclusion list that keeps
# a patient the criterion should have removed.
MDV_DX_CODE_TYPES   <- c("DISEASECODE", "ICD10")
MDV_DRUG_CODE_TYPES <- c("RECEIPTCODE", "NAME_ENG")
MDV_ANY_CODE_TYPES  <- c("DISEASECODE", "ICD10", "RECEIPTCODE")
CODELIST_CODE_TYPES <- list(
  "mm_dx.csv"           = MDV_DX_CODE_TYPES,
  "other_malig.csv"     = MDV_DX_CODE_TYPES,
  "pregnancy.csv"       = MDV_ANY_CODE_TYPES,
  "clintrial.csv"       = MDV_ANY_CODE_TYPES,
  "cl_mma_codelist.csv" = MDV_DRUG_CODE_TYPES)

# Checked in R as the file is read, before a row of it reaches SQL: cheaper
# than a round trip, it fails before anything is built, and every list gets it
# without a second call site to remember.
#
# Three things, each of which would otherwise make a rule that cannot fire: a
# type the list's scan does not read; an ICD10 row where the delivery has no
# ICD-10 column; and, on the two lists that group or grade by ICD-10, a
# DISEASECODE row that does not say which ICD-10 code it is.
check_code_types <- function(df, csv_name, type_col, code_col) {
  allowed <- CODELIST_CODE_TYPES[[csv_name]]
  if (is.null(allowed) || !type_col %in% names(df)) return(invisible(TRUE))
  keep <- !is.na(df[[code_col]]) &
          nzchar(gsub("[^A-Za-z0-9%]", "", as.character(df[[code_col]])))
  ty <- toupper(trimws(as.character(df[[type_col]])))
  ty[is.na(ty)] <- ""
  bad <- keep & !(ty %in% allowed)
  if (any(bad))
    stop("CODELIST ERROR: ", csv_name, " has ", sum(bad), " row(s) of a code ",
         "type this build does not read: ",
         paste(unique(ifelse(nzchar(ty[bad]), ty[bad], "<blank>")), collapse = ", "),
         ".\nIts scan reads ", paste(allowed, collapse = ", "), ". A row of ",
         "another type loads and matches nothing, so the rule it carries never ",
         "fires. These are MDV code lists: the Optum HCPCS, CPT, NDC, ICD9 and ",
         "REV types have no MDV column to meet.", call. = FALSE)
  if (any(keep & ty == "ICD10") && !nzchar(MDV_COLS$icd10))
    stop("CODELIST ERROR: ", csv_name, " has ICD10 rows, and MDV_COL_ICD10 is ",
         "blank, so this delivery has no ICD-10 column for them to meet. Name ",
         "the column in config.csv, or give the rows as DISEASECODE.",
         call. = FALSE)
  if ("icd10" %in% names(df)) {
    icd <- gsub("[^A-Za-z0-9]", "", as.character(df$icd10))
    icd[is.na(icd)] <- ""
    nomap <- keep & ty == "DISEASECODE" & !nzchar(icd)
    if (any(nomap))
      stop("CODELIST ERROR: ", csv_name, " has ", sum(nomap), " DISEASECODE ",
           "row(s) with no icd10. This list is graded or grouped by ICD-10 - ",
           "the strict myeloma code, the other-cancer pairing group - and an MDV ",
           "disease code says neither on its own. Fill icd10 with the code it ",
           "maps to.", call. = FALSE)
  }
  log_msg("  ", csv_name, ": code types ", paste(sort(unique(ty[keep])), collapse = ", "),
          " on all ", sum(keep), " row(s) that are kept")
  invisible(TRUE)
}

load_codelist_csv <- function(csv_name, col_spec) {
  cfg <- ndmm_config()
  if (!dir.exists(cfg$codelist_dir)) {
    stop(glue("CODELIST ERROR: codelist directory does not exist: {cfg$codelist_dir}"))
  }
  csv_path <- file.path(cfg$codelist_dir, csv_name)
  if (!file.exists(csv_path)) {
    stop(glue("CODELIST ERROR: required CSV file not found: {csv_path}"))
  }
  if (!csv_name %in% CODELIST_FILES)
    stop("CODELIST ERROR: ", csv_name, " is not one of the files this build is ",
         "defined on: ", paste(CODELIST_FILES, collapse = ", "), call. = FALSE)
  # The code lists live outside version control, so the name alone does not say which
  # version a run used. Hash it, and hash it again after the read: if it were
  # swapped mid-read the logged hash would describe a file we did not load.
  md5 <- unname(tools::md5sum(csv_path))
  # NA when the file could not be opened for hashing. Left alone, the re-hash
  # below would compare NA with NA and pass - so the swap check would be
  # silently off - and 'NA' would be written to LOT_CODELIST_METADATA in the
  # shape of a hash. grepl is FALSE on NA, so this covers both.
  if (!grepl("^[0-9a-f]{32}$", md5))
    stop("CODELIST ERROR: could not hash ", csv_name, ", so this run cannot ",
         "record or re-check which version of it was read", call. = FALSE)
  # colClasses: without it R reads a code as a number and drops leading zeros.
  df <- read.csv(csv_path, stringsAsFactors = FALSE, na.strings = c("", "NA", "NaN"),
                 colClasses = "character")
  if (!identical(md5, unname(tools::md5sum(csv_path))))
    stop("CODELIST ERROR: ", csv_name, " changed while it was being read",
         call. = FALSE)
  log_msg("  CSV columns in ", csv_name, ": ", paste(names(df), collapse = ", "))
  missing <- setdiff(col_spec, names(df))
  if (length(missing) > 0) {
    stop(glue("CODELIST ERROR: CSV {csv_name} missing required columns: {paste(missing, collapse=', ')}. Found: {paste(names(df), collapse=', ')}"))
  }
  df <- df[, col_spec, drop = FALSE]
  if (nrow(df) == 0) {
    stop(glue("CODELIST ERROR: CSV {csv_name} has no data rows"))
  }
  # Before a row reaches SQL, where a type nothing reads would match nothing.
  if ("code_type" %in% names(df)) check_code_types(df, csv_name, "code_type", "code")
  if ("CL_CODE_TYPE" %in% names(df)) check_code_types(df, csv_name, "CL_CODE_TYPE", "CL_CODE")
  esc <- function(x) {
    if (is.na(x) || is.null(x) || x == "") return("NULL")
    x <- gsub("'", "''", as.character(x))
    paste0("'", x, "'")
  }
  rows <- apply(df, 1, function(r) paste0("(", paste(vapply(r, esc, character(1)), collapse = ", "), ")"))
  sql <- paste0("SELECT * FROM (VALUES\n  ", paste(rows, collapse = ",\n  "), "\n) AS t(",
                paste(col_spec, collapse = ", "), ")")
  # Kept for LOT_CODELIST_METADATA, so the outputs say which version built them.
  seen <- getOption("ndmm_codelist_md5", list())
  seen[[csv_name]] <- list(md5 = md5, n_rows = nrow(df))
  options(ndmm_codelist_md5 = seen)
  log_msg("Loaded codelist from CSV: ", csv_path, " (", nrow(df), " rows, md5 ",
          md5, ")")
  paste0("(", sql, ") src")
}
