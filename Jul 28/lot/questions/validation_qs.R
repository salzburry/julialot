#!/usr/bin/env Rscript
# Standalone program: "MM LOT Validation next steps" study-team questions.
# Sibling of lot1_studyteam_qs.R.
#
#   Rscript validation_qs.R
#
# Answers, against the persisted work-schema tables (LOT_LONG, MAP_STACKED,
# LOT1_SCT) and the raw CDM (for the patient-journey examples):
#
#   Q1  LOT1 regimens including pomalidomide / elotuzumab / panobinostat,
#       split into mono- vs combination-therapy.
#   Q2  Raw-claim examples (before MAPs were derived) for patients with
#       pomalidomide in their LOT1 regimen.
#   Q3  LOT1 patients with no steroid at LOT1: steroid receipt within 7/14/30d
#       before LOT1 start, and within 7/14/30d after the 60-day induction
#       window.
#   Q4  Same as Q3 for LOT2 (30-day induction window).
#   Q5  No-steroid-at-LOT2 patients with a steroid in the 30d before LOT2:
#       Did they have a steroid at LOT1? (attribution check).
#   Q6  CAR-T prior to or during LOT1, with raw-claim journey examples.
#
# Builds nothing persistent; safe to run any time. Writes one CSV per result
# plus a run log. All operational definitions live in R/validation_qs.R
# and are shared verbatim with the combined dashboard's Exploratory objective.
#
# Cohorts: every question is answered once
# per cohort - the parent Overall LOT_LONG cohort always, and the NDMM (1L)
# population. One prefix is one cohort, so there is no second population (the
# dashboard's NDMM pass) is readable. NDMM CSVs carry an "ndmm_" prefix.

.script_dir <- local({
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", args, value = TRUE)
  if (length(file_arg) > 0)
    return(dirname(normalizePath(sub("^--file=", "", file_arg[1]))))
  for (i in seq_len(sys.nframe())) {
    ofile <- tryCatch(sys.frame(i)$ofile, error = function(e) NULL)
    if (!is.null(ofile)) return(dirname(normalizePath(ofile)))
  }
  getwd()
})

source(file.path(.script_dir, "_setup.R"))
qs_setup(.script_dir)
source(file.path(.script_dir, "validation_helpers.R"))   # vqs_* logic

