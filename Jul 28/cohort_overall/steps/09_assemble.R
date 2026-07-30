# =============================================================================
# 09_assemble.R -- join every flag, then apply the funnel
# -----------------------------------------------------------------------------
# Two tables, and the order between them is the design:
#
#   ovr_ELIG_COH_ALLFLAGS  one row per (PATID, candidate index date), every
#                          criterion as a column. Nobody is dropped.
#   ovr_ELIG_COH_FINAL     apply the active criteria, then take each patient's
#                          earliest surviving index date. This is the cohort.
#
# Filter first, rank second -- apply the criteria, THEN take the earliest
# surviving candidate. Ranking first would drop a patient whose earliest
# candidate fails a later gate even when a later candidate passes, so the index
# date a patient ends up with depends on which gates are on. Turning a gate off
# can move patients to an earlier index date, not just in or out; counts alone
# will not show that.
#
# Every flag is kept as a column, so a sensitivity analysis is a WHERE clause and
# the gates that ship off are still computed for downstream re-use.
#
# Derived here, not criteria (carried for the LOT build):
#   AGE_INDEX_YR  year(INDEX_DATE) - YRDOB      <- step 2 reads this
#   ENDDATE       least(study_end, death)
#   ENDDATE_CE    least(study_end, death, disenrolment)
#   FU_DAYS       ENDDATE    - (index+1) + 1
#   FU_DAYS_CE    ENDDATE_CE - (index+1) + 1
#   CE_3mosf      90-day strict, death-aware enrolment
# FU_DAYS counts from the day after index then adds 1 back, so someone who dies on
# their index date has FU_DAYS = 0.
#
# The ALLFLAGS SELECT is a copy of pipeline_steps.R step 23, so it names its
# source tables and columns explicitly rather than generating them from the
# criteria list -- that is what makes the drift comparison possible. The cost: a
# new criterion needs a column added here as well as its own step file, and
# ie_criteria.R errors at load time if that is missed.
# =============================================================================

