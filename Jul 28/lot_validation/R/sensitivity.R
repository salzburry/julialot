# Sensitivity of the LOT algorithm to its own thresholds.
#
# Vary one parameter at a time and record what moves. The direction is stated
# BEFORE the run, so a metric that moves the other way is a finding rather than
# a number a reader nods at.
#
# One cell is one complete LOT build - the gap threshold changes how MAPs are
# formed, which changes everything after them, and none of it is recoverable
# from an existing LOT_LONG. Six parameters with two values each, plus a
# seventh that is on or off, is fourteen builds. A cross-product would be over
# a thousand.
#
# Continuous enrolment is two different questions, and only one of them is the
# cohort's:
#
#   CE eligibility               Who qualifies. The cohort build's axis, and
#                                NDMM_FU_CE_COUNTS already reports 0/30/60/90
#                                days from one run.
#   CE as censoring              Whether LOT stops observing at disenrolment.
#                                That IS a setting here - censor_at_disenrollment
#                                - and it is swept below.
#
# One axis the ask named cannot be swept here:
#
#   maintenance-as-LOT vs flag   Not a setting. Maintenance is a descriptive
#                                flag and there is no maintenance period
#                                (05_sct.R:13), so a line would be a different
#                                algorithm. It is in the vignettes instead.

# Each axis: the values to try beside the shipped one, and what should happen.
#
# `confidence` says whether the direction follows from a rule or is our
# reading. The expected sign is for the parameter INCREASING:
#
#   up / down / none   what the metric should do
#   unclear            two effects pull against each other; recorded, never
#                      scored, so a guess cannot be counted as a hit
SENS_AXES <- list(
  list(param = "MAP_DISCON_GAP_DAYS", cfg = "map_discon_gap_days",
       values = c(60L, 120L),
       what = "gap after a MAP ends that counts as discontinuation",
       expect = list(n_lines = "down", pct_reaching_lot2 = "down",
                     median_lot1_length = "up", n_patients = "none"),
       confidence = "derived",
       why = paste0("A longer tolerated gap discontinues fewer agents, so fewer ",
                    "regimen changes become line boundaries. Patients are not ",
                    "gained or lost by it - the cohort is fixed before LOT runs.")),

  list(param = "INDUCTION_WINDOW_DAYS", cfg = "induction_window_days",
       values = c(30L, 90L),
       what = "days a med may join LOT1's regimen",
       expect = list(n_lot1_regimens = "down", median_lot1_meds = "up",
                     n_lines = "unclear", n_patients = "none"),
       confidence = "to_confirm",
       why = paste0("A longer window pulls more agents into LOT1's regimen, so ",
                    "regimens get larger and the distinct set of them narrows. ",
                    "Whether that changes the LINE count is genuinely unclear: ",
                    "an agent absorbed into induction is one that did not start ",
                    "a line, but the window does not by itself end anything.")),

  list(param = "INDUCTION_WINDOW_DAYS_LOT_N", cfg = "lot_n_induction_window_days",
       values = c(15L, 60L),
       what = "the same window for LOT2 and later",
       expect = list(n_lines = "unclear", n_patients = "none",
                     pct_reaching_lot3 = "unclear"),
       confidence = "to_confirm",
       why = "Same argument as LOT1's window, applied where the lines are fewer."),

  list(param = "CART_CONSOLIDATION_DAYS", cfg = "cart_consolidation_days",
       values = c(30L, 60L),
       what = "days after a med addition within which CAR-T closes the line",
       expect = list(n_cart_init = "up", n_lines = "down", n_patients = "none"),
       confidence = "derived",
       why = paste0("A longer window catches more additions as bridging, so more ",
                    "lines end as CART_INIT rather than the addition starting a ",
                    "line of its own.")),

  list(param = "SCT_TANDEM_DAYS", cfg = "sct_tandem_days",
       values = c(90L, 365L),
       what = "days within which a second AUTO is the tandem of the first",
       expect = list(n_lines = "down", n_patients = "none"),
       confidence = "derived",
       why = paste0("A longer tandem window makes more second transplants part of ",
                    "a pair rather than excess, and excess AUTO is what ends LOT1.")),

  # The only axis that changes the OBSERVATION WINDOW rather than a threshold
  # inside it, and the only one whose metrics have no derivable direction. Every
  # prediction here is "unclear", which the harness records and never scores -
  # a wrong sign would be a false failure in every sweep forever.
  #
  # Shortening observation pulls two ways at once:
  #
  #   fewer, shorter    OBS_END_DT becomes coalesce(ENDDATE_CE, ENDDATE), so
  #                     every claim window closes at or before where it closed.
  #                     Nothing is found later than before, and a patient whose
  #                     first non-steroid agent lands after they disenrolled has
  #                     no LOT1 at all - lot1_start reads map_stacked, which is
  #                     bounded by OBS_END_DT.
  #   more, and MORE    the no_belantamab criterion reads the same bounded
  #     patients        map_stacked (line_criteria.R) and truncates EVERY line of
  #                     a patient who has one. A belantamab MAP between
  #                     ENDDATE_CE and ENDDATE is visible to the reference cell
  #                     and invisible to this one - so a patient the primary run
  #                     removes entirely is kept here, and n_patients RISES.
  #
  # The ratios have no direction either: pct_reaching_lotN is patients reaching
  # the line over patients with a LOT1, and both move. The median is over a set
  # whose membership changes, so per-patient shortening does not carry to it.
  list(param = "CENSOR_AT_DISENROLLMENT", cfg = "censor_at_disenrollment",
       values = TRUE,
       what = "whether observation also ends at disenrolment, not only at death or study end",
       expect = list(n_lines = "unclear", median_lot1_length = "unclear",
                     pct_reaching_lot2 = "unclear", pct_reaching_lot3 = "unclear",
                     n_patients = "unclear"),
       confidence = "to_confirm",
       why = paste0("Shortening observation pulls both ways. Fewer triggers are ",
                    "reachable, so lines and lengths tend down - but the ",
                    "no_belantamab criterion also reads the shortened window, ",
                    "and it truncates every line of a patient it catches. A ",
                    "belantamab claim between disenrolment and study end is ",
                    "visible to the reference cell and invisible to this one, ",
                    "so a patient the primary run removes outright is kept here ",
                    "and the counts RISE. Which effect dominates is the cohort's ",
                    "doing, not the algorithm's, so nothing is predicted: the ",
                    "numbers are recorded and a mover is investigated, starting ",
                    "with NO_BELANTAMAB_ANY_LOT.")),

  list(param = "MAX_LOT", cfg = "max_lot",
       values = c(3L, 8L),
       what = "highest line built",
       expect = list(n_lines = "up", n_patients = "none",
                     pct_reaching_lot3 = "none"),
       confidence = "derived",
       why = paste0("Purely a cap. Raising it builds lines that were being ",
                    "discarded; it cannot change who has a LOT1 - the truncating ",
                    "criterion is asked of the claims, not of the built lines ",
                    "(line_criteria.R). Reaching LOT3 cannot move either: both ",
                    "alternatives are at or above three, so LOT3 is built in ",
                    "every cell and the same patients reach it. Only a value ",
                    "below three would change that row, and then it would be ",
                    "absent rather than lower."))
)

