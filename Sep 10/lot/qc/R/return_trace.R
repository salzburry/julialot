# The returning-drug trace, as functions: "drugs that come back", read off a
# finished run's published tables.
#
# The study team asked to see, on live patients, what the rules adopted on
# 30 Aug 2026 (LOT_RULES.md 4.3 and 4.8) do with a drug that comes back -
# and, for the 2L question, which returns now stay inside a line that the
# earlier reading would have split. The engine keeps no flag for any of it, so
# every kind here is recognised by its signature in LOT_LONG_FINAL and
# MAP_STACKED, the way the fold-in trace (R/foldin_trace.R) recognises a fold.
# That file is reused for the fold itself; this one adds the other shapes and
# a report that holds them side by side.
#
# Four kinds of return, per (patient, line n, drug):
#
#   fold        4.8 - the drug was in line n-1's regimen, has no episode inside
#               line n's induction window, and an episode inside line n after
#               it: exactly one agent advanced the line between its two doses,
#               so it JOINED line n. foldin_trace_sql() finds these.
#
#   own_return  4.3 - the drug came back inside line n after a CONFIRMED break
#               of its own (the immediately preceding episode of that drug
#               carries MAP_DISCON_FLG = 1, a gap of map_discon_gap_days or
#               more), and that preceding episode was itself inside line n. So
#               the drug already belonged to the line: either the line's own
#               window admitted it, or 4.8 folded it in earlier and the engine
#               carries it in the line's effective regimen. The line ran on
#               over the break. Before the rule the break released the drug and
#               this return opened a new line: a 1L drug back after a holiday
#               made a 2L that no longer exists.
#
#               Read under the drug's OWN name, not through a substitute: under
#               the older reading a substitute's restart was never released
#               (SUBSTITUTE_ONLY), so it is not a return the rule changed.
#
#   opens_line  the counter-example: a drug given earlier came back and OPENED
#               a line, which neither rule prevents. Three shapes, on OPEN_VIA:
#                 new_agent      the drug is from two or more lines back, so
#                                4.8's fold set - the immediately previous
#                                line's regimen - never held it, and its
#                                episode starts on line n's start date.
#                 melp_course    a short melphalan course of the previous
#                                line's regimen that 4.7 CONFIRMED: it starts
#                                the next line on its own first day, and
#                                melphalan is the one agent 4.3 exempts.
#                 melp_confirmed a drug from two or more lines back that
#                                arrived inside such a course and confirmed
#                                it, so the line opened on the MELPHALAN date
#                                rather than on this drug's.
#               The melphalan shapes are read only where the run applied the
#               melphalan rule.
#
#   carried_over  not a return: the drug was in line n-1's regimen and has an
#               episode inside line n's window, so it is an ordinary regimen
#               drug of both lines (a backbone continuing while an agent is
#               added). Counted, never traced: it is what a reader will ask
#               "why is this not a fold" about, and the answer is the window.
#               The IMMEDIATELY previous line's drugs only - a drug from
#               further back re-dosed inside a window is an ordinary regimen
#               join (4.2) that no rule here decided, and is not counted.
#
# RETURN_LINE is the line the return belongs to for the 2L question: line n
# for a fold and an own return, and line n-1 for an opens_line row - the
# drug came back after that line and opened the next. TRACE_LINES filters on
# it, so TRACE_LINES=2 is "drugs that came back in 2L": folds into 2L, own
# returns inside 2L, and returns after 2L that opened 3L.
#
# Patient ids are not masked here, like the fold-in trace: the file exists so
# a patient can be looked up. The runner masks on request, after the reads.

.need_foldin <- function() {
  if (!exists("foldin_trace_sql", mode = "function"))
    stop("R/foldin_trace.R is not sourced. The fold kind is its query, ",
         "and the episode table is its annotation.", call. = FALSE)
}

RETURN_TRACE_KINDS <- c("fold", "own_return", "opens_line")
RETURN_TRACE_ALL_KINDS <- c(RETURN_TRACE_KINDS, "carried_over")

# The columns every kind's rows are brought to, so the kinds can be stacked.
RETURN_TRACE_COLS <- c("PATID", "LOT_NUM", "MED_ABBR", "KIND", "RETURN_LINE",
                       "LOT_START_DT", "LOT_START_TYPE", "ELIGIBLE_END",
                       "LOT_BASE_END_DT", "PREV_BASE_MEDS", "RETURN_DT",
                       "PREV_EP_START", "PREV_EP_END", "FROM_LOT",
                       "PREV_LINE_START_TYPE", "HAS_WINDOW_EP", "OPEN_VIA")

# ---- The shared CTEs ----------------------------------------------------------
# The lines with their windows come from qc_window_sql() in R/checks.R, per
# line, so the window is the one definition C1 and the fold-in trace read. The
# regimen is exploded from it here, with the line's end joined back on from
# the published table, because the per-line shape does not carry it.
.return_trace_melp <- function(p) {
  a <- toupper(trimws(as.character(p$melp_abbr %||% "MELP")))
  if (!nzchar(a)) "MELP" else a
}
.return_trace_melp_on <- function(p)
  !identical(tolower(trimws(as.character(p$melp_rule %||% "off"))), "off")

# How long a course may cover and still be 4.7's "short" one. The engine pins
# it in its CONTRACT (melp_simple_course_days), so a run records it; a run
# that did not is one this trace cannot test the rule against, and the arms
# that would have to assert "short" are not emitted at all rather than
# asserting it on no evidence.
.return_trace_melp_days <- function(p) {
  d <- suppressWarnings(as.integer(p$melp_days %||% NA))
  if (length(d) != 1L || is.na(d) || d < 1L) NA_integer_ else d
}

# How far apart two doses may be and still be ONE course. 4.7 is a two-step
# rule - chain on melp_exposure_days, then measure the chained course against
# melp_simple_course_days - and a run that recorded only one of the two is one
# this trace cannot do the rule's arithmetic for.
.return_trace_melp_expo <- function(p) {
  d <- suppressWarnings(as.integer(p$melp_expo %||% NA))
  if (length(d) != 1L || is.na(d) || d < 1L) NA_integer_ else d
}
.return_trace_melp_course_on <- function(p)
  .return_trace_melp_on(p) && !is.na(.return_trace_melp_days(p)) &&
    !is.na(.return_trace_melp_expo(p))

# The two settings this trace needs that the QC catalogue's qc_params() does
# not carry. It is frozen - every check in R/checks.R judges by the list it
# already returns - so they are added here instead, in one place: three
# callers set them, and a caller that forgot melp_days would silently drop the
# melp_confirmed arm rather than fail. A run built before the course cap was
# recorded gets NA, which is that arm not being emitted; every other setting
# is still read strictly, so a run missing one still refuses to be traced.
return_trace_params <- function(settings, run_id, p = NULL) {
  .need_checks()
  if (is.null(p)) p <- qc_params(settings, run_id)
  p$gap <- qc_int(settings, "map_discon_gap_days")
  p$melp_days <- tryCatch(qc_int(settings, "melp_simple_course_days"),
                          error = function(e) NA_integer_)
  p$melp_expo <- tryCatch(qc_int(settings, "melp_exposure_days"),
                          error = function(e) NA_integer_)
  p
}

