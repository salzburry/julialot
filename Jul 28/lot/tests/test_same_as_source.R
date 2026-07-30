#!/usr/bin/env Rscript
# The steps are a port of apr_30_2026/02_lot1.R, not a rewrite. This compares
# them line for line against that file and fails on any difference except the
# one the port is allowed to make.
#
# Skipped when apr_30_2026 is not beside this folder, so a copied-out package
# still runs its other suites.
#
#   Rscript "Jul 28/lot/tests/test_same_as_source.R"

ROOT <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                                 fixed = TRUE))) else getwd()
  dirname(d)
})
source(file.path(ROOT, "tests", "testutil.R"))

SRC <- file.path(dirname(dirname(ROOT)), "apr_30_2026", "02_lot1.R")
if (!file.exists(SRC)) {
  cat("apr_30_2026 not beside this folder -- nothing to compare against. Skipping.\n")
  quit(status = 0L)
}
src <- readLines(SRC, warn = FALSE)

# Where each phase came from. Same ranges the port was cut on; if someone
# re-cuts them, this test is what proves the new cut is still faithful.
PHASES <- list(
  list(file = "01_codelists.R",     from = 77,   to = 243),
  list(file = "02_patient_input.R", from = 245,  to = 283),
  list(file = "03_mma_map.R",       from = 284,  to = 674),
  list(file = "04_lot1_base.R",     from = 675,  to = 829),
  list(file = "05_sct.R",           from = 830,  to = 1364),
  list(file = "06_lot1_end.R",      from = 1365, to = 1666),
  list(file = "07_qc.R",            from = 1667, to = 1809),
  list(file = "08_persist.R",       from = 1819, to = 1954)
)

# The one allowed change: LOT's own outputs carry the cohort prefix. Undo it
# and the two sides must be identical.
unport <- function(l) ifelse(grepl("wrk(cfg$input_cohort_table)", l, fixed = TRUE),
                             l, gsub("lot_out(", "wrk(", l, fixed = TRUE))

# Lines the port adds around the copied body: the comment, the signature, the
# ctx unpacking, the return, the closing brace.
body_of <- function(lines) {
  open  <- grep("^phase_[a-z0-9_]+ <- function\\(", lines)
  stopifnot(length(open) == 1)
  keep  <- lines[(open + 1):length(lines)]
  keep  <- keep[!grepl("^\\s*$", keep) | TRUE]
  # drop the unpacking block and the trailing return/brace the port added
  while (length(keep) && grepl("^  (meds|classes|sanitize_col|sct_src|med_flag_exprs) <- ctx\\$",
                               keep[1])) keep <- keep[-1]
  if (length(keep) && !nzchar(trimws(keep[1]))) keep <- keep[-1]
  end <- max(which(keep == "}"))
  keep <- keep[seq_len(end - 1)]
  # the return list this phase adds, if any
  ret <- grep("^  list\\(rollup_src = rollup_src", keep)
  if (length(ret)) keep <- keep[seq_len(ret - 1)]
  while (length(keep) && !nzchar(trimws(keep[length(keep)]))) keep <- keep[-length(keep)]
  keep
}

# What the approved deviations may do, stated as a property rather than a list
# of expected lines - a list goes stale and hides the next real change.
#
#   1. the code-list consistency block in 01_codelists.R was rewritten to fail
#      closed. It is spliced back to the source text before comparing.
#   2. two SELECT became SELECT DISTINCT.
#   3. guards and their comments were ADDED.
#
# So: after undoing (1) and (2), every remaining source line must still be
# present, in order. Anything removed or edited fails - which is what
# "differs, and the guards are there" could not catch.
CONSISTENCY_FROM <- "  # Code list vs rollup consistency."
CONSISTENCY_TO   <- "  # H4 fix: Codelist minimum-coverage validation (fail-loud)"
SRC_FROM         <- "  # Codelist <-> Rollup consistency QC"

undeviate <- function(lines) {
  a <- which(lines == CONSISTENCY_FROM); b <- which(lines == CONSISTENCY_TO)
  if (length(a) == 1 && length(b) == 1 && b > a) {
    sa <- which(src == SRC_FROM); sb <- which(src == CONSISTENCY_TO)
    lines <- c(lines[seq_len(a - 1)], src[sa:(sb - 1)], lines[b:length(lines)])
  }
  sub("^(\\s*)SELECT DISTINCT$", "\\1SELECT", lines)
}