ie_step_assemble <- function(cfg, h, criteria) {
  work <- h$work

  # Steps 2-10 in funnel order, only the ones config turns on.
  criteria_sql <- ie_criteria_sql(criteria, cfg)
  # Step 1 goes on its own line, as the legacy step 24 filter does. Read out of
  # the criterion rather than repeated here.
  idx <- Filter(function(c) identical(c$step, 1L), criteria)
  if (length(idx) != 1L)
    stop("expected exactly one Step 1 criterion; found ", length(idx),
         call. = FALSE)
  index_predicate <- idx[[1]]$predicate

  views <- list(
    ie_view(
      name = cfg$flags_view,
      legacy = "23_ELIG_COH_ALLFLAGS",
      description = "Assembling cohort with all flags",
      select = fmt("
        WITH base AS (
          SELECT
            q.PATID,
            q.index_date,
            d.GDR_CD,
            d.YRDOB,
            death.DEATH_DT,
            ce.baseline_start,
            ce.baseline_end,
            ce.CE_b,
            ce.CE_f,
            ce.ENDDATE_CE,
            th.MM_THERAPY_BASELINE,
            th.MM_THERAPY_FOLLOWUP,
            mm_bl.MM_BASELINE_EVIDENCE,
            om.OTHER_MALIGN_FLAG,
            preg.PREGNANT_FLAG,
            ct.CLINTRIAL_BASELINE,
            ct.CLINTRIAL_FOLLOWUP,
            q.inpt_qual, q.outpt_qual, q.outpt2_30, q.outpt2_60, q.outpt2_90, q.index_source
          FROM {work('mm_qualifying')} q
          LEFT JOIN {work('ce_flags')} ce ON q.PATID = ce.PATID AND q.index_date = ce.index_date
          LEFT JOIN {work('member_demo')} d ON q.PATID = d.PATID
          LEFT JOIN {work('death_dt')} death ON q.PATID = death.PATID AND q.index_date = death.index_date
          LEFT JOIN {work('mm_baseline_evidence_flag')} mm_bl ON q.PATID = mm_bl.PATID AND q.index_date = mm_bl.index_date
          LEFT JOIN {work('therapy_flags')} th ON q.PATID = th.PATID AND q.index_date = th.index_date
          LEFT JOIN {work('pregnancy_flag')} preg ON q.PATID = preg.PATID AND q.index_date = preg.index_date
          LEFT JOIN {work('clintrial_flag')} ct ON q.PATID = ct.PATID AND q.index_date = ct.index_date
          LEFT JOIN {work('other_malig_flag')} om ON q.PATID = om.PATID AND q.index_date = om.index_date
        ),
        -- CE_3mosf with death-aware logic (no gaps, ends at min of 90 days/death/study_end)
        ce3mos_calc AS (
          SELECT
            b.PATID,
            b.index_date,
            least(
              date_add(b.index_date, 90),
              date('{cfg$study_end}'),
              coalesce(b.DEATH_DT, date('{cfg$study_end}'))
            ) AS required_3mos_end,
            ss.cov_start,
            ss.cov_end
          FROM base b
          LEFT JOIN {work('enrollment_spans_strict')} ss ON b.PATID = ss.PATID
        ),
        ce3mos_flag AS (
          SELECT PATID, index_date,
            max(CASE WHEN cov_start <= index_date AND cov_end >= required_3mos_end THEN 1 ELSE 0 END) AS CE_3mosf
          FROM ce3mos_calc
          GROUP BY PATID, index_date
        )
        SELECT
          b.PATID,
          b.index_date AS INDEX_DATE,
          year(b.index_date) AS INDEX_YR,
          b.GDR_CD,
          b.YRDOB,
          (year(b.index_date) - b.YRDOB) AS AGE_INDEX_YR,
          b.inpt_qual, b.outpt_qual, b.outpt2_30, b.outpt2_60, b.outpt2_90, b.index_source,
          b.baseline_start, b.baseline_end,
          coalesce(b.CE_b, 0) AS CE_b,
          coalesce(b.CE_f, 0) AS CE_f,
          coalesce(c3.CE_3mosf, 0) AS CE_3mosf,
          b.DEATH_DT,
          least(date('{cfg$study_end}'), coalesce(b.DEATH_DT, date('{cfg$study_end}'))) AS ENDDATE,
          least(date('{cfg$study_end}'), coalesce(b.DEATH_DT, date('{cfg$study_end}')), coalesce(b.ENDDATE_CE, date('{cfg$study_end}'))) AS ENDDATE_CE,
          datediff(least(date('{cfg$study_end}'), coalesce(b.DEATH_DT, date('{cfg$study_end}'))), date_add(b.index_date, 1)) + 1 AS FU_DAYS,
          datediff(least(date('{cfg$study_end}'), coalesce(b.DEATH_DT, date('{cfg$study_end}')), coalesce(b.ENDDATE_CE, date('{cfg$study_end}'))), date_add(b.index_date, 1)) + 1 AS FU_DAYS_CE,
          coalesce(b.MM_THERAPY_BASELINE, 0) AS MM_bl_agents,
          coalesce(b.MM_THERAPY_FOLLOWUP, 0) AS MM_FU_agents,
          coalesce(b.MM_BASELINE_EVIDENCE, 0) AS MM_baseline_diag,
          coalesce(b.OTHER_MALIGN_FLAG, 0) AS OTHER_MALIGN_FLAG,
          coalesce(b.PREGNANT_FLAG, 0) AS PREGNANT_FLAG,
          coalesce(b.CLINTRIAL_BASELINE, 0) AS CLINTRIAL_BASELINE,
          coalesce(b.CLINTRIAL_FOLLOWUP, 0) AS CLINTRIAL_FOLLOWUP
        FROM base b
        LEFT JOIN ce3mos_flag c3 ON b.PATID = c3.PATID AND b.index_date = c3.index_date
      "),
      qc = fmt("SELECT count(*) AS n_total, count(DISTINCT PATID) AS n_patients FROM {work(cfg$flags_view)}")
    ),

    ie_view(
      name = cfg$final_table_name,
      legacy = "24_ELIG_COH_FINAL",
      stage = TRUE,   # built as __stg, published by the runner after reconcile
      description = fmt("FINAL COHORT ({work(cfg$final_table_name)}): Apply IE criteria then select EARLIEST qualifying index_date per patient"),
      select = fmt("
        -- First apply IE criteria, then select the EARLIEST qualifying index_date per patient
        -- This ensures that if a patient's earliest potential index_date fails IE criteria,
        -- a later index_date that passes can still be selected
        WITH filtered AS (
          SELECT *
          FROM {work(cfg$flags_view)}
          WHERE 1=1
            -- Step 1: Index date must qualify via IP (strict) or OP in configured window
            AND {index_predicate}
            {criteria_sql}
        ),
        ranked AS (
          SELECT *,
                 row_number() OVER (PARTITION BY PATID ORDER BY INDEX_DATE) AS rn
          FROM filtered
        )
        SELECT * FROM ranked WHERE rn = 1
      "),
      # No QC here: this step writes the staged table, and {work(final)} is the
      # published name, which does not exist on a first run. Reconciliation
      # counts the staged cohort instead.
      qc = NULL
    )
  )

  # No persist step. The legacy pipeline needed one because its final object was
  # a temp view; here the step above already wrote a table. That also removes the
  # bug where the persist step reads a different object than the one just built,
  # so legacy step 24b has no counterpart and the test lists it as absent by
  # design.

  list(views = views, criteria = list())
}
