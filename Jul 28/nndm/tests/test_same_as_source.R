#!/usr/bin/env Rscript
# The NDMM cohort is a port of the cohort half of
# apr_30_2026/06_ndmm_dashboard.R, not a rewrite. That file is 1,479 lines of
# which roughly 840 build the cohort and the rest render a dashboard; this
# package takes the first half only. Every ported file is compared line for
# line against the range it came from.
#
# Skipped when apr_30_2026 is not beside this folder, so a copied-out package
# still runs its other suites.
#
#   Rscript "Jul 28/nndm/tests/test_same_as_source.R"

ROOT <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                                 fixed = TRUE))) else getwd()
  dirname(d)
})
source(file.path(ROOT, "tests", "testutil.R"))

SRC <- file.path(dirname(dirname(ROOT)), "apr_30_2026", "06_ndmm_dashboard.R")
if (!file.exists(SRC)) {
  cat("apr_30_2026 not beside this folder -- nothing to compare against. Skipping.\n")
  quit(status = 0L)
}
src <- readLines(SRC, warn = FALSE)

# Where each file came from. The ranges are contiguous and non-overlapping, and
# together they are the cohort half of the source - asserted below, so a range
# that is quietly narrowed cannot drop code without saying so.
PARTS <- list(
  list(file = "R/nndm_constants.R",      from = 62,  to = 147),
  list(file = "R/steps/01_enrollment.R",  from = 148, to = 198),
  list(file = "R/steps/02_lot1_starts.R", from = 199, to = 216),
  list(file = "R/steps/03_prior_therapy.R", from = 217, to = 317),
  list(file = "R/steps/04_other_malig.R", from = 318, to = 533),
  list(file = "R/steps/05_pregnancy.R",   from = 534, to = 621),
  list(file = "R/steps/06_flags.R",       from = 622, to = 755),
  list(file = "R/steps/07_cohort.R",      from = 756, to = 839)
)

# The port is allowed to differ from the source in exactly the ways named here,
# and in no others. Each deviation is undone before the comparison, so an
# unapproved change survives and breaks equality; and a deviation that gets
# deleted leaves its entry with nothing to undo, which is reported rather than
# reading as a perfect match.
#
# All of these are the one clinical change the study team confirmed: the 1L
# follow-up CE is one day of enrollment on the index date, not three months.
# The protocol text (Rev Round 2, S6.2.1.1) says three months, so this is a
# deliberate override of the written spec and is spelled out rather than
# absorbed - the numbers it produces are not the numbers apr_30_2026 produces.
SUBST <- list(
  # The override now covers the remission variants of the plasma-cell groups as
  # well - the criterion is another cancer distinct from the index MM, and
  # remission cannot make a plasma-cell disorder more like a different one. The
  # list moves behind ndmm_mm_adjacent_groups() so the setting that decides it
  # lives in one place.
  "R/steps/04_other_malig.R" = list(
    list(from = "ovr_in <- paste(sprintf(\"'%s'\", gsub(\"'\", \"''\", ndmm_mm_adjacent_groups())),",
         to   = "ovr_in <- paste(sprintf(\"'%s'\", gsub(\"'\", \"''\", NDMM_MM_ADJACENT_OVERRIDE)),",
         n = 1L)),
  "R/steps/06_flags.R" = list(
    list(from = "AND s.cov_end   >= least(date_add(ec_l1.LOT1_START_DT, {NDMM_FU_CE_DAYS}),",
         to   = "AND s.cov_end   >= least(date_add(ec_l1.LOT1_START_DT, 90),", n = 1L),
    list(from = "THEN 1 ELSE 0 END) AS CE_fu",
         to   = "THEN 1 ELSE 0 END) AS CE_lot1_3mo", n = 1L),
    list(from = "coalesce(fuce.CE_fu, 0)                              AS CE_lot1_fu,",
         to   = "coalesce(fuce.CE_lot1_3mo, 0)                        AS CE_lot1_3mo_fu,", n = 1L),
    list(from = "AND CE_lot1_fu              = 1",
         to   = "AND CE_lot1_3mo_fu          = 1", n = 1L))
  # 07_cohort.R's CE_lot1_fu reference lives inside the rewritten block below,
  # so it is undone by SPLICE rather than named here.
)