# Every element of `want` appears in `got`, in order. Returns the first source
# line that does not, or NA.
first_missing <- function(got, want) {
  i <- 1L
  for (k in seq_along(want)) {
    hit <- FALSE
    while (i <= length(got)) {
      if (identical(got[i], want[k])) { i <- i + 1L; hit <- TRUE; break }
      i <- i + 1L
    }
    if (!hit) return(k)
  }
  NA_integer_
}

# Files that deliberately differ, and why. The source drops code-list rows on
# the RAW value while storing the NORMALIZED one, so a punctuation-only code
# survives as "" - and the claim side coalesces a missing code to "" too. That
# is a silent false match, not a rule, so the port fixes it. Each guard is
# asserted by name below; "differs" on its own would let one go missing.
CHANGED <- c("01_codelists.R", "03_mma_map.R", "05_sct.R")

cat("\n-- every phase is the source, line for line --\n")
for (p in PHASES) {
  f <- file.path(ROOT, "R", "steps", p$file)
  if (!file.exists(f)) { ok(FALSE, paste0(p$file, ": missing")); next }
  got  <- unport(body_of(readLines(f, warn = FALSE)))
  want <- src[p$from:p$to]
  while (length(want) && !nzchar(trimws(want[length(want)]))) want <- want[-length(want)]
  same <- identical(got, want)
  if (p$file %in% CHANGED) {
    # "differs, and the guards are there" would let an unrelated clinical
    # change ride along. Undo the approved deviations and require the rest to
    # be identical, so anything else shows up as a real difference.
    got <- undeviate(got)
    miss <- first_missing(got, want)
    if (!is.na(miss)) {
      ok(FALSE, paste0(p$file, ": a source line was changed or removed, at ",
                       "source line ", p$from + miss - 1,
                       "\n           source: ", want[miss]))
    } else {
      ok(TRUE, paste0(p$file, ": every source line survives; ",
                      length(got) - length(want), " guard line(s) added"))
    }
    next
  }
  if (!same) {
    n <- max(length(got), length(want))
    g <- c(got, rep(NA, n - length(got))); w <- c(want, rep(NA, n - length(want)))
    d <- which(is.na(g) | is.na(w) | g != w)[1]
    ok(FALSE, paste0(p$file, ": differs from 02_lot1.R at source line ",
                     p$from + d - 1, "\n           source: ", w[d],
                     "\n           ported: ", g[d]))
  } else {
    ok(TRUE, paste0(p$file, ": identical to 02_lot1.R lines ", p$from, "-", p$to,
                    " (", length(want), " lines)"))
  }
}

cat("\n-- ...and they differ only in the guards, nothing else --\n")
sql_of <- function(f) paste(readLines(file.path(ROOT, "R", "steps", f), warn = FALSE),
                            collapse = "\n")
GUARDS <- list(
  list(f = "01_codelists.R",
       pat = "AND regexp_replace(CL_CODE, '[^A-Za-z0-9]', '') <> ''",
       what = "the MM code list drops codes that normalize to blank"),
  list(f = "01_codelists.R", pat = "SELECT DISTINCT",
       what = "the MM code list is de-duplicated"),
  list(f = "05_sct.R",
       pat = "AND regexp_replace(CL_CODE, '[^A-Za-z0-9]', '') <> ''",
       what = "the SCT code list drops codes that normalize to blank"),
  list(f = "05_sct.R", pat = "SELECT DISTINCT",
       what = "the SCT code list is de-duplicated")
)
for (g in GUARDS) ok(grepl(g$pat, sql_of(g$f), fixed = TRUE), g$what)
# Both NDC joins, medical and Rx. Asserting one would have let the other ship
# unguarded - that is exactly how it happened in the cohort build.
mm <- sql_of("03_mma_map.R")
n_ndc <- length(gregexpr("AND regexp_replace(c.CL_CODE, '[^0-9]', '') <> ''",
                         mm, fixed = TRUE)[[1]])
ok(n_ndc == 2, paste0("both NDC joins require digits in the code (", n_ndc, ")"))
# The unchanged files must still be untouched.
for (f in setdiff(vapply(PHASES, `[[`, character(1), "file"), CHANGED))
  ok(!grepl("regexp_replace(CL_CODE, '[^A-Za-z0-9]', '') <> ''", sql_of(f), fixed = TRUE),
     paste0(f, ": no stray guard added"))

