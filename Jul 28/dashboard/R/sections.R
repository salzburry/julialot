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
#   {lot_long}      <prefix>LOT_LONG        every line the build produced
#   {lot_final}     <prefix>LOT_LONG_FINAL  after the line criteria
#   {patients}      <prefix>LOT_PATIENT_INPUT  the cohort as LOT read it
#   {attrition}     <cohort_prefix>NDMM_ATTRITION, when there is one
#   {run_meta}      <prefix>LOT_RUN_METADATA
#   {cohort}        the cohort table the run was pointed at

# How a section's rows are drawn. Deliberately few: a dashboard nobody can read
# is not better than a table, and every one of these renders without a
# JavaScript library or a plotting package - see render.R.
RENDER_TYPES <- c("table", "kpi", "bar")

# Which patients the journey section shows. Examples, not a sample: a random
# three patients are three LOT1-only patients, because most patients are. Each
# category names a shape somebody wants to see the algorithm handle, and the
# section reports the ones that matched nobody - so a category missing from the
# output reads as "none in this cohort" rather than "nobody thought to check".
#
# Predicates are over the per-patient columns the section derives below:
#   max_lot  lot1_start_type  lot1_end_reason
#   any_cart_init  any_sct_auto  any_sct_allo
JOURNEY_CATEGORIES <- list(
  list(label = "LOT1 to LOT2 progressor, drug-started",
       pred  = "max_lot >= 2 AND lot1_start_type = 'MED'"),
  list(label = "LOT1 only, discontinued",
       pred  = "max_lot = 1 AND lot1_end_reason = 'DISCONTINUATION'"),
  list(label = "Reached LOT4 or beyond",
       pred  = "max_lot >= 4"),
  list(label = "CAR-T",             pred = "any_cart_init = 1"),
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
             max(CASE WHEN LOT_BASE_END_REASON = 'CART_INIT' THEN 1 ELSE 0 END) AS any_cart_init,
             max(CASE WHEN LOT_START_TYPE = 'SCT_AUTO' THEN 1 ELSE 0 END)       AS any_sct_auto,
             max(CASE WHEN LOT_START_TYPE = 'SCT_ALLO' THEN 1 ELSE 0 END)       AS any_sct_allo
      FROM {lot_long}
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
    INNER JOIN {lot_long} l ON cast(l.PATID as string) = p.PATID
    WHERE p.rn <= {journeys_per_category}
    ORDER BY `Example`, `Patient`, `Line`")
}

