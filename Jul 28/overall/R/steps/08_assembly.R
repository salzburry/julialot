# Join every flag, apply the criteria, keep each patient's earliest surviving index.

phase_assembly <- function(cfg, h, ctx) {
  full_name <- h$full_name; work <- h$work
  criteria_sql <- ctx$criteria_sql

  list(
    # ---- Phase 10: assemble all flags, then apply the IE funnel ----
    # Step 23 joins every flag into ELIG_COH_ALLFLAGS and derives:
    #   ENDDATE     = min(death, study_end)
    #   ENDDATE_CE  = min(death, disenrollment, study_end)
    #   FU_DAYS     = ENDDATE    - (index + 1) + 1   (follow-up starts day after index)
    #   FU_DAYS_CE  = ENDDATE_CE - (index + 1) + 1
    # Step 24 then applies the criteria and keeps each patient's earliest
    # qualifying index date.
    list(
      name = "23_ELIG_COH_ALLFLAGS",
      description = "Assembling cohort with all flags",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('ELIG_COH_ALLFLAGS')} AS
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
      qc = glue("SELECT count(*) AS n_total, count(DISTINCT PATID) AS n_patients FROM {work('ELIG_COH_ALLFLAGS')}")
    ),

    list(
      name = "24_ELIG_COH_FINAL",
      description = glue("FINAL COHORT ({cfg$final_table_name}): Apply IE criteria then select EARLIEST qualifying index_date per patient"),
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work(cfg$final_table_name)} AS
        -- First apply IE criteria, then select the EARLIEST qualifying index_date per patient
        -- This ensures that if a patient's earliest potential index_date fails IE criteria,
        -- a later index_date that passes can still be selected
        WITH filtered AS (
          SELECT *
          FROM {work('ELIG_COH_ALLFLAGS')}
          WHERE 1=1
            -- Step 1: Index date must qualify via IP (strict) or OP in configured window
            AND (inpt_qual = 1 OR outpt2_{cfg$outpatient_window} = 1)
            {criteria_sql}
        ),
        ranked AS (
          SELECT *,
                 row_number() OVER (PARTITION BY PATID ORDER BY INDEX_DATE) AS rn
          FROM filtered
        )
        SELECT * FROM ranked WHERE rn = 1
      "),
      qc = glue("SELECT count(*) AS n_final_cohort FROM {work(cfg$final_table_name)}")
    ),

    # ---- Step 24b: write the final cohort as a permanent table ----

    if (isTRUE(cfg$persist_to_schema) && nzchar(cfg$personal_schema)) {
      persist_tbl <- full_name(cfg$personal_schema, cfg$final_table_name)
      list(
        name = "24b_persist_final_cohort",
        description = glue("Persist final cohort to {persist_tbl}"),
        sql = glue("
          CREATE OR REPLACE TABLE {persist_tbl} AS
          SELECT * FROM {work(cfg$final_table_name)}
        "),
        qc = glue("SELECT count(*) AS n_persisted FROM {persist_tbl}")
      )
    } else NULL
  )

  # ---- Assemble phases ----
  # Named list allows filtering by phase for interactive debugging:
  #   build_steps(cfg, mat_tables, phases = c("codelists", "dx_events"))
}
