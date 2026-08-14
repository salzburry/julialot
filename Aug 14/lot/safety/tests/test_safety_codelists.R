#!/usr/bin/env Rscript
# The placeholders hold their shape, and refuse to be read while they are
# placeholders. No warehouse.
#
#   Rscript "lot/safety/tests/test_safety_codelists.R"

ROOT <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                                 fixed = TRUE))) else getwd()
  dirname(d)
})
GROUP <- dirname(ROOT)
STUDY <- dirname(GROUP)

pass <- 0L; fail <- 0L
ok <- function(cond, what) {
  if (isTRUE(cond)) { pass <<- pass + 1L; cat("  ok     ", what, "\n") }
  else              { fail <<- fail + 1L; cat("  FAIL   ", what, "\n") }
}
stops <- function(expr, what) ok(inherits(tryCatch(expr, error = function(e) e), "error"), what)

source(file.path(ROOT, "R", "codelists_safety.R"))
TPL <- file.path(ROOT, "codelists")

cat("\n-- the roster is the protocol's, not a subset of it --\n")
# Table 2, transcribed. A count is not a roster: `length(all_c) == 26L` passes
# on any twenty-six names and pins a shortfall as readily as it catches one.
# The expectation is the list, so a condition enters or leaves only by someone
# editing what the protocol is asserted to say.
TABLE_2 <- list(
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
                     "other_movement_disorders", "seizures"),
  infectious     = c("severe_infection_with_hospitalisation"),
  other          = c("thrombocytopenia", "anemia")
)
all_c <- safety_roster()$condition
ok(setequal(names(SAFETY_CONDITIONS), names(TABLE_2)),
   paste0("Table 2's seven domains, and only those (", length(SAFETY_DOMAINS), ")"))
for (d in names(TABLE_2)) {
  got <- if (is.null(SAFETY_CONDITIONS[[d]])) character(0) else names(SAFETY_CONDITIONS[[d]])
  ok(setequal(got, TABLE_2[[d]]),
     if (setequal(got, TABLE_2[[d]])) paste0("...", d, ": all ", length(TABLE_2[[d]]), " of them")
     else paste0("...", d, " differs from Table 2 - missing: ",
                 paste(setdiff(TABLE_2[[d]], got), collapse = ", "), "; extra: ",
                 paste(setdiff(got, TABLE_2[[d]]), collapse = ", ")))
}
ok(length(all_c) == length(unlist(TABLE_2)),
   paste0("...", length(unlist(TABLE_2)), " conditions in total (", length(all_c), ")"))
ok(!any(duplicated(all_c)), "no condition is listed twice")
ok(length(HCRU_EVENTS) == 4L, "Table 3's four utilisation events")

cat("\n-- the template covers the roster exactly --\n")
st <- safety_fill_status(TPL)
ok(!length(st$absent),
   if (length(st$absent)) paste0("missing from the CSV: ", paste(st$absent, collapse = ", "))
   else "every condition the roster names is a row in the CSV")
ok(!length(st$unknown),
   if (length(st$unknown)) paste0("in the CSV but not the roster: ", paste(st$unknown, collapse = ", "))
   else "and the CSV names none the roster does not")
ok(!length(st$bad_domain), "every row's domain is one of Table 2's")

cat("\n-- and it is a placeholder, which is not a state it can be read in --\n")
ok(length(st$unfilled) == nrow(safety_roster()),
   paste0("every one of them is still unfilled (", length(st$unfilled), ")"))
# The whole point. Zero rows would be indistinguishable from zero events.
stops(safety_codelist(TPL),
      "reading it stops rather than returning an empty list")

cat("\n-- the inpatient rule is the cohort build's, not a second one --\n")
# Two definitions of an inpatient stay in one study is the failure this copy
# exists to avoid, so it is checked against the source rather than trusted.
mm <- paste(readLines(file.path(STUDY, "ndmm", "R", "steps", "00_mm_cohort.R"),
                      warn = FALSE), collapse = "\n")
h <- read.csv(file.path(TPL, "hcru_events.csv"), stringsAsFactors = FALSE,
              colClasses = "character")
ip <- h[h$event == "inpatient_hospitalisation_all_cause" & nzchar(h$code), ]
pos <- ip$code[ip$code_type == "POS"]
tos <- ip$code[ip$code_type == "TOS_CD"]
ok(length(pos) == 3L && all(vapply(pos, function(p) grepl(paste0("'", p, "'"), mm, fixed = TRUE), logical(1))),
   paste0("every POS in the list is one the cohort build calls inpatient (",
          paste(pos, collapse = ", "), ")"))
