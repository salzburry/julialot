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
all_c <- unlist(unname(SAFETY_CONDITIONS))
ok(length(all_c) == 23L, paste0("Table 2's twenty-three conditions (", length(all_c), ")"))
ok(identical(sort(names(SAFETY_CONDITIONS)), sort(SAFETY_DOMAINS)),
   "...in the five domains it groups them under")
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
ok(length(st$unfilled) == 23L,
   paste0("all twenty-three are still unfilled (", length(st$unfilled), ")"))
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
  s <- mut(s)
  write.csv(s, file.path(tmp, "safety_events.csv"), row.names = FALSE, na = "")
  file.copy(file.path(TPL, "hcru_events.csv"), tmp, overwrite = TRUE)
  # The template's HCRU rows are themselves incomplete, so fill those too or
  # every case below would stop for the wrong reason.
  h2 <- read.csv(file.path(tmp, "hcru_events.csv"), stringsAsFactors = FALSE,
                 colClasses = "character")
  h2$code[!nzchar(h2$code)] <- "21"
  h2$code_type[!nzchar(h2$code_type)] <- "POS"
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

cat("\n", strrep("-", 52), "\n", sep = "")
cat(sprintf("%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
