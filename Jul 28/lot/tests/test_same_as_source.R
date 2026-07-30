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
  ret <- grep("^  list\\(sct_src = sct_src", keep)
  if (length(ret)) keep <- keep[seq_len(ret - 1)]
  while (length(keep) && !nzchar(trimws(keep[length(keep)]))) keep <- keep[-length(keep)]
  keep
}

cat("\n-- every phase is the source, line for line --\n")
for (p in PHASES) {
  f <- file.path(ROOT, "R", "steps", p$file)
  if (!file.exists(f)) { ok(FALSE, paste0(p$file, ": missing")); next }
  got  <- unport(body_of(readLines(f, warn = FALSE)))
  want <- src[p$from:p$to]
  while (length(want) && !nzchar(trimws(want[length(want)]))) want <- want[-length(want)]
  same <- identical(got, want)
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
w <- grep("wrk(", all_lines, fixed = TRUE, value = TRUE)
ok(length(w) == 1 && grepl("cfg$input_cohort_table", w[1], fixed = TRUE),
   "wrk() is used once, for the cohort table")
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
