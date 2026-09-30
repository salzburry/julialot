# The MM-diagnosed adult population this cohort is drawn from, from MDV.
#
# Two criteria only: a qualifying MM diagnosis, and age 18 or over at that
# diagnosis. Lookback, prior therapy and the exclusions are applied at the 1L
# start instead, as in the Optum build.
#
# What changes on MDV (DECISIONS.md, "MDV"):
#   - A diagnosis is dated to the first day of its claim month (datamonth), the
#     way the OC rules date one. MDV does not date a diagnosis to the day.
#   - Only confirmed diagnoses count (utagaiflg), and by default only ones MDV
#     flags as cancer (cancerflg) - both OC base-population rules.
#   - Inpatient is the claim's care setting (nyugaikbn), with the FF1 episode
#     conditions available under NDMM_MDV_IP_RULE.
#   - "Two outpatient claims on different days within 90 days" is two
#     outpatient claim months at most three months apart.

# The staged MDV sources this build reads more than once. Views, not copies:
# the diagnosis table is the whole warehouse's, and every reader filters it.
build_ndmm_mdv_views <- function(con) {
  db_exec(con, paste0("CREATE OR REPLACE TEMPORARY VIEW ", NDMM_DX, " AS\n",
                      mdv_dx_select()))
  db_exec(con, paste0("CREATE OR REPLACE TEMPORARY VIEW ", NDMM_FF1, " AS\n",
                      mdv_ff1_select()))
}

# Diagnosis codes. DISTINCT because a repeated CSV row would duplicate every
# record it matches. strict marks C90.0x, which the inpatient path requires; an
# MDV disease code is graded by the ICD-10 code the list maps it to.
build_ndmm_mm_dx_codes <- function(con) {
  src <- load_codelist_csv("mm_dx.csv", c("code_type", "code", "icd10"))
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_MM_DX_CODES} AS
    SELECT DISTINCT code_type, code, icd10,
           CASE WHEN icd10 LIKE 'C900%' THEN 1 ELSE 0 END AS strict
    FROM (
      -- Each column normalised before the fallback, so a blank or
      -- punctuation-only icd10 is NULL and an ICD10 row falls back to its own
      -- code. Coalescing first kept the blank, which graded the row not strict.
      SELECT upper(trim(code_type)) AS code_type,
             {mdv_code_sql('code')} AS code,
             coalesce({mdv_code_sql('icd10')},
                      CASE WHEN upper(trim(code_type)) = 'ICD10'
                           THEN {mdv_code_sql('code')} END) AS icd10
      FROM {src}
      WHERE {mdv_code_sql('code')} IS NOT NULL
    ) c
  "))
}

# The diagnosis records matching a disease code list, as a subquery: every
# column of the staged record (NDMM_DX) plus the code-list columns in cols.
#
# One equi-join per code type - the MDV disease code, and the ICD-10 code
# where the delivery carries one (check_code_types() has refused ICD10 rows
# where it does not) - rather than one join ON a OR b. Spark cannot hash-join
# on a disjunction, so that form tests every diagnosis in the warehouse against
# every code on the list; the other-cancer list alone is some 1,600 codes.
# A record matching both arms comes back twice, and every reader either takes
# DISTINCT or aggregates.
ndmm_dx_join <- function(codes, cols, where = "1 = 1") {
  arm <- function(type, dcol) glue("
      SELECT d.*, {cols}
      FROM {NDMM_DX} d
      INNER JOIN {codes} c ON c.code_type = '{type}' AND d.{dcol} = c.code
      WHERE {where}")
  arms <- c(arm("DISEASECODE", "DX_CODE"),
            if (nzchar(MDV_COLS$icd10)) arm("ICD10", "ICD10"))
  paste0("(", paste(arms, collapse = "\n      UNION ALL\n"), "\n    )")
}

# Every MM diagnosis record over the study period, suspected ones included,
# carrying what each reading of criterion 1 asks of it. One scan serves the
# rule and NDMM_MM_DX_RULES, which prices the readings not taken; the rule
# itself filters on confirmed, cancer and the configured inpatient column.
#
#   inpt_none       nyugaikbn is the inpatient value
#   inpt_ff1        and fromdate falls inside one of the patient's FF1 episodes
#   inpt_ff1_chemo  and that episode is a first cancer given chemotherapy
build_ndmm_mm_dx_events <- function(con) {
  in_period <- glue("d.DX_MONTH BETWEEN date('{NDMM_STUDY_START}') AND date('{cfg$study_end}')")
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_MM_DX_EVENTS} AS
    WITH dx AS (
      SELECT DISTINCT m.PATID, m.DX_MONTH AS svc_dt, m.FROM_DT, m.CONFIRMED,
             m.CANCER, m.INPT, m.OUTPT, m.strict
      FROM {ndmm_dx_join(NDMM_MM_DX_CODES, 'c.strict', in_period)} m
    )
    SELECT dx.PATID, dx.svc_dt,
           max(dx.CONFIRMED) AS confirmed,
           max(dx.CANCER)    AS cancer,
           max(dx.strict)    AS mm_dx_strict_flg,
           max(dx.INPT)      AS inpt_none,
           max(CASE WHEN dx.INPT = 1 AND f.PATID IS NOT NULL THEN 1 ELSE 0 END)
                             AS inpt_ff1,
           max(CASE WHEN dx.INPT = 1 AND f.CANCERFIRST = 1 AND f.CHEMO = 1
                    THEN 1 ELSE 0 END) AS inpt_ff1_chemo,
           max(dx.OUTPT)     AS outpatient_flg
    FROM dx
    LEFT JOIN {NDMM_FF1} f
           ON f.PATID = dx.PATID
          AND dx.FROM_DT BETWEEN f.FF1_START_DT AND f.FF1_END_DT
    -- Grouped per record, not per month: a month's confirmed record and its
    -- suspected one stay apart, or max() would lend one's flags to the other.
    GROUP BY dx.PATID, dx.svc_dt, dx.FROM_DT, dx.CONFIRMED, dx.CANCER,
             dx.INPT, dx.OUTPT, dx.strict
  "))
}

