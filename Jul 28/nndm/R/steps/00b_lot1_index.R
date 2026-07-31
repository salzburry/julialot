# The 1L index date, from claims.
#
# Not a port. Protocol Rev Round 2 S6.2.1.1 defines it directly:
#
#   Eligible 1L treatment: Received an eligible or expected treatment for MM on
#   or after MM diagnosis (other than belantamab), occurring on or after
#   01 Jan 2017 (eligible treatment period).
#   The 1L cohort index date is the date of the first claim for MM treatment
#   within the identification period.
#
# apr_30_2026 took it from LOT_LONG instead - the start of line 1 as the LOT
# algorithm computes it. That is a different thing: LOT_LONG only exists for
# patients who already passed the parent build's criteria, and the line start
# is an output of the line-building rules rather than a claim date. Reading it
# also made this build depend on a LOT run, when the plan is the reverse - the
# LOT algorithm runs over the cohort this build produces.
#
# The scan is the same four sources as the prior-therapy scan, against the same
# codelist view, so "MM treatment" means one thing in this package. That view
# already has steroids dropped: a steroid claim alone is supportive care, not
# the start of a line.

# Belantamab rows of the MMA code list. The 1L treatment must be "other than
# belantamab", so these are excluded from the scan that sets the index date -
# and exclusion 4 removes the patient outright, from any line.
build_ndmm_belantamab_codes <- function(con) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_BELANTAMAB_CODES} AS
    SELECT DISTINCT code_type, code
    FROM {NDMM_MMA_CODELIST}
    WHERE upper(trim(med_abbr)) LIKE '{NDMM_BELANTAMAB_ABBR}'
  "))
  # The abbreviation is how belantamab is recognised on the code list, and this
  # package cannot see the production CSV. If it matches nothing, the exclusion
  # the whole study turns on silently does nothing, and belantamab claims would
  # also be allowed to set the index date. Stop and say so rather than build a
  # cohort on an assumption that turned out false.
  n <- tryCatch(as.integer(db_q(con, glue(
    "SELECT count(*) AS n FROM {NDMM_BELANTAMAB_CODES}"))$n),
    error = function(e) NA_integer_)
  if (is.na(n) || n == 0)
    stop("No row of cl_mma_codelist.csv has CL_MED_ABBR like '",
         NDMM_BELANTAMAB_ABBR, "'.\nThat is how this build recognises ",
         "belantamab, and without it the exclusion in S6.2.1.2 does nothing ",
         "and belantamab claims could set the 1L index date. Run 'SELECT ",
         "DISTINCT med_abbr FROM ", NDMM_MMA_CODELIST, "' on the warehouse ",
         "and set NDMM_BELANTAMAB_ABBR to the abbreviation it uses.",
         call. = FALSE)
  log_msg("  Belantamab code list: ", n, " codes matched '",
          NDMM_BELANTAMAB_ABBR, "'")
  invisible(n)
}

