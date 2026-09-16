# Table 4's baseline demographics.
#
# Four of the six are this package's own: RACE, ETHNICITY, STATE and BUS. Age
# is read off the cohort table so the two builds cannot disagree, and sex off
# the enrolment row that supplies the other four, with the cohort's value
# behind it for a patient no row covers.
#
# All six are timed "At index", and MEMBER_ENROLLMENT carries a new row each
# time anything about a member changes, so they are span-level attributes and
# "at index" means the span covering the index date. ENROL_ATTR_AT switches to
# the latest span for comparison. ../OPEN_QUESTIONS.md Q16.

# The US Census Bureau's four regions. Used when REGION_SOURCE=state_crosswalk,
# which is what the deployed extract needs: it carries STATE and no REGION.
# ../DATA_MAPPING.md section 4.
CENSUS_REGION <- list(
  Northeast = c("CT","ME","MA","NH","RI","VT","NJ","NY","PA"),
  Midwest   = c("IL","IN","MI","OH","WI","IA","KS","MN","MO","NE","ND","SD"),
  South     = c("DE","DC","FL","GA","MD","NC","SC","VA","WV","AL","KY","MS",
                "TN","AR","LA","OK","TX"),
  West      = c("AZ","CO","ID","MT","NV","NM","UT","WY","AK","CA","HI","OR","WA")
)

census_region_sql <- function(col = "e.STATE") {
  arms <- vapply(names(CENSUS_REGION), function(rg)
    sprintf("WHEN upper(trim(%s)) IN (%s) THEN '%s'", col,
            paste(sprintf("'%s'", CENSUS_REGION[[rg]]), collapse = ","), rg),
    character(1))
  paste0("CASE ", paste(arms, collapse = " "), " ELSE 'Unknown' END")
}

