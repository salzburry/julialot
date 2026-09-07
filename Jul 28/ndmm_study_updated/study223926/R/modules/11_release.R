# Small-cell suppression, applied.
#
# "Stratifications with < 25 patients will not be performed" (s7.8, Table 1's
# footnote). R/suppression.R has expressed that rule since the package was
# written and NOTHING called it: every S_* table left the warehouse with raw
# cell counts, n = 1 included. That is a disclosure-control failure rather than
# a wrong number, which is why it gets its own module rather than a footnote.
#
# The raw tables are not overwritten. Each suppressed table is written beside
# its source as S_*_RELEASE, so QC can still read the counts that produced a
# rate while the thing that leaves the warehouse cannot. Overwriting in place
# would also make the rule un-checkable: you cannot tell a suppressed cell from
# a cell that was always empty.

# The spec - which table, which count, which values - is in R/registry.R with
# the module that writes it, because the registry has to name the outputs and
# is sourced first.

mod_release <- function(con, cfg, cohorts) {
  min_n <- as.integer(cfg$suppress_min_n)
  for (tbl in names(SUPPRESSION_SPEC)) {
    spec <- SUPPRESSION_SPEC[[tbl]]
    src  <- wrk(tbl)
    out  <- wrk(paste0(tbl, "_RELEASE"))
    hit  <- sprintf("%s IS NOT NULL AND %s < %d", spec$n_col, spec$n_col, min_n)

    # The count itself is nulled too. Suppressing the rate and publishing the
    # n it was computed from suppresses nothing.
    nulled <- vapply(c(spec$n_col, spec$value_cols), function(cl)
      sprintf("CASE WHEN %s THEN NULL ELSE %s END AS %s", hit, cl, cl),
      character(1))

    run_step(con, paste0("release_", tolower(tbl)), sprintf("
      CREATE OR REPLACE TABLE %s AS
      SELECT * EXCEPT (%s),
             %s,
             CASE WHEN %s THEN 1 ELSE 0 END AS SUPPRESSED,
             CASE WHEN %s THEN 'n < %d' END AS SUPPRESSION_REASON
      FROM %s",
      out, paste(c(spec$n_col, spec$value_cols), collapse = ", "),
      paste(nulled, collapse = ",\n             "),
      hit, hit, min_n, src),
      qc = sprintf("SELECT count(*) AS n_rows, sum(SUPPRESSED) AS n_suppressed
                    FROM %s", out),
      allow_empty = TRUE)
  }

  # A group with exactly one suppressed row gives that row away by subtraction.
  # Reported, not fixed: regrouping is the analyst's call, and silently merging
  # categories would change what the table means.
  db_exec(con, sprintf("
    CREATE OR REPLACE TEMPORARY VIEW s_complementary_risk AS
    SELECT COHORT, LOT_NUM, PERIOD, count(*) AS n_suppressed
    FROM %s WHERE SUPPRESSED = 1
    GROUP BY COHORT, LOT_NUM, PERIOD HAVING count(*) = 1",
    wrk("S_SAFETY_RATES_RELEASE")))
  n <- db_q(con, "SELECT count(*) AS n FROM s_complementary_risk")$n[1]
  if (!is.na(n) && n > 0)
    log_msg("  WARNING: ", n, " group(s) in S_SAFETY_RATES_RELEASE have ",
            "exactly one suppressed row, so that row is recoverable by ",
            "subtraction. Regroup before the table leaves the warehouse.")
  log_msg("  released ", length(SUPPRESSION_SPEC), " table(s) with n < ",
          min_n, " suppressed")
}
