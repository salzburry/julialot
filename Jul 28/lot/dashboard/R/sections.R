# What the dashboard shows. This file is the dashboard.
#
# Every panel is one entry below: a name, a label, the tab it lands on, the SQL
# that produces it and how to draw the answer. Adding a panel is adding an
# entry; removing one is deleting an entry or setting its switch to FALSE. No
# other file has to change, and nothing here knows which cohort it is running
# for - the table names arrive as {curly} placeholders and are filled in from
# the run's arguments.
#
# The switch is SHOW_<NAME> in config.csv. Anything that is not TRUE or FALSE
# stops the build: a typo that quietly drops a panel is worse than a halt,
# because the page still renders and nobody can see what is missing.
#
# Placeholders a section may use:
#   {lot_final}     <prefix>LOT_LONG_FINAL  after the line criteria
#   {lot_long}      <prefix>LOT_LONG        before them
#   {patients}      <prefix>LOT_PATIENT_INPUT  the cohort as LOT read it
#   {attrition}     <cohort_prefix>NDMM_ATTRITION, when there is one
#   {run_meta}      <prefix>LOT_RUN_METADATA
#   {cohort}        the cohort table the run was pointed at
#
# Panels describe the study population, {lot_final}. {lot_long} is that table
# before the line criteria, and a patient-level truncate criterion makes the
# two hold different patients - so a panel on it describes people the study
# excluded, with nothing on the page saying so. It belongs on the Validation
# tab, where the comparison is the point, and nowhere else.

# How a section's rows are drawn. Deliberately few: a dashboard nobody can read
# is not better than a table, and every one of these renders without a
# JavaScript library or a plotting package - see render.R.
RENDER_TYPES <- c("table", "kpi", "bar", "sankey")

# What the percentage beside a bar is a percentage of. There is no answer right
# for every chart, and assuming one is how a number comes to mean something
# nobody intended - a share of the first bar, on a chart whose first bar is
# simply the largest category, is arithmetic without a claim behind it.
#   first  of the first bar - a funnel, where row one is the denominator
#   total  of all bars      - a partition, where the bars sum to the whole
#   none   no percentage    - overlapping or merely ranked categories
BAR_PCT <- c("first", "total", "none")

# Which patients the journey section shows. Examples, not a sample: a random
# three patients are three LOT1-only patients, because most patients are. Each
# category names a shape somebody wants to see the algorithm handle, and the
# section reports the ones that matched nobody - so a category missing from the
# output reads as "none in this cohort" rather than "nobody thought to check".
#
# Predicates are over the per-patient columns the section derives below:
#   max_lot  lot1_start_type  lot1_end_reason
#   any_cart  any_sct_auto  any_sct_allo
JOURNEY_CATEGORIES <- list(
  list(label = "LOT1 to LOT2 progressor, drug-started",
       pred  = "max_lot >= 2 AND lot1_start_type = 'MED'"),
  list(label = "LOT1 only, discontinued",
       pred  = "max_lot = 1 AND lot1_end_reason = 'DISCONTINUATION'"),
  list(label = "Reached LOT4 or beyond",
       pred  = "max_lot >= 4"),
  # The CAR-T line itself, not a previous line ending because CAR-T began. A
  # patient whose LOT1 is the CAR-T has no preceding line to carry CART_INIT, so
  # keying on that alone left them out of the examples while the transplant
  # panel counted them - two panels disagreeing about the same patients.
  list(label = "CAR-T",             pred = "any_cart = 1"),
  list(label = "Autologous transplant", pred = "any_sct_auto = 1"),
  list(label = "Allogeneic transplant", pred = "any_sct_allo = 1"),
  list(label = "Died on LOT1",      pred = "lot1_end_reason = 'DEATH'"),
  list(label = "Still on LOT1 at study end", pred = "lot1_end_reason = 'STUDY_END'")
)

