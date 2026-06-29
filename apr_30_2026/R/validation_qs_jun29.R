# ---------------------------------------------------------------------------
# Shared analysis module: "MM LOT Validation next steps" study-team questions
# (Julia Moore, forwarded 24-Jun-2026 / "June 29 2026" question set).
#
# This module holds ONLY data logic (SQL -> data.frame). It is consumed by:
#   - validation_qs_jun29.R          (standalone CSV/log program)
#   - 07_combined_dashboard.R        (Exploratory objective tables)
# so the two deliverables can never drift apart.
#
# It builds nothing persistent and is safe to run any time. It reads the
# persisted work-schema tables (LOT_LONG, MAP_STACKED, LOT1_SCT) and, for the
# raw-claim patient examples (Q2, Q6), the raw CDM via cdm_src(). The
# raw-claim pulls are GUARDED: if the CDM / codelist CSVs are not reachable
# they degrade to NULL and the caller falls back to the MAP-derived view.
#
# ---- The six questions -----------------------------------------------------
#   Q1  Breakdown of LOT1 patients whose regimen includes pomalidomide,
#       elotuzumab and/or panobinostat (mono- vs combination-therapy).
#   Q2  Raw-claim patient examples (before MAPs were derived) for patients
#       with pomalidomide in their LOT1 regimen.
#   Q3  Among LOT1 patients with NO steroid at LOT1, how many received a
#       steroid within 7/14/30 days before LOT1 start, and within 7/14/30
#       days after the end of the 60-day induction window.
#   Q4  Same as Q3 for LOT2 (30-day induction window).
#   Q5  Patients with no steroid at LOT2 but a steroid in the 30 days before
#       LOT2 start: did they have a steroid at LOT1 (attribution check)?
#   Q6  Patients with CAR-T prior to or during LOT1 (the LOT rules do not
#       allow CAR-T during LOT1), with raw-claim journey examples.
#
# ---- Operational definitions (documented, single source of truth) ----------
#  * Steroid signal source: the codes in steroid_codes.csv (mapped to DEX/PRED
#    tokens) scanned against medical (PROC_CD/BILL_PROC_CD HCPCS/CPT, NDC) + rx
#    (NDC) - the SAME source 05_regimen_dashboard.R uses (load_steroid_codes +
#    augment_lot_long), built here by vqs_build_steroid_claims(). There is NO
#    STEROID class in cl_mma_codelist.csv, so a MAP_STACKED MAP_MED_CLASS=
#    'STEROID' scan returns zero rows and would silently empty Q3/Q4/Q5.
#  * "Steroid CLASSIFIED as part of LOTn" (the Q3/Q4/Q5 denominator) -> a steroid
#    claim within the CAPPED induction window
#    [LOT_START_DT, LOT_INDUCTION_END_DT], where LOT_INDUCTION_END_DT =
#    least(LOT_BASE_END_DT, LOT_START_DT + W - 1), W = 60 (LOT1) / 45 (CART-
#    started LOTn) / 30 (other LOTn); SCT_ALLO lines have no membership. This
#    matches the Steroids panel's augmentation (LOT_INDUCTION_END_DT) EXACTLY,
#    so the no-steroid denominators reconcile. (See vqs_induction_end_sql.)
#  * "Received a steroid within N days prior / after" -> a steroid claim in the
#    respective window, anchored to the FIXED induction end (LOT_START + W - 1)
#    that the ask names ("their 60/30 day induction window"). The 7/14/30
#    windows are cumulative (<= N days). These are NOT capped at LOT_BASE_END_DT.
#  * Steroid claims are scanned for all LOT_LONG patients (matching the panel's
#    augmentation); they are NOT bounded to [INDEX_DATE, OBS_END_DT], so a
#    pre-index steroid can legitimately fall in a LOT1 prior window.
# ---------------------------------------------------------------------------

# Default medication abbreviations (overridable via env). Panobinostat in
# particular may not appear in this cohort at all (a 0 count is a valid
# answer); the token is also best-effort refined from the codelist below.
VQS_POMA_TOKEN <- toupper(Sys.getenv("POMA_MED_ABBR", unset = "POMA"))
VQS_ELOT_TOKEN <- toupper(Sys.getenv("ELOT_MED_ABBR", unset = "ELOT"))
VQS_PANO_TOKEN <- toupper(Sys.getenv("PANO_MED_ABBR", unset = "PANO"))

# Induction windows (config-driven; fall back to study defaults).
VQS_W1 <- tryCatch(as.integer(cfg$induction_window_days),       error = function(e) 60L)
VQS_W2 <- tryCatch(as.integer(cfg$lot_n_induction_window_days), error = function(e) 30L)
VQS_CART <- tryCatch(as.integer(cfg$cart_consolidation_days),   error = function(e) 45L)
if (is.na(VQS_W1) || VQS_W1 < 1) VQS_W1 <- 60L
if (is.na(VQS_W2) || VQS_W2 < 1) VQS_W2 <- 30L
if (is.na(VQS_CART) || VQS_CART < 1) VQS_CART <- 45L