# The inpatient column the configured rule reads.
ndmm_ip_col <- function(rule = NDMM_MDV_IP_RULE)
  switch(rule, none = "inpt_none", ff1 = "inpt_ff1", ff1_chemo = "inpt_ff1_chemo",
         stop("NDMM_MDV_IP_RULE='", rule, "' is not a setting. Use ",
              paste(NDMM_MDV_IP_RULES, collapse = ", "), ".", call. = FALSE))

# Criterion 1 as a query, so the rule and each priced alternative are the same
# SQL with one thing changed rather than copies that can drift.
#
# Every candidate date: one inpatient record carrying a strict code, or two
# outpatient claim months at most NDMM_OUTPATIENT_WINDOW_MONTHS apart. Months
# are distinct by construction, so "on different days" is "in different
# months". The candidate date is the earlier month, as the Optum rule takes the
# earlier claim.
#
# tx_link, when set, is the OC outpatient rule's treatment link: an outpatient
# month counts only if an MM therapy act falls within that many days of it.
ndmm_mm_qualifying_sql <- function(ip_col = ndmm_ip_col(), confirmed_only = TRUE,
                                   need_cancer = NDMM_MDV_REQUIRE_CANCERFLG,
                                   tx_link = NA_integer_) {
  where <- c("1 = 1", if (confirmed_only) "confirmed = 1",
             if (need_cancer) "cancer = 1")
  # " " outside the glue, which trims a leading newline.
  link <- if (is.na(tx_link)) "" else paste0(" ", glue("
        AND EXISTS (SELECT 1 FROM {NDMM_MM_TX} t
                    WHERE t.PATID = ev.PATID
                      AND abs(datediff(t.tx_dt, ev.svc_dt)) <= {tx_link})"))
  glue("
    WITH ev AS (
      SELECT * FROM {NDMM_MM_DX_EVENTS} WHERE {paste(where, collapse = ' AND ')}
    ),
    inpatient_potential AS (
      SELECT DISTINCT PATID, svc_dt AS potential_index
      FROM ev
      WHERE {ip_col} = 1 AND mm_dx_strict_flg = 1
    ),
    distinct_months AS (
      SELECT DISTINCT ev.PATID, ev.svc_dt
      FROM ev
      WHERE ev.outpatient_flg = 1{link}
    ),
    with_next AS (
      SELECT PATID, svc_dt,
             lead(svc_dt) OVER (PARTITION BY PATID ORDER BY svc_dt) AS next_dt
      FROM distinct_months
    ),
    outpatient_potential AS (
      SELECT DISTINCT PATID, svc_dt AS potential_index
      FROM with_next
      WHERE next_dt IS NOT NULL
        AND {mdv_month_diff_sql('next_dt', 'svc_dt')} <= {NDMM_OUTPATIENT_WINDOW_MONTHS}
    ),
    all_potential AS (
      SELECT PATID, potential_index, 1 AS inpt_qual, 0 AS outpt_qual
      FROM inpatient_potential
      UNION ALL
      SELECT PATID, potential_index, 0 AS inpt_qual, 1 AS outpt_qual
      FROM outpatient_potential
    )
    SELECT PATID,
           potential_index AS MM_DX_DT,
           max(inpt_qual) AS inpt_qual,
           max(outpt_qual) AS outpt_qual,
           CASE WHEN max(inpt_qual) = 1 THEN 'INPATIENT'
                ELSE 'OUTPATIENT_2IN{NDMM_OUTPATIENT_WINDOW_MONTHS}M' END AS index_source
    FROM all_potential
    GROUP BY PATID, potential_index")
}

# Every candidate diagnosis date, as configured. build_ndmm_base_cohort() picks
# the earliest and only then applies age. So a patient who is 17 at their
# earliest qualifying date is dropped - not advanced to a later date at which
# they are 18.
build_ndmm_mm_qualifying <- function(con) {
  db_exec(con, paste0("CREATE OR REPLACE TEMPORARY VIEW ", NDMM_MM_QUALIFYING,
                      " AS\n", ndmm_mm_qualifying_sql()))
}

# Sex and birth year, one row per patient: a usable birth year first, then a
# known sex, then the values themselves, so the same input always gives the
# same patient. MDV's patient table is one row per patient per hospital, and
# the patient key is the hospital's, so this is usually one row already.
#
# Death is a DPC Form 1 discharge whose outcome is a death code - the one place
# MDV records a death - dated to that discharge. Only in-hospital deaths at a
# contributing hospital are seen, so an ENDDATE that is not a death is not
# evidence the patient lived. With no outcome column configured, nobody dies.
build_ndmm_demographics <- function(con) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_MEMBER_DEMO} AS
    WITH p AS ({mdv_patient_select()}
    ),
    ranked AS (
      SELECT PATID, GDR_CD, YRDOB,
             row_number() OVER (PARTITION BY PATID
               ORDER BY CASE WHEN YRDOB IS NOT NULL THEN 0 ELSE 1 END,
                        CASE WHEN GDR_CD <> 'U' THEN 0 ELSE 1 END,
                        YRDOB, GDR_CD) AS rn
      FROM p
    )
    SELECT PATID, GDR_CD, YRDOB FROM ranked WHERE rn = 1
  "))
  # The FF1 discharge date as recorded. The Optum build clamped a death before
  # the diagnosis to the diagnosis; on MDV the death is an exact discharge
  # date, so moving it would publish a date no record carries. A death before
  # the 1L start fails criterion 5 instead (06_flags.R), and every act after a
  # recorded death is listed in NDMM_DEATH_CONFLICTS (DECISIONS M12).
  #
  # With more than one death-coded discharge, the EARLIEST is the death. A
  # patient dies once, so a later death-coded discharge is itself a record
  # after the death - a conflict NDMM_DEATH_CONFLICTS lists with every date -
  # and not a later death. Taking the latest let the later record hide the
  # earlier one: dead on 12 June, treated on 15 June, "dead" again on 20 June
  # read as alive at the index and no conflict at all.
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_DEATH_DT} AS
    WITH died AS (
      SELECT PATID, min(FF1_END_DT) AS death_raw
      FROM {NDMM_FF1}
      WHERE DIED = 1 AND FF1_END_DT IS NOT NULL
      GROUP BY PATID
    )
    SELECT q.PATID, q.MM_DX_DT, d.death_raw AS DEATH_DT
    FROM {NDMM_MM_QUALIFYING} q
    LEFT JOIN died d ON d.PATID = q.PATID
  "))
}

