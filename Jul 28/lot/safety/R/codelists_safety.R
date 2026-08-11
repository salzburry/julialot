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
# than repeated on twenty-six rows where it could drift.
SAFETY_DOMAINS <- c("hepatologic", "renal", "ocular", "cardiovascular",
                    "neurologic", "infectious", "other")
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
                     seizures                         = "chronic"),
  # Table 3's category list names the same seven independently: hepatologic,
  # renal, serious infection, ocular, cardiovascular, neurologic, other.
  infectious     = c(severe_infection_with_hospitalisation = "acute"),
  # Table 2 heads this group "Other (dependent on data availability)". The
  # dependency is on the data, so they are rostered like the rest and
  # availability is answered by running the codes.
  other          = c(thrombocytopenia = "chronic",
                     anemia           = "chronic")
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
HCRU_COLS   <- c("event", "measure", "precedence", "code_type", "code",
                 "source_note")

# Which rows are the definition and which are the alternative. A utilisation
# event can be identified more than one way - an admission is a CONFINEMENT row
# or, failing that, a claim carrying an inpatient POS - and the two are not
# additive. Unmarked, a reader has no way to tell a second definition from a
# second code, so the obvious read is to union them and count every admission
# twice. Marking it is the difference between a list that says what it means and
# one that happens to be read correctly.
HCRU_PRECEDENCE <- c("primary", "fallback")

