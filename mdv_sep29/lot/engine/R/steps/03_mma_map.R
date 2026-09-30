# MM-approved and steroid acts from MDV, then the Medication Available Period.
#
# Split at the seam lot/PORTING.md describes. phase_mma_extract() is the MDV
# half: it reads the act table and writes MMA_MED_PROCESSED, one row per drug,
# day and claim type. phase_map() is the Optum build's MAP state machine,
# unchanged: it reads only MMA_MED_PROCESSED and the cohort, and writes
# MAP_STACKED. The suite runs the first half against synthetic MDV. No suite
# here executes the second: it uses Spark aggregate with a finish lambda, which
# DuckDB cannot run (../../../MDV_RULES.md, "What was tested").

phase_mma_map <- function(con, ctx) {
  phase_mma_extract(con, ctx)
  phase_map(con, ctx)
}

phase_mma_extract <- function(con, ctx) {

  # STEP 2 (5A): MMA_MED - Raw extraction, from MDV acts.
  #
  # One source where Optum has four arms: every drug, oral or injected,
  # inpatient or outpatient, is an act, and mma_receipts (01_codelists.R) has
  # already resolved the code list to the receipt codes to join on.
  #
  # The Optum engine tells a pharmacy fill (its supply accumulates) from a
  # medical administration (it covers MEDICAL_DAY_SUPPLY from its own date) by
  # the table it came from. MDV has one table, so the code list's CL_ROUTE
  # says which an act is:
  #
  #   INJ   'medical'  - covers MEDICAL_DAY_SUPPLY days from the act
  #   ORAL  'pharmacy' - covers the act's days supplied, where the delivery
  #                      carries them (MDV_COL_ACT_DAYS); else one day for an
  #                      inpatient act, which DPC records day by day, and
  #                      ORAL_DAYS_DEFAULT for an outpatient prescription
  #
  # Everything after this - the MAP, the lines - reads the two claim types
  # exactly as it reads Optum's. LOT_RULES.md section 2.3.
  # An oral act with no days supplied is sized by its care setting. With the
  # setting column configured, a value that is neither MDV_INPATIENT nor
  # MDV_OUTPATIENT would fall to ORAL_DAYS_DEFAULT as if outpatient - 28 days
  # for what may be one inpatient day - and nothing would say so. Refused
  # instead: fix the codes, or declare the column NONE to take the documented
  # no-setting fallback on purpose.
  if (nzchar(MDV_COLS$act_nyugaikbn)) {
    unrec <- db_q(con, glue("
      SELECT a.SETTING_RAW, count(*) AS n_acts
      FROM ({mdv_act_select()}
      ) a
      INNER JOIN lot_patient_input p ON a.PATID = p.PATID
      INNER JOIN (SELECT DISTINCT RECEIPTCODE FROM mma_receipts WHERE CL_ROUTE = 'ORAL') c
              ON c.RECEIPTCODE = a.RECEIPTCODE
      WHERE a.ACT_DT >= p.INDEX_DATE AND a.ACT_DT <= p.OBS_END_DT
        AND a.INPT IS NULL
        AND coalesce(a.ACT_DAYS, 0) < 1
      GROUP BY a.SETTING_RAW
      ORDER BY n_acts DESC"))
    if (nrow(unrec) > 0)
      stop(sum(unrec$n_acts), " oral act(s) with no days supplied carry a ",
           MDV_COLS$act_nyugaikbn, " value that is neither MDV_INPATIENT ('",
           MDV_VALUES$inpatient, "') nor MDV_OUTPATIENT ('", MDV_VALUES$outpatient,
           "'): ", paste0(unrec$SETTING_RAW, " (", unrec$n_acts, ")", collapse = ", "),
           ". Their supply cannot be sized. Set MDV_INPATIENT / MDV_OUTPATIENT to ",
           "this delivery's codes, or MDV_COL_ACT_NYUGAIKBN=NONE to size every one ",
           "at ORAL_DAYS_DEFAULT on purpose.", call. = FALSE)
  }

  run_step(con, "S04_mma_med_raw", glue("
    CREATE OR REPLACE TEMPORARY VIEW mma_med_raw AS
    WITH codes AS (
      -- One row per receipt code: the checks in 01_codelists.R refused a code
      -- naming two drugs or two routes, so the grouping loses nothing.
      SELECT /*+ BROADCAST */ RECEIPTCODE, CL_MED_ABBR, CL_MED_CLASS, CL_ROUTE,
             min(CL_CODE_TYPE) AS CL_CODE_TYPE
      FROM mma_receipts
      GROUP BY RECEIPTCODE, CL_MED_ABBR, CL_MED_CLASS, CL_ROUTE
    ),
    act AS ({mdv_act_select()}
    )
    SELECT
      a.PATID,
      a.ACT_DT AS DATE_SERVICE,
      CASE WHEN c.CL_ROUTE = 'ORAL' THEN
             CASE WHEN a.ACT_DAYS >= 1 THEN a.ACT_DAYS
                  WHEN a.INPT = 1      THEN 1
                  ELSE {cfg$oral_days_default} END
           ELSE {cfg$medical_day_supply} END AS DAY_SUPPLY,
      CASE WHEN c.CL_ROUTE = 'ORAL' THEN 'pharmacy' ELSE 'medical' END AS CLAIM_TYPE,
      CASE WHEN c.CL_ROUTE = 'ORAL' THEN 'act_oral' ELSE 'act_inj' END AS CLAIM_SOURCE,
      a.RECEIPTCODE AS CODE,
      c.CL_CODE_TYPE AS CODE_TYPE,
      c.CL_MED_ABBR AS MED_ABBR,
      c.CL_MED_CLASS AS MED_CLASS,
      -- For the QC below only: where an oral act's supply came from.
      CASE WHEN c.CL_ROUTE <> 'ORAL' THEN 'fixed'
           WHEN a.ACT_DAYS >= 1 THEN 'carried'
           WHEN a.INPT = 1 THEN 'inpatient_day'
           ELSE 'default' END AS SUPPLY_SOURCE
    FROM act a
    INNER JOIN lot_patient_input p ON a.PATID = p.PATID
    INNER JOIN codes c ON c.RECEIPTCODE = a.RECEIPTCODE
    WHERE a.ACT_DT >= p.INDEX_DATE
      AND a.ACT_DT <= p.OBS_END_DT  -- ENDDATE_CE on MDV: the last record
  "), qc = "
    SELECT
      count(*) AS n_rows,
      count(DISTINCT PATID) AS n_patients,
      count(DISTINCT MED_ABBR) AS n_meds,
      sum(case when CLAIM_TYPE='pharmacy' then 1 else 0 end) AS n_oral_rows,
      sum(case when CLAIM_TYPE='medical' then 1 else 0 end) AS n_injected_rows,
      -- How much of the oral supply is the data's and how much is assumed.
      sum(case when SUPPLY_SOURCE='carried' then 1 else 0 end) AS n_oral_days_carried,
      sum(case when SUPPLY_SOURCE='inpatient_day' then 1 else 0 end) AS n_oral_inpatient_day,
      sum(case when SUPPLY_SOURCE='default' then 1 else 0 end) AS n_oral_days_default
    FROM mma_med_raw")

  # Enrich + dedup.
  #
  # Written to a table rather than left as a view. Beneath it, mma_med_raw is
  # the scan of the act table above, and this is read six times over a run -
  # so left lazy it is six passes over the act table for one extraction.
  materialize(con, "S05_mma_med_processed", view = "mma_med_processed", name = "MMA_MED_PROCESSED", body = glue("
    WITH enriched AS (
      SELECT
        r.PATID,
        r.CODE,
        r.CODE_TYPE,
        r.CLAIM_TYPE,
        r.DATE_SERVICE,
        r.DAY_SUPPLY,
        r.MED_ABBR,
        r.MED_CLASS,
        CASE WHEN coalesce(ru.CONDITIONING,0) = 1 THEN 'Yes' ELSE 'No' END AS MED_COND,
        CASE WHEN coalesce(ru.USED_FOR_OTHER_CANCERS,0) = 1 THEN 'Yes' ELSE 'No' END AS MED_OTHER_CANCER
      FROM mma_med_raw r
      LEFT JOIN mma_rollup ru
        ON r.MED_ABBR = ru.CL_MED_ABBR
    ),
    filtered AS (
      -- A pharmacy claim with a missing or odd DAY_SUPPLY is imputed to 28,
      -- not dropped.
      SELECT
        PATID, CODE, CODE_TYPE, CLAIM_TYPE, DATE_SERVICE,
        CASE
          WHEN CLAIM_TYPE = 'pharmacy' AND (DAY_SUPPLY IS NULL OR DAY_SUPPLY < 1)
          THEN 28
          ELSE DAY_SUPPLY
        END AS DAY_SUPPLY,
        MED_ABBR, MED_CLASS, MED_COND, MED_OTHER_CANCER
      FROM enriched
    ),
    dedup AS (
      -- Dedup within (PATID, MED_ABBR, DATE_SERVICE, CLAIM_TYPE). Keep the
      -- largest DAY_SUPPLY for pharmacy, or the single row for medical, where
      -- they are all 28.
      SELECT
        PATID,
        MED_ABBR,
        DATE_SERVICE,
        CLAIM_TYPE,
        max(DAY_SUPPLY) AS DAY_SUPPLY,
        -- min() so two runs dedup the same way.
        min(CODE) AS CODE,
        min(CODE_TYPE) AS CODE_TYPE,
        min(MED_CLASS) AS MED_CLASS,
        min(MED_COND) AS MED_COND,
        min(MED_OTHER_CANCER) AS MED_OTHER_CANCER
      FROM filtered
      GROUP BY PATID, MED_ABBR, DATE_SERVICE, CLAIM_TYPE
    )
    SELECT * FROM dedup
  "), qc = "
    SELECT
      count(*) AS n_rows,
      sum(case when CLAIM_TYPE='pharmacy' then 1 else 0 end) AS n_pharmacy_rows,
      sum(case when CLAIM_TYPE='medical' then 1 else 0 end) AS n_medical_rows,
      min(DAY_SUPPLY) AS min_day_supply,
      max(DAY_SUPPLY) AS max_day_supply
    FROM mma_med_processed")

  # After imputation, no pharmacy row should have an invalid DAY_SUPPLY.
  bad_ds <- db_q(con, "SELECT count(*) AS n_bad FROM mma_med_processed WHERE CLAIM_TYPE='pharmacy' AND (DAY_SUPPLY IS NULL OR DAY_SUPPLY < 1)")$n_bad
  if (bad_ds > 0) stop(glue("Post-imputation: found {bad_ds} pharmacy rows with invalid DAY_SUPPLY — imputation logic failed."))
}

# The Optum engine's MAP state machine, unchanged: MMA_MED_PROCESSED and the
# cohort in, MAP_STACKED out.
phase_map <- function(con, ctx) {


  # STEP 3 (5B): MAP_MED - Medication Available Period algorithm
  #
  # Medical runout rule:
  #   Medical runout date is DATE_SERVICE + DAY_SUPPLY - 1; pushout is not implemented.
  #
  # Pharmacy pushout rules:
  #   - If new pharmacy claim DATE_SERVICE <= current rx_runout:
  #     pushout = rx_runout - DATE_SERVICE + 1
  #     new rx_runout = DATE_SERVICE + DAY_SUPPLY - 1 + pushout
  #   - If new pharmacy claim DATE_SERVICE > current rx_runout
  #     (but still within MAP via med_runout):
  #     rx_runout resets to DATE_SERVICE + DAY_SUPPLY - 1 (no pushout)
  #
  # Medical: always DATE_SERVICE + DAY_SUPPLY - 1 (no pushout ever)
  #
  # MAP boundary: new MAP when DATE_SERVICE > max(rx_runout, med_runout)
  map_struct_type <- "array<struct<MAP_CNT:int,MAP_START_DT:date,MAP_RX_RUNOUT_DT:date,MAP_MED_RUNOUT_DT:date,MAP_END_DT:date>>"
  min_date <- "cast('1900-01-01' as date)"

  run_step(con, "S06_map_med", glue("
    CREATE OR REPLACE TEMPORARY VIEW map_med AS
    -- Stays a view. map_stacked below is its only reader, and that one is
    -- written to a table, so this plan runs once either way.
    WITH claims AS (
      SELECT
        PATID,
        MED_ABBR,
        MED_CLASS,
        DATE_SERVICE AS dt,
        CLAIM_TYPE  AS claim_type,
        cast(DAY_SUPPLY as int) AS ds
      FROM mma_med_processed
    ),
    grouped AS (
      SELECT
        PATID,
        MED_ABBR,
        min(MED_CLASS) AS MED_CLASS,  -- deterministic; should be 1:1 with MED_ABBR via rollup
        -- Sorted by date, then pharmacy before medical on the same date
        -- (type_ord=0 for rx). Pharmacy first on a same-day tie is a choice,
        -- and it is safe: rx pushout depends only on rx_runout, never on
        -- med_runout, and medical has no pushout at all. So the order within a
        -- day distorts neither. The MAP algorithm does not fix a tie-break
        -- order. This one is written down and gives the same answer twice.
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
      SELECT
        PATID,
        MED_ABBR,
        MED_CLASS,
        explode(
          aggregate(
            claims_arr,
            -- Accumulator: current MAP state
            named_struct(
              'map_cnt', 0,
              'cur_start', cast(null as date),
              'rx_runout', cast(null as date),
              'med_runout', cast(null as date),
              'maps', cast(array() as {map_struct_type})
            ),
            -- Merge function: process each claim
            (s, x) -> CASE
              -- CASE 1: First claim ever (no current MAP open)
              WHEN s.cur_start IS NULL THEN
                named_struct(
                  'map_cnt', 1,
                  'cur_start', x.dt,
                  'rx_runout', CASE WHEN x.type='pharmacy' THEN date_add(x.dt, x.ds - 1) ELSE NULL END,
                  'med_runout', CASE WHEN x.type='medical' THEN date_add(x.dt, x.ds - 1) ELSE NULL END,
                  'maps', s.maps
                )
              -- CASE 2: Claim beyond both runouts -> close current MAP, start new
              WHEN x.dt > greatest(coalesce(s.rx_runout, {min_date}), coalesce(s.med_runout, {min_date})) THEN
                named_struct(
                  'map_cnt', s.map_cnt + 1,
                  'cur_start', x.dt,
                  'rx_runout', CASE WHEN x.type='pharmacy' THEN date_add(x.dt, x.ds - 1) ELSE NULL END,
                  'med_runout', CASE WHEN x.type='medical' THEN date_add(x.dt, x.ds - 1) ELSE NULL END,
                  'maps', array_append(
                    s.maps,
                    named_struct(
                      'MAP_CNT', s.map_cnt,
                      'MAP_START_DT', s.cur_start,
                      'MAP_RX_RUNOUT_DT', s.rx_runout,
                      'MAP_MED_RUNOUT_DT', s.med_runout,
                      'MAP_END_DT', greatest(coalesce(s.rx_runout, {min_date}), coalesce(s.med_runout, {min_date}))
                    )
                  )
                )
              -- CASE 3: Claim within current MAP -> update runouts
              ELSE
                named_struct(
                  'map_cnt', s.map_cnt,
                  'cur_start', s.cur_start,
                  -- PHARMACY RUNOUT UPDATE
                  'rx_runout', CASE
                    WHEN x.type='pharmacy' THEN
                      CASE
                        -- First pharmacy claim in this MAP
                        WHEN s.rx_runout IS NULL THEN date_add(x.dt, x.ds - 1)
                        -- Pharmacy claim WITHIN current rx coverage -> PUSHOUT
                        -- pushout = rx_runout - DATE_SERVICE + 1
                        -- new rx_runout = DATE_SERVICE + DS - 1 + pushout = rx_runout + DS
                        WHEN x.dt <= s.rx_runout THEN
                          date_add(s.rx_runout, x.ds)
                        -- Pharmacy claim AFTER rx_runout but still in MAP (via med_runout)
                        -- -> RESET without pushout
                        ELSE
                          date_add(x.dt, x.ds - 1)
                      END
                    -- Not a pharmacy claim: rx_runout unchanged
                    ELSE s.rx_runout
                  END,
                  -- MEDICAL RUNOUT UPDATE
                  -- Pushout is not implemented for medical.
                  -- Always: DATE_SERVICE + DAY_SUPPLY - 1.
                  -- greatest() is a safety belt. If a same-day or
                  -- out-of-order claim gives an earlier runout, the later one
                  -- already there is kept.
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
            -- Finalize: flush the last open MAP
            s -> CASE
              WHEN s.cur_start IS NULL THEN cast(array() as {map_struct_type})
              ELSE array_append(
                s.maps,
                named_struct(
                  'MAP_CNT', s.map_cnt,
                  'MAP_START_DT', s.cur_start,
                  'MAP_RX_RUNOUT_DT', s.rx_runout,
                  'MAP_MED_RUNOUT_DT', s.med_runout,
                  'MAP_END_DT', greatest(coalesce(s.rx_runout, {min_date}), coalesce(s.med_runout, {min_date}))
                )
              )
            END
          )
        ) AS map_rec
      FROM grouped
    ),
    base AS (
      SELECT
        m.PATID,
        m.MED_ABBR,
        m.MED_CLASS,
        map_rec.MAP_CNT           AS MAP_CNT,
        map_rec.MAP_START_DT      AS MAP_START_DT,
        map_rec.MAP_RX_RUNOUT_DT  AS MAP_RX_RUNOUT_DT,
        map_rec.MAP_MED_RUNOUT_DT AS MAP_MED_RUNOUT_DT,
        CASE WHEN map_rec.MAP_END_DT = {min_date} THEN NULL ELSE map_rec.MAP_END_DT END AS MAP_END_DT
      FROM maps m
    ),
    with_next AS (
      SELECT
        b.*,
        lead(MAP_START_DT) OVER (PARTITION BY PATID, MED_ABBR ORDER BY MAP_CNT) AS NEXT_MAP_START_DT
      FROM base b
    )
    SELECT
      w.PATID,
      w.MED_ABBR,
      w.MED_CLASS,
      w.MAP_CNT,
      w.MAP_START_DT,
      w.MAP_RX_RUNOUT_DT,
      w.MAP_MED_RUNOUT_DT,
      w.MAP_END_DT,
      w.MED_ABBR AS MAP_MED_TYPE,
      w.MED_CLASS AS MAP_MED_CLASS,
      CASE
        WHEN w.NEXT_MAP_START_DT IS NOT NULL
          AND datediff(w.NEXT_MAP_START_DT, w.MAP_END_DT) >= {cfg$map_discon_gap_days}
          THEN 1
        WHEN w.NEXT_MAP_START_DT IS NULL
          AND datediff(p.OBS_END_DT, w.MAP_END_DT) >= {cfg$map_discon_gap_days}
          THEN 1
        ELSE 0
      END AS MAP_DISCON_FLG
    FROM with_next w
    INNER JOIN lot_patient_input p ON w.PATID = p.PATID
    WHERE w.MAP_END_DT IS NOT NULL
  "), qc = "
    SELECT
      count(*) AS n_maps,
      count(DISTINCT PATID) AS n_patients,
      count(DISTINCT MED_ABBR) AS n_meds,
      avg(datediff(MAP_END_DT, MAP_START_DT) + 1) AS avg_map_len_days,
      sum(MAP_DISCON_FLG) AS n_discontinuations
    FROM map_med")

  # STEP 4: MAP_STACKED
  #
  # The table every later phase reads, written here because phase_lot1_base
  # reads it four times before phase_lot1_end. Twenty-nine reads over a run.
  materialize(con, "S07_map_stacked", view = "map_stacked", name = "MAP_STACKED", body = "
    SELECT * FROM map_med
  ", qc = "SELECT count(*) AS n_rows FROM map_stacked")

}