# The base population: each patient's EARLIEST qualifying diagnosis, and then
# age >= 18 in that date's calendar year. Age drops the patient and never moves
# the date, because MM_DX_DT gates the 1L index. The ranking cannot see age at
# all: it runs on NDMM_MM_QUALIFYING alone, and the age test comes after, on
# the one surviving row, where it can only drop a patient.
build_ndmm_base_cohort <- function(con) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_BASE_COHORT} AS
    WITH ranked AS (
      SELECT q.PATID, q.MM_DX_DT, q.index_source,
             row_number() OVER (PARTITION BY q.PATID ORDER BY q.MM_DX_DT) AS rn
      FROM {NDMM_MM_QUALIFYING} q
      WHERE q.inpt_qual = 1 OR q.outpt_qual = 1
    ),
    first_dx AS (
      SELECT PATID, MM_DX_DT, index_source FROM ranked WHERE rn = 1
    )
    SELECT cast(f.PATID as string) AS PATID, f.MM_DX_DT, f.index_source,
           m.GDR_CD, m.YRDOB,
           (year(f.MM_DX_DT) - m.YRDOB) AS AGE_DX_YR,
           dd.DEATH_DT
    FROM first_dx f
    INNER JOIN {NDMM_MEMBER_DEMO} m ON m.PATID = f.PATID
    LEFT JOIN {NDMM_DEATH_DT} dd
           ON dd.PATID = f.PATID AND dd.MM_DX_DT = f.MM_DX_DT
    WHERE m.YRDOB IS NOT NULL
      AND (year(f.MM_DX_DT) - m.YRDOB) >= {NDMM_MIN_AGE}
  "))
}