main <- function() {
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")

  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  out_dir <- cfg$output_dir
  if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  stamp <- format(Sys.time(), "%Y%m%d_%H%M%S")

  write_out <- function(df, tag) {
    if (is.null(df) || nrow(df) == 0) { log_msg("  (", tag, ": no rows)"); return(invisible()) }
    f <- file.path(out_dir, paste0("validation_qs_", tag, "_", stamp, ".csv"))
    write.csv(df, f, row.names = FALSE)
    log_msg("  wrote ", tag, " -> ", f, " (", nrow(df), " rows)")
  }

  .pop      <- qs_population()
  lot_long  <- .pop$table
  .pop_label <- .pop$label
  map_tbl  <- qs_tbl("MAP_STACKED")
  sct_tbl  <- qs_tbl("LOT1_SCT")

  log_msg(SEP)
  log_msg("MM LOT Validation next steps - study-team questions")
  log_msg(SEP)
  if (!vqs_readable(con, lot_long))
    stop("Cannot read ", lot_long, ". Build the LOT pipeline (02_lot1.R / 03_lot2_5.R) first.")
  # Readable is not ownership. This script bounds raw-claim examples, pre-LOT1
  # CAR-T and steroid timing by INPUT_COHORT_TABLE, so a valid name for the
  # wrong cohort pairs one run's lines with another's dates - and a rerun that
  # replaced these tables and then failed leaves them looking fine.
  qs_check_run_binding(con)
  have_map <- vqs_readable(con, map_tbl)
  have_sct <- vqs_readable(con, sct_tbl)
  if (!have_map)
    log_msg("WARNING: ", map_tbl, " not readable - Q2 MAP-journey examples will ",
            "be skipped. (Q3/Q4/Q5 use the steroid_codes.csv signal, built ",
            "separately - not MAP_STACKED.)")
  if (!have_sct)
    log_msg("WARNING: ", sct_tbl, " not readable - CAR-T question (Q6) will be skipped.")

  tokens <- vqs_resolve_agent_tokens(con)
  log_msg("Agent tokens -> POMA='", tokens$poma, "', ELOT='", tokens$elot,
          "', PANO='", tokens$pano, "'. ", paste(tokens$notes, collapse = " "))

  # Observation-window bounds (ELIG_COH_FINAL) so the raw-claim examples are
  # scoped to [INDEX_DATE, OBS_END_DT] like the pipeline's S04/S12 pulls.
  bounds <- vqs_obs_bounds_src(con)
  if (!bounds$available)
    log_msg("WARNING: ", wrk(cfg$input_cohort_table), " not readable - raw-claim ",
            "examples will NOT be observation-window bounded, and 'CAR-T before ",
            "LOT1' (Q6) cannot be computed (needs the raw, bounded SCT scan).")
  # Cohort-wide raw CAR-T claim dates (observation-bounded) - the only way to
  # answer 'CAR-T before LOT1', which LOT1_SCT cannot express.
  cart_raw <- if (have_sct) vqs_build_raw_cart_dates(con, lot_long, bounds$sql) else NULL
  if (have_sct && is.null(cart_raw))
    log_msg("NOTE: raw CAR-T date scan unavailable - Q6 'before LOT1' reported as NA.")

  # Steroid signal = steroid_codes.csv scanned on medical+rx (the project's
  # only steroid source; there is no STEROID class in cl_mma_codelist.csv).
  # From the production code-list directory, the same place the LOT build reads
  # its four. A copy beside this script would be a second version of a governed
  # file, drifting quietly from the one the study actually uses.
  #
  # Not added to CODELIST_FILES: that list drives record_codelist_hashes(),
  # which stops the LOT build when a listed file has no hash - and the LOT
  # build never loads steroids, so naming it there would break a build that has
  # nothing to do with this question. Hashed here instead, in the note.
  ster <- vqs_build_steroid_claims(con, lot_long,
                                   file.path(cfg$codelist_dir, "steroid_codes.csv"))
  ster_src <- if (!is.null(ster$view)) vqs_steroid_src(ster$view) else NULL
  log_msg("Steroid signal: ", ster$note)
  if (is.null(ster_src))
    log_msg("WARNING: no steroid signal - Q3/Q4/Q5 will be SKIPPED (load steroid_codes.csv).")

  # Definitions sidecar so every CSV batch travels with its operational
  # definitions (counts alone are easy to misread).
  # Cohort passes: Overall always; NDMM when the persisted NDMM cohort table
  # (materialized by the combined dashboard's NDMM pass) is present. The NDMM
  # table is LOT_LONG INNER JOINed to the NDMM patient set - a strict subset
  # of the parent - so the shared signal views built above on the parent
  # patient list (steroid claims, raw CAR-T dates) cover both cohorts; each
  # per-question query joins back to its own cohort lot_long.
  # One population, not two. The old arrangement ran a "parent" LOT_LONG and an
  # NDMM-filtered subset of it side by side; the LOT run under this prefix is
  # over the cohort already, so there is no subset to compare against - a
  # different cohort is a different prefix and a separate run of this script.
  cohorts <- list(list(tag = "cohort", label = .pop_label, lot_long = lot_long))

  defs <- data.frame(item = c(
    "denominator_cohort", "steroid_signal", "steroid_at_lotn",
    "before_after_windows", "cart_during_or_closing", "cart_before_lot1",
    "agent_tokens", "raw_claims_window"),
    definition = c(
      paste0("One pass over ", lot_long, " - ", .pop_label, "."),
      paste0("steroid_codes.csv codes scanned on medical (PROC_CD/BILL_PROC_CD/NDC) + rx (NDC). ", ster$note),
      sprintf("No-steroid denominator: a steroid claim within the CAPPED induction window [LOT_START, LOT_INDUCTION_END_DT] = least(LOT_BASE_END_DT, LOT_START+W-1); W=%d (LOT1) / %d (CART-started LOTn) / %d (other LOTn); SCT_ALLO = no membership. Matches the Steroids panel.", VQS_W1, VQS_CART, VQS_W2),
      "Cumulative (<=N days) from a steroid claim date; before=[start-N,start-1] (rel. LOT_START); after=[fixed_ind_end+1, fixed_ind_end+N] where fixed_ind_end=LOT_START+W-1 (NOT capped).",
      "FIRST_CART_DT in [LOT1_START, LOT_BASE_END_DT], extended by +1 day ONLY when LOT_BASE_END_REASON in (SCT_CART, CART_INIT) - the engine sets the LOT end to CAR-T date - 1 only for a CAR-T-ending line, so the closing CAR-T lands one day past the end; for other end reasons a CAR-T at end+1 is post-LOT1 and excluded.",
      "Raw SCT CAR-T claim with service date < LOT1_START (LOT1_SCT.FIRST_CART_DT cannot express this).",
      sprintf("POMA=%s, ELOT=%s, PANO=%s (best-effort from cl_mma_codelist.csv).", tokens$poma, tokens$elot, tokens$pano),
      if (bounds$available) "Raw-claim examples bounded to [INDEX_DATE, OBS_END_DT] from ELIG_COH_FINAL."
      else "ELIG_COH_FINAL unavailable: raw-claim examples show full PATID history (NOT observation-bounded)."),
    stringsAsFactors = FALSE)
  write_out(defs, "definitions")

  for (co in cohorts) {
    ll <- co$lot_long
    # NDMM outputs carry an "ndmm_" prefix; Overall filenames are unchanged
    # (continuity with earlier runs).
    tg <- function(x) if (identical(co$tag, "overall")) x else paste0(co$tag, "_", x)
    log_msg(SEP); log_msg("Cohort pass: ", co$label, " (", ll, ")"); log_msg(SEP)

    # ---- Q1 ----
    log_msg(DASH); log_msg("[", co$label, "] Q1: LOT1 regimens with pomalidomide / elotuzumab / panobinostat")
    q1 <- vqs_q1_exclusion_agents(con, ll, tokens)
    write_out(q1, tg("q1_exclusion_agents_lot1"))
    log_msg(sprintf("  LOT1 patients = %s. Any of the three: %s (mono %s / combo %s).",
                    attr(q1, "lot1_patients"),
                    q1$n_lot1_with_agent[q1$agent == "Any of the three"],
                    q1$n_as_monotherapy[q1$agent == "Any of the three"],
                    q1$n_in_combination[q1$agent == "Any of the three"]))

    # ---- Q2 ----
    log_msg(DASH); log_msg("[", co$label, "] Q2: raw-claim examples for pomalidomide-at-LOT1 patients")
    if (have_map) {
      q2 <- vqs_q2_poma_examples(con, ll, map_tbl, tokens, n = 5L, bounds = bounds$sql)
      if (!is.null(q2$note)) log_msg("  ", q2$note)
      if (length(q2$patids)) log_msg("  example PATIDs: ", paste(q2$patids, collapse = ", "))
      write_out(q2$journey, tg("q2_poma_examples_map_journey"))
      write_out(q2$raw,     tg("q2_poma_examples_raw_claims"))
    } else log_msg("  skipped (MAP_STACKED unavailable).")

    # ---- Q3 / Q4 / Q5 (need the steroid signal) ----
    if (!is.null(ster_src)) {
      log_msg(DASH); log_msg("[", co$label, "] Q3: steroid timing for LOT1 patients with no steroid at LOT1")
      q3 <- vqs_steroid_windows(con, ll, ster_src, lot_num = 1L, w = VQS_W1)
      write_out(q3, tg("q3_lot1_steroid_windows"))
      log_msg(sprintf("  LOT1: %s patients, %s with steroid at LOT1, %s without (denominator).",
                      attr(q3, "line_patients"), attr(q3, "line_with_steroid"),
                      attr(q3, "line_without_steroid")))
      # "who" (patient-level): the actual no-steroid-at-LOT1 patients + windows.
      write_out(vqs_steroid_windows_patients(con, ll, ster_src, lot_num = 1L, w = VQS_W1),
                tg("q3_lot1_steroid_window_patients"))

      log_msg(DASH); log_msg("[", co$label, "] Q4: steroid timing for LOT2 patients with no steroid at LOT2")
      q4 <- vqs_steroid_windows(con, ll, ster_src, lot_num = 2L, w = VQS_W2)
      write_out(q4, tg("q4_lot2_steroid_windows"))
      log_msg(sprintf("  LOT2: %s patients, %s with steroid at LOT2, %s without (denominator).",
                      attr(q4, "line_patients"), attr(q4, "line_with_steroid"),
                      attr(q4, "line_without_steroid")))
      write_out(vqs_steroid_windows_patients(con, ll, ster_src, lot_num = 2L, w = VQS_W2),
                tg("q4_lot2_steroid_window_patients"))

      # ---- Q5 ----
      log_msg(DASH); log_msg("[", co$label, "] Q5: LOT2 pre-start steroid attribution to LOT1")
      q5 <- vqs_q5_lot2_attribution(con, ll, ster_src, w1 = VQS_W1, w2 = VQS_W2)
      write_out(q5, tg("q5_lot2_steroid_attribution"))
      log_msg("  denominator (no LOT2 steroid + steroid in 30d before LOT2): ", q5$n_patients[1],
              "; pre-LOT2 steroid ITSELF within LOT1 span (attributable): ", q5$n_patients[2],
              "; NOT within LOT1 span: ", q5$n_patients[3], ".")
    } else log_msg("Q3/Q4/Q5 skipped - no steroid signal (steroid_codes.csv).")

    # ---- Q6 ----
    if (have_sct) {
      log_msg(DASH); log_msg("[", co$label, "] Q6: CAR-T prior to or during LOT1")
      q6 <- vqs_q6_cart(con, ll, sct_tbl, w1 = VQS_W1, cart_raw_tbl = cart_raw)
      write_out(q6, tg("q6_cart_prior_or_during_lot1"))
      log_msg("  CAR-T prior to OR during LOT1: ",
              q6$n_patients[q6$metric == "CAR-T prior to OR during LOT1 (the ask)"],
              " patients (of ", q6$n_patients[1], " LOT1).",
              if (is.null(cart_raw)) " ('before LOT1' = NA: raw CAR-T scan unavailable.)" else "")

      log_msg(DASH); log_msg("[", co$label, "] Q6: raw-claim journey examples for CAR-T prior-to/during-LOT1 patients")
      ex <- vqs_q6_cart_examples(con, ll, sct_tbl, map_tbl, n = 5L,
                                 bounds = bounds$sql, cart_raw_tbl = cart_raw)
      if (!is.null(ex$note)) log_msg("  ", ex$note)
      if (length(ex$patids)) log_msg("  example PATIDs: ", paste(ex$patids, collapse = ", "))
      write_out(ex$sct_raw, tg("q6_cart_examples_raw_sct_claims"))
      write_out(ex$mma_raw, tg("q6_cart_examples_raw_mma_claims"))
      write_out(ex$journey, tg("q6_cart_examples_map_journey"))
    } else log_msg("Q6 skipped (LOT1_SCT unavailable).")
  }

  log_msg(SEP)
  log_msg("Validation questions complete (", length(cohorts), " cohort pass",
          if (length(cohorts) > 1) "es" else "", "). CSVs in ", out_dir)
  log_msg(SEP)
}

if (!interactive()) main()
