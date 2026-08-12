#!/usr/bin/env Rscript
# The two study-team questions the NDMM cohort cannot answer.
#
#   BROAD_PREFIX=overall_ TRIAL_PREFIX=overall_ \
#     Rscript broad_studyteam_qs.R
#
# Every other script in this folder is NDMM-only and reads one run's own
# tables. These two need a population NDMM does not have, so they live here
# rather than as sections that skip in a workbook about a different cohort.
#
#   Q3-assoc  Does POMA use track with another cancer?
#             NDMM excluded those patients by construction, so measured there
#             it is zero against zero. It needs the broad cohort's own LOT run.
#
#   Trial     The broad build's diagnosis-anchored CLINTRIAL_BASELINE /
#             CLINTRIAL_FOLLOWUP, and its OTHER_MALIGN_FLAG.
#             Not the answer to "did trial therapy precede LOT1" - that is
#             NDMM_CLINTRIAL_FLAGS, in poma_studyteam_qs.R, and this pair
#             cannot answer it: baseline stops before that build's
#             diagnosis-based index and follow-up runs past LOT1, so the
#             stretch between is in neither. Kept because OTHER_MALIGN_FLAG has
#             no 1L-anchored equivalent, and because the comparison around that
#             index is worth having on the population it belongs to.
#
# BROAD_PREFIX and TRIAL_PREFIX are two names for what should be one study, and
# the second question crosses them: it splits the flag build's patients by the
# 1L regimen from the LOT run. So they are checked against each other - the LOT
# run records the cohort it was built from, and that has to be the cohort the
# flag build wrote. Two different broad populations would put every patient the
# LOT run does not have into 'other', which reads the same as not having had
# POMA. When they cannot be tied together the flags are still reported, over
# their own population, with no split.
#
# Nothing here writes to the warehouse.

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
source(file.path(.script_dir, "validation_helpers.R"))

POMA_TOKEN <- toupper(Sys.getenv("POMA_MED_ABBR", unset = "POMA"))

# A query that cannot run leaves a row saying so, rather than an absent CSV
# somebody reads as a zero. Same shape the other scripts in this folder use.
best_effort <- function(expr, label) {
  r <- tryCatch(expr, error = function(e) {
    log_msg("  NOTE: '", label, "' unavailable - ", conditionMessage(e))
    data.frame(status = sprintf("'%s' unavailable: %s", label, conditionMessage(e)),
               stringsAsFactors = FALSE)
  })
  if (is.null(r))
    data.frame(status = sprintf("'%s' returned no data this run", label),
               stringsAsFactors = FALSE)
  else r
}

# Mirrors config_prompts.R baseline_days (183L). The broad pipeline does not
# read an env var for it, so these two stay in step by hand.
BROAD_BASELINE_DAYS <- 183L

