# Code list loading for the protocol's key safety events and healthcare
# utilisation events.
#
# The codes are not here and are not in this repository. They come from a CSV in
# cfg$codelist_dir, the same mounted path every other build reads, hashed before
# and after the read so a run records which version it used. What IS here is the
# roster: which conditions the protocol names, which the CSV has to cover, and
# what the file has to look like.
#
# That split is the point. The protocol's Table 2 says WHICH conditions are
# measured; the annex and the Optum documentation say WHICH CODES each one is.
# The first is settled and belongs in version control, so a condition cannot be
# dropped from the study by being dropped from a spreadsheet. The second is not
# settled yet, so it stays where every other code list lives.
#
# Until the codes arrive the file is a placeholder, and a placeholder must not
# be able to produce a number. A condition with no codes matches no claim, and a
# rate built on it is not a low rate - it is no measurement at all, reported as
# though it were one. So an unfilled condition stops the read rather than
# returning zero rows, and the run says which conditions are still empty.

# The protocol's Table 2, as a roster. Timing is the same for all of them -
# baseline and follow-up, at 1L, 2L and 3L - so it is stated once here rather
# than repeated on twenty-three rows where it could drift.
SAFETY_DOMAINS <- c("hepatologic", "renal", "ocular", "cardiovascular",
                    "neurologic")
SAFETY_CONDITIONS <- list(
  hepatologic    = c("abnormal_liver_function", "toxic_liver_disease",
                     "hepatic_failure", "chronic_hepatitis", "acute_hepatitis",
                     "fibrosis_and_cirrhosis", "non_alcoholic_steatohepatitis"),
  renal          = c("acute_kidney_injury_or_acute_kidney_disease",
                     "chronic_kidney_disease",
                     "moderate_to_severe_renal_impairment_or_esrd"),
  ocular         = c("corneal_ulcer", "keratopathies"),
  cardiovascular = c("myocardial_infarction_or_unstable_angina", "valvopathy",
                     "pulmonary_hypertension",
                     "cerebrovascular_event_stroke_or_tia",
                     "peripheral_arterial_thromboembolism",
                     "deep_venous_thrombosis_or_pulmonary_embolism"),
  neurologic     = c("peripheral_neuropathy", "parkinsons_disease",
                     "cognitive_impairment_or_dementia",
                     "other_movement_disorders", "seizures")
)
SAFETY_TIMING <- "baseline and follow-up, at 1L, 2L and 3L"

# Table 3's utilisation rows. Identified by evidence of a claim rather than by
# diagnosis, so these carry revenue, place-of-service or claim-type codes and
# not ICD - which is why they are a separate file with a separate shape.
HCRU_EVENTS <- c("inpatient_hospitalisation_all_cause",
                 "inpatient_hospitalisation_mm_related",
                 "inpatient_length_of_stay_all_cause",
                 "er_visit")

SAFETY_CODELIST_FILES <- c("safety_events.csv", "hcru_events.csv")
SAFETY_COLS <- c("domain", "condition", "acute_chronic", "code_type", "code",
                 "icd_family", "source_note")
HCRU_COLS   <- c("event", "measure", "code_type", "code", "source_note")

# What a code_type may say, and which Optum CDM field it lands on. Taken from
# the fields this study already queries rather than from the data dictionary at
# large: a code_type nothing joins to is a row that matches nothing, which is
# the same failure as an empty code and just as invisible.
#
#   ICD_DIAG      the diagnosis table's code, paired with icd_family
#   POS           medical claim POS        - place of service
#   TOS_CD        medical claim TOS_CD     - type of service
#   CONFINEMENT   the confinement table itself: CONF_ID is an admission, and
#                 ADMIT_DATE / DISCH_DATE are the stay
#   REV_CD        revenue code. PENDING: this study does not read a revenue
#                 code field today, so its presence has to be confirmed against
#                 the data dictionary before a row using it can be trusted.
#   PROC          CPT/HCPCS procedure. PENDING for the same reason.
SAFETY_CODE_TYPES <- c("ICD_DIAG")
HCRU_CODE_TYPES   <- c("POS", "TOS_CD", "CONFINEMENT", "REV_CD", "PROC")
# Not read by anything this study runs today. A row carrying one is accepted so
# the list can be drafted, and named by the runner so it is not mistaken for a
# definition that already works.
UNVERIFIED_CODE_TYPES <- c("REV_CD", "PROC")

