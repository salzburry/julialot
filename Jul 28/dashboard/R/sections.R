# What the dashboard shows. This file is the dashboard.
#
# Every panel is one entry below: a name, a label, the tab it lands on, the SQL
# that produces it and how to draw the answer. Adding a panel is adding an
# entry; removing one is deleting an entry or setting its switch to FALSE. No
# other file has to change, and nothing here knows which cohort it is running
# for - the table names arrive as {curly} placeholders and are filled in from
# the run's arguments.
#
# The switch is SHOW_<NAME> in config.csv, the same shape as lot's
# APPLY_<NAME>. Anything that is not TRUE or FALSE stops the build: a typo that
# quietly drops a panel is worse than a halt, because the dashboard still
# renders and nobody can see what is missing from it.
#
# Placeholders a section may use:
#   {lot_final}     <prefix>LOT_LONG_FINAL  after the line criteria
#   {lot_long}      <prefix>LOT_LONG        before them
#   {patients}      <prefix>LOT_PATIENT_INPUT  the cohort as LOT read it
#   {attrition}     <cohort_prefix>NDMM_ATTRITION, when there is one
#   {run_meta}      <prefix>LOT_RUN_METADATA
#   {cohort}        the cohort table the run was pointed at
#
# Describe the study population, which is {lot_final}. LOT_LONG is that table
# before the line criteria, and with a patient-level truncate criterion such as
# no_belantamab the two hold different PATIENTS, not merely different lines. A
# panel drawn on LOT_LONG therefore describes people the study excluded, with
# nothing on the page saying so.
#
# {lot_long} belongs on the Validation tab, where the comparison is the point,
# and nowhere else. {patients} is the cohort LOT was handed, so a panel over it
# restricts to the PATIDs that survived.

# How a section's rows are drawn. Deliberately few: a dashboard nobody can read
# is not better than a table, and every one of these renders without a
# JavaScript library or a plotting package - see render.R.
RENDER_TYPES <- c("table", "kpi", "bar", "sankey")

