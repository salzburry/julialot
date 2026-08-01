# CSV-only codelist loading, carried over from lot/R/codelists_lot.R.
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

# The per-code answer to a question a tumour-group label cannot answer.
#
# other_malig.csv tags each ICD code with a tumor_group, and the other-cancer
# criterion is decided on that label. For four of the overridden groups the
# label settles it - monoclonal gammopathy, solitary plasmacytoma, plasma cell
# leukemia, extramedullary plasmacytoma are plasma-cell disease, so they are
# the index disease and not another cancer. SECONDARY MALIGNANT NEOPLASM OF
# BONE is not like the others: C79.51 / C79.52 / 198.5 say a cancer spread to
# bone, not which cancer. Myeloma bone disease is usually coded as MM with bone
# involvement, but it is also miscoded here, which is why the source build
# overrides the group - and a breast or prostate primary metastatic to bone
# carries the same code. The label cannot separate those. A code can.
#
# So: one row per ICD code, override = 1 to treat it as the index disease (do
# not exclude) or 0 to treat it as another cancer (do exclude). A row here wins
# over the tumour-group label in both directions. The file ships empty, which
# means the labels decide everything, which is the source build's behaviour.
# NDMM_MM_ADJACENT_CODES lists every code in an overridden group, ready to
# paste in.
#
# Absent is allowed and means the same as empty; unreadable or malformed is
# not, because a file that was meant to be read and silently was not would
# change who is in the cohort with nothing saying so.
OVERRIDE_CSV_COLS <- c("dx", "icd_family", "override", "note")

# The read that both fill-in files share: absent means the shipped default,
# present means hashed, checked for its columns, and recorded whether or not it
# had rows. Hands back NULL for "nothing to apply" and a data frame otherwise,
# so each caller only writes the validation that is its own.
read_optional_csv <- function(path, cols, absent_msg, empty_msg) {
  if (!nzchar(path) || !file.exists(path)) {
    log_msg("  ", absent_msg, " (", path, " not present)")
    return(NULL)
  }
  md5 <- unname(tools::md5sum(path))
  if (!grepl("^[0-9a-f]{32}$", md5))
    stop("CODELIST ERROR: could not hash ", path, ", so this run cannot record ",
         "which version of it was read", call. = FALSE)
  df <- read.csv(path, stringsAsFactors = FALSE, na.strings = c("", "NA", "NaN"),
                 colClasses = "character")
  if (!identical(md5, unname(tools::md5sum(path))))
    stop("CODELIST ERROR: ", path, " changed while it was being read", call. = FALSE)
  miss <- setdiff(cols, names(df))
  if (length(miss))
    stop("CODELIST ERROR: ", path, " is missing ", paste(miss, collapse = ", "),
         ". Columns are: ", paste(cols, collapse = ", "), call. = FALSE)
  df <- df[, cols, drop = FALSE]
  # Recorded even when empty: "this run read the file and it had no rows" and
  # "this run never looked" are different, and only one of them is a decision.
  seen <- getOption("nndm_codelist_md5", list())
  seen[[basename(path)]] <- list(md5 = md5, n_rows = nrow(df))
  options(nndm_codelist_md5 = seen)
  if (nrow(df) == 0) {
    log_msg("  ", empty_msg, " (md5 ", md5, ")")
    return(NULL)
  }
  attr(df, "md5") <- md5
  df
}

