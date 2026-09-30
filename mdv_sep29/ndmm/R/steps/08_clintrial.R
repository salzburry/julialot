# Clinical-trial evidence, anchored on the 1L index.
#
# Not a criterion. Clinical trial does not filter this cohort and must not
# start: this is a descriptive flag, and the funnel is
# built from NDMM_CRITERIA alone.
#
# It gets its own table rather than columns on NDMM_FLAGS_ALL. Every column
# there is a criterion or an input to one, and ndmm_criteria_where() reads that
# table - a descriptive flag sitting among them invites being read as one, and
# a later change to the conjunction could pick it up by accident.
#
# ---- why it exists -------------------------------------------------------
#
# The question is about clinical trial evidence against the 1L start:
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
# clintrial.csv, in the shape the scan joins on, normalised the way every
# other code list here is.
#
# Every code_type the scan in build_ndmm_clintrial_flags() reads: a trial
# diagnosis (Z00.6, by MDV disease code or ICD-10) and a trial-related act by
# receipt code. A row typed anything else is loaded, joined on equality, and
# matches nothing, so the flag reads 0 and no error is raised.
#
# The same three as NDMM_PREG_CODE_TYPES today, and deliberately not shared
# with it: these are two scans, and one dropping a source must not quietly
# loosen the other's guard.
#
# Weaker on MDV than on Optum. In Japan a sponsor pays for an investigational
# drug, so it is not on the insurance claim at all, and what reaches MDV is at
# most a diagnosis or an act the list happens to carry. A zero here says even
# less than it does on Optum.
NDMM_CLINTRIAL_CODE_TYPES <- c("DISEASECODE", "ICD10", "RECEIPTCODE")