# Which code types each event may be identified on. A type can be valid for the
# file and wrong for the row: LOS is a column on CONFINEMENT and on no other
# table, so a length of stay drafted on POS has nothing to measure; and an ER
# visit counted off CONFINEMENT counts admissions, because a confinement row is
# a hospitalisation - an ER visit that became one is in there and an ER visit
# that did not is not. Both parse, both join, and both answer a different
# question than the one Table 3 asks.
HCRU_EVENT_CODE_TYPES <- list(
  inpatient_hospitalisation_all_cause = c("CONFINEMENT", "POS", "TOS_CD",
                                          "REV_CD"),
  inpatient_length_of_stay_all_cause  = "CONFINEMENT",
  inpatient_length_of_stay_mm_related = "CONFINEMENT",
  er_visit                            = c("POS", "TOS_CD", "REV_CD")
)

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
  # Trimmed on the way in, and a cell left empty by trimming is empty. A code
  # cell of " C90.00" is filled by every test below and joins to nothing, which
  # is this file's own failure mode arriving through a stray keystroke; and a
  # cell of "   " has to read as blank everywhere, not as blank in one check and
  # present in the next. The file on disk is unchanged and its md5 is recorded,
  # so what was read is still recoverable.
  df[] <- lapply(df, function(x) {
    x <- trimws(x)
    x[!is.na(x) & !nzchar(x)] <- NA_character_
    x
  })
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
  #
  # Every comparison here is NA-safe, and that is not defensive tidying. A blank
  # cell makes `!=` return NA, NA used as a subscript yields an NA element, and
  # the !is.na() on the way out drops it - so the check that exists to catch a
  # mislabelled condition passes an unlabelled one, which is strictly worse.
  # differs() reads a blank as different, and the blank is then named on its own.
  differs <- function(got, want) !is.na(want) & (is.na(got) | got != want)
  blank_on <- function(got, want) !is.na(want) & is.na(got)
  ros <- safety_roster()
  m <- merge(s$df[, c("domain", "condition", "acute_chronic")], ros,
             by = "condition", all.x = TRUE, suffixes = c("", "_want"))
  wrong_domain <- unique(m$condition[differs(m$domain, m$domain_want)])
  wrong_ac  <- unique(m$condition[differs(m$acute_chronic, m$acute_chronic_want)])
  no_ac     <- unique(m$condition[blank_on(m$acute_chronic, m$acute_chronic_want)])
  # Named separately from wrong_ac: "labelled acute where Table 2 says chronic"
  # and "not labelled at all" need different corrections, and rolling the second
  # into the first would report a value the row does not have.
  wrong_ac  <- setdiff(wrong_ac, no_ac)
  know <- HCRU_EVENTS[h$df$event]
  wrong_measure <- unique(h$df$event[differs(h$df$measure, know)])
  no_measure    <- unique(h$df$event[blank_on(h$df$measure, know)])
  wrong_measure <- setdiff(wrong_measure, no_measure)
  # An event name the protocol's Table 3 does not have. Its rows are counted
  # towards nothing, so a misspelling silently removes codes from the event it
  # was meant to fill - the same asymmetry safety_events.csv already checks for
  # with `unknown`.
  unknown_hcru <- setdiff(unique(h$df$event), names(HCRU_EVENTS))
  # Which rows are the definition and which the alternative, on filled rows -
  # an empty placeholder can carry it and should, but cannot be required to.
  bad_prec <- unique(c(h$df$precedence[filled(h$df$precedence) &
                                         !h$df$precedence %in% HCRU_PRECEDENCE]))
  no_prec  <- unique(hf$event[!filled(hf$precedence)])
  # A fallback with nothing to fall back from is not a fallback; it is a second
  # definition of the event with a label that hides it.
  no_primary <- setdiff(
    unique(h$df$event[!is.na(h$df$precedence) & h$df$precedence == "fallback"]),
    unique(h$df$event[!is.na(h$df$precedence) & h$df$precedence == "primary"]))
  # A filled code with no stated source cannot be checked back against the annex
  # or the dictionary, which is the only way anyone confirms it is right.
  no_source <- sum(!filled(sf$source_note)) + sum(!filled(hf$source_note))
  # The same code twice for the same condition on the same field. Harmless to a
  # DISTINCT read and not harmless to a count: a code list is joined to claims,
  # and a duplicated code returns the matching claim once per copy. It is also
  # how two people answering the same row separately shows up, which is worth
  # seeing rather than merging.
  dup_key <- function(d, cols)
    paste(do.call(paste, c(lapply(cols, function(k) ifelse(is.na(d[[k]]), "", d[[k]])),
                           sep = "|")))
  sk <- dup_key(sf, c("condition", "code_type", "code", "icd_family"))
  hk <- dup_key(hf, c("event", "code_type", "code"))
  dup_codes <- unique(c(sk[duplicated(sk)], hk[duplicated(hk)]))
  # More than one way marked as THE way. Precedence exists so a reader knows
  # which rows are the definition and which the alternative; two primaries on
  # one event is two definitions again, with the column that was meant to
  # settle it saying both.
  hp <- h$df[!is.na(h$df$precedence) & h$df$precedence == "primary", , drop = FALSE]
  # An event whose codes are in but whose PRIMARY row is still empty: the
  # fallback becomes the definition by default, which is what precedence exists
  # to prevent. Asked only of events with any codes, so a wholly empty event is
  # still a placeholder.
  live_ev <- unique(hf$event[!is.na(hf$event)])
  filled_primary <- unique(hf$event[!is.na(hf$precedence) &
                                      hf$precedence == "primary"])
  empty_primary <- setdiff(live_ev, filled_primary)
  # Two primary CODE TYPES for one event - two methods, not two codes. Several
  # POS values are one method; a POS primary beside a CONFINEMENT primary is
  # two, and a reader with no rule for choosing unions them.
  two_primary <- unique(unlist(lapply(unique(hp$event), function(e) {
    ct <- unique(hp$code_type[hp$event %in% e])
    if (length(ct) > 1L) paste0(e, " (", paste(ct, collapse = ", "), ")") else NULL
  })))
  # A code type this file allows, on an event that cannot be identified that
  # way. Checked over every row rather than filled ones: a placeholder drafted
  # on the wrong field is a wrong definition already, and it is cheaper to say
  # so before the codes arrive than after.
  ok_here <- vapply(seq_len(nrow(h$df)), function(i) {
    e <- h$df$event[i]; ct <- h$df$code_type[i]
    if (is.na(e) || !e %in% names(HCRU_EVENT_CODE_TYPES) || is.na(ct)) TRUE
    else ct %in% HCRU_EVENT_CODE_TYPES[[e]]
  }, logical(1))
  # Guarded: paste0() recycles a length-1 separator against a length-0 vector
  # and returns " on " rather than nothing, which would report a violation on
  # every clean file.
  wrong_event_type <- if (any(!ok_here))
    unique(paste0(h$df$event[!ok_here], " on ", h$df$code_type[!ok_here]))
  else character(0)
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
    no_ac = no_ac[!is.na(no_ac)],
    wrong_measure = wrong_measure[!is.na(wrong_measure)],
    no_measure = no_measure[!is.na(no_measure)],
    unknown_hcru = unknown_hcru[!is.na(unknown_hcru)],
    wrong_event_type = wrong_event_type[!is.na(wrong_event_type)],
    bad_precedence = bad_prec[!is.na(bad_prec)],
    no_precedence = no_prec[!is.na(no_prec)],
    no_primary = no_primary[!is.na(no_primary)],
    no_source = no_source,
    dup_codes = dup_codes[!is.na(dup_codes)],
    two_primary = two_primary[!is.na(two_primary)],
    empty_primary = empty_primary[!is.na(empty_primary)],
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
    # A blank domain is NA here, and an NA pasted into a message reads as the
    # literal "NA" - a value no file contains. Named for what it is instead.
    bad_domain = unique(ifelse(is.na(s$df$domain), "(blank)", s$df$domain)[
      !s$df$domain %in% SAFETY_DOMAINS]),
    n_codes = n_codes, n_hcru = n_hcru,
    unfilled = names(n_codes)[n_codes == 0L],
    hcru_unfilled = names(n_hcru)[n_hcru == 0L]
  )
}

