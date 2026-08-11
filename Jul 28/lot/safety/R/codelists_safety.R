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
# condition = acute/chronic, because Table 2 states both and a condition filed
# under the wrong domain or relabelled acute is not a code-list error - it is a
# different measurement, and it looks exactly like the right one. Holding all
# three together is what lets the CSV be checked rather than merely parsed.
SAFETY_CONDITIONS <- list(
  hepatologic    = c(abnormal_liver_function       = "acute_or_chronic",
                     toxic_liver_disease           = "acute_or_chronic",
                     hepatic_failure               = "acute_or_chronic",
                     chronic_hepatitis             = "chronic",
                     acute_hepatitis               = "acute",
                     fibrosis_and_cirrhosis        = "chronic",
                     non_alcoholic_steatohepatitis = "chronic"),
  renal          = c(acute_kidney_injury_or_acute_kidney_disease = "acute",
                     chronic_kidney_disease                      = "chronic",
                     moderate_to_severe_renal_impairment_or_esrd = "chronic"),
  ocular         = c(corneal_ulcer = "acute",
                     keratopathies = "acute"),
  cardiovascular = c(myocardial_infarction_or_unstable_angina     = "acute",
                     valvopathy                                   = "chronic",
                     pulmonary_hypertension                       = "chronic",
                     cerebrovascular_event_stroke_or_tia          = "acute",
                     peripheral_arterial_thromboembolism          = "acute",
                     deep_venous_thrombosis_or_pulmonary_embolism = "acute"),
  neurologic     = c(peripheral_neuropathy            = "chronic",
                     parkinsons_disease               = "chronic",
                     cognitive_impairment_or_dementia = "chronic",
                     other_movement_disorders         = "chronic",
                     seizures                         = "chronic")
)
SAFETY_TIMING <- "baseline and follow-up, at 1L, 2L and 3L"

# The domain and acute/chronic each condition belongs to, flattened, so a row
# can be checked against the roster rather than against itself.
safety_roster <- function() {
  do.call(rbind, lapply(SAFETY_DOMAINS, function(d)
    data.frame(domain = d, condition = names(SAFETY_CONDITIONS[[d]]),
               acute_chronic = unname(SAFETY_CONDITIONS[[d]]),
               stringsAsFactors = FALSE)))
}

# Table 3's utilisation rows. Identified by evidence of a claim rather than by
# diagnosis, so these carry revenue, place-of-service or claim-type codes and
# not ICD - which is why they are a separate file with a separate shape.
# event = the measure Table 3 asks for it. The protocol counts hospitalisations
# and ER visits (0, 1, 2, 3, 4+) and measures length of stay separately for
# all-cause and MM-related stays - so there are two length-of-stay events and
# no MM-related count, which is what the table asks for rather than what the
# symmetry suggests.
HCRU_EVENTS <- c(inpatient_hospitalisation_all_cause = "count_and_category",
                 inpatient_length_of_stay_all_cause  = "length_of_stay",
                 inpatient_length_of_stay_mm_related = "length_of_stay",
                 er_visit                            = "count_and_category")

SAFETY_CODELIST_FILES <- c("safety_events.csv", "hcru_events.csv")
SAFETY_COLS <- c("domain", "condition", "acute_chronic", "code_type", "code",
                 "icd_family", "source_note")
HCRU_COLS   <- c("event", "measure", "code_type", "code", "source_note")

# What a code_type may say, and which Optum CDM table it lands on. Checked
# against the Optum data dictionary and business rules rather than assumed: a
# code_type with no table behind it is a row that matches nothing, which is the
# same failure as an empty code and just as invisible.
#
#   ICD_DIAG      MED_DIAGNOSIS. Paired with icd_family, because ICD_FLAG is
#                 what distinguishes ICD-9 from ICD-10 on the claim.
#   PROC          MED_PROCEDURE. CPT/HCPCS - PROC_CD, or BILL_PROC_CD where the
#                 client supplied it for billing.
#   POS           MEDICAL POS    - the place the service was performed.
#   TOS_CD        MEDICAL TOS_CD - type of service. TOS_EXT is the same thing at
#                 its most specific, if a finer split is ever wanted.
#   CONFINEMENT   CONFINEMENT, which carries one unduplicated row per
#                 hospitalisation - so a row is an admission, and LOS is a
#                 column rather than a subtraction.
#
#   REV_CD        a revenue code. Optum derives ICU_IND, MATERNITY_IND and
#                 NEWBORN_IND from revenue codes, so they exist upstream, but
#                 no table in the dictionary surfaces a column to join on.
#                 Draftable, not runnable - see UNVERIFIED_CODE_TYPES.
SAFETY_CODE_TYPES <- c("ICD_DIAG", "PROC")
HCRU_CODE_TYPES   <- c("POS", "TOS_CD", "CONFINEMENT", "PROC", "REV_CD")