ok(length(tos) == 4L && all(vapply(tos, function(t) grepl(paste0("'", t, "'"), mm, fixed = TRUE), logical(1))),
   paste0("...and every TOS_CD likewise (", length(tos), ")"))
ok(any(ip$code_type == "CONFINEMENT"),
   "...and a confinement row counts as an admission, as it does there")

cat("\n-- the vocabularies agree with the cohort build's --\n")
cl <- readLines(file.path(STUDY, "ndmm", "R", "codelists.R"), warn = FALSE)
# Whole quoted tokens, then strip the quotes. A lookaround on the quote alone
# also matches the ", " between two of them, which is not a spelling of
# anything and would fail this against itself.
fam <- gsub('"', "", unlist(regmatches(cl, gregexpr('"[^"]*"', cl))[
  grep("^ICD_FAMILY_(9|10)\\s*<-", cl)]))
ok(length(fam) > 0L && all(fam %in% SAFETY_ICD_FAMILY),
   paste0("every icd_family spelling the cohort build accepts is accepted here (",
          length(fam), ")"))
ok(all(UNVERIFIED_CODE_TYPES %in% HCRU_CODE_TYPES),
   "the unverified field names are still in the vocabulary, so a draft row parses")

cat("\n-- a filled list is refused for the quiet reasons too --\n")
tmp <- file.path(tempdir(), "safety_cl"); dir.create(tmp, showWarnings = FALSE)
fill <- function(mut) {
  s <- read.csv(file.path(TPL, "safety_events.csv"), stringsAsFactors = FALSE,
                colClasses = "character")
  s$code_type <- "ICD_DIAG"; s$code <- "C90.0"; s$icd_family <- "ICD10"
  # A filled list is one somebody answered, and an answer says where it came
  # from - so the fixture carries a source_note as a filled row has to.
  s$source_note <- "test fixture, not a real code list"
  s <- mut(s)
  write.csv(s, file.path(tmp, "safety_events.csv"), row.names = FALSE, na = "")
  file.copy(file.path(TPL, "hcru_events.csv"), tmp, overwrite = TRUE)
  # The template's HCRU rows are themselves incomplete, so fill those too or
  # every case below would stop for the wrong reason.
  h2 <- read.csv(file.path(tmp, "hcru_events.csv"), stringsAsFactors = FALSE,
                 colClasses = "character")
  # A filled list is one where the open questions were answered, so the ER
  # placeholders resolve onto a confirmed field rather than being filled where
  # they stand - filling the REV_CD row would be the very thing the read
  # refuses, and this case is about the ones it should accept.
  h2 <- h2[!h2$code_type %in% UNVERIFIED_CODE_TYPES, , drop = FALSE]
  h2$code_type[!nzchar(h2$code_type)] <- "POS"
  h2$code[!nzchar(h2$code)] <- "21"
  write.csv(h2, file.path(tmp, "hcru_events.csv"), row.names = FALSE, na = "")
  tmp
}
ok(!inherits(tryCatch(safety_codelist(fill(identity)), error = function(e) e), "error"),
   "a fully filled list reads")
stops(safety_codelist(fill(function(s) { s$icd_family[1] <- "ICD_10"; s })),
      "...but an icd_family spelling the join would not recognise does not")
stops(safety_codelist(fill(function(s) { s$icd_family[1] <- ""; s })),
      "...nor an ICD_DIAG row with no family, which would match nothing")
stops(safety_codelist(fill(function(s) { s$code_type[1] <- "SNOMED"; s })),
      "...nor a code_type nothing joins to")
stops(safety_codelist(fill(function(s) { s$condition[1] <- "liver_things"; s })),
      "...nor a condition renamed out of the protocol's roster")
stops(safety_codelist(fill(function(s) s[-1, ])),
      "...nor a condition deleted from the file altogether")

cat("\n-- ...and for the semantic ones, which parse perfectly --\n")
# Every case here has codes in it and would load as a finished definition.
# What is wrong is what it measures, not whether it can be read.
stops(safety_codelist(fill(function(s) { s$code_type[1] <- ""; s })),
      "a code with no code_type: the code has nowhere to join")
stops(safety_codelist(fill(function(s) {
        s$domain[s$condition == "chronic_kidney_disease"] <- "cardiovascular"; s })),
      "a condition filed under a domain the protocol does not put it in")
stops(safety_codelist(fill(function(s) {
        s$acute_chronic[s$condition == "chronic_kidney_disease"] <- "acute"; s })),
      "a condition relabelled acute when Table 2 calls it chronic")