# What criterion 1 costs at each reading of it: the Optum translation this run
# may or may not apply, the OC rules' two inpatient refinements and their
# outpatient treatment link, and the two MDV flags. Patients with a qualifying
# diagnosis - criterion 1 alone, before age, the index or any exclusion. It
# does not change the cohort.
build_ndmm_mm_dx_rules <- function(con, cfg) {
  row <- function(label, sql, this = FALSE) glue("
    SELECT '{label}' AS RULE,
           count(DISTINCT PATID) AS N_PATIENTS,
           count(DISTINCT CASE WHEN inpt_qual = 1 THEN PATID END) AS N_VIA_INPATIENT,
           count(DISTINCT CASE WHEN outpt_qual = 1 THEN PATID END) AS N_VIA_OUTPATIENT,
           {as.integer(this)} AS IS_THIS_RUN
    FROM ({sql}) q")
  rules <- list(
    list("as configured", ndmm_mm_qualifying_sql(), TRUE),
    list("inpatient: nyugaikbn alone (the Optum rule)",
         ndmm_mm_qualifying_sql(ip_col = "inpt_none")),
    list("inpatient: inside an FF1 episode",
         ndmm_mm_qualifying_sql(ip_col = "inpt_ff1")),
    list("inpatient: FF1 first cancer with chemotherapy (the OC rule)",
         ndmm_mm_qualifying_sql(ip_col = "inpt_ff1_chemo")),
    list("outpatient months within 30 days of MM therapy (the OC rule)",
         ndmm_mm_qualifying_sql(tx_link = 30L)),
    list("suspected diagnoses included",
         ndmm_mm_qualifying_sql(confirmed_only = FALSE)),
    list(paste0("cancerflg ", if (NDMM_MDV_REQUIRE_CANCERFLG) "not " else "",
                "required"),
         ndmm_mm_qualifying_sql(need_cancer = !NDMM_MDV_REQUIRE_CANCERFLG)))
  body <- paste(vapply(seq_along(rules), function(i)
    row(rules[[i]][[1]], rules[[i]][[2]], isTRUE(rules[[i]][3][[1]])),
    character(1)), collapse = "\n    UNION ALL\n")
  db_exec(con, paste0("CREATE OR REPLACE TABLE ", wrk("NDMM_MM_DX_RULES"), " AS\n",
                      "SELECT r.*, ", sql_text(run_id), " AS RUN_ID,",
                      " current_timestamp() AS RECORDED_AT FROM (\n", body, "\n) r"))
  got <- db_q(con, glue("SELECT * FROM {wrk('NDMM_MM_DX_RULES')}"))
  log_msg("MM diagnosis (criterion 1) by reading, patients qualifying before age ",
          "and the index. This run: inpatient rule ", NDMM_MDV_IP_RULE,
          ", cancerflg ", if (NDMM_MDV_REQUIRE_CANCERFLG) "required" else "not required")
  for (i in seq_len(nrow(got)))
    log_msg("    ", if (isTRUE(got$IS_THIS_RUN[i] == 1L)) "->" else "  ", " ",
            got$RULE[i], ": ", format(got$N_PATIENTS[i], big.mark = ","),
            " (", format(got$N_VIA_INPATIENT[i], big.mark = ","), " inpatient, ",
            format(got$N_VIA_OUTPATIENT[i], big.mark = ","), " outpatient)")
  invisible(got)
}
