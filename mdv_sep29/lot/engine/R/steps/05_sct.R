# Stem cell transplant: AUTO, ALLO and CAR-T, from MDV.
#
# Split the way lot/PORTING.md says this file has to be: phase_sct_extract()
# reads MDV and writes SCT_CLAIMS_RAW; phase_sct_cluster() is the Optum
# build's AUTO clustering and ALLO/CAR-T ordering, unchanged, and reads only
# SCT_CLAIMS_RAW.

phase_sct <- function(con, ctx) {
  phase_sct_extract(con, ctx)
  phase_sct_cluster(con, ctx)
}

# The code types cl_sct_codelist.csv may carry on MDV:
#
#   RECEIPTCODE  an act's receipt code - a transplant procedure (K922, as a
#                receipt code), or a CAR-T product given as a drug
#   NAME_ENG     a drug-master English-name pattern - a CAR-T product,
#                '%vicleucel%'. Drugs only: the master is the drug master.
#   DISEASECODE  a confirmed diagnosis, by MDV disease code
#   ICD10        the same by ICD-10, where the delivery has the column
#
# A diagnosis is dated to the first of its claim month, which is coarse for a
# rule that clusters AUTO dates into 14-day windows; procedure receipt codes
# are the ones to rely on, and a status diagnosis recorded every month after a
# transplant would read as a transplant every month. codelists/README.md.
SCT_CODE_TYPES <- c("RECEIPTCODE", "NAME_ENG", "DISEASECODE", "ICD10")