# Lines the port adds that the source has no counterpart for, and how many.
#
# The <> '' guards are the second clinical change. Every codelist and claim
# value is normalised by stripping punctuation, and the source only checked the
# raw value for blankness: a CL_CODE of '---' survives that check, normalises
# to '', and then equals the normalised form of any claim whose code is
# missing. In the NDC branches both sides pad to 00000000000. The result is a
# patient excluded as previously treated, or as having another cancer, on the
# strength of a claim with no code in it. These add the check on the normalised
# value; they can only ever remove matches the source should not have made.
ADDED <- list(
  "R/nndm_constants.R" = c("NDMM_FU_CE_DAYS          <- 0L" = 1L),
  "R/steps/03_prior_therapy.R" = c(
    "AND regexp_replace(trim(CL_CODE), '[^A-Za-z0-9]', '') <> ''" = 1L,
    "AND (upper(trim(CL_CODE_TYPE)) <> 'NDC'" = 1L,
    "OR regexp_replace(CL_CODE, '[^0-9]', '') <> '')" = 1L,
    "AND regexp_replace(coalesce(cast(m.PROC_CD as string),''), '[^A-Za-z0-9]', '') <> ''" = 1L,
    "AND regexp_replace(coalesce(cast(m.BILL_PROC_CD as string),''), '[^A-Za-z0-9]', '') <> ''" = 1L,
    "AND regexp_replace(coalesce(cast(m.NDC as string),''), '[^0-9]', '') <> ''" = 1L,
    "AND regexp_replace(coalesce(cast(r.NDC as string),''), '[^0-9]', '') <> ''" = 1L),
  "R/steps/04_other_malig.R" = c(
    "AND regexp_replace(trim(dx), '[^A-Za-z0-9]', '') <> ''" = 1L,
    # The required-match count is now against the five labels the code list
    # must carry, not against every group the override reaches - the remission
    # variants are a proposal and their absence is reported, not fatal.
    "req    <- gsub(\"'\", \"''\", NDMM_MM_ADJACENT_OVERRIDE)" = 1L,
    "req_in <- paste(sprintf(\"'%s'\", req), collapse = \", \")" = 1L,
    "AND upper(trim(tumor_group)) IN ({req_in})" = 1L,
    # The third clinical change. The other-cancer rule is >=1 inpatient claim
    # or >=2 outpatient claims within 30 days of each other, in the 12-month
    # 1L baseline. The source bounded only the first of the outpatient pair, so
    # a claim on the day before the index and its confirmation a month after it
    # excluded the patient on a single baseline claim. This bounds the second
    # claim too, so both fall in the baseline the criterion names. It can only
    # remove exclusions, so the cohort it builds is larger than apr_30_2026's.
    "AND op.next_dt  BETWEEN l1.pre_lot1_start AND l1.pre_lot1_end" = 1L),
  "R/steps/05_pregnancy.R" = c(
    "AND regexp_replace(trim(code), '[^A-Za-z0-9]', '') <> ''" = 1L)
)

# Blocks the port rewrote rather than edited. Patching these back line by line
# would take twenty SUBST entries and would not be readable by anyone checking
# what changed; instead the block is named by its first and last line and
# swapped for the source's own lines before the comparison. Everything outside
# it is still held to the source exactly, and markers that stop matching are
# reported - so deleting the rewrite does not read as a perfect match.
#
# ndmm_counts(): the attrition follows protocol Rev Round 2 S6.2.1.1 then
# S6.2.1.2 in the order those sections list the criteria. The source applies
# belantamab first and follow-up CE second-to-last. Same final cohort - it is
# one conjunction either way - but different per-step counts, and the attrition
# is the deliverable.
SPLICE <- list(
  "R/steps/07_cohort.R" = list(
    # Widened: whole/elig/elig_lot1 are rewritten too. This package no longer
    # reads LOT_LONG or a parent cohort table, so the first three rows of the
    # funnel are a qualifying MM diagnosis, then age, then an eligible 1L
    # treatment - derived here rather than inherited.
    list(from = "ndmm_counts <- function(con, mm_qualifying, base_cohort) {",
         to   = "ndmm_final = ndmm_final)",
         src_from = 795L, src_to = 837L)
  ),
  # The materialization of NDMM_FLAGS_ALL. The source wrapped it in tryCatch and
  # warned on failure, keeping the in-place view: correct arithmetic, but this
  # package declares that table an output, so the run would report complete with
  # it missing - and every later read would re-run the whole scan DAG. It is one
  # call to checkpoint() now, which is what every other materialization in this
  # package uses and which stops if the write fails. It stays inside this
  # function because NDMM_PATIDS is defined over the view a few lines below and
  # Spark inlines a temp view's plan.
  "R/steps/06_flags.R" = list(
    list(from = 'checkpoint(con, "NDMM_FLAGS_ALL")',
         to   = 'checkpoint(con, "NDMM_FLAGS_ALL")',
         src_from = 727L, src_to = 741L)
  ),
  # The MM-adjacent override. The source logged how many of the expected
  # tumour-group labels matched the production codelist and carried on; an
  # unmatched label means the override silently does nothing for that group,
  # so a patient whose only other cancer is MM-adjacent is excluded as having
  # another cancer. The source's own comment calls that a run-review blocker.
  # This stops instead.
  "R/steps/04_other_malig.R" = list(
    list(from = "if (is.na(n_matched) || n_matched < n_exp)",
         to   = "\" expected MM-adjacent tumor_group labels\")",
         src_from = 340L, src_to = 348L)
  )
)

undo_report <- new.env()

