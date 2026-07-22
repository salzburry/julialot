#!/usr/bin/env Rscript
# July-20 study-team questions -> one Excel workbook + one refreshed HTML
# dashboard + patient-level CSVs.
#
#   Rscript jul20_studyteam_qs.R
#
# A sibling of lot_followup_qs.R / lot1_studyteam_qs.R. It answers Julia's
# July-20 follow-ups (dashboard refresh, DARA+BORT 1L deep dive, and the two
# candidate LOT-rule changes), reading the MM tables on Databricks. No existing
# pipeline or dashboard file is modified - this script only reads the persisted
# work-schema tables and re-uses the shared helpers in R/.
#
# Cohort: the NDMM study cohort by default (NDMM_LOT_LONG_FILT), which is the
# cohort Julia's question 2 names. Set LOT_COHORT=FULL for the whole LOT cohort.
# MAP_STACKED, LOT1_SCT, MMA_MED_PROCESSED and ELIG_COH_FINAL are shared,
# joined by PATID.
#
# Questions:
#   Q1  Dashboard refresh: a new steroid-free dashboard HTML with an
#       "All regimens per LOT" tab per line (every regimen string, not a top-N),
#       each downloadable as CSV from the table itself and also written as a
#       CSV file. Regimens come straight from LOT_BASE_MEDS, which the engine
#       builds without steroids; a steroid audit tab proves that. The
#       production dashboards are untouched.
#   Q2  1L DARA+BORT dual therapy (exactly those two agents) in this cohort:
#       a patient-level roster CSV (diagnosis date, per-agent episodes/MAPs and
#       claim counts, 2L regimen, region, payer), a per-MAP detail CSV, and
#       summary tabs - cycles per agent (a), 2L regimens (b), diagnosis years
#       (c), region x payer (d).
#   Q3  Impact of the two candidate LOT-rule changes, simulated read-only on
#       top of the persisted LOT_LONG / MAP_STACKED / LOT1_SCT:
#       (a) a MELP starting 60-180 days after the first MELP MAP of the line
#           does not advance the LOT (otherwise MELP is part of the line), and
#       (b) a CAR-T inside LOT1's 60-day induction window stays in LOT1.
#
# Honest limits, surfaced in the output rather than hidden:
#   - "Cycles" are not recorded in claims. We report drug episodes (MAPs) and
#     administration/fill claim counts per agent - the closest measurable
#     proxies, and the ones the ask itself names ("episodes and MAPs").
#   - Region is not derived anywhere in the pipeline today. The script probes
#     the Optum enrollment/member tables for a Census-region column at runtime
#     and says so plainly when none is reachable.
#   - Q3 is a first-order simulation (which lines would merge and how the
#     per-patient line counts shift), not an engine re-run. Later-line windows
#     and regimens are kept as built; a production re-run needs a spec change.
#   - Rule (a) as written makes every MELP non-advancing (a MELP with no
#     earlier MELP in the line falls into the "otherwise: part of the LOT"
#     branch). The tabs therefore show BOTH readings - the literal one and the
#     narrow one (only 60-180-day recurrences suppressed) - with the timing
#     decomposition, so the study team can confirm the intended rule.
#
# Writes no permanent tables (only session temp views). A run writes one Excel
# workbook, one dashboard HTML, a set of CSVs, a log, and the output folder if
# missing, and may set env defaults from pipeline_inputs.csv. Safe to run any
# time.

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

source_dir <- file.path(.script_dir, "R")
if (file.exists(file.path(source_dir, "load_inputs.R"))) {
  source(file.path(source_dir, "load_inputs.R"))
  load_pipeline_inputs(c(.script_dir, dirname(.script_dir)))
}
source(file.path(source_dir, "config_lot.R"))
source(file.path(source_dir, "db_utils_lot.R"))
source(file.path(source_dir, "codelists_lot.R"))        # load_codelist_csv
source(file.path(source_dir, "validation_qs.R"))        # vqs_* helpers (shared)

# The dashboard helpers are optional: without them (or without the DT /
# htmlwidgets / jsonlite / base64enc packages) the CSVs and the workbook are
# still written and the missing dashboard is flagged as a core gap.
.have_dashboard_helpers <- tryCatch({
  source(file.path(source_dir, "dashboard_lot.R")); TRUE
}, error = function(e) {
  FALSE
})

`%||%` <- function(a, b) if (is.null(a)) b else a

# ===========================================================================
# Writes the workbook with openxlsx. A "sheet" is a list of name, title,
# optional subtitle, narrative lines, and named tables (each a data.frame, or a
# list of caption + df). openxlsx must be installed; main() checks that first.
# (Same writer as lot_followup_qs.R.)
# ===========================================================================
wbx_write_workbook <- function(sheets, xlsx_path) {
  ox <- function(f) getExportedValue("openxlsx", f)
  wb <- ox("createWorkbook")()
  st_title <- ox("createStyle")(fontSize = 14, textDecoration = "bold",
                                fontColour = "#FFFFFF", fgFill = "#1F3864")
  st_sub   <- ox("createStyle")(fontColour = "#FFFFFF", fgFill = "#2E5496",
                                textDecoration = "italic")
  st_narr  <- ox("createStyle")(wrapText = TRUE, valign = "top")
  st_cap   <- ox("createStyle")(textDecoration = "bold", fgFill = "#D6E0F0")
  st_hdr   <- ox("createStyle")(textDecoration = "bold", fontColour = "#FFFFFF",
                                fgFill = "#2E5496", border = "TopBottomLeftRight",
                                halign = "left")
  for (s in sheets) {
    sn <- substr(gsub("[\\/?*:\\[\\]]", "", s$name), 1, 31)
    ox("addWorksheet")(wb, sn)
    r <- 1L
    ox("writeData")(wb, sn, s$title, startRow = r, startCol = 1)
    ox("addStyle")(wb, sn, st_title, rows = r, cols = 1:10, gridExpand = TRUE)
    r <- r + 1L
    if (!is.null(s$subtitle)) {
      ox("writeData")(wb, sn, s$subtitle, startRow = r, startCol = 1)
      ox("addStyle")(wb, sn, st_sub, rows = r, cols = 1:10, gridExpand = TRUE)
      r <- r + 1L
    }
    r <- r + 1L
    for (line in s$narrative %||% character()) {
      ox("writeData")(wb, sn, line, startRow = r, startCol = 1)
      ox("addStyle")(wb, sn, st_narr, rows = r, cols = 1, gridExpand = TRUE)
      r <- r + 1L
    }
    r <- r + 1L
    for (nm in names(s$tables %||% list())) {
      entry <- s$tables[[nm]]
      cap <- nm; df <- entry
      if (is.list(entry) && !is.data.frame(entry)) { cap <- entry$caption %||% nm; df <- entry$df }
      ox("writeData")(wb, sn, cap, startRow = r, startCol = 1)
      ox("addStyle")(wb, sn, st_cap, rows = r, cols = 1:10, gridExpand = TRUE)
      r <- r + 1L
      if (is.data.frame(df) && nrow(df) > 0) {
        ox("writeData")(wb, sn, df, startRow = r, startCol = 1,
                        headerStyle = st_hdr, withFilter = FALSE)
        r <- r + nrow(df) + 2L
      } else {
        ox("writeData")(wb, sn, "(no rows / not available)", startRow = r, startCol = 1)
        r <- r + 2L
      }
    }
    ox("setColWidths")(wb, sn, cols = 1:14, widths = "auto")
  }
  ox("saveWorkbook")(wb, xlsx_path, overwrite = TRUE)
  log_msg("wrote workbook -> ", xlsx_path, " (", length(sheets), " sheets)")
  invisible(TRUE)
}

# Run a pull and return its data, or a one-row "status" table naming the failure.
# This keeps a visible "unavailable" row in the workbook instead of a silent gap.
best_effort <- function(expr, label) {
  r <- tryCatch(expr, error = function(e) {
    log_msg("  NOTE: '", label, "' unavailable - ", conditionMessage(e))
    data.frame(status = sprintf("'%s' unavailable: %s", label, conditionMessage(e)),
               stringsAsFactors = FALSE)
  })
  if (is.null(r))
    data.frame(status = sprintf("'%s' returned no data (unavailable this run)", label),
               stringsAsFactors = FALSE)
  else r
}

# TRUE if x is a best_effort() failure row - a "could not build" placeholder.
is_status_table <- function(x)
  is.data.frame(x) && identical(names(x), "status")

num <- function(x) suppressWarnings(as.numeric(x))
pct1 <- function(x, d) if (isTRUE(num(d) > 0)) round(100 * num(x) / num(d), 1) else NA_real_
na_i <- function(x) { v <- num(x); if (length(v) == 0 || is.na(v)) NA_integer_ else as.integer(v) }