# In the vocabulary so a list can be drafted against them, but not confirmed to
# be queryable: PROC is a real column nothing in this study reads yet, and
# REV_CD is a field the dictionary never surfaces at all.
#
# Draftable and runnable are different states, and the gap between them is
# where this would go wrong quietly. A drafted row looks exactly like a finished
# one - it has codes in it - so left alone it would read as ready and then match
# nothing. An EMPTY row carrying one of these is fine and expected; a FILLED one
# stops the read until the field is confirmed, and the runner says which.
UNVERIFIED_CODE_TYPES <- c("PROC", "REV_CD")

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
  want <- safety_roster()$condition
  s <- safety_read_csv("safety_events.csv", SAFETY_COLS, codelist_dir)
  h <- safety_read_csv("hcru_events.csv",   HCRU_COLS,   codelist_dir)

  filled <- function(x) !is.na(x) & nzchar(trimws(x))
  n_codes <- vapply(want, function(c_i)
    sum(s$df$condition == c_i & filled(s$df$code)), integer(1))
  n_hcru <- vapply(names(HCRU_EVENTS), function(e)
    sum(h$df$event == e & filled(h$df$code)), integer(1))

  # A filled row whose code_type nothing joins to, or whose icd_family is
  # spelled a way the family join does not recognise. Both match no claim and
  # neither errors downstream - the exact silent-zero this file exists to stop.
  sf <- s$df[filled(s$df$code), , drop = FALSE]
  hf <- h$df[filled(h$df$code), , drop = FALSE]
  # A blank code_type reads as NA, and NA is not in any vocabulary - so it
  # lands in bad_type and would then be dropped by the is.na() filter below,
  # letting a code with nowhere to join count as a finished definition. That is
  # the silent zero this file exists to stop, arriving through the check meant
  # to stop it. Counted separately, before anything can discard it.
  no_type <- sum(!filled(sf$code_type)) + sum(!filled(hf$code_type))
  bad_type <- unique(c(sf$code_type[filled(sf$code_type) &
                                      !sf$code_type %in% SAFETY_CODE_TYPES],
                       hf$code_type[filled(hf$code_type) &
                                      !hf$code_type %in% HCRU_CODE_TYPES]))
  # The roster, held against the file. A condition filed under another domain
  # or relabelled acute still has codes and still parses; it measures something
  # the protocol did not ask for, under a name that says it did.
  ros <- safety_roster()
  m <- merge(s$df[, c("domain", "condition", "acute_chronic")], ros,
             by = "condition", all.x = TRUE, suffixes = c("", "_want"))
  wrong_domain <- unique(m$condition[!is.na(m$domain_want) &
                                       m$domain != m$domain_want])
  wrong_ac <- unique(m$condition[!is.na(m$acute_chronic_want) &
                                   m$acute_chronic != m$acute_chronic_want])
  wrong_measure <- unique(h$df$event[h$df$event %in% names(HCRU_EVENTS) &
                                       h$df$measure != HCRU_EVENTS[h$df$event]])
  bad_family <- unique(sf$icd_family[filled(sf$icd_family) &
                                       !sf$icd_family %in% SAFETY_ICD_FAMILY])
  # ICD_DIAG is joined on family as well as code, so a blank family is not a
  # missing label - it is a row that matches nothing.
  no_family <- sum(sf$code_type == "ICD_DIAG" & !filled(sf$icd_family))

  list(
    safety_md5 = s$md5, hcru_md5 = h$md5,
    safety_path = s$path, hcru_path = h$path,
    bad_type = bad_type[!is.na(bad_type)],
    no_type = no_type,
    wrong_domain = wrong_domain[!is.na(wrong_domain)],
    wrong_ac = wrong_ac[!is.na(wrong_ac)],
    wrong_measure = wrong_measure[!is.na(wrong_measure)],
    bad_family = bad_family[!is.na(bad_family)],
    no_family = no_family,
    # Filled rows only. An empty placeholder row carrying one of these is the
    # point of the placeholder; a filled one is a definition that cannot run.
    unverified = intersect(unique(c(sf$code_type, hf$code_type)),
                           UNVERIFIED_CODE_TYPES),
    # Every code type the file draws on, filled or not, so the runner can show
    # a placeholder's intended shape rather than an empty line.
    drafted = intersect(unique(c(s$df$code_type, h$df$code_type)),
                        UNVERIFIED_CODE_TYPES),
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
  if (st$no_type > 0L)
    stop("CODELIST ERROR: ", st$no_type, " row(s) have a code and no ",
         "code_type. The code has nowhere to join, so it matches nothing and ",
         "reports zero rather than failing.", call. = FALSE)
  if (length(st$bad_type))
    stop("CODELIST ERROR: code_type(s) nothing joins to: ",
         paste(st$bad_type, collapse = ", "), ". A row carrying one matches no ",
         "claim and reports zero rather than failing.", call. = FALSE)
  if (length(st$wrong_domain))
    stop("CODELIST ERROR: condition(s) filed under a domain the protocol does ",
         "not put them in: ", paste(st$wrong_domain, collapse = ", "),
         ". The codes may be right and the measurement would still be ",
         "reported under the wrong heading.", call. = FALSE)
  if (length(st$wrong_ac))
    stop("CODELIST ERROR: condition(s) whose acute_chronic differs from ",
         "Table 2: ", paste(st$wrong_ac, collapse = ", "), call. = FALSE)
  if (length(st$wrong_measure))
    stop("CODELIST ERROR: utilisation event(s) whose measure is not the one ",
         "Table 3 asks for: ", paste(st$wrong_measure, collapse = ", "),
         call. = FALSE)
  if (length(st$bad_family))
    stop("CODELIST ERROR: icd_family spelled a way the family join does not ",
         "recognise: ", paste(st$bad_family, collapse = ", "), ". Accepted: ",
         paste(SAFETY_ICD_FAMILY, collapse = ", "), call. = FALSE)
  if (st$no_family > 0L)
    stop("CODELIST ERROR: ", st$no_family, " ICD_DIAG row(s) have no ",
         "icd_family. The join is on family as well as code, so those match ",
         "nothing.", call. = FALSE)
  # Drafted against a field that has not been confirmed queryable. The codes may
  # be right; there is nowhere to join them, so a rate built on them would be
  # zero for want of a column.
  if (length(st$unverified))
    stop("CODELIST ERROR: filled row(s) use code type(s) not confirmed against ",
         "the data dictionary: ", paste(st$unverified, collapse = ", "),
         ". Confirm the field is exposed and on which table, or leave the rows ",
         "empty as placeholders.", call. = FALSE)
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