# Every reason this list is not fit to measure with, as text, in the order they
# are worth reading. Empty means ready.
#
# It is a function of the status and nothing else, so the loader and the runner
# cannot disagree about what ready means: safety_codelist() refuses on the first
# line this returns, and run_safety_codelists.R prints all of them and exits on
# whether there were any. Deciding it twice is how a runner comes to print
# "*** FILLED against an unconfirmed field" and "Ready." on consecutive lines.
safety_refuse <- function(st) {
  n_all <- length(unlist(unname(SAFETY_CONDITIONS)))
  msg <- character(0)
  add <- function(...) msg <<- c(msg, paste0(...))
  lst <- function(x) paste(x, collapse = ", ")

  if (length(st$absent))
    add("safety_events.csv does not mention ", length(st$absent),
        " condition(s) the protocol names: ", lst(st$absent))
  if (length(st$unknown))
    add("safety_events.csv names ", length(st$unknown),
        " condition(s) the protocol does not: ", lst(st$unknown),
        ". Add it to the roster deliberately or correct the spelling.")
  if (length(st$unknown_hcru))
    add("hcru_events.csv names ", length(st$unknown_hcru),
        " event(s) Table 3 does not: ", lst(st$unknown_hcru),
        ". Their codes count towards no event, so a misspelling empties the ",
        "event it was meant to fill.")
  if (length(st$bad_domain))
    add("safety_events.csv has domain(s) outside Table 2: ", lst(st$bad_domain))
  if (st$no_type > 0L)
    add(st$no_type, " row(s) have a code and no code_type. The code has ",
        "nowhere to join, so it matches nothing and reports zero rather than ",
        "failing.")
  if (length(st$bad_type))
    add("code_type(s) nothing joins to: ", lst(st$bad_type),
        ". A row carrying one matches no claim and reports zero rather than ",
        "failing.")
  if (length(st$wrong_domain))
    add("condition(s) filed under a domain the protocol does not put them in: ",
        lst(st$wrong_domain), ". The codes may be right and the measurement ",
        "would still be reported under the wrong heading.")
  if (length(st$wrong_ac))
    add("condition(s) whose acute_chronic differs from Table 2: ",
        lst(st$wrong_ac))
  if (length(st$no_ac))
    add("condition(s) with no acute_chronic at all: ", lst(st$no_ac),
        ". Table 2 states it for every one, and blank is not one of its values.")
  if (length(st$wrong_measure))
    add("utilisation event(s) whose measure is not the one Table 3 asks for: ",
        lst(st$wrong_measure))
  if (length(st$no_measure))
    add("utilisation event(s) with no measure at all: ", lst(st$no_measure),
        ". A count and a length of stay are different numbers.")
  if (length(st$wrong_event_type))
    add("utilisation event(s) drafted on a code type they cannot be identified ",
        "on: ", lst(st$wrong_event_type),
        ". The type is valid for this file and wrong for that row - it joins, ",
        "and answers a different question than Table 3 asks.")
  if (length(st$bad_precedence))
    add("precedence value(s) outside ", lst(HCRU_PRECEDENCE), ": ",
        lst(st$bad_precedence))
  if (length(st$no_precedence))
    add("utilisation event(s) with filled rows that do not say whether they ",
        "are the definition or the alternative: ", lst(st$no_precedence),
        ". Unmarked, the rows read as one list and every event is counted once ",
        "per way of identifying it.")
  if (length(st$dup_codes))
    add("the same code listed more than once for the same condition or event: ",
        lst(st$dup_codes),
        ". A code list is joined to claims, so a duplicated code returns the ",
        "matching claim once per copy.")
  if (length(st$two_primary))
    add("utilisation event(s) with more than one primary identification ",
        "method: ", lst(st$two_primary),
        ". Precedence exists so a reader knows which rows are the definition; ",
        "two primaries is two definitions, said by the column meant to settle ",
        "it. Several codes of one type are one method - two types are two.")
  if (length(st$empty_primary))
    add("utilisation event(s) whose codes are in but whose primary row is ",
        "still empty: ", lst(st$empty_primary),
        ". The fallback would silently become the definition, which is the ",
        "arrangement precedence exists to prevent. Fill the primary, or mark ",
        "the row that IS the definition as primary.")
  if (length(st$no_primary))
    add("utilisation event(s) with fallback rows and no primary: ",
        lst(st$no_primary),
        ". A fallback with nothing to fall back from is a second definition.")
  if (length(st$bad_family))
    add("icd_family spelled a way the family join does not recognise: ",
        lst(st$bad_family), ". Accepted: ", lst(SAFETY_ICD_FAMILY))
  if (st$no_family > 0L)
    add(st$no_family, " ICD_DIAG row(s) have no icd_family. The join is on ",
        "family as well as code, so those match nothing.")
  if (st$no_source > 0L)
    add(st$no_source, " filled row(s) have no source_note. A code with no ",
        "stated source cannot be checked back against the annex or the ",
        "dictionary, which is the only way anyone confirms it is right.")
  # Drafted against a field that has not been confirmed queryable. The codes may
  # be right; there is nowhere to join them, so a rate built on them would be
  # zero for want of a column.
  if (length(st$unverified))
    add("filled row(s) use code type(s) not confirmed against the data ",
        "dictionary: ", lst(st$unverified), ". Confirm the field is exposed ",
        "and on which table, or leave the rows empty as placeholders.")
  if (length(st$unfilled))
    add(length(st$unfilled), " of ", n_all, " conditions still have no codes, ",
        "so a rate for them would be zero for want of a code list rather than ",
        "for want of events: ", lst(st$unfilled))
  if (length(st$hcru_unfilled))
    add(length(st$hcru_unfilled), " utilisation event(s) still have no codes: ",
        lst(st$hcru_unfilled))
  msg
}

# The read the analysis would do. It refuses while anything is a placeholder,
# and names what is missing rather than saying the file is not ready: the whole
# reason to hold the roster in code is to be able to say which twenty-three.
safety_codelist <- function(codelist_dir) {
  st <- safety_fill_status(codelist_dir)
  bad <- safety_refuse(st)
  if (length(bad))
    stop("CODELIST ERROR: ", bad[1],
         if (length(bad) > 1L)
           paste0(" (and ", length(bad) - 1L, " more - run ",
                  "run_safety_codelists.R for all of them)"),
         call. = FALSE)
  st
}
