#!/usr/bin/env Rscript
# build_coverage_matrix.R
# From the fixture catalog, build the positive/negative coverage matrix per
# rule and flag rules lacking both polarities. Gaps block "harness ready".

build_coverage_matrix <- function(catalog_path) {
  cat_df <- read.csv(catalog_path, stringsAsFactors = FALSE, check.names = FALSE)
  rules <- sort(unique(cat_df$rule_name))
  m <- data.frame(
    rule = rules,
    positive = vapply(rules, function(r) sum(cat_df$rule_name == r & cat_df$polarity == "positive"), integer(1)),
    negative = vapply(rules, function(r) sum(cat_df$rule_name == r & cat_df$polarity == "negative"), integer(1)),
    stringsAsFactors = FALSE)
  m$gap <- ifelse(m$positive == 0 | m$negative == 0, "GAP", "")
  m
}

report_coverage <- function(m) {
  gaps <- m[m$gap == "GAP", , drop = FALSE]
  cat(sprintf("coverage: %d rules, %d with both polarities, %d gap(s)\n",
              nrow(m), sum(m$gap == ""), nrow(gaps)))
  if (nrow(gaps)) {
    cat("rules missing a polarity (need >=1 positive AND >=1 negative):\n")
    for (i in seq_len(nrow(gaps)))
      cat(sprintf("  - %-60s pos=%d neg=%d\n", gaps$rule[i], gaps$positive[i], gaps$negative[i]))
  }
  invisible(nrow(gaps) == 0)
}

if (sys.nframe() == 0 && !interactive()) {
  p <- commandArgs(trailingOnly = TRUE)[1]
  if (is.na(p)) p <- "tests/fixtures/catalog.csv"
  m <- build_coverage_matrix(p)
  report_coverage(m)
  # coverage gaps are reported (the catalog is intentionally seeded with TODOs);
  # exit 0 so this is informational until the catalog is declared complete.
  quit(status = 0)
}
