# ============================================================
# cyclo_appendix_lot.R — CYCLO monotherapy deep-dive (optional appendix)
# ============================================================
# Extracted from print_descriptives() during modularization.
# This is a specialized cohort-specific analysis for cyclophosphamide
# monotherapy patients. It writes standalone CSVs and is not part
# of the core LOT derivation.
# Requires: cfg, run_id, log_msg, db_q, wrk (from other modules)
# ============================================================

run_cyclo_deepdive <- function(con) {
  # --------------------------------------------------------
  # 11. CYCLO Monotherapy Deep-Dive (separate output files)
  # Writes to {output_dir}/cyclo_mono/ as standalone CSVs.
  #
  # Two cohort definitions produced:
  #   STRICT:           LOT1_BASE_MEDS = 'CYCL', LOT1_MED_CNT = 1
  #   STEROID-TOLERANT: only non-steroid induction med is CYCLO
  #                     (allows CYCLO + DEXA/PRED etc.)
  #
  # Outputs:
  # (1) 3 possible diagnosis dates under 30/60/90-day OP windows
  # (2) subsequent non-CYCLO non-steroid MM treatments
  # (3) SCT timing relative to CYCLO start AND all 3 dx dates
  # --------------------------------------------------------
  tryCatch({
    # CAST PATID AS STRING in every query below — some ODBC drivers return
    # the CDM PATID (BIGINT) as R numeric, which corrupts IDs into
    # subnormal floats (~1e-313) and breaks both IN-list builds and
    # roster CSVs. Forcing stringification at the warehouse is the only
    # robust fix; doing it at R side after the fact is too late.

    # --- Cohort A: Strict CYCLO monotherapy (no steroids) ---
    cyclo_strict <- db_q(con, "
      SELECT CAST(lb.PATID AS STRING) AS PATID,
             lb.INDEX_DATE, lb.LOT1_START_DT, lb.LOT1_BASE_MEDS,
             lb.LOT1_BASE_DISCON_DT, lb.LOT1_BASE_LENGTH, lb.LOT1_MED_CNT,
             lb.OBS_END_DT, lb.DEATH_DT, lb.GDR_CD, lb.AGE_INDEX_YR,
             'STRICT' AS COHORT_DEF
      FROM lot1_base_end lb
      WHERE lb.LOT1_BASE_MEDS = 'CYCL'
        AND lb.LOT1_MED_CNT = 1
    ")

    # --- Cohort B: Steroid-tolerant CYCLO monotherapy ---
    # Only non-steroid induction med is CYCLO (steroids allowed alongside)
    cyclo_steroid_tol <- db_q(con, glue("
      WITH induction_meds AS (
        SELECT DISTINCT
          ms.PATID,
          ms.MAP_MED_TYPE AS MED_ABBR,
          ms.MAP_MED_CLASS AS MED_CLASS
        FROM map_stacked ms
        INNER JOIN lot1_start l1 ON ms.PATID = l1.PATID
        WHERE ms.MAP_START_DT >= l1.LOT1_START_DT
          AND ms.MAP_START_DT <= date_add(l1.LOT1_START_DT, {cfg$induction_window_days - 1})
      ),
      non_steroid_summary AS (
        SELECT
          PATID,
          count(DISTINCT CASE WHEN MED_CLASS <> 'STEROID' THEN MED_ABBR END) AS N_NONSTEROID,
          max(CASE WHEN MED_CLASS <> 'STEROID' AND MED_ABBR = 'CYCL' THEN 1 ELSE 0 END) AS HAS_CYCLO
        FROM induction_meds
        GROUP BY PATID
      )
      SELECT CAST(lb.PATID AS STRING) AS PATID,
             lb.INDEX_DATE, lb.LOT1_START_DT, lb.LOT1_BASE_MEDS,
             lb.LOT1_BASE_DISCON_DT, lb.LOT1_BASE_LENGTH, lb.LOT1_MED_CNT,
             lb.OBS_END_DT, lb.DEATH_DT, lb.GDR_CD, lb.AGE_INDEX_YR,
             'STEROID_TOLERANT' AS COHORT_DEF
      FROM lot1_base_end lb
      INNER JOIN non_steroid_summary ns ON lb.PATID = ns.PATID
      WHERE ns.N_NONSTEROID = 1
        AND ns.HAS_CYCLO = 1
    "))

    n_strict  <- nrow(cyclo_strict)
    n_steroid <- nrow(cyclo_steroid_tol)
    log_msg("  CYCLO monotherapy — strict: ", n_strict,
            ", steroid-tolerant: ", n_steroid,
            " (delta: ", n_steroid - n_strict, " patients with CYCLO + steroid)")

    # Use steroid-tolerant as the primary cohort (most common clinical interpretation)
    cyclo_pats <- cyclo_steroid_tol
    n_cyclo    <- n_steroid

    if (n_cyclo > 0) {
      cyclo_dir <- file.path(cfg$output_dir, "cyclo_mono")
      dir.create(cyclo_dir, showWarnings = FALSE, recursive = TRUE)

      # Write both rosters
      write.csv(cyclo_strict, file.path(cyclo_dir, "cyclo_mono_patients_strict.csv"), row.names = FALSE)
      write.csv(cyclo_steroid_tol, file.path(cyclo_dir, "cyclo_mono_patients_steroid_tolerant.csv"), row.names = FALSE)
      log_msg("  Wrote: cyclo_mono_patients_strict.csv (N=", n_strict,
              "), cyclo_mono_patients_steroid_tolerant.csv (N=", n_steroid, ")")

      # PATID is CAST AS STRING in the cohort queries above — driver delivers
      # as R character, no extra coercion needed.
      pat_ids_sql <- paste0("('", paste(cyclo_pats$PATID, collapse = "','"), "')")

      # --- (1) Three possible diagnosis dates (30/60/90-day OP windows) ---
      allflags_tbl <- tryCatch({
        tbl_name <- wrk("ELIG_COH_ALLFLAGS")
        test <- db_q(con, glue("SELECT 1 FROM {tbl_name} LIMIT 1"))
        tbl_name
      }, error = function(e) NULL)

      if (!is.null(allflags_tbl)) {
        dx_dates <- db_q(con, glue("
          WITH window_dates AS (
            SELECT
              CAST(af.PATID AS STRING) AS PATID,
              min(CASE WHEN af.inpt_qual = 1 OR af.outpt2_30 = 1
                       THEN af.INDEX_DATE END) AS DX_DT_30,
              min(CASE WHEN af.inpt_qual = 1 OR af.outpt2_60 = 1
                       THEN af.INDEX_DATE END) AS DX_DT_60,
              min(CASE WHEN af.inpt_qual = 1 OR af.outpt2_90 = 1
                       THEN af.INDEX_DATE END) AS DX_DT_90
            FROM {allflags_tbl} af
            WHERE CAST(af.PATID AS STRING) IN {pat_ids_sql}
            GROUP BY CAST(af.PATID AS STRING)
          ),
          with_lot1 AS (
            SELECT
              w.PATID,
              lb.LOT1_START_DT AS CYCLO_START_DT,
              w.DX_DT_30,
              w.DX_DT_60,
              w.DX_DT_90,
              datediff(lb.LOT1_START_DT, w.DX_DT_30) AS DAYS_DX30_TO_CYCLO,
              datediff(lb.LOT1_START_DT, w.DX_DT_60) AS DAYS_DX60_TO_CYCLO,
              datediff(lb.LOT1_START_DT, w.DX_DT_90) AS DAYS_DX90_TO_CYCLO,
              datediff(w.DX_DT_30, w.DX_DT_60) AS DIFF_60v30,
              datediff(w.DX_DT_30, w.DX_DT_90) AS DIFF_90v30
            FROM window_dates w
            INNER JOIN lot1_base lb ON w.PATID = CAST(lb.PATID AS STRING)
          )
          SELECT * FROM with_lot1 ORDER BY PATID
        "))

        if (nrow(dx_dates) > 0) {
          write.csv(dx_dates, file.path(cyclo_dir, "cyclo_mono_dx_dates.csv"), row.names = FALSE)

          # Summary stats
          n_same_all   <- sum(!is.na(dx_dates$DX_DT_30) & !is.na(dx_dates$DX_DT_90) &
                              dx_dates$DX_DT_30 == dx_dates$DX_DT_90, na.rm = TRUE)
          n_diff_30v90 <- sum(!is.na(dx_dates$DIFF_90v30) & dx_dates$DIFF_90v30 != 0, na.rm = TRUE)
          n_only_90    <- sum(is.na(dx_dates$DX_DT_30) & !is.na(dx_dates$DX_DT_90), na.rm = TRUE)
          n_only_60    <- sum(is.na(dx_dates$DX_DT_30) & !is.na(dx_dates$DX_DT_60), na.rm = TRUE)

          dx_summary <- data.frame(
            Metric = c("Total CYCLO mono patients (steroid-tolerant)",
                        "Same dx date under all windows",
                        "Different date: 30d vs 90d window",
                        "Qualify under 90d but NOT 30d",
                        "Qualify under 60d but NOT 30d"),
            N = c(n_cyclo, n_same_all, n_diff_30v90, n_only_90, n_only_60),
            stringsAsFactors = FALSE
          )
          if (any(!is.na(dx_dates$DIFF_90v30) & dx_dates$DIFF_90v30 != 0)) {
            shifted <- dx_dates[!is.na(dx_dates$DIFF_90v30) & dx_dates$DIFF_90v30 != 0, ]
            dx_summary <- rbind(dx_summary, data.frame(
              Metric = c("Mean shift 90d vs 30d (days)",
                          "Median shift 90d vs 30d (days)"),
              N = c(round(mean(as.numeric(shifted$DIFF_90v30), na.rm = TRUE), 1),
                    round(median(as.numeric(shifted$DIFF_90v30), na.rm = TRUE), 0)),
              stringsAsFactors = FALSE
            ))
          }
          write.csv(dx_summary, file.path(cyclo_dir, "cyclo_mono_dx_summary.csv"), row.names = FALSE)
          log_msg("  Wrote: cyclo_mono_dx_dates.csv, cyclo_mono_dx_summary.csv")
        }
      } else {
        log_msg("  WARN: ELIG_COH_ALLFLAGS not found; skipping diagnosis date sensitivity.")
      }

      # --- (2) Subsequent MM treatments post-CYCLO initiation ---
      # Excludes both CYCLO itself and steroids (non-anti-MM supportive)
      post_cyclo_tx <- db_q(con, glue("
        SELECT
          CAST(ms.PATID AS STRING) AS PATID,
          ms.MAP_MED_TYPE AS MED,
          ms.MAP_MED_CLASS AS CLASS,
          ms.MAP_START_DT,
          ms.MAP_END_DT,
          datediff(ms.MAP_END_DT, ms.MAP_START_DT) + 1 AS MAP_DAYS,
          lb.LOT1_START_DT AS CYCLO_START_DT,
          datediff(ms.MAP_START_DT, lb.LOT1_START_DT) AS DAYS_FROM_CYCLO_START,
          ms.MAP_CNT
        FROM map_stacked ms
        INNER JOIN lot1_base lb
          ON ms.PATID = lb.PATID
        WHERE CAST(lb.PATID AS STRING) IN {pat_ids_sql}
          AND ms.MAP_MED_TYPE <> 'CYCL'
          AND ms.MAP_MED_CLASS <> 'STEROID'
          AND ms.MAP_START_DT > lb.LOT1_START_DT
        ORDER BY ms.PATID, ms.MAP_START_DT
      "))

      if (nrow(post_cyclo_tx) > 0) {
        write.csv(post_cyclo_tx, file.path(cyclo_dir, "cyclo_mono_subsequent_tx_detail.csv"), row.names = FALSE)

        post_tx_summary <- db_q(con, glue("
          WITH post AS (
            SELECT
              CAST(ms.PATID AS STRING) AS PATID,
              ms.MAP_MED_TYPE AS MED, ms.MAP_MED_CLASS AS CLASS,
              min(ms.MAP_START_DT) AS FIRST_TX_START_DT,
              datediff(min(ms.MAP_START_DT), lb.LOT1_START_DT) AS DAYS_FROM_CYCLO
            FROM map_stacked ms
            INNER JOIN lot1_base lb ON ms.PATID = lb.PATID
            WHERE CAST(lb.PATID AS STRING) IN {pat_ids_sql}
              AND ms.MAP_MED_TYPE <> 'CYCL'
              AND ms.MAP_MED_CLASS <> 'STEROID'
              AND ms.MAP_START_DT > lb.LOT1_START_DT
            GROUP BY ms.PATID, ms.MAP_MED_TYPE, ms.MAP_MED_CLASS, lb.LOT1_START_DT
          )
          SELECT MED, CLASS,
                 count(DISTINCT PATID) AS n_patients,
                 avg(DAYS_FROM_CYCLO) AS avg_days_from_cyclo,
                 min(DAYS_FROM_CYCLO) AS min_days,
                 percentile_approx(DAYS_FROM_CYCLO, 0.25) AS p25_days,
                 percentile_approx(DAYS_FROM_CYCLO, 0.5) AS median_days,
                 percentile_approx(DAYS_FROM_CYCLO, 0.75) AS p75_days,
                 max(DAYS_FROM_CYCLO) AS max_days
          FROM post
          GROUP BY MED, CLASS
          ORDER BY count(DISTINCT PATID) DESC
        "))
        write.csv(post_tx_summary, file.path(cyclo_dir, "cyclo_mono_subsequent_tx_summary.csv"), row.names = FALSE)
        log_msg("  Wrote: cyclo_mono_subsequent_tx_detail.csv, cyclo_mono_subsequent_tx_summary.csv")
      } else {
        log_msg("  No subsequent (non-CYCLO, non-steroid) treatments found.")
      }

      # --- (3) SCT timing relative to CYCLO start AND all 3 dx dates ---
      # Build SCT query; if allflags available, include DX_DT_30/60/90 offsets
      sct_dx_cols <- ""
      sct_dx_join <- ""
      if (!is.null(allflags_tbl)) {
        sct_dx_join <- glue("
          LEFT JOIN (
            SELECT CAST(PATID AS STRING) AS PATID,
              min(CASE WHEN inpt_qual = 1 OR outpt2_30 = 1 THEN INDEX_DATE END) AS DX_DT_30,
              min(CASE WHEN inpt_qual = 1 OR outpt2_60 = 1 THEN INDEX_DATE END) AS DX_DT_60,
              min(CASE WHEN inpt_qual = 1 OR outpt2_90 = 1 THEN INDEX_DATE END) AS DX_DT_90
            FROM {allflags_tbl}
            WHERE CAST(PATID AS STRING) IN {pat_ids_sql}
            GROUP BY CAST(PATID AS STRING)
          ) dx ON CAST(sct.PATID AS STRING) = dx.PATID")
        sct_dx_cols <- ",
          dx.DX_DT_30, dx.DX_DT_60, dx.DX_DT_90,
          CASE WHEN sct.LOT1_1ST_SCT_DT IS NOT NULL
            THEN datediff(sct.LOT1_1ST_SCT_DT, dx.DX_DT_30) END AS DAYS_DX30_TO_SCT,
          CASE WHEN sct.LOT1_1ST_SCT_DT IS NOT NULL
            THEN datediff(sct.LOT1_1ST_SCT_DT, dx.DX_DT_60) END AS DAYS_DX60_TO_SCT,
          CASE WHEN sct.LOT1_1ST_SCT_DT IS NOT NULL
            THEN datediff(sct.LOT1_1ST_SCT_DT, dx.DX_DT_90) END AS DAYS_DX90_TO_SCT"
      }

      cyclo_sct <- db_q(con, glue("
        SELECT
          CAST(sct.PATID AS STRING) AS PATID,
          lb.LOT1_START_DT AS CYCLO_START_DT,
          sct.LOT1_TX_AUTO_DT_1,
          sct.LOT1_TX_AUTO_DT_2,
          sct.FIRST_ALLO_DT,
          sct.FIRST_CART_DT,
          sct.LOT1_1ST_SCT_DT,
          sct.LOT1_TX_ENDDATE,
          sct.LOT1_TX_ENDDATE_REASON,
          sct.LOT1_SCT_AUTO_TAND_FLG,
          sct.LOT1_SCT_AUTO_SING_FLG,
          CASE WHEN sct.LOT1_1ST_SCT_DT IS NOT NULL
            THEN datediff(sct.LOT1_1ST_SCT_DT, lb.LOT1_START_DT)
          END AS DAYS_CYCLO_TO_SCT
          {sct_dx_cols}
        FROM lot1_sct sct
        INNER JOIN lot1_base lb ON sct.PATID = lb.PATID
        {sct_dx_join}
        WHERE CAST(lb.PATID AS STRING) IN {pat_ids_sql}
        ORDER BY sct.PATID
      "))

      n_with_sct <- sum(!is.na(cyclo_sct$LOT1_1ST_SCT_DT))
      log_msg("  CYCLO patients with SCT: ", n_with_sct, " / ", n_cyclo)

      write.csv(cyclo_sct, file.path(cyclo_dir, "cyclo_mono_sct_detail.csv"), row.names = FALSE)

      # SCT summary
      sct_summary <- data.frame(
        Metric = c("Total CYCLO mono patients (steroid-tolerant)",
                    "With any SCT", "Pct with SCT"),
        Value = c(n_cyclo, n_with_sct, paste0(round(100 * n_with_sct / n_cyclo, 1), "%")),
        stringsAsFactors = FALSE
      )
      if (n_with_sct > 0) {
        sct_with <- cyclo_sct[!is.na(cyclo_sct$LOT1_1ST_SCT_DT), ]
        n_auto <- sum(!is.na(sct_with$LOT1_TX_AUTO_DT_1))
        n_allo <- sum(!is.na(sct_with$FIRST_ALLO_DT))
        n_cart <- sum(!is.na(sct_with$FIRST_CART_DT))
        n_tand <- sum(sct_with$LOT1_SCT_AUTO_TAND_FLG == 1, na.rm = TRUE)
        sct_summary <- rbind(sct_summary, data.frame(
          Metric = c("AUTO SCT", "ALLO SCT", "CART", "Tandem AUTO",
                      "Mean days CYCLO start -> 1st SCT",
                      "Median days CYCLO start -> 1st SCT"),
          Value = c(n_auto, n_allo, n_cart, n_tand,
                    round(mean(as.numeric(sct_with$DAYS_CYCLO_TO_SCT), na.rm = TRUE), 1),
                    round(median(as.numeric(sct_with$DAYS_CYCLO_TO_SCT), na.rm = TRUE), 0)),
          stringsAsFactors = FALSE
        ))
        # Add per-window dx-to-SCT timing if available
        if ("DAYS_DX30_TO_SCT" %in% names(sct_with)) {
          sct_summary <- rbind(sct_summary, data.frame(
            Metric = c("Mean days Dx(30d) -> 1st SCT",
                        "Median days Dx(30d) -> 1st SCT",
                        "Mean days Dx(60d) -> 1st SCT",
                        "Median days Dx(60d) -> 1st SCT",
                        "Mean days Dx(90d) -> 1st SCT",
                        "Median days Dx(90d) -> 1st SCT"),
            Value = c(round(mean(as.numeric(sct_with$DAYS_DX30_TO_SCT), na.rm = TRUE), 1),
                      round(median(as.numeric(sct_with$DAYS_DX30_TO_SCT), na.rm = TRUE), 0),
                      round(mean(as.numeric(sct_with$DAYS_DX60_TO_SCT), na.rm = TRUE), 1),
                      round(median(as.numeric(sct_with$DAYS_DX60_TO_SCT), na.rm = TRUE), 0),
                      round(mean(as.numeric(sct_with$DAYS_DX90_TO_SCT), na.rm = TRUE), 1),
                      round(median(as.numeric(sct_with$DAYS_DX90_TO_SCT), na.rm = TRUE), 0)),
            stringsAsFactors = FALSE
          ))
        }
      }
      write.csv(sct_summary, file.path(cyclo_dir, "cyclo_mono_sct_summary.csv"), row.names = FALSE)
      log_msg("  Wrote: cyclo_mono_sct_detail.csv, cyclo_mono_sct_summary.csv")
      log_msg("  CYCLO monotherapy output directory: ", cyclo_dir)
    } else {
      log_msg("  No CYCLO monotherapy patients found in LOT1 (either definition).")
    }
  }, error = function(e) {
    log_msg("WARN: CYCLO monotherapy analysis failed: ", conditionMessage(e))
  })
}