# The spellings the cohort build accepts on a code list's icd_family column.
# Repeated here rather than imported because this package does not read the
# cohort build - but they have to agree, so tests/test_safety_codelists.R reads
# them out of ndmm/R/codelists.R and fails if they drift.
SAFETY_ICD_FAMILY <- c("9", "ICD9", "ICD-9", "ICD9DIAG",
                       "10", "ICD10", "ICD-10", "ICD10DIAG")

# Same reading contract as every other package here: the directory has to
# exist, the file has to be one this build is defined on, and it is hashed
# either side of the read so a swap mid-read cannot go unnoticed.
safety_read_csv <- function(csv_name, col_spec, codelist_dir) {
  if (!dir.exists(codelist_dir))
    stop("CODELIST ERROR: codelist directory does not exist: ", codelist_dir,
         call. = FALSE)
  if (!csv_name %in% SAFETY_CODELIST_FILES)
    stop("CODELIST ERROR: ", csv_name, " is not one of the files this build is ",
         "defined on: ", paste(SAFETY_CODELIST_FILES, collapse = ", "),
         call. = FALSE)
  csv_path <- file.path(codelist_dir, csv_name)
  if (!file.exists(csv_path))
    stop("CODELIST ERROR: required CSV file not found: ", csv_path, call. = FALSE)
  md5 <- unname(tools::md5sum(csv_path))
  # grepl is FALSE on NA, so an unhashable file is caught here rather than
  # comparing NA with NA below and passing with the swap check silently off.
  if (!grepl("^[0-9a-f]{32}$", md5))
    stop("CODELIST ERROR: could not hash ", csv_name, ", so this run cannot ",
         "record or re-check which version of it was read", call. = FALSE)
  # colClasses: an ICD or revenue code read as a number loses its leading zeros.
  df <- read.csv(csv_path, stringsAsFactors = FALSE,
                 na.strings = c("", "NA", "NaN"), colClasses = "character")
  if (!identical(md5, unname(tools::md5sum(csv_path))))
    stop("CODELIST ERROR: ", csv_name, " changed while it was being read",
         call. = FALSE)
  missing <- setdiff(col_spec, names(df))
  if (length(missing))
    stop("CODELIST ERROR: CSV ", csv_name, " missing required columns: ",
         paste(missing, collapse = ", "), ". Found: ",
         paste(names(df), collapse = ", "), call. = FALSE)
  list(df = df[, col_spec, drop = FALSE], md5 = md5, path = csv_path)
}