DASHBOARD_SECTIONS <- list(

  # ---- OVERVIEW ------------------------------------------------------------

  list(name = "run_provenance", tab = "Overview",
       label = "What produced these numbers",
       needs = "run_meta", render = "table",
       # One row. Which window, which code, which criteria - so a dashboard
       # filed away without its log still says what it describes.
       sql = "
         SELECT RUN_ID, STUDY_START, STUDY_END, CODE_MD5,
                LINE_CRITERIA_APPLIED, LOT_LONG_BY_LINE
         FROM {run_meta}"),

  list(name = "headline", tab = "Overview",
       label = "Cohort and lines",
       needs = c("patients", "lot_long", "lot_final"), render = "kpi",
       sql = "
         SELECT (SELECT count(*) FROM {patients})                     AS `Patients`,
                (SELECT count(*) FROM {lot_long})                     AS `Lines built`,
                (SELECT count(DISTINCT PATID) FROM {lot_long})        AS `Patients with a line`,
                (SELECT count(*) FROM {lot_final})                    AS `Lines after criteria`,
                (SELECT count(DISTINCT PATID) FROM {lot_final})       AS `Patients after criteria`"),

  list(name = "attrition", tab = "Overview",
       label = "Cohort attrition",
       needs = "attrition", render = "bar",
       # The funnel the cohort build wrote, read rather than recomputed - two
       # copies of an attrition is how the funnel and the cohort stop agreeing.
       sql = "
         SELECT STEP_LABEL AS label, N_PATIENTS AS n
         FROM {attrition} ORDER BY STEP_NUM"),

  # ---- COHORT --------------------------------------------------------------

  list(name = "demographics", tab = "Cohort",
       label = "Age at index and sex",
       needs = "patients", render = "table",
       sql = "
         SELECT CASE WHEN AGE_INDEX_YR < 65 THEN '18-64'
                     WHEN AGE_INDEX_YR < 75 THEN '65-74'
                     WHEN AGE_INDEX_YR < 85 THEN '75-84'
                     ELSE '85+' END                       AS `Age band`,
                upper(coalesce(GDR_CD, 'U'))              AS `Sex`,
                count(*)                                  AS `Patients`
         FROM {patients}
         GROUP BY 1, 2 ORDER BY 1, 2"),

  list(name = "age_stats", tab = "Cohort",
       label = "Age at index, distribution",
       needs = "patients", render = "table",
       sql = "
         SELECT count(*)                                              AS `Patients`,
                round(avg(AGE_INDEX_YR), 1)                           AS `Mean`,
                percentile_approx(AGE_INDEX_YR, 0.25)                 AS `P25`,
                percentile_approx(AGE_INDEX_YR, 0.5)                  AS `Median`,
                percentile_approx(AGE_INDEX_YR, 0.75)                 AS `P75`,
                min(AGE_INDEX_YR)                                     AS `Min`,
                max(AGE_INDEX_YR)                                     AS `Max`
         FROM {patients}"),

  list(name = "index_by_year", tab = "Cohort",
       label = "Index dates by year",
       needs = "patients", render = "bar",
       sql = "
         SELECT cast(year(INDEX_DATE) as string) AS label, count(*) AS n
         FROM {patients} GROUP BY 1 ORDER BY 1"),

  list(name = "followup", tab = "Cohort",
       label = "Follow-up and death",
       needs = "patients", render = "table",
       sql = "
         SELECT count(*)                                              AS `Patients`,
                sum(CASE WHEN DEATH_DT IS NOT NULL THEN 1 ELSE 0 END) AS `Died in window`,
                round(avg(FU_DAYS), 1)                                AS `Mean FU days`,
                percentile_approx(FU_DAYS, 0.5)                       AS `Median FU days`,
                percentile_approx(FU_DAYS, 0.25)                      AS `P25`,
                percentile_approx(FU_DAYS, 0.75)                      AS `P75`
         FROM {patients}"),

  # ---- LINES ---------------------------------------------------------------

  list(name = "lines_per_patient", tab = "Lines",
       label = "Highest line reached",
       needs = "lot_long", render = "bar",
       sql = "
         SELECT concat('LOT', cast(hi as string)) AS label, count(*) AS n
         FROM (SELECT PATID, max(LOT_NUM) AS hi FROM {lot_long} GROUP BY PATID)
         GROUP BY 1 ORDER BY 1"),

  list(name = "start_type", tab = "Lines",
       label = "How each line started",
       needs = "lot_long", render = "table",
       sql = "
         SELECT LOT_NUM AS `Line`, LOT_START_TYPE AS `Start type`,
                count(*) AS `Lines`
         FROM {lot_long} GROUP BY 1, 2 ORDER BY 1, 2"),

  list(name = "end_reason", tab = "Lines",
       label = "Why each line ended",
       needs = "lot_long", render = "table",
       sql = "
         SELECT LOT_NUM AS `Line`, LOT_BASE_END_REASON AS `End reason`,
                count(*) AS `Lines`
         FROM {lot_long} GROUP BY 1, 2 ORDER BY 1, 2"),

  list(name = "line_length", tab = "Lines",
       label = "Line length in days",
       needs = "lot_long", render = "table",
       sql = "
         SELECT LOT_NUM                                               AS `Line`,
                count(*)                                              AS `Lines`,
                percentile_approx(datediff(LOT_BASE_END_DT, LOT_START_DT), 0.25) AS `P25`,
                percentile_approx(datediff(LOT_BASE_END_DT, LOT_START_DT), 0.5)  AS `Median`,
                percentile_approx(datediff(LOT_BASE_END_DT, LOT_START_DT), 0.75) AS `P75`
         FROM {lot_long} GROUP BY 1 ORDER BY 1"),

  list(name = "med_count", tab = "Lines",
       label = "Drugs in the base regimen",
       needs = "lot_long", render = "table",
       sql = "
         SELECT LOT_NUM AS `Line`, LOT_MED_CNT AS `Drugs`, count(*) AS `Lines`
         FROM {lot_long} GROUP BY 1, 2 ORDER BY 1, 2"),

  # ---- REGIMENS ------------------------------------------------------------

  list(name = "top_regimens", tab = "Regimens",
       label = "Most common base regimens, by line",
       needs = "lot_long", render = "table",
       # Ranked within line, so line 1's long tail does not crowd out line 4.
       sql = "
         SELECT `Line`, `Regimen`, `Patients` FROM (
           SELECT LOT_NUM AS `Line`, LOT_BASE_MEDS AS `Regimen`,
                  count(DISTINCT PATID) AS `Patients`,
                  row_number() OVER (PARTITION BY LOT_NUM
                                     ORDER BY count(DISTINCT PATID) DESC) AS rn
           FROM {lot_long} GROUP BY LOT_NUM, LOT_BASE_MEDS)
         WHERE rn <= {top_n} ORDER BY `Line`, `Patients` DESC"),

  list(name = "first_added_med", tab = "Regimens",
       label = "First drug added after the base regimen",
       needs = "lot_long", render = "table",
       sql = "
         SELECT `Line`, `Added`, `Lines` FROM (
           SELECT LOT_NUM AS `Line`,
                  coalesce(LOT_BASE_1ST_ADD_MED, '(none)') AS `Added`,
                  count(*) AS `Lines`,
                  row_number() OVER (PARTITION BY LOT_NUM
                                     ORDER BY count(*) DESC) AS rn
           FROM {lot_long} GROUP BY LOT_NUM, LOT_BASE_1ST_ADD_MED)
         WHERE rn <= {top_n} ORDER BY `Line`, `Lines` DESC"),

  # ---- TRANSPLANT ----------------------------------------------------------

  list(name = "sct", tab = "Transplant",
       label = "Lines that are a transplant or CAR-T",
       needs = "lot_long", render = "table",
       sql = "
         SELECT LOT_NUM                                                AS `Line`,
                sum(CASE WHEN LOT_ALLO_LOT_FLG = 1 THEN 1 ELSE 0 END)  AS `ALLO`,
                sum(CASE WHEN LOT_CART_LOT_FLG = 1 THEN 1 ELSE 0 END)  AS `CAR-T`,
                sum(CASE WHEN LOT_START_TYPE = 'SCT_AUTO' THEN 1 ELSE 0 END) AS `AUTO start`,
                count(*)                                               AS `Lines`
         FROM {lot_long} GROUP BY 1 ORDER BY 1"),

  # ---- PATIENT EXAMPLES ----------------------------------------------------

  list(name = "patient_journeys", tab = "Patient examples",
       label = "Line-by-line journeys, a few patients per scenario",
       needs = "lot_long", render = "table",
       sql = .journey_sql()),

  list(name = "journey_coverage", tab = "Patient examples",
       label = "Scenarios, and how many patients each one has",
       needs = "lot_long", render = "bar",
       # The denominator behind the gallery. A scenario with no patients is the
       # interesting case - it means either the cohort has none or a rule is not
       # firing - and without this the reader cannot tell which of the two the
       # missing panel above is.
       sql = paste0("
         WITH pat AS (
           SELECT cast(PATID as string) AS PATID,
                  max(LOT_NUM)                                            AS max_lot,
                  max(CASE WHEN LOT_NUM = 1 THEN LOT_START_TYPE END)      AS lot1_start_type,
                  max(CASE WHEN LOT_NUM = 1 THEN LOT_BASE_END_REASON END) AS lot1_end_reason,
                  max(CASE WHEN LOT_BASE_END_REASON = 'CART_INIT' THEN 1 ELSE 0 END) AS any_cart_init,
                  max(CASE WHEN LOT_START_TYPE = 'SCT_AUTO' THEN 1 ELSE 0 END)       AS any_sct_auto,
                  max(CASE WHEN LOT_START_TYPE = 'SCT_ALLO' THEN 1 ELSE 0 END)       AS any_sct_allo
           FROM {lot_long} GROUP BY PATID
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