build_ndmm_clintrial_codes <- function(con) {
  src <- load_codelist_csv("clintrial.csv", c("code", "code_type"))
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_CLINTRIAL_CODES} AS
    SELECT DISTINCT upper(trim(code_type)) AS code_type,
           {mdv_code_sql('code')} AS code
    FROM {src}
    WHERE {mdv_code_sql('code')} IS NOT NULL
      -- A blank type joins nothing: the scan derives its own code_type and the
      -- join below is on equality, so a row typed '' can only meet a claim
      -- whose family came back NULL, and NULL is not ''. Dropped here so it
      -- cannot pad the count that decides whether this list is usable.
      AND code_type IS NOT NULL AND trim(code_type) <> ''
  "))
  # The same hole 05_pregnancy.R had. load_codelist_csv stops on a file with no
  # rows, but it counts the rows as read - and the filters above drop codes that
  # are blank or punctuation-only once normalised. So a file carrying one row of
  # 'HCPCS,---' is a nonempty file and an empty code list, and nothing else here
  # would notice: the flags builder inner-joins this view, an empty view yields
  # no rows, and every patient gets CLINTRIAL = 0 - a clean-looking answer that
  # means the scan had nothing to look for.
  n <- db_q(con, glue("SELECT count(*) AS N FROM {NDMM_CLINTRIAL_CODES}"))
  if (as.numeric(n[[1]][1]) == 0)
    stop("clintrial.csv has rows but no usable codes: every one is blank or ",
         "punctuation-only once non-alphanumerics are stripped, or carries no ",
         "code type. The scan would match nothing and every patient would be ",
         "flagged as not in a trial.", call. = FALSE)

  # Having codes is not the same as having reachable ones. The join is on
  # code_type equality against a type the scan derives itself, so a row typed
  # something no arm emits loads cleanly and matches nothing - a rule that
  # cannot fire, and the count above cannot see it because the row is present
  # and well formed. Same guard 05_pregnancy.R carries, over this scan's types.
  want <- paste(sprintf("'%s'", NDMM_CLINTRIAL_CODE_TYPES), collapse = ", ")
  bad <- db_q(con, glue("
    SELECT code_type, count(*) AS n
    FROM {NDMM_CLINTRIAL_CODES}
    WHERE code_type NOT IN ({want})
    GROUP BY code_type ORDER BY code_type"))
  if (nrow(bad))
    stop("clintrial.csv carries code type(s) no MDV source produces: ",
         paste0(bad$code_type, " (", bad$n, " code(s))", collapse = ", "),
         ".\nThey would match nothing, so patients in a trial by those codes ",
         "would read as not in one. The scan emits ",
         paste(NDMM_CLINTRIAL_CODE_TYPES, collapse = ", "),
         "; retype the rows.", call. = FALSE)
  invisible(TRUE)
}

# One row per cohort patient with a 1L start.
#
# Two MDV sources: a confirmed diagnosis, dated to the first of its claim
# month, and an act, dated to the day. Bounded to the study period, and joined
# to NDMM_LOT1_STARTS so it scans this cohort's patients rather than the whole
# warehouse.
build_ndmm_clintrial_flags <- function(con) {
  keep <- glue("d.CONFIRMED = 1
        AND d.DX_MONTH BETWEEN date('{NDMM_STUDY_START}') AND date('{cfg$study_end}')")
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_CLINTRIAL_FLAGS} AS
    WITH anchors AS (
      SELECT l1.PATID, l1.LOT1_START_DT, b.MM_DX_DT
      FROM {NDMM_LOT1_STARTS} l1
      INNER JOIN {NDMM_BASE_COHORT} b ON b.PATID = l1.PATID
    ),
    dx AS (
      SELECT DISTINCT m.PATID, m.DX_MONTH AS event_dt
      FROM {ndmm_dx_join(NDMM_CLINTRIAL_CODES, 'c.code AS matched_code', keep)} m
      INNER JOIN {NDMM_LOT1_STARTS} l1 ON m.PATID = l1.PATID
    ),
    act AS (
      SELECT DISTINCT a.PATID, a.ACT_DT AS event_dt
      FROM ({mdv_act_select()}
      ) a
      INNER JOIN {NDMM_LOT1_STARTS} l1 ON a.PATID = l1.PATID
      INNER JOIN {NDMM_CLINTRIAL_CODES} c
              ON c.code_type = 'RECEIPTCODE' AND c.code = a.RECEIPTCODE
      WHERE a.ACT_DT BETWEEN date('{NDMM_STUDY_START}') AND date('{cfg$study_end}')
    ),
    matched AS (
      SELECT PATID, event_dt FROM dx
      UNION
      SELECT PATID, event_dt FROM act
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
           --
           -- TWO of them, over the two windows, because a timing figure has to
           -- be about the same claims as the count it is printed beside.
           -- Anything-before-1L includes pre-diagnosis claims, so a patient
           -- whose only trial code predates their diagnosis contributes to it
           -- while contributing nothing to CLINTRIAL_DX_TO_LOT1 - and one with
           -- codes in both windows contributes the older date. Reported next to
           -- the diagnosis-to-1L count, that describes a different population
           -- over a different window.
           min(CASE WHEN m.event_dt < a.LOT1_START_DT
                    THEN m.event_dt END)                     AS CLINTRIAL_FIRST_PRE_LOT1_DT,
           max(CASE WHEN m.event_dt < a.LOT1_START_DT
                    THEN datediff(a.LOT1_START_DT, m.event_dt) END)
                                                             AS CLINTRIAL_DAYS_BEFORE_LOT1,
           -- NULL unless CLINTRIAL_DX_TO_LOT1 = 1, by construction: same
           -- predicate, so the two cannot describe different patients.
           min(CASE WHEN m.event_dt >= a.MM_DX_DT
                     AND m.event_dt <  a.LOT1_START_DT
                    THEN m.event_dt END)                     AS CLINTRIAL_FIRST_DX_TO_LOT1_DT,
           max(CASE WHEN m.event_dt >= a.MM_DX_DT
                     AND m.event_dt <  a.LOT1_START_DT
                    THEN datediff(a.LOT1_START_DT, m.event_dt) END)
                                                             AS CLINTRIAL_DX_TO_LOT1_DAYS
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
