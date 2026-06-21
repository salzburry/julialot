#!/usr/bin/env Rscript
# build_coverage_matrix.R
# Coverage matrix from the fixture catalog: per rule, how many positive/negative
# cases. `approved_only=TRUE` counts a case only when it is APPROVAL-READY
# (status == approved AND both reviewers filled), so a `--gate` run reflects what
# is actually validated, not what is merely listed. Gaps block "harness ready".

.filled <- function(x) !is.na(x) & nzchar(trimws(as.character(x)))

build_coverage_matrix <- function(catalog_path, approved_only = FALSE) {
  full <- read.csv(catalog_path, stringsAsFactors = FALSE, check.names = FALSE)
  counted <- full
  if (approved_only) {
    ready <- tolower(trimws(as.character(full$status))) == "approved" &
             .filled(full$clinical_reviewer) & .filled(full$engineering_reviewer)
    counted <- full[ready, , drop = FALSE]
  }
  rules <- sort(unique(full$rule_name))
  m <- data.frame(
    rule = rules,
    positive = vapply(rules, function(r) sum(counted$rule_name == r & counted$polarity == "positive"), integer(1)),
    negative = vapply(rules, function(r) sum(counted$rule_name == r & counted$polarity == "negative"), integer(1)),
    stringsAsFactors = FALSE)
  m$gap <- ifelse(m$positive == 0 | m$negative == 0, "GAP", "")
  m
}

report_coverage <- function(m, approved_only = FALSE) {
  gaps <- m[m$gap == "GAP", , drop = FALSE]
  cat(sprintf("coverage (%s): %d rules, %d with both polarities, %d gap(s)\n",
              if (approved_only) "approval-ready only" else "all catalog rows",
              nrow(m), sum(m$gap == ""), nrow(gaps)))
  if (nrow(gaps)) {
    cat("rules missing a polarity (need >=1 positive AND >=1 negative):\n")
    for (i in seq_len(nrow(gaps)))
      cat(sprintf("  - %-58s pos=%d neg=%d\n", gaps$rule[i], gaps$positive[i], gaps$negative[i]))
  }
  invisible(nrow(gaps) == 0)
}

if (sys.nframe() == 0 && !interactive()) {
  a <- commandArgs(trailingOnly = TRUE)
  gate <- "--gate" %in% a
  p <- a[!grepl("^--", a)]; p <- if (length(p)) p[1] else "tests/fixtures/catalog.csv"
  m <- build_coverage_matrix(p, approved_only = gate)
  ready <- report_coverage(m, approved_only = gate)
  # Informational by default; in --gate mode (pre-extraction readiness) gaps FAIL.
  quit(status = if (!gate || ready) 0L else 1L)
}
