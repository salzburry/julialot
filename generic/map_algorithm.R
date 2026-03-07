#!/usr/bin/env Rscript
# ============================================================
# Generic LOT Framework — MAP (Medication Available Period) Algorithm
# ============================================================
# Disease-agnostic MAP computation using the aggregate() state
# machine pattern on Spark SQL. This is the core reusable piece.
#
# The MAP algorithm converts individual drug claims into continuous
# coverage periods per (patient, medication) using:
#   - Pharmacy claims: pushout logic (overlapping fills extend coverage)
#   - Medical claims: no pushout (each claim = date + day_supply - 1)
#   - Gap detection: new MAP when gap exceeds threshold
#
# This module exports functions that generate SQL strings.
# It does NOT execute SQL — that's the engine's job.
# ============================================================

#' Generate SQL to create the medication claims view (MMA_MED equivalent)
#'
#' Pulls relevant medication claims by joining source claim tables
#' against the disease-specific code list.
#'
#' @param cfg Validated LOT config
#' @param cohort_view Name of the patient cohort temp view
#' @param codelist_view Name of the codelist temp view
#' @return SQL string for CREATE OR REPLACE TEMPORARY VIEW
generate_med_claims_sql <- function(cfg, cohort_view, codelist_view) {
  cm <- cfg$claims_mapping
  pid <- cm$patient_id_field
  day_supply <- cfg$parameters$medical_day_supply

  # Build source-specific claim extraction CTEs
  # Each data source (medical, rx) needs its own join pattern
  source_ctes <- list()
  source_unions <- list()

  # --- Medical claims (procedure codes / HCPCS / J-codes) ---
  if (!is.null(cm$medical_table)) {
    med_date <- if (!is.null(cm$medical_date_field)) cm$medical_date_field else "FST_DT"
    med_code_fields <- if (!is.null(cm$medical_code_fields)) cm$medical_code_fields else c("PROC_CD")

    for (i in seq_along(med_code_fields)) {
      cte_name <- paste0("med_src_", i)
      code_field <- med_code_fields[i]
      source_ctes[[cte_name]] <- glue::glue("
        {cte_name} AS (
          SELECT
            m.{pid},
            cast(m.{med_date} AS date) AS DATE_SERVICE,
            cl.CL_MEDICATION_FULL,
            cl.CL_MED_CLASS,
            cl.CL_MED_ABBR,
            {day_supply} AS DAY_SUPPLY,
            'medical' AS CLAIM_TYPE
          FROM {cm$medical_table} m
          INNER JOIN {cohort_view} p ON m.{pid} = p.{pid}
          INNER JOIN {codelist_view} cl
            ON cl.CL_CODE_TYPE = 'HCPCS'
           AND upper(regexp_replace(coalesce(cast(m.{code_field} as string),''), '[^A-Za-z0-9]', '')) = cl.CL_CODE
          WHERE cast(m.{med_date} AS date) >= p.INDEX_DATE
            AND cast(m.{med_date} AS date) <= p.OBS_END_DT
        )")
      source_unions <- c(source_unions, paste0("SELECT * FROM ", cte_name))
    }
  }

  # --- Pharmacy claims (NDC codes) ---
  if (!is.null(cm$rx_table)) {
    rx_date <- if (!is.null(cm$rx_date_field)) cm$rx_date_field else "FILL_DT"
    rx_code_field <- if (!is.null(cm$rx_code_field)) cm$rx_code_field else "NDC"
    rx_days_field <- if (!is.null(cm$rx_days_supply_field)) cm$rx_days_supply_field else "DAYS_SUP"

    source_ctes[["rx_src"]] <- glue::glue("
      rx_src AS (
        SELECT
          r.{pid},
          cast(r.{rx_date} AS date) AS DATE_SERVICE,
          cl.CL_MEDICATION_FULL,
          cl.CL_MED_CLASS,
          cl.CL_MED_ABBR,
          CASE
            WHEN coalesce(cast(r.{rx_days_field} as int), 0) > 0
            THEN cast(r.{rx_days_field} as int)
            ELSE {day_supply}
          END AS DAY_SUPPLY,
          'pharmacy' AS CLAIM_TYPE
        FROM {cm$rx_table} r
        INNER JOIN {cohort_view} p ON r.{pid} = p.{pid}
        INNER JOIN {codelist_view} cl
          ON cl.CL_CODE_TYPE = 'NDC'
         AND upper(regexp_replace(coalesce(cast(r.{rx_code_field} as string),''), '[^A-Za-z0-9]', '')) = cl.CL_CODE
        WHERE cast(r.{rx_date} AS date) >= p.INDEX_DATE
          AND cast(r.{rx_date} AS date) <= p.OBS_END_DT
      )")
    source_unions <- c(source_unions, "SELECT * FROM rx_src")
  }

  # Combine all sources
  cte_block <- paste(source_ctes, collapse = ",\n")
  union_block <- paste(source_unions, collapse = "\n    UNION ALL\n    ")

  glue::glue("
    CREATE OR REPLACE TEMPORARY VIEW generic_mma_med AS
    WITH {cte_block},
    combined AS (
      {union_block}
    )
    SELECT
      {pid} AS PATID,
      DATE_SERVICE,
      CL_MEDICATION_FULL,
      CL_MED_CLASS AS MED_CLASS,
      CL_MED_ABBR AS MED_ABBR,
      DAY_SUPPLY,
      CLAIM_TYPE
    FROM combined
  ")
}

#' Generate SQL for the MAP state machine
#'
#' This is the core reusable algorithm. It processes sorted claims
#' per (patient, medication) through an aggregate() state machine
#' that tracks pharmacy and medical runout dates, implementing:
#'   - Pharmacy pushout (overlapping fills)
#'   - Medical no-pushout (always date + supply - 1)
#'   - Gap-based MAP boundaries
#'
#' @param cfg Validated LOT config
#' @param med_claims_view Name of the medication claims temp view
#' @param cohort_view Name of the patient cohort temp view
#' @return SQL string for CREATE OR REPLACE TEMPORARY VIEW
generate_map_sql <- function(cfg, med_claims_view = "generic_mma_med",
                             cohort_view = "lot_patient_input") {
  gap_days <- cfg$parameters$map_gap_days
  min_date <- "cast('1900-01-01' as date)"
  map_struct_type <- "array<struct<MAP_CNT:int,MAP_START_DT:date,MAP_RX_RUNOUT_DT:date,MAP_MED_RUNOUT_DT:date,MAP_END_DT:date>>"

  glue::glue("
    CREATE OR REPLACE TEMPORARY VIEW generic_map_med AS
    WITH claims AS (
      SELECT PATID, MED_ABBR, MED_CLASS,
             DATE_SERVICE AS dt, CLAIM_TYPE AS claim_type,
             cast(DAY_SUPPLY as int) AS ds
      FROM {med_claims_view}
    ),
    grouped AS (
      SELECT
        PATID, MED_ABBR,
        min(MED_CLASS) AS MED_CLASS,
        sort_array(collect_list(named_struct(
          'dt', dt,
          'type_ord', case when claim_type='pharmacy' then 0 else 1 end,
          'type', claim_type,
          'ds', ds
        ))) AS claims_arr
      FROM claims
      GROUP BY PATID, MED_ABBR
    ),
    maps AS (
      SELECT PATID, MED_ABBR, MED_CLASS,
        explode(
          aggregate(
            claims_arr,
            named_struct(
              'map_cnt', 0,
              'cur_start', cast(null as date),
              'rx_runout', cast(null as date),
              'med_runout', cast(null as date),
              'maps', cast(array() as {map_struct_type})
            ),
            (s, x) -> CASE
              -- First claim: start new MAP
              WHEN s.cur_start IS NULL THEN
                named_struct(
                  'map_cnt', 1,
                  'cur_start', x.dt,
                  'rx_runout', CASE WHEN x.type='pharmacy' THEN date_add(x.dt, x.ds - 1) ELSE NULL END,
                  'med_runout', CASE WHEN x.type='medical' THEN date_add(x.dt, x.ds - 1) ELSE NULL END,
                  'maps', s.maps
                )
              -- Claim beyond both runouts: close MAP, start new
              WHEN x.dt > greatest(coalesce(s.rx_runout, {min_date}), coalesce(s.med_runout, {min_date})) THEN
                named_struct(
                  'map_cnt', s.map_cnt + 1,
                  'cur_start', x.dt,
                  'rx_runout', CASE WHEN x.type='pharmacy' THEN date_add(x.dt, x.ds - 1) ELSE NULL END,
                  'med_runout', CASE WHEN x.type='medical' THEN date_add(x.dt, x.ds - 1) ELSE NULL END,
                  'maps', array_append(
                    s.maps,
                    named_struct('MAP_CNT', s.map_cnt, 'MAP_START_DT', s.cur_start,
                      'MAP_RX_RUNOUT_DT', s.rx_runout, 'MAP_MED_RUNOUT_DT', s.med_runout,
                      'MAP_END_DT', greatest(coalesce(s.rx_runout, {min_date}), coalesce(s.med_runout, {min_date})))
                  )
                )
              -- Claim within MAP: update runouts
              ELSE
                named_struct(
                  'map_cnt', s.map_cnt,
                  'cur_start', s.cur_start,
                  'rx_runout', CASE
                    WHEN x.type='pharmacy' THEN
                      CASE
                        WHEN s.rx_runout IS NULL THEN date_add(x.dt, x.ds - 1)
                        WHEN x.dt <= s.rx_runout THEN date_add(s.rx_runout, x.ds)
                        ELSE date_add(x.dt, x.ds - 1)
                      END
                    ELSE s.rx_runout
                  END,
                  'med_runout', CASE
                    WHEN x.type='medical' THEN
                      CASE
                        WHEN s.med_runout IS NULL THEN date_add(x.dt, x.ds - 1)
                        ELSE greatest(s.med_runout, date_add(x.dt, x.ds - 1))
                      END
                    ELSE s.med_runout
                  END,
                  'maps', s.maps
                )
            END,
            -- Finalize: flush last open MAP
            s -> CASE
              WHEN s.cur_start IS NULL THEN cast(array() as {map_struct_type})
              ELSE array_append(
                s.maps,
                named_struct('MAP_CNT', s.map_cnt, 'MAP_START_DT', s.cur_start,
                  'MAP_RX_RUNOUT_DT', s.rx_runout, 'MAP_MED_RUNOUT_DT', s.med_runout,
                  'MAP_END_DT', greatest(coalesce(s.rx_runout, {min_date}), coalesce(s.med_runout, {min_date})))
              )
            END
          )
        ) AS map_rec
      FROM grouped
    ),
    base AS (
      SELECT m.PATID, m.MED_ABBR, m.MED_CLASS,
        map_rec.MAP_CNT, map_rec.MAP_START_DT,
        map_rec.MAP_RX_RUNOUT_DT, map_rec.MAP_MED_RUNOUT_DT,
        CASE WHEN map_rec.MAP_END_DT = {min_date} THEN NULL ELSE map_rec.MAP_END_DT END AS MAP_END_DT
      FROM maps m
    ),
    with_next AS (
      SELECT b.*,
        lead(MAP_START_DT) OVER (PARTITION BY PATID, MED_ABBR ORDER BY MAP_CNT) AS NEXT_MAP_START_DT
      FROM base b
    )
    SELECT
      w.PATID, w.MED_ABBR, w.MED_CLASS,
      w.MAP_CNT, w.MAP_START_DT,
      w.MAP_RX_RUNOUT_DT, w.MAP_MED_RUNOUT_DT,
      w.MAP_END_DT,
      w.MED_ABBR AS MAP_MED_TYPE,
      w.MED_CLASS AS MAP_MED_CLASS,
      CASE
        WHEN w.NEXT_MAP_START_DT IS NOT NULL
          AND datediff(w.NEXT_MAP_START_DT, w.MAP_END_DT) >= {gap_days}
          THEN 1
        WHEN w.NEXT_MAP_START_DT IS NULL
          AND datediff(p.OBS_END_DT, w.MAP_END_DT) >= {gap_days}
          THEN 1
        ELSE 0
      END AS MAP_DISCON_FLG
    FROM with_next w
    INNER JOIN {cohort_view} p ON w.PATID = p.PATID
    WHERE w.MAP_END_DT IS NOT NULL
  ")
}