# What the percentage beside a bar is a percentage OF. There is no answer right
# for every chart, and assuming one is how a number comes to mean something
# nobody intended - a share of the first bar, on a chart whose first bar is
# simply the largest category, is arithmetic without a claim behind it.
#   first  of the first bar - a funnel, where row one IS the denominator
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
  # patient whose LOT1 IS the CAR-T has no preceding line to carry CART_INIT, so
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
# than written three times: the three differ only in two numbers, and three
# copies of a query is three places for a fix to be applied twice.
.transition_section <- function(a, b) list(
  name  = paste0("lot", a, "_to_lot", b),
  tab   = "Transitions",
  label = paste0("LOT", a, " to LOT", b, " by regimen (progressors only)"),
  needs = "lot_final", render = "sankey",
  sql = paste0("
    WITH a AS (
      SELECT cast(PATID as string) AS PATID, LOT_BASE_MEDS AS reg
      FROM {lot_final}
      WHERE LOT_NUM = ", a, " AND LOT_BASE_MEDS IS NOT NULL
        AND trim(LOT_BASE_MEDS) <> ''
    ),
    b AS (
      SELECT cast(PATID as string) AS PATID, LOT_BASE_MEDS AS reg
      FROM {lot_final}
      WHERE LOT_NUM = ", b, " AND LOT_BASE_MEDS IS NOT NULL
        AND trim(LOT_BASE_MEDS) <> ''
    ),
    j AS (
      SELECT a.PATID, a.reg AS src, b.reg AS tgt
      FROM a INNER JOIN b ON a.PATID = b.PATID
    ),
    top_src AS (
      SELECT src FROM j GROUP BY src
      ORDER BY count(DISTINCT PATID) DESC LIMIT {top_n}
    ),
    s AS (SELECT j.* FROM j INNER JOIN top_src t ON j.src = t.src),
    top_tgt AS (
      SELECT tgt FROM s GROUP BY tgt
      ORDER BY count(DISTINCT PATID) DESC LIMIT {top_n}
    )
    SELECT s.src                                        AS source,
           coalesce(t.tgt, 'Other')                     AS target,
           count(DISTINCT s.PATID)                      AS n
    FROM s LEFT JOIN top_tgt t ON s.tgt = t.tgt
    GROUP BY 1, 2 ORDER BY n DESC")
)

# ---- The cohort funnel, whatever shape the cohort build wrote it in --------
#
# Making ATTRITION_TABLE a setting fixed the NAME. It did not fix the SHAPE,
# and the two cohort builds in this folder do not agree on one:
#
#   nndm     NDMM_ATTRITION      RUN_ID, STEP_NUM, CRITERION, N_PATIENTS,
#                                PCT_OF_START, RECORDED_AT
#   overall  <prefix>attrition_report
#                                row_order, run_id, final_table_name,
#                                created_at, step_id, description,
#                                n_30, n_60, n_90
#
# A single query against the nndm columns therefore fails outright on an
# overall-built cohort - the panel is replaced by a query-failed notice while
# the rest of the page renders, which reads as "this study has no funnel"
# rather than "the dashboard cannot read this funnel".
#
# One spec per shape. `cols` is what identifies the layout - matched against
# DESCRIBE, case-insensitively - and `stamp` is the column saying when the
# funnel was recorded, used to catch a funnel newer than the LOT run below it.
#
# Add a shape by adding an entry. Nothing else changes.
ATTRITION_LAYOUTS <- list(
  list(name  = "nndm",
       cols  = c("RUN_ID", "STEP_NUM", "CRITERION", "N_PATIENTS", "RECORDED_AT"),
       stamp = "RECORDED_AT",
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
       # CREATE OR REPLACE, not an append - so this table holds one run and
       # needs no latest-run filter. That is the build's choice, not an
       # assumption made here.
       #
       # Three counts, one cohort. n_30/n_60/n_90 are the outpatient-window
       # sensitivity, and only the column matching the window the build was
       # configured with describes the cohort that was actually written; the
       # other two describe cohorts no table exists for. overall's own printer
       # marks the built column with a star and warns against reading the row
       # left to right, so picking one here without saying which would be the
       # same mistake in a different medium. ATTRITION_WINDOW names it and the
       # panel label repeats it.
       sql = "
         SELECT description AS label, n_{attrition_window} AS n
         FROM {attrition}
         ORDER BY row_order")
)

DASHBOARD_SECTIONS <- list(

  # ---- OVERVIEW ------------------------------------------------------------

  list(name = "run_provenance", tab = "Overview",
       label = "What produced these numbers",
       needs = "run_meta", render = "table",
       # The run that OWNS the tables on this prefix, resolved before any panel
       # runs - see resolve_owner_run(). Not "the latest metadata row", and not
       # "the latest completed metadata row" either.
       #
       # Completeness alone is not ownership. LOT writes LOT_LONG_FINAL with
       # CREATE OR REPLACE in the line-criteria phase and only afterwards
       # validates it, records the counts, and marks the build complete. So a
       # rerun that replaced the table and then died leaves ITS table on disk
       # with an incomplete metadata row - filtered out by any completeness
       # test - while the previous run's complete row is still the newest one
       # that passes. The page would then carry the failed run's numbers under
       # the successful run's provenance, which is worse than either alone.
       #
       # LOT_BUILD_STATUS settles it: one row per run, written "complete" last
       # of all, so the latest row on the prefix is the run that last wrote
       # these tables. {owner_run} is that run.
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
  # time by resolve_attrition(), because the funnel's SHAPE differs by cohort
  # build and not only its name - see ATTRITION_LAYOUTS below.
  list(name = "attrition", tab = "Overview",
       label = "Cohort attrition, as the cohort build recorded it",
       needs = "attrition", render = "bar", pct = "first",
       layouts = "ATTRITION_LAYOUTS",
       sql = ATTRITION_LAYOUTS[[1]]$sql),

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

  list(name = "followup", tab = "Cohort",
       label = "Follow-up and death",
       needs = c("patients", "lot_final"), render = "table",
       sql = "
         SELECT count(*)                                              AS `Patients`,
                sum(CASE WHEN DEATH_DT IS NOT NULL THEN 1 ELSE 0 END) AS `Died in window`,
                round(avg(FU_DAYS), 1)                                AS `Mean FU days`,
                percentile_approx(FU_DAYS, 0.5)                       AS `Median FU days`,
                percentile_approx(FU_DAYS, 0.25)                      AS `P25`,
                percentile_approx(FU_DAYS, 0.75)                      AS `P75`
         FROM {patients}
         WHERE PATID IN (SELECT DISTINCT PATID FROM {lot_final})"),

  # ---- LINES ---------------------------------------------------------------

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

  list(name = "line_length", tab = "Lines",
       label = "Line length in days",
       needs = "lot_final", render = "table",
       sql = "
         SELECT LOT_NUM                                               AS `Line`,
                count(*)                                              AS `Lines`,
                percentile_approx(datediff(LOT_BASE_END_DT, LOT_START_DT), 0.25) AS `P25`,
                percentile_approx(datediff(LOT_BASE_END_DT, LOT_START_DT), 0.5)  AS `Median`,
                percentile_approx(datediff(LOT_BASE_END_DT, LOT_START_DT), 0.75) AS `P75`
         FROM {lot_final} GROUP BY 1 ORDER BY 1"),

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
       sql = "
         SELECT `Line`, `Regimen`, `Patients` FROM (
           SELECT LOT_NUM AS `Line`, LOT_BASE_MEDS AS `Regimen`,
                  count(DISTINCT PATID) AS `Patients`,
                  row_number() OVER (PARTITION BY LOT_NUM
                                     ORDER BY count(DISTINCT PATID) DESC) AS rn
           FROM {lot_final} GROUP BY LOT_NUM, LOT_BASE_MEDS)
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

  # Who moves from which regimen to which, one Sankey per consecutive pair.
  #
  # INNER JOIN, so a patient who never reached the next line is not in it: the
  # chart is about what progressors switched to, and carrying non-progressors
  # would put the biggest flow on a transition that never happened. The
  # denominator is on the panel above it, in `lines_per_patient`.
  #
  # Top N sources; targets outside the top N collapse to "Other", so the chart
  # stays readable and nothing is silently dropped - "Other" is drawn, and it
  # sits at the bottom because it is a bucket rather than a regimen.
  .transition_section(1, 2),
  .transition_section(2, 3),
  .transition_section(3, 4),
  .transition_section(4, 5),

  # ---- PATIENT EXAMPLES ----------------------------------------------------

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
       # Each of these is impossible unless something upstream is wrong. The lot
       # build stops on them; they are repeated here so a dashboard read on its
       # own still shows a zero rather than an absence.
       sql = "
         SELECT
           sum(CASE WHEN LOT_BASE_END_DT < LOT_START_DT THEN 1 ELSE 0 END) AS `End before start`,
           sum(CASE WHEN LOT_START_DT IS NULL THEN 1 ELSE 0 END)           AS `No start date`,
           sum(CASE WHEN LOT_BASE_END_DT IS NULL THEN 1 ELSE 0 END)        AS `No end date`,
           sum(CASE WHEN LOT_NUM < 1 THEN 1 ELSE 0 END)                    AS `Line below 1`
         FROM {lot_long}")
)

# ---------------------------------------------------------------------------
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