cat("\n-- LOT2-5 and LOT_LONG are whole-file copies --\n")
# These two were already function-structured in the source, so they are copied
# entire rather than cut into phases. Same rule: identical once unported.
WHOLE <- list(
  list(file = "09_lot2_5_inputs.R", src = "R/lot2_5_inputs.R"),
  list(file = "10_lot2_5_base.R",   src = "R/lot2_5_base.R")
)
for (p in WHOLE) {
  f  <- file.path(ROOT, "R", "steps", p$file)
  sf <- file.path(dirname(SRC), p$src)
  if (!file.exists(f) || !file.exists(sf)) { ok(FALSE, paste0(p$file, ": missing")); next }
  got  <- unport(readLines(f, warn = FALSE))
  want <- readLines(sf, warn = FALSE)
  same <- identical(got, want)
  if (!same) {
    n <- max(length(got), length(want))
    g <- c(got, rep(NA, n - length(got))); w <- c(want, rep(NA, n - length(want)))
    d <- which(is.na(g) | is.na(w) | g != w)[1]
    ok(FALSE, paste0(p$file, ": differs from ", p$src, " at line ", d,
                     "\n           source: ", w[d], "\n           ported: ", g[d]))
  } else {
    ok(TRUE, paste0(p$file, ": identical to ", p$src, " (", length(want), " lines)"))
  }
}

cat("\n-- the port covers the whole of main(), with nothing dropped silently --\n")
covered <- unlist(lapply(PHASES, function(p) p$from:p$to))
# Named, so nothing can be dropped without saying why:
#   62-76     connect and log the settings - now build_lot()
#   244       blank
#   1810-1818 descriptives, which is reporting rather than rules
#   1955-1968 the closing log - now build_lot()
EXCLUDED <- c(62:76, 244, 1810:1818, 1955:1968)
missed <- setdiff(setdiff(62:1968, EXCLUDED), covered)
ok(length(missed) == 0,
   if (length(missed)) paste0("source lines not ported: ",
                              paste(head(missed, 8), collapse = ", "), " ...")
   else paste0("all ", length(covered), " rule lines of main() are ported"))
# Each exclusion has to still be what it claims, or it is a silent drop.
ok(any(grepl("dbConnect", src[62:76])) && any(grepl("dbConnect", readLines(
     file.path(ROOT, "R", "build_lot.R"), warn = FALSE))),
   "the connect block moved into build_lot(), it was not lost")
ok(any(grepl("generate_descriptives", src[1810:1818])),
   "the descriptives block is reporting, out of scope for the rules")

cat("\n-- LOT's outputs are prefixed, the cohort table is not --\n")
steps <- list.files(file.path(ROOT, "R", "steps"), "\\.R$", full.names = TRUE)
all_lines <- unlist(lapply(steps, readLines, warn = FALSE))
# Count is brittle - LOT1 and the LOT2-5 rebuild both read the cohort. What
# matters is that every unprefixed name IS the cohort table.
w <- grep("(?<!lot_)wrk\\(", all_lines, perl = TRUE, value = TRUE)
stray <- w[!grepl("cfg$input_cohort_table", w, fixed = TRUE)]
ok(length(stray) == 0,
   if (length(stray)) paste0("unprefixed table name: ", trimws(stray[1]))
   else paste0("all ", length(w), " uses of wrk() are the cohort table"))
n_out <- length(grep("lot_out(", all_lines, fixed = TRUE))
ok(n_out >= 12, paste0("every other table name goes through lot_out() (", n_out, ")"))
# A CREATE TABLE that skipped lot_out() would overwrite another cohort's.
code_lines <- all_lines[!grepl("^\\s*(#|--)", all_lines)]
creates <- grep("CREATE (OR REPLACE )?TABLE|INSERT INTO|ALTER TABLE|DELETE FROM",
                code_lines, value = TRUE)
unprefixed <- creates[!grepl("lot_out\\(|\\{stg\\}", creates)]
ok(length(unprefixed) == 0,
   if (length(unprefixed)) paste0("persistent write without a prefix: ",
                                  trimws(unprefixed[1]))
   else paste0("all ", length(creates), " persistent writes are prefixed"))

report()
