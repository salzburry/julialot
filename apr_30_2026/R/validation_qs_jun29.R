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
#  * "Receives a steroid at LOTn"  -> a STEROID-class MAP (MAP_STACKED,
#    MAP_MED_CLASS = 'STEROID') whose MAP_START_DT falls inside the LOTn
#    induction window [LOT_START_DT, LOT_START_DT + W - 1], W = 60 for LOT1,
#    30 for LOT2. This mirrors the LOT engine's own induction-membership rule
#    (02_lot1.R S09, which selects induction meds by MAP_START_DT in-window
#    and explicitly EXCLUDES MAP_MED_CLASS = 'STEROID' from the regimen). The
#    same STEROID-class MAP rows are the steroid signal used throughout.
#  * "Received a steroid within N days prior / after" -> a STEROID-class MAP
#    that STARTS in the respective window. The 7/14/30 windows are cumulative
#    (<= N days), exactly as phrased in the ask.
#  * Steroid signal source: MAP_STACKED STEROID-class segments (derived from
#    cl_mma_codelist.csv). This is self-contained from persisted tables and is
#    identical in the standalone program and the dashboard. NOTE: it is the
#    codelist's STEROID class, which can differ slightly from the dashboard's
#    optional steroid_codes.csv augmentation (LOT_BASE_MEDS_AUG) when that CSV
#    is populated; the definition used here is stated on every output.
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
if (is.na(VQS_W1) || VQS_W1 < 1) VQS_W1 <- 60L
if (is.na(VQS_W2) || VQS_W2 < 1) VQS_W2 <- 30L

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

