# Sensitivity of the LOT algorithm to its own thresholds.
#
# Idea 2(d): vary the parameters and record what moves, with the direction
# stated BEFORE the run rather than read off afterwards.
#
# That ordering is the whole value. A table of numbers from thirteen builds says
# nothing on its own - every threshold changes something, so every cell differs
# and a reader nods. Stating which way each metric should move first turns it
# into a test: a cell that moves the other way is either a bug or a hole in our
# reading of the algorithm, and either is worth knowing.
#
# ---- what this costs ------------------------------------------------------
#
# One cell is one complete LOT build. There is no cheaper way: the gap
# threshold changes how MAPs are formed, which changes the lines, which changes
# everything after them - none of it recoverable from an existing LOT_LONG the
# way nndm recomputes its CE alternatives inside one run.
#
# So the grid is ONE-AT-A-TIME from the shipped configuration, not a
# cross-product. Six parameters with two alternatives each is thirteen builds,
# not seven hundred and twenty-nine. A cross-product would be the honest thing if
# the parameters interacted strongly; they mostly do not, and thirteen builds is
# already a serious amount of warehouse.
#
# ---- what is NOT here -----------------------------------------------------
#
# The ask names four axes. Two of them are not this package's to vary:
#
#   maintenance-as-LOT vs flag   NOT A SETTING. Maintenance is a descriptive
#                                flag (contains_mtx_reg) and there is no
#                                maintenance period - 05_sct.R:13. Making it a
#                                line would be a new algorithm, not a
#                                sensitivity of this one, so there is nothing
#                                here to sweep. It is a real divergence from
#                                other algorithms and it is in the vignette
#                                catalogue instead.
#
#   CE requirements              The COHORT build's axis, not LOT's. nndm
#                                already reports it without rebuilding
#                                anything - NDMM_FU_CE_COUNTS gives the cohort
#                                at 0/30/60/90 days from one run. Sweeping it
#                                here would mean rebuilding the cohort AND the
#                                LOT per cell, which is a different order of
#                                cost and a different package's question.

# Each axis: the values to try beside the shipped one, and what should happen.
#
# `direction` is per metric, and `confidence` says whether it follows from a
# rule or is our reading. Same distinction the vignettes make, and for the same
# reason: a predicted direction that turns out wrong means something different
# depending on how sure we were.
#
#   up / down / none   the expected sign as the parameter INCREASES
#   unclear            two effects pull against each other; recorded so the run
#                      settles it rather than a guess being scored as a hit
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

  list(param = "MAX_LOT", cfg = "max_lot",
       values = c(3L, 8L),
       what = "highest line built",
       expect = list(n_lines = "up", n_patients = "none",
                     pct_reaching_lot3 = "up"),
       confidence = "derived",
       why = paste0("Purely a cap. Raising it builds lines that were being ",
                    "discarded; it cannot change who has a LOT1."))
)

# What each cell is measured on. Read from the cell's OWN outputs, so a cell
# that failed contributes nothing rather than the previous cell's numbers.
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

# One statement per cell. LOT_ATTRITION already holds the progression counts,
# so the reaching-LOTn figures come from the funnel this build writes rather
# than being derived a second way here.
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
# The reference cell is built like any other rather than assumed: a run already
# sitting under the study prefix may have been built with settings that have
# since changed, and a reference nobody checked is the one number every delta
# in the table leans on.
sens_plan <- function(axes = SENS_AXES, prefix_base = "sens_") {
  cells <- list(list(id = "reference", param = NA_character_, value = NA_integer_,
                     prefix = paste0(prefix_base, "ref_")))
  for (a in axes)
    for (v in a$values)
      cells[[length(cells) + 1L]] <- list(
        id     = paste0(tolower(a$param), "_", v),
        param  = a$param, value = as.integer(v), axis = a,
        prefix = paste0(prefix_base, tolower(sub("_DAYS$", "", a$param)), "_", v, "_"))
  cells
}

# Refuse a plan that would quietly cost more than the operator expects, and
# refuse one that would write over the study's own tables.
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

# Which way a metric actually moved, against which way it was expected to.
#
# Compared as a SIGN, not a size. How far a threshold moves a number depends on
# the cohort; which way it moves is a property of the algorithm, and that is
# the part worth predicting.
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
    shipped <- as.numeric(r$shipped_value)
    higher  <- as.numeric(r$value) > shipped
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
        # "unclear" was recorded so the run could settle it - it is never a
        # miss, and scoring it as one would reward confident guesses.
        verdict = if (identical(want, "unclear")) "recorded"
                  else if (is.na(moved)) "no data"
                  else if (identical(moved, want)) "as expected" else "AGAINST EXPECTATION",
        confidence = a$confidence,
        stringsAsFactors = FALSE)
    }
  }
  if (!length(out)) return(NULL)
  do.call(rbind, out)
}