.return_trace_base_ctes <- function(t, p) {
  .need_checks()
  melp <- .return_trace_melp(p)
  # Both numbers or neither: the cap is meaningless without the chain that
  # says what it measures, so a run missing either gets an empty melp_open.
  melp_expo <- .return_trace_melp_expo(p)
  melp_cap <- .return_trace_melp_days(p)
  melp_cap <- if (is.na(melp_expo) || is.na(melp_cap)) 0L else melp_cap
  melp_expo <- if (is.na(melp_expo)) 0L else melp_expo
  paste0(qc_window_sql(t, p, per_line = TRUE), ",
    reg AS (
      SELECT w.PATID, w.LOT_NUM, w.LOT_START_DT, w.LOT_START_TYPE,
             w.LOT_BASE_MEDS, w.ELIGIBLE_END, l.LOT_BASE_END_DT, m AS MED_ABBR
      FROM lines w
      INNER JOIN ", t$final, " l
        ON cast(l.PATID as string) = w.PATID AND l.LOT_NUM = w.LOT_NUM
      LATERAL VIEW explode(split(coalesce(w.LOT_BASE_MEDS, ''), ' ')) e AS m
      WHERE m <> ''
    ),
    -- Every episode with the one before it, per patient and drug: the
    -- engine's own restart test reads lag(MAP_DISCON_FLG) the same way
    -- (engine/R/prior_regimen.R, map_restart_sql).
    ep AS (
      SELECT cast(PATID as string) AS PATID, MAP_MED_TYPE, MAP_MED_CLASS,
             MAP_START_DT, MAP_END_DT, MAP_DISCON_FLG,
             lag(MAP_DISCON_FLG) OVER (PARTITION BY cast(PATID as string), MAP_MED_TYPE
                                      ORDER BY MAP_START_DT) AS PREV_DISCON,
             lag(MAP_START_DT) OVER (PARTITION BY cast(PATID as string), MAP_MED_TYPE
                                     ORDER BY MAP_START_DT) AS PREV_START,
             lag(MAP_END_DT) OVER (PARTITION BY cast(PATID as string), MAP_MED_TYPE
                                   ORDER BY MAP_START_DT) AS PREV_END
      FROM ", t$map, "
    ),
    -- The drug's first episode inside the line's own window, where it has one.
    in_window AS (
      SELECT w.PATID, w.LOT_NUM, w.MED_ABBR, min(e.MAP_START_DT) AS FIRST_IN_WINDOW
      FROM reg w
      INNER JOIN ep e
        ON e.PATID = w.PATID AND e.MAP_MED_TYPE = w.MED_ABBR
       AND e.MAP_START_DT >= w.LOT_START_DT AND e.MAP_START_DT <= w.ELIGIBLE_END
      GROUP BY w.PATID, w.LOT_NUM, w.MED_ABBR
    ),
    -- The lines a SHORT melphalan course opened. 4.7 is a TWO-step rule and
    -- both steps are done here the way engine/R/melp_rule.R does them
    -- (its melp_runs / melp_dose_expo / course-cover chain): doses closer
    -- together than melp_exposure_days are one course, and the course's cover
    -- is the latest supply end over ALL its episodes - not the opening
    -- episode's own end. Measuring the opening episode alone would be a LOWER
    -- bound on the course, so it would clear the cap more often than the rule
    -- does and put 4.7's name on lines the rule never touched. Where the run
    -- recorded neither number the cap below is 0, nothing is a short course,
    -- and the arm that rests on one is not emitted at all.
    melp_doses AS (
      SELECT cast(PATID as string) AS PATID, MAP_START_DT AS DOSE_DT
      FROM ", t$map, "
      WHERE upper(trim(MAP_MED_TYPE)) = '", melp, "'
      GROUP BY cast(PATID as string), MAP_START_DT
    ),
    melp_runs AS (
      SELECT PATID, DOSE_DT,
             CASE WHEN datediff(DOSE_DT,
                    lag(DOSE_DT) OVER (PARTITION BY PATID ORDER BY DOSE_DT))
                       < ", melp_expo, "
                  THEN 0 ELSE 1 END AS IS_NEW
      FROM melp_doses
    ),
    melp_dose_expo AS (
      SELECT PATID, DOSE_DT,
             min(DOSE_DT) OVER (PARTITION BY PATID, E) AS EXPO_DT
      FROM (SELECT PATID, DOSE_DT,
                   sum(IS_NEW) OVER (PARTITION BY PATID ORDER BY DOSE_DT
                                     ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS E
            FROM melp_runs) r
    ),
    melp_cover AS (
      SELECT d.PATID, d.EXPO_DT, max(m.MAP_END_DT) AS COURSE_END_DT
      FROM melp_dose_expo d
      INNER JOIN ", t$map, " m
        ON cast(m.PATID as string) = d.PATID AND m.MAP_START_DT = d.DOSE_DT
       AND upper(trim(m.MAP_MED_TYPE)) = '", melp, "'
      GROUP BY d.PATID, d.EXPO_DT
    ),
    melp_open AS (
      SELECT DISTINCT w.PATID, w.LOT_NUM, c.EXPO_DT AS COURSE_START,
             c.COURSE_END_DT AS COURSE_END
      FROM reg w
      INNER JOIN melp_cover c
        ON c.PATID = w.PATID AND c.EXPO_DT = w.LOT_START_DT
      WHERE datediff(c.COURSE_END_DT, c.EXPO_DT) + 1 <= ", melp_cap, "
    ),
    -- The line before each line, for what opened it and what it carried.
    --
    -- Re-keyed on LOT_NUM + 1, which finds nothing if a patient's lines ever
    -- skipped a number. They cannot: lines 2..n are built in order, each
    -- needing the one before it, the criteria layer either flags or truncates
    -- (engine/R/line_criteria.R, ON_FAIL) and truncate drops a failing line
    -- and every LATER one, and the build asserts 1..n twice and stops - on
    -- LOT_LONG and again on LOT_LONG_FINAL (engine/R/build_lot.R,
    -- check_lot_long and check_lot_final). A run that reached these tables
    -- has no gap.
    prev_line AS (
      SELECT cast(PATID as string) AS PATID, LOT_NUM + 1 AS LOT_NUM,
             LOT_START_TYPE AS PREV_LINE_START_TYPE, LOT_BASE_MEDS AS PREV_LINE_MEDS
      FROM ", t$final, "
    )")
}

# The own return - 4.3. One row per return, so a drug that came back after
# two breaks in one line is two rows.
#
# What makes the drug the LINE's is that its previous dose was inside the
# line, not that the induction window admitted it. Both are the line's own
# drugs by the time it ends: the window's, and one 4.8 folded in, which the
# engine then carries in the line's effective regimen (engine/R/foldin_rule.R,
# foldin_base_meds_eff) so its later doses are neither an added medication nor
# a next-line start. Gated on the window instead, a folded drug's SECOND
# course - back after a confirmed break, kept in the line by 4.3 exactly as
# any other own drug - was reported as no return at all.
#
# The fold's own first return keeps its previous dose in line n-1, so it stays
# out of this kind and remains 4.8's.
return_trace_own_sql <- function(t, p) {
  paste0("
    WITH ", .return_trace_base_ctes(t, p), "
    SELECT w.PATID, w.LOT_NUM, w.MED_ABBR, 'own_return' AS KIND, w.LOT_NUM AS RETURN_LINE,
           w.LOT_START_DT, w.LOT_START_TYPE, w.ELIGIBLE_END, w.LOT_BASE_END_DT,
           cast(NULL as string) AS PREV_BASE_MEDS,
           e.MAP_START_DT AS RETURN_DT, e.PREV_START AS PREV_EP_START,
           e.PREV_END AS PREV_EP_END, cast(NULL as int) AS FROM_LOT,
           cast(NULL as string) AS PREV_LINE_START_TYPE,
           CASE WHEN iw.FIRST_IN_WINDOW IS NULL THEN 0 ELSE 1 END AS HAS_WINDOW_EP,
           cast(NULL as string) AS OPEN_VIA
    FROM reg w
    -- the drug came back inside the line, after the window, after a confirmed
    -- break of its own...
    INNER JOIN ep e
      ON e.PATID = w.PATID AND e.MAP_MED_TYPE = w.MED_ABBR
     AND e.MAP_START_DT >= w.LOT_START_DT
     AND e.MAP_START_DT >  w.ELIGIBLE_END
     AND e.MAP_START_DT <= w.LOT_BASE_END_DT
     AND coalesce(e.PREV_DISCON, 0) = 1
     -- ...and the dose the break follows was itself inside this line, which
     -- is what makes the drug the line's own rather than the one before it
     AND e.PREV_START >= w.LOT_START_DT
    -- whether the line's own window admitted it, for the narrative: a drug
    -- 4.8 folded in has no window episode and is the line's all the same
    LEFT JOIN in_window iw
      ON iw.PATID = w.PATID AND iw.LOT_NUM = w.LOT_NUM AND iw.MED_ABBR = w.MED_ABBR
    -- a steroid is excluded from every line decision by class (2.1), so its
    -- return never opened a line under either reading and is not one here
    WHERE upper(trim(coalesce(e.MAP_MED_CLASS, ''))) <> 'STEROID'
    ORDER BY w.PATID, w.LOT_NUM, w.MED_ABBR, e.MAP_START_DT")
}

# The counter-example: an earlier drug that came back and OPENED a line.
# Three shapes, on OPEN_VIA - see the header. The melphalan arms are emitted
# only where the run applied the melphalan rule; without it melphalan is an
# ordinary drug and 4.3 holds its return like any other.
return_trace_opens_sql <- function(t, p) {
  melp <- .return_trace_melp(p)
  sel <- function(via, return_dt, from_lot) paste0("
    SELECT w.PATID, w.LOT_NUM, w.MED_ABBR, 'opens_line' AS KIND, w.LOT_NUM - 1 AS RETURN_LINE,
           w.LOT_START_DT, w.LOT_START_TYPE, w.ELIGIBLE_END, w.LOT_BASE_END_DT,
           pv.PREV_LINE_MEDS AS PREV_BASE_MEDS,
           ", return_dt, " AS RETURN_DT, b.PREV_EP_START,
           be.MAP_END_DT AS PREV_EP_END, ", from_lot, " AS FROM_LOT,
           pv.PREV_LINE_START_TYPE, cast(NULL as int) AS HAS_WINDOW_EP,
           '", via, "' AS OPEN_VIA")
  joins <- "
    LEFT JOIN prev_line pv ON pv.PATID = w.PATID AND pv.LOT_NUM = w.LOT_NUM
    LEFT JOIN before b
      ON b.PATID = w.PATID AND b.LOT_NUM = w.LOT_NUM AND b.MED_ABBR = w.MED_ABBR
    LEFT JOIN ep be
      ON be.PATID = w.PATID AND be.MAP_MED_TYPE = w.MED_ABBR
     AND be.MAP_START_DT = b.PREV_EP_START"
  not_prev <- "
      AND NOT EXISTS (
        SELECT 1 FROM prev_carried pc
        WHERE pc.PATID = w.PATID AND pc.LOT_NUM = w.LOT_NUM AND pc.MED_ABBR = w.MED_ABBR)"
  not_steroid <- "
      AND upper(trim(coalesce(e.MAP_MED_CLASS, ''))) <> 'STEROID'"

  # Arm A: the ordinary line-opening return - a drug two or more lines back,
  # dosed on the line's own start date.
  arm_a <- paste0(sel("new_agent", "w.LOT_START_DT", "ec.FROM_LOT"), "
    FROM reg w
    INNER JOIN earlier_carried ec
      ON ec.PATID = w.PATID AND ec.LOT_NUM = w.LOT_NUM AND ec.MED_ABBR = w.MED_ABBR
    INNER JOIN ep e
      ON e.PATID = w.PATID AND e.MAP_MED_TYPE = w.MED_ABBR
     AND e.MAP_START_DT = w.LOT_START_DT", joins, "
    WHERE w.LOT_START_TYPE = 'MED' AND w.LOT_NUM >= 3", not_steroid, not_prev)

  # Arm B: a short melphalan course of the PREVIOUS line's regimen that 4.7
  # confirmed. The one previous-line drug that opens a line: 4.3's exclusion
  # exempts it (engine/R/melp_rule.R, melp_prior_regimen_exempt), and the line
  # starts on the course's own first day. From LOT 2 up, unlike arm A.
  arm_b <- paste0(sel("melp_course", "w.LOT_START_DT", "w.LOT_NUM - 1"), "
    FROM reg w
    INNER JOIN prev_carried pc
      ON pc.PATID = w.PATID AND pc.LOT_NUM = w.LOT_NUM AND pc.MED_ABBR = w.MED_ABBR
    INNER JOIN ep e
      ON e.PATID = w.PATID AND e.MAP_MED_TYPE = w.MED_ABBR
     AND e.MAP_START_DT = w.LOT_START_DT", joins, "
    WHERE w.LOT_START_TYPE = 'MED' AND w.LOT_NUM >= 2
      AND upper(trim(w.MED_ABBR)) = '", melp, "'", not_steroid)

  # Arm C: a drug two or more lines back that arrived INSIDE such a course and
  # confirmed it. 4.7 moves the line's start onto the melphalan date, so this
  # drug's own episode is inside the line's window rather than on its start.
  arm_c <- paste0(sel("melp_confirmed", "iw.FIRST_IN_WINDOW", "ec.FROM_LOT"), "
    FROM reg w
    INNER JOIN earlier_carried ec
      ON ec.PATID = w.PATID AND ec.LOT_NUM = w.LOT_NUM AND ec.MED_ABBR = w.MED_ABBR
    INNER JOIN in_window iw
      ON iw.PATID = w.PATID AND iw.LOT_NUM = w.LOT_NUM AND iw.MED_ABBR = w.MED_ABBR
    INNER JOIN ep e
      ON e.PATID = w.PATID AND e.MAP_MED_TYPE = w.MED_ABBR
     AND e.MAP_START_DT = iw.FIRST_IN_WINDOW
    INNER JOIN melp_open mo ON mo.PATID = w.PATID AND mo.LOT_NUM = w.LOT_NUM", joins, "
    WHERE w.LOT_START_TYPE = 'MED' AND w.LOT_NUM >= 3
      AND iw.FIRST_IN_WINDOW > w.LOT_START_DT
      -- 4.7's confirming agent starts WHILE the course still covers
      AND iw.FIRST_IN_WINDOW <= mo.COURSE_END
      AND upper(trim(w.MED_ABBR)) <> '", melp, "'", not_steroid, not_prev)

  # Arm B needs only the abbreviation - a previous-line drug opening a line is
  # 4.7's exemption whatever the course length, and melp_prior_regimen_exempt
  # names the injected dates rather than the drug. Arm C asserts the course is
  # short, so it is emitted only where the run recorded how short that is.
  arms <- c(arm_a,
            if (.return_trace_melp_on(p)) arm_b,
            if (.return_trace_melp_course_on(p)) arm_c)
  paste0("
    WITH ", .return_trace_base_ctes(t, p), ",", .foldin_alias_ctes(t), ",
    -- any line two or more back that carried the drug, under any of its names
    earlier_carried AS (
      SELECT a.PATID, a.LOT_NUM, a.MED_ABBR, max(pl.LOT_NUM) AS FROM_LOT
      FROM w_alias a
      INNER JOIN ", t$final, " pl
        ON cast(pl.PATID as string) = a.PATID AND pl.LOT_NUM <= a.LOT_NUM - 2
      WHERE array_contains(split(coalesce(pl.LOT_BASE_MEDS, ''), ' '), a.ALIAS)
      GROUP BY a.PATID, a.LOT_NUM, a.MED_ABBR
    ),
    -- the drug's last episode before the line it opened
    before AS (
      SELECT w.PATID, w.LOT_NUM, w.MED_ABBR,
             max(e.MAP_START_DT) AS PREV_EP_START
      FROM reg w
      INNER JOIN ep e
        ON e.PATID = w.PATID AND e.MAP_MED_TYPE = w.MED_ABBR
       AND e.MAP_START_DT < w.LOT_START_DT
      GROUP BY w.PATID, w.LOT_NUM, w.MED_ABBR
    )",
    paste(arms, collapse = "\n    UNION ALL\n"), "
    ORDER BY PATID, LOT_NUM, MED_ABBR")
}

# The carried-over drug: counted for scale, never traced.
return_trace_carried_sql <- function(t, p) {
  paste0("
    WITH ", .return_trace_base_ctes(t, p), ",", .foldin_alias_ctes(t), "
    SELECT w.PATID, w.LOT_NUM, w.MED_ABBR, 'carried_over' AS KIND, w.LOT_NUM AS RETURN_LINE,
           w.LOT_START_DT, w.LOT_START_TYPE, w.ELIGIBLE_END, w.LOT_BASE_END_DT,
           pc.PREV_BASE_MEDS, iw.FIRST_IN_WINDOW AS RETURN_DT,
           cast(NULL as date) AS PREV_EP_START, cast(NULL as date) AS PREV_EP_END,
           cast(NULL as int) AS FROM_LOT, cast(NULL as string) AS PREV_LINE_START_TYPE,
           1 AS HAS_WINDOW_EP, cast(NULL as string) AS OPEN_VIA
    FROM reg w
    INNER JOIN prev_carried pc
      ON pc.PATID = w.PATID AND pc.LOT_NUM = w.LOT_NUM AND pc.MED_ABBR = w.MED_ABBR
    INNER JOIN in_window iw
      ON iw.PATID = w.PATID AND iw.LOT_NUM = w.LOT_NUM AND iw.MED_ABBR = w.MED_ABBR
    WHERE w.LOT_NUM >= 2
      AND NOT EXISTS (
        SELECT 1 FROM ep s WHERE s.PATID = w.PATID AND s.MAP_MED_TYPE = w.MED_ABBR
          AND upper(trim(coalesce(s.MAP_MED_CLASS, ''))) = 'STEROID')
      -- ...and a melphalan course that OPENED the line is not a backbone
      -- carried over into it: 4.7 started the line on it, and the
      -- line-opening kind reports it.
      AND NOT (upper(trim(w.MED_ABBR)) = '", .return_trace_melp(p), "'
               AND iw.FIRST_IN_WINDOW = w.LOT_START_DT)
    ORDER BY w.PATID, w.LOT_NUM, w.MED_ABBR")
}

# All four, as one named list. The fold is the fold-in trace's own query,
# unchanged, so the two reports cannot disagree about what a fold is.
return_trace_queries <- function(t, p) {
  .need_foldin()
  list(fold = foldin_trace_sql(t, p),
       own_return = return_trace_own_sql(t, p),
       opens_line = return_trace_opens_sql(t, p),
       carried_over = return_trace_carried_sql(t, p))
}

# The kinds' rows stacked into one frame with RETURN_TRACE_COLS. `results` is
# the named list of frames the queries returned; a kind whose frame lacks a
# column (the fold query carries no PREV_EP_*) gets NA there.
return_trace_stack <- function(results) {
  out <- lapply(names(results), function(k) {
    d <- results[[k]]
    # A frame the runner could not fill carries its error and no rows; the
    # runner has already said so, and the stack must not read it as empty.
    if (is.null(d) || !is.data.frame(d) || !nrow(d)) return(NULL)
    d <- as.data.frame(d, stringsAsFactors = FALSE)
    d$KIND <- k
    if (is.null(d$RETURN_LINE)) d$RETURN_LINE <- as.integer(d$LOT_NUM)
    for (cn in RETURN_TRACE_COLS) if (is.null(d[[cn]])) d[[cn]] <- NA
    d <- d[, RETURN_TRACE_COLS, drop = FALSE]
    d$PATID <- as.character(d$PATID)
    d$LOT_NUM <- as.integer(d$LOT_NUM); d$RETURN_LINE <- as.integer(d$RETURN_LINE)
    d$FROM_LOT <- suppressWarnings(as.integer(d$FROM_LOT))
    for (dc in c("LOT_START_DT", "ELIGIBLE_END", "LOT_BASE_END_DT", "RETURN_DT",
                 "PREV_EP_START", "PREV_EP_END"))
      d[[dc]] <- .as_date(d[[dc]])
    d
  })
  out <- Filter(Negate(is.null), out)
  if (!length(out)) {
    e <- as.data.frame(stats::setNames(replicate(length(RETURN_TRACE_COLS), character(0),
                                                 simplify = FALSE), RETURN_TRACE_COLS),
                       stringsAsFactors = FALSE)
    return(e)
  }
  d <- do.call(rbind, out)
  d <- d[order(d$PATID, d$RETURN_DT, d$LOT_NUM, d$MED_ABBR, method = "radix"), , drop = FALSE]
  rownames(d) <- NULL
  d
}

# ---- Filters, the sample and the summary --------------------------------------
# A kind list or a line list from the environment, refused rather than guessed
# at when it names something this trace does not know.
return_trace_parse_kinds <- function(raw) {
  raw <- trimws(as.character(raw %||% ""))
  if (!nzchar(raw)) return(RETURN_TRACE_KINDS)
  k <- unique(trimws(strsplit(raw, ",", fixed = TRUE)[[1]]))
  k <- k[nzchar(k)]
  bad <- setdiff(k, RETURN_TRACE_KINDS)
  if (length(bad))
    stop("TRACE_KINDS names kind(s) this trace does not have: ", paste(bad, collapse = ", "),
         ". The kinds are ", paste(RETURN_TRACE_KINDS, collapse = ", "), ".", call. = FALSE)
  if (!length(k)) stop("TRACE_KINDS is empty.", call. = FALSE)
  k
}
return_trace_parse_lines <- function(raw) {
  raw <- trimws(as.character(raw %||% ""))
  if (!nzchar(raw)) return(NULL)
  v <- trimws(strsplit(raw, ",", fixed = TRUE)[[1]])
  v <- v[nzchar(v)]
  n <- suppressWarnings(as.integer(v))
  if (!length(n) || any(is.na(n)) || any(n < 1L))
    stop("TRACE_LINES='", raw, "' is not a comma-separated list of line numbers.",
         call. = FALSE)
  unique(n)
}

# The rows in scope for tracing: the kinds asked for, on the return lines
# asked for. carried_over is never in scope.
return_trace_in_scope <- function(cands, kinds = RETURN_TRACE_KINDS, lines = NULL) {
  keep <- cands$KIND %in% kinds
  if (!is.null(lines)) keep <- keep & cands$RETURN_LINE %in% lines
  cands[keep, , drop = FALSE]
}

# Deterministic and a spread: ranked within (KIND, RETURN_LINE, MED_ABBR) by
# id and taken round-robin, so twelve patients show every kind on several
# lines and drugs rather than twelve LEN folds. A listed set bypasses it.
return_trace_sample <- function(cands, n, patids = NULL) {
  if (!is.null(patids) && length(patids))
    return(foldin_trace_check_patids(patids))
  n <- as.integer(n)
  if (is.na(n) || n < 1L) stop("TRACE_N must be a whole number of at least 1.", call. = FALSE)
  if (is.null(cands) || !nrow(cands)) return(character(0))
  # Only a traced kind is ever sampled: a carried-over drug is counted, and a
  # patient with nothing but one has nothing to show.
  cands <- cands[as.character(cands$KIND) %in% RETURN_TRACE_KINDS, , drop = FALSE]
  if (!nrow(cands)) return(character(0))
  d <- data.frame(PATID = as.character(cands$PATID), KIND = as.character(cands$KIND),
                  LINE = as.integer(cands$RETURN_LINE), MED_ABBR = as.character(cands$MED_ABBR),
                  stringsAsFactors = FALSE)
  # Kinds in the order the report explains them, not alphabetical: a fold,
  # then an own return, then the counter-example.
  d$K <- match(d$KIND, RETURN_TRACE_ALL_KINDS)
  d <- d[order(d$K, d$LINE, d$MED_ABBR, d$PATID, method = "radix"), , drop = FALSE]
  d <- d[!duplicated(d[, c("PATID", "KIND", "LINE", "MED_ABBR")]), , drop = FALSE]
  grp <- paste(d$KIND, d$LINE, d$MED_ABBR)
  d$rank <- stats::ave(seq_len(nrow(d)), grp, FUN = seq_along)
  d <- d[order(d$rank, d$K, d$LINE, d$MED_ABBR, d$PATID, method = "radix"), , drop = FALSE]
  utils::head(unique(d$PATID), n)
}

# Over every candidate row, never the sample. Counts per kind, per kind and
# return line, and per kind and drug, with the table's own totals beside them.
return_trace_summary <- function(cands, n_patients_total, n_lines_total) {
  cnt <- function(d) c(n_patients = length(unique(d$PATID)),
                       n_lines = nrow(unique(d[, c("PATID", "LOT_NUM"), drop = FALSE])),
                       n_returns = nrow(d))
  row <- function(kind, level, key, v) data.frame(
    kind = kind, level = level, key = key,
    n_patients = unname(v[["n_patients"]]), n_lines = unname(v[["n_lines"]]),
    n_returns = unname(v[["n_returns"]]), stringsAsFactors = FALSE)
  out <- list(row("LOT_LONG_FINAL", "all lines", "",
                  c(n_patients = as.numeric(n_patients_total),
                    n_lines = as.numeric(n_lines_total), n_returns = NA_real_)))
  d0 <- if (is.null(cands) || !nrow(cands))
    data.frame(PATID = character(0), LOT_NUM = integer(0), KIND = character(0),
               RETURN_LINE = integer(0), MED_ABBR = character(0), stringsAsFactors = FALSE)
  else cands
  for (k in RETURN_TRACE_ALL_KINDS) {
    d <- d0[d0$KIND == k, , drop = FALSE]
    out[[length(out) + 1L]] <- row(k, "all", "", cnt(d))
    for (l in sort(unique(d$RETURN_LINE)))
      out[[length(out) + 1L]] <- row(k, "by return line", paste0("LOT", l),
                                     cnt(d[d$RETURN_LINE == l, , drop = FALSE]))
    for (m in sort(unique(d$MED_ABBR)))
      out[[length(out) + 1L]] <- row(k, "by drug", m, cnt(d[d$MED_ABBR == m, , drop = FALSE]))
    # The three arms of opens_line are three different readings - an ordinary
    # return, a short melphalan course, and the agent that confirmed one - and
    # a total that does not separate them reads as one rule doing all of it.
    via <- if (is.null(d$OPEN_VIA)) character(0) else as.character(d$OPEN_VIA)
    for (v in sort(unique(via[!is.na(via) & nzchar(via)])))
      out[[length(out) + 1L]] <- row(k, "by open path", v,
                                     cnt(d[!is.na(via) & via == v, , drop = FALSE]))
  }
  do.call(rbind, out)
}

# ---- The episode table ----------------------------------------------------------
# The fold-in trace's annotation, then the notes the other kinds add:
#
#   'RETURNED to LOT n after a k-day break (4.3)'   the own return's episode
#   'break follows: k days to the return'            the episode before it
#   the two joined by '; '                           an episode that is both
#   'opens LOT n - back from LOT k, out of 4.8's scope'
#   'opens LOT n - LOT n-1 was opened by <type>, so no fold across it'
return_trace_annotate <- function(lines, episodes, tx, cands, p, subs = NULL) {
  .need_foldin()
  folds <- cands[cands$KIND == "fold", , drop = FALSE]
  ep <- foldin_trace_annotate(lines, episodes, tx, folds, p, subs = subs)
  own <- cands[cands$KIND == "own_return", , drop = FALSE]
  # A drug can come back more than once inside one line, and then the second
  # return's PREVIOUS episode is the first return's own: one episode is both a
  # return and the break before the next. Writing either note over the other
  # would drop a return out of the table, so the two are collected apart and
  # joined at the end, which also makes the result independent of the order
  # the rows arrived in.
  returned <- rep(NA_character_, nrow(ep))
  broke <- rep(NA_character_, nrow(ep))
  match_ep <- function(pid, med, dt) {
    m <- ep$PATID == pid & ep$MAP_MED_TYPE == med & !is.na(ep$MAP_START_DT) & ep$MAP_START_DT == dt
    !is.na(m) & m
  }
  for (i in seq_len(nrow(own))) {
    pid <- as.character(own$PATID[i]); med <- as.character(own$MED_ABBR[i])
    ret <- .as_date(own$RETURN_DT[i]); pe <- .as_date(own$PREV_EP_END[i]); ps <- .as_date(own$PREV_EP_START[i])
    gap <- if (is.na(pe)) NA_integer_ else as.integer(ret - pe)
    returned[match_ep(pid, med, ret)] <-
      paste0("RETURNED to LOT ", own$LOT_NUM[i], " after a ",
             if (is.na(gap)) "confirmed" else paste0(gap, "-day"), " break (4.3)")
    if (!is.na(ps))
      broke[match_ep(pid, med, ps)] <-
        paste0("break follows: ", if (is.na(gap)) "confirmed" else paste0(gap, " days"),
               " to the return")
  }
  # After the fold note, and over it: foldin_trace_annotate marks every
  # post-window episode of a folded drug as folded, and a later course of one
  # that the engine did not fold is this rule's, not 4.8's.
  marked <- which(!is.na(returned) | !is.na(broke))
  for (j in marked) {
    parts <- c(returned[j], broke[j])
    ep$note[j] <- paste(parts[!is.na(parts)], collapse = "; ")
  }
  op <- cands[cands$KIND == "opens_line", , drop = FALSE]
  for (i in seq_len(nrow(op))) {
    pid <- as.character(op$PATID[i]); med <- as.character(op$MED_ABBR[i])
    dt <- .as_date(op$RETURN_DT[i]); n <- as.integer(op$LOT_NUM[i])
    hit <- ep$PATID == pid & ep$MAP_MED_TYPE == med & !is.na(ep$MAP_START_DT) & ep$MAP_START_DT == dt
    via <- as.character(op$OPEN_VIA[i] %||% "new_agent")
    from <- suppressWarnings(as.integer(op$FROM_LOT[i]))
    pt <- as.character(op$PREV_LINE_START_TYPE[i])
    ep$note[hit] <- if (identical(via, "melp_course"))
      paste0("opens LOT ", n, " - a short melphalan course 4.7 confirmed")
    else if (identical(via, "melp_confirmed"))
      paste0("confirms the melphalan course that opened LOT ", n, " (4.7)")
    # The procedure reading only where the drug was in the fold set the
    # procedure line's build read - the line before it. Further back, 4.8
    # never judged the drug and the refusal is not what happened.
    else if (!is.na(pt) && nzchar(pt) && pt != "MED" && !is.na(from) && from == n - 2L)
      paste0("opens LOT ", n, " - LOT ", n - 1L, " was opened by ", pt, ", so no fold across it")
    else paste0("opens LOT ", n, " - back from LOT ", if (is.na(from)) "?" else from,
                ", out of 4.8's scope")
  }
  ep
}

# ---- The narratives ----------------------------------------------------------------
# One paragraph per candidate row. A fold's is the fold-in trace's own. An own
# return's says where the drug was, the break, the return, what the line did,
# and what the reading before 30 Aug 2026 would have done - the same local
# reading the fold narrative makes, stated for the patient's earliest return
# only (the caveat foldin_trace_narrative explains). An opens_line row's says
# why the return opened a line and that the rule changed nothing there.
# What the line's own regimen covered before the return, as the engine chained
# it: the regimen drugs the window admitted, and - since 4.4 makes a pair one
# agent and the older engine's chain read the substitute's episodes as the
# drug's - their permissible substitutes' episodes too.
# The chained course's cover, as 4.7 measures it and engine/R/melp_rule.R
# computes it: doses closer together than melp_exposure_days are one course,
# and its cover is the latest supply end over that course's episodes. Read in
# R here because a narrative has the episodes rather than the CTEs. NA where
# no episode of the drug starts on the course's first day.
.melp_course_end <- function(e, drug, first, expo) {
  st <- .as_date(e$MAP_START_DT); en <- .as_date(e$MAP_END_DT)
  keep <- as.character(e$MAP_MED_TYPE) == drug & !is.na(st) & st >= first
  st <- st[keep]; en <- en[keep]
  o <- order(st); st <- st[o]; en <- en[o]
  if (!length(st) || is.na(first) || st[1] != first) return(as.Date(NA))
  last <- 1L
  if (!is.na(expo) && length(st) > 1L)
    for (i in seq(2L, length(st)))
      if (as.integer(st[i] - st[i - 1L]) < expo) last <- i else break
  en <- en[seq_len(last)]
  en <- en[!is.na(en)]
  if (!length(en)) as.Date(NA) else max(en)
}

.own_cover_before <- function(e, base, start, elig, ret, subs = NULL) {
  e_start <- .as_date(e$MAP_START_DT); e_med <- as.character(e$MAP_MED_TYPE)
  base_drugs <- strsplit(trimws(base), " ", fixed = TRUE)[[1]]
  base_drugs <- base_drugs[nzchar(base_drugs)]
  own <- base_drugs[vapply(base_drugs, function(m)
    any(e_med == m & e_start >= start & e_start <= elig), logical(1))]
  names_of <- unique(unlist(lapply(own, .drug_aliases, subs = subs)))
  own_eps <- e[e_med %in% names_of & e_start >= start & e_start < ret, , drop = FALSE]
  own_end <- if (nrow(own_eps)) max(.as_date(own_eps$MAP_END_DT), na.rm = TRUE) else as.Date(NA)
  # Which of those episodes was a substitute's, for the sentence that says so.
  sub_eps <- own_eps[!as.character(own_eps$MAP_MED_TYPE) %in% own, , drop = FALSE]
  list(own = own, own_end = own_end, subs_used = unique(as.character(sub_eps$MAP_MED_TYPE)))
}

# A procedure between a drug's last dose and its return. Under the older
# reading such an event opened a line of its own before the return could, so
# the counterfactual for the return cannot be read from these tables.
.procedure_between <- function(tx, pid, from_dt, to_dt) {
  if (is.null(tx) || !nrow(tx) || is.na(to_dt)) return(NULL)
  t <- tx[as.character(tx$PATID) == pid, , drop = FALSE]
  if (!nrow(t)) return(NULL)
  d <- .as_date(t$TX_DT)
  keep <- !is.na(d) & d <= to_dt & (is.na(from_dt) | d > from_dt)
  if (!any(keep)) return(NULL)
  i <- which(keep)[which.min(d[keep])]
  list(type = as.character(t$TX_TYPE[i]), dt = d[i])
}

return_trace_narrative <- function(row, lines, episodes, p, tx = NULL, subs = NULL,
                                   all_rows = NULL) {
  .need_foldin()
  kind <- as.character(row$KIND)
  pid <- as.character(row$PATID)
  ln <- lines[as.character(lines$PATID) == pid, , drop = FALSE]
  if (identical(kind, "fold")) {
    fr <- if (is.null(all_rows)) NULL else all_rows[all_rows$PATID == pid & all_rows$KIND == "fold", , drop = FALSE]
    return(foldin_trace_narrative(row, lines, episodes, p, tx = tx, subs = subs, all_folds = fr))
  }
  n <- as.integer(row$LOT_NUM); drug <- as.character(row$MED_ABBR)
  start <- .as_date(row$LOT_START_DT); ret <- .as_date(row$RETURN_DT); elig <- .as_date(row$ELIGIBLE_END)
  this <- ln[as.integer(ln$LOT_NUM) == n, , drop = FALSE]
  base <- if (nrow(this)) as.character(this$LOT_BASE_MEDS[1]) else ""
  end <- if (nrow(this)) .as_date(this$LOT_BASE_END_DT[1]) else as.Date(NA)
  reason <- if (nrow(this)) as.character(this$LOT_BASE_END_REASON[1]) else ""
  start_type <- as.character(row$LOT_START_TYPE %||% "MED")
  w <- if (identical(start_type, "CART")) p$cart else if (n == 1L) p$ind1 else p$indn
  e <- episodes[as.character(episodes$PATID) == pid, , drop = FALSE]
  e <- e[toupper(trimws(as.character(e$MAP_MED_CLASS))) != "STEROID", , drop = FALSE]
  k <- as.integer(ret - start)
  fmt <- function(d) if (is.na(d)) "(not in the read)" else format(d)

  if (identical(kind, "own_return")) {
    ps <- .as_date(row$PREV_EP_START); pe <- .as_date(row$PREV_EP_END)
    gap <- if (is.na(pe)) NA_integer_ else as.integer(ret - pe)
    has_win <- is.na(row$HAS_WINDOW_EP) || as.integer(row$HAS_WINDOW_EP) == 1L
    # The flag is per drug NAME, so a substitute covering the gap does not
    # clear it - and under the older reading the return was released all the
    # same. Said here so a reader who sees the substitute's episodes in the
    # table below is not left thinking the break is wrong.
    gap_txt <- if (is.na(gap))
      "a confirmed break (MAP_DISCON_FLG = 1 on the episode before it)"
    else paste0("a break of ", gap, " days (MAP_DISCON_FLG = 1: at least ",
                if (is.null(p$gap) || is.na(p$gap)) "map_discon_gap_days" else p$gap,
                " days with no supply of ", drug, " itself)")
    cover <- .own_cover_before(e, base, start, elig, ret, subs = subs)
    own_txt <- if (length(cover$own)) paste(cover$own, collapse = " ") else "(none in the read)"
    sub_txt <- if (length(cover$subs_used))
      paste0(" Its permissible substitute ", paste(cover$subs_used, collapse = " and "),
             " was dosed inside the gap; 4.4 makes the pair one agent, so that cover is the ",
             "line's, and the flag on ", drug, "'s own episodes is what the break is read from.")
      else ""
    # Where this patient's two histories part: the earliest return of any
    # kind the rules decided. A later one cannot be read locally.
    first_ret <- ret
    if (!is.null(all_rows) && nrow(all_rows)) {
      ar <- all_rows[all_rows$PATID == pid & all_rows$KIND %in% c("fold", "own_return"), , drop = FALSE]
      rd <- .as_date(ar$RETURN_DT); rd <- rd[!is.na(rd)]
      if (length(rd)) first_ret <- min(rd)
    }
    proc <- .procedure_between(tx, pid, pe, ret)
    # LOT 5 (max_lot) is the last line the engine builds, so there is no
    # "next line" for the older reading to have opened.
    capped <- !is.null(p$max_lot) && !is.na(p$max_lot) && n >= as.integer(p$max_lot)
    cap_txt <- if (capped)
      paste0(" LOT ", n, " is the last line the engine builds (max_lot ", p$max_lot,
             "), so under that reading the return would have sat in no line at all.")
      else ""
    pre <- if (!is.na(first_ret) && ret > first_ret) {
      paste0("Before 30 Aug 2026 this return cannot be read from these tables alone: an ",
             "earlier return on ", format(first_ret), " is the first thing the rules decided ",
             "for this patient, and the line holding this one depends on what the older reading ",
             "would have made of that. A build of the same cohort with APPLY_OWN_RETURN_FOLD=FALSE ",
             "and APPLY_MAP_FOLDIN=FALSE, differenced against this one, is what settles it.")
    } else if (!is.null(proc)) {
      paste0("Before 30 Aug 2026 the break released the drug, and the return would not have ",
             "stayed in LOT ", n, ". What it would have opened cannot be read from these tables ",
             "alone: a ", proc$type, " on ", format(proc$dt), " falls between the break and the ",
             "return, and under that reading a procedure opens a line of its own first, so the ",
             "return would have arrived into a line these tables do not contain. A build of the ",
             "same cohort with APPLY_OWN_RETURN_FOLD=FALSE, differenced against this one, is what ",
             "settles it.")
    } else if (is.na(cover$own_end)) {
      paste0("Before 30 Aug 2026 the break released the drug, and this return would have ",
             "opened a new line on ", format(ret), ". The episodes read here show no cover ",
             "for LOT ", n, "'s regimen before it, so which end LOT ", n, " would have had ",
             "cannot be said from them: MED_ADD on ", format(ret - 1L), " if another of its ",
             "drugs still ran, or DISCONTINUATION on its run-out if none did.", cap_txt)
    } else if (ret > cover$own_end) {
      paste0("Before 30 Aug 2026 the break released the drug, and this return would have ",
             "opened a new line on ", format(ret), ". LOT ", n, "'s regimen (", own_txt,
             ") had run out on ", format(cover$own_end), ", before the return, so the return ",
             "would have confirmed that run-out (5.3): LOT ", n, " would have ended ",
             "DISCONTINUATION on ", format(cover$own_end), " and the next line would have ",
             "started on ", format(ret), " with ", drug, ".", cap_txt)
    } else {
      paste0("Before 30 Aug 2026 the break released the drug, and this return would have ",
             "been an added medication: LOT ", n, "'s regimen (", own_txt, ") was still covered on ",
             format(ret), " (cover ran to ", format(cover$own_end), "), so LOT ", n,
             " would have ended MED_ADD on ", format(ret - 1L), " and a new line would have ",
             "opened on ", format(ret), " with ", drug, ".", cap_txt)
    }
    # How the drug came to be the line's: the window admitted it, or 4.8 did.
    belongs <- if (has_win)
      paste0(drug, " is in LOT ", n, "'s own regimen (", base, "): it was dosed inside the line's ",
             w, "-day induction window.")
      else paste0(drug, " is in LOT ", n, "'s regimen (", base, ") because 4.8 folded it in - it ",
                  "has no episode inside the line's ", w, "-day induction window - and the engine ",
                  "carries a folded drug in the line's regimen, so this later course is the ",
                  "line's own drug coming back.")
    return(paste0(
      belongs, " Its episode of ", fmt(ps), " to ", fmt(pe), " was followed by ",
      gap_txt, ", and ", drug, " came back on ", format(ret), ", ", k, " days after LOT ", n,
      " opened and outside the window (window ended ", format(elig), "). Under 4.3 a drug of ",
      "the line's own regimen never starts a line, so the return stayed in LOT ", n,
      ", which runs on over the break: LOT ", n, " is ", format(start), " to ", fmt(end),
      if (nzchar(reason)) paste0(" (", reason, ")") else "", ".", sub_txt, " ", pre))
  }

  if (identical(kind, "opens_line")) {
    from <- as.integer(row$FROM_LOT); pt <- as.character(row$PREV_LINE_START_TYPE %||% "")
    via <- as.character(row$OPEN_VIA %||% "new_agent")
    prev_meds <- as.character(row$PREV_BASE_MEDS %||% "")
    prev_meds <- if (is.na(prev_meds) || !nzchar(prev_meds)) "no drug" else prev_meds
    pl <- ln[as.integer(ln$LOT_NUM) == n - 1L, , drop = FALSE]
    pl_end <- if (nrow(pl)) .as_date(pl$LOT_BASE_END_DT[1]) else as.Date(NA)
    pl_reason <- if (nrow(pl)) as.character(pl$LOT_BASE_END_REASON[1]) else ""
    ps <- .as_date(row$PREV_EP_START); pe <- .as_date(row$PREV_EP_END)
    away <- if (is.na(pe)) "" else paste0(" Its previous episode ran ", fmt(ps), " to ", fmt(pe),
                                          ", ", as.integer(ret - pe), " days before.")
    from_line <- if (is.na(from)) NULL else ln[as.integer(ln$LOT_NUM) == from, , drop = FALSE]
    from_meds <- if (!is.null(from_line) && nrow(from_line)) as.character(from_line$LOT_BASE_MEDS[1]) else ""
    from_txt <- paste0(drug, " was last in LOT ", if (is.na(from)) "?" else from, "'s regimen",
                       if (nzchar(from_meds) && !is.na(from_meds)) paste0(" (", from_meds, ")") else "",
                       ".")
    # What the line before it did, read off its own row rather than assumed:
    # it was ended by the return, had already run out and the return confirmed
    # it (5.3), or had already closed on a procedure.
    ended <- if (identical(pl_reason, "MED_ADD"))
      paste0("It was an added medication: LOT ", n - 1L, " ended MED_ADD on ", fmt(pl_end),
             ", and ", drug, " opened LOT ", n, " (", base, ").")
    else if (identical(pl_reason, "DISCONTINUATION"))
      paste0("LOT ", n - 1L, "'s own regimen had already run out - it ended DISCONTINUATION on ",
             fmt(pl_end), " - so the return confirmed that run-out (5.3) and opened LOT ", n,
             " (", base, ").")
    else if (pl_reason %in% c("SCT_ALLO", "SCT_AUTO", "SCT_CART", "SCT_AUTO_CONT", "CART_INIT"))
      paste0("LOT ", n - 1L, " had already closed on a procedure (", pl_reason, " on ", fmt(pl_end),
             ") with no regimen left to hold the drug in, so ", drug, " opened LOT ", n,
             " (", base, ").")
    else paste0("LOT ", n - 1L, " ended ",
                if (nzchar(pl_reason)) pl_reason else "(reason not in the read)",
                " on ", fmt(pl_end), ", and ", drug, " opened LOT ", n, " (", base, ").")

    if (identical(via, "melp_course")) {
      # What the COURSE covered, chained the way 4.7 measures it - not a window
      # belonging to some other rule, and not the opening episode alone. Where
      # the episodes are not in the read, the run's own cap stands in.
      e_st <- .as_date(e$MAP_START_DT)
      md <- .return_trace_melp_days(p)
      cover <- .melp_course_end(e, drug, ret, .return_trace_melp_expo(p))
      if (is.na(cover)) cover <- if (!is.na(md)) ret + md else ret
      other <- sort(unique(as.character(e$MAP_MED_TYPE)[
        !is.na(e_st) & e_st > ret & e_st <= cover & as.character(e$MAP_MED_TYPE) != drug]))
      conf <- if (length(other)) paste0(" confirmed by ", paste(utils::head(other, 2), collapse = " and "))
              else " confirmed by a new agent inside its cover"
      return(paste0(
        drug, " was in LOT ", n - 1L, "'s regimen (", prev_meds, ") and came back on ", format(ret),
        " as a short course", conf, ". 4.7 makes such a course a line of its own from its first day, ",
        "and melphalan is the one agent 4.3 exempts from 'a drug of the previous regimen never ",
        "starts a line'. ", ended, " The 30 Aug 2026 rules changed nothing here: this is 4.7's ",
        "reading, and it held before them too."))
    }
    if (identical(via, "melp_confirmed")) {
      md <- .return_trace_melp_days(p)
      return(paste0(
        from_txt, away, " It came back on ", format(ret), ", while a melphalan course that started ",
        "on ", format(start), " was still covering - a course of ",
        if (is.na(md)) "the run's cap in" else md, " days or fewer, which is 4.7's short one. ",
        "4.7 reads a new agent arriving inside such a course as what advances the line, and advances ",
        "it on the MELPHALAN's date rather than the agent's, so ", drug, " is in LOT ", n,
        "'s regimen (", base, ") without a line ever opening on its own date. LOT ", n - 1L,
        " ended ", if (nzchar(pl_reason)) pl_reason else "(reason not in the read)", " on ",
        fmt(pl_end), ", and the melphalan opened LOT ", n, ".",
        " What these tables cannot show is whether 4.7 was the rule that acted: a course this short ",
        "opening a line looks the same here whether the rule suppressed it and this arrival advanced ",
        "it, or melphalan simply started the line as a new agent. Read this as where the drug ",
        "landed, not as the rule's verdict."))
    }
    # The refusal-across-a-procedure reading belongs only to a drug the
    # procedure line's own build would have judged: one in the regimen of the
    # line before it, which is the fold set 4.8 reads. Further back, 4.8 never
    # looked at the drug and the refusal is not what happened.
    why <- if (!is.na(pt) && nzchar(pt) && pt != "MED" && !is.na(from) && from == n - 2L)
      paste0("LOT ", n - 1L, " was opened by a transplant or CAR-T (", pt, ") and carried ",
             prev_meds, ". 4.8 refuses a fold across a procedure that opened a line, so ", drug,
             " was no returning regimen drug when it came back on ", format(ret), ". ", ended)
    else
      paste0("LOT ", n - 1L, " (", prev_meds, ") did not carry it",
             if (!is.na(pt) && nzchar(pt) && pt != "MED") paste0(" - it was opened by ", pt, " -") else "",
             ". 4.8's fold set is the immediately previous line's regimen only, so a drug from ",
             "further back is out of its scope, and 4.3 does not hold it either: when ", drug,
             " came back on ", format(ret), " it was a new agent like any other. ", ended)
    return(paste0(from_txt, away, " ", why, " The 30 Aug 2026 rules changed nothing here: ",
                  "this return opened a line under the earlier reading too."))
  }

  paste0(drug, " in LOT ", n, ": ", kind, " on ", format(ret), ".")
}

# ---- Rendering --------------------------------------------------------------------
RETURN_TRACE_KIND_LABEL <- c(
  fold = "Folded into the line it returned in (4.8)",
  own_return = "Came back to its own line after a break (4.3)",
  opens_line = "Came back and opened a line (outside 4.8)",
  carried_over = "Carried over inside the induction window (no rule involved)")

return_trace_patient_md <- function(shown_id, rows_p, lines_p, episodes_p, ann_p, p,
                                    tx_p = NULL, subs = NULL) {
  .need_foldin()
  ln <- c(paste0("## Patient ", shown_id), "")
  if (is.null(lines_p) || !nrow(lines_p))
    return(c(ln, "This id has no line in LOT_LONG_FINAL under this prefix. Check the id.", ""))
  traced <- if (is.null(rows_p)) rows_p else rows_p[rows_p$KIND %in% RETURN_TRACE_KINDS, , drop = FALSE]
  if (is.null(traced) || !nrow(traced)) {
    ln <- c(ln, paste0("No returning drug found for this patient: no regimen drug of any line ",
                       "carries a fold's, an own return's or a line-opening return's signature. ",
                       "Listed by request; the lines and episodes are shown as they are."), "")
  } else {
    ord <- order(.as_date(traced$RETURN_DT), as.character(traced$KIND),
                 as.character(traced$MED_ABBR), method = "radix")
    for (i in ord) {
      r <- traced[i, , drop = FALSE]
      ln <- c(ln, paste0("**", RETURN_TRACE_KIND_LABEL[[as.character(r$KIND)]], " - ",
                         as.character(r$MED_ABBR), ", LOT ", as.integer(r$LOT_NUM), ".** ",
                         return_trace_narrative(r, lines_p, episodes_p, p, tx = tx_p, subs = subs,
                                                all_rows = rows_p)), "")
    }
  }
  ln <- c(ln, "Lines (LOT_LONG_FINAL):", "",
          foldin_trace_md_table(lines_p, TRACE_LINE_COLS), "",
          "Episodes (MAP_STACKED) and transplant events, in date order:", "",
          foldin_trace_md_table(ann_p, TRACE_EPISODE_COLS), "")
  ln
}

return_trace_markdown <- function(run_id, pfx, p, summary, patients_sections, masked,
                                  kinds = RETURN_TRACE_KINDS, lines = NULL,
                                  n_candidates = NA, n_traced = length(patients_sections),
                                  listed = FALSE, source_note = NULL) {
  .need_foldin()
  gap <- if (is.null(p$gap) || is.na(p$gap)) "map_discon_gap_days" else paste0(p$gap, " days")
  ln <- c(paste0("# Returning-drug trace - prefix `", pfx, "`"),
          "",
          paste0("Run `", run_id, "`. What the rules adopted on 30 Aug 2026 (LOT_RULES.md ",
                 "4.3 and 4.8) did with drugs that came back, on the patients they touched: ",
                 "raw MAP episodes beside the final lines, the returns marked."),
          "",
          if (!is.null(source_note)) c(source_note, "") else character(0),
          if (isTRUE(masked))
            paste0("Patient ids are MASKED to their last six characters, as the QC report ",
                   "masks them. To look a patient up, run the trace without TRACE_MASK_PATID.")
          else
            paste0("Patient ids are NOT masked. This file carries patient identifiers and ",
                   "stays inside the study environment; it exists so each patient can be ",
                   "looked up in the warehouse."),
          "",
          "Three kinds of return are traced, and a fourth is counted:",
          "",
          paste0("- **fold (4.8)** - a drug of the previous line, back after exactly one new ",
                 "agent opened the next line: it JOINED that line's regimen instead of ",
                 "starting one. Signature: in line n's regimen, in line n-1's, no episode ",
                 "inside line n's induction window, an episode inside line n after it."),
          paste0("- **own return (4.3)** - a drug the line already held, back after a ",
                 "confirmed break of its own (", gap, " or more with no supply of that drug): ",
                 "the line ran on over the break. Before the rule the break released the drug ",
                 "and the return opened a new line - a 1L drug back after a holiday made a 2L ",
                 "that no longer exists. Signature: an episode inside the line, after its ",
                 "window, whose preceding episode carries MAP_DISCON_FLG = 1 and was itself ",
                 "inside the line. That preceding dose is the window's for an ordinary regimen ",
                 "drug and the folded course for one 4.8 folded in, which the engine carries in ",
                 "the line's regimen - so a folded drug's LATER return is this kind, not a ",
                 "second fold."),
          paste0("- **opened a line** - a drug given earlier that came back and opened a ",
                 "line, which neither rule prevents. `OPEN_VIA` says which shape: `new_agent`, ",
                 "a drug two or more lines back, so 4.8's fold set - the immediately previous ",
                 "line's regimen - never held it, and where that previous line was itself ",
                 "opened by a transplant or CAR-T, 4.8 refused the fold as well; ",
                 "`melp_course`, a short melphalan course of the previous line's regimen that ",
                 "4.7 confirmed, which is the one previous-line drug 4.3 exempts; and ",
                 "`melp_confirmed`, a drug two or more lines back that arrived while a short ",
                 "melphalan course was still covering, where the line opened on the melphalan's ",
                 "date rather than on its own. That last one says where the drug landed, not ",
                 "which rule put it there: a short course opening a line reads the same here ",
                 "whether 4.7 suppressed it and this arrival confirmed it, or melphalan simply ",
                 "started the line. The counter-example, so a reader sees where the rules stop."),
          paste0("- **carried over** (counted only) - a drug of the IMMEDIATELY previous ",
                 "line dosed inside the next line's induction window: an ordinary regimen drug ",
                 "of both lines. Not a return, and not a fold - the window is why. A drug from ",
                 "further back re-dosed inside a window is an ordinary regimen join (4.2) that ",
                 "no rule here decided, and is not counted."),
          "",
          paste0("RETURN_LINE is the line a return belongs to for the 2L question: the line a ",
                 "fold or an own return sits in, and the line BEFORE the one a returning drug ",
                 "opened. So \"drugs that came back in 2L\" is RETURN_LINE = 2: folds into ",
                 "LOT 2, own returns inside LOT 2, and returns after LOT 2 that opened LOT 3; ",
                 "own returns inside LOT 1 are the ones that would have made a 2L before the ",
                 "rule. It is a filing convention, not a column of the run: a reader who wants ",
                 "the returns whose episode LIES in 2L reads LOT_NUM = 2 in the candidates CSV."),
          "",
          paste0("Windows as the run recorded them: LOT1 ", p$ind1, " days, later lines ", p$indn,
                 ", CAR-T ", p$cart, ". A permissible substitute and the drug it replaces are one ",
                 "agent in the fold and line-opening tests (4.4); an own return is read under the ",
                 "drug's own name, because a substitute's restart was never released under the ",
                 "older reading either and so is not a return this rule changed. Each paragraph ",
                 "also says what the reading ",
                 "before 30 Aug 2026 would have made of the return - a local reading of these ",
                 "tables, stated for the FIRST return the rules decided in a patient; a later ",
                 "one says that it cannot be read locally. A build of the same cohort with ",
                 "APPLY_MAP_FOLDIN=FALSE and APPLY_OWN_RETURN_FOLD=FALSE, differenced against ",
                 "this one, is what settles an alternative history."),
          "",
          paste0("Traced: kinds ", paste(kinds, collapse = ", "),
                 if (is.null(lines)) ", every return line" else paste0(", return line(s) ", paste(lines, collapse = ", ")),
                 ". ",
                 if (is.na(n_candidates)) "" else paste0(n_candidates, " patient(s) carry a return in scope. "),
                 n_traced, " traced",
                 if (isTRUE(listed)) " (listed by TRACE_PATIDS)" else " (a round-robin sample over kind, line and drug)",
                 "."),
          "",
          "## Summary (over every return in the run, not the sample)", "",
          foldin_trace_md_table(summary), "")
  for (s in patients_sections) ln <- c(ln, s)
  ln
}
