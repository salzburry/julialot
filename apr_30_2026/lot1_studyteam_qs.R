#!/usr/bin/env Rscript
# Standalone LOT1 study-team questions (forwarded MM LOT1 feedback).
#
#   Rscript lot1_studyteam_qs.R
#
# Answers, against the LOT1 (first-line MM) cohort:
#   Q1  Patients whose 1L regimen contains POMA (pomalidomide):
#       (a) how many have another cancer (+ best-effort type / Kaposi)
#       (b) payer source / Medicare Advantage (best-effort introspection)
#       (c) clinical-trial participation (the study team's "IE criteria 10")
#   Q2  Top 25 1L regimens by calendar year.
#   Q3  Whether the dashboard's auto patient-journey examples are the
#       6-9-meds-at-1L-induction patients from the Sankey (LOT1 Fig 9).
#   Q4  anti-BCMA / Blenrep (belantamab) availability - all lines, not
#       just 1L (epi follow-up: how many Blenrep-treated patients exist).
#
# Reads only persisted work-schema tables (LOT_LONG, ELIG_COH_ALLFLAGS,
# ELIG_COH_FINAL, MAP_STACKED) and the raw CDM; it builds nothing and is
# safe to run any time.
#
# Three honest limits, surfaced in the output rather than hidden:
#  - "Another cancer" (#8) and "clinical trial" (#10) are *exclusion*
#    criteria, so the 1L regimen (LOT_LONG) only exists for patients who
#    survived them. POMA-at-1L is therefore identifiable for delivered
#    patients; for patients excluded on those criteria the 1L regimen
#    cannot be reconstructed here (needs a pipeline re-run + codelists).
#    That blind spot is quantified, not papered over.
#  - Payer/plan is never projected by the pipeline; member_enrollment is
#    introspected at runtime and candidate plan columns are dumped for an
#    analyst to map Medicare Advantage (no guessed column names).
#  - Cancer *type* is not in the persisted flags; this is a guarded raw
#    ICD-10 C-code scan (C90* excluded) - NOT the cohort's other_malig
#    criterion, which uses the tumor-group codelist + a 1-inpatient or
#    2-outpatient confirmation rule. Re-run that step for an authoritative
#    breakdown. CDM tables go through cdm_src() so the quarterly vintage
#    matches the rest of the pipeline (USE_QUARTERLY_TABLES).

.script_dir <- local({
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", args, value = TRUE)
  if (length(file_arg) > 0) {
    return(dirname(normalizePath(sub("^--file=", "", file_arg[1]))))
  }
  for (i in seq_len(sys.nframe())) {
    ofile <- tryCatch(sys.frame(i)$ofile, error = function(e) NULL)
    if (!is.null(ofile)) return(dirname(normalizePath(ofile)))
  }
  getwd()
})

source_dir <- file.path(.script_dir, "R")
if (file.exists(file.path(source_dir, "load_inputs.R"))) {
  source(file.path(source_dir, "load_inputs.R"))
  load_pipeline_inputs(c(.script_dir, dirname(.script_dir)))
}
source(file.path(source_dir, "config_lot.R"))
source(file.path(source_dir, "db_utils_lot.R"))

POMA_TOKEN  <- Sys.getenv("POMA_MED_ABBR", unset = "POMA")
MED_CNT_LO  <- 6L
MED_CNT_HI  <- 9L