# SQL for the induction-window END used to decide "steroid CLASSIFIED as part of
# LOTn" (the denominator). Mirrors 05_regimen_dashboard.R augment_lot_long
# (LOT_INDUCTION_END_DT) EXACTLY so Q3/Q4/Q5 reconcile with the Steroids panel:
#   - SCT_ALLO-started line -> NULL (no steroid membership; parent suppresses it)
#   - else cap at LOT_BASE_END_DT, window = 60d (LOT1) / 45d (CART-started LOTn)
#     / 30d (other LOTn); when LOT_BASE_END_DT is NULL use the full window.
# The 7/14/30d before/after windows are NOT capped - they are anchored to the
# fixed induction end (LOT_START + W - 1) that Julia named ("their 60/30 day
# induction window").
vqs_induction_end_sql <- function(lot_num, w, start_expr = "cast(LOT_START_DT as date)") {
  bw <- if (lot_num == 1L) as.character(as.integer(w))
        else glue("CASE WHEN LOT_START_TYPE = 'CART' THEN {VQS_CART} ELSE {as.integer(w)} END")
  glue("CASE WHEN LOT_START_TYPE = 'SCT_ALLO' THEN cast(NULL as date)
             WHEN LOT_BASE_END_DT IS NULL THEN date_add({start_expr}, ({bw}) - 1)
             ELSE least(cast(LOT_BASE_END_DT as date),
                        date_add({start_expr}, ({bw}) - 1)) END")
}

# Quote a vector of ids for an IN (...) list; '' when empty so SQL stays valid.
vqs_in_list <- function(ids) {
  ids <- unique(as.character(ids))
  ids <- ids[!is.na(ids) & nzchar(ids)]
  if (length(ids) == 0) return("''")
  paste(sprintf("'%s'", gsub("'", "''", ids)), collapse = ", ")
}

vqs_readable <- function(con, tbl) isTRUE(tryCatch(
  nrow(db_q(con, glue("SELECT 1 FROM {tbl} LIMIT 1"))) >= 0,
  error = function(e) FALSE))

# Steroid-claim relation (sub-select string) over a built steroid-claims view.
vqs_steroid_src <- function(ster_view) glue(
  "(SELECT cast(PATID as string) AS PATID, STER_DT FROM {ster_view})")

# Build the steroid-claim signal the way the rest of this project does it:
# scan medical (PROC_CD/BILL_PROC_CD as HCPCS/CPT, NDC) + rx (NDC) for the
# codes in steroid_codes.csv (mapped to DEX/PRED tokens). This is the same
# source 05_regimen_dashboard.R uses (load_steroid_codes + augment_lot_long).
#
# IMPORTANT: do NOT use a MAP_STACKED MAP_MED_CLASS='STEROID' scan - steroids
# are NOT a class in cl_mma_codelist.csv, so that scan returns zero rows and
# silently empties Q3/Q4/Q5 (every patient reads as "no steroid"). steroid_
# codes.csv is the project's only steroid source.
#
# Returns list(view=<temp view name or NULL>, n_codes, n_hcpcs, n_ndc, note).
vqs_build_steroid_claims <- function(con, lot_long, ster_csv) {
  out <- list(view = NULL, n_codes = 0L, n_hcpcs = 0L, n_ndc = 0L, note = NULL)
  if (is.null(ster_csv) || !file.exists(ster_csv)) {
    out$note <- paste0("steroid_codes.csv not found (", ster_csv,
                       "); steroid analyses (Q3/Q4/Q5) skipped.")
    return(out)
  }
  df <- tryCatch(read.csv(ster_csv, stringsAsFactors = FALSE,
                          check.names = FALSE, comment.char = "#"),
                 error = function(e) NULL)
  if (is.null(df) || nrow(df) == 0 ||
      !all(c("code", "code_type", "mapped_to") %in% names(df))) {
    out$note <- "steroid_codes.csv empty/unreadable or missing columns; Q3/Q4/Q5 skipped."
    return(out)
  }
  sq <- function(x) gsub("'", "''", x, fixed = TRUE)
  rows <- character(0); types <- character(0)
  for (i in seq_len(nrow(df))) {
    cd <- toupper(gsub("[^A-Za-z0-9]", "", trimws(as.character(df$code[i]))))
    ty <- toupper(trimws(as.character(df$code_type[i])))
    mt <- toupper(trimws(as.character(df$mapped_to[i])))
    if (!nzchar(cd) || !nzchar(mt)) next
    rows  <- c(rows,  sprintf("('%s','%s','%s')", sq(cd), sq(ty), sq(mt)))
    types <- c(types, ty)
  }
  if (length(rows) == 0) {
    out$note <- "steroid_codes.csv parsed to 0 valid rows; Q3/Q4/Q5 skipped."
    return(out)
  }
  out$n_codes <- length(rows)
  out$n_hcpcs <- sum(types == "HCPCS")
  out$n_ndc   <- sum(types == "NDC")
  med <- cdm_src(cfg$tbl_medical); rxt <- cdm_src(cfg$tbl_rx)
  ok <- tryCatch({
    db_exec(con, glue("
      CREATE OR REPLACE TEMPORARY VIEW vqs_steroid_claims AS
      WITH sc AS (SELECT * FROM VALUES {paste(rows, collapse = ',')} AS t(code, code_type, mapped_to)),
      lp AS (SELECT DISTINCT cast(PATID as string) AS PATID FROM {lot_long}),
      s1 AS (
        SELECT cast(m.PATID as string) AS PATID, cast(m.FST_DT as date) AS STER_DT
        FROM {med} m JOIN sc ON sc.code_type IN ('HCPCS','CPT')
          AND sc.code = upper(regexp_replace(coalesce(cast(m.PROC_CD as string),''), '[^A-Za-z0-9]', ''))
        WHERE m.FST_DT IS NOT NULL AND EXISTS (SELECT 1 FROM lp WHERE lp.PATID = cast(m.PATID as string))
      ),
      s2 AS (
        SELECT cast(m.PATID as string) AS PATID, cast(m.FST_DT as date) AS STER_DT
        FROM {med} m JOIN sc ON sc.code_type = 'HCPCS'
          AND sc.code = upper(regexp_replace(coalesce(cast(m.BILL_PROC_CD as string),''), '[^A-Za-z0-9]', ''))
        WHERE m.FST_DT IS NOT NULL AND EXISTS (SELECT 1 FROM lp WHERE lp.PATID = cast(m.PATID as string))
      ),
      s3 AS (
        SELECT cast(m.PATID as string) AS PATID, cast(m.FST_DT as date) AS STER_DT
        FROM {med} m JOIN sc ON sc.code_type = 'NDC'
          AND lpad(regexp_replace(coalesce(cast(m.NDC as string),''), '[^0-9]', ''), 11, '0')
            = lpad(regexp_replace(sc.code, '[^0-9]', ''), 11, '0')
        WHERE m.FST_DT IS NOT NULL AND EXISTS (SELECT 1 FROM lp WHERE lp.PATID = cast(m.PATID as string))
      ),
      s4 AS (
        SELECT cast(r.PATID as string) AS PATID, cast(r.FILL_DT as date) AS STER_DT
        FROM {rxt} r JOIN sc ON sc.code_type = 'NDC'
          AND lpad(regexp_replace(coalesce(cast(r.NDC as string),''), '[^0-9]', ''), 11, '0')
            = lpad(regexp_replace(sc.code, '[^0-9]', ''), 11, '0')
        WHERE r.FILL_DT IS NOT NULL AND EXISTS (SELECT 1 FROM lp WHERE lp.PATID = cast(r.PATID as string))
      )
      SELECT DISTINCT PATID, STER_DT FROM (
        SELECT * FROM s1 UNION ALL SELECT * FROM s2
        UNION ALL SELECT * FROM s3 UNION ALL SELECT * FROM s4
      ) WHERE STER_DT IS NOT NULL"))
    TRUE
  }, error = function(e) {
    out$note <<- paste("steroid-claim scan failed:", conditionMessage(e)); FALSE
  })
  if (isTRUE(ok)) {
    out$view <- "vqs_steroid_claims"
    out$note <- sprintf(
      "steroid signal = steroid_codes.csv (%d codes: %d HCPCS, %d NDC) scanned on medical+rx.%s",
      out$n_codes, out$n_hcpcs, out$n_ndc,
      if (out$n_ndc == 0L) " NOTE: 0 NDC codes - oral-RX steroids undercounted." else "")
  }
  out
}

# Observation-window bounds, reconstructed from the persisted Part-1 cohort
# (ELIG_COH_FINAL) exactly as 02_lot1.R S03 builds lot_patient_input:
# OBS_END_DT = cast(ENDDATE as date) (primary) or coalesce(ENDDATE_CE, ENDDATE)
# under the disenrollment-censoring sensitivity flag. Used to scope the raw
# claim pulls to [INDEX_DATE, OBS_END_DT], so the "raw claims before MAPs"
# examples match the pipeline's analytic window rather than a patient's whole
# claim history. Returns list(sql = <subquery or NULL>, available = <bool>).
vqs_obs_bounds_src <- function(con) {
  tbl <- wrk(cfg$input_cohort_table)
  obs_end <- if (isTRUE(cfg$censor_at_disenrollment))
    "coalesce(cast(ENDDATE_CE AS date), cast(ENDDATE AS date))"
  else "cast(ENDDATE AS date)"
  ok <- vqs_readable(con, tbl) && isTRUE(tryCatch({
    db_q(con, glue("SELECT INDEX_DATE, ENDDATE FROM {tbl} LIMIT 1")); TRUE
  }, error = function(e) FALSE))
  if (!ok) return(list(sql = NULL, available = FALSE))
  list(available = TRUE, sql = glue(
    "(SELECT cast(PATID as string) AS PATID,
             cast(INDEX_DATE AS date) AS INDEX_DATE,
             {obs_end}               AS OBS_END_DT
        FROM {tbl})"))
}

# ---- Token resolution ------------------------------------------------------
# Best-effort: build the (tiny, CSV-backed) mma_codelist view and resolve the
# three agents by medication-full-name LIKE, so a codelist abbreviation change
# does not silently zero out the answer. Falls back to the env/default tokens.
# Returns a named list(poma=, elot=, pano=, resolved=<character notes>).
vqs_resolve_agent_tokens <- function(con) {
  out <- list(poma = VQS_POMA_TOKEN, elot = VQS_ELOT_TOKEN,
              pano = VQS_PANO_TOKEN, notes = character(0))
  ok <- tryCatch({ vqs_build_mma_codelist(con); TRUE }, error = function(e) FALSE)
  if (!ok) {
    out$notes <- "mma_codelist unavailable; using default/env tokens."
    return(out)
  }
  pick <- function(like, dflt) {
    df <- tryCatch(db_q(con, glue("
      SELECT CL_MED_ABBR, count(*) AS n
      FROM mma_codelist
      WHERE lower(CL_MEDICATION_FULL) LIKE '%{like}%'
      GROUP BY CL_MED_ABBR ORDER BY n DESC")), error = function(e) NULL)
    if (is.null(df) || nrow(df) == 0) return(dflt)
    toupper(trimws(df$CL_MED_ABBR[1]))
  }
  out$poma <- pick("pomalidomide", VQS_POMA_TOKEN)
  out$elot <- pick("elotuzumab",   VQS_ELOT_TOKEN)
  out$pano <- pick("panobinostat", VQS_PANO_TOKEN)
  out$notes <- sprintf("Resolved tokens from cl_mma_codelist.csv: POMA=%s, ELOT=%s, PANO=%s.",
                       out$poma, out$elot, out$pano)
  out
}

# ===========================================================================
# Q1 - LOT1 regimens including pomalidomide / elotuzumab / panobinostat
# ===========================================================================
vqs_q1_exclusion_agents <- function(con, lot_long, tokens) {
  p <- tokens$poma; e <- tokens$elot; a <- tokens$pano
  has <- function(tok) glue("array_contains(meds, '{tok}')")
  any3 <- glue("({has(p)} OR {has(e)} OR {has(a)})")
  r <- db_q(con, glue("
    WITH l1 AS (
      SELECT split(LOT_BASE_MEDS, ' ') AS meds,
             size(filter(split(LOT_BASE_MEDS, ' '), x -> length(x) > 0)) AS n_agents
      FROM {lot_long}
      WHERE LOT_NUM = 1 AND LOT_BASE_MEDS IS NOT NULL AND trim(LOT_BASE_MEDS) <> ''
    )
    SELECT
      count(*)                                                         AS lot1_patients,
      sum(CASE WHEN {has(p)} THEN 1 ELSE 0 END)                        AS poma_any,
      sum(CASE WHEN {has(p)} AND n_agents = 1 THEN 1 ELSE 0 END)       AS poma_mono,
      sum(CASE WHEN {has(p)} AND n_agents > 1 THEN 1 ELSE 0 END)       AS poma_combo,
      sum(CASE WHEN {has(e)} THEN 1 ELSE 0 END)                        AS elot_any,
      sum(CASE WHEN {has(e)} AND n_agents = 1 THEN 1 ELSE 0 END)       AS elot_mono,
      sum(CASE WHEN {has(e)} AND n_agents > 1 THEN 1 ELSE 0 END)       AS elot_combo,
      sum(CASE WHEN {has(a)} THEN 1 ELSE 0 END)                        AS pano_any,
      sum(CASE WHEN {has(a)} AND n_agents = 1 THEN 1 ELSE 0 END)       AS pano_mono,
      sum(CASE WHEN {has(a)} AND n_agents > 1 THEN 1 ELSE 0 END)       AS pano_combo,
      sum(CASE WHEN {any3} THEN 1 ELSE 0 END)                          AS any_any,
      sum(CASE WHEN {any3} AND n_agents = 1 THEN 1 ELSE 0 END)         AS any_mono,
      sum(CASE WHEN {any3} AND n_agents > 1 THEN 1 ELSE 0 END)         AS any_combo
    FROM l1
  "))
  n_lot1 <- as.numeric(r$lot1_patients[1])
  mk <- function(label, tok, any, mono, combo) data.frame(
    agent             = label,
    token             = tok,
    n_lot1_with_agent = as.integer(any),
    n_as_monotherapy  = as.integer(mono),
    n_in_combination  = as.integer(combo),
    pct_of_lot1       = if (isTRUE(n_lot1 > 0)) round(100 * as.numeric(any) / n_lot1, 2) else NA_real_,
    stringsAsFactors  = FALSE)
  df <- rbind(
    mk("Pomalidomide",     p, r$poma_any, r$poma_mono, r$poma_combo),
    mk("Elotuzumab",       e, r$elot_any, r$elot_mono, r$elot_combo),
    mk("Panobinostat",     a, r$pano_any, r$pano_mono, r$pano_combo),
    mk("Any of the three", paste(p, e, a), r$any_any, r$any_mono, r$any_combo))
  attr(df, "lot1_patients") <- n_lot1
  df
}

# ===========================================================================
# Q3 / Q4 - steroid timing for patients with NO steroid at the line
# Returns a tidy table: one row per (window). Reused for LOT1 (W=60) and
# LOT2 (W=30).
# ===========================================================================
vqs_steroid_windows <- function(con, lot_long, ster_src, lot_num, w) {
  ind_end <- vqs_induction_end_sql(lot_num, w)
  r <- db_q(con, glue("
    WITH lot AS (
      SELECT cast(PATID as string) AS PATID, cast(LOT_START_DT as date) AS LS,
             {ind_end} AS IND_END
      FROM {lot_long}
      WHERE LOT_NUM = {lot_num} AND LOT_START_DT IS NOT NULL
    ),
    ster AS {ster_src},
    at_line AS (   -- steroid CLASSIFIED as part of the line (capped induction end)
      SELECT DISTINCT l.PATID
      FROM lot l JOIN ster s ON s.PATID = l.PATID
       AND l.IND_END IS NOT NULL AND s.STER_DT BETWEEN l.LS AND l.IND_END
    ),
    no_ster AS (
      SELECT l.* FROM lot l
      LEFT JOIN at_line a ON a.PATID = l.PATID
      WHERE a.PATID IS NULL
    ),
    flags AS (
      SELECT n.PATID,
        max(CASE WHEN s.STER_DT BETWEEN date_sub(n.LS, 7)  AND date_sub(n.LS, 1) THEN 1 ELSE 0 END) AS p7,
        max(CASE WHEN s.STER_DT BETWEEN date_sub(n.LS, 14) AND date_sub(n.LS, 1) THEN 1 ELSE 0 END) AS p14,
        max(CASE WHEN s.STER_DT BETWEEN date_sub(n.LS, 30) AND date_sub(n.LS, 1) THEN 1 ELSE 0 END) AS p30,
        max(CASE WHEN s.STER_DT BETWEEN date_add(n.LS, {w}) AND date_add(n.LS, {w} - 1 + 7)  THEN 1 ELSE 0 END) AS a7,
        max(CASE WHEN s.STER_DT BETWEEN date_add(n.LS, {w}) AND date_add(n.LS, {w} - 1 + 14) THEN 1 ELSE 0 END) AS a14,
        max(CASE WHEN s.STER_DT BETWEEN date_add(n.LS, {w}) AND date_add(n.LS, {w} - 1 + 30) THEN 1 ELSE 0 END) AS a30
      FROM no_ster n LEFT JOIN ster s ON s.PATID = n.PATID
      GROUP BY n.PATID
    )
    SELECT lp.n_lp AS line_patients,
           ls.n_ls AS line_with_steroid,
           f.n_no  AS line_without_steroid,
           f.prior_7d, f.prior_14d, f.prior_30d,
           f.after_7d, f.after_14d, f.after_30d
    FROM      (SELECT count(*) AS n_lp FROM lot)     lp
    CROSS JOIN (SELECT count(*) AS n_ls FROM at_line) ls
    CROSS JOIN (
      SELECT count(*) AS n_no,
             coalesce(sum(p7),  0) AS prior_7d, coalesce(sum(p14), 0) AS prior_14d,
             coalesce(sum(p30), 0) AS prior_30d,
             coalesce(sum(a7),  0) AS after_7d, coalesce(sum(a14), 0) AS after_14d,
             coalesce(sum(a30), 0) AS after_30d
      FROM flags
    ) f
  "))
  denom <- as.numeric(r$line_without_steroid[1])
  pct <- function(x) if (isTRUE(denom > 0)) round(100 * as.numeric(x) / denom, 2) else NA_real_
  nums <- as.numeric(c(r$prior_7d[1], r$prior_14d[1], r$prior_30d[1],
                       r$after_7d[1], r$after_14d[1], r$after_30d[1]))
  df <- data.frame(
    window = c(sprintf("Within %dd BEFORE LOT%d start", c(7, 14, 30), lot_num),
               sprintf("Within %dd AFTER end of %dd induction window", c(7, 14, 30), w)),
    n_patients = as.integer(nums),
    stringsAsFactors = FALSE)
  df$pct_of_no_steroid <- vapply(df$n_patients, pct, numeric(1))
  attr(df, "line_patients")        <- as.numeric(r$line_patients[1])
  attr(df, "line_with_steroid")    <- as.numeric(r$line_with_steroid[1])
  attr(df, "line_without_steroid") <- denom
  df
}

# Patient-level companion to vqs_steroid_windows() - answers Julia's "can we
# see WHO of these patients received a steroid within ..." (Q3/Q4). One row per
# no-steroid-at-line patient who received a steroid in at least one prior/after
# window, with per-window flags and the nearest steroid dates. `limit` caps the
# rows for the dashboard (NULL = all, for the standalone CSV).
vqs_steroid_windows_patients <- function(con, lot_long, ster_src, lot_num, w, limit = NULL) {
  lim  <- if (!is.null(limit)) glue("LIMIT {as.integer(limit)}") else ""
  ind_end <- vqs_induction_end_sql(lot_num, w)
  db_q(con, glue("
    WITH lot AS (
      SELECT cast(PATID as string) AS PATID, cast(LOT_START_DT as date) AS LS,
             {ind_end} AS IND_END
      FROM {lot_long}
      WHERE LOT_NUM = {lot_num} AND LOT_START_DT IS NOT NULL
    ),
    ster AS {ster_src},
    at_line AS (
      SELECT DISTINCT l.PATID FROM lot l JOIN ster s ON s.PATID = l.PATID
       AND l.IND_END IS NOT NULL AND s.STER_DT BETWEEN l.LS AND l.IND_END
    ),
    no_ster AS (
      SELECT l.* FROM lot l LEFT JOIN at_line a ON a.PATID = l.PATID
      WHERE a.PATID IS NULL
    ),
    flags AS (
      SELECT n.PATID, n.LS,
        max(CASE WHEN s.STER_DT BETWEEN date_sub(n.LS, 7)  AND date_sub(n.LS, 1) THEN 1 ELSE 0 END) AS prior_7d,
        max(CASE WHEN s.STER_DT BETWEEN date_sub(n.LS, 14) AND date_sub(n.LS, 1) THEN 1 ELSE 0 END) AS prior_14d,
        max(CASE WHEN s.STER_DT BETWEEN date_sub(n.LS, 30) AND date_sub(n.LS, 1) THEN 1 ELSE 0 END) AS prior_30d,
        max(CASE WHEN s.STER_DT BETWEEN date_add(n.LS, {w}) AND date_add(n.LS, {w} - 1 + 7)  THEN 1 ELSE 0 END) AS after_7d,
        max(CASE WHEN s.STER_DT BETWEEN date_add(n.LS, {w}) AND date_add(n.LS, {w} - 1 + 14) THEN 1 ELSE 0 END) AS after_14d,
        max(CASE WHEN s.STER_DT BETWEEN date_add(n.LS, {w}) AND date_add(n.LS, {w} - 1 + 30) THEN 1 ELSE 0 END) AS after_30d,
        max(CASE WHEN s.STER_DT BETWEEN date_sub(n.LS, 30) AND date_sub(n.LS, 1) THEN s.STER_DT END) AS nearest_prior_ster_dt,
        min(CASE WHEN s.STER_DT BETWEEN date_add(n.LS, {w}) AND date_add(n.LS, {w} - 1 + 30) THEN s.STER_DT END) AS first_after_ster_dt
      FROM no_ster n LEFT JOIN ster s ON s.PATID = n.PATID
      GROUP BY n.PATID, n.LS
    )
    SELECT PATID, cast(LS as string) AS lot_start,
           prior_7d, prior_14d, prior_30d, after_7d, after_14d, after_30d,
           cast(nearest_prior_ster_dt as string) AS nearest_prior_ster_dt,
           cast(first_after_ster_dt   as string) AS first_after_ster_dt
    FROM flags
    WHERE prior_30d = 1 OR after_30d = 1
    ORDER BY PATID
    {lim}
  "))
}

# ===========================================================================
# Q5 - attribution check. Julia: for patients with NO steroid classified at
# LOT2 but a steroid in the month before LOT2, is that pre-LOT2 steroid
# actually attributable to the LOT1 regimen?
#
# The DIRECT test (headline) preserves the actual pre-LOT2 steroid date(s) and
# asks whether one of them falls INSIDE LOT1's active span [L1_START,
# L1_BASE_END_DT] - that is the steroid being "the LOT1 regimen's". Two
# weaker "had ANY steroid during LOT1" rows are kept as supporting context;
# they can be 1 for a patient whose pre-LOT2 steroid is actually AFTER LOT1
# ended (a different, earlier steroid was in LOT1), which is exactly why they
# are not the headline.
# ===========================================================================
vqs_q5_lot2_attribution <- function(con, lot_long, ster_src, w1, w2) {
  r <- db_q(con, glue("
    WITH lot2 AS (
      SELECT cast(PATID as string) AS PATID, cast(LOT_START_DT as date) AS L2,
             {vqs_induction_end_sql(2L, w2)} AS L2_IND_END
      FROM {lot_long} WHERE LOT_NUM = 2 AND LOT_START_DT IS NOT NULL
    ),
    lot1 AS (
      SELECT cast(PATID as string) AS PATID,
             cast(LOT_START_DT as date)    AS L1,
             cast(LOT_BASE_END_DT as date) AS L1_END
      FROM {lot_long} WHERE LOT_NUM = 1
    ),
    ster AS {ster_src},
    at_lot2 AS (   -- steroid CLASSIFIED as part of LOT2 (capped induction end)
      SELECT DISTINCT l.PATID FROM lot2 l JOIN ster s ON s.PATID = l.PATID
       AND l.L2_IND_END IS NOT NULL AND s.STER_DT BETWEEN l.L2 AND l.L2_IND_END
    ),
    no_l2 AS (   -- LOT2 patients with NO steroid at LOT2 induction
      SELECT l.PATID, l.L2
      FROM lot2 l LEFT JOIN at_lot2 a ON a.PATID = l.PATID
      WHERE a.PATID IS NULL
    ),
    -- The actual pre-LOT2 steroid claim dates (one row per such claim),
    -- carried alongside the patient's LOT1 span so we can test the SAME
    -- steroid against LOT1.
    prior_ster AS (
      SELECT n.PATID, n.L2, l1.L1, l1.L1_END, s.STER_DT
      FROM no_l2 n
      JOIN ster s ON s.PATID = n.PATID
        AND s.STER_DT BETWEEN date_sub(n.L2, 30) AND date_sub(n.L2, 1)
      LEFT JOIN lot1 l1 ON l1.PATID = n.PATID
    ),
    denom AS (SELECT DISTINCT PATID FROM prior_ster),
    -- DIRECT attribution: the pre-LOT2 steroid itself lands inside LOT1 span.
    attrib AS (
      SELECT DISTINCT PATID FROM prior_ster
      WHERE L1_END IS NOT NULL AND STER_DT BETWEEN L1 AND L1_END
    ),
    -- Supporting context (any steroid, not necessarily the pre-LOT2 one).
    at_lot1_ind AS (
      SELECT DISTINCT d.PATID FROM denom d
      JOIN lot1 l ON l.PATID = d.PATID
      JOIN ster s ON s.PATID = d.PATID
        AND s.STER_DT BETWEEN l.L1 AND date_add(l.L1, {w1} - 1)
    ),
    during_lot1 AS (
      SELECT DISTINCT d.PATID FROM denom d
      JOIN lot1 l ON l.PATID = d.PATID
      JOIN ster s ON s.PATID = d.PATID
        AND l.L1_END IS NOT NULL AND s.STER_DT BETWEEN l.L1 AND l.L1_END
    )
    SELECT a.n_denom, b.n_attrib, c.n_ind, e.n_dur
    FROM      (SELECT count(*) AS n_denom  FROM denom)       a
    CROSS JOIN (SELECT count(*) AS n_attrib FROM attrib)      b
    CROSS JOIN (SELECT count(*) AS n_ind    FROM at_lot1_ind) c
    CROSS JOIN (SELECT count(*) AS n_dur    FROM during_lot1) e
  "))
  denom    <- as.numeric(r$n_denom[1])
  n_attrib <- as.numeric(r$n_attrib[1])
  n_ind    <- as.numeric(r$n_ind[1])
  n_dur    <- as.numeric(r$n_dur[1])
  n_notattr <- denom - n_attrib
  pct <- function(x) if (isTRUE(denom > 0)) round(100 * x / denom, 2) else NA_real_
  data.frame(
    metric = c(
      "No-steroid-at-LOT2 patients with a steroid in the 30d before LOT2 (denominator)",
      "  HEADLINE: the pre-LOT2 steroid ITSELF falls within LOT1 span [start, base end] (attributable to LOT1)",
      "  ... pre-LOT2 steroid NOT within LOT1 span (not attributable to LOT1 by the direct test)",
      "  context: had ANY steroid at LOT1 induction (within 60d window)",
      "  context: had ANY steroid any time during LOT1 [start, base end]"),
    n_patients = as.integer(c(denom, n_attrib, n_notattr, n_ind, n_dur)),
    pct_of_denominator = c(NA_real_, pct(n_attrib), pct(n_notattr), pct(n_ind), pct(n_dur)),
    stringsAsFactors = FALSE)
}

# ===========================================================================
# Q6 - CAR-T prior to or during LOT1
#
# Two date sources, by necessity:
#   * "DURING / closing LOT1" uses LOT1_SCT.FIRST_CART_DT (the engine's own
#     derived value). The window is [L1_START, L1_END], extended to L1_END + 1
#     ONLY when END_REASON in (SCT_CART, CART_INIT): a CAR-T-ending LOT1 sets
#     LOT1_BASE_END_DT = FIRST_CART_DT - 1 (02_lot1.R LOT1_TX_ENDDATE), so the
#     closing CAR-T lands one day past L1_END. For any other end reason a CAR-T
#     at L1_END + 1 is post-LOT1 and is NOT counted. (FIRST_CART_DT is itself
#     >= LOT1_START_DT by construction.)
#   * "BEFORE LOT1" cannot come from LOT1_SCT at all (first_cart filters
#     TX_DT >= LOT1_START_DT). It is taken from the raw CAR-T claim dates
#     (cart_raw_tbl, observation-window-bounded). When that scan is
#     unavailable the before-LOT1 rows are reported as NA with a note.
# ===========================================================================
vqs_q6_cart <- function(con, lot_long, sct_tbl, w1, cart_raw_tbl = NULL) {
  have_raw <- !is.null(cart_raw_tbl)
  # "During or closing LOT1" upper bound: the engine sets the LOT end to the
  # CAR-T date - 1 ONLY when CAR-T closes LOT1 (END_REASON SCT_CART/CART_INIT),
  # so the +1 (to recover the closing CAR-T) applies in that case only. For any
  # other end reason a CAR-T at L1_END + 1 is genuinely post-LOT1, so the upper
  # bound stays at L1_END.
  during_ub <- "CASE WHEN END_REASON IN ('SCT_CART','CART_INIT') THEN date_add(L1_END, 1) ELSE L1_END END"
  during_expr <- glue("sum(CASE WHEN CART_DT IS NOT NULL
              AND CART_DT BETWEEN L1 AND ({during_ub}) THEN 1 ELSE 0 END)")
  # before-LOT1 raw flag (only meaningful when have_raw). Expressions below
  # read from the outer query's FROM j, where the raw flag is column has_before.
  before_expr <- if (have_raw)
    "sum(CASE WHEN has_before = 1 THEN 1 ELSE 0 END)" else "cast(NULL as bigint)"
  prior_or_during_expr <- if (have_raw)
    glue("sum(CASE WHEN has_before = 1 OR (CART_DT IS NOT NULL
              AND CART_DT BETWEEN L1 AND ({during_ub})) THEN 1 ELSE 0 END)")
  else "cast(NULL as bigint)"
  raw_cte <- if (have_raw) glue("
    rb AS (
      SELECT l.PATID,
             max(CASE WHEN c.CART_DT < l.L1 THEN 1 ELSE 0 END) AS has_before
      FROM l1 l JOIN {cart_raw_tbl} c ON c.PATID = l.PATID
      GROUP BY l.PATID
    ),") else ""
  rb_join <- if (have_raw) "LEFT JOIN rb ON rb.PATID = l.PATID" else ""

  r <- db_q(con, glue("
    WITH l1 AS (
      SELECT cast(PATID as string) AS PATID,
             cast(LOT_START_DT as date)    AS L1,
             cast(LOT_BASE_END_DT as date) AS L1_END,
             LOT_BASE_END_REASON           AS END_REASON,
             coalesce(LOT_CART_LOT_FLG, 0) AS CART_FLG
      FROM {lot_long} WHERE LOT_NUM = 1
    ),
    sct AS (
      SELECT cast(PATID as string) AS PATID, min(cast(FIRST_CART_DT as date)) AS CART_DT
      FROM {sct_tbl} WHERE FIRST_CART_DT IS NOT NULL
      GROUP BY cast(PATID as string)
    ),
    {raw_cte}
    j AS (
      SELECT l.PATID, l.L1, l.L1_END, l.END_REASON, l.CART_FLG, s.CART_DT
             {if (have_raw) ', coalesce(rb.has_before, 0) AS has_before' else ''}
      FROM l1 l
      LEFT JOIN sct s ON s.PATID = l.PATID
      {rb_join}
    )
    SELECT
      count(*) AS lot1_patients,
      {before_expr}                                                                          AS n_cart_before_lot1_start,
      sum(CASE WHEN CART_DT BETWEEN L1 AND date_add(L1, {w1} - 1) THEN 1 ELSE 0 END)         AS n_cart_in_lot1_induction,
      {during_expr}                                                                          AS n_cart_during_or_closing_lot1,
      {prior_or_during_expr}                                                                 AS n_cart_prior_or_during_lot1,
      sum(CASE WHEN END_REASON IN ('SCT_CART','CART_INIT') THEN 1 ELSE 0 END)                AS n_lot1_ended_by_cart,
      sum(CASE WHEN CART_DT IS NOT NULL THEN 1 ELSE 0 END)                                   AS n_with_cart_on_after_lot1_start,
      sum(CASE WHEN CART_FLG = 1 THEN 1 ELSE 0 END)                                          AS n_lot1_flagged_cart_line
    FROM j
  "))
  n <- as.numeric(r$lot1_patients[1])
  pct <- function(x) if (isTRUE(n > 0) && !is.na(x)) round(100 * x / n, 2) else NA_real_
  na_or <- function(x) { v <- suppressWarnings(as.numeric(x)); if (length(v) == 0) NA_real_ else v }
  labels <- c(
    "LOT1 patients (denominator)",
    "CAR-T BEFORE LOT1 start (raw SCT claims)",
    "CAR-T within 60d after LOT1 start (start-relative; not LOT-end capped)",
    "CAR-T during or closing LOT1 [start, base end; +1d iff CAR-T closed LOT1]",
    "CAR-T prior to OR during LOT1 (the ask)",
    "LOT1 ended by CAR-T (end reason SCT_CART/CART_INIT)",
    "Any CAR-T on/after LOT1 start (incl. later-line, informational)",
    "LOT1 flagged as a CAR-T line (LOT_CART_LOT_FLG)")
  vals <- c(na_or(r$lot1_patients[1]), na_or(r$n_cart_before_lot1_start[1]),
            na_or(r$n_cart_in_lot1_induction[1]), na_or(r$n_cart_during_or_closing_lot1[1]),
            na_or(r$n_cart_prior_or_during_lot1[1]), na_or(r$n_lot1_ended_by_cart[1]),
            na_or(r$n_with_cart_on_after_lot1_start[1]), na_or(r$n_lot1_flagged_cart_line[1]))
  df <- data.frame(
    metric      = labels,
    n_patients  = ifelse(is.na(vals), NA_integer_, as.integer(vals)),
    pct_of_lot1 = c(NA_real_, vapply(vals[-1], pct, numeric(1))),
    stringsAsFactors = FALSE)
  attr(df, "have_raw_before") <- have_raw
  df
}

# ===========================================================================
# Codelist views for the raw-claim examples (guarded; built only when needed).
# Mirrors 02_lot1.R S01 (mma_codelist) and S11 (sct_codelist).
# ===========================================================================
.vqs_codelist_built <- new.env(parent = emptyenv())

vqs_build_mma_codelist <- function(con) {
  if (isTRUE(.vqs_codelist_built$mma)) return(invisible(TRUE))
  if (!exists("load_codelist_csv")) stop("load_codelist_csv not available")
  src <- load_codelist_csv("cl_mma_codelist.csv",
    c("CL_CODE_TYPE", "CL_CODE", "CL_MEDICATION_FULL", "CL_MED_CLASS", "CL_MED_ABBR"))
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW mma_codelist AS
    SELECT
      upper(trim(CL_CODE_TYPE)) AS CL_CODE_TYPE,
      upper(regexp_replace(trim(CL_CODE), '[^A-Za-z0-9]', '')) AS CL_CODE,
      lower(trim(CL_MEDICATION_FULL)) AS CL_MEDICATION_FULL,
      upper(trim(CL_MED_CLASS))       AS CL_MED_CLASS,
      upper(trim(CL_MED_ABBR))        AS CL_MED_ABBR
    FROM {src}
    WHERE CL_CODE IS NOT NULL AND trim(CL_CODE) <> ''
      AND CL_CODE_TYPE IS NOT NULL AND trim(CL_CODE_TYPE) <> ''"))
  .vqs_codelist_built$mma <- TRUE
  invisible(TRUE)
}

vqs_build_sct_codelist <- function(con) {
  if (isTRUE(.vqs_codelist_built$sct)) return(invisible(TRUE))
  if (!exists("load_codelist_csv")) stop("load_codelist_csv not available")
  src <- load_codelist_csv("cl_sct_codelist.csv",
    c("CL_CODE_TYPE", "CL_CODE", "SCT_TYPE"))
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW sct_codelist AS
    SELECT
      CASE
        WHEN upper(trim(CL_CODE_TYPE)) IN ('ICD10PROC','ICD10PCS') THEN 'ICD10PROC'
        WHEN upper(trim(CL_CODE_TYPE)) = 'ICD9PROC' THEN 'ICD9PROC'
        WHEN upper(trim(CL_CODE_TYPE)) LIKE '%PROC%' OR upper(trim(CL_CODE_TYPE)) = 'ICD' THEN 'ICD10PROC'
        WHEN upper(trim(CL_CODE_TYPE)) IN ('ICD10DIAG','ICD10DX','DIAG10')
          OR upper(trim(CL_CODE_TYPE)) LIKE 'ICD%10%DIAG%' THEN 'ICD10DIAG'
        WHEN upper(trim(CL_CODE_TYPE)) IN ('ICD9DIAG','ICD9DX','ICD9','DIAG9')
          OR upper(trim(CL_CODE_TYPE)) LIKE 'ICD%9%DIAG%' THEN 'ICD9DIAG'
        WHEN upper(trim(CL_CODE_TYPE)) IN ('DIAG','DX','DIAGNOSIS') THEN 'ICD10DIAG'
        WHEN upper(trim(CL_CODE_TYPE)) IN ('CPT','CPT4') THEN 'HCPCS'
        ELSE upper(trim(CL_CODE_TYPE))
      END AS CL_CODE_TYPE,
      upper(regexp_replace(trim(CL_CODE), '[^A-Za-z0-9]', '')) AS CL_CODE,
      CASE
        WHEN upper(trim(SCT_TYPE)) LIKE 'ALLO%' THEN 'ALLO'
        WHEN upper(trim(SCT_TYPE)) LIKE 'AUTO%' THEN 'AUTO'
        WHEN upper(trim(SCT_TYPE)) IN ('CAR-T','CART','CAR_T') THEN 'CART'
        ELSE upper(trim(SCT_TYPE))
      END AS SCT_TYPE
    FROM {src}
    WHERE CL_CODE IS NOT NULL AND trim(CL_CODE) <> ''
      AND SCT_TYPE IS NOT NULL AND trim(SCT_TYPE) <> ''"))
  .vqs_codelist_built$sct <- TRUE
  invisible(TRUE)
}

# Raw MM/steroid claims (before MAP derivation) for a set of patients, joined
# to mma_codelist exactly as 02_lot1.R S04 does. When `bounds` (the
# vqs_obs_bounds_src() subquery) is supplied, claims are restricted to
# [INDEX_DATE, OBS_END_DT] as the pipeline does; otherwise the pull falls back
# to PATID-only (a wider "journey" window the caller should label as such).
# Returns one row per claim.
vqs_raw_mma_claims <- function(con, patids, bounds = NULL) {
  vqs_build_mma_codelist(con)
  ids <- vqs_in_list(patids)
  med <- cdm_src(cfg$tbl_medical); rxt <- cdm_src(cfg$tbl_rx)
  bjoin  <- if (!is.null(bounds)) glue("JOIN {bounds} b ON b.PATID = u.PATID") else ""
  bwhere <- if (!is.null(bounds)) "WHERE u.DATE_SERVICE BETWEEN b.INDEX_DATE AND b.OBS_END_DT" else ""
  db_q(con, glue("
    WITH cl AS (SELECT /*+ BROADCAST */ * FROM mma_codelist),
    med_proc_cd AS (
      SELECT cast(m.PATID as string) AS PATID, cast(m.FST_DT AS date) AS DATE_SERVICE,
             'medical' AS CLAIM_TYPE, 'med_proc_cd' AS CLAIM_SOURCE,
             c.CL_CODE AS CODE, c.CL_CODE_TYPE AS CODE_TYPE,
             c.CL_MED_ABBR AS MED_ABBR, c.CL_MED_CLASS AS MED_CLASS
      FROM {med} m JOIN cl c ON c.CL_CODE_TYPE = 'HCPCS'
       AND upper(regexp_replace(coalesce(cast(m.PROC_CD as string),''), '[^A-Za-z0-9]', '')) = c.CL_CODE
      WHERE cast(m.PATID as string) IN ({ids})
    ),
    med_bill_proc_cd AS (
      SELECT cast(m.PATID as string) AS PATID, cast(m.FST_DT AS date) AS DATE_SERVICE,
             'medical' AS CLAIM_TYPE, 'med_bill_proc' AS CLAIM_SOURCE,
             c.CL_CODE AS CODE, c.CL_CODE_TYPE AS CODE_TYPE,
             c.CL_MED_ABBR AS MED_ABBR, c.CL_MED_CLASS AS MED_CLASS
      FROM {med} m JOIN cl c ON c.CL_CODE_TYPE = 'HCPCS'
       AND upper(regexp_replace(coalesce(cast(m.BILL_PROC_CD as string),''), '[^A-Za-z0-9]', '')) = c.CL_CODE
      WHERE cast(m.PATID as string) IN ({ids})
    ),
    med_ndc AS (
      SELECT cast(m.PATID as string) AS PATID, cast(m.FST_DT AS date) AS DATE_SERVICE,
             'medical' AS CLAIM_TYPE, 'med_ndc' AS CLAIM_SOURCE,
             c.CL_CODE AS CODE, c.CL_CODE_TYPE AS CODE_TYPE,
             c.CL_MED_ABBR AS MED_ABBR, c.CL_MED_CLASS AS MED_CLASS
      FROM {med} m JOIN cl c ON c.CL_CODE_TYPE = 'NDC'
       AND lpad(regexp_replace(coalesce(cast(m.NDC as string),''), '[^0-9]', ''), 11, '0')
         = lpad(regexp_replace(c.CL_CODE, '[^0-9]', ''), 11, '0')
      WHERE cast(m.PATID as string) IN ({ids})
        AND cast(m.NDC as string) IS NOT NULL AND trim(cast(m.NDC as string)) <> ''
    ),
    rx_claims AS (
      SELECT cast(r.PATID as string) AS PATID, cast(r.FILL_DT AS date) AS DATE_SERVICE,
             'pharmacy' AS CLAIM_TYPE, 'rx_ndc' AS CLAIM_SOURCE,
             c.CL_CODE AS CODE, c.CL_CODE_TYPE AS CODE_TYPE,
             c.CL_MED_ABBR AS MED_ABBR, c.CL_MED_CLASS AS MED_CLASS
      FROM {rxt} r JOIN cl c ON c.CL_CODE_TYPE = 'NDC'
       AND lpad(regexp_replace(coalesce(cast(r.NDC as string),''), '[^0-9]', ''), 11, '0')
         = lpad(regexp_replace(c.CL_CODE, '[^0-9]', ''), 11, '0')
      WHERE cast(r.PATID as string) IN ({ids})
    ),
    u AS (
      SELECT * FROM med_proc_cd
      UNION ALL SELECT * FROM med_bill_proc_cd
      UNION ALL SELECT * FROM med_ndc
      UNION ALL SELECT * FROM rx_claims
    )
    SELECT u.PATID, cast(u.DATE_SERVICE as string) AS DATE_SERVICE, u.CLAIM_TYPE,
           u.CLAIM_SOURCE, u.CODE, u.CODE_TYPE, u.MED_ABBR, u.MED_CLASS
    FROM u {bjoin}
    {bwhere}
    ORDER BY u.PATID, u.DATE_SERVICE, u.MED_ABBR
  "))
}

# Raw SCT claims (before AUTO/ALLO/CART date processing) for given patients,
# mirroring 02_lot1.R S12 (medical PROC_CD/BILL_PROC_CD + med_procedure +
# med_diagnosis). When `bounds` is supplied, restricts to [INDEX_DATE,
# OBS_END_DT] as S12 does. Returns one row per (PATID, DATE_SERVICE, SCT_TYPE).
vqs_raw_sct_claims <- function(con, patids, bounds = NULL) {
  vqs_build_sct_codelist(con)
  ids <- vqs_in_list(patids)
  med <- cdm_src(cfg$tbl_medical); mproc <- cdm_src(cfg$tbl_med_proc)
  dx  <- cdm_src(cfg$tbl_med_diag)
  bjoin  <- if (!is.null(bounds)) glue("JOIN {bounds} b ON b.PATID = c.PATID") else ""
  bwhere <- if (!is.null(bounds)) "WHERE c.DATE_SERVICE BETWEEN b.INDEX_DATE AND b.OBS_END_DT" else ""
  db_q(con, glue("
    WITH s AS (SELECT /*+ BROADCAST */ * FROM sct_codelist),
    med_proc AS (
      SELECT cast(m.PATID as string) AS PATID, cast(m.FST_DT AS date) AS DATE_SERVICE,
             s.SCT_TYPE, s.CL_CODE AS CODE, 'med_proc_cd' AS SRC
      FROM {med} m JOIN s ON s.CL_CODE_TYPE = 'HCPCS'
       AND upper(regexp_replace(coalesce(cast(m.PROC_CD as string),''), '[^A-Za-z0-9]', '')) = s.CL_CODE
      WHERE cast(m.PATID as string) IN ({ids})
    ),
    med_bill AS (
      SELECT cast(m.PATID as string) AS PATID, cast(m.FST_DT AS date) AS DATE_SERVICE,
             s.SCT_TYPE, s.CL_CODE AS CODE, 'med_bill_proc' AS SRC
      FROM {med} m JOIN s ON s.CL_CODE_TYPE = 'HCPCS'
       AND upper(regexp_replace(coalesce(cast(m.BILL_PROC_CD as string),''), '[^A-Za-z0-9]', '')) = s.CL_CODE
      WHERE cast(m.PATID as string) IN ({ids})
    ),
    medproc AS (
      SELECT cast(mp.PATID as string) AS PATID, cast(mp.FST_DT AS date) AS DATE_SERVICE,
             s.SCT_TYPE, s.CL_CODE AS CODE, 'med_procedure' AS SRC
      FROM {mproc} mp JOIN s
        ON (  (s.CL_CODE_TYPE = 'ICD10PROC' AND coalesce(upper(mp.ICD_FLAG),'') NOT IN ('9','ICD9','ICD-9'))
           OR (s.CL_CODE_TYPE = 'ICD9PROC'  AND upper(mp.ICD_FLAG) IN ('9','ICD9','ICD-9'))
           OR  s.CL_CODE_TYPE = 'HCPCS')
       AND upper(regexp_replace(coalesce(cast(mp.PROC as string),''), '[^A-Za-z0-9]', '')) = s.CL_CODE
      WHERE cast(mp.PATID as string) IN ({ids})
    ),
    med_diag AS (
      SELECT cast(d.PATID as string) AS PATID, cast(d.FST_DT AS date) AS DATE_SERVICE,
             s.SCT_TYPE, s.CL_CODE AS CODE, 'med_diagnosis' AS SRC
      FROM {dx} d JOIN s
        ON (  (s.CL_CODE_TYPE = 'ICD10DIAG' AND coalesce(upper(d.ICD_FLAG),'') NOT IN ('9','ICD9','ICD-9'))
           OR (s.CL_CODE_TYPE = 'ICD9DIAG'  AND upper(d.ICD_FLAG) IN ('9','ICD9','ICD-9')))
       AND upper(regexp_replace(coalesce(cast(d.DIAG as string),''), '[^A-Za-z0-9]', '')) = s.CL_CODE
      WHERE cast(d.PATID as string) IN ({ids})
    ),
    c AS (
      SELECT * FROM med_proc UNION ALL SELECT * FROM med_bill
      UNION ALL SELECT * FROM medproc UNION ALL SELECT * FROM med_diag
    )
    SELECT c.PATID, cast(c.DATE_SERVICE as string) AS DATE_SERVICE, c.SCT_TYPE,
           min(c.CODE) AS CODE
    FROM c {bjoin}
    {bwhere}
    GROUP BY c.PATID, c.DATE_SERVICE, c.SCT_TYPE
    ORDER BY c.PATID, c.DATE_SERVICE
  "))
}

# All raw CAR-T claim dates for the LOT1 cohort, observation-window-bounded
# (needs ELIG_COH_FINAL bounds). This is what makes "CAR-T BEFORE LOT1 start"
# answerable: LOT1_SCT.FIRST_CART_DT only captures CAR-T on/after LOT1 start
# (02_lot1.R first_cart CTE filters TX_DT >= LOT1_START_DT), so pre-LOT1 CAR-T
# must come from the raw SCT claims. Creates/returns a temp view name, or NULL
# when the codelist / bounds / CDM are unreachable.
vqs_build_raw_cart_dates <- function(con, lot_long, bounds) {
  if (is.null(bounds)) return(NULL)
  view <- "vqs_cart_dates_raw"
  ok <- tryCatch({
    vqs_build_sct_codelist(con)
    med <- cdm_src(cfg$tbl_medical); mproc <- cdm_src(cfg$tbl_med_proc)
    dx  <- cdm_src(cfg$tbl_med_diag)
    db_exec(con, glue("
      CREATE OR REPLACE TEMPORARY VIEW {view} AS
      WITH s AS (SELECT /*+ BROADCAST */ * FROM sct_codelist WHERE SCT_TYPE = 'CART'),
      l1 AS (SELECT DISTINCT cast(PATID as string) AS PATID FROM {lot_long} WHERE LOT_NUM = 1),
      bnd AS {bounds},
      raw AS (
        SELECT cast(m.PATID as string) AS PATID, cast(m.FST_DT AS date) AS DATE_SERVICE
        FROM {med} m JOIN s ON s.CL_CODE_TYPE = 'HCPCS'
         AND upper(regexp_replace(coalesce(cast(m.PROC_CD as string),''), '[^A-Za-z0-9]', '')) = s.CL_CODE
        UNION ALL
        SELECT cast(m.PATID as string) AS PATID, cast(m.FST_DT AS date) AS DATE_SERVICE
        FROM {med} m JOIN s ON s.CL_CODE_TYPE = 'HCPCS'
         AND upper(regexp_replace(coalesce(cast(m.BILL_PROC_CD as string),''), '[^A-Za-z0-9]', '')) = s.CL_CODE
        UNION ALL
        SELECT cast(mp.PATID as string) AS PATID, cast(mp.FST_DT AS date) AS DATE_SERVICE
        FROM {mproc} mp JOIN s
          ON (  (s.CL_CODE_TYPE = 'ICD10PROC' AND coalesce(upper(mp.ICD_FLAG),'') NOT IN ('9','ICD9','ICD-9'))
             OR (s.CL_CODE_TYPE = 'ICD9PROC'  AND upper(mp.ICD_FLAG) IN ('9','ICD9','ICD-9'))
             OR  s.CL_CODE_TYPE = 'HCPCS')
         AND upper(regexp_replace(coalesce(cast(mp.PROC as string),''), '[^A-Za-z0-9]', '')) = s.CL_CODE
        UNION ALL
        SELECT cast(d.PATID as string) AS PATID, cast(d.FST_DT AS date) AS DATE_SERVICE
        FROM {dx} d JOIN s
          ON (  (s.CL_CODE_TYPE = 'ICD10DIAG' AND coalesce(upper(d.ICD_FLAG),'') NOT IN ('9','ICD9','ICD-9'))
             OR (s.CL_CODE_TYPE = 'ICD9DIAG'  AND upper(d.ICD_FLAG) IN ('9','ICD9','ICD-9')))
         AND upper(regexp_replace(coalesce(cast(d.DIAG as string),''), '[^A-Za-z0-9]', '')) = s.CL_CODE
      )
      SELECT DISTINCT r.PATID, r.DATE_SERVICE AS CART_DT
      FROM raw r
      JOIN l1  ON l1.PATID = r.PATID
      JOIN bnd b ON b.PATID = r.PATID
      WHERE r.DATE_SERVICE BETWEEN b.INDEX_DATE AND b.OBS_END_DT"))
    TRUE
  }, error = function(e) { log_msg("  [vqs] raw CAR-T date scan unavailable: ",
                                   conditionMessage(e)); FALSE })
  if (isTRUE(ok)) view else NULL
}

# MAP-derived journey (always available) for a set of patients: their
# MAP_STACKED segments tagged relative to LOT1, so the "after MAPs" picture
# sits next to the raw claims.
vqs_map_journey <- function(con, map_tbl, lot_long, patids) {
  ids <- vqs_in_list(patids)
  db_q(con, glue("
    WITH l1 AS (
      SELECT cast(PATID as string) AS PATID, cast(LOT_START_DT as date) AS L1,
             cast(LOT_BASE_END_DT as date) AS L1_END
      FROM {lot_long} WHERE LOT_NUM = 1
    )
    SELECT cast(m.PATID as string) AS PATID,
           m.MAP_MED_TYPE  AS MED_ABBR,
           m.MAP_MED_CLASS AS MED_CLASS,
           cast(m.MAP_START_DT as string) AS MAP_START_DT,
           cast(m.MAP_END_DT   as string) AS MAP_END_DT,
           CASE WHEN m.MAP_START_DT BETWEEN l.L1 AND date_add(l.L1, {VQS_W1} - 1)
                THEN 1 ELSE 0 END AS in_lot1_induction
    FROM {map_tbl} m JOIN l1 l ON l.PATID = cast(m.PATID as string)
    WHERE cast(m.PATID as string) IN ({ids})
    ORDER BY PATID, MAP_START_DT, MED_ABBR
  "))
}

# Q2 example patients: a few patients with POMA in their LOT1 regimen, with the
# MAP-derived journey (reliable) + raw MM claims (guarded). n controls how many.
vqs_q2_poma_examples <- function(con, lot_long, map_tbl, tokens, n = 5L, bounds = NULL) {
  poma <- tokens$poma
  ids <- db_q(con, glue("
    SELECT cast(PATID as string) AS PATID
    FROM {lot_long}
    WHERE LOT_NUM = 1 AND LOT_BASE_MEDS IS NOT NULL
      AND array_contains(split(LOT_BASE_MEDS, ' '), '{poma}')
    ORDER BY PATID
    LIMIT {as.integer(n)}"))$PATID
  out <- list(patids = ids, journey = NULL, raw = NULL, note = NULL,
              windowed = !is.null(bounds))
  if (length(ids) == 0) {
    out$note <- sprintf("No LOT1 patients with token '%s'.", poma)
    return(out)
  }
  out$journey <- tryCatch(vqs_map_journey(con, map_tbl, lot_long, ids),
                          error = function(e) NULL)
  out$raw <- tryCatch(vqs_raw_mma_claims(con, ids, bounds = bounds), error = function(e) {
    out$note <<- paste("Raw-claim pull unavailable:", conditionMessage(e))
    NULL
  })
  if (is.null(bounds) && !is.null(out$raw))
    out$note <- paste(c(out$note, paste0(
      "Raw claims NOT observation-window bounded (ELIG_COH_FINAL unavailable); ",
      "shows full claim history for these PATIDs.")), collapse = " ")
  out
}

# Q6 example patients: a few with CAR-T prior to/during LOT1, with raw SCT
# claims (guarded) + the surrounding raw MM claims + MAP journey. "During or
# closing LOT1" uses [L1_START, L1_END], extended to L1_END + 1 only when
# END_REASON in (SCT_CART, CART_INIT) (the engine sets L1_END to the CAR-T
# date - 1 only for a CAR-T-ending line); "before LOT1" patients are added
# from the raw CAR-T date view when available.
vqs_q6_cart_examples <- function(con, lot_long, sct_tbl, map_tbl, n = 5L,
                                 bounds = NULL, cart_raw_tbl = NULL) {
  before_union <- if (!is.null(cart_raw_tbl)) glue("
    UNION
    SELECT DISTINCT cast(l.PATID as string) AS PATID
    FROM (SELECT cast(PATID as string) AS PATID, cast(LOT_START_DT as date) AS L1
          FROM {lot_long} WHERE LOT_NUM = 1) l
    JOIN {cart_raw_tbl} c ON c.PATID = l.PATID AND c.CART_DT < l.L1")
  else ""
  ids <- db_q(con, glue("
    WITH l1 AS (
      SELECT cast(PATID as string) AS PATID, cast(LOT_START_DT as date) AS L1,
             cast(LOT_BASE_END_DT as date) AS L1_END,
             LOT_BASE_END_REASON AS END_REASON
      FROM {lot_long} WHERE LOT_NUM = 1
    ),
    sct AS (
      SELECT cast(PATID as string) AS PATID, min(cast(FIRST_CART_DT as date)) AS CART_DT
      FROM {sct_tbl} WHERE FIRST_CART_DT IS NOT NULL
      GROUP BY cast(PATID as string)
    ),
    pick AS (
      -- 'during or closing LOT1': +1 only when CAR-T itself closed LOT1.
      SELECT l.PATID FROM l1 l JOIN sct s ON s.PATID = l.PATID
      WHERE s.CART_DT BETWEEN l.L1 AND
            (CASE WHEN l.END_REASON IN ('SCT_CART','CART_INIT')
                  THEN date_add(l.L1_END, 1) ELSE l.L1_END END)
      {before_union}
    )
    SELECT PATID FROM pick ORDER BY PATID LIMIT {as.integer(n)}"))$PATID
  out <- list(patids = ids, sct_raw = NULL, mma_raw = NULL, journey = NULL,
              note = NULL, windowed = !is.null(bounds))
  if (length(ids) == 0) {
    out$note <- if (is.null(cart_raw_tbl))
      paste("No patients with CAR-T during or closing LOT1.",
            "(Before-LOT1 CAR-T was NOT assessed for examples - the raw CAR-T",
            "scan was unavailable.)")
    else "No patients with CAR-T prior to or during LOT1."
    return(out)
  }
  out$journey <- tryCatch(vqs_map_journey(con, map_tbl, lot_long, ids),
                          error = function(e) NULL)
  out$sct_raw <- tryCatch(vqs_raw_sct_claims(con, ids, bounds = bounds), error = function(e) {
    out$note <<- paste("Raw SCT-claim pull unavailable:", conditionMessage(e)); NULL })
  out$mma_raw <- tryCatch(vqs_raw_mma_claims(con, ids, bounds = bounds), error = function(e) NULL)
  if (is.null(bounds) && (!is.null(out$sct_raw) || !is.null(out$mma_raw)))
    out$note <- paste(c(out$note, paste0(
      "Raw claims NOT observation-window bounded (ELIG_COH_FINAL unavailable); ",
      "shows full claim history for these PATIDs.")), collapse = " ")
  out
}