main <- function() {
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")
  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  out_dir <- cfg$output_dir
  if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  stamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
  write_out <- function(df, tag) {
    if (is.null(df) || nrow(df) == 0) {
      log_msg("  (", tag, ": no rows)"); return(invisible())
    }
    f <- file.path(out_dir, paste0("broad_studyteam_qs_", tag, "_", stamp, ".csv"))
    write.csv(df, f, row.names = FALSE)
    log_msg("  wrote ", tag, " -> ", f, " (", nrow(df), " rows)")
  }

  log_msg("Broad-cohort study-team questions")
  # This script runs under the NDMM prefix - it reads that build's
  # NDMM_OTHER_MALIG_CODES for the MM-adjacent rule - so the same binding check
  # applies here as anywhere else, even though the lines come from elsewhere.
  qs_check_run_binding(con)

  # ---- the other-cancer association -------------------------------------
  #
  # Lines AND index dates from the same run. Taking the dates from the NDMM
  # cohort would drop every broad patient the NDMM exclusions removed out of the
  # index join: they stay in the denominator through the left join and can never
  # match a diagnosis, so they read as having no other cancer - the opposite of
  # the population this recovers.
  broad_pfx <- trimws(Sys.getenv("BROAD_PREFIX", unset = ""))
  if (!nzchar(broad_pfx)) {
    log_msg("BROAD_PREFIX is not set, so the association is skipped. It needs ",
            "the prefix of a LOT run over the broad cohort - one prefix is one ",
            "cohort, and this question is about the one NDMM removed patients ",
            "from.")
  } else if (!grepl("^[A-Za-z][A-Za-z0-9_]*_$", broad_pfx)) {
    stop("BROAD_PREFIX '", broad_pfx, "' should be a name ending in '_'.",
         call. = FALSE)
  }
  broad_lot <- if (nzchar(broad_pfx))
    full_name(cfg$work_schema, paste0(broad_pfx, "LOT_LONG_FINAL")) else NA_character_
  broad_idx <- if (nzchar(broad_pfx))
    full_name(cfg$work_schema, paste0(broad_pfx, "LOT_PATIENT_INPUT")) else NA_character_

  # Readable is not ownership. That run replaces LOT_LONG_FINAL before it
  # validates it, so a rerun that replaced it and then failed leaves lines that
  # read perfectly well and were never checked. Its status row settles it, and
  # names the cohort it was built from.
  broad <- if (nzchar(broad_pfx)) qs_broad_run_state(con, broad_pfx) else
    list(ok = TRUE, why = NULL, cohort = NA_character_, vintage = NULL)
  if (nzchar(broad_pfx) && !isTRUE(broad$ok))
    log_msg("Association skipped - ", broad$why)
  if (!is.null(broad$vintage)) log_msg("  ", broad$vintage)

  # The code list as the cohort build resolved it, with is_mm_adjacent_override
  # already applied - one derivation of that rule rather than two. Secondary
  # neoplasm of bone is not MM-adjacent: C79.51, C79.52 and 198.5 are metastatic
  # cancer and exclude (ndmm/DECISIONS.md section 4).
  om_codes <- qs_tbl("NDMM_OTHER_MALIG_CODES")

  assoc <- if (nzchar(broad_pfx) && isTRUE(broad$ok) &&
               vqs_readable(con, broad_lot) && vqs_readable(con, broad_idx) &&
               vqs_readable(con, om_codes))
    best_effort(db_q(con, glue("
      WITH poma1l AS (SELECT DISTINCT cast(PATID as string) PATID FROM {broad_lot}
                      WHERE LOT_NUM=1 AND array_contains(split(LOT_BASE_MEDS,' '),'{POMA_TOKEN}')),
      lot1 AS (SELECT DISTINCT cast(PATID as string) PATID FROM {broad_lot} WHERE LOT_NUM=1),
      idx AS (SELECT cast(PATID as string) PATID, cast(INDEX_DATE as date) index_date FROM {broad_idx}),
      codes AS (SELECT dx, icd_family, is_mm_adjacent_override AS is_mm_adj
                FROM {om_codes} WHERE dx IS NOT NULL),
      hits AS (SELECT cast(d.PATID as string) PATID,
                      max(1)                                            has_any,
                      max(CASE WHEN c.is_mm_adj = 0 THEN 1 ELSE 0 END)  has_nonadj
               FROM {cdm_src(cfg$tbl_med_diag)} d
               JOIN idx i ON cast(d.PATID as string) = i.PATID
               JOIN codes c
                 ON upper(regexp_replace(d.DIAG,'[^A-Za-z0-9]','')) = c.dx
                AND ({qs_icd_family_sql('d.ICD_FLAG')}) = c.icd_family
               WHERE cast(d.FST_DT as date)
                     BETWEEN date_sub(i.index_date,{BROAD_BASELINE_DAYS}) AND date_sub(i.index_date,1)
               GROUP BY cast(d.PATID as string))
      SELECT CASE WHEN p.PATID IS NOT NULL THEN 'POMA-1L' ELSE 'other-1L' END  grp,
             count(*)                                              n_pts,
             sum(coalesce(h.has_any,0))                            n_incl_mm_adjacent,
             round(100.0*sum(coalesce(h.has_any,0))/count(*),1)    pct_incl_mm_adjacent,
             sum(coalesce(h.has_nonadj,0))                         n_other_cancer_deconf,
             round(100.0*sum(coalesce(h.has_nonadj,0))/count(*),1) pct_other_cancer_deconf
      FROM lot1 l LEFT JOIN poma1l p USING (PATID) LEFT JOIN hits h ON h.PATID = l.PATID
      GROUP BY 1 ORDER BY 1")), "broad-cohort de-confounded other-cancer")
    else NULL
  write_out(assoc, "other_cancer_association")
  if (!is.null(assoc))
    log_msg("  Association over prefix '", broad_pfx, "'",
            if (!is.na(broad$cohort) && nzchar(trimws(broad$cohort)))
              paste0(", built from ", broad$cohort) else "",
            ". Compare the two groups on pct_other_cancer_deconf. ",
            "Claim-presence basis, looser than the pipeline's confirmed ",
            ">=1-IP-or->=2-OP flag, so it runs higher than the cohort's own rate.")

  # ---- the diagnosis-anchored flags -------------------------------------
  #
  # Two tables from one build: ELIG_COH_ALLFLAGS has a row per candidate index
  # date, and that build's final cohort says which candidate it selected.
  trial <- qs_trial_flags_ready(con)
  if (!isTRUE(trial$ok)) {
    log_msg("Diagnosis-anchored flags skipped - ", trial$why)
  } else {
    allflags  <- trial$src$flags
    trial_idx <- trial$src$index

    # The POMA split crosses the two broad sources, and only here. The flags
    # are the flag build's own; the regimen that splits them comes from the LOT
    # run under BROAD_PREFIX. So the split runs only when both are usable AND
    # they are the same cohort - otherwise the flags are still reported, over
    # the population they belong to, ungrouped.
    #
    # Reporting them ungrouped rather than not at all: this half of the section
    # is about that build's OTHER_MALIGN_FLAG and its trial windows, which do
    # not need the LOT run. Only the split does.
    pair <- qs_broad_pair_bound(broad$cohort, trial_idx)
    # Why the split is off, or NULL when it runs. One reason, decided once and
    # read by both the log and the CSV column, which used to be able to
    # disagree.
    #
    # Unverified lineage leaves it off, alongside a known mismatch: 'other' is
    # the complement of a POMA set drawn from the LOT run, so a flag-build
    # patient that run never held lands in it, counted as not having had POMA.
    # Same arithmetic either way - verification only changes whether anyone can
    # see it. Costs the split on a broad build too old to record
    # INPUT_COHORT_TABLE; the flags still report, ungrouped.
    split_off <-
      if (!nzchar(broad_pfx))
        paste0("BROAD_PREFIX is unset, and the 1L regimen that splits these ",
               "patients comes from a LOT run over this build's own cohort.")
      else if (!isTRUE(broad$ok))
        "the broad LOT run behind that regimen is not usable this run."
      else if (!isTRUE(pair$bound)) pair$why
      else NULL
    poma_split <- is.null(split_off)
    # On the rows, not in the console alone: the CSV outlives the log, and one
    # row of counts says nothing about why it is one row.
    lineage <- if (poma_split)
      "POMA split, lineage verified - both broad sources name the same cohort"
    else paste0("no POMA split - ", split_off)
    # Doubled: this is prose, and one unescaped apostrophe ends the literal and
    # kills the query inside best_effort().
    lineage_lit <- gsub("'", "''", lineage, fixed = TRUE)
    poma_cte <- if (poma_split) glue("
      , poma1l AS (SELECT DISTINCT cast(PATID as string) PATID FROM {broad_lot}
                   WHERE LOT_NUM=1 AND array_contains(split(LOT_BASE_MEDS,' '),'{POMA_TOKEN}'))")
                else ""
    grp_expr <- if (poma_split)
      "CASE WHEN p.PATID IS NOT NULL THEN 'POMA-1L' ELSE 'other' END" else "'all'"
    poma_join <- if (poma_split)
      "LEFT JOIN poma1l p ON p.PATID = cast(a.PATID as string)" else ""
    # Over that build's own population, not the NDMM one. Restricting to the
    # NDMM patients was what made the old version an overlap of two cohorts
    # with a match rate to police; here the denominator is the population the
    # flags belong to, and the question is about that population.
    flg <- best_effort(db_q(con, glue("
      WITH f AS (SELECT cast(PATID as string) PATID, INDEX_DATE FROM {trial_idx})
      {poma_cte}
      SELECT {grp_expr}                                                         AS grp,
             '{lineage_lit}'                                                    AS lineage,
             count(DISTINCT a.PATID)                                            AS n_pts,
             count(DISTINCT CASE WHEN a.OTHER_MALIGN_FLAG = 1 THEN a.PATID END) AS n_other_malig,
             count(DISTINCT CASE WHEN a.CLINTRIAL_BASELINE = 1 THEN a.PATID END)  AS n_trial_baseline,
             count(DISTINCT CASE WHEN a.CLINTRIAL_FOLLOWUP = 1 THEN a.PATID END)  AS n_trial_followup,
             count(DISTINCT CASE WHEN a.CLINTRIAL_BASELINE = 1
                                   OR a.CLINTRIAL_FOLLOWUP  = 1 THEN a.PATID END) AS n_trial_any
      FROM {allflags} a
      JOIN f ON cast(a.PATID as string) = f.PATID AND a.INDEX_DATE = f.INDEX_DATE
      {poma_join}
      -- The expression rather than the ordinal: without the split it is a
      -- literal, and GROUP BY 1 on a constant is the one place the ordinal
      -- shorthand is worth not relying on.
      GROUP BY {grp_expr} ORDER BY 1")), "diagnosis-anchored flags")
    write_out(flg, "diagnosis_anchored_flags")
    log_msg("  Diagnosis-anchored flags from ", allflags, ", aligned to ",
            trial_idx, ". Both windows are relative to that build's own index: ",
            "baseline ends the day before it, follow-up starts on it and runs ",
            "past LOT1, so NEITHER isolates 'before LOT1'. For that, read ",
            "NDMM_CLINTRIAL_FLAGS in poma_studyteam_qs.R.")
    log_msg("  Lineage: ", lineage, " (also the CSV's `lineage` column, so it ",
            "stays with the numbers when this log does not.)")
    if (!poma_split)
      log_msg("  NOTE: one row, grp='all', with no POMA split - ", split_off)
  }

  log_msg("Broad-cohort questions complete. CSVs in ", out_dir)
}

if (!interactive()) main()
