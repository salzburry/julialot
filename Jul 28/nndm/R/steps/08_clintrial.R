# Clinical-trial evidence, anchored on the 1L index.
#
# NOT a criterion. Clinical trial does not filter this cohort and must not
# start: this is a descriptive flag the study team asked for, and the funnel is
# built from NDMM_CRITERIA alone.
#
# It gets its own table rather than columns on NDMM_FLAGS_ALL. Every column
# there is a criterion or an input to one, and ndmm_criteria_where() reads that
# table - a descriptive flag sitting among them invites being read as one, and
# a later change to the conjunction could pick it up by accident.
#
# ---- why it exists -------------------------------------------------------
#
# The broad build already flags clinical trial, but on ITS index - the
# diagnosis-based candidate it selects - and the study team's question is about
# the 1L start:
#
#   "was the POMA recorded at LOT1 really first line, or did trial therapy
#    come before it?"
#
# Its two flags cannot answer that. CLINTRIAL_BASELINE ends the day before the
# diagnosis index, so it misses everything between diagnosis and LOT1.
# CLINTRIAL_FOLLOWUP starts on the diagnosis index and runs past LOT1, so it
# mixes that same stretch with evidence from after treatment began. The window
# that matters is in neither.
#
# So the windows here are cut at the 1L index, and the diagnosis-to-LOT1
# stretch is its own column.

# The four windows, and what each one is for.
#
#   CLINTRIAL_PRE_DX        before the MM diagnosis
#   CLINTRIAL_DX_TO_LOT1    diagnosis up to the day before LOT1 <- the answer
#   CLINTRIAL_POST_LOT1     LOT1 onward - context, never evidence of a prior line
#
# Those three partition the study period: no claim is in two of them, so they
# can be added.
#
#   CLINTRIAL_PRE_LOT1_12MO  the twelve months before LOT1
#
# That fourth one SPANS the first two - a trial claim ten months before LOT1
# and two months before diagnosis is in both PRE_DX and PRE_LOT1_12MO. It is
# here because it is the window filter #4 uses for prior MM therapy, so the two
# can be read side by side. Adding it to the others double-counts, which is why
# it is named for its window rather than for a position in a sequence.
NDMM_CLINTRIAL_WINDOWS <- c("CLINTRIAL_PRE_DX", "CLINTRIAL_DX_TO_LOT1",
                            "CLINTRIAL_POST_LOT1", "CLINTRIAL_PRE_LOT1_12MO")

# clintrial.csv, in the shape the claim scan joins on. Same file and the same
# normalisation the broad build uses, so "a trial claim" means one thing across
# the two cohorts and a difference between them is about the window, not about
# the codes.
build_ndmm_clintrial_codes <- function(con) {
  src <- load_codelist_csv("clintrial.csv", c("code", "code_type"))
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_CLINTRIAL_CODES} AS
    SELECT DISTINCT upper(trim(code_type)) AS code_type,
           upper(regexp_replace(trim(code), '[^A-Za-z0-9]', '')) AS code
    FROM {src}
    WHERE code IS NOT NULL AND regexp_replace(code, '[^A-Za-z0-9]', '') <> ''
  "))
}

