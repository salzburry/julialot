# MM-approved and steroid claims, then the Medication Available Period.

phase_mma_map <- function(con, ctx) {
  meds <- ctx$meds

  # STEP 2 (5A): MMA_MED - Raw extraction
  # Sources: medical (PROC_CD, BILL_PROC_CD, NDC), rx (NDC)
  # Note: med_procedure excluded - PROC holds ICD procedure codes, measured;
  # see source (4) below
  run_step(con, "S04_mma_med_raw", glue("
    CREATE OR REPLACE TEMPORARY VIEW mma_med_raw AS
    WITH codelist AS (
      SELECT /*+ BROADCAST */ * FROM mma_codelist
    ),
    -- 1) Medical claims - PROC_CD (HCPCS)
    -- Day supply hardcoded to {cfg$medical_day_supply}
    med_proc_cd AS (
      SELECT
        m.PATID,
        cast(m.FST_DT AS date) AS DATE_SERVICE,
        {cfg$medical_day_supply} AS DAY_SUPPLY,
        'medical' AS CLAIM_TYPE,
        'med_proc_cd' AS CLAIM_SOURCE,
        c.CL_CODE AS CODE,
        c.CL_CODE_TYPE AS CODE_TYPE,
        c.CL_MED_ABBR AS MED_ABBR,
        c.CL_MED_CLASS AS MED_CLASS
      FROM {cdm_src(cfg$tbl_medical)} m
      INNER JOIN lot_patient_input p ON m.PATID = p.PATID
      INNER JOIN codelist c
        ON c.CL_CODE_TYPE = 'HCPCS'
       AND upper(regexp_replace(coalesce(cast(m.PROC_CD as string),''), '[^A-Za-z0-9]', '')) = c.CL_CODE
      WHERE cast(m.FST_DT AS date) >= p.INDEX_DATE
        AND cast(m.FST_DT AS date) <= p.OBS_END_DT  -- ENDDATE primary; ENDDATE_CE under sensitivity flag
    ),
    -- 2) Medical claims - BILL_PROC_CD (HCPCS)
    med_bill_proc_cd AS (
      SELECT
        m.PATID,
        cast(m.FST_DT AS date) AS DATE_SERVICE,
        {cfg$medical_day_supply} AS DAY_SUPPLY,
        'medical' AS CLAIM_TYPE,
        'med_bill_proc' AS CLAIM_SOURCE,
        c.CL_CODE AS CODE,
        c.CL_CODE_TYPE AS CODE_TYPE,
        c.CL_MED_ABBR AS MED_ABBR,
        c.CL_MED_CLASS AS MED_CLASS
      FROM {cdm_src(cfg$tbl_medical)} m
      INNER JOIN lot_patient_input p ON m.PATID = p.PATID
      INNER JOIN codelist c
        ON c.CL_CODE_TYPE = 'HCPCS'
       AND upper(regexp_replace(coalesce(cast(m.BILL_PROC_CD as string),''), '[^A-Za-z0-9]', '')) = c.CL_CODE
      WHERE cast(m.FST_DT AS date) >= p.INDEX_DATE
        AND cast(m.FST_DT AS date) <= p.OBS_END_DT  -- ENDDATE primary; ENDDATE_CE under sensitivity flag
    ),
    -- 3) Medical claims - NDC field (NDC-coded drug administrations on medical)
    med_ndc AS (
      SELECT
        m.PATID,
        cast(m.FST_DT AS date) AS DATE_SERVICE,
        {cfg$medical_day_supply} AS DAY_SUPPLY,
        'medical' AS CLAIM_TYPE,
        'med_ndc' AS CLAIM_SOURCE,
        c.CL_CODE AS CODE,
        c.CL_CODE_TYPE AS CODE_TYPE,
        c.CL_MED_ABBR AS MED_ABBR,
        c.CL_MED_CLASS AS MED_CLASS
      FROM {cdm_src(cfg$tbl_medical)} m
      INNER JOIN lot_patient_input p ON m.PATID = p.PATID
      INNER JOIN codelist c
        ON c.CL_CODE_TYPE = 'NDC'
       -- Normalize both sides to NDC11 (lpad stripped value to 11 digits with zeros)
       -- Without this a codelist NDC with no digits pads to eleven zeros, and
       -- so does a claim with no NDC: every such claim becomes a treatment.
       AND regexp_replace(c.CL_CODE, '[^0-9]', '') <> ''
       -- ...and the claim side. The WHERE below only tests the raw value, so a
       -- punctuation-only NDC passes it and still normalizes to eleven zeros.
       AND {ndc_key('m.NDC')}
         = lpad(regexp_replace(c.CL_CODE, '[^0-9]', ''), 11, '0')
      WHERE cast(m.NDC as string) IS NOT NULL AND trim(cast(m.NDC as string)) <> ''
        AND cast(m.FST_DT AS date) >= p.INDEX_DATE
        AND cast(m.FST_DT AS date) <= p.OBS_END_DT  -- ENDDATE primary; ENDDATE_CE under sensitivity flag
    ),
    -- 4) med_procedure is not a drug source: its PROC column holds ICD
    -- procedure codes, and the MMA code list is HCPCS and NDC.
    --
    -- Measured, because med_procedure.PROC is named among
    -- the tables joined to CL_MMA_CODELIST and Optum's business rules say PROC
    -- can carry a drug given as a procedure under HCPCS/CPT. Neither holds
    -- here. Profiling PROC over the study period returns 43.1M of ~43.2M rows
    -- at ICD_FLAG=10 and seven characters, which is ICD-10-PCS. The whole
    -- five-character tail is ~15k rows, 0.035%, and its values are things like
    -- 00002 and ERHOS - malformed, not J-codes. Reading this table would add
    -- no MM therapy claim.
    -- 5) Pharmacy (rx) claims (NDC)
    rx_claims AS (
      SELECT
        r.PATID,
        cast(r.FILL_DT AS date) AS DATE_SERVICE,
        cast(r.DAYS_SUP AS int) AS DAY_SUPPLY,
        'pharmacy' AS CLAIM_TYPE,
        'rx_ndc' AS CLAIM_SOURCE,
        c.CL_CODE AS CODE,
        c.CL_CODE_TYPE AS CODE_TYPE,
        c.CL_MED_ABBR AS MED_ABBR,
        c.CL_MED_CLASS AS MED_CLASS
      FROM {cdm_src(cfg$tbl_rx)} r
      INNER JOIN lot_patient_input p ON r.PATID = p.PATID
      INNER JOIN codelist c
        ON c.CL_CODE_TYPE = 'NDC'
       -- Normalize both sides to NDC11 (lpad stripped value to 11 digits with zeros)
       -- Same guard as the medical NDC join above. The Rx path has no other
       -- claim-side filter, so an unguarded blank code reaches every fill.
       AND regexp_replace(c.CL_CODE, '[^0-9]', '') <> ''
       -- The Rx branch has no WHERE on NDC at all, so without this a missing
       -- fill NDC becomes eleven zeros and matches an all-zero code list row.
       AND {ndc_key('r.NDC')}
         = lpad(regexp_replace(c.CL_CODE, '[^0-9]', ''), 11, '0')
      WHERE cast(r.FILL_DT AS date) >= p.INDEX_DATE
        AND cast(r.FILL_DT AS date) <= p.OBS_END_DT  -- ENDDATE primary; ENDDATE_CE under sensitivity flag
    )
    SELECT * FROM med_proc_cd
    UNION ALL SELECT * FROM med_bill_proc_cd
    UNION ALL SELECT * FROM med_ndc
    UNION ALL SELECT * FROM rx_claims
  "), qc = "
    SELECT
      count(*) AS n_rows,
      count(DISTINCT PATID) AS n_patients,
      count(DISTINCT MED_ABBR) AS n_meds,
      sum(case when CLAIM_TYPE='pharmacy' then 1 else 0 end) AS n_pharmacy_rows,
      sum(case when CLAIM_TYPE='medical' then 1 else 0 end) AS n_medical_rows,
      -- Confirms each source path is actually contributing claims.
      sum(case when CLAIM_SOURCE='med_proc_cd' then 1 else 0 end) AS n_from_proc_cd,
      sum(case when CLAIM_SOURCE='med_bill_proc' then 1 else 0 end) AS n_from_bill_proc,
      sum(case when CLAIM_SOURCE='med_ndc' then 1 else 0 end) AS n_from_med_ndc,
      sum(case when CLAIM_SOURCE='rx_ndc' then 1 else 0 end) AS n_from_rx_ndc
    FROM mma_med_raw")

  # Enrich + dedup.
  #
  # Written to a table rather than left as a view. mma_med_raw beneath it is
  # the four-arm scan of `medical` and `rx` above, and this is read six times
  # over the run - map_med, the imputation check below, phase_qc's coverage
  # table, and the two counts in phase_persist. Left lazy that is six passes
  # over the raw claim tables for one extraction.
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
      -- Pharmacy claims
      -- with missing or anomalous DAY_SUPPLY should be imputed to 28, not dropped.
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
      -- Dedup: within (PATID, MED_ABBR, DATE_SERVICE, CLAIM_TYPE)
      -- keep max DAY_SUPPLY (pharmacy) or single row (medical, all 28)
      SELECT
        PATID,
        MED_ABBR,
        DATE_SERVICE,
        CLAIM_TYPE,
        max(DAY_SUPPLY) AS DAY_SUPPLY,
        -- Deterministic dedup: min() for reproducibility across runs
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

  # Sanity check: after imputation, no pharmacy rows should have invalid DAY_SUPPLY
  bad_ds <- db_q(con, "SELECT count(*) AS n_bad FROM mma_med_processed WHERE CLAIM_TYPE='pharmacy' AND (DAY_SUPPLY IS NULL OR DAY_SUPPLY < 1)")$n_bad
  if (bad_ds > 0) stop(glue("Post-imputation: found {bad_ds} pharmacy rows with invalid DAY_SUPPLY — imputation logic failed."))


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
    -- Stays a view: map_stacked below is its only reader, and that one is
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
        -- Sort: by date, then pharmacy before medical on same date (type_ord=0 for rx).
        -- Design choice: pharmacy processed first on same-day ties. This is safe because:
        --   rx pushout only depends on rx_runout (not med_runout),
        --   and medical never has pushout, so order on same day doesn't distort either.
        -- The MAP algorithm doesn't mandate tie-break order; this choice is documented and deterministic.
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
                  -- greatest() is a safety belt: if a same-day or out-of-order claim
                  -- produces an earlier runout, we keep the existing later one.
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

  # STEP 5: MAP_PREV
  #
  # map_stacked with each row's preceding same-agent episode attached. Every
  # boundary query reads this rather than carrying its own lag(). See
  # engine/R/map_prev.R.
  materialize(con, "S08_map_prev", view = "map_prev", name = "MAP_PREV",
              body = map_prev_sql("map_stacked"),
              qc = "
    SELECT
      count(*) AS n_rows,
      sum(CASE WHEN PREV_DISCON_FLG IS NULL THEN 1 ELSE 0 END) AS n_first_episodes,
      sum(CASE WHEN PREV_DISCON_FLG = 1 THEN 1 ELSE 0 END) AS n_after_discon,
      sum(CASE WHEN PREV_DISCON_FLG = 0 THEN 1 ELSE 0 END) AS n_after_short_gap
    FROM map_prev")

}