undeviate <- function(lines, file) {
  short <- character(0)
  for (sp in SPLICE[[file]]) {
    i <- which(lines == sp$from); j <- which(lines == sp$to)
    if (length(i) != 1L || length(j) != 1L || j[1] < i[1]) {
      short <- c(short, paste0("rewritten block ", sp$from, " ... ", sp$to,
                               " (found ", length(i), " start, ", length(j), " end)"))
      next
    }
    lines <- append(lines[-(i[1]:j[1])], code_only(src[sp$src_from:sp$src_to]),
                    after = i[1] - 1L)
  }
  for (sb in SUBST[[file]]) {
    hit <- which(lines == sb$from)
    if (length(hit) != sb$n)
      short <- c(short, paste0(sb$from, " (expected ", sb$n, ", found ", length(hit), ")"))
    if (length(hit)) lines[hit[seq_len(min(sb$n, length(hit)))]] <- sb$to
  }
  for (nm in names(ADDED[[file]])) {
    want <- ADDED[[file]][[nm]]
    hit  <- which(lines == nm)
    if (length(hit) < want)
      short <- c(short, paste0(nm, " (expected ", want, ", found ", length(hit), ")"))
    if (length(hit)) lines <- lines[-hit[seq_len(min(want, length(hit)))]]
  }
  assign(file, short, envir = undo_report)
  lines
}

CHANGED <- c("R/nndm_constants.R", "R/steps/03_prior_therapy.R",
             "R/steps/04_other_malig.R", "R/steps/05_pregnancy.R",
             "R/steps/06_flags.R", "R/steps/07_cohort.R")

# Comments are compared out, so the copied comments can be tidied without
# weakening the check. Change a code line and it fails; change a comment and it
# does not. Whole-line comments only - stripping trailing ones would mangle a
# "#" inside a SQL string.
code_only <- function(lines) {
  keep <- !grepl("^\\s*(#|--)", lines) & nzchar(trimws(lines))
  trimws(lines[keep])
}

# The header each ported file adds above the copied body.
body_of <- function(lines) {
  i <- which(!grepl("^\\s*#", lines) & nzchar(trimws(lines)))
  if (!length(i)) return(character(0))
  lines[seq(min(i), length(lines))]
}

cat("\n-- every ported file is the source, line for line --\n")
for (p in PARTS) {
  f <- file.path(ROOT, p$file)
  if (!file.exists(f)) { ok(FALSE, paste0(p$file, ": missing")); next }
  raw  <- code_only(body_of(readLines(f, warn = FALSE)))
  got  <- if (p$file %in% CHANGED) undeviate(raw, p$file) else raw
  want <- code_only(src[p$from:p$to])
  if (p$file %in% CHANGED) {
    sh <- get(p$file, envir = undo_report)
    if (length(sh)) { ok(FALSE, paste0(p$file, ": an approved deviation is missing -- ", sh[1])); next }
  }
  if (identical(got, want)) {
    ok(TRUE, paste0(p$file, ": ",
                    if (p$file %in% CHANGED) "identical once the approved deviations are undone"
                    else paste0("same code as lines ", p$from, "-", p$to),
                    " (", length(want), " lines)"))
  } else {
    n <- max(length(got), length(want))
    g <- c(got, rep(NA, n - length(got))); w <- c(want, rep(NA, n - length(want)))
    d <- which(is.na(g) | is.na(w) | g != w)[1]
    ok(FALSE, paste0(p$file, ": differs at source line ", p$from + d - 1,
                     "\n           source: ", if (is.na(w[d])) "<nothing>" else w[d],
                     "\n           ported: ", if (is.na(g[d])) "<nothing>" else g[d]))
  }
}

cat("\n-- and every ported file parses --\n")
# Line-for-line equality does not imply this: a range that ends mid-statement
# compares clean and then fails to source. It did, between the constants and
# the enrollment step.
for (p in PARTS) {
  f <- file.path(ROOT, p$file)
  e <- tryCatch({ parse(f); NULL }, error = function(e) e)
  ok(is.null(e), paste0(p$file, ": parses",
                        if (!is.null(e)) paste0(" -- ", conditionMessage(e)) else ""))
}

cat("\n-- and the ranges account for the whole cohort half --\n")
# Contiguous and in order, so no source line between the first and the last
# falls outside a ported file. A narrowed range would leave a gap here rather
# than silently dropping the code inside it.
gaps <- character(0)
for (i in seq_along(PARTS)[-1]) {
  if (PARTS[[i]]$from != PARTS[[i - 1]]$to + 1L)
    gaps <- c(gaps, paste0(PARTS[[i - 1]]$to, " -> ", PARTS[[i]]$from))
}
ok(length(gaps) == 0,
   if (length(gaps)) paste0("the ranges skip source lines: ", paste(gaps, collapse = ", "))
   else paste0("the ", length(PARTS), " ranges are contiguous, ",
               PARTS[[1]]$from, "-", PARTS[[length(PARTS)]]$to))

report()