mfill <- function(mut) {
  d <- fill(identity)
  h2 <- read.csv(file.path(d, "hcru_events.csv"), stringsAsFactors = FALSE,
                 colClasses = "character")
  write.csv(mut(h2), file.path(d, "hcru_events.csv"), row.names = FALSE, na = "")
  d
}
stops(safety_codelist(mfill(function(h2) {
        h2$measure[h2$event == "er_visit"] <- "length_of_stay"; h2 })),
      "a utilisation event measuring something Table 3 does not ask of it")

cat("\n-- a placeholder on an unconfirmed field may be drafted, not run --\n")
# The gap between draftable and runnable is where this goes wrong quietly: a
# filled row looks exactly like a finished one, so REV_CD codes would read as
# ready and then join to nothing, because no CDM table surfaces the column.
ok(all(c("PROC", "REV_CD") %in% UNVERIFIED_CODE_TYPES),
   "PROC and REV_CD are draftable")
ok("REV_CD" %in% HCRU_CODE_TYPES,
   "...so an empty REV_CD placeholder row is a legal row")
tpl_h <- read.csv(file.path(TPL, "hcru_events.csv"), stringsAsFactors = FALSE,
                  colClasses = "character")
er <- tpl_h[tpl_h$event == "er_visit", ]
ok(nrow(er) >= 2 && all(!nzchar(er$code)) &&
     all(c("POS", "TOS_CD") %in% er$code_type),
   paste0("the ER placeholder says where its codes go before it has any (",
          paste(er$code_type, collapse = ", "), ")"))
ok(!length(safety_fill_status(TPL)$unverified),
   "an empty placeholder is not flagged as an unconfirmed definition")
ok("REV_CD" %in% safety_fill_status(TPL)$drafted,
   "...but it is reported as drafted on one, so it is not invisible")
# And the moment it carries a code it stops being a placeholder.
stops(safety_codelist(fill(function(s) { s$code_type[1] <- "PROC"; s })),
      "a FILLED row on an unconfirmed field stops the read")

cat("\n-- the documented command agrees with the read it is gating --\n")
# Everything above tests safety_codelist(). What anyone actually runs is
# run_safety_codelists.R. Decided separately, the two disagree:
# the runner on completeness alone. It would print "*** FILLED against an
# unconfirmed field" and "Ready." two lines apart and exit 0 on a list the
# analysis could not then read. A unit test on the loader cannot see that, so
# this battery runs the real command in a real process and compares its exit
# status against the loader's verdict on the same directory.
#
# The assertion is agreement, not a list of exit codes, so a check added to the
# loader later is covered here the day it lands rather than the day someone
# remembers to add a case for it.
RSCRIPT <- file.path(R.home("bin"), "Rscript")
CLI <- file.path(ROOT, "run_safety_codelists.R")
cli_exit <- function(dir)
  # shQuote on the env value as well as the script: system2() prefixes the
  # command with `env NAME=VALUE` verbatim, so an unquoted path with a space in
  # it splits and the shell reports 127 - which is nonzero, and would have read
  # as this test passing.
  suppressWarnings(system2(RSCRIPT, shQuote(CLI), stdout = NULL, stderr = NULL,
                           env = paste0("CODELIST_DIR=", shQuote(dir))))
agrees <- function(dir, what) {
  refused <- inherits(tryCatch(safety_codelist(dir), error = function(e) e), "error")
  rc <- cli_exit(dir)
  ok(refused == (rc != 0L),
     paste0(what, " - loader ", if (refused) "refuses" else "reads",
            ", command exits ", rc))
}
both <- function(smut = identity, hmut = identity) {
  d <- fill(smut)
  h2 <- read.csv(file.path(d, "hcru_events.csv"), stringsAsFactors = FALSE,
                 colClasses = "character")
  write.csv(hmut(h2), file.path(d, "hcru_events.csv"), row.names = FALSE, na = "")
  d
}
ok(file.exists(CLI), "the command the README documents is where it says it is")
agrees(TPL, "the shipped template, which is a placeholder")
agrees(both(), "a fully filled list")
agrees(both(function(s) { s$code_type[1] <- "REV_CD"; s }),
       "a FILLED row on an unconfirmed field")
agrees(both(function(s) { s$code_type[1] <- "SNOMED"; s }),
       "a code_type nothing joins to")
agrees(both(function(s) { s$code_type[1] <- ""; s }),
       "a code with no code_type at all")
agrees(both(function(s) { s$icd_family[1] <- "ICD_10"; s }),
       "an icd_family the family join would not recognise")
agrees(both(function(s) { s$icd_family[1] <- ""; s }),
       "an ICD_DIAG row with no family")
agrees(both(function(s) {
         s$domain[s$condition == "chronic_kidney_disease"] <- "cardiovascular"; s }),
       "a condition filed under the wrong domain")