# One row per cohort patient with a 1L start.
#
# Five claim sources, the same five the broad build scans: diagnosis, PROC_CD,
# BILL_PROC_CD (the facility-claim procedure code - a code populated only there
# is missed without it), ICD procedure, and revenue code. Bounded to the study
# period, and joined to NDMM_LOT1_STARTS so it scans this cohort's patients
# rather than the whole warehouse.
#
# icd_family_sql() on both ICD sources, so a claim whose flag is blank or
# spelled some way nobody anticipated yields NULL and matches neither family -
# rather than being read as ICD-10 and then failing the join silently.
build_ndmm_clintrial_flags <- function(con, med_diag_tbl, medical_tbl,
                                       med_proc_tbl) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_CLINTRIAL_FLAGS} AS
    WITH anchors AS (
      SELECT l1.PATID, l1.LOT1_START_DT, b.MM_DX_DT
      FROM {NDMM_LOT1_STARTS} l1
      INNER JOIN {NDMM_BASE_COHORT} b ON b.PATID = l1.PATID
    ),
    dx AS (
      SELECT cast(d.PATID as string) AS PATID, cast(d.FST_DT as date) AS event_dt,
             {icd_family_sql('d.ICD_FLAG', 'ICD9DIAG', 'ICD10DIAG')} AS code_type,
             upper(regexp_replace(d.DIAG, '[^A-Za-z0-9]', '')) AS code
      FROM {med_diag_tbl} d
      INNER JOIN {NDMM_LOT1_STARTS} l1 ON cast(d.PATID as string) = l1.PATID
      WHERE d.DIAG IS NOT NULL
        AND cast(d.FST_DT as date) BETWEEN date('{NDMM_STUDY_START}') AND date('{cfg$study_end}')
    ),
    med AS (
      SELECT s.PATID, s.event_dt, t.code_type, t.code
      FROM (
        SELECT cast(m.PATID as string) AS PATID, cast(m.FST_DT as date) AS event_dt,
               m.PROC_CD, m.BILL_PROC_CD, m.RVNU_CD
        FROM {medical_tbl} m
        INNER JOIN {NDMM_LOT1_STARTS} l1 ON cast(m.PATID as string) = l1.PATID
        WHERE cast(m.FST_DT as date) BETWEEN date('{NDMM_STUDY_START}') AND date('{cfg$study_end}')
      ) s
      LATERAL VIEW stack(3,
        'HCPCS', CASE WHEN s.PROC_CD IS NOT NULL
                      THEN upper(regexp_replace(s.PROC_CD, '[^A-Za-z0-9]', '')) END,
        'HCPCS', CASE WHEN s.BILL_PROC_CD IS NOT NULL
                      THEN upper(regexp_replace(s.BILL_PROC_CD, '[^A-Za-z0-9]', '')) END,
        'REV',   CASE WHEN s.RVNU_CD IS NOT NULL AND trim(s.RVNU_CD) <> ''
                      THEN upper(trim(s.RVNU_CD)) END
      ) t AS code_type, code
      WHERE t.code IS NOT NULL AND t.code <> ''
    ),
    icd_proc AS (
      SELECT cast(p.PATID as string) AS PATID, cast(p.FST_DT as date) AS event_dt,
             {icd_family_sql('p.ICD_FLAG', 'ICD9PROC', 'ICD10PROC')} AS code_type,
             upper(regexp_replace(p.PROC, '[^A-Za-z0-9]', '')) AS code
      FROM {med_proc_tbl} p
      INNER JOIN {NDMM_LOT1_STARTS} l1 ON cast(p.PATID as string) = l1.PATID
      WHERE p.PROC IS NOT NULL
        AND cast(p.FST_DT as date) BETWEEN date('{NDMM_STUDY_START}') AND date('{cfg$study_end}')
    ),
    events AS (
      SELECT * FROM dx UNION ALL SELECT * FROM med UNION ALL SELECT * FROM icd_proc
    ),
    matched AS (
      SELECT /*+ BROADCAST(c) */ e.PATID, e.event_dt
      FROM events e
      INNER JOIN {NDMM_CLINTRIAL_CODES} c
              ON e.code_type = c.code_type AND e.code = c.code
    )
    SELECT a.PATID,
           a.LOT1_START_DT,
           a.MM_DX_DT,
           max(CASE WHEN m.event_dt < a.MM_DX_DT
                    THEN 1 ELSE 0 END)                       AS CLINTRIAL_PRE_DX,
           max(CASE WHEN m.event_dt >= a.MM_DX_DT
                     AND m.event_dt <  a.LOT1_START_DT
                    THEN 1 ELSE 0 END)                       AS CLINTRIAL_DX_TO_LOT1,
           max(CASE WHEN m.event_dt >= a.LOT1_START_DT
                    THEN 1 ELSE 0 END)                       AS CLINTRIAL_POST_LOT1,
           max(CASE WHEN m.event_dt >= date_sub(a.LOT1_START_DT, {NDMM_PRE_LOT1_DAYS})
                     AND m.event_dt <  a.LOT1_START_DT
                    THEN 1 ELSE 0 END)                       AS CLINTRIAL_PRE_LOT1_12MO,
           -- How long before the 1L start the earliest trial claim falls. A
           -- flag says whether; this says when, which is what separates
           -- 'trial therapy, then POMA' from 'a trial code the same week'.
           min(CASE WHEN m.event_dt < a.LOT1_START_DT
                    THEN m.event_dt END)                     AS CLINTRIAL_FIRST_PRE_LOT1_DT,
           max(CASE WHEN m.event_dt < a.LOT1_START_DT
                    THEN datediff(a.LOT1_START_DT, m.event_dt) END)
                                                             AS CLINTRIAL_DAYS_BEFORE_LOT1
    FROM anchors a
    LEFT JOIN matched m ON m.PATID = a.PATID
    GROUP BY a.PATID, a.LOT1_START_DT, a.MM_DX_DT
  "))
}

# A patient with no MM_DX_DT would land in none of the three partition columns
# and read as having no trial evidence anywhere - the silent-zero shape this
# build keeps having to guard against. The base cohort requires a qualifying
# diagnosis, so it cannot happen; asked anyway, because it is the assumption
# the partition rests on.
#
# The counts go to the log rather than a table: this is a descriptive flag, and
# a run whose trial rate looks wrong should be visible without opening the
# warehouse.
report_ndmm_clintrial <- function(con) {
  q <- db_q(con, glue("
    SELECT count(*)                                          AS n_pts,
           sum(CASE WHEN MM_DX_DT IS NULL THEN 1 ELSE 0 END) AS n_no_dx,
           sum(CLINTRIAL_PRE_DX)                             AS n_pre_dx,
           sum(CLINTRIAL_DX_TO_LOT1)                         AS n_dx_to_lot1,
           sum(CLINTRIAL_POST_LOT1)                          AS n_post_lot1,
           sum(CLINTRIAL_PRE_LOT1_12MO)                      AS n_pre_lot1_12mo
    FROM {NDMM_CLINTRIAL_FLAGS}"))
  if (isTRUE(as.integer(q$n_no_dx[1]) > 0))
    stop(q$n_no_dx[1], " patients in ", NDMM_CLINTRIAL_FLAGS, " have no ",
         "MM_DX_DT. The three windows are cut at that date, so those rows ",
         "would read as no trial evidence anywhere rather than as unknown.",
         call. = FALSE)
  log_msg("  Clinical trial (descriptive, not a criterion), ", q$n_pts[1],
          " patients: before diagnosis ", q$n_pre_dx[1],
          ", diagnosis to 1L ", q$n_dx_to_lot1[1],
          ", 1L onward ", q$n_post_lot1[1],
          "; 12 months before 1L ", q$n_pre_lot1_12mo[1],
          " (that window spans the first two - do not add it to them)")
  invisible(q)
}
