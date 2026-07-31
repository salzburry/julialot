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
  list(file = "05_sct.R",           from = 830,  to = 1189),
  list(file = "05b_lot1_sct.R",     from = 1190, to = 1364),
  list(file = "06_lot1_end.R",      from = 1365, to = 1666),
  list(file = "07_qc.R",            from = 1667, to = 1809),
  list(file = "08_persist.R",       from = 1819, to = 1954)
)

# The deviation every file makes: LOT's own outputs carry the cohort prefix.
# The named ones below are undone per file on top of this.
unport <- function(l) ifelse(grepl("wrk(cfg$input_cohort_table)", l, fixed = TRUE),
                             l, gsub("lot_out(", "wrk(", l, fixed = TRUE))

# Lines the port adds around the copied body: the comment, the signature, the
# ctx unpacking, the return, the closing brace.
body_of <- function(lines) {
  open  <- grep("^phase_[a-z0-9_]+ <- function\\(", lines)
  stopifnot(length(open) == 1)
  keep  <- lines[(open + 1):length(lines)]
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

# Every approved deviation, named exactly. They are undone one at a time and
# then the two sides must be IDENTICAL - not "the source still fits inside
# what we have". A subsequence check let an inserted second WHERE clause pass,
# because every source line was still there.
#
# The list is strict both ways. An unapproved line survives the undoing and
# breaks equality; an approved deviation that gets deleted leaves its entry
# with nothing to remove, which is reported. That second half matters most for
# CUT: an added block is not in the source, so losing all of it would otherwise
# read as a perfect match.

# Blocks that replace source text: cut ours, put the source's back.
# The opening anchor is a code line, identical on both sides, so tidying the
# comment above it cannot silently stop the splice - which is what happened
# when it was the comment.
SPLICE <- list(
  "01_codelists.R" = list(from = "  log_msg(\"Checking codelist <-> rollup consistency...\")",
                          to   = "  # Minimum code list coverage.",
                          src  = "  log_msg(\"Checking codelist <-> rollup consistency...\")",
                          src_to = "  # H4 fix: Codelist minimum-coverage validation (fail-loud)")
)

# Blocks that are pure additions: cut, replace with nothing.
CUT <- list(
  # The consistency block itself is SPLICEd; this one sits after it, among the
  # source's own flag-expression code, so it is cut by name like the SCT ones.
  "01_codelists.R" = list(
    c(from = "for (nm in list(list(v = meds, what = \"medication\"),",
      to   = "log_msg(\"  OK: Every medication and class makes one distinct column name.\")")),
  "05_sct.R" = list(
    c(from = "sct_dup <- db_q(con, \"",
      to   = "log_msg(\"  OK: Each SCT code names exactly one transplant type.\")"),
    c(from = "sct_unmapped <- db_q(con, \"",
      to   = "log_msg(\"  OK: Every SCT_TYPE is one the build reads.\")"),
    c(from = "sct_code_type <- db_q(con, \"",
      to   = "log_msg(\"  OK: Every SCT code type is one an extraction branch reads.\")"),
    c(from = "sct_version <- db_q(con, glue(\"",
      to   = "log_msg(\"  OK: Every ICD-9 SCT code type is read as ICD-9.\")"))
)

# Lines that were EDITED rather than added, and how many of each. Counted like
# the rest: a blanket regex here would also hide an unapproved DISTINCT.
SUBST <- list(
  "01_codelists.R" = list(list(from = "SELECT DISTINCT", to = "SELECT", n = 2L)),
  "05_sct.R"       = list(list(from = "SELECT DISTINCT", to = "SELECT", n = 1L)),
  # The persisted orphan count has to ask what the main check asks, or
  # LOT_QC_SUMMARY reports an orphan the build deliberately ignored.
  "08_persist.R"   = list(list(
    from = "FROM mma_extractable_codelist c LEFT JOIN mma_rollup r ON c.CL_MED_ABBR = r.CL_MED_ABBR",
    to   = "FROM mma_codelist c LEFT JOIN mma_rollup r ON c.CL_MED_ABBR = r.CL_MED_ABBR",
    n    = 1L))
)

# Single added code lines, and how many of each.
DROP <- list(
  "01_codelists.R" = c(
    "AND regexp_replace(CL_CODE, '[^A-Za-z0-9]', '') <> ''" = 1L,
    "WHERE upper(trim(coalesce(CL_MED_CLASS, ''))) <> 'STEROID'" = 1L),
  "03_mma_map.R" = c(
    "AND regexp_replace(c.CL_CODE, '[^0-9]', '') <> ''" = 2L,
    "AND regexp_replace(coalesce(cast(m.NDC as string),''), '[^0-9]', '') <> ''" = 1L,
    "AND regexp_replace(coalesce(cast(r.NDC as string),''), '[^0-9]', '') <> ''" = 1L),
  "05_sct.R" = c(
    "AND regexp_replace(CL_CODE, '[^A-Za-z0-9]', '') <> ''" = 1L)
)

# Reported so a stale entry cannot hide a deleted guard.
undo_report <- new.env()

undeviate <- function(lines, file) {
  short <- character(0)
  sp <- SPLICE[[file]]
  if (!is.null(sp)) {
    a <- which(lines == sp$from); b <- which(lines == sp$to)
    if (length(a) == 1 && length(b) == 1 && b > a) {
      sa <- which(src == sp$src); sb <- which(src == sp$src_to)
      lines <- c(lines[seq_len(a - 1)], src[sa:(sb - 1)], lines[b:length(lines)])
    } else {
      # Reported, like the rest. Both anchors are exact whole-line matches,
      # and a missed one silently stops the splice - the file then differs
      # everywhere, which reads as a rewritten block rather than a moved
      # anchor. The opening one is a code line for that reason; the closing
      # one is still a comment.
      short <- c(short, paste0(sp$from, " ... ", sp$to,
                               " (anchor not found: ",
                               if (!length(a) && !length(b)) "neither line"
                               else if (!length(a)) "the opening line"
                               else if (!length(b)) "the closing line"
                               else "they are not in order", ")"))
    }
  }
  lines <- code_only(lines)
  # Reported like the rest. A CUT block is a pure addition, so deleting the
  # whole of it - both anchors with it - would leave nothing to cut and a port
  # that matches the source exactly, which is how a safety check could be
  # removed with every suite still green.
  for (cb in CUT[[file]]) {
    a <- grep(cb[["from"]], lines, fixed = TRUE)[1]
    b <- grep(cb[["to"]],   lines, fixed = TRUE)[1]
    if (is.na(a) || is.na(b) || b < a) {
      short <- c(short, paste0(cb[["from"]], " ... ", cb[["to"]],
                               " (added block gone: ",
                               if (is.na(a) && is.na(b)) "neither anchor found"
                               else if (is.na(a)) "opening anchor not found"
                               else if (is.na(b)) "closing anchor not found"
                               else "anchors out of order", ")"))
      next
    }
    lines <- lines[-(a:b)]
  }
  for (sb in SUBST[[file]]) {
    hit <- which(lines == sb$from)
    if (length(hit) != sb$n)
      short <- c(short, paste0(sb$from, " (expected ", sb$n, ", found ", length(hit), ")"))
    if (length(hit)) lines[hit[seq_len(min(sb$n, length(hit)))]] <- sb$to
  }
  for (nm in names(DROP[[file]])) {
    want_n <- DROP[[file]][[nm]]
    hit <- which(lines == nm)
    if (length(hit) < want_n)
      short <- c(short, paste0(nm, " (expected ", want_n, ", found ", length(hit), ")"))
    if (length(hit)) lines <- lines[-hit[seq_len(min(want_n, length(hit)))]]
  }
  assign(file, short, envir = undo_report)
  lines
}

# Comments do not execute, so they are compared out. That is what lets the
# copied review-diary comments be tidied without weakening this test: the
# executable R and SQL still has to match exactly. Whole-line comments only -
# stripping trailing ones would mangle a "#" inside a SQL string.
code_only <- function(lines) {
  # A trailing "--" or "#" is a comment only when it is outside quotes; an odd
  # number of quotes before it means the marker sits inside a string literal.
  # If that guess were ever wrong the comparison below would fail, loudly.
  drop_trailing <- function(l) {
    at <- sort(c(gregexpr("--", l, fixed = TRUE)[[1]],
                 gregexpr("#", l, fixed = TRUE)[[1]]))
    at <- at[at > 0]
    for (i in at) {
      head <- substr(l, 1, i - 1)
      if (nchar(gsub("[^\\'\"]", "", head)) %% 2 == 0) return(substr(l, 1, i - 1))
    }
    l
  }
  keep <- !grepl("^\\s*(#|--)", lines) & nzchar(trimws(lines))
  trimws(vapply(lines[keep], drop_trailing, character(1), USE.NAMES = FALSE))
}

# Files that deliberately differ, and why. The source drops code-list rows on
# the RAW value while storing the NORMALIZED one, so a punctuation-only code
# survives as "" - and the claim side coalesces a missing code to "" too. That
# is a silent false match, not a rule, so the port fixes it. Each guard is
# asserted by name below; "differs" on its own would let one go missing.
CHANGED <- c("01_codelists.R", "03_mma_map.R", "05_sct.R", "08_persist.R")

cat("\n-- every phase is the source, line for line --\n")
for (p in PHASES) {
  f <- file.path(ROOT, "R", "steps", p$file)
  if (!file.exists(f)) { ok(FALSE, paste0(p$file, ": missing")); next }
  raw  <- unport(body_of(readLines(f, warn = FALSE)))
  got  <- if (p$file %in% CHANGED) undeviate(raw, p$file) else code_only(raw)
  want <- code_only(src[p$from:p$to])
  same <- identical(got, want)
  if (p$file %in% CHANGED) {
    short <- get(p$file, envir = undo_report)
    if (length(short)) {
      ok(FALSE, paste0(p$file, ": an approved deviation is missing -- ", short[1]))
      next
    }
    # "differs, and the guards are there" would let an unrelated clinical
    # change ride along. Undo the approved deviations and require the rest to
    # be identical, so anything else shows up as a real difference.
    if (!same) {
      n <- max(length(got), length(want))
      g <- c(got, rep(NA, n - length(got))); w <- c(want, rep(NA, n - length(want)))
      d <- which(is.na(g) | is.na(w) | g != w)[1]
      ok(FALSE, paste0(p$file, ": differs beyond the approved deviations, at ",
                       "source line ", p$from + d - 1,
                       "\n           source: ", if (is.na(w[d])) "<nothing>" else w[d],
                       "\n           ported: ", if (is.na(g[d])) "<nothing>" else g[d]))
    } else {
      ok(TRUE, paste0(p$file, ": identical once the approved deviations are undone"))
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
    ok(TRUE, paste0(p$file, ": same code as 02_lot1.R lines ", p$from, "-", p$to,
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
# Both rollup builders, or a fresh-session run would disagree with LOT1.
# One builder puts it in a new WHERE, the other in an existing one, so match
# the predicate rather than the clause. trim matters: the projection trims and
# the raw column does not, so ' STEROID ' would otherwise survive.
ok(grepl("upper(trim(coalesce(CL_MED_CLASS, ''))) <> 'STEROID'",
         sql_of("01_codelists.R"), fixed = TRUE),
   "the rollup drops steroids - once, now that both paths share it")
ok(grepl("FROM mma_extractable_codelist c LEFT JOIN mma_rollup r",
         sql_of("08_persist.R"), fixed = TRUE),
   "the persisted orphan count reads the same population as the live check")
# The unchanged files must still be untouched.
for (f in setdiff(vapply(PHASES, `[[`, character(1), "file"), CHANGED))
  ok(!grepl("regexp_replace(CL_CODE, '[^A-Za-z0-9]', '') <> ''", sql_of(f), fixed = TRUE),
     paste0(f, ": no stray guard added"))

cat("\n-- LOT2-5 and LOT_LONG are whole-file copies --\n")
# These two were already function-structured in the source, so they are copied
# entire rather than cut into phases. Same rule: identical once unported.
# 09_lot2_5_inputs.R is deliberately no longer a copy: it carried its own
# drifting duplicates of the code-list, cohort and SCT SQL, and now calls the
# LOT1 phases instead. The SQL it used to hold is still compared - as part of
# the phases it now calls.
WHOLE <- list(
  list(file = "10_lot2_5_base.R",   src = "R/lot2_5_base.R")
)
for (p in WHOLE) {
  f  <- file.path(ROOT, "R", "steps", p$file)
  sf <- file.path(dirname(SRC), p$src)
  if (!file.exists(f) || !file.exists(sf)) { ok(FALSE, paste0(p$file, ": missing")); next }
  got  <- code_only(unport(readLines(f, warn = FALSE)))
  want <- code_only(readLines(sf, warn = FALSE))
  same <- identical(got, want)
  if (!same) {
    n <- max(length(got), length(want))
    g <- c(got, rep(NA, n - length(got))); w <- c(want, rep(NA, n - length(want)))
    d <- which(is.na(g) | is.na(w) | g != w)[1]
    ok(FALSE, paste0(p$file, ": differs from ", p$src, " at line ", d,
                     "\n           source: ", w[d], "\n           ported: ", g[d]))
  } else {
    ok(TRUE, paste0(p$file, ": same code as ", p$src, " (", length(want), " lines)"))
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