mod_demographics <- function(con, cfg, cohort) {
  region <- if (identical(cfg$region_source, "region_column"))
    "coalesce(nullif(trim(e.REGION), ''), 'Unknown')" else census_region_sql()

  # Which enrolment row supplies the attribute.
  #
  # s7.8.1: "assessed at the time of index date where possible. If data is
  # missing at index, data from the baseline period present nearest index will
  # be used." So under index_span the rows in play are those overlapping the
  # baseline window through the index day; the one covering the index wins,
  # and where none does - the span ended the day before therapy started, which
  # the 12-month enrolment test allows - the row ending nearest the index
  # stands in. Restricted to the covering row alone, that patient's race,
  # region and insurance were reported Unknown.
  covers <- "e.ELIGEFF <= p.INDEX_DATE AND e.ELIGEND >= p.INDEX_DATE"
  pick <- if (identical(cfg$enrol_attr_at, "index_span"))
    "AND e.ELIGEFF <= p.INDEX_DATE AND e.ELIGEND >= p.BASELINE_START" else ""
  # A TOTAL order. A member on two concurrent plans has two rows with the same
  # ELIGEFF covering the index, so ranking on ELIGEFF alone picks arbitrarily
  # and the attributes can differ between two runs of identical code.

  # Age, guarded on both ends. YRDOB is capped at 89 years, so a mean or median
  # age is right-censored (the bands are unaffected - the cap sits above the 75
  # cut-point). It is also 0 on some rows, which unguarded is an age of about
  # 2026 and lands those patients in the 75+ band. Anything outside a plausible
  # human range is Unknown.
  age_expr <- sprintf(
    "CASE WHEN cast(c.YRDOB as int) BETWEEN %d AND year(r.INDEX_DATE)
           AND year(r.INDEX_DATE) - cast(c.YRDOB as int) BETWEEN 0 AND 120
          THEN cast(year(r.INDEX_DATE) - cast(c.YRDOB as int) as int) END",
    1900L)

  # Under index_span the covering row comes first, then the rows nearest the
  # index by their end date; under latest_span the most recent row, wherever
  # it falls.
  ordering <- if (identical(cfg$enrol_attr_at, "index_span"))
    sprintf("CASE WHEN %s THEN 0 ELSE 1 END, e.ELIGEND DESC, e.ELIGEFF DESC, e.PAT_PLANID",
            covers)
    else "e.ELIGEND DESC, e.ELIGEFF DESC, e.PAT_PLANID"
  # Which row it was, on the row itself: the span covering the index, a
  # baseline span standing in for it, the latest span, or none at all.
  attr_source <- if (identical(cfg$enrol_attr_at, "index_span"))
    sprintf("CASE WHEN e.PATID IS NULL THEN 'none' WHEN %s THEN 'index_span'
                  ELSE 'baseline_nearest' END", covers)
    else "CASE WHEN e.PATID IS NULL THEN 'none' ELSE 'latest_span' END"

  # Age at the diagnosis as well as at the index. I2 is "aged >= 18 years at
  # the time of MM diagnosis according to calendar year", and the shells
  # tabulate age at diagnosis beside age at index; the same calendar-year
  # arithmetic, on the diagnosis date S_PERIODS carries.
  age_dx_expr <- sprintf(
    "CASE WHEN cast(c.YRDOB as int) BETWEEN %d AND year(r.DX_DT)
           AND year(r.DX_DT) - cast(c.YRDOB as int) BETWEEN 0 AND 120
          THEN cast(year(r.DX_DT) - cast(c.YRDOB as int) as int) END",
    1900L)

  prepare_table(con, wrk("S_DEMOGRAPHICS"),
    "PATID string, COHORT string, INDEX_DATE date,
     AGE_YEARS int, AGE_BAND string, AGE_GROUP string, SEX string, REGION string,
     RACE string, ETHNICITY string, INSURANCE_TYPE string,
     ENROL_ROW_FOUND int, ATTR_SOURCE string,
     AGE_AT_DX_YEARS int, AGE_AT_DX_BAND string", cohort$key)
  run_step(con, paste0("demographics_", cohort$key), sprintf("
    INSERT INTO %1$s
    WITH ranked AS (
      SELECT p.PATID, p.COHORT, p.INDEX_DATE, p.DX_DT,
             e.RACE, e.ETHNICITY, e.BUS, e.GDR_CD, %2$s AS REGION_VAL,
             %10$s AS ATTR_SOURCE,
             row_number() OVER (PARTITION BY p.PATID, p.COHORT ORDER BY %3$s)
               AS rn
      FROM %4$s p
      LEFT JOIN %5$s e ON cast(e.PATID as string) = p.PATID %6$s
      WHERE p.COHORT = '%7$s'
    )
    SELECT r.PATID, r.COHORT, r.INDEX_DATE,
           -- YRDOB is cast, not coerced. Spark would coerce a string in
           -- arithmetic, but relying on that puts the study's only age
           -- variable on an implicit rule that differs between engines and
           -- silently yields NULL on a stray space.
           --
           -- And YRDOB is CAPPED. The V9.0 dictionary gives it as the
           -- member year of birth capped at 89 years, changed on 14-04-2025
           -- from a cap at 90. So AGE_YEARS is right-censored: the bands are
           -- unaffected (the cap sits above 75) but a MEAN or MEDIAN age
           -- computed from this column is biased downward, and myeloma has a
           -- real tail above 89. Table 4 reports both; the continuous one
           -- carries that caveat. ../DATA_MAPPING.md section 4.
           %9$s AS AGE_YEARS,
           CASE WHEN %9$s IS NULL THEN 'Unknown'
                WHEN %9$s <  45 THEN '18-44'
                WHEN %9$s <  65 THEN '45-64'
                WHEN %9$s <  75 THEN '65-74'
                WHEN %9$s >= 75 THEN '75+'
                ELSE 'Unknown' END AS AGE_BAND,
           -- The protocol age STRATIFICATION, which is two groups and not
           -- the four descriptive bands above. VARIABLES.md stratification 2:
           -- age >= 75 against < 75, intended as a proxy for transplant
           -- status. The bands describe Table 1 age distribution; this is what
           -- a subgroup column asks for, and it is carried into the rate
           -- tables so a rate can be reported for each group. A rate is not
           -- the sum of its parts, so a grouping that spread < 75 over three
           -- rows could report no rate for it at all.
           CASE WHEN %9$s IS NULL THEN 'Unknown'
                WHEN %9$s >= 75 THEN '75+'
                ELSE '<75' END AS AGE_GROUP,
           -- s7.8.1 times every demographic 'at index', and GDR_CD is on
           -- the enrolment row like RACE and BUS, so it is read off the same
           -- row the other attributes come from. The cohort table's copy is
           -- the fallback: it is the value the cohort build read off SOME
           -- enrolment row, and a patient with no row in play would
           -- otherwise be Unknown for a sex the build had.
           CASE upper(trim(coalesce(r.GDR_CD, c.GDR_CD, 'U'))) WHEN 'M' THEN 'Male'
                WHEN 'F' THEN 'Female' ELSE 'Unknown' END AS SEX,
           coalesce(r.REGION_VAL, 'Unknown') AS REGION,
           -- The dictionary gives the reported categories as African American,
           -- Asian, Caucasian, Other/Unknown; Table 4 asks for Asian, Black,
           -- White, Unknown. The single-character code values are in the RACE
           -- lookup, which the dictionary does not include, so this maps what
           -- can be mapped and sends everything else to Unknown rather than
           -- guessing. ../OPEN_QUESTIONS.md Q10.
           CASE upper(trim(coalesce(r.RACE,'')))
                WHEN 'A' THEN 'Asian' WHEN 'B' THEN 'Black'
                WHEN 'W' THEN 'White' WHEN 'C' THEN 'White'
                ELSE 'Unknown' END AS RACE,
           CASE upper(trim(coalesce(r.ETHNICITY,'')))
                WHEN 'H' THEN 'Hispanic or Latino'
                WHEN 'N' THEN 'Not Hispanic or Latino'
                ELSE 'Unknown' END AS ETHNICITY,
           CASE upper(trim(coalesce(r.BUS,''))) WHEN 'MCR' THEN 'Medicare'
                WHEN 'COM' THEN 'Commercial Health Plan'
                ELSE 'Unknown' END AS INSURANCE_TYPE,
           CASE WHEN r.RACE IS NULL AND r.BUS IS NULL THEN 0 ELSE 1 END
             AS ENROL_ROW_FOUND,
           r.ATTR_SOURCE,
           %11$s AS AGE_AT_DX_YEARS,
           CASE WHEN %11$s IS NULL THEN 'Unknown'
                WHEN %11$s <  45 THEN '18-44'
                WHEN %11$s <  65 THEN '45-64'
                WHEN %11$s <  75 THEN '65-74'
                WHEN %11$s >= 75 THEN '75+'
                ELSE 'Unknown' END AS AGE_AT_DX_BAND
    FROM ranked r
    INNER JOIN %8$s c ON c.PATID = r.PATID
    WHERE r.rn = 1",
    wrk("S_DEMOGRAPHICS"), region, ordering, wrk("S_PERIODS"),
    cdm_src("member_enrollment"), pick, cohort$key, wrk("S_ELIGIBILITY"),
    age_expr, attr_source, age_dx_expr),
    qc = sprintf("SELECT count(*) AS n_rows,
                    sum(CASE WHEN RACE='Unknown' THEN 1 ELSE 0 END) AS n_race_unk,
                    sum(CASE WHEN ETHNICITY='Unknown' THEN 1 ELSE 0 END) AS n_eth_unk,
                    sum(CASE WHEN REGION='Unknown' THEN 1 ELSE 0 END) AS n_region_unk,
                    sum(1 - ENROL_ROW_FOUND) AS n_no_enrol_row
                  FROM %s WHERE COHORT = '%s'",
                 wrk("S_DEMOGRAPHICS"), cohort$key))

  # A high Unknown rate on RACE or ETHNICITY means the code values are not the
  # ones assumed above, not that the population is unknown. Said out loud,
  # because a silently-Unknown column reads as a finding.
  chk <- db_q(con, sprintf(
    "SELECT count(*) AS n, sum(CASE WHEN RACE='Unknown' THEN 1 ELSE 0 END) AS r,
            sum(CASE WHEN ETHNICITY='Unknown' THEN 1 ELSE 0 END) AS e
     FROM %s WHERE COHORT = '%s'", wrk("S_DEMOGRAPHICS"), cohort$key))
  if (chk$n[1] > 0) {
    watch <- c(RACE = "r", ETHNICITY = "e")
    for (i in seq_along(watch)) {
      frac <- chk[[watch[i]]][1] / chk$n[1]
      if (!is.na(frac) && frac > 0.5)
        log_msg("  WARNING: ", names(watch)[i], " is Unknown for ",
                round(100 * frac), "% of ", cohort$key,
                ". Profile the column before reporting it - the code values ",
                "are not published in the CDM dictionary. ",
                "../OPEN_QUESTIONS.md Q10.")
    }
  }
}