load_override_csv <- function(path) {
  df <- read_optional_csv(path, OVERRIDE_CSV_COLS,
    "No per-code MM-adjacent overrides; tumour-group labels decide the other-cancer criterion",
    "Per-code MM-adjacent overrides: none listed")
  if (is.null(df)) return(NULL)
  md5 <- attr(df, "md5")
  # Every field checked before any of it reaches SQL. A row nobody can act on
  # is a typo in a file whose whole purpose is to be exact, so it stops the run
  # rather than being dropped - a dropped row reads as a decision that was made.
  ov <- trimws(df$override)
  bad <- which(!(ov %in% c("0", "1")))
  if (length(bad))
    stop("CODELIST ERROR: ", path, " row(s) ", paste(bad, collapse = ", "),
         ": override must be 0 or 1, got ",
         paste(unique(ov[bad]), collapse = ", "), call. = FALSE)
  fam <- toupper(trimws(df$icd_family))
  fam[fam %in% c("9", "ICD9", "ICD-9", "ICD9DIAG")]  <- "ICD9"
  fam[fam %in% c("10", "ICD10", "ICD-10", "ICD10DIAG")] <- "ICD10"
  bad <- which(!(fam %in% c("ICD9", "ICD10")))
  if (length(bad))
    stop("CODELIST ERROR: ", path, " row(s) ", paste(bad, collapse = ", "),
         ": icd_family must say ICD9 or ICD10, got ",
         paste(unique(df$icd_family[bad]), collapse = ", "), call. = FALSE)
  # Normalised the same way both sides of the join are, and blank after that is
  # the '---' problem: it would match every claim with no diagnosis code.
  dx <- toupper(gsub("[^A-Za-z0-9]", "", trimws(df$dx)))
  bad <- which(is.na(dx) | !nzchar(dx))
  if (length(bad))
    stop("CODELIST ERROR: ", path, " row(s) ", paste(bad, collapse = ", "),
         ": dx is blank once punctuation is stripped", call. = FALSE)
  key <- paste(dx, fam)
  dup <- unique(key[duplicated(key)])
  if (length(dup))
    stop("CODELIST ERROR: ", path, " gives two answers for ",
         paste(dup, collapse = ", "), ". One row per code.", call. = FALSE)
  log_msg("  Per-code MM-adjacent overrides: ", nrow(df), " (",
          sum(ov == "1"), " kept as the index disease, ", sum(ov == "0"),
          " excluded as another cancer), md5 ", md5)
  rows <- sprintf("('%s', '%s', %s)", dx, fam, ov)
  paste0("(SELECT * FROM (VALUES\n  ", paste(rows, collapse = ",\n  "),
         "\n) AS t(dx, icd_family, override)) ovr")
}

# Which agents may set the 1L index. The list S6.2.1.1 gestures at and no
# document in this repository contains.
#
# The protocol says the 1L index is the first claim for an "eligible or
# expected treatment for MM ... other than belantamab". Annex 2 is the
# categorization of SOC regimens, which S6.2.2 calls exemplary and open to
# recategorization - an analysis grouping, not an eligibility rule - and it is
# a stand-alone document. So this build does not invent an allowlist. It reads
# one if the study team writes it down, and until then any MM therapy on
# cl_mma_codelist.csv can set the index, steroids and belantamab aside.
#
# One row per CL_MED_ABBR. eligible = 1 puts the agent on the allowlist,
# eligible = 0 bars it - the same effect as naming it in
# NDMM_INDEX_EXCLUDED_ABBRS, in a file rather than an environment variable.
#
# The modes, and the difference matters:
#   no rows          - no allowlist. Any MM therapy sets the index. This is
#                      what ships, and it is the current cohort.
#   only eligible=0  - a deny list. Everything else still sets the index.
#   any eligible=1   - an ALLOWLIST. Only those agents set the index, and every
#                      other agent on the code list is barred. An agent left
#                      off silently takes its patients out of the cohort at
#                      attrition step 3, so the run says how many it barred.
#
# NDMM_INDEX_AGENTS lists every agent on the code list with how many indexes it
# set, which is the sheet to build this from.
ELIGIBLE_CSV_COLS <- c("med_abbr", "eligible", "note")

