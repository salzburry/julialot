# The three builds this asks for, and what is read off them.
#
# The rule itself is not here - it is lot/engine/R/melp_rule.R, because the
# engine builds the lines. This file is the experiment: which builds, what to
# measure, and how to read one against another.
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
       what = paste0("every melphalan exposure judged, including one with a ",
                     "transplant coded on it - so one clinical event can end a ",
                     "line twice. The transplant question answered the way the ",
                     "request implies, since it carves nothing out")),
  list(id = "yield_to_sct", mode = "yield_to_sct",
       what = paste0("the same, except that an exposure with an AUTO coded ",
                     "within MELP_SCT_DAYS is left to the transplant rule. The ",
                     "melphalan rule then fills only the gap where a transplant ",
                     "left no procedure code")))

# Neither cell is the rule exactly as written, and the names do not say so: they
# name the transplant reading, which is what separates the two. On B.2 both take
# the narrow reading - the melphalan boundary is removed, and the line is not
# held open to the second dose, because that would need melphalan to join a
# regimen whose induction window it never entered. Open question 6 in
# lot/questions/melphalan_lot_rule.md, and n_b2_line_starts counts what it
# decides.
MELP_B2_READING <- paste0(
  "B.2: the melphalan boundary is removed and the line is not held open to the ",
  "second dose. Both cells take this reading - see open question 6.")

# The cell's own run id, from its own status row. Reading LOT_ATTRITION or
# LOT_RUN_METADATA without it would take whichever run's rows came back first.
cell_run_id <- function(con, c_i) {
  # paste0, not glue. Everything else in this file builds SQL that way, and a
  # lone glue() call makes the package an attach dependency of every script that
  # sources it - read_melp_metrics.R does not attach it and died here.
  st <- tryCatch(db_q(con, paste0(
    "SELECT RUN_ID FROM ", wrk(paste0(c_i$prefix, "LOT_BUILD_STATUS")),
    " ORDER BY UPDATED_AT DESC LIMIT 1")), error = function(e) NULL)
  if (is.null(st) || !nrow(st))
    stop("No LOT_BUILD_STATUS row under ", c_i$prefix, ", so there is no run ",
         "to read ", c_i$id, "'s numbers from.", call. = FALSE)
  st$RUN_ID[1]
}

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

# What every cell has to agree on before any difference between them can be
# called the rule's.
#
# The runner already requires one cohort table and one cohort prefix. That is
# not enough: a table name is not a cohort attempt. Re-running the cohort build
# under the same prefix replaces NDMM_COHORT in place, so a reference built over
# attempt A and two cells built over attempt B all complete, all look right, and
# the A-to-B difference is reported as the effect of melphalan. The same goes
# for a production code list edited between cells, for the LOT code itself, and
# for the study window.
#
# LOT records all of it: the cohort attempt it read in LOT_RUN_METADATA, the
# code fingerprint and study window beside it, and every code list's md5 in
# LOT_CODELIST_METADATA. So the check is to read it back rather than to trust
# that three sequential builds saw the same world.
MELP_INPUT_FIELDS <- c(
  COHORT_RUN_ID = "the cohort build's run",
  COHORT_STAMP  = "...and its attempt, since a re-run keeps the run id",
  STUDY_START   = "the study window's start",
  STUDY_END     = "...and its end",
  CODE_MD5      = "the LOT code that built it",
  CODELIST_MD5  = "every production code list it read")

