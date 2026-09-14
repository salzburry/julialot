# Who is eligible, with no line of therapy involved.
#
# This and 00_spine.R are the package's two independent roots, which is why
# they share a number. The spine is the LOT engine's lines. This is the cohort
# build's eligibility verdict. Neither reads the other, and either can be built
# without the other existing.
#
# Eight of the eleven criteria are settled before this package runs - I1 to I4
# and X1 to X4 - and arrive as flags on INPUT_COHORT_TABLE. None of them needs
# a line, an index date from LOT, or anything the engine produces. Only three
# are line-relative by definition: I5 (follow-up from the line's index), N1
# (received THIS line) and N2 (enrolment before THIS line's index). Those stay
# in 01_cohorts.R, which is where a patient and a line are combined.
#
# So this module is the answer to "which patients are eligible", and it is
# available whether or not a LOT run exists.
#
# It is also the ONLY module that reads INPUT_COHORT_TABLE. Everything
# downstream reads S_ELIGIBILITY instead. That is what makes the layering real
# rather than cosmetic: the upstream table is touched in one place, its
# contract is checked in one place, and a change to its shape reaches the rest
# of the package through a table this package declares.

# The patient-level facts the rest of the package takes off the cohort build,
# carried here so nothing else has to join the upstream table.
mod_eligibility <- function(con, cfg, cohorts) {
  # A wide input keeps the patients an exclusion would have removed and carries
  # the verdict as a flag; a pre-filtered one removed them and carries no flag.
  # Under the second, cohort_flag_pred_one() returns the literal "1 = 1" and
  # every MET_X is 1 for everyone - which is TRUE and says nothing. EVIDENCE
  # records which of the two this run read, so a 1 can be told from a 1.
  flags <- intersect(unname(CRITERION_FLAG), .cohort_cols())
  evidence <- if (length(flags)) "flags on the input" else
    "upstream, pre-filtered - no flag on the input to read"

  # CREATE OR REPLACE, as 00_spine.R does, not prepare_table + INSERT. This
  # table has no COHORT column to scope a clear by - it is one row per patient,
  # the same rows whichever cohorts the run selected - and an INSERT here is
  # positional, so a column added later would land in the wrong place under an
  # older table. A root table is rebuilt whole.
  run_step(con, "eligibility", sprintf("
    CREATE OR REPLACE TABLE %1$s AS
    SELECT cast(c.PATID as string) AS PATID,
           c.INDEX_DATE AS COHORT_INDEX_DATE,
           c.MM_DX_DT, c.DEATH_DT, c.ENDDATE, c.ENDDATE_CE,
           cast(c.YRDOB as int) AS YRDOB, c.GDR_CD,
           -- I1 to I4 are the cohort build's inclusion tests. This package has
           -- no flag for them and cannot re-derive them: a patient on the
           -- input passed them by being there. Recorded as 1 with EVIDENCE
           -- saying where the 1 came from, never as a test this package ran.
           1 AS MET_I1, 1 AS MET_I2, 1 AS MET_I3, 1 AS MET_I4,
           CASE WHEN %2$s THEN 1 ELSE 0 END AS MET_X1,
           CASE WHEN %3$s THEN 1 ELSE 0 END AS MET_X2,
           CASE WHEN %4$s THEN 1 ELSE 0 END AS MET_X3,
           CASE WHEN %5$s THEN 1 ELSE 0 END AS MET_X4,
           '%6$s' AS EVIDENCE
    FROM %7$s c",
    wrk("S_ELIGIBILITY"),
    cohort_flag_pred_one("X1_prior_mm_tx", .cohort_cols()),
    cohort_flag_pred_one("X2_other_cancer", .cohort_cols()),
    cohort_flag_pred_one("X3_pregnancy", .cohort_cols()),
    cohort_flag_pred_one("X4_belantamab", .cohort_cols()),
    gsub("'", "''", evidence), input_cohort_tbl()),
    qc = sprintf("SELECT count(*) AS n_patients,
                    count(DISTINCT PATID) AS n_distinct,
                    sum(1 - MET_X1) AS n_fail_x1, sum(1 - MET_X2) AS n_fail_x2,
                    sum(1 - MET_X3) AS n_fail_x3, sum(1 - MET_X4) AS n_fail_x4
                  FROM %s", wrk("S_ELIGIBILITY")))

  # One row per patient is the contract every downstream join rests on. The
  # upstream table is checked for duplicate PATIDs by check_cohort_table(), but
  # that runs before this and against a different statement; this asserts the
  # property on the table this package wrote, which is the one that is joined.
  d <- db_q(con, sprintf(
    "SELECT count(*) AS n, count(DISTINCT PATID) AS n_pat FROM %s",
    wrk("S_ELIGIBILITY")))
  # A driver that answers with nothing usable leaves the check unable to say
  # anything, and this is not the place to fail a run over a driver quirk -
  # the same reading check_cohort_table() takes of its own aggregate.
  num <- function(x) {
    v <- suppressWarnings(as.numeric(if (is.null(d[[x]])) NA else d[[x]]))
    if (!length(v) || is.na(v[1])) NA_real_ else v[1]
  }
  n <- num("n"); n_pat <- num("n_pat")
  if (!is.na(n) && !is.na(n_pat) && n != n_pat)
    stop("ELIGIBILITY ERROR: ", wrk("S_ELIGIBILITY"), " holds ", n,
         " row(s) for ", n_pat, " patient(s). Every downstream join is ",
         "on PATID and would multiply the duplicated patients through the ",
         "whole run. The duplication is in INPUT_COHORT_TABLE '",
         cfg$input_cohort_table, "'.", call. = FALSE)

  log_msg("  eligibility: ", if (is.na(n_pat)) "?" else n_pat,
          " patient(s), exclusions read ", evidence)
}