load_eligible_agents_csv <- function(path) {
  df <- read_optional_csv(path, ELIGIBLE_CSV_COLS,
    "No eligible-1L agent list; any MM therapy on the code list can set the index",
    "Eligible-1L agent list: no rows, so any MM therapy can set the index")
  if (is.null(df)) return(NULL)
  el <- trimws(df$eligible)
  bad <- which(!(el %in% c("0", "1")))
  if (length(bad))
    stop("CODELIST ERROR: ", path, " row(s) ", paste(bad, collapse = ", "),
         ": eligible must be 0 or 1, got ",
         paste(unique(el[bad]), collapse = ", "), call. = FALSE)
  ab <- toupper(trimws(df$med_abbr))
  bad <- which(is.na(ab) | !nzchar(ab))
  if (length(bad))
    stop("CODELIST ERROR: ", path, " row(s) ", paste(bad, collapse = ", "),
         ": med_abbr is blank", call. = FALSE)
  dup <- unique(ab[duplicated(ab)])
  if (length(dup))
    stop("CODELIST ERROR: ", path, " gives two answers for ",
         paste(dup, collapse = ", "), ". One row per agent.", call. = FALSE)
  out <- list(allow = ab[el == "1"], deny = ab[el == "0"])
  log_msg("  Eligible-1L agent list: ", length(out$allow), " allowed, ",
          length(out$deny), " barred (md5 ", attr(df, "md5"), ")")
  if (length(out$allow))
    log_msg("  ALLOWLIST IN FORCE: only these agents can set a 1L index - ",
            paste(out$allow, collapse = ", "),
            ". Every other agent on cl_mma_codelist.csv is barred, and a ",
            "patient whose only MM therapy is one of those has no index and ",
            "leaves the cohort at attrition step 3.")
  out
}

# One label per ICD code is the wrong grain for "another cancer".
#
# Criterion 7 Path B is two outpatient claims within 30 days for the same
# cancer, and this build pairs them on other_malig.csv's tumor_group. That
# column carries one label per ICD code, and a label is a code description, not
# a tumour type - "PLASMA CELL LEUKEMIA IN REMISSION" and "PLASMA CELL LEUKEMIA
# NOT HAVING ACHIEVED REMISSION" are two labels for one disease, and a solid
# tumour coded at two subsites is two more. Claims that should confirm each
# other land in different labels, never pair, and the patient is not excluded.
# The criterion under-detects, so the cohort is too LARGE - which is the
# direction that puts patients in a study they do not belong in.
#
# The real fix is a primary_tumor_group column on the production code list.
# Until there is one: tumor_group, primary_tumor_group, note. Every label
# mapped to the same primary_tumor_group pairs together. Anything unmapped
# stays its own group, so an empty file is the rule the source runs.
#
# NDMM_OTHER_MALIG_GROUPS lists every label on the code list to map from, and
# NDMM_OTHER_MALIG_GRAIN says what the grain is currently costing.
PRIMARY_GROUP_CSV_COLS <- c("tumor_group", "primary_tumor_group", "note")

load_primary_groups_csv <- function(path) {
  df <- read_optional_csv(path, PRIMARY_GROUP_CSV_COLS,
    "No primary-tumour-group map; outpatient pairs must share one code-list label",
    "Primary-tumour-group map: no rows, so each label is its own group")
  if (is.null(df)) return(NULL)
  from <- toupper(trimws(df$tumor_group))
  to   <- toupper(trimws(df$primary_tumor_group))
  bad <- which(is.na(from) | !nzchar(from) | is.na(to) | !nzchar(to))
  if (length(bad))
    stop("CODELIST ERROR: ", path, " row(s) ", paste(bad, collapse = ", "),
         ": tumor_group and primary_tumor_group must both be filled in",
         call. = FALSE)
  dup <- unique(from[duplicated(from)])
  if (length(dup))
    stop("CODELIST ERROR: ", path, " maps ", paste(dup, collapse = ", "),
         " to two primary groups. One row per label.", call. = FALSE)
  log_msg("  Primary-tumour-group map: ", length(from), " label(s) into ",
          length(unique(to)), " group(s), md5 ", attr(df, "md5"))
  rows <- sprintf("('%s', '%s')", gsub("'", "''", from), gsub("'", "''", to))
  # Alias columns named so nothing bare matches the code list's own column
  # names: an unqualified tumor_group with both relations in scope is the
  # correlated-subquery bug this file already had once.
  paste0("(SELECT * FROM (VALUES\n  ", paste(rows, collapse = ",\n  "),
         "\n) AS t(pg_label, pg_primary)) pg")
}

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