# Three tables, because the run does not record all of this in one place.
# CONTRACT_DEVIATIONS is a column of LOT_BUILD_STATUS and not of
# LOT_RUN_METADATA - deliberately, since the status row is the one every
# downstream reader uses to decide which run owns a prefix. Selecting it from
# the metadata table is an unresolved column, and the whole query fails.
melp_inputs_sql <- function(meta_tbl, codelist_tbl, status_tbl, run_id) {
  paste0("
    SELECT m.COHORT_RUN_ID, m.COHORT_STAMP, m.STUDY_START, m.STUDY_END,
           m.CODE_MD5, m.CONTRACT_SETTINGS,
           (SELECT concat_ws('|', sort_array(collect_list(
                     concat(c.CODELIST_FILE, ':', c.MD5))))
            FROM ", codelist_tbl, " c WHERE c.RUN_ID = '", run_id, "')
                                                            AS CODELIST_MD5,
           (SELECT max(s.CONTRACT_DEVIATIONS)
            FROM ", status_tbl, " s WHERE s.RUN_ID = '", run_id, "')
                                                            AS CONTRACT_DEVIATIONS
    FROM ", meta_tbl, " m WHERE m.RUN_ID = '", run_id, "'")
}

# Every field the same across every cell, or the comparison is not about the
# rule. Reported as a list rather than a first failure, because an operator
# fixing one and re-running only to hit the next is how a sweep gets abandoned.
melp_check_inputs <- function(rows) {
  bad <- character(0)
  for (f in names(MELP_INPUT_FIELDS)) {
    v <- vapply(rows, function(r) {
      x <- r[[f]]
      if (is.null(x) || length(x) == 0 || is.na(x[1])) "<none>" else as.character(x[1])
    }, character(1))
    if (length(unique(v)) > 1L)
      bad <- c(bad, paste0("  ", f, " (", MELP_INPUT_FIELDS[[f]], "):\n",
                           paste0("    ", names(rows), " = ", v, collapse = "\n")))
    else if (identical(unique(v), "<none>"))
      bad <- c(bad, paste0("  ", f, " (", MELP_INPUT_FIELDS[[f]],
                           "): not recorded by any cell, so it cannot be compared"))
  }
  if (length(bad))
    stop("The three cells were not built over the same inputs, so the ",
         "differences between them are not the rule's:\n",
         paste(bad, collapse = "\n"),
         "\nRebuild all three without touching the cohort or the code lists.",
         call. = FALSE)
  invisible(TRUE)
}

# And each cell has to be the algorithm it says it is.
#
# The reference must carry no deviation: if it needed one it is not the contract
# build, and every delta is measured against the wrong thing. Each mode must
# carry the melphalan deviation, naming the mode that cell is supposed to be -
# and nothing else, because the cells are three separate processes and a second
# setting reaching one of them would be read as the rule's effect.
#
# check_lot_contract() writes one entry per wrong setting as
# "key=value (contract value)", pipe-separated by write_build_status(). So the
# entries are what is counted, and the mode is matched inside its own entry
# rather than anywhere in the string.
melp_check_deviations <- function(rows, cells) {
  mode_of <- setNames(lapply(cells, function(c_i) c_i$mode),
                      vapply(cells, function(c_i) c_i$id, character(1)))
  bad <- character(0)
  for (id in names(rows)) {
    dev <- rows[[id]]$CONTRACT_DEVIATIONS
    dev <- if (is.null(dev) || length(dev) == 0 || is.na(dev[1])) "" else trimws(dev[1])
    entries <- trimws(unlist(strsplit(dev, "|", fixed = TRUE)))
    entries <- entries[nzchar(entries)]
    want <- mode_of[[id]]
    if (is.na(want)) {
      if (length(entries))
        bad <- c(bad, paste0("  ", id, " is meant to be the contract build but ",
                             "deviates on: ", paste(entries, collapse = "; ")))
      next
    }
    melp  <- grep("^apply_melp_rule=", entries)
    other <- entries[-melp]
    if (!length(melp))
      bad <- c(bad, paste0("  ", id, " is meant to build the rule but records no ",
                           "melphalan deviation (",
                           if (length(entries)) paste(entries, collapse = "; ") else "none", ")"))
    else if (!any(grepl(paste0("^apply_melp_rule=", want, "\\b"), entries[melp])))
      bad <- c(bad, paste0("  ", id, " is meant to build ", want,
                           " but records: ", paste(entries[melp], collapse = "; ")))
    if (length(other))
      bad <- c(bad, paste0("  ", id, " changed something other than the rule: ",
                           paste(other, collapse = "; ")))
  }
  if (length(bad))
    stop("A cell is not the algorithm it claims:\n", paste(bad, collapse = "\n"),
         call. = FALSE)
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
  n_pat_with_melp    = "patients with any melphalan line",
  n_b2_line_starts   = "MED-started lines whose start is a B.2 second dose",
  n_b2_melp_only     = "...of those, the ones no other agent would have started")

# One statement per cell. The reaching-LOTn figures come from LOT_ATTRITION,
# which already holds them, rather than being derived a second way.
#
# The four melphalan figures are where the double-count shows. If as_asked ends
# more lines by melphalan than yield_to_sct does, and the transplant ends fewer,
# the two rules were firing on the same events - which is the question the two
# cells exist to settle.
# ind1 / indn / cart are the build's own induction windows, needed to tell a
# previous line's B exposure from an A one. map_tbl is the persisted MAP stack,
# which is what makes the B.2 count exact rather than a proxy.
# Several statements, not one.
#
# It was one SELECT with nineteen scalar subqueries over seven CTEs, two of
# them window queries. Spark turns each scalar subquery into a join, and the
# 2026-08-12 reference run died in the optimizer - "The Spark SQL phase
# optimization failed with an internal error" - before executing anything, so
# all four retries failed the same way. Split, each plan is ordinary.
#
# Same numbers: these are independent aggregates that never needed one plan.
# The counts that shared a scan now share a CASE instead.
#
# Returns one statement per name. melp_metrics() runs them and cbinds the row.
melp_metric_sql <- function(final_tbl, attrition_tbl, run_id, abbr = "MELP",
                            map_tbl = NULL, expo_days = 30L, restart_days = 60L,
                            advance_days = 180L, ind1 = 60L, indn = 30L,
                            cart = 45L) {
  in_melp <- paste0("array_contains(split(upper(coalesce(LOT_BASE_MEDS, '')), ' '), '", abbr, "')")

  # The melphalan exposure chain, the way lot/engine/R/melp_rule.R chains it:
  # doses closer together than expo_days are one administration. Rebuilt here
  # because the engine's version is a CTE inside a build, not a table. Both B.2
  # statements need it, and it is small enough to derive twice.
  mx_with <- paste0("
    WITH mdose AS (
      SELECT PATID, MAP_START_DT AS DOSE_DT FROM ", map_tbl, "
      WHERE upper(trim(MAP_MED_TYPE)) = '", abbr, "' GROUP BY PATID, MAP_START_DT
    ),
    mrun AS (
      SELECT PATID, DOSE_DT,
             CASE WHEN datediff(DOSE_DT,
                    lag(DOSE_DT) OVER (PARTITION BY PATID ORDER BY DOSE_DT))
                       < ", expo_days, " THEN 0 ELSE 1 END AS IS_NEW
      FROM mdose
    ),
    mxe AS (
      SELECT PATID, min(DOSE_DT) AS EXPO_DT
      FROM (SELECT PATID, DOSE_DT,
                   sum(IS_NEW) OVER (PARTITION BY PATID ORDER BY DOSE_DT
                                     ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS E
            FROM mrun) r
      GROUP BY PATID, E
    ),
    -- Each exposure with the one immediately before it. The engine judges
    -- consecutive pairs, so the pair has to be consecutive here too: exposures
    -- on days 100, 160 and 250 give the engine 100-160 and 160-250, and a range
    -- join would also match 100-250 and report one line twice.
    mx AS (
      SELECT PATID, EXPO_DT,
             lag(EXPO_DT) OVER (PARTITION BY PATID ORDER BY EXPO_DT) AS PREV_EXPO_DT
      FROM mxe
    )")

  # The B.2 group. All four conditions, because any one alone lets in lines with
  # no B.2 pair at all - a line DARA started, melphalan merely joining its
  # induction window, satisfies "after a runout, melphalan in the regimen".
  # Open question 6 in lot/questions/melphalan_lot_rule.md.
  b2 <- function(extra, alias) paste0(mx_with, "
    SELECT count(*) AS ", alias, "
    FROM (SELECT l.PATID, l.LOT_NUM, l.LOT_START_DT, l.LOT_START_TYPE,
                 lag(l.LOT_NUM)             OVER w AS PREV_LOT_NUM,
                 lag(l.LOT_START_DT)        OVER w AS PREV_START_DT,
                 lag(l.LOT_START_TYPE)      OVER w AS PREV_START_TYPE,
                 lag(l.LOT_BASE_END_REASON) OVER w AS PREV_REASON
          FROM ", final_tbl, " l
          WINDOW w AS (PARTITION BY l.PATID ORDER BY l.LOT_NUM)) x
    -- One join, and the exposure carries its own immediate predecessor, so the
    -- pair is the one the engine judged and one line cannot be counted twice.
    INNER JOIN mx e ON e.PATID = x.PATID AND e.EXPO_DT = x.LOT_START_DT
    WHERE x.LOT_NUM > 1
    -- 1. the previous line ended by running out, not by melphalan
      AND x.PREV_REASON = 'DISCONTINUATION'
    -- 2. and melphalan STARTED this line. Landing on the start date is not
    -- enough: the same-day tie-break is SCT_ALLO > CART > SCT_AUTO > MED, so an
    -- AUTO coded on the melphalan date takes the start and the line is the
    -- transplant's, not the drug's.
      AND x.LOT_START_TYPE = 'MED'
    -- 3. the exposure before it sits in the previous line...
      AND e.PREV_EXPO_DT IS NOT NULL
      AND e.PREV_EXPO_DT >= x.PREV_START_DT
      AND e.PREV_EXPO_DT <  x.LOT_START_DT
    -- ...outside that line's own induction window, making it B not A
      AND datediff(e.PREV_EXPO_DT, x.PREV_START_DT) > CASE
            WHEN x.PREV_LOT_NUM = 1         THEN ", ind1 - 1L, "
            WHEN x.PREV_START_TYPE = 'CART' THEN ", cart - 1L, "
            ELSE ", indn - 1L, " END
    -- 4. and the pair 60-179 days apart, which is B.2 not B.1 or B.3
      AND datediff(x.LOT_START_DT, e.PREV_EXPO_DT)
            BETWEEN ", restart_days, " AND ", advance_days - 1L, extra)

  # The same lines, less the ones another agent would have started anyway.
  # LOT_START_TYPE = 'MED' says a medication won the tie-break, not which one,
  # so a line daratumumab also started that day exists under either reading.
  #
  # A lower bound, deliberately: med_cand also passes over the previous line's
  # agents expanded by permissible substitutes, and that expansion is a session
  # view rather than a table this can read. That drops a line, not invents one.
  melp_only <- paste0("
      AND NOT EXISTS (SELECT 1 FROM ", map_tbl, " o
                      WHERE o.PATID = x.PATID
                        AND o.MAP_START_DT = x.LOT_START_DT
                        AND o.MAP_MED_CLASS <> 'STEROID'
                        AND upper(trim(o.MAP_MED_TYPE)) <> '", abbr, "')")

  no_map <- function(alias) paste0("SELECT cast(NULL as bigint) AS ", alias)

  c(core = paste0("
    WITH per_pat AS (
      SELECT PATID, count(*) AS n_lines FROM ", final_tbl, " GROUP BY PATID
    )
    SELECT count(*)                              AS n_patients,
           sum(n_lines)                          AS n_lines,
           percentile_approx(n_lines, 0.5)       AS median_lines
    FROM per_pat"),

    prog = paste0("
    SELECT round(100.0 * max(CASE WHEN STEP = 'Reached LOT2' THEN N_PATIENTS END)
                 / nullif(max(CASE WHEN STEP = 'Reached LOT1' THEN N_PATIENTS END), 0), 2)
                                                 AS pct_reaching_lot2,
           round(100.0 * max(CASE WHEN STEP = 'Reached LOT3' THEN N_PATIENTS END)
                 / nullif(max(CASE WHEN STEP = 'Reached LOT1' THEN N_PATIENTS END), 0), 2)
                                                 AS pct_reaching_lot3
    FROM ", attrition_tbl, "
    WHERE RUN_ID = '", run_id, "' AND KIND = 'progression'"),

    # One scan of the lines. Every count that used to be its own subquery is a
    # CASE over the same rows, which is what the scalar subqueries cost most.
    lines = paste0("
    SELECT percentile_approx(CASE WHEN LOT_NUM = 1 AND LOT_BASE_LENGTH IS NOT NULL
                                  THEN LOT_BASE_LENGTH END, 0.5)   AS median_lot1_length,
           percentile_approx(CASE WHEN LOT_NUM = 1
                                  THEN LOT_MED_CNT END, 0.5)       AS median_lot1_meds,
           count(DISTINCT CASE WHEN LOT_NUM = 1 AND LOT_BASE_MEDS IS NOT NULL
                                 AND trim(LOT_BASE_MEDS) <> ''
                               THEN LOT_BASE_MEDS END)             AS n_lot1_regimens,
           sum(CASE WHEN LOT_BASE_END_REASON = 'CART_INIT' THEN 1 ELSE 0 END)
                                                                   AS n_cart_init,
           sum(CASE WHEN LOT_BASE_END_REASON = 'SCT_AUTO' THEN 1 ELSE 0 END)
                                                                   AS n_sct_auto_end,
           sum(CASE WHEN LOT_BASE_END_REASON = 'MED_ADD'
                     AND upper(trim(coalesce(LOT_BASE_1ST_ADD_MED, ''))) = '", abbr, "'
                    THEN 1 ELSE 0 END)                             AS n_melp_add,
           sum(CASE WHEN ", in_melp, " THEN 1 ELSE 0 END)          AS n_melp_lines,
           count(DISTINCT CASE WHEN ", in_melp, " THEN PATID END)  AS n_pat_with_melp
    FROM ", final_tbl),

    b2      = if (is.null(map_tbl)) no_map("n_b2_line_starts")
              else b2("", "n_b2_line_starts"),
    b2_only = if (is.null(map_tbl)) no_map("n_b2_melp_only")
              else b2(melp_only, "n_b2_melp_only"))
}

# One row, from however many statements it takes. A statement that comes back
# empty or unreadable is a NULL here, and the caller stops on it - the result is
# the comparison between all three cells, not a best effort at one.
melp_metrics <- function(con, ...) {
  qs <- melp_metric_sql(...)
  out <- list()
  for (nm in names(qs)) {
    d <- tryCatch(db_q(con, qs[[nm]]), error = function(e) NULL)
    if (is.null(d) || !is.data.frame(d) || nrow(d) != 1L) return(NULL)
    out[[nm]] <- d
  }
  do.call(cbind, unname(out))
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
      # A metric named here and not selected by melp_metric_sql() would
      # otherwise come back as a zero-length column and fail inside the
      # arithmetic, several lines from the cause.
      if (is.null(ref[[m]]) || is.null(r[[m]]))
        stop("Metric '", m, "' is named in MELP_METRICS but is not a column of ",
             "the results, so melp_metric_sql() does not select it.", call. = FALSE)
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

# The two readings against each other, patient by patient rather than by
# subtracting totals.
#
# Subtracting aggregates does not answer "how many patients does the transplant
# question affect". A patient whose lines move can leave the totals where they
# were - the SCT rule may win the end-reason priority anyway, one changed
# boundary can shift several later lines, and two patients moving opposite ways
# cancel. So the two LOT_LONG_FINAL tables are compared directly: a patient
# counts as differing if their line count, or any line's start, end or end
# reason, is not the same under both readings.
melp_modes_patients_sql <- function(a_tbl, y_tbl) {
  side <- function(t) paste0("
      SELECT cast(PATID as string) AS PATID,
             concat_ws('|', sort_array(collect_list(concat_ws(':',
               cast(LOT_NUM as string), cast(LOT_START_DT as string),
               cast(LOT_BASE_END_DT as string),
               coalesce(LOT_BASE_END_REASON, ''))))) AS SHAPE,
             count(*) AS N_LINES
      FROM ", t, " GROUP BY PATID")
  paste0("
    WITH a AS (", side(a_tbl), "),
    y AS (", side(y_tbl), ")
    SELECT count(*)                                                AS N_PATIENTS,
           sum(CASE WHEN a.PATID IS NULL OR y.PATID IS NULL THEN 1
                    ELSE 0 END)                                    AS N_ONLY_ONE_SIDE,
           sum(CASE WHEN a.SHAPE <=> y.SHAPE THEN 0 ELSE 1 END)    AS N_DIFFERENT,
           sum(CASE WHEN a.N_LINES <=> y.N_LINES THEN 0 ELSE 1 END) AS N_LINE_COUNT_DIFFERENT,
           sum(CASE WHEN NOT (a.SHAPE <=> y.SHAPE)
                     AND (a.N_LINES <=> y.N_LINES) THEN 1 ELSE 0 END)
                                                                   AS N_SAME_COUNT_DIFFERENT_LINES
    FROM a FULL OUTER JOIN y ON a.PATID = y.PATID")
}

# The aggregate view of the same thing. Useful, and not the same claim: this is
# the downstream consequence of the two readings, not a count of the events
# where both rules fired.
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
