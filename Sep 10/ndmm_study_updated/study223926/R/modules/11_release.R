# Small-cell suppression, applied.
#
# The rule, twice, and the two sentences differ:
#   s7.2.3 "Stratifications with <25 patients will not be performed or may be
#          regrouped due to low volumes."
#   s7.8   "If there are less than 25 patients in a particular stratifications
#          or cohort, analyses will not be conducted (unless specific to SOC)."
#
# What runs below is the first: suppress every cell under the floor, SOC
# included. s7.8's SOC exemption is NOT applied - see OPEN_QUESTIONS.md Q29.
# Suppressing more than required loses a stratum the protocol may permit; the
# other way round would publish one it forbids. This SQL is the only place the
# rule exists.
#
# The raw tables are not overwritten. Each suppressed table is written beside
# its source as S_*_RELEASE, so QC can still read the counts that produced a
# rate while the thing that leaves the warehouse cannot - and a suppressed cell
# stays tellable from one that was always empty.

# The spec - which table, which count, which values - is in R/registry.R beside
# the module that writes it, because the registry has to name the outputs and
# is sourced first.

mod_release <- function(con, cfg, cohorts) {
  min_n <- as.integer(cfg$suppress_min_n)
  for (tbl in names(SUPPRESSION_SPEC)) {
    spec <- SUPPRESSION_SPEC[[tbl]]
    src  <- wrk(tbl)
    out  <- wrk(paste0(tbl, "_RELEASE"))
    # A count that cannot be read has not been shown to clear the floor, so a
    # NULL suppresses too. Every denominator the modules write today is
    # non-NULL by construction, but a new module reaches here without an edit.
    hit  <- sprintf("(%s IS NULL OR %s < %d)", spec$n_col, spec$n_col, min_n)

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
             CASE WHEN %s IS NULL THEN 'n unknown'
                  WHEN %s < %d THEN 'n < %d' END AS SUPPRESSION_REASON
      FROM %s",
      out, paste(c(spec$n_col, spec$value_cols), collapse = ", "),
      paste(nulled, collapse = ",\n             "),
      hit, spec$n_col, spec$n_col, min_n, min_n, src),
      qc = sprintf("SELECT count(*) AS n_rows, sum(SUPPRESSED) AS n_suppressed
                    FROM %s", out),
      allow_empty = TRUE)
  }

  # A group with exactly one suppressed row gives that row away by subtraction:
  # every other row in the group is published, and so is the group's own total,
  # so the withheld cell is the difference.
  #
  # Reported, not fixed: regrouping is the analyst's call, and silently merging
  # categories would change what the table means. The group is the stratum a
  # table's rows divide up, which differs per table, so SUPPRESSION_SPEC
  # declares it beside the count column it is about.
  for (tbl in names(SUPPRESSION_SPEC)) {
    grp <- SUPPRESSION_SPEC[[tbl]]$group_by
    if (!length(grp)) next
    rel <- wrk(paste0(tbl, "_RELEASE"))
    n <- db_q(con, sprintf(
      "SELECT count(*) AS n FROM (SELECT %1$s FROM %2$s WHERE SUPPRESSED = 1
         GROUP BY %1$s HAVING count(*) = 1)",
      paste(grp, collapse = ", "), rel))$n[1]
    if (!is.na(n) && n > 0)
      log_msg("  WARNING: ", n, " group(s) in ", tbl, "_RELEASE have exactly ",
              "one suppressed row, so that row is recoverable by subtraction ",
              "from the rest of its ", paste(grp, collapse = "/"),
              " group. Regroup before the table leaves the warehouse.")
  }
  log_msg("  released ", length(SUPPRESSION_SPEC), " table(s) with n < ",
          min_n, " suppressed")
}
