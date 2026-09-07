# Table 4's baseline demographics.
#
# Four of the six are new to this repo: nothing in Jul 28/ reads RACE,
# ETHNICITY, STATE or BUS today. The two that exist - age and sex - are read
# off the cohort table so the two builds cannot disagree.
#
# Every one of these is timed "At index", and MEMBER_ENROLLMENT carries a new
# row each time anything about a member changes, so they are span-level
# attributes and "at index" means the span covering the index date. ENROL_ATTR_AT
# switches to the latest span for comparison. ../OPEN_QUESTIONS.md Q16.

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
  pick <- if (identical(cfg$enrol_attr_at, "index_span"))
    "AND e.ELIGEFF <= p.INDEX_DATE AND e.ELIGEND >= p.INDEX_DATE" else ""
  ordering <- if (identical(cfg$enrol_attr_at, "index_span"))
    "e.ELIGEFF DESC" else "e.ELIGEND DESC"

  prepare_table(con, wrk("S_DEMOGRAPHICS"),
    "PATID string, COHORT string, INDEX_DATE date,
     AGE_YEARS int, AGE_BAND string, SEX string, REGION string,
     RACE string, ETHNICITY string, INSURANCE_TYPE string,
     ENROL_ROW_FOUND int", cohort$key)
  run_step(con, paste0("demographics_", cohort$key), sprintf("
    INSERT INTO %1$s
    WITH ranked AS (
      SELECT p.PATID, p.COHORT, p.INDEX_DATE,
             e.RACE, e.ETHNICITY, e.BUS, %2$s AS REGION_VAL,
             row_number() OVER (PARTITION BY p.PATID, p.COHORT ORDER BY %3$s)
               AS rn
      FROM %4$s p
      LEFT JOIN %5$s e ON cast(e.PATID as string) = p.PATID %6$s
      WHERE p.COHORT = '%7$s'
    )
    SELECT r.PATID, r.COHORT, r.INDEX_DATE,
           -- YRDOB is cast, not coerced. The CDM stores it as a character
           -- column; Spark would coerce a string in arithmetic, but relying on
           -- that puts the study's only age variable on an implicit rule that
           -- differs between engines and silently yields NULL on a stray
           -- space. s7.8.1: age is the index year minus the birth year.
           cast(year(r.INDEX_DATE) - cast(c.YRDOB as int) as int) AS AGE_YEARS,
           CASE WHEN year(r.INDEX_DATE) - cast(c.YRDOB as int) <  45 THEN '18-44'
                WHEN year(r.INDEX_DATE) - cast(c.YRDOB as int) <  65 THEN '45-64'
                WHEN year(r.INDEX_DATE) - cast(c.YRDOB as int) <  75 THEN '65-74'
                WHEN year(r.INDEX_DATE) - cast(c.YRDOB as int) >= 75 THEN '75+'
                ELSE 'Unknown' END AS AGE_BAND,
           CASE upper(coalesce(c.GDR_CD,'U')) WHEN 'M' THEN 'Male'
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
             AS ENROL_ROW_FOUND
    FROM ranked r
    INNER JOIN %8$s c ON c.PATID = r.PATID
    WHERE r.rn = 1",
    wrk("S_DEMOGRAPHICS"), region, ordering, wrk("S_PERIODS"),
    cdm_src("member_enrollment"), pick, cohort$key, cfg$input_cohort_table),
    qc = sprintf("SELECT count(*) AS n_rows,
                    sum(CASE WHEN RACE='Unknown' THEN 1 ELSE 0 END) AS n_race_unk,
                    sum(CASE WHEN ETHNICITY='Unknown' THEN 1 ELSE 0 END) AS n_eth_unk,
                    sum(CASE WHEN REGION='Unknown' THEN 1 ELSE 0 END) AS n_region_unk,
                    sum(1 - ENROL_ROW_FOUND) AS n_no_enrol_row
                  FROM %s WHERE COHORT = '%s'",
                 wrk("S_DEMOGRAPHICS"), cohort$key))

  # A high Unknown rate on RACE or ETHNICITY means the code values are not the
  # ones assumed above, not that the population is unknown. Said out loud
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
