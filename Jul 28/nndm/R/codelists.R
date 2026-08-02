# CSV-only code list loading.
# The CSV in cfg$codelist_dir is required; there is no embedded fallback.

# The four files this build reads: mm_dx.csv identifies the MM diagnosis
# that defines the population, cl_mma_codelist.csv drives the
# prior-MM-therapy scan, other_malig.csv the other-cancer exclusion, and
# pregnancy.csv the pregnancy exclusion. Anything else is a typo, not a code
# list. tests/test_runner.R reads the load_codelist_csv() calls out of R/ and
# requires every file they name to be here - this list was short by
# other_malig.csv, which made every production run fail inside step 4.
CODELIST_FILES <- c("cl_mma_codelist.csv", "mm_dx.csv", "other_malig.csv",
                    "pregnancy.csv")

# What the icd_family column may say, both ways round.
#
# The normalising CASE has no third branch: anything that is not one of the
# ICD-9 spellings becomes ICD10. Both code lists carrying this column are
# joined to claims on family as well as on code, so a row whose family is
# blank, NULL, or spelled some way nobody anticipated is classed ICD10 and then
# matches no ICD-9 claim. It does not error and it does not warn - it quietly
# stops doing anything. On mm_dx.csv that is a diagnosis code that qualifies
# nobody; on other_malig.csv it is a cancer code that excludes nobody, which
# leaves patients in the cohort who should not be. Nothing downstream can see
# either. So the accepted values are named both ways and checked, rather than
# one list and a catch-all.
ICD_FAMILY_9  <- c("9", "ICD9", "ICD-9", "ICD9DIAG")
ICD_FAMILY_10 <- c("10", "ICD10", "ICD-10", "ICD10DIAG")

# Checked in R as the file is read, before a row of it reaches SQL: it is
# cheaper than a round trip, it fails before anything is built, and every list
# carrying the column gets it without a second call site to remember.
#
# Rows the build drops anyway are not an alarm, so where the file has a dx
# column this looks only at rows carrying one - the same rows the normalising
# SELECT keeps.
check_icd_family <- function(df, csv_name) {
  if (!"icd_family" %in% names(df)) return(invisible(TRUE))
  keep <- if ("dx" %in% names(df))
    !is.na(df$dx) & nzchar(gsub("[^A-Za-z0-9]", "", as.character(df$dx)))
  else rep(TRUE, nrow(df))
  raw  <- trimws(as.character(df$icd_family))
  # read.csv maps "" to NA here, so a blank column and a missing one look alike.
  bad  <- keep & (is.na(raw) | !nzchar(raw) |
                  !(toupper(raw) %in% toupper(c(ICD_FAMILY_9, ICD_FAMILY_10))))
  if (any(bad)) {
    shown <- unique(ifelse(is.na(raw) | !nzchar(raw), "<blank>", raw)[bad])
    stop("CODELIST ERROR: ", csv_name, " has ", sum(bad),
         " row(s) whose icd_family this build does not recognise: ",
         paste(shown, collapse = ", "),
         ".\nAn unrecognised family reads as ICD10, and the code lists are ",
         "joined to claims on family as well as code - so an ICD-9 row spelled ",
         "this way would match no claim and silently stop qualifying or ",
         "excluding anyone. Spell it one of: ",
         paste(c(ICD_FAMILY_9, ICD_FAMILY_10), collapse = ", "), ".",
         call. = FALSE)
  }
  log_msg("  ", csv_name, ": icd_family recognised on all ", sum(keep),
          " row(s) that are kept")
  invisible(TRUE)
}

# Raw claim ICD_FLAG, normalised. Both families are named and anything else is
# NULL - not the other family by default.
#
# Reading "not one of the ICD-9 spellings" as ICD-10 means a NULL
# or unexpected flag on a genuine ICD-9 claim was classed ICD-10 and then failed
# the family join silently: a missed MM diagnosis, or an exclusion claim that
# stopped excluding the patient it should. The codelist column is checked and
# stops the build because that file can be corrected; the CDM's values cannot,
# so this yields NULL, which matches neither family and is the honest answer for
# a row whose family is unknown.
#
# nine/ten are the labels the caller wants: a family column, or the DIAG / PROC
# code_type pairs.
RAW_ICD9  <- c("9", "ICD9", "ICD-9")
RAW_ICD10 <- c("10", "ICD10", "ICD-10")
icd_family_sql <- function(col, nine = "ICD9", ten = "ICD10") {
  q <- function(v) paste(sprintf("'%s'", v), collapse = ", ")
  paste0("CASE WHEN upper(trim(", col, ")) IN (", q(RAW_ICD9), ") THEN '", nine, "'",
         " WHEN upper(trim(", col, ")) IN (", q(RAW_ICD10), ") THEN '", ten, "'",
         " ELSE NULL END")
}

load_codelist_csv <- function(csv_name, col_spec) {
  cfg <- nndm_config()
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
  # The code lists live outside git, so the name alone does not say which
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
  # colClasses: without it R reads an NDC as a number and drops leading zeros.
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
  # Before a row reaches the normalising CASE downstream, whose ELSE is a
  # catch-all that would class an unrecognised family as ICD10.
  check_icd_family(df, csv_name)
  esc <- function(x) {
    if (is.na(x) || is.null(x) || x == "") return("NULL")
    x <- gsub("'", "''", as.character(x))
    paste0("'", x, "'")
  }
  rows <- apply(df, 1, function(r) paste0("(", paste(vapply(r, esc, character(1)), collapse = ", "), ")"))
  sql <- paste0("SELECT * FROM (VALUES\n  ", paste(rows, collapse = ",\n  "), "\n) AS t(",
                paste(col_spec, collapse = ", "), ")")
  # Kept for LOT_CODELIST_METADATA, so the outputs say which version built them.
  seen <- getOption("nndm_codelist_md5", list())
  seen[[csv_name]] <- list(md5 = md5, n_rows = nrow(df))
  options(nndm_codelist_md5 = seen)
  log_msg("Loaded codelist from CSV: ", csv_path, " (", nrow(df), " rows, md5 ",
          md5, ")")
  paste0("(", sql, ") src")
}