# What each cell is measured on, from the cell's OWN tables - so a failed cell
# contributes nothing rather than the previous cell's numbers.
SENS_METRICS <- c(
  n_patients         = "patients with at least one line in LOT_LONG_FINAL",
  n_lines            = "lines in LOT_LONG_FINAL",
  median_lines       = "median lines per patient",
  pct_reaching_lot2  = "% of LOT1 patients who reach LOT2",
  pct_reaching_lot3  = "% of LOT1 patients who reach LOT3",
  median_lot1_length = "median LOT1 length in days (inclusive)",
  median_lot1_meds   = "median agents in a LOT1 regimen",
  n_lot1_regimens    = "distinct LOT1 regimen strings",
  n_cart_init        = "lines ending CART_INIT")

# One statement per cell. The reaching-LOTn figures come from LOT_ATTRITION,
# which already holds them, rather than being derived a second way.
sens_metric_sql <- function(final_tbl, attrition_tbl, run_id) {
  paste0("
    WITH per_pat AS (
      SELECT PATID, count(*) AS n_lines, max(LOT_NUM) AS max_lot
      FROM ", final_tbl, " GROUP BY PATID
    ),
    prog AS (
      SELECT STEP, N_PATIENTS FROM ", attrition_tbl, "
      WHERE RUN_ID = '", run_id, "' AND KIND = 'progression'
    )
    SELECT (SELECT count(*) FROM per_pat)                                   AS n_patients,
           (SELECT count(*) FROM ", final_tbl, ")                           AS n_lines,
           (SELECT percentile_approx(n_lines, 0.5) FROM per_pat)            AS median_lines,
           round(100.0 * (SELECT N_PATIENTS FROM prog WHERE STEP = 'Reached LOT2')
                 / nullif((SELECT N_PATIENTS FROM prog WHERE STEP = 'Reached LOT1'), 0), 2)
                                                                            AS pct_reaching_lot2,
           round(100.0 * (SELECT N_PATIENTS FROM prog WHERE STEP = 'Reached LOT3')
                 / nullif((SELECT N_PATIENTS FROM prog WHERE STEP = 'Reached LOT1'), 0), 2)
                                                                            AS pct_reaching_lot3,
           (SELECT percentile_approx(LOT_BASE_LENGTH, 0.5) FROM ", final_tbl, "
             WHERE LOT_NUM = 1 AND LOT_BASE_LENGTH IS NOT NULL)             AS median_lot1_length,
           (SELECT percentile_approx(LOT_MED_CNT, 0.5) FROM ", final_tbl, "
             WHERE LOT_NUM = 1)                                             AS median_lot1_meds,
           (SELECT count(DISTINCT LOT_BASE_MEDS) FROM ", final_tbl, "
             WHERE LOT_NUM = 1 AND LOT_BASE_MEDS IS NOT NULL
               AND trim(LOT_BASE_MEDS) <> '')                               AS n_lot1_regimens,
           (SELECT count(*) FROM ", final_tbl, "
             WHERE LOT_BASE_END_REASON = 'CART_INIT')                       AS n_cart_init")
}

# The grid, one at a time from the shipped configuration.
#
# The reference cell is built, not assumed. A run already under the study
# prefix may have been built with settings that have since changed, and every
# delta in the table leans on that one number.
sens_plan <- function(axes = SENS_AXES, prefix_base = "sens_") {
  cells <- list(list(id = "reference", param = NA_character_, value = NA_character_,
                     prefix = paste0(prefix_base, "ref_")))
  for (a in axes)
    for (v in a$values)
      cells[[length(cells) + 1L]] <- list(
        id     = paste0(tolower(a$param), "_", v),
        param  = a$param, value = as.character(v), axis = a,
        prefix = paste0(prefix_base, tolower(sub("_DAYS$", "", a$param)), "_", v, "_"))
  cells
}

# Refuse a plan that costs more than expected, or that would write over the
# study's own tables.
check_sens_plan <- function(cells, study_prefix, cap = 24L) {
  bad <- character(0)
  pfx <- vapply(cells, function(c_i) c_i$prefix, character(1))
  if (anyDuplicated(pfx))
    bad <- c(bad, "two cells would write to the same prefix")
  if (!all(grepl("^[A-Za-z][A-Za-z0-9_]*_$", pfx)))
    bad <- c(bad, "a cell prefix is not a valid object prefix")
  if (nzchar(study_prefix) && study_prefix %in% pfx)
    bad <- c(bad, paste0("a cell would write to the study's own prefix '",
                         study_prefix, "', overwriting the run being measured"))
  if (length(cells) > cap)
    bad <- c(bad, paste0(length(cells), " cells is more than the cap of ", cap,
                         "; each one is a complete LOT build. Narrow SENS_AXES ",
                         "or raise SENS_MAX_CELLS deliberately."))
  if (length(bad))
    stop("The sensitivity plan is not safe to run:\n  ",
         paste(bad, collapse = "\n  "), call. = FALSE)
  invisible(TRUE)
}

# Values travel as text, so a switch survives the trip. as.integer(TRUE) is 1,
# and the build reads as.logical("1") as NA - the cell would then be a silent
# copy of the reference and every metric would read "no movement".
#
# Ranked numerically here only to say which side of the shipped value a cell
# sits on, with FALSE below TRUE.
sens_rank <- function(x) {
  x <- toupper(trimws(as.character(x)))
  ifelse(x == "TRUE", 1, ifelse(x == "FALSE", 0, suppressWarnings(as.numeric(x))))
}

# Which way a metric moved, against which way we said it would.
#
# The SIGN, not the size. How far a threshold moves a number depends on the
# cohort; which way it moves is the algorithm.
#
# Four verdicts:
#
#   as expected          moved the way we said
#   AGAINST EXPECTATION  moved the other way, or moved when "none" was said.
#                        This is the finding.
#   no movement          a direction was predicted and nothing changed. Not the
#                        opposite finding: whether anyone sits near a threshold
#                        is the cohort's doing, not the algorithm's.
#   recorded / no data   "unclear" was predicted, or the cell gave nothing.
sens_compare <- function(results, axes = SENS_AXES, tol = 1e-9) {
  ref <- results[results$cell == "reference", , drop = FALSE]
  if (!nrow(ref)) stop("No reference cell in the results.", call. = FALSE)
  out <- list()
  by_param <- setNames(axes, vapply(axes, function(a) a$param, character(1)))
  for (i in seq_len(nrow(results))) {
    r <- results[i, , drop = FALSE]
    if (identical(r$cell, "reference")) next
    a <- by_param[[r$param]]
    if (is.null(a)) next
    shipped <- sens_rank(r$shipped_value)
    higher  <- sens_rank(r$value) > shipped
    for (m in names(a$expect)) {
      if (!m %in% names(results)) next
      got <- as.numeric(r[[m]]); base <- as.numeric(ref[[m]])
      if (is.na(got) || is.na(base)) { moved <- NA_character_ }
      else if (abs(got - base) <= tol) moved <- "none"
      else moved <- if ((got > base) == higher) "up" else "down"
      want <- a$expect[[m]]
      out[[length(out) + 1L]] <- data.frame(
        cell = r$cell, param = r$param, value = r$value, metric = m,
        reference = base, observed = got,
        expected = want, moved = moved,
        # "unclear" is never a miss - scoring it would reward a lucky guess.
        # Nor is "no movement": a cell that moved nothing has contradicted
        # nothing. Predicting "none" and getting movement IS a miss.
        verdict = if (identical(want, "unclear")) "recorded"
                  else if (is.na(moved)) "no data"
                  else if (identical(moved, want)) "as expected"
                  else if (identical(moved, "none")) "no movement"
                  else "AGAINST EXPECTATION",
        confidence = a$confidence,
        stringsAsFactors = FALSE)
    }
  }
  if (!length(out)) return(NULL)
  do.call(rbind, out)
}
