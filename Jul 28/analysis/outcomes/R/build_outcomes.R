# Secondary Objective 1: treatment patterns and treatment-related outcomes.
# Protocol Table 4.
#
# Reads one finished LOT run. Computes no line and no cohort of its own, so any
# number here traces back to the run that produced it.
#
#   TTNT  index LOT start to the next LOT or death, whichever is first
#   TTD   the same, plus the current line's own end
#   OS    index LOT start to death
#
# All three censor at the follow-up end. The protocol excludes the start date
# and includes the event date, so the index day does not count and the event day
# does, which is a plain datediff.

# The follow-up end, per protocol 6.1: the day after the index date to whichever
# comes first - the end of continuous enrollment, the end of the study period,
# or death.
#
# The cohort carries both halves: ENDDATE is min(death, study end) and
# ENDDATE_CE is where continuous enrolment stops. The earliest of the two is
# the protocol's follow-up end. ENDDATE_CE is NULL for a patient who never
# disenrolled, which is why it is coalesced rather than compared raw - a NULL
# inside least() would swallow the whole expression.
FU_END_SQL <- "least(cast(c.ENDDATE as date),
                     coalesce(cast(c.ENDDATE_CE as date), cast(c.ENDDATE as date)))"

# One row per patient per line, with the next line's start beside it. Every
# outcome below is a date difference off this, so they cannot disagree about
# when a line started or what came after it.
#
# base_tbl is the cohort build's NDMM_BASE_COHORT, which carries MM_DX_DT. The
# cohort table itself does not: its INDEX_DATE is the 1L treatment start, and
# every column on it is anchored there. NULL when there is no such table - a
# cohort built by another package has no MM diagnosis date to offer - and the
# diagnosis columns are then absent rather than guessed.
#
# subseq_tbls names the line-specific eligibility cohorts, keyed by line number
# ("2" -> <prefix>NDMM_COHORT_2L). Table 4's denominator for a later line is a
# study-team question with two defensible answers, so both are carried rather
# than one being chosen here:
#
#   ALL_LINES       every line in the 1L cohort. A 2L result is then "of the
#                   patients we followed from 1L, this is what their second
#                   line looked like".
#   LINE_ELIGIBLE   only lines whose patient is in that line's own cohort,
#                   which adds 365 days of enrolment before the line and 90
#                   after it. A 2L result is then "of the patients we could
#                   properly observe at 2L, this is what it looked like".
#
# They answer different questions and give different numbers. LINE_ELIGIBLE
# marks the row; the summaries report over both and the reader picks.
outcomes_base_sql <- function(lines_tbl, cohort_tbl, base_tbl = NULL,
                              subseq_tbls = list()) {
  dx_join <- if (is.null(base_tbl)) "" else glue("
    LEFT JOIN (SELECT cast(PATID as string) AS PATID,
                      cast(MM_DX_DT as date) AS MM_DX_DT
               FROM {base_tbl}) x ON x.PATID = n.PATID")
  dx_cols <- if (is.null(base_tbl))
    "cast(NULL as date) AS MM_DX_DT, cast(NULL as int) AS DX_TO_LOT1_DAYS"
  else
    # Table 4 measures diagnosis date (excluded) to index date (included), and
    # the cohort's INDEX_DATE is that 1L index.
    "x.MM_DX_DT, datediff(c.INDEX_DATE, x.MM_DX_DT) AS DX_TO_LOT1_DAYS"
  # 1L is the cohort itself, so every 1L line is eligible by construction. A
  # line with no cohort of its own - 4L and beyond - is NULL rather than 0: not
  # eligible and not-asked are different answers, and 0 would quietly shrink the
  # restricted denominator by every line nobody set a criterion for.
  # Each fragment opens with its own newline. glue() trims a template's leading
  # blank line, so a fragment interpolated straight after a column name welds
  # onto it - "n.PATIDLEFT JOIN" - and the statement will not parse.
  el_join <- if (!length(subseq_tbls)) "" else paste0(
    vapply(names(subseq_tbls), function(n) paste0("\n", glue(
      "    LEFT JOIN (SELECT DISTINCT cast(PATID as string) AS PATID
               FROM {subseq_tbls[[n]]}) e{n} ON e{n}.PATID = n.PATID")),
    character(1)), collapse = "")
  el_col <- if (!length(subseq_tbls)) "cast(NULL as int) AS LINE_ELIGIBLE" else
    paste0("CASE WHEN n.LOT_NUM = 1 THEN 1\n",
           paste0(vapply(names(subseq_tbls), function(n) glue(
             "                WHEN n.LOT_NUM = {n} THEN CASE WHEN e{n}.PATID IS NOT NULL THEN 1 ELSE 0 END"),
             character(1)), collapse = "\n"),
           "\n           END AS LINE_ELIGIBLE")
  el_bare <- sub(" AS LINE_ELIGIBLE$", "", el_col)
  glue("
    WITH coh AS (
      SELECT cast(PATID as string) AS PATID,
             cast(INDEX_DATE as date) AS INDEX_DATE,
             cast(ENDDATE as date)    AS ENDDATE,
             cast(ENDDATE_CE as date) AS ENDDATE_CE,
             cast(DEATH_DT as date)   AS DEATH_DT
      FROM {cohort_tbl}
    ),
    ln AS (
      SELECT cast(PATID as string) AS PATID,
             cast(LOT_NUM as int)  AS LOT_NUM,
             cast(LOT_START_DT as date)    AS LOT_START_DT,
             cast(LOT_BASE_END_DT as date) AS LOT_END_DT,
             LOT_BASE_END_REASON           AS LOT_END_REASON,
             LOT_BASE_MEDS                 AS REGIMEN
      FROM {lines_tbl}
    ),
    nxt AS (
      SELECT l.*,
             -- The next line this patient actually has, whatever its number:
             -- lead() over the ordered lines rather than LOT_NUM + 1, so a
             -- gap in the numbering cannot silently read as 'no next line'.
             lead(l.LOT_START_DT) OVER (PARTITION BY l.PATID ORDER BY l.LOT_NUM)
               AS NEXT_LOT_START_DT,
             lead(l.LOT_NUM) OVER (PARTITION BY l.PATID ORDER BY l.LOT_NUM)
               AS NEXT_LOT_NUM
      FROM ln l
    )
    SELECT n.PATID, n.LOT_NUM, n.LOT_START_DT, n.LOT_END_DT, n.LOT_END_REASON,
           n.REGIMEN, n.NEXT_LOT_START_DT, n.NEXT_LOT_NUM,
           c.INDEX_DATE, c.DEATH_DT,
           {dx_cols},
           {el_col},
           -- The DESTINATION line's eligibility as well as this row's. A gap is
           -- 'among patients initiating a subsequent LOT', so the cohort that
           -- governs a 1L-to-2L gap is the 2L one - which lives on the NEXT row,
           -- not this one. Reading this row's flag makes every 1L-to-2L gap
           -- eligible, because 1L always is, and the restricted answer would be
           -- the unrestricted one.
           lead({el_bare}) OVER (PARTITION BY n.PATID ORDER BY n.LOT_NUM)
             AS NEXT_LINE_ELIGIBLE,
           {FU_END_SQL} AS FU_END_DT
    FROM nxt n INNER JOIN coh c ON c.PATID = n.PATID
    {dx_join}{el_join}")
}

# The three outcomes off that base. Each is a date and a 0/1, not a summary:
# a median with no event flag beside it cannot be recomputed or checked, and
# the study team fits the curves.
#
# An event date after the follow-up end is not an event - the patient ran out of
# observation rather than reaching the outcome - so it censors. One ON the
# follow-up end is an event: death is the follow-up end for anyone who dies
# inside the window, since the cohort clamps ENDDATE at the death date.
# Written once, here, so all three treat the boundary the same way.
# The 2L/3L build's provenance as three constant columns. One definition, used
# by every table that carries a DENOM or a LINE_ELIGIBLE, so the provenance
# cannot land on one output and not the next.
prov_cols <- function(subseq) {
  g <- function(k) {
    v <- if (is.null(subseq)) NULL else subseq[[k]]
    sql_text(if (is.null(v) || is.na(v)) NA_character_ else as.character(v))
  }
  paste0("           ", g("subseq"), " AS SUBSEQ_RUN_ID,\n",
         "           ", g("pre"),    " AS CE_PRE_DAYS,\n",
         "           ", g("fu"),     " AS CE_FU_DAYS,\n")
}

# `subseq` is the 2L/3L build's provenance - which subsequent run, over which
# cohort attempt, under which continuous-enrolment windows - or NULL where
# there are no line cohorts. It goes ON the table.
#
# LINE_ELIGIBLE is a restriction whose meaning is set by those windows, and the
# label is the same whatever they were. A sensitivity build under 180/30 is
# accepted deliberately - that is the sweep's business - but the run said so
# only in its log, which does not outlive the session, while the table it
# produced looked exactly like a 365/90 one. A reader opening OUT_TTE a month
# later had no way to ask.
outcomes_tte_sql <- function(base_sql, run_id, lot_run_id = NA_character_,
                             subseq = NULL) {
  glue("
    WITH b AS ({base_sql}),
    ev AS (
      SELECT b.*,
             -- TTNT: next line or death, whichever is first.
             least(coalesce(b.NEXT_LOT_START_DT, date('9999-12-31')),
                   coalesce(b.DEATH_DT,          date('9999-12-31'))) AS TTNT_DT,
             -- TTD: the line's own end as well, per Table 4.
             least(coalesce(b.LOT_END_DT,        date('9999-12-31')),
                   coalesce(b.NEXT_LOT_START_DT, date('9999-12-31')),
                   coalesce(b.DEATH_DT,          date('9999-12-31'))) AS TTD_DT,
             coalesce(b.DEATH_DT, date('9999-12-31'))                 AS OS_DT
      FROM b
    )
    SELECT PATID, LOT_NUM, LOT_START_DT, LOT_END_DT, LOT_END_REASON, REGIMEN,
           NEXT_LOT_NUM, NEXT_LOT_START_DT, DEATH_DT, FU_END_DT,
           MM_DX_DT, DX_TO_LOT1_DAYS,
           -- Both eligibilities travel to OUT_TTE, because the summaries read
           -- them off it. This projection names its columns, so anything the
           -- base computes and it omits is gone by the time they run.
           LINE_ELIGIBLE, NEXT_LINE_ELIGIBLE,

           -- ON the follow-up end, not before it. Death IS the follow-up end
           -- for anyone who dies inside the study window - the cohort clamps
           -- ENDDATE at the death date - so a strict test makes every death a
           -- censoring and leaves OS with no events at all. An event after the
           -- follow-up end is still censoring: those dates are the 9999-12-31
           -- sentinel or a line the patient was never observed to reach.
           CASE WHEN TTNT_DT <= FU_END_DT THEN 1 ELSE 0 END AS TTNT_EVENT,
           datediff(least(TTNT_DT, FU_END_DT), LOT_START_DT) AS TTNT_DAYS,

           -- Except here: a line whose own end IS the run-out has not ended -
           -- the observation has. That is censoring however the dates fall.
           CASE WHEN TTD_DT <= FU_END_DT
                 AND NOT (coalesce(LOT_END_REASON, '') = 'STUDY_END'
                          AND TTD_DT = LOT_END_DT)
                THEN 1 ELSE 0 END AS TTD_EVENT,
           datediff(least(TTD_DT,  FU_END_DT), LOT_START_DT) AS TTD_DAYS,

           CASE WHEN OS_DT <= FU_END_DT THEN 1 ELSE 0 END AS OS_EVENT,
           datediff(least(OS_DT,   FU_END_DT), LOT_START_DT) AS OS_DAYS,

           -- Why TTNT ended, so a curve can be read without re-deriving it.
           CASE WHEN TTNT_DT >  FU_END_DT              THEN 'CENSORED'
                WHEN NEXT_LOT_START_DT IS NOT NULL
                 AND (DEATH_DT IS NULL
                      OR NEXT_LOT_START_DT <= DEATH_DT) THEN 'NEXT_LOT'
                ELSE 'DEATH' END                        AS TTNT_REASON,
           {sql_text(run_id)}     AS OUT_RUN_ID,
           {sql_text(lot_run_id)} AS LOT_RUN_ID,
           -- The provenance of LINE_ELIGIBLE, beside LINE_ELIGIBLE. NULL where
           -- there are no line cohorts and the flag is NULL too.
{prov_cols(subseq)}           current_timestamp()    AS BUILT_AT
    FROM ev
    WHERE FU_END_DT >= LOT_START_DT")
}

# Both denominators, side by side, as one extra column rather than two sets of
# tables. ALL_LINES is every line in the 1L cohort; LINE_ELIGIBLE keeps only the
# lines whose patient is in that line's own cohort. A line with no cohort of its
# own has LINE_ELIGIBLE NULL and so appears under ALL_LINES only - the
# restricted denominator never silently absorbs a line nobody set a criterion
# for.
#
# When no line-specific cohort is readable there is one denominator to report,
# and offering an empty second one would read as "nobody qualified".
denom_from <- function(tte_tbl, both) paste0(
  tte_tbl, " t CROSS JOIN (SELECT 'ALL_LINES' AS DENOM",
  if (both) " UNION ALL SELECT 'LINE_ELIGIBLE'" else "", ") d")
DENOM_KEEP <- "(d.DENOM = 'ALL_LINES' OR t.LINE_ELIGIBLE = 1)"
# A gap belongs to the line being INITIATED, not the one being left: Table 4
# says "among patients initiating a subsequent LOT", and the cohort that governs
# a 1L-to-2L gap is the 2L one. Keying on this row's flag would make every
# 1L-to-2L gap eligible - 1L always is - so the restricted answer would be the
# unrestricted one, and a 2L-to-3L gap would be judged on 2L eligibility.
DENOM_KEEP_NEXT <- "(d.DENOM = 'ALL_LINES' OR t.NEXT_LINE_ELIGIBLE = 1)"

# Table 4's treatment attrition: number and percent of patients who received
# each subsequent LOT, discontinued and did not receive another, were lost to
# follow-up, or died.
#
# Exclusive and ordered, because a patient can look like more than one: someone
# who starts a next line and later dies is counted as receiving the next line,
# since that is what the row is about. Every other category is conditioned on
# there being no next line.
#
# The protocol names four but they are not exhaustive, and the gap matters.
# A patient still on treatment when the data runs out has not been lost to
# follow-up - they were observed to the end of the study period and were still
# being treated. Folding them into "lost to follow-up" would overstate loss and
# hide the ongoing group entirely, so they get their own count and the five sum
# to N_ON_LINE.
outcomes_attrition_sql <- function(tte_tbl, study_end, run_id, lot_run_id,
                                   both_denoms = FALSE, subseq = NULL) {
  # "Received the next LOT" has to mean OBSERVED to receive it. lot's primary
  # analysis ignores disenrolment, so LOT_LONG_FINAL carries lines that start
  # after a patient's protocol follow-up ended - NEXT_LOT_NUM is populated for
  # them and TTNT already censors them. Counting the column instead of the event
  # credits the study with progressions nobody watched happen, and blocks those
  # patients from every other category, all of which require no next line.
  nxt  <- "TTNT_EVENT = 1 AND TTNT_REASON = 'NEXT_LOT'"
  none <- glue("NOT ({nxt})")
  # No observed next line, no death, and the line never ended inside follow-up:
  # the patient was on treatment when observation stopped. Why it stopped is the
  # difference between the two.
  still <- glue("{none} AND OS_EVENT = 0 AND TTD_EVENT = 0")
  # Table 4 asks for number AND percent. Denominator is the line's own N.
  pct <- function(e) glue("round(100.0 * sum(CASE WHEN {e} THEN 1 ELSE 0 END)
                                 / nullif(count(*), 0), 1)")
  n <- function(e) glue("sum(CASE WHEN {e} THEN 1 ELSE 0 END)")
  died  <- glue("{none} AND OS_EVENT = 1")
  disc  <- glue("{none} AND OS_EVENT = 0 AND TTD_EVENT = 1")
  lost  <- glue("{still} AND FU_END_DT <  date('{study_end}')")
  going <- glue("{still} AND FU_END_DT >= date('{study_end}')")
  glue("
    SELECT d.DENOM, t.LOT_NUM,
           count(*)      AS N_ON_LINE,
           {n(nxt)}      AS N_NEXT_LOT,        {pct(nxt)}   AS PCT_NEXT_LOT,
           {n(died)}     AS N_DIED,            {pct(died)}  AS PCT_DIED,
           {n(disc)}     AS N_DISCON_NO_NEXT,  {pct(disc)}  AS PCT_DISCON_NO_NEXT,
           -- Observation stopped before the study did: they disenrolled.
           {n(lost)}     AS N_LOST_TO_FU,      {pct(lost)}  AS PCT_LOST_TO_FU,
           -- Observation ran to the end of the study period and they were
           -- still on treatment. Not a loss - the study stopped, not them.
           {n(going)}    AS N_ONGOING,         {pct(going)} AS PCT_ONGOING,
{prov_cols(subseq)}
           {sql_text(run_id)}     AS OUT_RUN_ID,
           {sql_text(lot_run_id)} AS LOT_RUN_ID,
           current_timestamp()    AS BUILT_AT
    FROM {denom_from(tte_tbl, both_denoms)}
    WHERE {DENOM_KEEP}
    GROUP BY d.DENOM, t.LOT_NUM ORDER BY d.DENOM, t.LOT_NUM")
}

# Table 4's time from prior LOT to next LOT initiation: among patients starting
# a subsequent LOT, prior start (excluded) to next start (included). Continuous
# months, so days / 30.4375 - the mean Gregorian month, not 30, which drifts by
# six days a year.
outcomes_line_gap_sql <- function(tte_tbl, run_id, lot_run_id,
                                  both_denoms = FALSE, subseq = NULL) {
  glue("
    SELECT d.DENOM,
           t.LOT_NUM                            AS FROM_LOT,
           t.NEXT_LOT_NUM                       AS TO_LOT,
           count(*)                             AS N,
           round(avg(datediff(NEXT_LOT_START_DT, LOT_START_DT)) / 30.4375, 2)
                                                AS MEAN_MONTHS,
           round(percentile_approx(
                   datediff(NEXT_LOT_START_DT, LOT_START_DT), 0.5) / 30.4375, 2)
                                                AS MEDIAN_MONTHS,
           min(datediff(NEXT_LOT_START_DT, LOT_START_DT)) AS MIN_DAYS,
           max(datediff(NEXT_LOT_START_DT, LOT_START_DT)) AS MAX_DAYS,
{prov_cols(subseq)}
           {sql_text(run_id)}     AS OUT_RUN_ID,
           {sql_text(lot_run_id)} AS LOT_RUN_ID,
           current_timestamp()    AS BUILT_AT
    FROM {denom_from(tte_tbl, both_denoms)}
    WHERE {DENOM_KEEP_NEXT} AND
    -- 'Among patients initiating a subsequent LOT' - observed to initiate it.
    -- A line starting after the patient's follow-up ended is one lot recorded
    -- because its primary analysis ignores disenrolment, not one this study
    -- watched begin, and its gap is measured over unobserved time.
          (t.TTNT_EVENT = 1 AND t.TTNT_REASON = 'NEXT_LOT')
    GROUP BY d.DENOM, t.LOT_NUM, t.NEXT_LOT_NUM
    ORDER BY d.DENOM, t.LOT_NUM, t.NEXT_LOT_NUM")
}

# Table 4's patients receiving each line: number and percent on each 1L, 2L, 3L
# and 4L regimen. Regimen as lot recorded it - the SOC categories in 6.2.2 are
# Annex 2's and are not applied here, so this is the raw distribution a category
# map would be built against.
outcomes_regimen_sql <- function(tte_tbl, run_id, lot_run_id,
                                 both_denoms = FALSE, subseq = NULL) {
  glue("
    SELECT d.DENOM, t.LOT_NUM, t.REGIMEN, count(*) AS N,
           round(100.0 * count(*)
                 / sum(count(*)) OVER (PARTITION BY d.DENOM, t.LOT_NUM), 2)
             AS PCT_OF_LINE,
{prov_cols(subseq)}
           {sql_text(run_id)}     AS OUT_RUN_ID,
           {sql_text(lot_run_id)} AS LOT_RUN_ID,
           current_timestamp()    AS BUILT_AT
    FROM {denom_from(tte_tbl, both_denoms)}
    WHERE {DENOM_KEEP}
    GROUP BY d.DENOM, t.LOT_NUM, t.REGIMEN
    ORDER BY d.DENOM, t.LOT_NUM, N DESC")
}

# Table 4's time from diagnosis to 1L initiation, in months: diagnosis date
# (excluded) to index date (included), at the 1L index.
#
# One row per patient, so the 1L rows only - the value is the same on every
# line a patient has, and repeating it per line would weight patients by how
# many lines they reached.
outcomes_dx_to_lot1_sql <- function(tte_tbl, run_id, lot_run_id) {
  glue("
    SELECT count(*)                                        AS N,
           round(avg(DX_TO_LOT1_DAYS) / 30.4375, 2)        AS MEAN_MONTHS,
           round(percentile_approx(DX_TO_LOT1_DAYS, 0.5) / 30.4375, 2)
                                                           AS MEDIAN_MONTHS,
           round(percentile_approx(DX_TO_LOT1_DAYS, 0.25) / 30.4375, 2)
                                                           AS Q1_MONTHS,
           round(percentile_approx(DX_TO_LOT1_DAYS, 0.75) / 30.4375, 2)
                                                           AS Q3_MONTHS,
           min(DX_TO_LOT1_DAYS)                            AS MIN_DAYS,
           max(DX_TO_LOT1_DAYS)                            AS MAX_DAYS,
           -- A 1L start before the diagnosis would be negative, which the
           -- cohort build forbids: the index is the first therapy claim ON OR
           -- AFTER the diagnosis. Counted so that stays true.
           sum(CASE WHEN DX_TO_LOT1_DAYS < 0 THEN 1 ELSE 0 END) AS N_NEGATIVE,
           {sql_text(run_id)}     AS OUT_RUN_ID,
           {sql_text(lot_run_id)} AS LOT_RUN_ID,
           current_timestamp()    AS BUILT_AT
    FROM {tte_tbl}
    WHERE LOT_NUM = 1 AND DX_TO_LOT1_DAYS IS NOT NULL")
}
