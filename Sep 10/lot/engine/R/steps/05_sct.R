# Stem cell transplant: AUTO, ALLO and CAR-T.

phase_sct <- function(con, ctx) {
  sct_src <- ctx$sct_src

  # STEP 7 (SCT): Stem Cell Transplant detection
  # SCT detection rules:
  #   - AUTO: 14-day window grouping + 60-day gap + 180-day tandem
  #   - ALLO/CART: simple sequential dates
  #   - ALLO/CART immediately end LOT1
  #   - Single AUTO allowed; tandem pair allowed; excess AUTO ends LOT1
  #
  # Maintenance is a descriptive flag and nothing more - contains_mtx_reg,
  # derived in S16b. There is no maintenance-period view.

  # S11: Register SCT codelist
  # Normalize CL_CODE_TYPE to canonical values:
  #   ICD10PROC / ICD10PCS            -> 'ICD10PROC' (matches med_procedure.PROC with ICD_FLAG=10)
  #   ICD9PROC                        -> 'ICD9PROC'  (matches med_procedure.PROC with ICD_FLAG=9)
  #   ICD10DIAG / ICD10DX             -> 'ICD10DIAG' (matches med_diagnosis.DIAG with ICD_FLAG=10)
  #   ICD9DIAG / ICD9DX               -> 'ICD9DIAG'  (matches med_diagnosis.DIAG with ICD_FLAG=9)
  #   HCPCS                           -> 'HCPCS'     (matches medical.PROC_CD)
  # Normalize SCT_TYPE: Allogenic->ALLO, Autologous->AUTO, CAR-T->CART
  run_step(con, "S11_sct_codelist", glue("
    CREATE OR REPLACE TEMPORARY VIEW sct_codelist AS
    SELECT DISTINCT
      CASE
        WHEN upper(trim(CL_CODE_TYPE)) IN ('ICD10PROC', 'ICD10PCS') THEN 'ICD10PROC'
        WHEN upper(trim(CL_CODE_TYPE)) = 'ICD9PROC' THEN 'ICD9PROC'
        WHEN upper(trim(CL_CODE_TYPE)) LIKE '%PROC%'
          OR upper(trim(CL_CODE_TYPE)) = 'ICD' THEN 'ICD10PROC'
        WHEN upper(trim(CL_CODE_TYPE)) IN ('ICD10DIAG', 'ICD10DX', 'DIAG10')
          OR upper(trim(CL_CODE_TYPE)) LIKE 'ICD%10%DIAG%' THEN 'ICD10DIAG'
        WHEN upper(trim(CL_CODE_TYPE)) IN ('ICD9DIAG', 'ICD9DX', 'ICD9', 'DIAG9')
          OR upper(trim(CL_CODE_TYPE)) LIKE 'ICD%9%DIAG%' THEN 'ICD9DIAG'
        WHEN upper(trim(CL_CODE_TYPE)) IN ('DIAG', 'DX', 'DIAGNOSIS') THEN 'ICD10DIAG'
        WHEN upper(trim(CL_CODE_TYPE)) IN ('CPT', 'CPT4') THEN 'HCPCS'
        ELSE upper(trim(CL_CODE_TYPE))
      END AS CL_CODE_TYPE,
      upper(regexp_replace(trim(CL_CODE), '[^A-Za-z0-9]', '')) AS CL_CODE,
      CASE
        WHEN upper(trim(SCT_TYPE)) LIKE 'ALLO%' THEN 'ALLO'
        WHEN upper(trim(SCT_TYPE)) LIKE 'AUTO%' THEN 'AUTO'
        WHEN upper(trim(SCT_TYPE)) IN ('CAR-T', 'CART', 'CAR_T') THEN 'CART'
        WHEN upper(trim(SCT_TYPE)) IN ('UNKNOWN', 'UNK', 'OTHER', 'SCT', 'HSCT',
                                        'HCT', 'STEM CELL', 'TRANSPLANT', 'BMT')
          THEN 'UNKNOWN'
        ELSE upper(trim(SCT_TYPE))
      END AS SCT_TYPE
    FROM {sct_src}
    WHERE CL_CODE IS NOT NULL AND trim(CL_CODE) <> ''
      -- Normalized, not raw - see mma_codelist. A punctuation-only code would
      -- otherwise match every claim with a missing procedure or diagnosis.
      AND regexp_replace(CL_CODE, '[^A-Za-z0-9]', '') <> ''
      AND SCT_TYPE IS NOT NULL AND trim(SCT_TYPE) <> ''
  "), qc = "SELECT SCT_TYPE, CL_CODE_TYPE, count(*) AS n_codes FROM sct_codelist GROUP BY SCT_TYPE, CL_CODE_TYPE ORDER BY SCT_TYPE, CL_CODE_TYPE")

  # DISTINCT covers SCT_TYPE, so one code can still name both AUTO and ALLO.
  # The claim extraction keeps a row per type, so one claim becomes two
  # transplants.
  sct_dup <- db_q(con, "
    SELECT CL_CODE_TYPE, CL_CODE, concat_ws(', ', collect_set(SCT_TYPE)) AS types
    FROM sct_codelist
    GROUP BY CL_CODE_TYPE, CL_CODE
    HAVING count(DISTINCT SCT_TYPE) > 1
  ")
  if (nrow(sct_dup) > 0) {
    print(sct_dup)
    stop("SCT codes naming more than one transplant type: ",
         paste(sct_dup$CL_CODE, collapse = ", "),
         " - one claim would become several transplants.", call. = FALSE)
  }
  # The same again ignoring the code type, for the types that share a claim
  # column. The med_procedure join takes ICD10PROC, ICD9PROC or HCPCS against
  # mp.PROC, so one code under two of them matches the same row twice.
  sct_cross <- db_q(con, "
    SELECT CL_CODE, concat_ws(', ', collect_set(CL_CODE_TYPE)) AS code_types,
           concat_ws(', ', collect_set(SCT_TYPE)) AS types
    FROM sct_codelist
    WHERE CL_CODE_TYPE IN ('ICD10PROC', 'ICD9PROC', 'HCPCS')
    GROUP BY CL_CODE
    HAVING count(DISTINCT SCT_TYPE) > 1
  ")
  if (nrow(sct_cross) > 0) {
    print(sct_cross)
    stop("SCT codes naming more than one transplant type across the code ",
         "types that share a claim column: ",
         paste(sct_cross$CL_CODE, collapse = ", "), call. = FALSE)
  }
  log_msg("  OK: Each SCT code names exactly one transplant type.")

  # The CASE above maps the spellings it knows and passes anything else
  # through unchanged. Only AUTO, ALLO and CART are ever selected from, so an
  # unmapped spelling raises no error - those transplants simply stop existing,
  # and no count says so.
  sct_unmapped <- db_q(con, "
    SELECT SCT_TYPE, count(*) AS n_codes
    FROM sct_codelist
    WHERE SCT_TYPE NOT IN ('AUTO', 'ALLO', 'CART', 'UNKNOWN')
    GROUP BY SCT_TYPE
    ORDER BY SCT_TYPE
  ")
  if (nrow(sct_unmapped) > 0) {
    print(sct_unmapped)
    stop("SCT_TYPE value(s) nothing reads: ",
         paste(sct_unmapped$SCT_TYPE, collapse = ", "),
         " - add the spelling to the CASE in S11, or fix the code list. ",
         "Left alone these transplants are dropped silently.", call. = FALSE)
  }
  log_msg("  OK: Every SCT_TYPE is one the build reads.")

  # The same hole on the other arm of the same CASE. The claim joins below read
  # exactly five code types. Anything the CASE does not map passes through and
  # matches none of them. A blank type gets through too: S01 drops those from
  # the MM code list, and this list has no such filter, so the WHERE above
  # guards CL_CODE and SCT_TYPE but not this.
  sct_code_type <- db_q(con, "
    SELECT coalesce(CL_CODE_TYPE, '<null>') AS CL_CODE_TYPE, count(*) AS n_codes
    FROM sct_codelist
    WHERE CL_CODE_TYPE IS NULL
       OR trim(CL_CODE_TYPE) = ''
       OR CL_CODE_TYPE NOT IN ('HCPCS', 'ICD10PROC', 'ICD9PROC',
                               'ICD10DIAG', 'ICD9DIAG')
    GROUP BY coalesce(CL_CODE_TYPE, '<null>')
    ORDER BY CL_CODE_TYPE
  ")
  if (nrow(sct_code_type) > 0) {
    print(sct_code_type)
    stop("SCT code type(s) no extraction reads: ",
         paste(sct_code_type$CL_CODE_TYPE, collapse = ", "),
         " - add the spelling to the CASE in S11, or fix the code list. ",
         "Left alone these codes match nothing and the transplant is lost.",
         call. = FALSE)
  }
  log_msg("  OK: Every SCT code type is one an extraction branch reads.")

  # An ICD-9 code type has to be read as ICD-9. The '%PROC%' arm above catches
  # spellings the exact ICD9PROC test misses, so they arrive as ICD10PROC and
  # the check above accepts them. Asked of the raw value, because these are the
  # only spellings the CASE turns into an ICD-9 type.
  sct_version <- db_q(con, glue("
    SELECT trim(CL_CODE_TYPE) AS CL_CODE_TYPE, count(*) AS n_codes
    FROM {sct_src}
    WHERE regexp_replace(coalesce(CL_CODE_TYPE, ''), '[^0-9]', '') LIKE '%9%'
      AND regexp_replace(coalesce(CL_CODE_TYPE, ''), '[^0-9]', '') NOT LIKE '%10%'
      AND upper(trim(CL_CODE_TYPE)) NOT IN
            ('ICD9PROC', 'ICD9DIAG', 'ICD9DX', 'ICD9', 'DIAG9')
      AND upper(trim(CL_CODE_TYPE)) NOT LIKE 'ICD%9%DIAG%'
    GROUP BY trim(CL_CODE_TYPE)
    ORDER BY CL_CODE_TYPE
  "))
  if (nrow(sct_version) > 0) {
    print(sct_version)
    stop("SCT code type(s) naming ICD-9 that the build will read as ICD-10: ",
         paste(sct_version$CL_CODE_TYPE, collapse = ", "),
         " - spell them ICD9PROC or ICD9DIAG in the code list. Left alone the ",
         "claim join looks in the ICD-10 columns and finds nothing.",
         call. = FALSE)
  }
  log_msg("  OK: Every ICD-9 SCT code type is read as ICD-9.")

  # S12: Extract raw SCT claims from MEDICAL + MED_PROCEDURE
  run_step(con, "S12_sct_claims_raw", glue("
    CREATE OR REPLACE TEMPORARY VIEW sct_claims_raw AS
    WITH sct_codes AS (
      SELECT /*+ BROADCAST */ * FROM sct_codelist
    ),
    -- Medical PROC_CD (contains CPT/HCPCS)
    med_proc AS (
      SELECT m.PATID, cast(m.FST_DT AS date) AS DATE_SERVICE,
             s.SCT_TYPE, s.CL_CODE AS CODE, 'med_proc_cd' AS SRC
      FROM {cdm_src(cfg$tbl_medical)} m
      INNER JOIN lot_patient_input p ON m.PATID = p.PATID
      INNER JOIN sct_codes s
        ON s.CL_CODE_TYPE = 'HCPCS'
       AND upper(regexp_replace(coalesce(cast(m.PROC_CD as string),''), '[^A-Za-z0-9]', '')) = s.CL_CODE
      WHERE cast(m.FST_DT AS date) >= p.INDEX_DATE
        AND cast(m.FST_DT AS date) <= p.OBS_END_DT
    ),
    -- Medical BILL_PROC_CD (also CPT/HCPCS)
    med_bill AS (
      SELECT m.PATID, cast(m.FST_DT AS date) AS DATE_SERVICE,
             s.SCT_TYPE, s.CL_CODE AS CODE, 'med_bill_proc' AS SRC
      FROM {cdm_src(cfg$tbl_medical)} m
      INNER JOIN lot_patient_input p ON m.PATID = p.PATID
      INNER JOIN sct_codes s
        ON s.CL_CODE_TYPE = 'HCPCS'
       AND upper(regexp_replace(coalesce(cast(m.BILL_PROC_CD as string),''), '[^A-Za-z0-9]', '')) = s.CL_CODE
      WHERE cast(m.FST_DT AS date) >= p.INDEX_DATE
        AND cast(m.FST_DT AS date) <= p.OBS_END_DT
    ),
    -- MED_PROCEDURE PROC holds ICD-9 and ICD-10 procedure codes. There is also
    -- an HCPCS branch that matches nothing in this extract, and it is kept.
    --
    -- Profiling PROC over the study period gives 43.1M of 43.2M rows at
    -- ICD_FLAG=10 and seven characters - ICD-10-PCS - with no HCPCS at all. So
    -- the CL_CODE_TYPE='HCPCS' branch below contributes no row here. Every
    -- HCPCS SCT code (CPT 38240/38241, S2150, CAR-T Q2042/Q2054/Q2055/Q2056)
    -- is found by med_proc and med_bill above, which read the columns those
    -- codes live in. It is NOT the safety net it once read as, and nothing
    -- should lean on it.
    --
    -- Left in on purpose. It is one disjunct in a join condition the query
    -- evaluates either way, so it costs no extra scan, and it is right if a
    -- later extract does carry HCPCS there. See ndmm/DECISIONS.md #6.
    medproc AS (
      SELECT mp.PATID, cast(mp.FST_DT AS date) AS DATE_SERVICE,
             s.SCT_TYPE, s.CL_CODE AS CODE, 'med_procedure' AS SRC
      FROM {cdm_src(cfg$tbl_med_proc)} mp
      INNER JOIN lot_patient_input p ON mp.PATID = p.PATID
      INNER JOIN sct_codes s
        ON (  (s.CL_CODE_TYPE = 'ICD10PROC'
               AND coalesce(upper(mp.ICD_FLAG), '') NOT IN ('9', 'ICD9', 'ICD-9'))
           OR (s.CL_CODE_TYPE = 'ICD9PROC'
               AND upper(mp.ICD_FLAG) IN ('9', 'ICD9', 'ICD-9'))
           OR s.CL_CODE_TYPE = 'HCPCS'
           )
       AND upper(regexp_replace(coalesce(cast(mp.PROC as string),''), '[^A-Za-z0-9]', '')) = s.CL_CODE
      WHERE cast(mp.FST_DT AS date) >= p.INDEX_DATE
        AND cast(mp.FST_DT AS date) <= p.OBS_END_DT
    ),
    -- MED_DIAGNOSIS DIAG (ICD-10/ICD-9 diagnosis codes)
    med_diag AS (
      SELECT d.PATID, cast(d.FST_DT AS date) AS DATE_SERVICE,
             s.SCT_TYPE, s.CL_CODE AS CODE, 'med_diagnosis' AS SRC
      FROM {cdm_src(cfg$tbl_med_diag)} d
      INNER JOIN lot_patient_input p ON d.PATID = p.PATID
      INNER JOIN sct_codes s
        ON (  (s.CL_CODE_TYPE = 'ICD10DIAG'
               AND coalesce(upper(d.ICD_FLAG), '') NOT IN ('9', 'ICD9', 'ICD-9'))
           OR (s.CL_CODE_TYPE = 'ICD9DIAG'
               AND upper(d.ICD_FLAG) IN ('9', 'ICD9', 'ICD-9'))
           )
       AND upper(regexp_replace(coalesce(cast(d.DIAG as string),''), '[^A-Za-z0-9]', '')) = s.CL_CODE
      WHERE cast(d.FST_DT AS date) >= p.INDEX_DATE
        AND cast(d.FST_DT AS date) <= p.OBS_END_DT
    ),
    combined AS (
      SELECT * FROM med_proc
      UNION ALL SELECT * FROM med_bill
      UNION ALL SELECT * FROM medproc
      UNION ALL SELECT * FROM med_diag
    )
    -- Dedup to one record per (PATID, DATE_SERVICE, SCT_TYPE).
    SELECT PATID, DATE_SERVICE, SCT_TYPE, min(CODE) AS CODE
    FROM combined
    GROUP BY PATID, DATE_SERVICE, SCT_TYPE
  "), qc = "
    SELECT SCT_TYPE, count(*) AS n_claims, count(DISTINCT PATID) AS n_patients,
           min(DATE_SERVICE) AS min_date, max(DATE_SERVICE) AS max_date
    FROM sct_claims_raw
    GROUP BY SCT_TYPE
    ORDER BY SCT_TYPE")

  # The SCT CTEs carry an SRC column so a row can be traced back. Dedup drops
  # it. To see what each source contributed, query the combined CTE before
  # dedup.


  # S13: AUTO SCT date processing
  #
  # Step 1: group AUTO claims into 14-day windows. A claim joins the window if
  #         it falls 0 to 13 days after the window's first claim
  #         (datediff <= sct_auto_window_days = 13, a 14-day window counting
  #         its first day). Take the LAST date in each window, not the first.
  #         The first claims are workup; the last is the transplant.
  #
  # Tandem boundary adjustment. When a 14-day window straddles the 180-day
  # tandem boundary, measured from the previous finalized TX date, take the date
  # closest to the boundary instead of the window's last: min |date - boundary|
  # over the dates in the window. Worked example: TX_AUTO1 = 09MAY2018, the
  # 180-day mark is 05NOV2018, and the window 06NOV-20NOV picks 07NOV rather
  # than 20NOV.
  #
  # The boundary is prev + sct_tandem_days, the last day that still counts as a
  # tandem, and it has to be the same day the classification uses: every
  # classification site tests datediff(AUTO_DT_2, AUTO_DT_1) <= sct_tandem_days
  # - see 05b_lot1_sct.R and 10_lot2_5_base.R. Aimed one day short, a window
  # across the seam is pulled to the wrong side.
  #
  # Step 2: apply the 60-day minimum gap between events, merging anything
  # closer. The result is the finalized AUTO TX dates per patient.
  run_step(con, "S13_tx_auto_dates", glue("
    CREATE OR REPLACE TEMPORARY VIEW tx_auto_dates AS
    WITH auto_dates AS (
      SELECT DISTINCT PATID, DATE_SERVICE AS dt
      FROM sct_claims_raw
      WHERE SCT_TYPE = 'AUTO'
    ),
    grouped AS (
      SELECT PATID,
             sort_array(collect_list(dt)) AS dates_arr
      FROM auto_dates
      GROUP BY PATID
    ),
    -- Phases 1 and 2 in one pass: 14-day windowing with tandem-aware date
    -- selection, and 60-day gap merging.
    --
    -- State tracks:
    --   tx_dates: finalized TX dates array
    --   cur_start: start of current 14-day window (first date in window)
    --   cur_max_dt: last (max) date in current window (default selection)
    --   cur_boundary_dt: date in window closest to tandem boundary
    --   cur_boundary_dist: abs distance of cur_boundary_dt to tandem boundary
    --   last_tx_dt: last finalized TX date (for tandem boundary + 60-day gap)
    processed AS (
      SELECT PATID,
        aggregate(
          dates_arr,
          named_struct(
            'tx_dates', cast(array() as array<date>),
            'cur_start', cast(null as date),
            'cur_max_dt', cast(null as date),
            'cur_boundary_dt', cast(null as date),
            'cur_boundary_dist', cast(null as int),
            'last_tx_dt', cast(null as date)
          ),
          (s, x) -> CASE
            -- First claim ever: start first window
            WHEN s.cur_start IS NULL THEN
              named_struct(
                'tx_dates', s.tx_dates,
                'cur_start', x,
                'cur_max_dt', x,
                'cur_boundary_dt', cast(null as date),
                'cur_boundary_dist', cast(null as int),
                'last_tx_dt', s.last_tx_dt
              )
            -- Within 14-day window: update max + tandem boundary tracking
            WHEN datediff(x, s.cur_start) <= {cfg$sct_auto_window_days} THEN
              named_struct(
                'tx_dates', s.tx_dates,
                'cur_start', s.cur_start,
                'cur_max_dt', x,  -- x >= cur_max_dt since sorted
                -- Track the date closest to the tandem boundary, but only
                -- when that date is within window_days of it - that is, the
                -- window touches the 180-day mark. Far from the boundary,
                -- cur_boundary_dt stays NULL and coalesce() falls back to the
                -- window's last date.
                'cur_boundary_dt', CASE
                  WHEN s.last_tx_dt IS NULL THEN NULL
                  WHEN abs(datediff(x, date_add(s.last_tx_dt, {cfg$sct_tandem_days})))
                       <= {cfg$sct_auto_window_days}
                   AND (s.cur_boundary_dist IS NULL
                        OR abs(datediff(x, date_add(s.last_tx_dt, {cfg$sct_tandem_days})))
                           < s.cur_boundary_dist)
                    THEN x
                  WHEN s.cur_boundary_dt IS NOT NULL THEN s.cur_boundary_dt
                  ELSE NULL
                END,
                'cur_boundary_dist', CASE
                  WHEN s.last_tx_dt IS NULL THEN NULL
                  WHEN abs(datediff(x, date_add(s.last_tx_dt, {cfg$sct_tandem_days})))
                       <= {cfg$sct_auto_window_days}
                   AND (s.cur_boundary_dist IS NULL
                        OR abs(datediff(x, date_add(s.last_tx_dt, {cfg$sct_tandem_days})))
                           < s.cur_boundary_dist)
                    THEN abs(datediff(x, date_add(s.last_tx_dt, {cfg$sct_tandem_days})))
                  WHEN s.cur_boundary_dist IS NOT NULL THEN s.cur_boundary_dist
                  ELSE NULL
                END,
                'last_tx_dt', s.last_tx_dt
              )
            -- Beyond 14-day window: finalize current window, start new
            ELSE
              -- Pick the date: boundary-closest if the tandem boundary is
              -- active, otherwise the window's last. Then the 60-day gap: keep
              -- it only if it is 60 or more days from last_tx_dt.
              CASE
                WHEN s.last_tx_dt IS NOT NULL
                 AND datediff(
                       coalesce(s.cur_boundary_dt, s.cur_max_dt),
                       s.last_tx_dt
                     ) < {cfg$sct_auto_gap_days}
                THEN
                  -- Too close to the last TX. Drop the window and start a new
                  -- one.
                  named_struct(
                    'tx_dates', s.tx_dates,
                    'cur_start', x,
                    'cur_max_dt', x,
                    -- Start boundary tracking only if x is near the
                    -- boundary.
                    'cur_boundary_dt', CASE
                      WHEN s.last_tx_dt IS NOT NULL
                       AND abs(datediff(x, date_add(s.last_tx_dt, {cfg$sct_tandem_days})))
                           <= {cfg$sct_auto_window_days}
                      THEN x
                      ELSE NULL
                    END,
                    'cur_boundary_dist', CASE
                      WHEN s.last_tx_dt IS NOT NULL
                       AND abs(datediff(x, date_add(s.last_tx_dt, {cfg$sct_tandem_days})))
                           <= {cfg$sct_auto_window_days}
                      THEN abs(datediff(x, date_add(s.last_tx_dt, {cfg$sct_tandem_days})))
                      ELSE NULL
                    END,
                    'last_tx_dt', s.last_tx_dt
                  )
                ELSE
                  -- A real TX. Finalize it and start a new window.
                  named_struct(
                    'tx_dates', array_append(
                      s.tx_dates,
                      coalesce(s.cur_boundary_dt, s.cur_max_dt)
                    ),
                    'cur_start', x,
                    'cur_max_dt', x,
                    -- Start boundary tracking from the TX just finalized.
                    'cur_boundary_dt', CASE
                      WHEN abs(datediff(
                             x,
                             date_add(coalesce(s.cur_boundary_dt, s.cur_max_dt), {cfg$sct_tandem_days})
                           )) <= {cfg$sct_auto_window_days}
                      THEN x
                      ELSE NULL
                    END,
                    'cur_boundary_dist', CASE
                      WHEN abs(datediff(
                             x,
                             date_add(coalesce(s.cur_boundary_dt, s.cur_max_dt), {cfg$sct_tandem_days})
                           )) <= {cfg$sct_auto_window_days}
                      THEN abs(datediff(
                             x,
                             date_add(coalesce(s.cur_boundary_dt, s.cur_max_dt), {cfg$sct_tandem_days})
                           ))
                      ELSE NULL
                    END,
                    'last_tx_dt', coalesce(s.cur_boundary_dt, s.cur_max_dt)
                  )
                END
          END,
          -- Finalize: flush last open window
          s -> CASE
            WHEN s.cur_start IS NULL THEN s.tx_dates
            -- The 60-day gap check, for the last window.
            WHEN s.last_tx_dt IS NOT NULL
             AND datediff(
                   coalesce(s.cur_boundary_dt, s.cur_max_dt),
                   s.last_tx_dt
                 ) < {cfg$sct_auto_gap_days}
            THEN s.tx_dates
            ELSE array_append(
              s.tx_dates,
              coalesce(s.cur_boundary_dt, s.cur_max_dt)
            )
          END
        ) AS tx_dates
      FROM grouped
    ),
    exploded AS (
      SELECT PATID, posexplode(tx_dates) AS (pos, TX_DT)
      FROM processed
    )
    SELECT PATID, pos + 1 AS TX_SEQ, TX_DT
    FROM exploded
  "), qc = "
    SELECT count(*) AS n_auto_tx_events, count(DISTINCT PATID) AS n_patients,
           min(TX_SEQ) AS min_seq, max(TX_SEQ) AS max_seq
    FROM tx_auto_dates")

  # S14: ALLO and CART sequential dates (simple ordering)
  run_step(con, "S14_tx_allo_cart_dates", "
    CREATE OR REPLACE TEMPORARY VIEW tx_allo_cart_dates AS
    WITH allo_dates AS (
      SELECT DISTINCT PATID, DATE_SERVICE AS dt
      FROM sct_claims_raw
      WHERE SCT_TYPE = 'ALLO'
    ),
    cart_dates AS (
      SELECT DISTINCT PATID, DATE_SERVICE AS dt
      FROM sct_claims_raw
      WHERE SCT_TYPE = 'CART'
    ),
    allo_seq AS (
      SELECT PATID, 'ALLO' AS SCT_TYPE, dt AS TX_DT,
             row_number() OVER (PARTITION BY PATID ORDER BY dt) AS TX_SEQ
      FROM allo_dates
    ),
    cart_seq AS (
      SELECT PATID, 'CART' AS SCT_TYPE, dt AS TX_DT,
             row_number() OVER (PARTITION BY PATID ORDER BY dt) AS TX_SEQ
      FROM cart_dates
    )
    SELECT * FROM allo_seq
    UNION ALL
    SELECT * FROM cart_seq
  ", qc = "
    SELECT SCT_TYPE, count(*) AS n_events, count(DISTINCT PATID) AS n_patients
    FROM tx_allo_cart_dates
    GROUP BY SCT_TYPE
    ORDER BY SCT_TYPE")
}