phase_sct_extract <- function(con, ctx) {
  sct_src <- ctx$sct_src

  # S11: Register the SCT code list, types and SCT_TYPE normalised.
  run_step(con, "S11_sct_codelist", glue("
    CREATE OR REPLACE TEMPORARY VIEW sct_codelist AS
    SELECT DISTINCT CL_CODE_TYPE,
      CASE WHEN CL_CODE_TYPE = 'NAME_ENG' THEN lower(trim(CL_CODE_RAW))
           ELSE {mdv_code_sql('CL_CODE_RAW')} END AS CL_CODE,
      SCT_TYPE
    FROM (
      SELECT
        CASE
          WHEN upper(trim(CL_CODE_TYPE)) IN ('RECEIPTCODE', 'RECEIPT') THEN 'RECEIPTCODE'
          WHEN upper(trim(CL_CODE_TYPE)) IN ('NAME_ENG', 'NAME') THEN 'NAME_ENG'
          WHEN upper(trim(CL_CODE_TYPE)) IN ('DISEASECODE', 'MDVDX') THEN 'DISEASECODE'
          WHEN upper(trim(CL_CODE_TYPE)) IN ('ICD10', 'ICD10DIAG', 'ICD10DX') THEN 'ICD10'
          ELSE upper(trim(CL_CODE_TYPE))
        END AS CL_CODE_TYPE,
        CL_CODE AS CL_CODE_RAW,
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
        -- Normalized, not raw - see mma_codelist. A punctuation-only code
        -- would otherwise match every act with a missing code.
        AND {mdv_code_sql('CL_CODE')} IS NOT NULL
        AND SCT_TYPE IS NOT NULL AND trim(SCT_TYPE) <> ''
    ) t
  "), qc = "SELECT SCT_TYPE, CL_CODE_TYPE, count(*) AS n_codes FROM sct_codelist GROUP BY SCT_TYPE, CL_CODE_TYPE ORDER BY SCT_TYPE, CL_CODE_TYPE")

  # Every act code the list stands for, resolved the way mma_receipts is.
  run_step(con, "S11b_sct_receipts", glue("
    CREATE OR REPLACE TEMPORARY VIEW sct_receipts AS
    WITH m AS ({mdv_drug_select()}
    )
    SELECT DISTINCT s.SCT_TYPE, s.CL_CODE AS CODE, s.CL_CODE AS RECEIPTCODE
    FROM sct_codelist s WHERE s.CL_CODE_TYPE = 'RECEIPTCODE'
    UNION
    SELECT DISTINCT s.SCT_TYPE, s.CL_CODE AS CODE, m.RECEIPTCODE
    FROM sct_codelist s
    INNER JOIN m ON s.CL_CODE_TYPE = 'NAME_ENG' AND m.NAME_ENG LIKE s.CL_CODE
  "), qc = "SELECT SCT_TYPE, count(DISTINCT RECEIPTCODE) AS n_receiptcodes FROM sct_receipts GROUP BY SCT_TYPE ORDER BY SCT_TYPE")

  # A NAME_ENG pattern the inner join above resolved to nothing. Every
  # structural check below passes on it, and the product's acts - CAR-T,
  # mostly - are then never seen, so a line a CAR-T should end or start runs
  # on. A misspelling ('%vicleucell%') is the likely cause; a product not sold
  # in Japan the other. Stops unless waived by name, like unresolved_names on
  # the drug list.
  sct_unresolved <- db_q(con, "
    SELECT s.SCT_TYPE, s.CL_CODE
    FROM sct_codelist s
    LEFT JOIN (SELECT DISTINCT CODE FROM sct_receipts) r ON r.CODE = s.CL_CODE
    WHERE s.CL_CODE_TYPE = 'NAME_ENG' AND r.CODE IS NULL
    ORDER BY s.SCT_TYPE, s.CL_CODE
  ")
  if (nrow(sct_unresolved) > 0) {
    print(sct_unresolved)
    problem <- data.frame(check = "sct_unresolved_names", detail = paste0(
      nrow(sct_unresolved), " SCT NAME_ENG pattern(s) matching no drug in ",
      mdv_tbl("drug"), ": ",
      paste0(sct_unresolved$SCT_TYPE, " '", sct_unresolved$CL_CODE, "'", collapse = ", ")),
      stringsAsFactors = FALSE)
    if (!problem$check %in% codelist_waivers())
      stop(problem$detail, ". Those acts would never be read as transplants or CAR-T. ",
           "Fix the pattern, or name sct_unresolved_names in CODELIST_WAIVERS ",
           "once the study team has read which.", call. = FALSE)
    log_msg("WAIVED (", problem$check, "): ", problem$detail)
    options(lot_waivers_applied = union(getOption("lot_waivers_applied", character(0)),
                                        problem$check))
  } else {
    log_msg("  OK: Every SCT NAME_ENG pattern matches a drug in the master.")
  }

  # DISTINCT covers SCT_TYPE, so one code can still name both AUTO and ALLO,
  # and one act would become two transplants. Asked of the rows and of the
  # receipt codes they resolve to, which is what the act join sees.
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
         " - one act would become several transplants.", call. = FALSE)
  }
  sct_cross <- db_q(con, "
    SELECT RECEIPTCODE, concat_ws(', ', collect_set(SCT_TYPE)) AS types
    FROM sct_receipts
    GROUP BY RECEIPTCODE
    HAVING count(DISTINCT SCT_TYPE) > 1
  ")
  if (nrow(sct_cross) > 0) {
    print(sct_cross)
    stop("Receipt codes the SCT list resolves to more than one transplant ",
         "type: ", paste(sct_cross$RECEIPTCODE, collapse = ", "), call. = FALSE)
  }
  log_msg("  OK: Each SCT code names exactly one transplant type.")

  # The CASE above maps the spellings it knows and passes anything else
  # through unchanged. Only AUTO, ALLO and CART are ever selected from, so an
  # unmapped spelling raises no error - those transplants simply stop existing.
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

  # The same hole on the other arm of the CASE: the extraction reads exactly
  # four code types, and anything else passes through and matches none. The
  # Optum HCPCS and ICD procedure types have no MDV column to meet.
  want <- paste(sprintf("'%s'", SCT_CODE_TYPES), collapse = ", ")
  sct_code_type <- db_q(con, glue("
    SELECT coalesce(CL_CODE_TYPE, '<null>') AS CL_CODE_TYPE, count(*) AS n_codes
    FROM sct_codelist
    WHERE CL_CODE_TYPE IS NULL OR trim(CL_CODE_TYPE) = ''
       OR CL_CODE_TYPE NOT IN ({want})
    GROUP BY coalesce(CL_CODE_TYPE, '<null>')
    ORDER BY CL_CODE_TYPE
  "))
  if (nrow(sct_code_type) > 0) {
    print(sct_code_type)
    stop("SCT code type(s) no MDV extraction reads: ",
         paste(sct_code_type$CL_CODE_TYPE, collapse = ", "),
         " - the MDV list carries ", paste(SCT_CODE_TYPES, collapse = ", "),
         ". Left alone these codes match nothing and the transplant is lost.",
         call. = FALSE)
  }
  n_icd <- db_q(con, "SELECT count(*) AS n FROM sct_codelist WHERE CL_CODE_TYPE = 'ICD10'")$n
  if (isTRUE(n_icd > 0) && !nzchar(MDV_COLS$icd10))
    stop("cl_sct_codelist.csv has ICD10 rows, and MDV_COL_ICD10 is blank, so ",
         "this delivery has no ICD-10 column for them to meet. Name the column ",
         "or give the rows as DISEASECODE.", call. = FALSE)
  log_msg("  OK: Every SCT code type is one an MDV extraction reads.")

  # S12: Extract raw SCT events from the act table and the diagnosis table.
  dx_arm <- function(type, dcol) glue("
      SELECT d.PATID, d.DX_MONTH AS DATE_SERVICE, s.SCT_TYPE,
             s.CL_CODE AS CODE, 'diseasedata' AS SRC
      FROM ({mdv_dx_select()}
      ) d
      INNER JOIN lot_patient_input p ON d.PATID = p.PATID
      INNER JOIN sct_codelist s ON s.CL_CODE_TYPE = '{type}' AND d.{dcol} = s.CL_CODE
      WHERE d.CONFIRMED = 1
        AND d.DX_MONTH >= p.INDEX_DATE
        AND d.DX_MONTH <= p.OBS_END_DT")
  sct_dx_arms <- paste(c(dx_arm("DISEASECODE", "DX_CODE"),
                         if (nzchar(MDV_COLS$icd10)) dx_arm("ICD10", "ICD10")),
                       collapse = "\n      UNION ALL\n")
  run_step(con, "S12_sct_claims_raw", glue("
    CREATE OR REPLACE TEMPORARY VIEW sct_claims_raw AS
    WITH act AS (
      SELECT a.PATID, a.ACT_DT AS DATE_SERVICE, r.SCT_TYPE,
             a.RECEIPTCODE AS CODE, 'actdata' AS SRC
      FROM ({mdv_act_select()}
      ) a
      INNER JOIN lot_patient_input p ON a.PATID = p.PATID
      INNER JOIN sct_receipts r ON r.RECEIPTCODE = a.RECEIPTCODE
      WHERE a.ACT_DT >= p.INDEX_DATE
        AND a.ACT_DT <= p.OBS_END_DT
    ),
    -- Confirmed diagnoses only, dated to the first of the claim month. One
    -- equi-join per code type rather than a join ON a OR b, which Spark cannot
    -- hash and would test every diagnosis in the warehouse against every code.
    dx AS ({sct_dx_arms}
    ),
    combined AS (
      SELECT * FROM act
      UNION ALL SELECT * FROM dx
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
}

# The Optum engine's AUTO clustering and ALLO/CAR-T ordering, unchanged:
# SCT_CLAIMS_RAW in, TX_AUTO_DATES and TX_ALLO_CART_DATES out.
phase_sct_cluster <- function(con, ctx) {

  # SCT detection rules:
  #   - AUTO: 14-day window grouping + 60-day gap + 180-day tandem
  #   - ALLO/CART: simple sequential dates
  #   - ALLO/CART immediately end LOT1
  #   - Single AUTO allowed; tandem pair allowed; excess AUTO ends LOT1
  #
  # Maintenance is a descriptive flag and nothing more - contains_mtx_reg,
  # derived in S16b. There is no maintenance-period view.

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
  # Tandem boundary adjustment. When any claim in a 14-day window is within
  # sct_auto_window_days of the 180-day tandem boundary, measured from the
  # previous finalized TX date - on either side of it, not only across it - take
  # the date closest to the boundary instead of the window's last: min |date -
  # boundary| over the dates in the window. Worked example: TX_AUTO1 =
  # 09MAY2018, the 180-day mark is 05NOV2018, and the window 06NOV-20NOV, wholly
  # past the mark, picks 07NOV rather than 20NOV (LOT_RULES.md 6.1; vignettes
  # auto_seam_straddle, auto_seam_after, auto_seam_far).
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