agrees(both(function(s) {
         s$acute_chronic[s$condition == "chronic_kidney_disease"] <- "acute"; s }),
       "a condition relabelled acute")
agrees(both(function(s) {
         s$acute_chronic[s$condition == "chronic_kidney_disease"] <- ""; s }),
       "a condition with no acute_chronic at all")
agrees(both(function(s) { s$source_note <- ""; s }),
       "filled codes with no stated source")
agrees(both(function(s) s[-1, ]), "a condition missing from the file")
agrees(both(function(s) { s$condition[1] <- "liver_things"; s }),
       "a condition the protocol does not name")
agrees(both(hmut = function(h2) { h2$measure[h2$event == "er_visit"] <- "count"; h2 }),
       "a utilisation event measuring the wrong thing")
agrees(both(hmut = function(h2) { h2$measure[h2$event == "er_visit"] <- ""; h2 }),
       "a utilisation event with no measure")
agrees(both(hmut = function(h2) { h2$event[nrow(h2)] <- "er_visits"; h2 }),
       "a utilisation event Table 3 does not have")
agrees(both(hmut = function(h2) { h2$precedence[h2$event == "er_visit"] <- ""; h2 }),
       "filled rows that do not say which is the definition")
agrees(both(hmut = function(h2) { h2$precedence[h2$event == "er_visit"] <- "fallback"; h2 }),
       "an event with fallbacks and no primary")
# The way round that check: keep a primary ROW and leave it empty. no_primary
# only asks that one exists, so a filled fallback beside an empty primary read
# as ready - and the fallback then silently became the definition, which is the
# arrangement precedence exists to prevent.
agrees(both(hmut = function(h2) {
         h2 <- h2[h2$event != "er_visit", , drop = FALSE]
         rbind(h2,
           data.frame(event = "er_visit", measure = "count_and_category",
                      precedence = "primary", code_type = "POS", code = "",
                      source_note = "PLACEHOLDER", stringsAsFactors = FALSE),
           data.frame(event = "er_visit", measure = "count_and_category",
                      precedence = "fallback", code_type = "TOS_CD",
                      code = "99281", source_note = "filled",
                      stringsAsFactors = FALSE)) }),
       "a filled fallback beside an EMPTY primary")
agrees(both(hmut = function(h2) {
         h2$code_type[h2$event == "er_visit"] <- "CONFINEMENT"; h2 }),
       "an ER visit counted off the hospitalisation table")
# A code list is joined to claims, so a duplicated code returns the matching
# claim once per copy. It is also how two people answering the same row
# separately shows up, which is worth seeing rather than silently merging.
agrees(both(function(s) rbind(s, s[1, ])), "the same safety code listed twice")
agrees(both(hmut = function(h2) rbind(h2, h2[1, ])),
       "...and the same utilisation code listed twice")
# Precedence exists so a reader knows which rows are the definition. Two
# primaries on one event is two definitions, said by the column meant to settle
# it - and a reader with no rule for choosing unions them.
agrees(both(hmut = function(h2) rbind(h2, data.frame(
         event = "er_visit", measure = "count_and_category",
         precedence = "primary", code_type = "TOS_CD", code = "99281",
         source_note = "fixture", stringsAsFactors = FALSE))),
       "two primary identification methods for one event")
# Several codes of ONE type are one method, which is what a POS list is.
d <- both(hmut = function(h2) rbind(h2, data.frame(
       event = "er_visit", measure = "count_and_category", precedence = "primary",
       code_type = "POS", code = "24", source_note = "fixture",
       stringsAsFactors = FALSE)))
ok(!inherits(tryCatch(safety_codelist(d), error = function(e) e), "error"),
   "...while several codes of one type are one method, not two")

cat("\n-- and a blank cell is a blank cell everywhere --\n")
# The NA trap these all share: a blank makes `!=` return NA, NA subscripts an
# NA element out, and the !is.na() on the way out drops it - so the check meant
# to catch a mislabelled row lets an unlabelled one through.
d <- both(function(s) { s$acute_chronic[2] <- "  "; s })
ok(length(safety_fill_status(d)$no_ac) == 1L,
   "whitespace in acute_chronic is blank, not a value that happens to differ")
d <- both(function(s) { s$code[3] <- " C90.0 "; s })
sd <- safety_read_csv("safety_events.csv", SAFETY_COLS, d)
ok(identical(sd$df$code[3], "C90.0"),
   "a padded code is trimmed on the way in, so it joins to what it names")

cat("\n", strrep("-", 52), "\n", sep = "")
cat(sprintf("%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