main <- function() {
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")

  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  out_dir <- cfg$output_dir
  if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  stamp <- format(Sys.time(), "%Y%m%d_%H%M%S")

  num <- function(x) suppressWarnings(as.numeric(x))
  readable <- function(tbl) isTRUE(tryCatch(
    nrow(db_q(con, glue("SELECT 1 FROM {tbl} LIMIT 1"))) >= 0,
    error = function(e) FALSE))

  write_out <- function(df, tag) {
    if (is.null(df) || nrow(df) == 0) {
      log_msg("  (", tag, ": no rows)")
      return(invisible())
    }
    f <- file.path(out_dir, paste0("lot1_studyteam_qs_", tag, "_", stamp, ".csv"))
    write.csv(df, f, row.names = FALSE)
    log_msg("  wrote ", tag, " -> ", f, " (", nrow(df), " rows)")
  }

  # DESCRIBE-based column discovery so we never hard-code a source schema.
  describe_cols <- function(tbl) {
    d <- tryCatch(db_q(con, glue("DESCRIBE TABLE {tbl}")), error = function(e) NULL)
    if (is.null(d) || !"col_name" %in% names(d)) return(character(0))
    cn <- trimws(as.character(d$col_name))
    cn <- cn[nzchar(cn) & !startsWith(cn, "#")]
    unique(cn)
  }

  lot_long <- wrk("LOT_LONG")
  allflags <- wrk("ELIG_COH_ALLFLAGS")

  log_msg("LOT1 study-team questions - reading ", lot_long)
  if (!readable(lot_long)) {
    stop("Cannot read ", lot_long,
         ". Build the LOT1 stage (lot_program.R) first.")
  }
  have_flags <- readable(allflags)
  if (!have_flags) {
    log_msg("WARNING: ", allflags, " not readable. It is a pipeline ",
            "checkpoint - ensure the cohort pipeline materialized it to the ",
            "work/personal schema. Q1a/Q1c flag breakdowns will be skipped.")
  }

  # ---- POMA-at-1L base set (delivered cohort) -------------------------
  poma <- db_q(con, glue("
    SELECT cast(PATID as string)               AS PATID,
           LOT_BASE_MEDS,
           cast(LOT_MED_CNT as int)            AS LOT_MED_CNT,
           cast(cast(LOT_START_DT as date) as string) AS LOT_START_DT,
           LOT_BASE_END_REASON
    FROM {lot_long}
    WHERE LOT_NUM = 1
      AND LOT_BASE_MEDS IS NOT NULL
      AND array_contains(split(LOT_BASE_MEDS, ' '), '{POMA_TOKEN}')
  "))
  n_poma <- length(unique(poma$PATID))
  n_lot1 <- num(db_q(con, glue(
    "SELECT count(DISTINCT PATID) n FROM {lot_long} WHERE LOT_NUM = 1"))$n)
  log_msg(sprintf("POMA-at-1L (token '%s'): %d patients of %d LOT1 (%.1f%%)",
                  POMA_TOKEN, n_poma, n_lot1,
                  if (isTRUE(n_lot1 > 0)) 100 * n_poma / n_lot1 else NA_real_))
  write_out(poma, "q1_poma_1l_patients")
  have_poma <- n_poma > 0
  if (!have_poma) {
    log_msg("No POMA-at-1L patients found. If the regimen token differs, ",
            "set POMA_MED_ABBR. Skipping POMA-specific Q1 sections; Q2 and ",
            "Q3 are POMA-independent and still run.")
  }
  poma_ids <- if (have_poma)
    paste(sprintf("'%s'", unique(poma$PATID)), collapse = ",") else "''"

  final_tbl <- wrk(cfg$input_cohort_table)
  have_final <- readable(final_tbl)
  if (!have_final) {
    log_msg("WARNING: ", final_tbl, " not readable. ELIG_COH_FINAL holds the ",
            "selected INDEX_DATE per patient; without it the flag join can pick ",
            "a different candidate index date than the one behind LOT1. ",
            "Q1a/Q1c index-aligned flag breakdowns will be skipped.")
  }

  # ---- Q1a / Q1c : pre-exclusion flags for the POMA-at-1L patients ----
  # ELIG_COH_ALLFLAGS has one row per *candidate* index_date per patient;
  # joining by PATID alone can read flags from a candidate that did NOT
  # produce the LOT1 record. Use ELIG_COH_FINAL (one row per patient with
  # the selected INDEX_DATE) to align the join to the correct candidate.
  if (have_poma && have_flags && have_final) {
    flg <- db_q(con, glue("
      WITH f AS (
        SELECT cast(PATID as string) AS PATID, INDEX_DATE
        FROM {final_tbl}
        WHERE cast(PATID as string) IN ({poma_ids})
      )
      SELECT
        count(DISTINCT a.PATID)                                            AS n_poma_in_allflags,
        count(DISTINCT CASE WHEN a.OTHER_MALIGN_FLAG = 1 THEN a.PATID END)   AS n_other_malig,
        count(DISTINCT CASE WHEN a.CLINTRIAL_BASELINE = 1 THEN a.PATID END)  AS n_clintrial_baseline,
        count(DISTINCT CASE WHEN a.CLINTRIAL_FOLLOWUP = 1 THEN a.PATID END)  AS n_clintrial_followup,
        count(DISTINCT CASE WHEN a.CLINTRIAL_BASELINE = 1
                              OR a.CLINTRIAL_FOLLOWUP  = 1 THEN a.PATID END) AS n_clintrial_any
      FROM {allflags} a
      JOIN f ON cast(a.PATID as string) = f.PATID
            AND a.INDEX_DATE             = f.INDEX_DATE
    "))
    write_out(flg, "q1ac_poma_flags")
    log_msg(sprintf(
      "  Q1a other-cancer flag: %s POMA-1L patients | Q1c clinical-trial: %s (BL %s / FU %s) - aligned to selected INDEX_DATE.",
      flg$n_other_malig[1], flg$n_clintrial_any[1],
      flg$n_clintrial_baseline[1], flg$n_clintrial_followup[1]))
  }

  # Blind-spot quantification: how many ALLFLAGS patients carry each
  # exclusion flag at ANY candidate index date, and how many of those
  # ever reach LOT_LONG (excluded patients have no 1L regimen -> not
  # POMA-classifiable here). Patient-level distinct counts so the
  # multi-candidate ALLFLAGS structure is collapsed correctly.
  if (have_flags) {
    blind <- db_q(con, glue("
      WITH lot1 AS (SELECT DISTINCT cast(PATID as string) PATID
                    FROM {lot_long} WHERE LOT_NUM = 1)
      SELECT
        count(DISTINCT a.PATID) AS allflags_total,
        count(DISTINCT CASE WHEN a.OTHER_MALIGN_FLAG = 1 THEN a.PATID END)  AS allflags_other_malig,
        count(DISTINCT CASE WHEN a.OTHER_MALIGN_FLAG = 1 AND l.PATID IS NOT NULL
                            THEN a.PATID END)                               AS other_malig_with_lot1,
        count(DISTINCT CASE WHEN (a.CLINTRIAL_BASELINE = 1
                               OR a.CLINTRIAL_FOLLOWUP = 1) THEN a.PATID END) AS allflags_clintrial,
        count(DISTINCT CASE WHEN (a.CLINTRIAL_BASELINE = 1
                               OR a.CLINTRIAL_FOLLOWUP = 1) AND l.PATID IS NOT NULL
                            THEN a.PATID END)                               AS clintrial_with_lot1
      FROM {allflags} a
      LEFT JOIN lot1 l ON l.PATID = cast(a.PATID as string)
    "))
    write_out(blind, "q1ac_exclusion_blindspot")
    log_msg("  Blind spot - of patients ever flagged at any candidate index ",
            "date, how many have a 1L regimen (POMA-classifiable): other-cancer ",
            blind$other_malig_with_lot1[1], "/", blind$allflags_other_malig[1],
            ", clinical-trial ", blind$clintrial_with_lot1[1], "/",
            blind$allflags_clintrial[1],
            " - the remainder were excluded and cannot be POMA-classified here.")
  }

  # ---- Q1a detail : best-effort RAW cancer-code scan ------------------
  # NOT equivalent to the cohort's other_malig criterion, which uses the
  # other_malig_codes tumor-group codelist + an inpatient-or-2-outpatient
  # confirmation rule (pipeline_steps.R). This is a raw ICD-10 C* scan
  # against the same quarterly diagnosis table the pipeline reads (via
  # cdm_src() so USE_QUARTERLY_TABLES is honored), excluding C90* (MM /
  # plasma-cell) so the output is not trivially dominated by the index
  # disease. Useful for the Kaposi (C46*) hypothesis check; for an
  # authoritative tumor-group breakdown re-run the other_malig step.
  dx_tbl <- cdm_src(cfg$tbl_med_diag)
  dx_done <- FALSE
  tryCatch({
    if (have_poma && readable(dx_tbl)) {
      cols  <- describe_cols(dx_tbl)
      pid_c <- cols[grepl("^PATID$|PAT_ID", cols, ignore.case = TRUE)][1]
      code_c <- cols[grepl("DIAG|ICD|DX", cols, ignore.case = TRUE) &
                       !grepl("DT|DATE|FLG|FLAG|TYPE|POS", cols, ignore.case = TRUE)][1]
      if (!is.na(pid_c) && !is.na(code_c)) {
        kap <- db_q(con, glue("
          SELECT upper(regexp_replace(trim(d.{code_c}), '[^A-Za-z0-9]', '')) AS dx_code,
                 count(DISTINCT cast(d.{pid_c} as string)) AS n_patients
          FROM {dx_tbl} d
          WHERE cast(d.{pid_c} as string) IN ({poma_ids})
            AND upper(regexp_replace(trim(d.{code_c}), '[^A-Za-z0-9]', '')) RLIKE '^C[0-9]'
            AND upper(regexp_replace(trim(d.{code_c}), '[^A-Za-z0-9]', '')) NOT RLIKE '^C90'
          GROUP BY 1 ORDER BY n_patients DESC
        "))
        if (nrow(kap) > 0) {
          kap$is_kaposi <- grepl("^C46", kap$dx_code)
          write_out(kap, "q1a_raw_nonmm_ccode_scan")
          nk <- sum(num(kap$n_patients[kap$is_kaposi]))
          log_msg("  Q1a raw non-MM C-code scan: ", nrow(kap),
                  " distinct ICD-10 codes among POMA-1L patients (C90* excluded); ",
                  "Kaposi (C46*) patients: ", ifelse(is.finite(nk), nk, 0),
                  ". NOTE: raw scan only - NOT the cohort's other_malig criterion ",
                  "(which requires the other_malig_codes tumor-group codelist + ",
                  "inpatient-or-2-outpatient confirmation).")
          dx_done <- TRUE
        }
      }
    }
  }, error = function(e)
    log_msg("  Q1a raw C-code scan errored (", conditionMessage(e), ")"))
  if (!dx_done) {
    if (!have_poma) {
      log_msg("  Q1a raw C-code scan SKIPPED - no POMA-at-1L patients.")
    } else {
      log_msg("  Q1a raw C-code scan UNAVAILABLE from accessible sources. ",
              "Follow-up: re-run the other_malig step for the authoritative ",
              "tumor-group breakdown, or supply the diagnosis table/columns ",
              "to scan ICD-10 C46* (Kaposi) directly.")
    }
  }

  # ---- Q1b : payer / Medicare Advantage (best-effort introspection) ---
  # cdm_src() so USE_QUARTERLY_TABLES is honored (same vintage the pipeline
  # reads); falls back to the unsuffixed table when quarterly is off.
  enr_tbl <- cdm_src("member_enrollment")
  enr_done <- FALSE
  tryCatch({
    if (have_poma && readable(enr_tbl)) {
      cols  <- describe_cols(enr_tbl)
      pid_c <- cols[grepl("^PATID$|PAT_ID", cols, ignore.case = TRUE)][1]
      plan_cols <- cols[grepl("PRODUCT|PLAN|PAYER|PAY_TYPE|PAYTYPE|BUS|LOB|MEDICARE|MEDADV|INS|PROD",
                              cols, ignore.case = TRUE)]
      log_msg("  Q1b member_enrollment plan-like columns: ",
              if (length(plan_cols)) paste(plan_cols, collapse = ", ") else "(none matched)")
      if (!is.na(pid_c) && length(plan_cols) > 0) {
        parts <- lapply(plan_cols, function(cc) db_q(con, glue("
          SELECT '{cc}' AS source_column,
                 cast(e.{cc} as string)                 AS value,
                 count(DISTINCT cast(e.{pid_c} as string)) AS n_patients
          FROM {enr_tbl} e
          WHERE cast(e.{pid_c} as string) IN ({poma_ids})
          GROUP BY 2 ORDER BY n_patients DESC
        ")))
        payer <- do.call(rbind, parts)
        write_out(payer, "q1b_enrollment_plan_values")
        log_msg("  Q1b: distinct plan/product values for POMA-1L patients ",
                "written. Map Medicare Advantage from these (no MA column is ",
                "projected by the pipeline; this is the source-level evidence).")
        enr_done <- TRUE
      }
    }
  }, error = function(e)
    log_msg("  Q1b enrollment introspection errored (", conditionMessage(e), ")"))
  if (!enr_done) {
    if (!have_poma) {
      log_msg("  Q1b payer/Medicare-Advantage SKIPPED - no POMA-at-1L patients.")
    } else {
      log_msg("  Q1b payer/Medicare-Advantage UNAVAILABLE: member_enrollment not ",
              "readable or no plan-like columns. Out-of-pipeline data step needed.")
    }
  }

  # ---- Q2 : top 25 1L regimens by calendar year ----------------------
  q2 <- db_q(con, glue("
    SELECT yr, regimen, n, rn FROM (
      SELECT year(LOT_START_DT)                              AS yr,
             LOT_BASE_MEDS                                   AS regimen,
             count(*)                                        AS n,
             row_number() OVER (PARTITION BY year(LOT_START_DT)
                                ORDER BY count(*) DESC, LOT_BASE_MEDS) AS rn
      FROM {lot_long}
      WHERE LOT_NUM = 1
        AND LOT_BASE_MEDS IS NOT NULL AND trim(LOT_BASE_MEDS) <> ''
        AND LOT_START_DT IS NOT NULL
      GROUP BY year(LOT_START_DT), LOT_BASE_MEDS
    ) WHERE rn <= 25
    ORDER BY yr, rn
  "))
  write_out(q2, "q2_top25_regimens_by_year")
  log_msg("  Q2: top-25 1L regimens across ",
          length(unique(q2$yr)), " calendar years.")

  # ---- Q3 : journey examples vs 6-9-meds-at-1L-induction -------------
  # Faithfully replays the dashboard's auto journey-example selection
  # (04_lot_detail_dashboard.R): deepest progressors first, then one extra per
  # unique terminal reason, capped at 12. Then measures overlap with the
  # 6-9-induction-meds set the Sankey (Fig 9) highlights.
  pat_pick <- db_q(con, glue("
    WITH pm AS (SELECT PATID, max(LOT_NUM) AS max_lot
                FROM {lot_long} GROUP BY PATID)
    SELECT cast(pm.PATID as string) AS PATID, pm.max_lot,
           ll.LOT_BASE_END_REASON  AS terminal_reason
    FROM pm
    JOIN {lot_long} ll ON ll.PATID = pm.PATID AND ll.LOT_NUM = pm.max_lot
  "))
  pat_pick$max_lot <- num(pat_pick$max_lot)
  pat_pick <- pat_pick[order(-pat_pick$max_lot), , drop = FALSE]
  picked <- head(unique(pat_pick$PATID), 6)
  for (r in unique(pat_pick$terminal_reason)) {
    if (length(picked) >= 12) break
    cand <- pat_pick$PATID[pat_pick$terminal_reason %in% r & !pat_pick$PATID %in% picked]
    if (length(cand) > 0) picked <- c(picked, cand[1])
  }
  picked <- unique(picked)[seq_len(min(12, length(unique(picked))))]

  pick_ids <- paste(sprintf("'%s'", picked), collapse = ",")
  picked_cnt <- db_q(con, glue("
    SELECT cast(PATID as string) AS PATID, cast(LOT_MED_CNT as int) AS LOT_MED_CNT
    FROM {lot_long}
    WHERE LOT_NUM = 1 AND cast(PATID as string) IN ({pick_ids})
  "))
  pmc <- num(picked_cnt$LOT_MED_CNT)
  in_band <- sum(pmc >= MED_CNT_LO & pmc <= MED_CNT_HI, na.rm = TRUE)

  band <- db_q(con, glue("
    SELECT
      count(DISTINCT PATID)                                              AS lot1_patients,
      count(DISTINCT CASE WHEN LOT_MED_CNT BETWEEN {MED_CNT_LO} AND {MED_CNT_HI}
                          THEN PATID END)                                AS lot1_6to9_meds
    FROM {lot_long} WHERE LOT_NUM = 1
  "))
  dist <- db_q(con, glue("
    SELECT cast(LOT_MED_CNT as int) AS lot1_med_cnt, count(DISTINCT PATID) AS n_patients
    FROM {lot_long} WHERE LOT_NUM = 1 GROUP BY 1 ORDER BY 1
  "))
  write_out(picked_cnt, "q3_journey_examples")
  write_out(dist,       "q3_lot1_med_count_distribution")
  log_msg(sprintf(
    "  Q3: %d auto journey examples; %d have 6-9 meds at 1L induction. ",
    length(picked), in_band),
    "Cohort-wide, ", band$lot1_6to9_meds[1], "/", band$lot1_patients[1],
    " LOT1 patients have 6-9 induction meds. NOTE: journey examples are ",
    "chosen by progression depth + terminal-reason diversity, NOT by ",
    "induction med count - so they are a different set; any overlap is ",
    "incidental and quantified above.")

  # ---- Q4 : anti-BCMA / Blenrep (belantamab) availability ------------
  # Epi follow-up. Belantamab mafodotin (Blenrep, HCPCS J9037) is a
  # late-line anti-BCMA agent withdrawn from the US market during the
  # study window (Nov 2022) and reapproved by FDA after study end
  # (Oct 2025) for RRMM after >=2 prior lines - so within STUDY_END
  # 2025-06-30 counts are expected to be low and concentrated in
  # later lines. This scans ALL lines, not just 1L. MAP_STACKED is
  # the per-medication exposure table (cohort-scoped); the belantamab
  # token is detected from the data (class like BCMA, abbr starting
  # BEL) rather than
  # hard-coded, so a codelist abbreviation change does not break it.
  map_tbl <- wrk("MAP_STACKED")
  if (!readable(map_tbl)) {
    log_msg("  Q4: ", map_tbl, " not readable - anti-BCMA / Blenrep ",
            "availability skipped (rebuild via lot_program.R).")
  } else {
    bcma <- db_q(con, glue("
      SELECT MAP_MED_TYPE  AS med_abbr,
             MAP_MED_CLASS AS med_class,
             count(DISTINCT PATID)             AS n_patients,
             count(*)                          AS n_segments,
             cast(min(MAP_START_DT) as string) AS first_use,
             cast(max(MAP_START_DT) as string) AS last_use
      FROM {map_tbl}
      WHERE upper(MAP_MED_CLASS) LIKE '%BCMA%'
         OR upper(MAP_MED_TYPE)  LIKE 'BEL%'
      GROUP BY MAP_MED_TYPE, MAP_MED_CLASS
      ORDER BY n_patients DESC
    "))
    write_out(bcma, "q4_antibcma_inventory")

    bela_tokens <- if (nrow(bcma) > 0)
      unique(bcma$med_abbr[grepl("^BEL", toupper(bcma$med_abbr))]) else
      character(0)

    if (length(bela_tokens) == 0) {
      log_msg("  Q4: no belantamab (Blenrep) exposure found in ", map_tbl,
              "; anti-BCMA agents present: ",
              if (nrow(bcma) > 0) paste(bcma$med_abbr, collapse = ", ")
              else "(none)",
              ". A zero count is itself the answer for epi - Blenrep is ",
              "absent from this cohort.")
    } else {
      tok_in <- paste(sprintf("'%s'", bela_tokens), collapse = ", ")
      n_bela <- num(db_q(con, glue("
        SELECT count(DISTINCT PATID) AS n
        FROM {map_tbl} WHERE MAP_MED_TYPE IN ({tok_in})"))$n)

      by_year <- db_q(con, glue("
        SELECT year(MAP_START_DT)      AS yr,
               count(DISTINCT PATID)   AS n_patients,
               count(*)                AS n_segments
        FROM {map_tbl} WHERE MAP_MED_TYPE IN ({tok_in})
        GROUP BY year(MAP_START_DT) ORDER BY yr
      "))
      write_out(by_year, "q4_blenrep_by_year")

      reg_preds <- paste(sprintf(
        "array_contains(split(LOT_BASE_MEDS, ' '), '%s')", bela_tokens),
        collapse = " OR ")
      by_lot <- db_q(con, glue("
        SELECT LOT_NUM, count(DISTINCT PATID) AS n_patients
        FROM {lot_long}
        WHERE LOT_BASE_MEDS IS NOT NULL AND ({reg_preds})
        GROUP BY LOT_NUM ORDER BY LOT_NUM
      "))
      write_out(by_lot, "q4_blenrep_by_lot")

      log_msg(sprintf(
        "  Q4: Blenrep (token%s %s) - %s distinct patients with belantamab exposure (all lines, cohort-scoped).",
        if (length(bela_tokens) > 1) "s" else "",
        paste(bela_tokens, collapse = "/"), n_bela))
      if (nrow(by_lot) > 0) {
        log_msg("  Q4: Blenrep appears in a 1L-5L regimen for these line ",
                "counts - ",
                paste(sprintf("LOT%s:%s", by_lot$LOT_NUM, by_lot$n_patients),
                      collapse = ", "),
                " (LOT_BASE_MEDS match; a patient may give a J9037 claim ",
                "without it joining a LOT regimen).")
      } else {
        log_msg("  Q4: belantamab exposure exists in MAP_STACKED but does ",
                "not surface in any LOT_BASE_MEDS regimen string.")
      }
    }
  }

  log_msg("LOT1 study-team questions complete. CSVs in ", out_dir)
}

if (!interactive()) main()
