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

# Artifact-awareness for --gate: an approval-ready case must point to an EXISTING
# fixture (declared input + expected paths). A row marked `approved` with no
# runnable artifact behind it - or a dangling path - is not real coverage and
# fails the gate. (Expected-output HASH pinning against the frozen baseline is
# Increment 0A / Databricks-side and is intentionally not done here.)
check_catalog_artifacts <- function(catalog, base_dir = ".",
                                     cols = c("input_fixture", "expected_fixture")) {
  ready <- tolower(trimws(as.character(catalog$status))) == "approved" &
           .filled(catalog$clinical_reviewer) & .filled(catalog$engineering_reviewer)
  problems <- character(0)
  for (i in which(ready)) {
    cid <- catalog$case_id[i]
    for (cn in cols) {
      val <- if (cn %in% names(catalog)) trimws(as.character(catalog[[cn]][i])) else ""
      if (!nzchar(val)) { problems <- c(problems, sprintf("%s: approved but no %s declared", cid, cn)); next }
      if (!file.exists(file.path(base_dir, val)))
        problems <- c(problems, sprintf("%s: %s artifact missing (%s)", cid, cn, val))
    }
  }
  problems
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
  artifacts_ok <- TRUE
  if (gate) {                                   # approved rows must have real fixtures
    probs <- check_catalog_artifacts(read.csv(p, stringsAsFactors = FALSE, check.names = FALSE), dirname(p))
    if (length(probs)) { artifacts_ok <- FALSE
      cat("approved cases missing a runnable artifact:\n"); for (q in probs) cat("  - ", q, "\n") }
  }
  # Informational by default; in --gate mode (pre-extraction readiness) gaps or
  # missing artifacts FAIL.
  quit(status = if (!gate || (ready && artifacts_ok)) 0L else 1L)
}