# The first eligible MM treatment claim on or after the MM diagnosis and on or
# after the eligible-treatment cutoff. That date is the NDMM index.
build_ndmm_lot1_index <- function(con, medical_tbl, rx_tbl) {
  # Every branch is scoped to the base cohort, dated on or after that patient's
  # own diagnosis, and inside the eligible-treatment period. Belantamab is left
  # out by the anti-join: S6.2.1.1 says the eligible 1L treatment is one "other
  # than belantamab", so a belantamab claim cannot be what sets the index.
  arm <- function(tbl, dt, match_sql) glue("
      SELECT cast(t.PATID as string) AS PATID, cast(t.{dt} as date) AS tx_dt
      FROM {tbl} t
      INNER JOIN {NDMM_BASE_COHORT} b ON cast(t.PATID as string) = b.PATID
      INNER JOIN {NDMM_MMA_CODELIST} c ON {match_sql}
      LEFT JOIN {NDMM_BELANTAMAB_CODES} bl
             ON bl.code_type = c.code_type AND bl.code = c.code
      WHERE bl.code IS NULL
        AND cast(t.{dt} as date) >= b.MM_DX_DT
        AND cast(t.{dt} as date) >= date('{NDMM_LOT1_FROM}')
        AND cast(t.{dt} as date) <= date('{cfg$study_end}')")
  proc_match <- "c.code_type IN ('HCPCS','CPT')
       AND upper(regexp_replace(coalesce(cast(t.PROC_CD as string),''), '[^A-Za-z0-9]', '')) = c.code
       AND regexp_replace(coalesce(cast(t.PROC_CD as string),''), '[^A-Za-z0-9]', '') <> ''"
  bill_match <- "c.code_type = 'HCPCS'
       AND upper(regexp_replace(coalesce(cast(t.BILL_PROC_CD as string),''), '[^A-Za-z0-9]', '')) = c.code
       AND regexp_replace(coalesce(cast(t.BILL_PROC_CD as string),''), '[^A-Za-z0-9]', '') <> ''"
  ndc_match <- "c.code_type = 'NDC'
       AND lpad(regexp_replace(coalesce(cast(t.NDC as string),''), '[^0-9]', ''), 11, '0')
         = lpad(regexp_replace(c.code, '[^0-9]', ''), 11, '0')
       AND regexp_replace(coalesce(cast(t.NDC as string),''), '[^0-9]', '') <> ''"
  db_exec(con, paste0(glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_LOT1_STARTS} AS
    WITH tx AS ("),
    arm(medical_tbl, "FST_DT",  proc_match), "\n      UNION ALL\n",
    arm(medical_tbl, "FST_DT",  bill_match), "\n      UNION ALL\n",
    arm(medical_tbl, "FST_DT",  ndc_match),  "\n      UNION ALL\n",
    arm(rx_tbl,      "FILL_DT", ndc_match),
    glue("
    )
    SELECT PATID, min(tx_dt) AS LOT1_START_DT
    FROM tx
    GROUP BY PATID")))
}

# MAP_STACKED is a LOT-build table this package no longer reads. The ported
# flags step takes its belantamab source as a parameter and looks for
# MAP_MED_TYPE LIKE 'BEL%', so this view answers in that shape from raw claims:
# one row per patient with any belantamab claim, at any time, in any line.
build_ndmm_belantamab_patids <- function(con, medical_tbl, rx_tbl) {
  arm <- function(tbl, dt, col, numeric_only) glue("
      SELECT DISTINCT cast(t.PATID as string) AS PATID
      FROM {tbl} t
      INNER JOIN {NDMM_BELANTAMAB_CODES} c
        ON {if (numeric_only)
              paste0(\"lpad(regexp_replace(coalesce(cast(t.\", col, \" as string),''), '[^0-9]', ''), 11, '0') = lpad(regexp_replace(c.code, '[^0-9]', ''), 11, '0')\",
                     \" AND regexp_replace(coalesce(cast(t.\", col, \" as string),''), '[^0-9]', '') <> ''\")
            else
              paste0(\"upper(regexp_replace(coalesce(cast(t.\", col, \" as string),''), '[^A-Za-z0-9]', '')) = c.code\",
                     \" AND regexp_replace(coalesce(cast(t.\", col, \" as string),''), '[^A-Za-z0-9]', '') <> ''\")}
      WHERE cast(t.{dt} as date) <= date('{cfg$study_end}')")
  db_exec(con, paste0(glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_BELANTAMAB_PATIDS} AS
    WITH hits AS ("),
    arm(medical_tbl, "FST_DT",  "PROC_CD",      FALSE), "\n      UNION\n",
    arm(medical_tbl, "FST_DT",  "BILL_PROC_CD", FALSE), "\n      UNION\n",
    arm(medical_tbl, "FST_DT",  "NDC",          TRUE),  "\n      UNION\n",
    arm(rx_tbl,      "FILL_DT", "NDC",          TRUE),
    glue("
    )
    SELECT PATID, 'BEL' AS MAP_MED_TYPE FROM hits")))
}