# ---------------------------------------------------------------------------
# Look up the drug short-codes (DARA/BORT/MELP) from cl_mma_codelist.csv by
# full drug name, so a code change in the codelist does not quietly break a
# count. resolved = TRUE only when every code came from the codelist.
# ---------------------------------------------------------------------------
resolve_jul20_tokens <- function(con) {
  out <- list(dara = "DARA", bort = "BORT", melp = "MELP",
              notes = character(0), resolved = FALSE)
  ok <- tryCatch({ vqs_build_mma_codelist(con); TRUE }, error = function(e) FALSE)
  if (!ok) {
    out$notes <- "mma_codelist unavailable; using default tokens (DARA/BORT/MELP)."
    return(out)
  }
  fell_back <- character()
  pick <- function(name, like, dflt) {
    df <- tryCatch(db_q(con, glue("
      SELECT CL_MED_ABBR, count(*) AS n
      FROM mma_codelist
      WHERE lower(CL_MEDICATION_FULL) LIKE '%{like}%'
      GROUP BY CL_MED_ABBR ORDER BY n DESC")), error = function(e) NULL)
    if (is.null(df) || nrow(df) == 0) { fell_back <<- c(fell_back, name); return(dflt) }
    toupper(trimws(df$CL_MED_ABBR[1]))
  }
  out$dara <- pick("DARA", "daratumumab", "DARA")
  out$bort <- pick("BORT", "bortezomib",  "BORT")
  out$melp <- pick("MELP", "melphalan",   "MELP")
  out$resolved <- length(fell_back) == 0
  if (length(fell_back))
    out$notes <- sprintf("Some tokens not found in cl_mma_codelist.csv (fell back to defaults for: %s). Tokens: DARA=%s, BORT=%s, MELP=%s.",
                         paste(fell_back, collapse = ", "), out$dara, out$bort, out$melp)
  else out$notes <- sprintf("Resolved tokens from cl_mma_codelist.csv: DARA=%s, BORT=%s, MELP=%s.",
                       out$dara, out$bort, out$melp)
  out
}

# The drug codes in a regimen string, dropping blanks. The engine already keeps
# steroids out of LOT_BASE_MEDS, so this is the list of MM agents.
MEDS_ARR <- "filter(split(LOT_BASE_MEDS, ' '), x -> length(x) > 0)"

# The steroid short-codes used across the repo's codelists (dashboard,
# steroid_codes.csv, engine rollup). The Q1 audit checks regimens against this
# fixed list; the token table backs it up by listing every code that appears.
STEROID_TOKENS <- c("DEX", "DEXA", "DEXAMETHASONE", "DEXAMETH",
                    "PRED", "PREDNISONE", "PREDNISOLONE",
                    "METHYLPRED", "METHYLPREDNISOLONE", "MPRED")

# Embedded dashboard tables are capped at this many rows (the full data always
# goes to the CSV files); mirrors the drilldown cap in the production dashboard.
DASH_MAX_ROWS <- 8000L

# Label used for lines that have no drug regimen (transplant / CAR-T-only).
blank_regimen_sql <- function(meds_col = "LOT_BASE_MEDS", type_col = "LOT_START_TYPE") {
  glue("CASE WHEN {meds_col} IS NULL OR trim({meds_col}) = ''
             THEN concat('(no drug regimen - ', coalesce({type_col}, 'unknown'), ' start)')
             ELSE {meds_col} END")
}

# ===========================================================================
# Q1a - every regimen per LOT (the "long lists"). One data.frame per LOT_NUM,
# ranked by distinct patients, with the per-line percentage. Transplant-only
# lines keep a labelled "(no drug regimen ...)" row so the counts reconcile
# with the per-line patient totals.
# ===========================================================================
q1_all_regimens <- function(con, lot_long) {
  denom <- db_q(con, glue("
    SELECT LOT_NUM, count(DISTINCT cast(PATID as string)) AS n_patients
    FROM {lot_long} GROUP BY LOT_NUM ORDER BY LOT_NUM"))

  all_reg <- db_q(con, glue("
    WITH l AS (
      SELECT LOT_NUM, cast(PATID as string) AS PATID,
             {blank_regimen_sql()} AS regimen
      FROM {lot_long}
    )
    SELECT LOT_NUM, regimen,
           count(DISTINCT PATID) AS n_patients,
           count(*)              AS n_lines
    FROM l GROUP BY LOT_NUM, regimen
    ORDER BY LOT_NUM, n_patients DESC, regimen"))

  if (nrow(all_reg) == 0)
    return(list(per_lot = list(),
                denom = data.frame(status = "No LOT rows found.", stringsAsFactors = FALSE)))

  per_lot <- list()
  for (ln in sort(unique(as.integer(num(all_reg$LOT_NUM))))) {
    d <- all_reg[as.integer(num(all_reg$LOT_NUM)) == ln, , drop = FALSE]
    dn <- num(denom$n_patients[as.integer(num(denom$LOT_NUM)) == ln][1])
    per_lot[[as.character(ln)]] <- data.frame(
      rank        = seq_len(nrow(d)),
      regimen     = d$regimen,
      n_patients  = as.integer(num(d$n_patients)),
      pct_of_line = vapply(num(d$n_patients), function(x) pct1(x, dn), numeric(1)),
      n_lines     = as.integer(num(d$n_lines)),
      stringsAsFactors = FALSE)
  }
  denom_df <- data.frame(line = paste0("LOT", denom$LOT_NUM),
                         n_line_patients = as.integer(num(denom$n_patients)),
                         stringsAsFactors = FALSE)
  list(per_lot = per_lot, denom = denom_df)
}

# ===========================================================================
# Q1b - steroid audit: does any steroid code show up in a regimen? (expected 0)
# plus the full agent-token vocabulary so a reader can see every agent that
# does appear. Same audit as the July-11 workbook.
# ===========================================================================
q1_steroid_audit <- function(con, lot_long) {
  ster_arr <- paste(sprintf("'%s'", STEROID_TOKENS), collapse = ", ")

  audit <- best_effort(db_q(con, glue("
    WITH ll AS (
      SELECT {MEDS_ARR} AS meds
      FROM {lot_long}
      WHERE LOT_BASE_MEDS IS NOT NULL AND trim(LOT_BASE_MEDS) <> ''
    )
    SELECT count(*)                                                              AS n_lot_regimen_rows,
           sum(CASE WHEN size(array_intersect(meds, array({ster_arr}))) > 0
                    THEN 1 ELSE 0 END)                                           AS n_rows_with_steroid_token
    FROM ll")), "steroid-in-regimen audit")

  vocab <- best_effort(db_q(con, glue("
    WITH base AS (
      SELECT cast(PATID as string) AS PATID, {MEDS_ARR} AS meds
      FROM {lot_long}
      WHERE LOT_BASE_MEDS IS NOT NULL AND trim(LOT_BASE_MEDS) <> ''
    )
    SELECT upper(tok)             AS agent_token,
           count(*)              AS n_regimen_rows,
           count(DISTINCT PATID) AS n_patients,
           CASE WHEN array_contains(array({ster_arr}), upper(tok))
                THEN 'steroid - not expected here' ELSE '' END AS note
    FROM base LATERAL VIEW explode(meds) t AS tok
    GROUP BY upper(tok) ORDER BY n_patients DESC")), "LOT regimen token vocabulary")

  list(audit = audit, vocab = vocab)
}

# ===========================================================================
# Q2 setup - the 1L DARA+BORT dual-therapy cohort as a temp view:
# LOT1 patients whose regimen is exactly the two agents (no other MM agent;
# backbone steroids never enter the regimen, so they do not change the pair).
# ===========================================================================
q2_build_dual_view <- function(con, lot_long, dara, bort) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW _jul20_dual AS
    WITH l1 AS (
      SELECT cast(PATID as string) AS PATID,
             cast(LOT_START_DT as date)    AS L1,
             cast(LOT_BASE_END_DT as date) AS L1_END,
             LOT_BASE_END_REASON           AS L1_END_REASON,
             {MEDS_ARR} AS meds
      FROM {lot_long}
      WHERE LOT_NUM = 1 AND LOT_BASE_MEDS IS NOT NULL AND trim(LOT_BASE_MEDS) <> ''
    )
    SELECT PATID, L1, L1_END, L1_END_REASON,
           coalesce(L1_END, cast('9999-12-31' as date)) AS L1_CAP
    FROM l1
    WHERE size(meds) = 2 AND array_contains(meds, '{dara}')
      AND array_contains(meds, '{bort}')"))
  num(db_q(con, "SELECT count(*) AS n FROM _jul20_dual")$n[1])
}

# Per-patient-per-agent episode (MAP) summary inside LOT1, as a temp view.
q2_build_agent_views <- function(con, map_tbl, dara, bort) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW _jul20_dual_agent AS
    SELECT d.PATID,
           upper(trim(m.MAP_MED_TYPE)) AS agent,
           count(*)                          AS n_episodes,
           min(cast(m.MAP_START_DT as date)) AS first_episode_start,
           max(cast(m.MAP_END_DT as date))   AS last_episode_end,
           sum(datediff(least(cast(m.MAP_END_DT as date), d.L1_CAP),
                        cast(m.MAP_START_DT as date)) + 1) AS days_covered_in_lot1
    FROM {map_tbl} m
    JOIN _jul20_dual d ON cast(m.PATID as string) = d.PATID
    WHERE upper(trim(m.MAP_MED_TYPE)) IN ('{dara}', '{bort}')
      AND cast(m.MAP_START_DT as date) BETWEEN d.L1 AND d.L1_CAP
    GROUP BY d.PATID, upper(trim(m.MAP_MED_TYPE))"))
  invisible(TRUE)
}

# Per-patient-per-agent claim counts inside LOT1 (administrations / fills),
# from the processed medication claims table. Optional - MMA_MED_PROCESSED may
# not be persisted; the caller degrades gracefully.
q2_build_claim_view <- function(con, mma_tbl, dara, bort) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW _jul20_dual_claims AS
    SELECT d.PATID,
           upper(trim(c.MED_ABBR)) AS agent,
           sum(CASE WHEN lower(c.CLAIM_TYPE) = 'medical'  THEN 1 ELSE 0 END) AS n_medical_claims,
           sum(CASE WHEN lower(c.CLAIM_TYPE) = 'pharmacy' THEN 1 ELSE 0 END) AS n_pharmacy_fills
    FROM {mma_tbl} c
    JOIN _jul20_dual d ON cast(c.PATID as string) = d.PATID
    WHERE upper(trim(c.MED_ABBR)) IN ('{dara}', '{bort}')
      AND cast(c.DATE_SERVICE as date) BETWEEN d.L1 AND d.L1_CAP
    GROUP BY d.PATID, upper(trim(c.MED_ABBR))"))
  invisible(TRUE)
}

# ===========================================================================
# Q2a - cycles per agent: episode-count and claim-count summaries plus the
# episode-count distribution. "Cycle" is a protocol concept the claims do not
# record; episodes (MAPs) and administration/fill counts are the proxies.
# ===========================================================================
q2_cycles_summary <- function(con, have_claims) {
  summ <- db_q(con, "
    SELECT agent,
           count(*)                              AS n_patients,
           percentile_approx(n_episodes, 0.5)    AS median_episodes,
           percentile_approx(n_episodes, 0.25)   AS p25_episodes,
           percentile_approx(n_episodes, 0.75)   AS p75_episodes,
           max(n_episodes)                       AS max_episodes,
           percentile_approx(days_covered_in_lot1, 0.5) AS median_days_covered
    FROM _jul20_dual_agent GROUP BY agent ORDER BY agent")

  dist <- db_q(con, "
    SELECT agent,
           CASE WHEN n_episodes >= 5 THEN '5+'
                ELSE cast(n_episodes as string) END AS n_episodes_bucket,
           count(*) AS n_patients
    FROM _jul20_dual_agent
    GROUP BY agent, CASE WHEN n_episodes >= 5 THEN '5+'
                         ELSE cast(n_episodes as string) END
    ORDER BY agent, n_episodes_bucket")

  out <- list(summary = summ, distribution = dist)
  if (have_claims) {
    out$claims <- db_q(con, "
      SELECT agent,
             count(*)                                  AS n_patients,
             percentile_approx(n_medical_claims, 0.5)  AS median_medical_claims,
             percentile_approx(n_medical_claims, 0.25) AS p25_medical_claims,
             percentile_approx(n_medical_claims, 0.75) AS p75_medical_claims,
             max(n_medical_claims)                     AS max_medical_claims,
             percentile_approx(n_pharmacy_fills, 0.5)  AS median_pharmacy_fills,
             max(n_pharmacy_fills)                     AS max_pharmacy_fills
      FROM _jul20_dual_claims GROUP BY agent ORDER BY agent")
  }
  out
}

# ===========================================================================
# Q2b - what the DARA+BORT patients receive in 2L (all regimens, plus a
# "(no 2L observed)" row so the denominator stays the full dual cohort).
# ===========================================================================
q2_lot2_regimens <- function(con, lot_long, n_dual) {
  d <- db_q(con, glue("
    WITH l2 AS (
      SELECT cast(PATID as string) AS PATID,
             {blank_regimen_sql()} AS regimen
      FROM {lot_long} WHERE LOT_NUM = 2
    )
    SELECT CASE WHEN l2.PATID IS NULL THEN '(no 2L observed)'
                ELSE l2.regimen END AS lot2_regimen,
           count(DISTINCT d.PATID) AS n_patients
    FROM _jul20_dual d LEFT JOIN l2 ON l2.PATID = d.PATID
    GROUP BY CASE WHEN l2.PATID IS NULL THEN '(no 2L observed)' ELSE l2.regimen END
    ORDER BY n_patients DESC, lot2_regimen"))
  if (nrow(d) == 0)
    return(data.frame(status = "No DARA+BORT dual patients found.", stringsAsFactors = FALSE))
  data.frame(rank = seq_len(nrow(d)),
             lot2_regimen = d$lot2_regimen,
             n_patients = as.integer(num(d$n_patients)),
             pct_of_dual = vapply(num(d$n_patients), function(x) pct1(x, n_dual), numeric(1)),
             stringsAsFactors = FALSE)
}

# ===========================================================================
# Q2c - when were the DARA+BORT patients diagnosed? INDEX_DATE (the qualifying
# MM diagnosis date from the Part-1 cohort) by calendar year.
# ===========================================================================
q2_diagnosis_years <- function(con, coh_tbl, n_dual) {
  d <- db_q(con, glue("
    SELECT year(cast(e.INDEX_DATE as date)) AS diagnosis_year,
           count(DISTINCT d.PATID)          AS n_patients
    FROM _jul20_dual d
    JOIN {coh_tbl} e ON cast(e.PATID as string) = d.PATID
    WHERE e.INDEX_DATE IS NOT NULL
    GROUP BY year(cast(e.INDEX_DATE as date))
    ORDER BY diagnosis_year"))
  if (nrow(d) == 0)
    return(data.frame(status = "No diagnosis dates found (ELIG_COH_FINAL join returned no rows).",
                      stringsAsFactors = FALSE))
  out <- data.frame(diagnosis_year = as.integer(num(d$diagnosis_year)),
                    n_patients = as.integer(num(d$n_patients)),
                    pct_of_dual = vapply(num(d$n_patients), function(x) pct1(x, n_dual), numeric(1)),
                    stringsAsFactors = FALSE)
  n_matched <- sum(out$n_patients)
  if (n_matched < n_dual)
    out <- rbind(out, data.frame(diagnosis_year = NA_integer_,
                                 n_patients = as.integer(n_dual - n_matched),
                                 pct_of_dual = pct1(n_dual - n_matched, n_dual),
                                 stringsAsFactors = FALSE))
  out
}

# ---------------------------------------------------------------------------
# DESCRIBE-based column discovery so we never hard-code a source schema
# (same pattern as lot1_studyteam_qs.R).
# ---------------------------------------------------------------------------
make_describe_cols <- function(con) {
  function(tbl) {
    d <- tryCatch(db_q(con, glue("DESCRIBE TABLE {tbl}")), error = function(e) NULL)
    if (is.null(d) || !"col_name" %in% names(d)) return(character(0))
    cn <- trimws(as.character(d$col_name))
    cn <- cn[nzchar(cn) & !startsWith(cn, "#")]
    unique(cn)
  }
}

# ===========================================================================
# Q2d setup - payer and region lookups for the dual cohort, each as a temp
# view keyed by PATID. Payer follows the production derivation (the enrollment
# span covering the LOT1 start; Medicare wins overlaps; else the latest span
# starting on/before LOT1; else Unknown). Region is probed at runtime because
# no pipeline table carries it: the first enrollment/member table with a
# region-like column is used, with the same covering-span preference when the
# table has span dates and a per-patient modal value otherwise.
# ===========================================================================
q2_build_payer_view <- function(con, enr) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW _jul20_payer AS
    WITH span AS (
      SELECT d.PATID,
             upper(trim(cast(e.BUS as string))) AS bus,
             row_number() OVER (PARTITION BY d.PATID
                                ORDER BY
                                  CASE WHEN cast(e.ELIGEND as date) >= d.L1
                                       THEN 0 ELSE 1 END,
                                  CASE WHEN cast(e.ELIGEND as date) >= d.L1
                                        AND upper(trim(cast(e.BUS as string))) = 'MCR'
                                       THEN 0 ELSE 1 END,
                                  cast(e.ELIGEFF as date) DESC,
                                  cast(e.ELIGEND as date) DESC) AS rn
      FROM _jul20_dual d
      LEFT JOIN {enr} e
        ON cast(e.PATID as string) = d.PATID
       AND cast(e.ELIGEFF as date) <= d.L1
    )
    SELECT PATID,
           CASE WHEN bus = 'MCR' THEN 'Medicare'
                WHEN bus = 'COM' THEN 'Commercial'
                WHEN bus IS NULL OR bus = '' THEN 'Unknown'
                ELSE concat('Other (', bus, ')') END AS payer
    FROM span WHERE rn = 1"))
  invisible(TRUE)
}

# Probe candidate CDM tables for a region-like column. Returns list(tbl, col,
# has_spans, tried) or NULL when nothing usable is reachable.
q2_find_region_source <- function(con, describe_cols) {
  tried <- character(0)
  for (base in c("member_cont_enrollment", "member_enrollment", "member")) {
    for (namer in list(cdm_src, cdm)) {
      tbl <- tryCatch(namer(base), error = function(e) NULL)
      if (is.null(tbl) || tbl %in% tried) next
      tried <- c(tried, tbl)
      cols <- describe_cols(tbl)
      if (length(cols) == 0) next
      up <- toupper(cols)
      hit <- cols[up == "REGION"]
      if (length(hit) == 0) hit <- cols[grepl("REGION|DIVISION", up)]
      if (length(hit) == 0) next
      return(list(tbl = tbl, col = hit[1],
                  has_spans = all(c("ELIGEFF", "ELIGEND") %in% up),
                  cols = cols, tried = tried))
    }
  }
  list(tbl = NULL, col = NULL, has_spans = FALSE, cols = character(0), tried = tried)
}

q2_build_region_view <- function(con, src) {
  if (src$has_spans) {
    db_exec(con, glue("
      CREATE OR REPLACE TEMPORARY VIEW _jul20_region AS
      WITH span AS (
        SELECT d.PATID,
               upper(trim(cast(e.{src$col} as string))) AS region,
               row_number() OVER (PARTITION BY d.PATID
                                  ORDER BY
                                    CASE WHEN cast(e.ELIGEND as date) >= d.L1
                                         THEN 0 ELSE 1 END,
                                    cast(e.ELIGEFF as date) DESC,
                                    cast(e.ELIGEND as date) DESC) AS rn
        FROM _jul20_dual d
        LEFT JOIN {src$tbl} e
          ON cast(e.PATID as string) = d.PATID
         AND cast(e.ELIGEFF as date) <= d.L1
      )
      SELECT PATID,
             CASE WHEN region IS NULL OR region = '' THEN 'Unknown'
                  ELSE region END AS region
      FROM span WHERE rn = 1"))
  } else {
    # No span dates on this table: take the per-patient modal value.
    db_exec(con, glue("
      CREATE OR REPLACE TEMPORARY VIEW _jul20_region AS
      WITH vals AS (
        SELECT d.PATID,
               upper(trim(cast(e.{src$col} as string))) AS region,
               count(*) AS n
        FROM _jul20_dual d
        JOIN {src$tbl} e ON cast(e.PATID as string) = d.PATID
        GROUP BY d.PATID, upper(trim(cast(e.{src$col} as string)))
      ),
      ranked AS (
        SELECT PATID, region,
               row_number() OVER (PARTITION BY PATID ORDER BY n DESC, region) AS rn
        FROM vals
      )
      SELECT PATID,
             CASE WHEN region IS NULL OR region = '' THEN 'Unknown'
                  ELSE region END AS region
      FROM ranked WHERE rn = 1"))
  }
  invisible(TRUE)
}

# ===========================================================================
# Q2d - region x payer cross-tab over the dual cohort (long counts pivoted to
# a region-by-payer grid with totals), plus an optional plan-type value-count
# context table when the enrollment table exposes a product/plan column.
# ===========================================================================
q2_region_payer_crosstab <- function(con, have_region, have_payer, n_dual) {
  reg_expr <- if (have_region) "coalesce(r.region, 'Unknown')" else "'(region unavailable)'"
  pay_expr <- if (have_payer)  "coalesce(p.payer, 'Unknown')"  else "'(payer unavailable)'"
  joins <- paste(
    if (have_payer)  "LEFT JOIN _jul20_payer p  ON p.PATID = d.PATID" else "",
    if (have_region) "LEFT JOIN _jul20_region r ON r.PATID = d.PATID" else "",
    sep = "\n    ")
  long <- db_q(con, glue("
    SELECT {reg_expr} AS region, {pay_expr} AS payer,
           count(DISTINCT d.PATID) AS n_patients
    FROM _jul20_dual d
    {joins}
    GROUP BY {reg_expr}, {pay_expr}
    ORDER BY region, payer"))
  if (nrow(long) == 0)
    return(list(long = data.frame(status = "No dual patients to cross-tabulate.",
                                  stringsAsFactors = FALSE), wide = NULL))

  long$n_patients <- as.integer(num(long$n_patients))
  long$pct_of_dual <- vapply(long$n_patients, function(x) pct1(x, n_dual), numeric(1))

  # Pivot long -> region rows x payer columns, with row/column totals.
  regions <- sort(unique(long$region))
  payers  <- sort(unique(long$payer))
  wide <- data.frame(region = regions, stringsAsFactors = FALSE)
  for (p in payers) {
    v <- vapply(regions, function(rg) {
      i <- which(long$region == rg & long$payer == p)
      if (length(i)) long$n_patients[i[1]] else 0L
    }, integer(1))
    wide[[p]] <- v
  }
  wide$row_total <- rowSums(wide[, payers, drop = FALSE])
  tot <- c(region = "TOTAL",
           as.list(colSums(wide[, c(payers, "row_total"), drop = FALSE])))
  wide <- rbind(wide, as.data.frame(tot, stringsAsFactors = FALSE, check.names = FALSE))
  list(long = long, wide = wide)
}

q2_plan_type_context <- function(con, describe_cols, enr) {
  cols <- describe_cols(enr)
  up <- toupper(cols)
  cand <- cols[grepl("PRODUCT|PLAN_TYPE|PLANTYPE|LOB|GRP", up) & up != "BUS"]
  if (length(cand) == 0)
    return(data.frame(status = paste0("No product/plan-type column found on ", enr,
                                      " (columns probed: ", paste(head(cols, 40), collapse = ", "), ")"),
                      stringsAsFactors = FALSE))
  col <- cand[1]
  d <- db_q(con, glue("
    SELECT '{col}' AS plan_type_column,
           coalesce(nullif(upper(trim(cast(e.{col} as string))), ''), '(blank)') AS value,
           count(DISTINCT d.PATID) AS n_patients
    FROM _jul20_dual d
    JOIN {enr} e ON cast(e.PATID as string) = d.PATID
    GROUP BY coalesce(nullif(upper(trim(cast(e.{col} as string))), ''), '(blank)')
    ORDER BY n_patients DESC"))
  if (nrow(d) == 0)
    return(data.frame(status = sprintf("Plan-type column %s had no values for the dual cohort.", col),
                      stringsAsFactors = FALSE))
  d
}

# ===========================================================================
# Q2 - patient-level roster (one row per dual patient). Written as the main
# downloadable CSV; the same frame (capped) also lands in the dashboard.
# ===========================================================================
q2_roster <- function(con, lot_long, coh_tbl, dara, bort,
                      have_claims, have_payer, have_region) {
  claims_sel <- if (have_claims) "
           dc.n_medical_claims  AS dara_medical_claims,
           dc.n_pharmacy_fills  AS dara_pharmacy_fills,
           bc.n_medical_claims  AS bort_medical_claims,
           bc.n_pharmacy_fills  AS bort_pharmacy_fills," else "
           cast(NULL as int) AS dara_medical_claims,
           cast(NULL as int) AS dara_pharmacy_fills,
           cast(NULL as int) AS bort_medical_claims,
           cast(NULL as int) AS bort_pharmacy_fills,"
  claims_join <- if (have_claims) glue("
    LEFT JOIN _jul20_dual_claims dc ON dc.PATID = d.PATID AND dc.agent = '{dara}'
    LEFT JOIN _jul20_dual_claims bc ON bc.PATID = d.PATID AND bc.agent = '{bort}'") else ""
  payer_sel  <- if (have_payer)  "coalesce(p.payer, 'Unknown')"   else "'(unavailable)'"
  payer_join <- if (have_payer)  "LEFT JOIN _jul20_payer p ON p.PATID = d.PATID" else ""
  region_sel  <- if (have_region) "coalesce(r.region, 'Unknown')" else "'(unavailable)'"
  region_join <- if (have_region) "LEFT JOIN _jul20_region r ON r.PATID = d.PATID" else ""

  db_q(con, glue("
    WITH l2 AS (
      SELECT cast(PATID as string) AS PATID,
             cast(LOT_START_DT as date) AS L2_START,
             LOT_START_TYPE AS L2_START_TYPE,
             {blank_regimen_sql()} AS L2_REGIMEN
      FROM {lot_long} WHERE LOT_NUM = 2
    )
    SELECT d.PATID,
           cast(e.INDEX_DATE as string)          AS mm_diagnosis_index_date,
           year(cast(e.INDEX_DATE as date))      AS mm_diagnosis_year,
           e.AGE_INDEX_YR                        AS age_at_index,
           e.GDR_CD                              AS gender,
           cast(d.L1 as string)                  AS lot1_start_dt,
           cast(d.L1_END as string)              AS lot1_end_dt,
           d.L1_END_REASON                       AS lot1_end_reason,
           da.n_episodes                         AS dara_n_episodes,
           cast(da.first_episode_start as string) AS dara_first_episode_start,
           cast(da.last_episode_end as string)   AS dara_last_episode_end,
           da.days_covered_in_lot1               AS dara_days_covered,
           bo.n_episodes                         AS bort_n_episodes,
           cast(bo.first_episode_start as string) AS bort_first_episode_start,
           cast(bo.last_episode_end as string)   AS bort_last_episode_end,
           bo.days_covered_in_lot1               AS bort_days_covered,{claims_sel}
           CASE WHEN l2.PATID IS NULL THEN 0 ELSE 1 END AS has_lot2,
           cast(l2.L2_START as string)           AS lot2_start_dt,
           l2.L2_START_TYPE                      AS lot2_start_type,
           l2.L2_REGIMEN                         AS lot2_regimen,
           {region_sel}                          AS region,
           {payer_sel}                           AS payer
    FROM _jul20_dual d
    LEFT JOIN {coh_tbl} e ON cast(e.PATID as string) = d.PATID
    LEFT JOIN _jul20_dual_agent da ON da.PATID = d.PATID AND da.agent = '{dara}'
    LEFT JOIN _jul20_dual_agent bo ON bo.PATID = d.PATID AND bo.agent = '{bort}'{claims_join}
    LEFT JOIN l2 ON l2.PATID = d.PATID
    {payer_join}
    {region_join}
    ORDER BY d.PATID"))
}

# Per-MAP detail for the dual cohort (every DARA/BORT episode from LOT1 start
# on, flagged for the induction window and the LOT1 span) - the "individual
# episodes and MAPs" Julia asked for, one row per episode.
q2_map_detail <- function(con, map_tbl, dara, bort, w1) {
  db_q(con, glue("
    SELECT d.PATID,
           upper(trim(m.MAP_MED_TYPE))        AS agent,
           m.MAP_CNT                          AS episode_number,
           cast(m.MAP_START_DT as string)     AS map_start_dt,
           cast(m.MAP_END_DT as string)       AS map_end_dt,
           datediff(cast(m.MAP_END_DT as date),
                    cast(m.MAP_START_DT as date)) + 1 AS map_days,
           m.MAP_DISCON_FLG                   AS map_discon_flg,
           CASE WHEN cast(m.MAP_START_DT as date)
                     BETWEEN d.L1 AND date_add(d.L1, {w1} - 1)
                THEN 1 ELSE 0 END             AS starts_in_induction_window,
           CASE WHEN cast(m.MAP_START_DT as date) BETWEEN d.L1 AND d.L1_CAP
                THEN 1 ELSE 0 END             AS starts_in_lot1
    FROM {map_tbl} m
    JOIN _jul20_dual d ON cast(m.PATID as string) = d.PATID
    WHERE upper(trim(m.MAP_MED_TYPE)) IN ('{dara}', '{bort}')
      AND cast(m.MAP_START_DT as date) >= d.L1
    ORDER BY d.PATID, agent, m.MAP_CNT"))
}

# ===========================================================================
# Q3b - CAR-T rule impact. Current rule: a CAR-T on/after the LOT1 start -
# including inside the 60-day induction window - ends LOT1 the day before
# (END_REASON SCT_CART or CART_INIT) and opens a CART-started LOT2.
# Candidate rule: a CAR-T inside the induction window stays in LOT1.
# Affected lines = LOT1 rows ended by CAR-T whose first CAR-T date falls in
# [LOT1 start, start + w1 - 1]. Simulation: the CART LOT2 folds back into
# LOT1 (new end = the old LOT2's end) and later lines renumber down by one.
# ===========================================================================
q3_cart_impact <- function(con, lot_long, sct_tbl, w1) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW _jul20_cart AS
    WITH l1 AS (
      SELECT cast(PATID as string) AS PATID,
             cast(LOT_START_DT as date)    AS L1,
             cast(LOT_BASE_END_DT as date) AS L1_END,
             LOT_BASE_END_REASON           AS END_REASON
      FROM {lot_long} WHERE LOT_NUM = 1
    ),
    sct AS (
      SELECT cast(PATID as string) AS PATID,
             min(cast(FIRST_CART_DT as date)) AS CART_DT
      FROM {sct_tbl} WHERE FIRST_CART_DT IS NOT NULL
      GROUP BY cast(PATID as string)
    ),
    l2 AS (
      SELECT cast(PATID as string) AS PATID,
             cast(LOT_START_DT as date)    AS L2,
             LOT_START_TYPE                AS L2_TYPE,
             {blank_regimen_sql()}         AS L2_REGIMEN,
             cast(LOT_BASE_END_DT as date) AS L2_END,
             LOT_BASE_END_REASON           AS L2_END_REASON
      FROM {lot_long} WHERE LOT_NUM = 2
    ),
    cnt AS (
      SELECT cast(PATID as string) AS PATID, count(*) AS n_lots
      FROM {lot_long} GROUP BY cast(PATID as string)
    )
    SELECT l.PATID, l.L1, l.L1_END, l.END_REASON, s.CART_DT,
           datediff(s.CART_DT, l.L1) AS days_from_lot1_start,
           CASE WHEN s.CART_DT IS NOT NULL
                 AND s.CART_DT BETWEEN l.L1 AND date_add(l.L1, {w1} - 1)
                THEN 1 ELSE 0 END AS cart_in_window,
           CASE WHEN l.END_REASON IN ('SCT_CART', 'CART_INIT')
                THEN 1 ELSE 0 END AS ended_by_cart,
           l2.L2, l2.L2_TYPE, l2.L2_REGIMEN, l2.L2_END, l2.L2_END_REASON,
           c.n_lots
    FROM l1 l
    LEFT JOIN sct s ON s.PATID = l.PATID
    LEFT JOIN l2  ON l2.PATID  = l.PATID
    LEFT JOIN cnt c ON c.PATID = l.PATID"))

  inv <- db_q(con, glue("
    SELECT
      count(*)                                                          AS n_lot1_patients,
      sum(CASE WHEN CART_DT IS NOT NULL THEN 1 ELSE 0 END)              AS n_any_cart_on_after_lot1,
      sum(cart_in_window)                                               AS n_cart_in_induction_window,
      sum(CASE WHEN cart_in_window = 1 AND ended_by_cart = 1
               THEN 1 ELSE 0 END)                                       AS n_affected_lot1_ended_by_cart,
      sum(CASE WHEN cart_in_window = 1 AND ended_by_cart = 0
               THEN 1 ELSE 0 END)                                       AS n_in_window_not_ending_lot1,
      sum(CASE WHEN cart_in_window = 1 AND ended_by_cart = 1
                AND END_REASON = 'SCT_CART' THEN 1 ELSE 0 END)          AS n_affected_reason_sct_cart,
      sum(CASE WHEN cart_in_window = 1 AND ended_by_cart = 1
                AND END_REASON = 'CART_INIT' THEN 1 ELSE 0 END)         AS n_affected_reason_cart_init,
      sum(CASE WHEN cart_in_window = 1 AND ended_by_cart = 1
                AND L2 IS NOT NULL THEN 1 ELSE 0 END)                   AS n_affected_with_lot2_to_merge,
      sum(CASE WHEN cart_in_window = 1 AND ended_by_cart = 1
                AND L2_TYPE = 'CART' THEN 1 ELSE 0 END)                 AS n_affected_lot2_type_cart
    FROM _jul20_cart"))

  timing <- db_q(con, "
    SELECT CASE
             WHEN CART_DT IS NULL THEN '(no CAR-T on/after LOT1)'
             WHEN days_from_lot1_start = 0 THEN 'day 0 (on the LOT1 start date)'
             WHEN days_from_lot1_start BETWEEN 1 AND 29 THEN 'day 1-29'
             WHEN days_from_lot1_start BETWEEN 30 AND 59 THEN 'day 30-59'
             ELSE 'day 60+ (outside the induction window)'
           END AS first_cart_timing,
           count(*)            AS n_patients,
           sum(ended_by_cart)  AS n_lot1_ended_by_cart
    FROM _jul20_cart
    GROUP BY CASE
             WHEN CART_DT IS NULL THEN '(no CAR-T on/after LOT1)'
             WHEN days_from_lot1_start = 0 THEN 'day 0 (on the LOT1 start date)'
             WHEN days_from_lot1_start BETWEEN 1 AND 29 THEN 'day 1-29'
             WHEN days_from_lot1_start BETWEEN 30 AND 59 THEN 'day 30-59'
             ELSE 'day 60+ (outside the induction window)'
           END
    ORDER BY first_cart_timing")

  # Lines-per-patient distribution before vs after the merge. Affected
  # patients with a LOT2 lose one line; everyone else is unchanged.
  shift <- db_q(con, "
    SELECT n_lots,
           count(*) AS n_patients,
           sum(CASE WHEN cart_in_window = 1 AND ended_by_cart = 1
                     AND L2 IS NOT NULL THEN 1 ELSE 0 END) AS n_losing_one_line
    FROM _jul20_cart
    GROUP BY n_lots ORDER BY n_lots")

  roster <- db_q(con, "
    SELECT PATID,
           cast(L1 as string)      AS lot1_start_dt,
           cast(L1_END as string)  AS lot1_end_dt,
           END_REASON              AS lot1_end_reason,
           cast(CART_DT as string) AS first_cart_dt,
           days_from_lot1_start,
           cast(L2 as string)      AS lot2_start_dt,
           L2_TYPE                 AS lot2_start_type,
           L2_REGIMEN              AS lot2_regimen,
           cast(L2_END as string)  AS lot2_end_dt,
           L2_END_REASON           AS lot2_end_reason,
           cast(L2_END as string)  AS simulated_new_lot1_end_dt,
           n_lots                  AS n_lots_current,
           CASE WHEN L2 IS NOT NULL THEN n_lots - 1 ELSE n_lots END AS n_lots_simulated
    FROM _jul20_cart
    WHERE cart_in_window = 1 AND ended_by_cart = 1
    ORDER BY PATID")

  list(inventory = inv, timing = timing, shift = shift, roster = roster)
}

# Turns the q3 shift frames into a before/after lines-per-patient table.
q3_shift_table <- function(shift, n_col = "n_losing_one_line") {
  if (is_status_table(shift) || nrow(shift) == 0) return(shift)
  lots  <- as.integer(num(shift$n_lots))
  n     <- as.integer(num(shift$n_patients))
  lose  <- as.integer(num(shift[[n_col]]))
  after <- integer(max(lots))
  before <- integer(max(lots))
  for (i in seq_along(lots)) {
    before[lots[i]] <- before[lots[i]] + n[i]
    stay <- n[i] - lose[i]
    after[lots[i]] <- after[lots[i]] + stay
    tgt <- max(1L, lots[i] - 1L)
    after[tgt] <- after[tgt] + lose[i]
  }
  data.frame(lines_per_patient = seq_len(max(lots)),
             n_patients_current = before,
             n_patients_simulated = after,
             change = after - before,
             stringsAsFactors = FALSE)
}

# ===========================================================================
# Q3a - MELP rule impact. Current rule: MELP is an ordinary agent - a MELP MAP
# starting after the induction window ends the line (MED_ADD) and/or starts
# the next line. The candidate rule keys each advancing MELP to the FIRST MELP
# MAP of the line it follows: 60-180 days after it -> do not advance;
# otherwise -> MELP is part of the line. Read literally both branches stop the
# advance, so the tabs show the literal reading AND the narrow one (only the
# 60-180-day recurrences suppressed), with the timing decomposition.
#
# A "MELP boundary" is a line transition attributable to MELP: the earlier
# line ended MED_ADD with MELP as the added drug, and/or the next line is
# MED-started on the date a MELP MAP begins.
# ===========================================================================
q3_melp_impact <- function(con, lot_long, map_tbl, melp) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW _jul20_melp_maps AS
    SELECT cast(PATID as string) AS PATID,
           cast(MAP_START_DT as date) AS MSTART
    FROM {map_tbl}
    WHERE upper(trim(MAP_MED_TYPE)) = '{melp}'"))

  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW _jul20_lots AS
    SELECT cast(PATID as string) AS PATID,
           LOT_NUM,
           cast(LOT_START_DT as date)    AS LSTART,
           cast(LOT_BASE_END_DT as date) AS LEND,
           LOT_START_TYPE,
           LOT_BASE_END_REASON,
           upper(trim(coalesce(LOT_BASE_1ST_ADD_MED, ''))) AS ADD_MED,
           cast(LOT_BASE_1ST_ADD_MED_DT as date)           AS ADD_DT,
           coalesce(LOT_TX_AUTO_FLG, 0) AS AUTO_FLG,
           LOT_BASE_MEDS
    FROM {lot_long}"))

  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW _jul20_melp_bounds AS
    WITH b AS (
      SELECT p.PATID,
             p.LOT_NUM              AS prev_lot,
             p.LSTART               AS prev_start,
             p.LEND                 AS prev_end,
             p.LOT_BASE_END_REASON  AS prev_end_reason,
             p.LOT_BASE_MEDS        AS prev_regimen,
             p.ADD_DT,
             p.AUTO_FLG             AS prev_auto_flg,
             n.LOT_NUM              AS next_lot,
             n.LSTART               AS next_start,
             n.LOT_START_TYPE       AS next_start_type,
             n.AUTO_FLG             AS next_auto_flg,
             n.LOT_BASE_MEDS        AS next_regimen,
             CASE WHEN p.LOT_BASE_END_REASON = 'MED_ADD' AND p.ADD_MED = '{melp}'
                  THEN 1 ELSE 0 END AS ended_by_melp_add,
             CASE WHEN n.LOT_START_TYPE = 'MED' AND mm.PATID IS NOT NULL
                  THEN 1 ELSE 0 END AS next_starts_on_melp
      FROM _jul20_lots p
      LEFT JOIN _jul20_lots n
        ON n.PATID = p.PATID AND n.LOT_NUM = p.LOT_NUM + 1
      LEFT JOIN (SELECT DISTINCT PATID, MSTART FROM _jul20_melp_maps) mm
        ON mm.PATID = p.PATID AND mm.MSTART = n.LSTART
    ),
    adv AS (
      SELECT *,
             CASE WHEN ended_by_melp_add = 1 THEN date_add(ADD_DT, 1)
                  ELSE next_start END AS adv_melp_start
      FROM b
      WHERE ended_by_melp_add = 1 OR next_starts_on_melp = 1
    ),
    anch AS (
      SELECT a.PATID, a.prev_lot, min(m.MSTART) AS anchor_melp_start
      FROM adv a
      JOIN _jul20_melp_maps m
        ON m.PATID = a.PATID
       AND m.MSTART >= a.prev_start
       AND m.MSTART <  a.adv_melp_start
       AND m.MSTART <= coalesce(a.prev_end, a.adv_melp_start)
      GROUP BY a.PATID, a.prev_lot
    )
    SELECT a.*,
           anch.anchor_melp_start,
           CASE WHEN anch.anchor_melp_start IS NULL THEN NULL
                ELSE datediff(a.adv_melp_start, anch.anchor_melp_start) END AS gap_days,
           CASE
             WHEN anch.anchor_melp_start IS NULL THEN 'first MELP of the line (no earlier MELP anchor)'
             WHEN datediff(a.adv_melp_start, anch.anchor_melp_start) < 60 THEN 'under 60 days'
             WHEN datediff(a.adv_melp_start, anch.anchor_melp_start) <= 180 THEN '60-180 days'
             ELSE 'over 180 days'
           END AS gap_bucket
    FROM adv a
    LEFT JOIN anch ON anch.PATID = a.PATID AND anch.prev_lot = a.prev_lot"))

  totals <- db_q(con, glue("
    SELECT
      (SELECT count(DISTINCT PATID) FROM _jul20_melp_maps
        WHERE PATID IN (SELECT cast(PATID as string) FROM {lot_long}))  AS n_patients_with_melp_map,
      (SELECT count(*) FROM _jul20_melp_bounds)                          AS n_melp_boundaries,
      (SELECT count(DISTINCT PATID) FROM _jul20_melp_bounds)             AS n_patients_with_melp_boundary,
      (SELECT count(*) FROM _jul20_melp_bounds WHERE gap_bucket = '60-180 days')
                                                                         AS n_boundaries_60_180,
      (SELECT count(*) FROM _jul20_melp_bounds WHERE next_lot IS NOT NULL)
                                                                         AS n_boundaries_with_next_line"))

  inv <- db_q(con, "
    SELECT gap_bucket,
           count(*)                                                    AS n_boundaries,
           count(DISTINCT PATID)                                       AS n_patients,
           sum(ended_by_melp_add)                                      AS n_prev_ended_med_add_melp,
           sum(next_starts_on_melp)                                    AS n_next_line_starts_on_melp,
           sum(CASE WHEN prev_auto_flg = 1 OR coalesce(next_auto_flg, 0) = 1
                     OR coalesce(next_start_type, '') = 'SCT_AUTO'
                    THEN 1 ELSE 0 END)                                 AS n_with_transplant_context
    FROM _jul20_melp_bounds
    GROUP BY gap_bucket
    ORDER BY gap_bucket")

  by_line <- db_q(con, "
    SELECT concat('LOT', cast(prev_lot as string), ' -> ',
                  CASE WHEN next_lot IS NULL THEN '(line end only)'
                       ELSE concat('LOT', cast(next_lot as string)) END) AS boundary,
           count(*) AS n_boundaries,
           count(DISTINCT PATID) AS n_patients
    FROM _jul20_melp_bounds
    GROUP BY prev_lot, next_lot
    ORDER BY prev_lot, next_lot")

  # Lines-per-patient shift under both readings. Only boundaries with a next
  # line reduce the line count when suppressed.
  shift <- db_q(con, glue("
    WITH cnt AS (
      SELECT cast(PATID as string) AS PATID, count(*) AS n_lots
      FROM {lot_long} GROUP BY cast(PATID as string)
    ),
    supp AS (
      SELECT PATID,
             sum(CASE WHEN next_lot IS NOT NULL THEN 1 ELSE 0 END) AS n_supp_literal,
             sum(CASE WHEN next_lot IS NOT NULL AND gap_bucket = '60-180 days'
                      THEN 1 ELSE 0 END)                           AS n_supp_narrow
      FROM _jul20_melp_bounds GROUP BY PATID
    )
    SELECT c.n_lots,
           count(*)                              AS n_patients,
           sum(coalesce(s.n_supp_literal, 0))    AS n_lines_removed_literal,
           sum(coalesce(s.n_supp_narrow, 0))     AS n_lines_removed_narrow
    FROM cnt c LEFT JOIN supp s ON s.PATID = c.PATID
    GROUP BY c.n_lots ORDER BY c.n_lots"))

  roster <- db_q(con, "
    SELECT PATID,
           prev_lot,
           cast(prev_start as string)        AS prev_lot_start_dt,
           cast(prev_end as string)          AS prev_lot_end_dt,
           prev_end_reason,
           prev_regimen,
           ended_by_melp_add,
           next_starts_on_melp,
           next_lot,
           cast(next_start as string)        AS next_lot_start_dt,
           next_start_type,
           next_regimen,
           cast(adv_melp_start as string)    AS advancing_melp_map_start_dt,
           cast(anchor_melp_start as string) AS first_melp_map_in_line_dt,
           gap_days,
           gap_bucket,
           prev_auto_flg,
           coalesce(next_auto_flg, 0)        AS next_auto_flg
    FROM _jul20_melp_bounds
    ORDER BY PATID, prev_lot")

  list(totals = totals, inventory = inv, by_line = by_line,
       shift = shift, roster = roster)
}

# Before/after lines-per-patient for the MELP simulation (both readings).
# Approximation stated in the tab: each suppressed boundary merges two lines,
# so a patient's line count drops by their number of suppressed boundaries.
q3_melp_shift_table <- function(shift) {
  if (is_status_table(shift) || nrow(shift) == 0) return(shift)
  lots <- as.integer(num(shift$n_lots))
  n    <- as.integer(num(shift$n_patients))
  data.frame(lines_per_patient = lots,
             n_patients_current = n,
             n_lines_removed_literal = as.integer(num(shift$n_lines_removed_literal)),
             n_lines_removed_narrow  = as.integer(num(shift$n_lines_removed_narrow)),
             stringsAsFactors = FALSE)
}

# ===========================================================================
main <- function() {
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")

  # The workbook is Excel, so check for openxlsx up front (before any
  # warehouse work) and stop with an install hint if it is missing.
  if (!requireNamespace("openxlsx", quietly = TRUE))
    stop("openxlsx is required to build the Excel workbook. Install it with ",
         "install.packages('openxlsx') and re-run.")

  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  out_dir <- cfg$output_dir
  if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  stamp <- format(Sys.time(), "%Y%m%d_%H%M%S")

  # ---- Cohort selection --------------------------------------------------
  cohort_mode <- toupper(Sys.getenv("LOT_COHORT", unset = "NDMM"))
  if (cohort_mode == "FULL") {
    lot_long <- wrk("LOT_LONG")
    cohort_label <- "full LOT cohort (all LOT1 patients)"
  } else {
    cohort_mode <- "NDMM"
    lot_long <- wrk("NDMM_LOT_LONG_FILT")
    cohort_label <- "NDMM newly-diagnosed 1L study cohort"
  }
  map_tbl <- wrk("MAP_STACKED")
  sct_tbl <- wrk("LOT1_SCT")
  mma_tbl <- wrk("MMA_MED_PROCESSED")
  coh_tbl <- wrk(cfg$input_cohort_table)

  log_msg(SEP)
  log_msg("July-20 study-team questions [", cohort_label,
          "] -> workbook + refreshed dashboard + CSVs")
  log_msg(SEP)
  if (!vqs_readable(con, lot_long)) {
    if (cohort_mode == "NDMM")
      stop("Cannot read ", lot_long, ". Run 06_ndmm_dashboard.R first to persist ",
           "NDMM_LOT_LONG_FILT (LOT_LONG restricted to the NDMM study cohort), or set ",
           "LOT_COHORT=FULL to run on LOT_LONG.")
    stop("Cannot read ", lot_long, ". Build the LOT pipeline (02_lot1.R / 03_lot2_5.R) first.")
  }
  have_map <- vqs_readable(con, map_tbl)
  have_sct <- vqs_readable(con, sct_tbl)
  have_mma <- vqs_readable(con, mma_tbl)
  have_coh <- vqs_readable(con, coh_tbl)
  if (!have_map) log_msg("WARNING: ", map_tbl, " not readable - Q2 episodes and the Q3a MELP simulation cannot be built.")
  if (!have_sct) log_msg("WARNING: ", sct_tbl, " not readable - the Q3b CAR-T simulation cannot be built.")
  if (!have_mma) log_msg("NOTE: ", mma_tbl, " not readable - per-agent claim counts will be blank (episodes still reported).")
  if (!have_coh) log_msg("WARNING: ", coh_tbl, " not readable - diagnosis dates cannot be reported.")

  tok <- resolve_jul20_tokens(con)
  log_msg(paste(tok$notes, collapse = " "))

  describe_cols <- make_describe_cols(con)

  write_out <- function(df, tag) {
    if (is.null(df) || !is.data.frame(df) || nrow(df) == 0 || is_status_table(df)) {
      log_msg("  (", tag, ": no rows to write)")
      return(invisible(NULL))
    }
    f <- file.path(out_dir, paste0("jul20_qs_", tag, "_", tolower(cohort_mode), "_", stamp, ".csv"))
    write.csv(df, f, row.names = FALSE)
    log_msg("  wrote ", tag, " -> ", f, " (", nrow(df), " rows)")
    f
  }

  n_lot1 <- num(db_q(con, glue(
    "SELECT count(DISTINCT cast(PATID as string)) AS n FROM {lot_long} WHERE LOT_NUM = 1"))$n[1])
  log_msg(sprintf("Cohort denominator: LOT1 = %s patients.", format(n_lot1, big.mark = ",")))

  sheets <- list()
  add_sheet <- function(...) sheets[[length(sheets) + 1L]] <<- list(...)

  # Reasons the run counts as incomplete, beyond the failed-table scan at the
  # end: a token fallback, a steroid hit, a skipped dashboard, or a Q2/Q3
  # input table that never became readable.
  extra_gaps <- character()
  if (!isTRUE(tok$resolved))
    extra_gaps <- c(extra_gaps,
      "Agent tokens could not be resolved from cl_mma_codelist.csv - fell back to defaults (DARA/BORT/MELP); every token-based answer (Q2 and Q3a) is unverified")

  # Dashboard availability (ask #1 is the dashboard itself).
  dash_ok <- .have_dashboard_helpers &&
    isTRUE(tryCatch(exists("save_table") && exists("build_dashboard") &&
                    exists("add_html_card"), error = function(e) FALSE)) &&
    requireNamespace("DT", quietly = TRUE) &&
    requireNamespace("htmlwidgets", quietly = TRUE) &&
    requireNamespace("jsonlite", quietly = TRUE) &&
    requireNamespace("base64enc", quietly = TRUE)
  if (dash_ok) {
    cfg$build_dashboard <<- TRUE
    dashboard_items <<- list()
  } else {
    extra_gaps <- c(extra_gaps,
      "Q1 refreshed dashboard could not be built (dashboard helpers or the DT/htmlwidgets/jsonlite/base64enc packages are unavailable) - the regimen CSVs and workbook tabs still carry the content")
    log_msg("WARNING: dashboard packages unavailable - Q1 dashboard skipped (CSVs still written).")
  }
  dash_table <- function(df, section, title) {
    if (!dash_ok || !is.data.frame(df)) return(invisible(NULL))
    shown <- df
    if (nrow(shown) > DASH_MAX_ROWS) {
      shown <- shown[seq_len(DASH_MAX_ROWS), , drop = FALSE]
      title <- paste0(title, " (first ", DASH_MAX_ROWS, " rows - full data in the CSV)")
    }
    save_table(shown, section, title)
  }
  dash_card <- function(html, section, title) {
    if (!dash_ok) return(invisible(NULL))
    add_html_card(html, section, title)
  }

  # ---- Q1a: all regimens per LOT ----------------------------------------
  q1 <- best_effort(q1_all_regimens(con, lot_long), "all regimens per LOT")
  q1_failed <- is.data.frame(q1)
  if (!q1_failed) {
    for (ln in names(q1$per_lot))
      write_out(q1$per_lot[[ln]], paste0("all_regimens_lot", ln))
  }

  # ---- Q1b: steroid audit ------------------------------------------------
  aud <- q1_steroid_audit(con, lot_long)
  aud_failed <- is_status_table(aud$audit)
  aud_hits <- if (aud_failed) NA_integer_
              else suppressWarnings(as.integer(num(aud$audit$n_rows_with_steroid_token[1])))
  if (aud_failed) {
    ster_line <- "The steroid audit could not run (see the status table on the steroid tab)."
  } else if (isTRUE(aud_hits > 0)) {
    extra_gaps <- c(extra_gaps, sprintf(
      "Q1 steroid audit failed: %d regimen row(s) contain a steroid token - investigate before sharing", aud_hits))
    ster_line <- sprintf(
      "Audit FAILED: %d regimen row(s) contain a steroid token - unexpected; investigate before using these lists.", aud_hits)
  } else if (is.na(aud_hits)) {
    extra_gaps <- c(extra_gaps, "Q1 steroid audit inconclusive - no usable count (no LOT regimen rows?)")
    ster_line <- "The steroid audit returned no usable count this run, so it is inconclusive."
  } else {
    ster_line <- paste0(
      "Steroids never enter the LOT rules or the regimen strings (the engine excludes them by construction), ",
      "and the audit found no steroid token in any regimen - so these lists are steroid-free without any re-run.")
  }

  # ---- Q2: DARA+BORT 1L dual therapy ------------------------------------
  n_dual <- NA_real_
  q2_tabs <- list(); q2_notes <- character()
  q2_cycles <- NULL; q2_l2 <- NULL; q2_dx <- NULL
  roster <- NULL; map_detail <- NULL
  xt <- NULL; plan_ctx <- NULL
  have_payer <- FALSE; have_region <- FALSE
  region_note <- ""; payer_note <- ""

  dual_res <- best_effort(q2_build_dual_view(con, lot_long, tok$dara, tok$bort),
                          "DARA+BORT dual cohort")
  n_dual <- if (is_status_table(dual_res)) NA_real_ else num(dual_res[1])
  if (length(n_dual) == 0 || is.na(n_dual)) {
    n_dual <- NA_real_
    q2_notes <- "The DARA+BORT dual cohort could not be built - see the status rows."
    q2_tabs[["DARA+BORT dual cohort"]] <- data.frame(
      status = "Could not build the 1L DARA+BORT dual-therapy cohort view.",
      stringsAsFactors = FALSE)
  } else {
    log_msg(sprintf("1L DARA+BORT dual-therapy patients: %s.", format(n_dual, big.mark = ",")))

    have_agent <- FALSE
    if (have_map) {
      have_agent <- !is_status_table(best_effort(
        q2_build_agent_views(con, map_tbl, tok$dara, tok$bort), "per-agent episode view"))
    }
    have_claims <- FALSE
    if (have_mma) {
      have_claims <- !is_status_table(best_effort(
        q2_build_claim_view(con, mma_tbl, tok$dara, tok$bort), "per-agent claim view"))
    }

    # Payer (production derivation) and region (probed) lookups.
    enr <- tryCatch(cdm_src("member_enrollment"), error = function(e) NULL)
    enr_ok <- !is.null(enr) && isTRUE(tryCatch({
      db_q(con, glue("SELECT BUS, ELIGEFF, ELIGEND FROM {enr} LIMIT 1")); TRUE
    }, error = function(e) FALSE))
    if (enr_ok) {
      have_payer <- !is_status_table(best_effort(q2_build_payer_view(con, enr), "payer lookup"))
      payer_note <- paste0("Payer = Optum line of business (member_enrollment.BUS) on the enrollment span ",
                           "covering the LOT1 start: MCR = Medicare, COM = Commercial; Medicare wins overlaps.")
    } else {
      payer_note <- "member_enrollment.BUS was not readable, so payer is unavailable this run."
      extra_gaps <- c(extra_gaps, "Q2d payer unavailable - member_enrollment.BUS not readable")
    }
    reg_src <- q2_find_region_source(con, describe_cols)
    if (!is.null(reg_src$tbl)) {
      have_region <- !is_status_table(best_effort(q2_build_region_view(con, reg_src), "region lookup"))
      region_note <- sprintf("Region = %s.%s (%s).", reg_src$tbl, reg_src$col,
                             if (reg_src$has_spans) "enrollment span covering the LOT1 start"
                             else "per-patient modal value - the table has no span dates")
    } else {
      region_note <- paste0("No region-like column was found on the enrollment/member tables probed (",
                            paste(reg_src$tried, collapse = ", "),
                            "), so region is unavailable this run. If the Optum member table in this ",
                            "workspace carries the Census region under another name, extend the probe list.")
      extra_gaps <- c(extra_gaps, "Q2d region unavailable - no region-like column found on the probed CDM tables")
    }

    if (have_agent) {
      q2_cycles <- best_effort(q2_cycles_summary(con, have_claims), "cycles per agent")
      roster <- best_effort(q2_roster(con, lot_long, coh_tbl, tok$dara, tok$bort,
                                      have_claims, have_payer, have_region),
                            "DARA+BORT patient roster")
      map_detail <- best_effort(q2_map_detail(con, map_tbl, tok$dara, tok$bort, VQS_W1),
                                "DARA+BORT MAP detail")
    } else {
      q2_cycles <- data.frame(status = paste0(map_tbl, " not readable - episodes/MAPs need MAP_STACKED."),
                              stringsAsFactors = FALSE)
      roster <- q2_cycles; map_detail <- q2_cycles
    }
    q2_l2 <- best_effort(q2_lot2_regimens(con, lot_long, n_dual), "2L regimens of the dual cohort")
    q2_dx <- if (have_coh) best_effort(q2_diagnosis_years(con, coh_tbl, n_dual), "diagnosis years")
             else data.frame(status = paste0(coh_tbl, " not readable - diagnosis dates unavailable."),
                             stringsAsFactors = FALSE)
    xt <- best_effort(q2_region_payer_crosstab(con, have_region, have_payer, n_dual),
                      "region x payer crosstab")
    if (enr_ok)
      plan_ctx <- best_effort(q2_plan_type_context(con, describe_cols, enr), "plan-type context")

    write_out(roster, "dara_bort_patients")
    write_out(map_detail, "dara_bort_map_detail")
    if (!is_status_table(xt) && is.data.frame(xt$long)) write_out(xt$long, "region_payer_counts")
  }

  # ---- Q3: rule-change impact -------------------------------------------
  cart <- if (have_sct)
    best_effort(q3_cart_impact(con, lot_long, sct_tbl, VQS_W1), "CAR-T rule impact")
  else data.frame(status = paste0(sct_tbl, " not readable - LOT1_SCT (FIRST_CART_DT) is required."),
                  stringsAsFactors = FALSE)
  melp <- if (have_map)
    best_effort(q3_melp_impact(con, lot_long, map_tbl, tok$melp), "MELP rule impact")
  else data.frame(status = paste0(map_tbl, " not readable - MAP_STACKED is required."),
                  stringsAsFactors = FALSE)

  if (!is_status_table(cart)) write_out(cart$roster, "cart_rule_affected_patients")
  if (!is_status_table(melp)) write_out(melp$roster, "melp_rule_boundaries")

  # ======================================================================
  # Workbook assembly
  # ======================================================================
  add_sheet(name = "Read Me",
    title = paste0("July-20 study-team questions - ", cohort_label),
    subtitle = paste0("Generated ", stamp, " by jul20_studyteam_qs.R against ", cfg$work_schema),
    narrative = c(
      sprintf("Cohort: %s. LOT1 = %s patients. Switch with LOT_COHORT=FULL / NDMM.",
              cohort_label, format(n_lot1, big.mark = ",")),
      tok$notes,
      "Q1 = the dashboard refresh. A new steroid-free dashboard HTML sits next to this workbook, with an all-regimens tab per LOT; every list is downloadable from the dashboard (CSV button) and is also written as a CSV file. The production dashboards are untouched. The steroid tab shows why no LOT re-run is needed: steroids never enter the LOT rules or regimen strings.",
      "Q2 = the 1L DARA+BORT dual-therapy deep dive (regimen exactly DARA + BORT, no other MM agent). Patient-level CSVs: jul20_qs_dara_bort_patients_* (one row per patient - diagnosis date, per-agent episodes and claim counts, 2L, region, payer) and jul20_qs_dara_bort_map_detail_* (one row per drug episode/MAP). The workbook tabs summarise cycles (a), 2L regimens (b), diagnosis years (c), and region x payer (d).",
      "Q3 = the two candidate LOT-rule changes, simulated read-only on the persisted tables (no engine re-run): Q3a the MELP 60-180-day rule, Q3b the CAR-T induction-window rule. Each tab quantifies the affected lines/patients and how the per-patient line counts would shift; affected patients are in the *_affected_* / *_boundaries_* CSVs.",
      "Regimen strings (LOT_BASE_MEDS) are space-separated, alphabetically-sorted MM-agent tokens; steroids are excluded by construction, so 'DARA+BORT dual therapy, no other agents' means no other MM agent (a backbone steroid does not change the pairing).",
      "The induction-window setting is shared with the pipeline (60 days for LOT1)."),
    tables = list())

  # Q1 regimen sheets: one per LOT so each long list stays a single table.
  if (!q1_failed) {
    denom_tbl <- q1$denom
    for (ln in names(q1$per_lot)) {
      df <- q1$per_lot[[ln]]
      add_sheet(name = paste0("Q1 LOT", ln, " regimens"),
        title = paste0("Q1 - all regimens in LOT", ln),
        subtitle = paste0("Every regimen string (no top-N cut). Cohort: ", cohort_label, "."),
        narrative = c(
          sprintf("%d distinct regimen strings. pct_of_line uses the LOT%s distinct-patient denominator.",
                  nrow(df), ln),
          "Transplant / CAR-T-only lines carry a labelled '(no drug regimen ...)' row so the counts reconcile with the per-line totals.",
          sprintf("Downloadable copy: %s (also a CSV button on the dashboard tab).",
                  paste0("jul20_qs_all_regimens_lot", ln, "_", tolower(cohort_mode), "_", stamp, ".csv"))),
        tables = setNames(list(df), paste0("All LOT", ln, " regimens")))
    }
    add_sheet(name = "Q1 line denominators",
      title = "Q1 - per-line patient denominators",
      subtitle = paste0("Cohort: ", cohort_label, "."),
      narrative = "Distinct patients reaching each line; the denominators behind pct_of_line.",
      tables = list("Patients per line" = denom_tbl))
  } else {
    add_sheet(name = "Q1 all regimens",
      title = "Q1 - all regimens per LOT",
      subtitle = paste0("Cohort: ", cohort_label, "."),
      narrative = "The regimen lists could not be built - see the status table.",
      tables = list("All regimens per LOT" = q1))
  }

  add_sheet(name = "Q1 Steroids",
    title = "Q1 - steroids are already excluded from the LOT",
    subtitle = paste0("Regimen audit + agent-token list. Cohort: ", cohort_label, "."),
    narrative = c(
      ster_line,
      "Steroids only ever surface in the display layer of the production dashboards (steroid_codes.csv adds DEXA/PRED tokens to the display strings). This refresh reads the raw LOT_BASE_MEDS instead, so nothing steroid-driven appears anywhere in it.",
      paste0("The audit checks the known steroid abbreviations (",
             paste(STEROID_TOKENS, collapse = ", "),
             "); the token table lists every agent that actually appears, so an unlisted abbreviation would still be visible.")),
    tables = list(
      "Steroid tokens in any LOT regimen (expected: 0)" = aud$audit,
      "Agent tokens appearing in LOT regimens"          = aud$vocab))

  # Q2 sheets ------------------------------------------------------------
  q2_overview_tables <- list()
  if (!is.na(n_dual)) {
    q2_overview_tables[["Cohort"]] <- data.frame(
      metric = c("1L DARA+BORT dual-therapy patients (denominator)",
                 "Share of the cohort's LOT1 patients"),
      value = c(as.integer(n_dual), pct1(n_dual, n_lot1)),
      stringsAsFactors = FALSE)
    if (!is.null(q2_cycles) && !is_status_table(q2_cycles)) {
      q2_overview_tables[["Episodes (MAPs) per agent inside LOT1"]] <- q2_cycles$summary
      q2_overview_tables[["Episode-count distribution"]] <- q2_cycles$distribution
      if (!is.null(q2_cycles$claims))
        q2_overview_tables[["Claim counts per agent inside LOT1 (medical claims ~ administrations; pharmacy fills)"]] <- q2_cycles$claims
    } else if (!is.null(q2_cycles)) {
      q2_overview_tables[["Episodes (MAPs) per agent"]] <- q2_cycles
    }
  } else {
    q2_overview_tables <- q2_tabs
  }
  add_sheet(name = "Q2 DARA+BORT cycles",
    title = "Q2(a) - 1L DARA+BORT: episodes, MAPs and claim counts per agent",
    subtitle = paste0("Among patients whose 1L regimen is exactly DARA + BORT. Cohort: ", cohort_label, "."),
    narrative = c(
      q2_notes,
      "Claims do not record protocol cycles. Per the ask, the per-agent numbers are the drug episodes (MAPs) inside LOT1 and the claim counts behind them: medical claims are the administration visits (DARA/BORT are given in-clinic), pharmacy rows are fills.",
      "The patient-level detail is in jul20_qs_dara_bort_patients_* (one row per patient) and jul20_qs_dara_bort_map_detail_* (one row per episode, flagged for the induction window and the LOT1 span)."),
    tables = q2_overview_tables)

  add_sheet(name = "Q2 2L and diagnosis",
    title = "Q2(b)+(c) - what the DARA+BORT patients get in 2L, and when they were diagnosed",
    subtitle = paste0("Cohort: ", cohort_label, "."),
    narrative = c(
      "The 2L list keeps a '(no 2L observed)' row so the denominator stays the full dual cohort.",
      "Diagnosis = INDEX_DATE, the qualifying MM diagnosis date behind the Part-1 cohort entry. A NA year row appears when a dual patient has no readable index date."),
    tables = list(
      "2L regimens of the 1L DARA+BORT patients" = q2_l2 %||% data.frame(status = "not built", stringsAsFactors = FALSE),
      "Diagnosis year of the 1L DARA+BORT patients" = q2_dx %||% data.frame(status = "not built", stringsAsFactors = FALSE)))

  xt_tables <- list()
  if (!is.null(xt) && !is_status_table(xt)) {
    if (!is.null(xt$wide)) xt_tables[["Region x payer (patients)"]] <- xt$wide
    xt_tables[["Region x payer (long form, with % of dual cohort)"]] <- xt$long
  } else if (!is.null(xt)) {
    xt_tables[["Region x payer"]] <- xt
  }
  if (!is.null(plan_ctx)) xt_tables[["Plan-type context (probed enrollment column)"]] <- plan_ctx
  add_sheet(name = "Q2 Region x payer",
    title = "Q2(d) - DARA+BORT patients by region, cross-tabulated with payer",
    subtitle = paste0("Cohort: ", cohort_label, "."),
    narrative = c(payer_note, region_note,
      "Counts are distinct patients; the long form repeats the grid with the share of the dual cohort."),
    tables = xt_tables)

  # Q3 sheets ------------------------------------------------------------
  melp_tables <- list()
  if (!is_status_table(melp)) {
    melp_tables[["Headline counts"]] <- melp$totals
    melp_tables[["MELP-attributable line boundaries by timing vs the line's first MELP MAP"]] <- melp$inventory
    melp_tables[["Boundaries by line pair"]] <- melp$by_line
    melp_tables[["Lines per patient - current, with removable lines under each reading"]] <-
      q3_melp_shift_table(melp$shift)
  } else {
    melp_tables[["MELP rule impact"]] <- melp
  }
  add_sheet(name = "Q3a MELP rule impact",
    title = "Q3(a) - impact of the MELP 60-180-day rule",
    subtitle = paste0("Simulated read-only on LOT_LONG + MAP_STACKED. Cohort: ", cohort_label, "."),
    narrative = c(
      "Today MELP advances lines like any agent: a MELP MAP starting after the induction window ends the line (MED_ADD) and/or starts the next one. A 'MELP boundary' below is such a transition.",
      "The proposed rule keys each advancing MELP to the first MELP MAP of the line it follows. As written, BOTH branches keep MELP in the line (a MELP in the 60-180-day window 'does not advance'; otherwise MELP is 'part of the LOT'), so read literally no MELP ever advances a line. The timing decomposition lets the team apply the narrow reading instead (suppress only the 60-180-day recurrences) - please confirm which is intended.",
      "The transplant-context column counts boundaries adjacent to an autologous transplant - the July-11 D1 deep dive showed MELP around 2L is usually transplant conditioning, which is likely what this rule is aiming at.",
      "Simulation note (first-order): each suppressed boundary merges its two lines, so a patient's line count drops by their number of suppressed boundaries with a next line. Later-line windows/regimens are kept as built; an exact re-derivation needs a spec change and an engine re-run.",
      "Affected boundaries, patient by patient: jul20_qs_melp_rule_boundaries_*."),
    tables = melp_tables)

  cart_tables <- list()
  if (!is_status_table(cart)) {
    cart_tables[["Inventory"]] <- cart$inventory
    cart_tables[["First CAR-T timing vs LOT1 start"]] <- cart$timing
    cart_tables[["Lines per patient - current vs simulated"]] <- q3_shift_table(cart$shift)
  } else {
    cart_tables[["CAR-T rule impact"]] <- cart
  }
  add_sheet(name = "Q3b CAR-T rule impact",
    title = "Q3(b) - impact of keeping an induction-window CAR-T inside LOT1",
    subtitle = paste0("Simulated read-only on LOT_LONG + LOT1_SCT. Cohort: ", cohort_label, "."),
    narrative = c(
      sprintf("Today a CAR-T on/after the LOT1 start - including inside the %d-day induction window - ends LOT1 the day before (SCT_CART, or CART_INIT when it lands within %d days of an added agent) and opens a CART-started LOT2.", VQS_W1, VQS_CART),
      "Under the proposed rule those induction-window CAR-Ts stay in LOT1: the CART LOT2 folds back into LOT1 (the simulated new LOT1 end is the old LOT2's end) and later lines renumber down one.",
      "The affected rows - with their current LOT1/LOT2 and the simulated merge - are in jul20_qs_cart_rule_affected_patients_*."),
    tables = cart_tables)

  # ======================================================================
  # Dashboard assembly (the Q1 deliverable; sections mirror the workbook)
  # ======================================================================
  dash_file <- paste0("jul20_refresh_dashboard_", tolower(cohort_mode), ".html")
  if (dash_ok) {
    dash_card(paste0(
      '<div style="font-family:system-ui;padding:12px;max-width:860px">',
      '<h3 style="margin:0 0 6px">Refreshed LOT dashboard - steroid-free</h3>',
      '<p style="color:#555;font-size:13px">Cohort: ', cohort_label,
      '. Generated ', stamp, ' by jul20_studyteam_qs.R. ',
      'Regimen strings come straight from <code>LOT_BASE_MEDS</code>, which the LOT engine builds ',
      'without steroids, and the display-layer steroid augmentation of the production dashboards is not applied here - ',
      'so no steroid token appears anywhere. Every table has a CSV download button; the long lists are also written as ',
      'CSV files next to this dashboard.</p></div>'),
      section = "OVERVIEW", title = "About this refresh")

    if (!q1_failed) {
      for (ln in names(q1$per_lot))
        dash_table(q1$per_lot[[ln]], "ALL REGIMENS BY LOT",
                   paste0("LOT", ln, " - all regimens (",
                          nrow(q1$per_lot[[ln]]), " distinct)"))
      dash_table(q1$denom, "ALL REGIMENS BY LOT", "Per-line patient denominators")
    }
    if (!is_status_table(aud$audit))
      dash_table(aud$audit, "STEROID AUDIT", "Steroid tokens in any LOT regimen (expected 0)")
    if (!is_status_table(aud$vocab))
      dash_table(aud$vocab, "STEROID AUDIT", "Agent tokens appearing in LOT regimens")
    dash_card(paste0(
      '<div style="font-family:system-ui;padding:12px;max-width:860px">',
      '<h3 style="margin:0 0 6px">Why no LOT re-run is needed</h3>',
      '<p style="color:#555;font-size:13px">', ster_line, '</p></div>'),
      section = "STEROID AUDIT", title = "Steroids and the LOT rules")

    if (!is.na(n_dual)) {
      if (!is.null(q2_cycles) && !is_status_table(q2_cycles)) {
        dash_table(q2_cycles$summary, "DARA+BORT 1L", "Episodes (MAPs) per agent inside LOT1")
        dash_table(q2_cycles$distribution, "DARA+BORT 1L", "Episode-count distribution")
        if (!is.null(q2_cycles$claims))
          dash_table(q2_cycles$claims, "DARA+BORT 1L", "Claim counts per agent inside LOT1")
      }
      if (!is.null(q2_l2) && !is_status_table(q2_l2))
        dash_table(q2_l2, "DARA+BORT 1L", "2L regimens of the dual cohort")
      if (!is.null(q2_dx) && !is_status_table(q2_dx))
        dash_table(q2_dx, "DARA+BORT 1L", "Diagnosis year distribution")
      if (!is.null(xt) && !is_status_table(xt) && !is.null(xt$wide))
        dash_table(xt$wide, "DARA+BORT 1L", "Region x payer (patients)")
      if (is.data.frame(roster) && !is_status_table(roster))
        dash_table(roster, "DARA+BORT 1L",
                   paste0("Patient roster (", nrow(roster), " patients - CSV button downloads all)"))
    }

    if (!is_status_table(melp)) {
      dash_table(melp$inventory, "LOT RULE IMPACT", "MELP boundaries by timing vs the line's first MELP MAP")
      dash_table(q3_melp_shift_table(melp$shift), "LOT RULE IMPACT", "MELP rule - lines per patient")
    }
    if (!is_status_table(cart)) {
      dash_table(cart$inventory, "LOT RULE IMPACT", "CAR-T rule - inventory")
      dash_table(cart$timing, "LOT RULE IMPACT", "First CAR-T timing vs LOT1 start")
      dash_table(q3_shift_table(cart$shift), "LOT RULE IMPACT", "CAR-T rule - lines per patient, current vs simulated")
    }

    build_dashboard(out_name = dash_file,
      header_title = "MM LOT &mdash; July-20 refresh (steroid-free)",
      header_sub   = paste0(cohort_label, " &bull; all regimens per LOT &bull; DARA+BORT 1L &bull; rule-change impact"))
    dash_path <- file.path(out_dir, dash_file)
    if (file.exists(dash_path)) {
      log_msg("wrote dashboard -> ", dash_path)
    } else {
      extra_gaps <- c(extra_gaps,
        "Q1 refreshed dashboard file was not written (build_dashboard skipped) - see the log")
    }
  }

  # ---- flag anything that makes the run incomplete ------------------------
  core_gaps <- extra_gaps
  for (s in sheets) for (nm in names(s$tables %||% list())) {
    entry <- s$tables[[nm]]; df <- entry
    if (is.list(entry) && !is.data.frame(entry)) df <- entry$df
    if (is_status_table(df))
      core_gaps <- c(core_gaps, sprintf("%s / %s", s$name, nm))
  }
  incomplete <- length(core_gaps) > 0
  if (incomplete) {
    log_msg("WARNING: answers are INCOMPLETE:")
    for (g in core_gaps) log_msg("  - ", g)
    sheets[[1]]$narrative <- c(
      paste0("INCOMPLETE run: ", length(core_gaps),
             " issue(s) - see the affected tabs and re-run once resolved. ",
             paste(core_gaps, collapse = "; "), "."),
      sheets[[1]]$narrative)
  }

  # ---- write --------------------------------------------------------------
  suffix <- if (incomplete) "_INCOMPLETE" else ""
  xlsx <- file.path(out_dir, paste0("jul20_studyteam_qs_", tolower(cohort_mode), "_",
                                    stamp, suffix, ".xlsx"))
  wbx_write_workbook(sheets, xlsx)
  log_msg(SEP)
  if (incomplete)
    log_msg("July-20 study-team questions COMPLETED WITH GAPS (", length(core_gaps),
            " issue(s)) - INCOMPLETE workbook -> ", xlsx)
  else
    log_msg("July-20 study-team questions complete. Workbook -> ", xlsx,
            if (dash_ok) paste0("; dashboard -> ", file.path(out_dir, dash_file)) else "")
  log_msg(SEP)
}

if (!interactive()) {
  main()
}
