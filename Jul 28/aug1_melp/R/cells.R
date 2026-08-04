# The three builds this asks for, and what is read off them.
#
# The rule itself is not here - it is lot/R/melp_rule.R, because lot builds the
# lines. This file is the experiment: which builds, what to measure, and how to
# read one against another.
#
# Three cells, because the ask leaves one thing open. Melphalan is transplant
# conditioning, so a melphalan claim and an AUTO procedure code are often the
# same clinical event, and the transplant rule already fires on it. The request
# does not say which rule should win. So both readings are built and the
# difference between them is the answer to that question, in patients.
MELP_CELLS <- list(
  list(id = "reference", mode = NA_character_,
       what = "the contract build, unchanged - what the study has today"),
  list(id = "as_asked", mode = "as_asked",
       what = paste0("the rule exactly as written. Every melphalan exposure is ",
                     "judged, including one with a transplant coded on it, so ",
                     "one clinical event can end a line twice")),
  list(id = "yield_to_sct", mode = "yield_to_sct",
       what = paste0("the same rule, except that an exposure with an AUTO ",
                     "coded within MELP_SCT_DAYS is left to the transplant ",
                     "rule. The melphalan rule then fills only the gap where a ",
                     "transplant left no procedure code")))

melp_cell_plan <- function(cells = MELP_CELLS, prefix_base = "melp_") {
  lapply(cells, function(c_i)
    c(c_i, list(prefix = paste0(prefix_base, c_i$id, "_"))))
}

# Refuse a plan that would write over the study's own tables. A cell is a whole
# LOT build with CREATE OR REPLACE in it, so this is the one mistake that
# cannot be undone.
check_melp_plan <- function(cells, study_prefix) {
  bad <- character(0)
  pfx <- vapply(cells, function(c_i) c_i$prefix, character(1))
  if (anyDuplicated(pfx))
    bad <- c(bad, "two cells share a prefix, so one would overwrite the other")
  if (nzchar(study_prefix) && study_prefix %in% pfx)
    bad <- c(bad, paste0("a cell writes to '", study_prefix,
                         "', which is the study's own prefix"))
  if (!all(grepl("^[A-Za-z][A-Za-z0-9_]*_$", pfx)))
    bad <- c(bad, "a cell prefix is not a valid object prefix")
  if (length(bad)) stop(paste(bad, collapse = "; "), call. = FALSE)
  invisible(TRUE)
}

# What is read off each build. The same nine numbers the sensitivity harness
# uses, so a melphalan cell and a threshold cell can be read side by side, plus
# four that are about this rule in particular.
MELP_METRICS <- c(
  n_patients         = "patients with at least one line in LOT_LONG_FINAL",
  n_lines            = "lines in LOT_LONG_FINAL",
  median_lines       = "median lines per patient",
  pct_reaching_lot2  = "% of LOT1 patients who reach LOT2",
  pct_reaching_lot3  = "% of LOT1 patients who reach LOT3",
  median_lot1_length = "median LOT1 length in days (inclusive)",
  median_lot1_meds   = "median agents in a LOT1 regimen",
  n_lot1_regimens    = "distinct LOT1 regimen strings",
  n_cart_init        = "lines ending CART_INIT",
  n_melp_add         = "lines ended by melphalan as an added medication",
  n_melp_lines       = "lines whose regimen contains melphalan",
  n_sct_auto_end     = "lines ended by an autologous transplant",
  n_pat_with_melp    = "patients with any melphalan line")

# One statement per cell. The reaching-LOTn figures come from LOT_ATTRITION,
# which already holds them, rather than being derived a second way.
#
# The four melphalan figures are where the double-count shows. If as_asked ends
# more lines by melphalan than yield_to_sct does, and the transplant ends fewer,
# the two rules were firing on the same events - which is the question the two
# cells exist to settle.
melp_metric_sql <- function(final_tbl, attrition_tbl, run_id, abbr = "MELP") {
  paste0("
    WITH per_pat AS (
      SELECT PATID, count(*) AS n_lines, max(LOT_NUM) AS max_lot
      FROM ", final_tbl, " GROUP BY PATID
    ),
    prog AS (
      SELECT STEP, N_PATIENTS FROM ", attrition_tbl, "
      WHERE RUN_ID = '", run_id, "' AND KIND = 'progression'
    ),
    melp AS (
      SELECT PATID, LOT_BASE_END_REASON, LOT_BASE_1ST_ADD_MED, LOT_BASE_MEDS
      FROM ", final_tbl, "
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
             WHERE LOT_BASE_END_REASON = 'CART_INIT')                       AS n_cart_init,
           (SELECT count(*) FROM melp
             WHERE LOT_BASE_END_REASON = 'MED_ADD'
               AND upper(trim(coalesce(LOT_BASE_1ST_ADD_MED, ''))) = '", abbr, "')
                                                                            AS n_melp_add,
           (SELECT count(*) FROM melp
             WHERE array_contains(split(upper(coalesce(LOT_BASE_MEDS, '')), ' '), '", abbr, "'))
                                                                            AS n_melp_lines,
           (SELECT count(*) FROM ", final_tbl, "
             WHERE LOT_BASE_END_REASON = 'SCT_AUTO')                        AS n_sct_auto_end,
           (SELECT count(DISTINCT PATID) FROM melp
             WHERE array_contains(split(upper(coalesce(LOT_BASE_MEDS, '')), ' '), '", abbr, "'))
                                                                            AS n_pat_with_melp")
}

# Each cell against the reference. No direction is predicted, and that is the
# difference between this and the sensitivity sweep: there a threshold moves a
# number a way we can reason about beforehand, so predicting the sign first is a
# test. Here the rule moves boundaries in both directions at once - A.2 adds
# lines, B.2 and B.3 remove them - and which wins is what the run is for.
# Writing down a guess would be a guess.
melp_compare <- function(results, cells = MELP_CELLS) {
  ref <- results[results$cell == "reference", , drop = FALSE]
  if (!nrow(ref)) stop("No reference cell in the results.", call. = FALSE)
  out <- list()
  for (i in seq_len(nrow(results))) {
    r <- results[i, , drop = FALSE]
    if (identical(r$cell, "reference")) next
    for (m in names(MELP_METRICS)) {
      base <- suppressWarnings(as.numeric(ref[[m]][1]))
      got  <- suppressWarnings(as.numeric(r[[m]][1]))
      out[[length(out) + 1L]] <- data.frame(
        cell = r$cell, metric = m, reference = base, observed = got,
        change = if (is.na(base) || is.na(got)) NA_real_ else got - base,
        pct_change = if (is.na(base) || is.na(got) || base == 0) NA_real_
                     else round(100 * (got - base) / base, 2),
        stringsAsFactors = FALSE)
    }
  }
  do.call(rbind, out)
}

# The one comparison that is not against the reference: the two readings against
# each other. Their difference is the double-count - the events the transplant
# rule and the melphalan rule both claimed - which is the open question the
# request left, answered in patients rather than argued.
melp_modes_apart <- function(results) {
  a <- results[results$cell == "as_asked", , drop = FALSE]
  y <- results[results$cell == "yield_to_sct", , drop = FALSE]
  if (!nrow(a) || !nrow(y)) return(NULL)
  do.call(rbind, lapply(names(MELP_METRICS), function(m) data.frame(
    metric = m,
    as_asked = suppressWarnings(as.numeric(a[[m]][1])),
    yield_to_sct = suppressWarnings(as.numeric(y[[m]][1])),
    difference = suppressWarnings(as.numeric(a[[m]][1]) - as.numeric(y[[m]][1])),
    stringsAsFactors = FALSE)))
}