# What the roster says against what the file carries. Returned rather than
# printed, so the runner can report it and the loader can refuse on it.
safety_fill_status <- function(codelist_dir) {
  want <- unlist(unname(SAFETY_CONDITIONS), use.names = FALSE)
  s <- safety_read_csv("safety_events.csv", SAFETY_COLS, codelist_dir)
  h <- safety_read_csv("hcru_events.csv",   HCRU_COLS,   codelist_dir)

  filled <- function(x) !is.na(x) & nzchar(trimws(x))
  n_codes <- vapply(want, function(c_i)
    sum(s$df$condition == c_i & filled(s$df$code)), integer(1))
  n_hcru <- vapply(HCRU_EVENTS, function(e)
    sum(h$df$event == e & filled(h$df$code)), integer(1))

  # A filled row whose code_type nothing joins to, or whose icd_family is
  # spelled a way the family join does not recognise. Both match no claim and
  # neither errors downstream - the exact silent-zero this file exists to stop.
  sf <- s$df[filled(s$df$code), , drop = FALSE]
  hf <- h$df[filled(h$df$code), , drop = FALSE]
  bad_type <- unique(c(sf$code_type[!sf$code_type %in% SAFETY_CODE_TYPES],
                       hf$code_type[!hf$code_type %in% HCRU_CODE_TYPES]))
  bad_family <- unique(sf$icd_family[filled(sf$icd_family) &
                                       !sf$icd_family %in% SAFETY_ICD_FAMILY])
  # ICD_DIAG is joined on family as well as code, so a blank family is not a
  # missing label - it is a row that matches nothing.
  no_family <- sum(sf$code_type == "ICD_DIAG" & !filled(sf$icd_family))

  list(
    safety_md5 = s$md5, hcru_md5 = h$md5,
    safety_path = s$path, hcru_path = h$path,
    bad_type = bad_type[!is.na(bad_type)],
    bad_family = bad_family[!is.na(bad_family)],
    no_family = no_family,
    unverified = intersect(unique(hf$code_type), UNVERIFIED_CODE_TYPES),
    # A condition the roster names and the file does not mention at all. Worse
    # than an unfilled one: unfilled is visibly not done, absent is invisible.
    absent  = setdiff(want, s$df$condition),
    unknown = setdiff(unique(s$df$condition), want),
    bad_domain = unique(s$df$domain[!s$df$domain %in% SAFETY_DOMAINS]),
    n_codes = n_codes, n_hcru = n_hcru,
    unfilled = names(n_codes)[n_codes == 0L],
    hcru_unfilled = names(n_hcru)[n_hcru == 0L]
  )
}

# The read the analysis would do. It refuses while anything is a placeholder,
# and names what is missing rather than saying the file is not ready: the whole
# reason to hold the roster in code is to be able to say which twenty-three.
safety_codelist <- function(codelist_dir) {
  st <- safety_fill_status(codelist_dir)
  if (length(st$absent))
    stop("CODELIST ERROR: safety_events.csv does not mention ",
         length(st$absent), " condition(s) the protocol names: ",
         paste(st$absent, collapse = ", "), call. = FALSE)
  if (length(st$unknown))
    stop("CODELIST ERROR: safety_events.csv names ", length(st$unknown),
         " condition(s) the protocol does not: ",
         paste(st$unknown, collapse = ", "),
         ". Add it to the roster deliberately or correct the spelling.",
         call. = FALSE)
  if (length(st$bad_domain))
    stop("CODELIST ERROR: safety_events.csv has domain(s) outside Table 2: ",
         paste(st$bad_domain, collapse = ", "), call. = FALSE)
  if (length(st$bad_type))
    stop("CODELIST ERROR: code_type(s) nothing joins to: ",
         paste(st$bad_type, collapse = ", "), ". A row carrying one matches no ",
         "claim and reports zero rather than failing.", call. = FALSE)
  if (length(st$bad_family))
    stop("CODELIST ERROR: icd_family spelled a way the family join does not ",
         "recognise: ", paste(st$bad_family, collapse = ", "), ". Accepted: ",
         paste(SAFETY_ICD_FAMILY, collapse = ", "), call. = FALSE)
  if (st$no_family > 0L)
    stop("CODELIST ERROR: ", st$no_family, " ICD_DIAG row(s) have no ",
         "icd_family. The join is on family as well as code, so those match ",
         "nothing.", call. = FALSE)
  if (length(st$unfilled))
    stop("CODELIST ERROR: ", length(st$unfilled), " of ",
         length(unlist(unname(SAFETY_CONDITIONS))),
         " conditions still have no codes, so a rate for them would be zero ",
         "for want of a code list rather than for want of events: ",
         paste(st$unfilled, collapse = ", "), call. = FALSE)
  if (length(st$hcru_unfilled))
    stop("CODELIST ERROR: ", length(st$hcru_unfilled),
         " utilisation event(s) still have no codes: ",
         paste(st$hcru_unfilled, collapse = ", "), call. = FALSE)
  st
}