# One statement for the whole gallery: the per-patient flags, the first N
# patients of each category, and their lines. Built from the list above so
# adding a category is adding a line there.
#
# PATID is masked to its last six characters, here rather than after the fact,
# so the identifier never reaches the HTML or the CSV export. `order by PATID`
# rather than a random sample: the same cohort gives the same examples twice,
# which is what makes an example something two people can discuss.
.journey_sql <- function(cats = JOURNEY_CATEGORIES) {
  arms <- vapply(cats, function(c_i) paste0(
    "      SELECT PATID, '", gsub("'", "''", c_i$label), "' AS category,\n",
    "             row_number() OVER (ORDER BY PATID) AS rn\n",
    "      FROM pat WHERE ", c_i$pred), character(1))
  paste0("
    WITH pat AS (
      SELECT cast(PATID as string) AS PATID,
             max(LOT_NUM)                                            AS max_lot,
             max(CASE WHEN LOT_NUM = 1 THEN LOT_START_TYPE END)      AS lot1_start_type,
             max(CASE WHEN LOT_NUM = 1 THEN LOT_BASE_END_REASON END) AS lot1_end_reason,
             max(CASE WHEN LOT_CART_LOT_FLG = 1 OR LOT_START_TYPE = 'CART'
                           OR LOT_BASE_END_REASON = 'CART_INIT'
                      THEN 1 ELSE 0 END)                                  AS any_cart,
             max(CASE WHEN LOT_START_TYPE = 'SCT_AUTO' THEN 1 ELSE 0 END)       AS any_sct_auto,
             max(CASE WHEN LOT_START_TYPE = 'SCT_ALLO' THEN 1 ELSE 0 END)       AS any_sct_allo
      FROM {lot_final}
      GROUP BY PATID
    ),
    picked AS (\n", paste(arms, collapse = "\n      UNION ALL\n"), "\n    )
    SELECT p.category                                       AS `Example`,
           concat('...', lower(substr(p.PATID, greatest(length(p.PATID) - 5, 1)))) AS `Patient`,
           l.LOT_NUM                                        AS `Line`,
           l.LOT_START_DT                                   AS `Start`,
           l.LOT_BASE_END_DT                                AS `End`,
           datediff(l.LOT_BASE_END_DT, l.LOT_START_DT)      AS `Days`,
           l.LOT_START_TYPE                                 AS `Started by`,
           l.LOT_BASE_MEDS                                  AS `Regimen`,
           coalesce(l.LOT_BASE_1ST_ADD_MED, '')             AS `First add`,
           l.LOT_BASE_END_REASON                            AS `Ended by`
    FROM picked p
    INNER JOIN {lot_final} l ON cast(l.PATID as string) = p.PATID
    WHERE p.rn <= {journeys_per_category}
    ORDER BY `Example`, `Patient`, `Line`")
}

# One Sankey section for the move from line `a` to line `b`. Generated rather
# than written out per pair: they differ only in two numbers, and copies of a
# query are places for a fix to be applied to some of them.
#
# LEFT JOIN, not INNER: a patient who stopped after LOT{a} used to vanish, so
# the panel could not show how many went on at all. They are a terminal node
# now, and the ribbons leaving a regimen add up to that regimen's patients.
#
# A line decides whether the patient got there, not a regimen string. An
# SCT_ALLO line carries no regimen - 10_lot2_5_base.R suppresses its induction
# rows - so filtering on a non-blank LOT_BASE_MEDS read those patients as "No
# LOT{b}" when they had reached it, and dropped them entirely as a source. That
# invents attrition. Blank regimens are labelled by what started the line.
#
# Non-top-N sources become "Other" rather than being dropped, so the chart
# really is every LOT{a} patient. The stopped node is ranked out of the top-N,
# or the largest single answer could be folded into "Other".
.transition_section <- function(a, b) {
  line <- function(n) paste0("
      SELECT cast(PATID as string) AS PATID,
             coalesce(nullif(trim(LOT_BASE_MEDS), ''),
                      concat(coalesce(LOT_START_TYPE, '?'), ' (no regimen)')) AS reg
      FROM {lot_final}
      WHERE LOT_NUM = ", n)
  list(
  name  = paste0("lot", a, "_to_lot", b),
  tab   = "Transitions",
  label = paste0("LOT", a, " to LOT", b, " by regimen, with those who stopped"),
  needs = "lot_final", render = "sankey",
  sql = paste0("
    WITH a AS (", line(a), "
    ),
    b AS (", line(b), "
    ),
    j AS (
      SELECT a.PATID, a.reg AS src,
             coalesce(b.reg, 'No LOT", b, "') AS tgt,
             CASE WHEN b.PATID IS NULL THEN 1 ELSE 0 END AS stopped
      FROM a LEFT JOIN b ON a.PATID = b.PATID
    ),
    top_src AS (
      SELECT src FROM j GROUP BY src
      ORDER BY count(DISTINCT PATID) DESC LIMIT {top_n}
    ),
    s AS (
      SELECT j.PATID, coalesce(ts.src, 'Other') AS src, j.tgt, j.stopped
      FROM j LEFT JOIN top_src ts ON j.src = ts.src
    ),
    top_tgt AS (
      SELECT tgt FROM s WHERE stopped = 0 GROUP BY tgt
      ORDER BY count(DISTINCT PATID) DESC LIMIT {top_n}
    )
    SELECT s.src                                              AS source,
           CASE WHEN s.stopped = 1 THEN s.tgt
                ELSE coalesce(t.tgt, 'Other') END             AS target,
           count(DISTINCT s.PATID)                            AS n
    FROM s LEFT JOIN top_tgt t ON s.tgt = t.tgt
    GROUP BY 1, 2 ORDER BY n DESC"))
}

# One per step of the ladder, to whatever height this run built. Hardcoding
# four pairs was right only while MAX_LOT was five.
.transition_sections <- function(max_lot = cfg_defaults$max_lot) {
  n <- suppressWarnings(as.integer(max_lot))
  if (is.na(n) || n < 2L)
    stop("MAX_LOT='", max_lot, "' (want a whole number, 2 or more - there is ",
         "no transition to draw below that)", call. = FALSE)
  lapply(seq_len(n - 1L), function(a) .transition_section(a, a + 1L))
}

# ---- The cohort funnel, whatever shape the cohort build wrote it in --------
#
# ATTRITION_TABLE fixed the name, not the shape, and the two cohort builds do
# not agree on one:
#
#   ndmm     NDMM_ATTRITION      RUN_ID, STEP_NUM, CRITERION, N_PATIENTS,
#                                PCT_OF_START, RECORDED_AT
#   overall  <prefix>attrition_report
#                                row_order, run_id, final_table_name,
#                                created_at, step_id, description,
#                                n_30, n_60, n_90
#
# A query against the ndmm columns fails outright on an overall-built cohort,
# and the panel is replaced by a notice that reads as "this study has no
# funnel" rather than "this dashboard cannot read it".
#
# One spec per shape. `cols` identifies the layout, matched against DESCRIBE;
# `stamp` says when the funnel was recorded, used to catch a funnel newer than
# the LOT run. Add a shape by adding an entry.
ATTRITION_LAYOUTS <- list(
  list(name  = "ndmm",
       cols  = c("RUN_ID", "STEP_NUM", "CRITERION", "N_PATIENTS", "RECORDED_AT"),
       stamp = "RECORDED_AT",
       run_col = "RUN_ID",
       # Same query, pinned to one run id instead of to the newest.
       sql_run = "
         SELECT a.CRITERION AS label, a.N_PATIENTS AS n
         FROM {attrition} a
         WHERE a.RUN_ID = '{cohort_run}'
         ORDER BY a.STEP_NUM",
       # History: the build deletes and re-inserts only its own RUN_ID, so
       # previous runs stay and an unfiltered read interleaves several funnels
       # by STEP_NUM - with the bar taking its denominator from the first row.
       # Latest by RECORDED_AT, because the dashboard runs afterwards in a
       # different session and cannot know the run id.
       sql = "
         WITH latest AS (
           SELECT RUN_ID FROM {attrition}
           ORDER BY RECORDED_AT DESC LIMIT 1
         )
         SELECT a.CRITERION AS label, a.N_PATIENTS AS n
         FROM {attrition} a INNER JOIN latest l ON a.RUN_ID = l.RUN_ID
         ORDER BY a.STEP_NUM"),

  list(name  = "overall",
       cols  = c("row_order", "run_id", "created_at", "step_id", "description",
                 "n_30", "n_60", "n_90"),
       stamp = "created_at",
       run_col = "run_id",
       sql_run = "
         SELECT description AS label, n_{attrition_window} AS n
         FROM {attrition}
         WHERE run_id = '{cohort_run}'
         ORDER BY row_order",
       # CREATE OR REPLACE, not an append - so this table holds one run and
       # needs no latest-run filter. That is the build's choice, not an
       # assumption made here.
       #
       # Three counts, one cohort. n_30/n_60/n_90 are the outpatient-window
       # sensitivity; only the column matching the configured window describes
       # the cohort that was written, and the other two describe cohorts no
       # table exists for. ATTRITION_WINDOW names which, and the panel label
       # repeats it.
       sql = "
         SELECT description AS label, n_{attrition_window} AS n
         FROM {attrition}
         ORDER BY row_order")
)

DASHBOARD_SECTIONS <- c(list(

  # ---- OVERVIEW ------------------------------------------------------------

  list(name = "run_provenance", tab = "Overview",
       label = "What produced these numbers",
       needs = "run_meta", render = "table",
       # The run that OWNS these tables, resolved before any panel runs - see
       # resolve_owner_run(). Not the latest metadata row, and not the latest
       # complete one either.
       #
       # LOT replaces LOT_LONG_FINAL early and validates it afterwards, so a
       # rerun that replaced the table and then died leaves ITS table on disk
       # with an incomplete row, while the previous run's complete row is the
       # newest that passes. The page would carry the failed run's numbers
       # under the successful run's provenance.
       #
       # LOT_BUILD_STATUS settles it: "complete" is written last, so the latest
       # row is the run that last wrote these tables.
       sql = "
         SELECT RUN_ID, RUN_TIMESTAMP, STUDY_START, STUDY_END, CODE_MD5,
                LINE_CRITERIA_APPLIED, LOT_LONG_BY_LINE
         FROM {run_meta}
         WHERE RUN_ID = '{owner_run}'"),

  list(name = "headline", tab = "Overview",
       label = "Cohort and lines",
       needs = c("patients", "lot_long", "lot_final"), render = "kpi",
       sql = "
         SELECT (SELECT count(*) FROM {patients})                     AS `Patients`,
                (SELECT count(*) FROM {lot_long})                     AS `Lines built`,
                (SELECT count(DISTINCT PATID) FROM {lot_long})        AS `Patients with a line`,
                (SELECT count(*) FROM {lot_final})                    AS `Lines after criteria`,
                (SELECT count(DISTINCT PATID) FROM {lot_final})       AS `Patients after criteria`"),

  # The SQL here is a placeholder. Which query actually runs is decided at run
  # time by resolve_attrition(), because the funnel's shape differs by cohort
  # build and not only its name - see ATTRITION_LAYOUTS below.
  list(name = "attrition", tab = "Overview",
       label = "Cohort attrition, as the cohort build recorded it",
       needs = "attrition", render = "bar", pct = "first",
       layouts = "ATTRITION_LAYOUTS",
       sql = ATTRITION_LAYOUTS[[1]]$sql),

  # The LOT funnel starts where the cohort funnel ends. Its own panels, not
  # rows appended: that one counts patients into the cohort, this one counts
  # what happened afterwards, and one chart running from one into the other
  # would read as a single narrowing.
  #
  # Progression is split off again. Nobody is removed there - a patient with no
  # LOT3 did not progress, or their follow-up ended - so it sits beside the
  # funnel, not inside it. Split by KIND, which the LOT build writes for this.
  #
  # The label carries KIND, because the bar cannot. Two rows are not attrition
  # at all: for a treatment-indexed cohort they re-derive a fact the cohort
  # build already established, so a drop is the two scans disagreeing. Under a
  # heading saying "attrition" it would read as expected loss.
  list(name = "lot_attrition", tab = "Overview",
       label = "LOT: cohort to study population - [check] rows are not attrition",
       needs = "lot_attrition", render = "bar", pct = "first",
       sql = "
         SELECT CASE WHEN KIND = 'reconciliation' THEN concat('[check] ', STEP)
                     WHEN KIND = 'criterion'      THEN concat('[removed] ', STEP)
                     ELSE STEP END                AS label,
                N_PATIENTS                        AS n
         FROM {lot_attrition}
         WHERE RUN_ID = '{owner_run}' AND KIND <> 'progression'
         ORDER BY STEP_NUM"),

  list(name = "lot_progression", tab = "Overview",
       label = "How far patients get - percentages are of LOT1",
       needs = "lot_attrition", render = "bar", pct = "first",
       sql = "
         SELECT STEP AS label, N_PATIENTS AS n
         FROM {lot_attrition}
         WHERE RUN_ID = '{owner_run}' AND KIND = 'progression'
         ORDER BY STEP_NUM"),

  # The bars carry one number each. Lines, and the share of the row above -
  # which for a criterion is its own cost and for a line is the share going on
  # to the next - only fit in a table.
  list(name = "lot_attrition_detail", tab = "Overview",
       label = "The same funnel with lines and step-to-step percentages",
       needs = "lot_attrition", render = "table",
       sql = "
         SELECT STEP_NUM                          AS `#`,
                KIND                              AS `Kind`,
                STEP                              AS `Step`,
                N_PATIENTS                        AS `Patients`,
                N_LINES                           AS `Lines`,
                PCT_OF_START                      AS `% of first`,
                PCT_OF_PREV                       AS `% of previous`
         FROM {lot_attrition}
         WHERE RUN_ID = '{owner_run}'
         ORDER BY STEP_NUM"),

  # ---- COHORT --------------------------------------------------------------

  list(name = "demographics", tab = "Cohort",
       label = "Age at index and sex",
       needs = c("patients", "lot_final"), render = "table",
       sql = "
         SELECT CASE WHEN AGE_INDEX_YR < 65 THEN '18-64'
                     WHEN AGE_INDEX_YR < 75 THEN '65-74'
                     WHEN AGE_INDEX_YR < 85 THEN '75-84'
                     ELSE '85+' END                       AS `Age band`,
                upper(coalesce(GDR_CD, 'U'))              AS `Sex`,
                count(*)                                  AS `Patients`
         FROM {patients}
         WHERE PATID IN (SELECT DISTINCT PATID FROM {lot_final})
         GROUP BY 1, 2 ORDER BY 1, 2"),

  list(name = "age_stats", tab = "Cohort",
       label = "Age at index, distribution",
       needs = c("patients", "lot_final"), render = "table",
       sql = "
         SELECT count(*)                                              AS `Patients`,
                round(avg(AGE_INDEX_YR), 1)                           AS `Mean`,
                percentile_approx(AGE_INDEX_YR, 0.25)                 AS `P25`,
                percentile_approx(AGE_INDEX_YR, 0.5)                  AS `Median`,
                percentile_approx(AGE_INDEX_YR, 0.75)                 AS `P75`,
                min(AGE_INDEX_YR)                                     AS `Min`,
                max(AGE_INDEX_YR)                                     AS `Max`
         FROM {patients}
         WHERE PATID IN (SELECT DISTINCT PATID FROM {lot_final})"),

  list(name = "index_by_year", tab = "Cohort",
       label = "Index dates by year",
       needs = c("patients", "lot_final"), render = "bar", pct = "total",
       sql = "
         SELECT cast(year(INDEX_DATE) as string) AS label, count(*) AS n
         FROM {patients}
         WHERE PATID IN (SELECT DISTINCT PATID FROM {lot_final})
         GROUP BY 1 ORDER BY 1"),

  # Two definitions, two rows. FU_DAYS runs to death or the study end and
  # ignores disenrolment - LOT's primary analysis. FU_DAYS_CE is also capped
  # where enrolment stops - the protocol's follow-up period, and what outcomes
  # censors on. Showing one picks a side silently.
  #
  # Rows rather than one wide line: side-by-side percentiles of two different
  # definitions invite reading across as though the columns were a
  # distribution. Same patients both times, so the two Patients cells agreeing
  # is part of the panel.
  list(name = "followup", tab = "Cohort",
       label = "Follow-up days, on both definitions",
       needs = c("patients", "lot_final"), render = "table",
       sql = "
         SELECT `Follow-up ends at`, `Patients`, `Mean`, `Min`, `P25`,
                `Median`, `P75`, `Max`
         FROM (
           SELECT 1 AS ord,
                  'Death or study end'                       AS `Follow-up ends at`,
                  count(*)                                   AS `Patients`,
                  round(avg(FU_DAYS), 1)                     AS `Mean`,
                  min(FU_DAYS)                               AS `Min`,
                  percentile_approx(FU_DAYS, 0.25)           AS `P25`,
                  percentile_approx(FU_DAYS, 0.5)            AS `Median`,
                  percentile_approx(FU_DAYS, 0.75)           AS `P75`,
                  max(FU_DAYS)                               AS `Max`
           FROM {patients}
           WHERE PATID IN (SELECT DISTINCT PATID FROM {lot_final})
           UNION ALL
           SELECT 2,
                  '...or disenrolment, whichever is first',
                  count(*),
                  round(avg(FU_DAYS_CE), 1),
                  min(FU_DAYS_CE),
                  percentile_approx(FU_DAYS_CE, 0.25),
                  percentile_approx(FU_DAYS_CE, 0.5),
                  percentile_approx(FU_DAYS_CE, 0.75),
                  max(FU_DAYS_CE)
           FROM {patients}
           WHERE PATID IN (SELECT DISTINCT PATID FROM {lot_final})
         ) fu ORDER BY ord"),

  # What ended it. A short median because people died and a short median
  # because they left the data are the same number and different findings.
  #
  # In that order, so a patient who disenrolled and died later counts as
  # disenrolled - the death is outside the window this cohort can see. The
  # three are exclusive and cover everyone.
  #
  # Not outcomes' N_LOST_TO_FU / N_ONGOING, and does not reconcile with them.
  # This is one row per PATIENT over the whole study population. Those are one
  # row per patient-LINE, and only over the residual after the next line, death
  # and discontinuation have been taken out - so this panel's "Died" has no
  # counterpart there at all. What the two share is the boundary: follow-up
  # ending before the study end rather than at it.
  list(name = "followup_end_reason", tab = "Cohort",
       label = "What ended follow-up",
       needs = c("patients", "lot_final"), render = "bar", pct = "total",
       sql = "
         SELECT CASE
                  WHEN DEATH_DT IS NOT NULL AND DEATH_DT <= ENDDATE_CE
                    THEN 'Died'
                  WHEN ENDDATE_CE < ENDDATE
                    THEN 'Disenrolled'
                  ELSE 'Followed to study end'
                END                     AS label,
                count(*)                AS n
         FROM {patients}
         WHERE PATID IN (SELECT DISTINCT PATID FROM {lot_final})
         GROUP BY 1 ORDER BY 2 DESC"),

  # The study end is fixed, so a 2025 index has less room than a 2017 one. Any
  # median over the whole cohort averages across that, which is what makes a
  # trend elsewhere hard to read as a finding.
  #
  # `Died in FU` is the death that ENDED follow-up - the predicate the panel
  # above partitions on, not every recorded death. Two columns on one page both
  # called "died", differing by the patients who left before dying, is the
  # discrepancy nobody can reconcile later.
  list(name = "followup_by_index_year", tab = "Cohort",
       label = "Follow-up days by index year",
       needs = c("patients", "lot_final"), render = "table",
       sql = "
         SELECT cast(year(INDEX_DATE) as string)                      AS `Index year`,
                count(*)                                              AS `Patients`,
                percentile_approx(FU_DAYS, 0.5)                       AS `Median`,
                percentile_approx(FU_DAYS_CE, 0.5)                    AS `Median (CE)`,
                percentile_approx(FU_DAYS_CE, 0.25)                   AS `P25 (CE)`,
                percentile_approx(FU_DAYS_CE, 0.75)                   AS `P75 (CE)`,
                sum(CASE WHEN DEATH_DT IS NOT NULL AND DEATH_DT <= ENDDATE_CE
                         THEN 1 ELSE 0 END)                           AS `Died in FU`
         FROM {patients}
         WHERE PATID IN (SELECT DISTINCT PATID FROM {lot_final})
         GROUP BY 1 ORDER BY 1"),

  # Not a confounder - the other direction. Highest line reached is a
  # post-index outcome, so grouping by it selects on having survived and stayed
  # enrolled long enough to get there. Later-line groups have longer follow-up
  # by construction, which is what this panel is for saying out loud.
  #
  # The restriction is stated even though the inner join already applies it.
  # Every cohort panel here says which population it is on in its own SQL,
  # rather than leaving a reader to work out that a join is inner.
  list(name = "followup_by_max_lot", tab = "Cohort",
       label = "Follow-up days by highest line reached",
       needs = c("patients", "lot_final"), render = "table",
       sql = "
         SELECT concat('LOT', cast(m.max_lot as string))                 AS `Highest line`,
                count(*)                                                 AS `Patients`,
                percentile_approx(p.FU_DAYS, 0.5)                        AS `Median`,
                percentile_approx(p.FU_DAYS_CE, 0.5)                     AS `Median (CE)`,
                percentile_approx(p.FU_DAYS_CE, 0.25)                    AS `P25 (CE)`,
                percentile_approx(p.FU_DAYS_CE, 0.75)                    AS `P75 (CE)`,
                sum(CASE WHEN p.DEATH_DT IS NOT NULL
                              AND p.DEATH_DT <= p.ENDDATE_CE
                         THEN 1 ELSE 0 END)                          AS `Died in FU`
         FROM {patients} p
         INNER JOIN (SELECT PATID, max(LOT_NUM) AS max_lot
                     FROM {lot_final} GROUP BY PATID) m
                 ON m.PATID = p.PATID
         WHERE p.PATID IN (SELECT DISTINCT PATID FROM {lot_final})
         GROUP BY 1 ORDER BY 1"),

  # What the cohort's own follow-up-CE window costs, read off the table the
  # cohort build writes for exactly this. Not a sensitivity anyone has to run:
  # every build produces it, and the gap between the applied row and the
  # 90-day row is the deviation priced in patients. DECISIONS.md #1.
  #
  # N_COHORT is the whole conjunction at that window, so it is the cohort you
  # would ship rather than one criterion's count.
  list(name = "fu_ce_window", tab = "Cohort",
       label = "What the follow-up-enrolment window costs",
       needs = "fu_ce_counts", render = "table",
       sql = "
         SELECT FU_CE_RULE                                            AS `Window`,
                N_PASSING_CRITERION_5                                 AS `Passing the CE criterion`,
                N_COHORT                                              AS `Cohort at this window`,
                CASE WHEN IS_THIS_RUN = 1 THEN 'this run' ELSE '' END AS `Applied`
         FROM {fu_ce_counts}
         ORDER BY N_COHORT DESC, FU_CE_RULE"),

  # Lines.

  # Follow-up as the outcomes build sees it, which is not what the Cohort tab
  # shows. One row per patient-LINE, measured from that line's start rather
  # than from the index date - so it is the window each TTNT, TTD and OS was
  # actually observed over.
  #
  # The event counts are the point. A median TTNT is only readable if enough
  # lines reached the event; a line where almost everything is censored has a
  # median the data cannot support, and nothing else on the page says so.
  list(name = "outcomes_followup", tab = "Lines",
       label = "Observed follow-up per line, from the outcomes build",
       needs = "out_tte", render = "table",
       sql = "
         SELECT LOT_NUM                                                AS `Line`,
                count(*)                                               AS `Lines`,
                sum(CASE WHEN LINE_ELIGIBLE = 1 THEN 1 ELSE 0 END)     AS `Line-eligible`,
                percentile_approx(datediff(FU_END_DT, LOT_START_DT), 0.25) AS `P25 days`,
                percentile_approx(datediff(FU_END_DT, LOT_START_DT), 0.5)  AS `Median days`,
                percentile_approx(datediff(FU_END_DT, LOT_START_DT), 0.75) AS `P75 days`,
                sum(TTNT_EVENT)                                        AS `TTNT events`,
                sum(TTD_EVENT)                                         AS `TTD events`,
                sum(OS_EVENT)                                          AS `Deaths`
         FROM {out_tte}
         GROUP BY LOT_NUM ORDER BY LOT_NUM"),

  list(name = "lines_per_patient", tab = "Lines",
       label = "Highest line reached",
       needs = "lot_final", render = "bar", pct = "total",
       sql = "
         SELECT concat('LOT', cast(hi as string)) AS label, count(*) AS n
         FROM (SELECT PATID, max(LOT_NUM) AS hi FROM {lot_final} GROUP BY PATID)
         GROUP BY 1 ORDER BY 1"),

  list(name = "start_type", tab = "Lines",
       label = "How each line started",
       needs = "lot_final", render = "table",
       sql = "
         SELECT LOT_NUM AS `Line`, LOT_START_TYPE AS `Start type`,
                count(*) AS `Lines`
         FROM {lot_final} GROUP BY 1, 2 ORDER BY 1, 2"),

  list(name = "end_reason", tab = "Lines",
       label = "Why each line ended",
       needs = "lot_final", render = "table",
       sql = "
         SELECT LOT_NUM AS `Line`, LOT_BASE_END_REASON AS `End reason`,
                count(*) AS `Lines`
         FROM {lot_final} GROUP BY 1, 2 ORDER BY 1, 2"),

  # LOT_BASE_LENGTH, not datediff. The engine defines a line's length
  # inclusively - datediff(end, start) + 1 - and stores it, so recomputing it
  # here without the +1 reported every percentile one day short of the column
  # sitting beside it. build_lot.R's own lot1_duration_is_plausible check
  # carries the same warning; this section was the thing it warns about.
  #
  # Completed lines only. A line still running at study end has not finished,
  # and its length so far is not a length: folding those in counts a censored
  # line as a short one and drags the median down. They are counted in their
  # own column instead, because how many there are is what says whether the
  # median can be read at all. This is the definition run_benchmarks.R uses for
  # median_line_duration_days, so the two now agree rather than differing by
  # the censoring and a day.
  list(name = "line_length", tab = "Lines",
       label = "Line length in days (completed lines)",
       needs = "lot_final", render = "table",
       sql = "
         SELECT LOT_NUM                                                   AS `Line`,
                sum(CASE WHEN coalesce(LOT_BASE_END_REASON, '') <> 'STUDY_END'
                         THEN 1 ELSE 0 END)                               AS `Completed`,
                sum(CASE WHEN LOT_BASE_END_REASON = 'STUDY_END'
                         THEN 1 ELSE 0 END)                               AS `Still open`,
                percentile_approx(CASE WHEN coalesce(LOT_BASE_END_REASON, '') <> 'STUDY_END'
                                       THEN LOT_BASE_LENGTH END, 0.25)    AS `P25`,
                percentile_approx(CASE WHEN coalesce(LOT_BASE_END_REASON, '') <> 'STUDY_END'
                                       THEN LOT_BASE_LENGTH END, 0.5)     AS `Median`,
                percentile_approx(CASE WHEN coalesce(LOT_BASE_END_REASON, '') <> 'STUDY_END'
                                       THEN LOT_BASE_LENGTH END, 0.75)    AS `P75`
         FROM {lot_final} WHERE LOT_BASE_LENGTH IS NOT NULL
         GROUP BY 1 ORDER BY 1"),

  # The review table. The headline above is three percentiles; this is the
  # shape of the distribution behind them, per line, so a median can be read
  # with the tail it came from rather than on its own. Same definition as the
  # section above - completed lines, LOT_BASE_LENGTH - so the two cannot
  # disagree, and the censored count travels with it for the same reason.
  list(name = "line_length_detail", tab = "Lines",
       label = "Line length in days - full distribution (completed lines)",
       needs = "lot_final", render = "table",
       sql = "
         SELECT LOT_NUM                                                   AS `Line`,
                sum(CASE WHEN coalesce(LOT_BASE_END_REASON, '') <> 'STUDY_END'
                         THEN 1 ELSE 0 END)                               AS `Completed`,
                sum(CASE WHEN LOT_BASE_END_REASON = 'STUDY_END'
                         THEN 1 ELSE 0 END)                               AS `Still open`,
                min(CASE WHEN coalesce(LOT_BASE_END_REASON, '') <> 'STUDY_END'
                         THEN LOT_BASE_LENGTH END)                        AS `Min`,
                percentile_approx(CASE WHEN coalesce(LOT_BASE_END_REASON, '') <> 'STUDY_END'
                                       THEN LOT_BASE_LENGTH END, 0.10)    AS `P10`,
                percentile_approx(CASE WHEN coalesce(LOT_BASE_END_REASON, '') <> 'STUDY_END'
                                       THEN LOT_BASE_LENGTH END, 0.25)    AS `P25`,
                percentile_approx(CASE WHEN coalesce(LOT_BASE_END_REASON, '') <> 'STUDY_END'
                                       THEN LOT_BASE_LENGTH END, 0.5)     AS `Median`,
                percentile_approx(CASE WHEN coalesce(LOT_BASE_END_REASON, '') <> 'STUDY_END'
                                       THEN LOT_BASE_LENGTH END, 0.75)    AS `P75`,
                percentile_approx(CASE WHEN coalesce(LOT_BASE_END_REASON, '') <> 'STUDY_END'
                                       THEN LOT_BASE_LENGTH END, 0.90)    AS `P90`,
                max(CASE WHEN coalesce(LOT_BASE_END_REASON, '') <> 'STUDY_END'
                         THEN LOT_BASE_LENGTH END)                        AS `Max`,
                round(avg(CASE WHEN coalesce(LOT_BASE_END_REASON, '') <> 'STUDY_END'
                               THEN LOT_BASE_LENGTH END), 1)              AS `Mean`
         FROM {lot_final} WHERE LOT_BASE_LENGTH IS NOT NULL
         GROUP BY 1 ORDER BY 1"),

  list(name = "med_count", tab = "Lines",
       label = "Drugs in the base regimen",
       needs = "lot_final", render = "table",
       sql = "
         SELECT LOT_NUM AS `Line`, LOT_MED_CNT AS `Drugs`, count(*) AS `Lines`
         FROM {lot_final} GROUP BY 1, 2 ORDER BY 1, 2"),

  # ---- REGIMENS ------------------------------------------------------------

  list(name = "top_regimens", tab = "Regimens",
       label = "Most common base regimens, by line",
       needs = "lot_final", render = "table",
       # Ranked within line, so line 1's long tail does not crowd out line 4.
       #
       # Blank regimens are labelled by what started the line, the same way the
       # transitions panel does it. An ALLO line carries no regimen string, and
       # on this table there is no other column to say so - the row came out as
       # an empty cell against a count, which the reader has to guess at. The
       # label is built in the innermost select and grouped on, so a real
       # regimen still groups exactly as before.
       sql = "
         SELECT `Line`, `Regimen`, `Patients` FROM (
           SELECT `Line`, `Regimen`, count(DISTINCT PATID) AS `Patients`,
                  row_number() OVER (PARTITION BY `Line`
                                     ORDER BY count(DISTINCT PATID) DESC) AS rn
           FROM (
             SELECT LOT_NUM AS `Line`, PATID,
                    coalesce(nullif(trim(LOT_BASE_MEDS), ''),
                             concat(coalesce(LOT_START_TYPE, '?'), ' (no regimen)'))
                      AS `Regimen`
             FROM {lot_final})
           GROUP BY `Line`, `Regimen`)
         WHERE rn <= {top_n} ORDER BY `Line`, `Patients` DESC"),

  list(name = "first_added_med", tab = "Regimens",
       label = "First drug added after the base regimen",
       needs = "lot_final", render = "table",
       sql = "
         SELECT `Line`, `Added`, `Lines` FROM (
           SELECT LOT_NUM AS `Line`,
                  coalesce(LOT_BASE_1ST_ADD_MED, '(none)') AS `Added`,
                  count(*) AS `Lines`,
                  row_number() OVER (PARTITION BY LOT_NUM
                                     ORDER BY count(*) DESC) AS rn
           FROM {lot_final} GROUP BY LOT_NUM, LOT_BASE_1ST_ADD_MED)
         WHERE rn <= {top_n} ORDER BY `Line`, `Lines` DESC"),

  # ---- TRANSPLANT ----------------------------------------------------------

  list(name = "sct", tab = "Transplant",
       label = "Lines that are a transplant or CAR-T",
       needs = "lot_final", render = "table",
       sql = "
         SELECT LOT_NUM                                                AS `Line`,
                sum(CASE WHEN LOT_ALLO_LOT_FLG = 1 THEN 1 ELSE 0 END)  AS `ALLO`,
                sum(CASE WHEN LOT_CART_LOT_FLG = 1 THEN 1 ELSE 0 END)  AS `CAR-T`,
                sum(CASE WHEN LOT_START_TYPE = 'SCT_AUTO' THEN 1 ELSE 0 END) AS `AUTO start`,
                count(*)                                               AS `Lines`
         FROM {lot_final} GROUP BY 1 ORDER BY 1"),

  # ---- TRANSITIONS ---------------------------------------------------------
  #
  # Who moves from which regimen to which, one Sankey per consecutive pair, to
  # whatever height this run built - see .transition_sections(), spliced in
  # below rather than listed here.
  #
  # Every LOT{a} patient is in it, including those who never reached LOT{b} -
  # they are a terminal node, so the ribbons leaving a regimen add up to that
  # regimen's patients.
  #
  # Top N sources; the rest collapse to "Other", drawn at the bottom because it
  # is a bucket rather than a regimen. The stopped node is ranked out of that.

  # Patient examples.

  list(name = "patient_journeys", tab = "Patient examples",
       label = "Line-by-line journeys, a few patients per scenario",
       needs = "lot_final", render = "table",
       sql = .journey_sql()),

  list(name = "journey_coverage", tab = "Patient examples",
       label = "Scenarios, and how many patients each one has",
       needs = "lot_final", render = "bar", pct = "none",
       # The denominator behind the gallery. A scenario with no patients is the
       # interesting case - it means either the cohort has none or a rule is not
       # firing - and without this the reader cannot tell which of the two the
       # missing panel above is.
       #
       # No percentage: a patient can be in several scenarios at once, so the
       # bars do not partition anything and any denominator would invite a
       # reader to add them up.
       sql = paste0("
         WITH pat AS (
           SELECT cast(PATID as string) AS PATID,
                  max(LOT_NUM)                                            AS max_lot,
                  max(CASE WHEN LOT_NUM = 1 THEN LOT_START_TYPE END)      AS lot1_start_type,
                  max(CASE WHEN LOT_NUM = 1 THEN LOT_BASE_END_REASON END) AS lot1_end_reason,
                  max(CASE WHEN LOT_CART_LOT_FLG = 1 OR LOT_START_TYPE = 'CART'
                           OR LOT_BASE_END_REASON = 'CART_INIT'
                      THEN 1 ELSE 0 END)                                  AS any_cart,
                  max(CASE WHEN LOT_START_TYPE = 'SCT_AUTO' THEN 1 ELSE 0 END)       AS any_sct_auto,
                  max(CASE WHEN LOT_START_TYPE = 'SCT_ALLO' THEN 1 ELSE 0 END)       AS any_sct_allo
           FROM {lot_final} GROUP BY PATID
         )
         SELECT label, n FROM (\n",
         paste(vapply(JOURNEY_CATEGORIES, function(c_i) paste0(
           "           SELECT '", gsub("'", "''", c_i$label), "' AS label,",
           " count(*) AS n, ", which(vapply(JOURNEY_CATEGORIES, function(x)
             identical(x$label, c_i$label), logical(1)))[1], " AS ord",
           " FROM pat WHERE ", c_i$pred), character(1)),
           collapse = "\n           UNION ALL\n"),
         "\n         ) ORDER BY ord")),

  # ---- VALIDATION ----------------------------------------------------------

  list(name = "criteria_impact", tab = "Validation",
       label = "What the line criteria removed",
       needs = c("lot_long", "lot_final"), render = "kpi",
       # LOT_LONG against LOT_LONG_FINAL. A truncate criterion makes these two
       # different tables, and the difference is the criterion's cost.
       sql = "
         SELECT (SELECT count(DISTINCT PATID) FROM {lot_long})  AS `Patients before`,
                (SELECT count(DISTINCT PATID) FROM {lot_final}) AS `Patients after`,
                (SELECT count(DISTINCT PATID) FROM {lot_long})
                  - (SELECT count(DISTINCT PATID) FROM {lot_final}) AS `Removed`,
                (SELECT count(*) FROM {lot_long})  AS `Lines before`,
                (SELECT count(*) FROM {lot_final}) AS `Lines after`"),

  list(name = "line_integrity", tab = "Validation",
       label = "Lines that should not exist",
       needs = "lot_long", render = "table",
       # Each of these is impossible unless something earlier is wrong. The lot
       # build stops on them; they are repeated here so a dashboard read on its
       # own still shows a zero rather than an absence.
       sql = "
         SELECT
           sum(CASE WHEN LOT_BASE_END_DT < LOT_START_DT THEN 1 ELSE 0 END) AS `End before start`,
           sum(CASE WHEN LOT_START_DT IS NULL THEN 1 ELSE 0 END)           AS `No start date`,
           sum(CASE WHEN LOT_BASE_END_DT IS NULL THEN 1 ELSE 0 END)        AS `No end date`,
           sum(CASE WHEN LOT_NUM < 1 THEN 1 ELSE 0 END)                    AS `Line below 1`
         FROM {lot_long}")
),
.transition_sections())

FIELDS <- c("name", "tab", "label", "needs", "render", "sql")

.is_str <- function(x) is.character(x) && length(x) == 1L && !is.na(x) && nzchar(trimws(x))

# A malformed section that renders an empty panel is the failure worth spending
# code on: the dashboard still builds, and the panel that is missing is the one
# nobody notices. Checked before anything runs.
validate_sections <- function(secs = DASHBOARD_SECTIONS, inputs = NULL) {
  bad <- character(0); seen <- character(0)
  for (i in seq_along(secs)) {
    s <- secs[[i]]
    at <- paste0("section ", i)
    if (!is.list(s)) { bad <- c(bad, paste0(at, ": not a list")); next }
    if (.is_str(s$name)) at <- paste0("'", s$name, "'")
    miss <- setdiff(FIELDS, names(s))
    if (length(miss)) {
      bad <- c(bad, paste0(at, ": missing ", paste(miss, collapse = ", ")))
      next
    }
    for (f in c("name", "tab", "label", "sql"))
      if (!.is_str(s[[f]])) bad <- c(bad, paste0(at, ": ", f, " must be one non-empty string"))
    if (!.is_str(s$render) || !s$render %in% RENDER_TYPES)
      bad <- c(bad, paste0(at, ": render must be one of ",
                           paste(RENDER_TYPES, collapse = ", ")))
    if (identical(s$render, "bar")) {
      if (is.null(s$pct) || !.is_str(s$pct) || !s$pct %in% BAR_PCT)
        bad <- c(bad, paste0(at, ": a bar must say what its percentage is of - ",
                             paste(BAR_PCT, collapse = ", ")))
    } else if (!is.null(s$pct)) {
      bad <- c(bad, paste0(at, ": pct means nothing to a ", s$render))
    }
    if (!is.character(s$needs) || !length(s$needs))
      bad <- c(bad, paste0(at, ": needs must name at least one input"))
    else if (!is.null(inputs)) {
      unknown <- setdiff(s$needs, names(inputs))
      if (length(unknown))
        bad <- c(bad, paste0(at, ": needs an input that does not exist: ",
                             paste(unknown, collapse = ", ")))
    }
    # The switch is SHOW_<NAME> and R is case-sensitive where the environment is
    # not, so two names differing only in case are one switch.
    if (.is_str(s$name)) {
      if (toupper(s$name) %in% seen)
        bad <- c(bad, paste0(at, ": duplicate name (case does not distinguish)"))
      seen <- c(seen, toupper(s$name))
    }
  }
  if (length(bad))
    stop("Dashboard sections are not usable:\n  ", paste(bad, collapse = "\n  "),
         call. = FALSE)
  invisible(TRUE)
}

# SHOW_<NAME> in config.csv. Default TRUE: a section declared here is meant to
# be shown, and switching one off is the deliberate act.
section_enabled <- function(s) {
  v <- Sys.getenv(paste0("SHOW_", toupper(s$name)), unset = "TRUE")
  if (!toupper(trimws(v)) %in% c("TRUE", "FALSE"))
    stop("SHOW_", toupper(s$name), "='", v, "' (want TRUE or FALSE)", call. = FALSE)
  identical(toupper(trimws(v)), "TRUE")
}

enabled_sections <- function(secs = DASHBOARD_SECTIONS) Filter(section_enabled, secs)