# Steroid-claim relation (sub-select string) over MAP_STACKED STEROID class.
vqs_steroid_src <- function(map_tbl) glue(
  "(SELECT cast(PATID as string) AS PATID, MAP_START_DT AS STER_DT
      FROM {map_tbl}
     WHERE upper(MAP_MED_CLASS) = 'STEROID' AND MAP_START_DT IS NOT NULL)")

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
vqs_steroid_windows <- function(con, lot_long, map_tbl, lot_num, w) {
  ster <- vqs_steroid_src(map_tbl)
  r <- db_q(con, glue("
    WITH lot AS (
      SELECT cast(PATID as string) AS PATID, cast(LOT_START_DT as date) AS LS
      FROM {lot_long}
      WHERE LOT_NUM = {lot_num} AND LOT_START_DT IS NOT NULL
    ),
    ster AS {ster},
    at_line AS (
      SELECT DISTINCT l.PATID
      FROM lot l JOIN ster s ON s.PATID = l.PATID
       AND s.STER_DT BETWEEN l.LS AND date_add(l.LS, {w} - 1)
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
    SELECT
      (SELECT count(*) FROM lot)     AS line_patients,
      (SELECT count(*) FROM at_line) AS line_with_steroid,
      count(*)                       AS line_without_steroid,
      sum(p7) AS prior_7d, sum(p14) AS prior_14d, sum(p30) AS prior_30d,
      sum(a7) AS after_7d, sum(a14) AS after_14d, sum(a30) AS after_30d
    FROM flags
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

# ===========================================================================
# Q5 - attribution check: of patients with no steroid at LOT2 but a steroid in
# the 30d before LOT2 start, how many had a steroid at LOT1?
# ===========================================================================
vqs_q5_lot2_attribution <- function(con, lot_long, map_tbl, w1, w2) {
  ster <- vqs_steroid_src(map_tbl)
  r <- db_q(con, glue("
    WITH lot2 AS (
      SELECT cast(PATID as string) AS PATID, cast(LOT_START_DT as date) AS L2
      FROM {lot_long} WHERE LOT_NUM = 2 AND LOT_START_DT IS NOT NULL
    ),
    lot1 AS (
      SELECT cast(PATID as string) AS PATID,
             cast(LOT_START_DT as date)    AS L1,
             cast(LOT_BASE_END_DT as date) AS L1_END
      FROM {lot_long} WHERE LOT_NUM = 1
    ),
    ster AS {ster},
    at_lot2 AS (
      SELECT DISTINCT l.PATID FROM lot2 l JOIN ster s ON s.PATID = l.PATID
       AND s.STER_DT BETWEEN l.L2 AND date_add(l.L2, {w2} - 1)
    ),
    prior_grp AS (   -- no steroid at LOT2, but a steroid in the 30d before LOT2
      SELECT DISTINCT l.PATID, l.L2
      FROM lot2 l
      LEFT JOIN at_lot2 a ON a.PATID = l.PATID
      JOIN ster s ON s.PATID = l.PATID
        AND s.STER_DT BETWEEN date_sub(l.L2, 30) AND date_sub(l.L2, 1)
      WHERE a.PATID IS NULL
    ),
    at_lot1_ind AS (
      SELECT DISTINCT g.PATID FROM prior_grp g
      JOIN lot1 l ON l.PATID = g.PATID
      JOIN ster s ON s.PATID = g.PATID
        AND s.STER_DT BETWEEN l.L1 AND date_add(l.L1, {w1} - 1)
    ),
    during_lot1 AS (
      SELECT DISTINCT g.PATID FROM prior_grp g
      JOIN lot1 l ON l.PATID = g.PATID
      JOIN ster s ON s.PATID = g.PATID
        AND l.L1_END IS NOT NULL AND s.STER_DT BETWEEN l.L1 AND l.L1_END
    )
    SELECT a.n1 AS n_no_lot2_steroid_with_prior30,
           b.n2 AS n_with_steroid_at_lot1_induction,
           c.n3 AS n_with_steroid_anytime_during_lot1
    FROM      (SELECT count(*) AS n1 FROM prior_grp)   a
    CROSS JOIN (SELECT count(*) AS n2 FROM at_lot1_ind) b
    CROSS JOIN (SELECT count(*) AS n3 FROM during_lot1) c
  "))
  denom <- as.numeric(r$n_no_lot2_steroid_with_prior30[1])
  n_ind <- as.numeric(r$n_with_steroid_at_lot1_induction[1])
  n_dur <- as.numeric(r$n_with_steroid_anytime_during_lot1[1])
  pct <- function(x) if (isTRUE(denom > 0)) round(100 * x / denom, 2) else NA_real_
  data.frame(
    metric = c("No-steroid-at-LOT2 patients with a steroid in the 30d before LOT2 (denominator)",
               "  ... of whom had a steroid at LOT1 INDUCTION (within 60d window)",
               "  ... of whom had a steroid ANY time during LOT1 [start, base end]"),
    n_patients = as.integer(c(denom, n_ind, n_dur)),
    pct_of_denominator = c(NA_real_, pct(n_ind), pct(n_dur)),
    stringsAsFactors = FALSE)
}

# ===========================================================================
# Q6 - CAR-T prior to or during LOT1
# ===========================================================================
vqs_q6_cart <- function(con, lot_long, sct_tbl, w1) {
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
    j AS (
      SELECT l.PATID, l.L1, l.L1_END, l.END_REASON, l.CART_FLG, s.CART_DT
      FROM l1 l LEFT JOIN sct s ON s.PATID = l.PATID
    )
    SELECT
      count(*) AS lot1_patients,
      sum(CASE WHEN CART_DT IS NOT NULL THEN 1 ELSE 0 END)                                   AS n_with_any_cart_date,
      sum(CASE WHEN CART_DT IS NOT NULL AND CART_DT <  L1 THEN 1 ELSE 0 END)                 AS n_cart_before_lot1_start,
      sum(CASE WHEN CART_DT BETWEEN L1 AND date_add(L1, {w1} - 1) THEN 1 ELSE 0 END)         AS n_cart_in_lot1_induction,
      sum(CASE WHEN CART_DT IS NOT NULL AND L1_END IS NOT NULL
                AND CART_DT BETWEEN L1 AND L1_END THEN 1 ELSE 0 END)                         AS n_cart_during_lot1,
      sum(CASE WHEN CART_DT IS NOT NULL AND (CART_DT < L1
                OR (L1_END IS NOT NULL AND CART_DT BETWEEN L1 AND L1_END)) THEN 1 ELSE 0 END) AS n_cart_prior_or_during_lot1,
      sum(CASE WHEN END_REASON IN ('SCT_CART','CART_INIT') THEN 1 ELSE 0 END)                AS n_lot1_ended_by_cart,
      sum(CASE WHEN CART_FLG = 1 THEN 1 ELSE 0 END)                                          AS n_lot1_flagged_cart_line
    FROM j
  "))
  n <- as.numeric(r$lot1_patients[1])
  pct <- function(x) if (isTRUE(n > 0)) round(100 * x / n, 2) else NA_real_
  labels <- c(
    "LOT1 patients (denominator)",
    "With any first-CAR-T date (LOT1_SCT.FIRST_CART_DT)",
    "CAR-T BEFORE LOT1 start",
    "CAR-T within LOT1 60d induction window",
    "CAR-T during LOT1 [start, base end]",
    "CAR-T prior to OR during LOT1 (the ask)",
    "LOT1 ended by CAR-T (end reason SCT_CART/CART_INIT)",
    "LOT1 flagged as a CAR-T line (LOT_CART_LOT_FLG)")
  vals <- as.numeric(c(r$lot1_patients[1], r$n_with_any_cart_date[1],
                       r$n_cart_before_lot1_start[1], r$n_cart_in_lot1_induction[1],
                       r$n_cart_during_lot1[1], r$n_cart_prior_or_during_lot1[1],
                       r$n_lot1_ended_by_cart[1], r$n_lot1_flagged_cart_line[1]))
  data.frame(
    metric      = labels,
    n_patients  = as.integer(vals),
    pct_of_lot1 = c(NA_real_, vapply(vals[-1], pct, numeric(1))),
    stringsAsFactors = FALSE)
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
# to mma_codelist exactly as 02_lot1.R S04 does. Returns one row per claim.
vqs_raw_mma_claims <- function(con, patids) {
  vqs_build_mma_codelist(con)
  ids <- vqs_in_list(patids)
  med <- cdm_src(cfg$tbl_medical); rxt <- cdm_src(cfg$tbl_rx)
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
    SELECT PATID, cast(DATE_SERVICE as string) AS DATE_SERVICE, CLAIM_TYPE,
           CLAIM_SOURCE, CODE, CODE_TYPE, MED_ABBR, MED_CLASS
    FROM u
    ORDER BY PATID, DATE_SERVICE, MED_ABBR
  "))
}

# Raw SCT claims (before AUTO/ALLO/CART date processing) for given patients,
# mirroring 02_lot1.R S12 (medical PROC_CD/BILL_PROC_CD + med_procedure +
# med_diagnosis). Returns one row per (PATID, DATE_SERVICE, SCT_TYPE).
vqs_raw_sct_claims <- function(con, patids) {
  vqs_build_sct_codelist(con)
  ids <- vqs_in_list(patids)
  med <- cdm_src(cfg$tbl_medical); mproc <- cdm_src(cfg$tbl_med_proc)
  dx  <- cdm_src(cfg$tbl_med_diag)
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
    SELECT PATID, cast(DATE_SERVICE as string) AS DATE_SERVICE, SCT_TYPE,
           min(CODE) AS CODE
    FROM c GROUP BY PATID, DATE_SERVICE, SCT_TYPE
    ORDER BY PATID, DATE_SERVICE
  "))
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
vqs_q2_poma_examples <- function(con, lot_long, map_tbl, tokens, n = 5L) {
  poma <- tokens$poma
  ids <- db_q(con, glue("
    SELECT cast(PATID as string) AS PATID
    FROM {lot_long}
    WHERE LOT_NUM = 1 AND LOT_BASE_MEDS IS NOT NULL
      AND array_contains(split(LOT_BASE_MEDS, ' '), '{poma}')
    ORDER BY PATID
    LIMIT {as.integer(n)}"))$PATID
  out <- list(patids = ids, journey = NULL, raw = NULL, note = NULL)
  if (length(ids) == 0) {
    out$note <- sprintf("No LOT1 patients with token '%s'.", poma)
    return(out)
  }
  out$journey <- tryCatch(vqs_map_journey(con, map_tbl, lot_long, ids),
                          error = function(e) NULL)
  out$raw <- tryCatch(vqs_raw_mma_claims(con, ids), error = function(e) {
    out$note <<- paste("Raw-claim pull unavailable:", conditionMessage(e))
    NULL
  })
  out
}

# Q6 example patients: a few with CAR-T prior to/during LOT1, with raw SCT
# claims (guarded) + the surrounding raw MM claims + MAP journey.
vqs_q6_cart_examples <- function(con, lot_long, sct_tbl, map_tbl, n = 5L) {
  ids <- db_q(con, glue("
    WITH l1 AS (
      SELECT cast(PATID as string) AS PATID, cast(LOT_START_DT as date) AS L1,
             cast(LOT_BASE_END_DT as date) AS L1_END
      FROM {lot_long} WHERE LOT_NUM = 1
    ),
    sct AS (
      SELECT cast(PATID as string) AS PATID, min(cast(FIRST_CART_DT as date)) AS CART_DT
      FROM {sct_tbl} WHERE FIRST_CART_DT IS NOT NULL
      GROUP BY cast(PATID as string)
    )
    SELECT l.PATID FROM l1 l JOIN sct s ON s.PATID = l.PATID
    WHERE s.CART_DT < l.L1
       OR (l.L1_END IS NOT NULL AND s.CART_DT BETWEEN l.L1 AND l.L1_END)
    ORDER BY l.PATID
    LIMIT {as.integer(n)}"))$PATID
  out <- list(patids = ids, sct_raw = NULL, mma_raw = NULL, journey = NULL, note = NULL)
  if (length(ids) == 0) {
    out$note <- "No patients with CAR-T prior to or during LOT1."
    return(out)
  }
  out$journey <- tryCatch(vqs_map_journey(con, map_tbl, lot_long, ids),
                          error = function(e) NULL)
  out$sct_raw <- tryCatch(vqs_raw_sct_claims(con, ids), error = function(e) {
    out$note <<- paste("Raw SCT-claim pull unavailable:", conditionMessage(e)); NULL })
  out$mma_raw <- tryCatch(vqs_raw_mma_claims(con, ids), error = function(e) NULL)
  out
}
