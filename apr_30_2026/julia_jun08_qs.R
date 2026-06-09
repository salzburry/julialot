#!/usr/bin/env Rscript
# Julia June-08-2026 follow-up Qs (file: June 08 2026/julia questions june 5.pdf).
#
#   Rscript julia_jun08_qs.R
#
# Builds a SEPARATE single self-contained HTML dashboard
# (julia_jun08_qs_dashboard.html) and runs every focused analysis
# TWICE - once on the whole delivered cohort and once on Ashley's
# planned study cohort - so Julia can compare side by side.
#
#   Q1  Regimen-category sankeys: wired the same way as lot_fu_qs.R
#       (REGIMEN_CATEGORIES_CSV env var). The MM Treatment Table for
#       Protocol xlsx is not in June 08 2026/ yet; once Julia drops
#       it (or a CSV with regimen,category columns) set the env var
#       and the category sankeys turn on for both cohorts.
#   Q2  Steroid inclusion is a PIPELINE-LEVEL change (LOT regimens
#       are built with WHERE MAP_MED_CLASS <> 'STEROID' in
#       lot_program.R:679 / lot2_5_base.R). This script documents
#       the HCPCS / NDC codes Julia provided in a scoping card so
#       they can be folded into the codelist when Julia confirms
#       the updated LOT rules. No regenerated LOT tables yet.
#   Q3  Patient journeys AND focused/category sankeys all filtered
#       so non-progressors (no subsequent LOT) drop out: journey
#       examples require max LOT_NUM >= 2, sankeys INNER-JOIN
#       LOTn and LOTn+1 so the (no LOTn) bucket is gone entirely.
#   Q4  Ashley's planned study cohort - materialised as a
#       session-scoped temp view (ASHLEY_VIEW) so downstream queries
#       INNER JOIN to it (no giant IN-list literal). If the
#       authoritative IE_COHORT_PATIDS view from lot_ie_cohort.R is
#       present it is reused verbatim; otherwise the full criteria
#       are built inline. Enforced: LOT1 LOT_START_DT >= 2017-01-01
#       (NOT ELIG_COH_FINAL.INDEX_DATE, the MM-dx qualifying date per
#       pipeline_steps.R:356); no belantamab in LOT_BASE_MEDS at ANY
#       LOT_NUM nor in MAP_STACKED.MAP_MED_TYPE (true any-exposure);
#       and - when member_enrollment is readable - CE >= 365 d before
#       1L start AND CE >= 183 d before MM-dx date (gaps <= 30 d,
#       same span logic as pipeline_steps.R:386). If enrollment is
#       NOT readable the CE windows are skipped and the cohort card
#       says so. Still NOT enforced (flagged in the card, not
#       silently dropped): CE >= 3 months follow-up, re-check of
#       age >= 18 at MM-dx, and the baseline-window mismatch
#       (other-malig / pregnancy / no-baseline-MM-therapy exclusions
#       inherited from the delivered cohort were applied against the
#       pipeline window, not Julia's 12-mo-pre-1L window).
#
# Reads only persisted work-schema tables (LOT_LONG, ELIG_COH_FINAL,
# MAP_STACKED) plus an optional REGIMEN_CATEGORIES_CSV. Builds
# nothing in the warehouse; safe to run any time after the pipeline.

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
source(file.path(source_dir, "dashboard_lot.R"))

TOP_N <- as.integer(Sys.getenv("FOCUSED_SANKEY_TOP_N", unset = "10"))
if (is.na(TOP_N) || TOP_N < 1) TOP_N <- 10L
ELIGIBLE_1L_FROM <- Sys.getenv("ELIGIBLE_1L_FROM", unset = "2017-01-01")
BELA_TOKEN       <- Sys.getenv("BELANTAMAB_MED_ABBR", unset = "BELA")
# Continuous-enrolment thresholds for the Ashley cohort (match
# lot_ie_cohort.R defaults). When member_enrollment is readable these
# ARE enforced inline; otherwise the cohort degrades to LOT1-date +
# belantamab only, with a clear note in the cohort card.
IE_COHORT_VIEW   <- Sys.getenv("IE_COHORT_VIEW", unset = "IE_COHORT_PATIDS")
CE_PRE_LOT_DAYS  <- as.integer(Sys.getenv("CE_PRE_LOT1_DAYS",  unset = "365"))
CE_PRE_MM_DAYS   <- as.integer(Sys.getenv("CE_PRE_MM_DX_DAYS", unset = "183"))
CE_GAP_DAYS      <- as.integer(Sys.getenv("CE_GAP_DAYS",       unset = "30"))
ENR_TBL_NAME     <- Sys.getenv("MEMBER_ENROLLMENT_TBL",
                                unset = "member_enrollment")
if (anyNA(c(CE_PRE_LOT_DAYS, CE_PRE_MM_DAYS, CE_GAP_DAYS)))
  stop("CE_PRE_LOT1_DAYS / CE_PRE_MM_DX_DAYS / CE_GAP_DAYS must be integers.")
# Set TRUE once the cohort is built so the cohort-definition card can
# report whether the CE windows were actually applied.
.CE_ENFORCED <- FALSE

esc_html <- function(s) {
  s <- gsub("&", "&amp;", as.character(s), fixed = TRUE)
  s <- gsub("<", "&lt;",  s, fixed = TRUE)
  gsub(">", "&gt;", s, fixed = TRUE)
}

fu_sankey <- function(src_lab, tgt_lab, value, section, title) {
  if (!has_plotly || length(value) == 0) return(invisible())
  nodes <- unique(c(src_lab, tgt_lab))
  idx   <- setNames(seq_along(nodes) - 1L, nodes)
  sk <- tryCatch(
    plotly::plot_ly(
      type = "sankey", orientation = "h", arrangement = "snap",
      node = list(label = nodes, pad = 14, thickness = 16,
                  color = "#2E86AB",
                  line  = list(color = "white", width = 0.5)),
      link = list(source = unname(idx[src_lab]),
                  target = unname(idx[tgt_lab]),
                  value  = as.numeric(value),
                  color  = "rgba(46,134,171,0.30)")
    ) |>
      plotly::layout(title = list(text = title, font = list(size = 15)),
                     font  = list(size = 11),
                     margin = list(l = 10, r = 10, t = 50, b = 10),
                     paper_bgcolor = "white") |>
      plotly::config(displayModeBar = TRUE, displaylogo = FALSE),
    error = function(e) {
      log_msg("  INFO: sankey '", title, "' skipped (",
              conditionMessage(e), ")")
      NULL
    })
  if (!is.null(sk)) add_to_dashboard(sk, section = section, title = title)
}

# Materialises the Ashley-cohort PATID set as a session-scoped temp
# view so downstream queries can INNER JOIN to it instead of carrying
# a giant SQL IN (...) literal. Returns the size of the cohort (for
# the cohort-def card); 0 means no patient survived the filter.
#
# Verified pipeline semantics (pipeline_steps.R:356 + lot_program.R:686):
#   - ELIG_COH_FINAL.INDEX_DATE = MM diagnosis qualifying date, NOT
#     1L treatment start. Julia's "eligible 1L treatment on/after
#     2017-01-01" therefore filters LOT_LONG.LOT_START_DT at LOT_NUM=1.
#   - Belantamab "any exposure" check spans BOTH LOT_BASE_MEDS at any
#     LOT_NUM AND MAP_STACKED.MAP_MED_TYPE = BELA, so a belantamab
#     claim that did not surface inside a base-regimen string still
#     excludes the patient.
ASHLEY_VIEW <- "ashley_cohort"

build_ashley_cohort <- function(con, lot_long, map_tbl, final_tbl,
                                 enr_tbl, have_map, have_enr) {
  log_msg("Building Ashley's planned study cohort (temp view)")

  # Prefer the authoritative IE cohort from lot_ie_cohort.R if it has
  # already been materialised - that view enforces the full criteria
  # (1L date, belantamab-anywhere, CE >=12mo pre-LOT1, CE >=6mo
  # pre-MM-dx). The dashboard then exactly matches the standalone IE
  # cohort.
  ie_tbl <- wrk(IE_COHORT_VIEW)
  ie_ok <- isTRUE(tryCatch(
    nrow(db_q(con, glue("SELECT 1 FROM {ie_tbl} LIMIT 1"))) >= 0,
    error = function(e) FALSE))
  if (ie_ok) {
    log_msg("  Using existing ", ie_tbl, " (full IE criteria).")
    db_exec(con, glue(
      "CREATE OR REPLACE TEMPORARY VIEW {ASHLEY_VIEW} AS ",
      "SELECT DISTINCT cast(PATID as string) AS PATID FROM {ie_tbl}"))
    .CE_ENFORCED <<- TRUE
    return(as.integer(db_q(con, glue(
      "SELECT count(DISTINCT PATID) AS n FROM {ASHLEY_VIEW}"))$n))
  }

  bela_map_branch <- if (have_map) glue("
        UNION ALL
        SELECT DISTINCT cast(PATID as string) AS PATID
        FROM {map_tbl}
        WHERE upper(MAP_MED_TYPE) = upper('{BELA_TOKEN}')")
    else ""

  # CE-window CTEs - inlined only when member_enrollment is readable.
  # Mirrors the gap-allowing enrollment-span build in
  # lot_ie_cohort.R / pipeline_steps.R:386-419.
  if (have_enr) {
    enr_ctes <- glue(",
    enr_base AS (
      SELECT cast(PATID as string) AS PATID,
             cast(ELIGEFF as date) AS elig_eff,
             cast(ELIGEND as date) AS elig_end
      FROM {enr_tbl}
      WHERE ELIGEFF IS NOT NULL AND ELIGEND IS NOT NULL
    ),
    enr_ordered AS (
      SELECT PATID, elig_eff, elig_end,
        max(elig_end) OVER (PARTITION BY PATID ORDER BY elig_eff, elig_end
          ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS max_end_so_far
      FROM enr_base
    ),
    enr_flagged AS (
      SELECT PATID, elig_eff, elig_end,
        CASE WHEN max_end_so_far IS NULL THEN 1
             WHEN elig_eff <= date_add(max_end_so_far, {CE_GAP_DAYS} + 1) THEN 0
             ELSE 1 END AS new_grp
      FROM enr_ordered
    ),
    enr_grouped AS (
      SELECT PATID, elig_eff, elig_end,
        sum(new_grp) OVER (PARTITION BY PATID ORDER BY elig_eff, elig_end
          ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS grp_id
      FROM enr_flagged
    ),
    enr_spans AS (
      SELECT PATID, min(elig_eff) AS cov_start, max(elig_end) AS cov_end
      FROM enr_grouped GROUP BY PATID, grp_id
    )")
    ce_join <- glue("
      AND EXISTS (SELECT 1 FROM enr_spans s
                  WHERE s.PATID = l.PATID
                    AND s.cov_start <= date_sub(l.LOT1_DT, {CE_PRE_LOT_DAYS})
                    AND s.cov_end   >= date_sub(l.LOT1_DT, 1))
      AND EXISTS (SELECT 1 FROM enr_spans s
                  JOIN mm_dx m ON m.PATID = l.PATID
                  WHERE s.PATID = l.PATID
                    AND s.cov_start <= date_sub(m.MM_DX_DT, {CE_PRE_MM_DAYS})
                    AND s.cov_end   >= date_sub(m.MM_DX_DT, 1))")
    .CE_ENFORCED <<- TRUE
  } else {
    enr_ctes <- ""
    ce_join  <- ""
    log_msg("  member_enrollment not readable - CE windows NOT applied; ",
            "Ashley cohort = 1L-date + belantamab only. Run ",
            "lot_ie_cohort.R or check MEMBER_ENROLLMENT_TBL for the ",
            "full criteria.")
  }

  sql <- glue("
    CREATE OR REPLACE TEMPORARY VIEW {ASHLEY_VIEW} AS
    WITH lot1 AS (
      SELECT cast(PATID as string) AS PATID, LOT_START_DT AS LOT1_DT
      FROM {lot_long}
      WHERE LOT_NUM = 1 AND LOT_START_DT IS NOT NULL
    ),
    base AS (
      SELECT DISTINCT cast(PATID as string) AS PATID FROM {final_tbl}
    ),
    mm_dx AS (
      SELECT cast(PATID as string) AS PATID,
             cast(INDEX_DATE as date) AS MM_DX_DT
      FROM {final_tbl}
    ),
    bela_any AS (
      SELECT DISTINCT PATID FROM (
        SELECT cast(PATID as string) AS PATID
        FROM {lot_long}
        WHERE LOT_BASE_MEDS IS NOT NULL
          AND array_contains(split(LOT_BASE_MEDS, ' '), '{BELA_TOKEN}')
        {bela_map_branch}
      )
    ){enr_ctes}
    SELECT l.PATID
    FROM lot1 l
    JOIN base b ON b.PATID = l.PATID
    LEFT JOIN bela_any x ON x.PATID = l.PATID
    WHERE l.LOT1_DT >= cast('{ELIGIBLE_1L_FROM}' as date)
      AND x.PATID IS NULL
      {ce_join}
  ")
  ok <- tryCatch({ db_exec(con, sql); TRUE },
                 error = function(e) {
                   log_msg("  Ashley cohort view build failed: ",
                           conditionMessage(e)); FALSE })
  if (!ok) {
    # Fallback: an empty view so downstream subqueries still resolve
    # (every Ashley section then renders as empty rather than crashing).
    tryCatch(db_exec(con, glue(
      "CREATE OR REPLACE TEMPORARY VIEW {ASHLEY_VIEW} AS ",
      "SELECT cast('' as string) AS PATID WHERE 1 = 0")),
      error = function(e) NULL)
    .CE_ENFORCED <<- FALSE
    return(0L)
  }
  as.integer(db_q(con, glue(
    "SELECT count(DISTINCT PATID) AS n FROM {ASHLEY_VIEW}"))$n)
}

# Filter expression for a cohort definition. Returns a SQL fragment
# appended to a WHERE clause; relies on the persisted ASHLEY_VIEW for
# the Ashley cohort (no IN-list interpolation, so cohort size never
# hits SQL/ODBC statement-length limits).
cohort_filter_sql <- function(cohort_def) {
  if (isTRUE(cohort_def$is_ashley))
    return(paste0(" AND cast(PATID as string) IN (SELECT PATID FROM ",
                  ASHLEY_VIEW, ")"))
  ""
}

# ---- Q3 + Q4: filtered MED JOURNEY (max LOT_NUM >= 2) ---------------
build_journeys <- function(con, lot_long, map_tbl, cohort_def) {
  section <- paste0("JOURNEY_", cohort_def$section_suffix)
  log_msg("Journeys (multi-LOT only) - cohort: ", cohort_def$label)

  filt <- cohort_filter_sql(cohort_def)
  pat_pick <- tryCatch(db_q(con, glue("
    WITH pm AS (
      SELECT cast(PATID as string) AS PATID, max(LOT_NUM) AS max_lot
      FROM {lot_long}
      WHERE 1 = 1{filt}
      GROUP BY cast(PATID as string)
      HAVING max(LOT_NUM) >= 2
    )
    SELECT pm.PATID, pm.max_lot,
           ll.LOT_BASE_END_REASON AS terminal_reason
    FROM pm
    JOIN {lot_long} ll
      ON cast(ll.PATID as string) = pm.PATID
     AND ll.LOT_NUM = pm.max_lot
  ")), error = function(e) {
    log_msg("  pat_pick failed: ", conditionMessage(e)); NULL
  })

  if (is.null(pat_pick) || nrow(pat_pick) == 0) {
    add_html_card(paste0(
      '<div style="font-family:system-ui;padding:14px">',
      '<h3>Patient medication journeys (', esc_html(cohort_def$label), ')</h3>',
      '<p style="color:#555">No patients in this cohort reach ',
      'LOT_NUM &ge; 2, so no auto journey examples were drawn.</p></div>'),
      section = section,
      title = paste0("Journeys (", cohort_def$label, ", none)"))
    return(invisible())
  }
  pat_pick$max_lot <- as.numeric(pat_pick$max_lot)
  ord <- pat_pick[order(-pat_pick$max_lot), , drop = FALSE]
  pick_ids <- head(ord$PATID, 6)
  for (rs in unique(ord$terminal_reason)) {
    if (length(pick_ids) >= 12) break
    cand <- ord$PATID[ord$terminal_reason %in% rs & !ord$PATID %in% pick_ids]
    if (length(cand)) pick_ids <- c(pick_ids, cand[1])
  }
  pick_ids <- unique(pick_ids)[seq_len(min(12, length(unique(pick_ids))))]
  id_list <- paste(sprintf("'%s'", gsub("'", "''", pick_ids)), collapse = ", ")

  jdf <- db_q(con, glue("
    SELECT cast(PATID as string) AS PATID, LOT_NUM, LOT_START_TYPE,
           cast(cast(LOT_START_DT    as date) as string) AS LOT_START_DT,
           cast(cast(LOT_BASE_END_DT as date) as string) AS LOT_BASE_END_DT,
           LOT_BASE_END_REASON, LOT_BASE_LENGTH, LOT_BASE_MEDS
    FROM {lot_long}
    WHERE cast(PATID as string) IN ({id_list})
    ORDER BY PATID, LOT_NUM
  "))
  jdf$LOT_NUM         <- as.numeric(jdf$LOT_NUM)
  jdf$LOT_START_DT    <- as.Date(jdf$LOT_START_DT)
  jdf$LOT_BASE_END_DT <- as.Date(jdf$LOT_BASE_END_DT)
  eend <- jdf$LOT_BASE_END_DT
  eend[is.na(eend)] <- jdf$LOT_START_DT[is.na(eend)]
  jdf$LOT_BASE_END_DT <- eend

  mdf <- tryCatch(db_q(con, glue("
    SELECT cast(PATID as string) AS PATID,
           MAP_MED_TYPE          AS MED,
           MAP_MED_CLASS         AS CLASS,
           cast(cast(MAP_START_DT as date) as string) AS MAP_START_DT,
           cast(cast(MAP_END_DT   as date) as string) AS MAP_END_DT,
           coalesce(MAP_CNT, 1)        AS MAP_CNT,
           coalesce(MAP_DISCON_FLG, 0) AS MAP_DISCON_FLG
    FROM {map_tbl}
    WHERE cast(PATID as string) IN ({id_list})
    ORDER BY PATID, MAP_MED_TYPE, MAP_START_DT
  ")), error = function(e) {
    log_msg("  MAP_STACKED read failed: ", conditionMessage(e)); NULL
  })

  if (is.null(mdf) || nrow(mdf) == 0) {
    add_html_card(paste0(
      '<div style="font-family:system-ui;padding:14px">',
      '<h3>Patient medication journeys (', esc_html(cohort_def$label), ')</h3>',
      '<p style="color:#555">No MAP_STACKED rows for the selected ',
      'example patients in this cohort.</p></div>'),
      section = section,
      title = paste0("Journeys (", cohort_def$label, ", none)"))
    return(invisible())
  }
  mdf$MAP_START_DT <- as.Date(mdf$MAP_START_DT)
  mdf$MAP_END_DT   <- as.Date(mdf$MAP_END_DT)
  bad_end <- is.na(mdf$MAP_END_DT) | mdf$MAP_END_DT < mdf$MAP_START_DT
  mdf$MAP_END_DT[bad_end] <- mdf$MAP_START_DT[bad_end]

  k <- 0L
  for (pid in pick_ids) {
    pm <- mdf[mdf$PATID == pid, , drop = FALSE]
    pl <- jdf[jdf$PATID == pid, , drop = FALSE]
    pl <- pl[order(pl$LOT_NUM), , drop = FALSE]
    if (nrow(pm) == 0 || all(is.na(pm$MAP_START_DT))) next
    if (nrow(pl) < 2) next
    k <- k + 1L
    tryCatch({
      meds  <- sort(unique(pm$MED))
      med_y <- setNames(seq_along(meds), meds)
      ymax  <- length(meds)
      shapes <- list(); annotations <- list()
      for (j in seq_len(nrow(pm))) {
        row <- pm[j, ]
        y   <- med_y[[row$MED]]
        cls <- as.character(row$CLASS)
        color <- if (!is.na(cls) && cls %in% names(lot_class_palette))
          lot_class_palette[[cls]] else "#636e72"
        shapes[[length(shapes) + 1]] <- list(
          type = "rect",
          x0 = as.character(row$MAP_START_DT),
          x1 = as.character(row$MAP_END_DT),
          y0 = y - 0.35, y1 = y + 0.35,
          fillcolor = color,
          opacity = if (isTRUE(row$MAP_CNT > 1)) 0.6 else 0.85,
          line = list(color = color, width = 1), layer = "below"
        )
      }
      for (i in seq_len(nrow(pl))) {
        st  <- as.character(pl$LOT_START_TYPE[i])
        col <- if (!is.na(st) && st %in% names(lot_start_palette))
          lot_start_palette[[st]] else "#2E86AB"
        x <- as.character(pl$LOT_START_DT[i])
        shapes[[length(shapes) + 1]] <- list(
          type = "line", x0 = x, x1 = x, y0 = 0.3, y1 = ymax + 0.7,
          line = list(color = col, width = 2, dash = "dash"),
          layer = "above")
        annotations[[length(annotations) + 1]] <- list(
          x = x, y = ymax + 0.6,
          text = paste0("LOT", pl$LOT_NUM[i], " start"),
          showarrow = FALSE, font = list(size = 10, color = col),
          xanchor = "left", textangle = -30)
      }
      mid_x <- pm$MAP_START_DT +
        as.integer((pm$MAP_END_DT - pm$MAP_START_DT) / 2)
      hover_df <- data.frame(
        x = mid_x, y = med_y[pm$MED],
        text = paste0("Med: ", pm$MED, "\nClass: ", pm$CLASS,
                      "\nStart: ", pm$MAP_START_DT,
                      "\nEnd: ", pm$MAP_END_DT,
                      "\nMAP #", pm$MAP_CNT),
        stringsAsFactors = FALSE)
      pat_label <- paste0("Patient ", k)
      pp <- plotly::plot_ly(hover_df, x = ~x, y = ~y, text = ~text,
                            type = "scatter", mode = "markers",
                            marker = list(size = 1, opacity = 0),
                            hoverinfo = "text") |>
        plotly::layout(
          title = list(text = paste0(pat_label, " - Medication Journey (",
                                     cohort_def$label, ")"),
                       font = list(size = 14)),
          xaxis = list(title = "", type = "date", gridcolor = "#eee"),
          yaxis = list(title = "Medication", tickmode = "array",
                       tickvals = seq_along(meds), ticktext = meds,
                       range = c(0.4, length(meds) + 0.9),
                       gridcolor = "#eee"),
          shapes = shapes, annotations = annotations,
          showlegend = FALSE,
          margin = list(l = 110, t = 50, b = 40, r = 30),
          plot_bgcolor = "#fafafa", paper_bgcolor = "white") |>
        plotly::config(displayModeBar = TRUE, displaylogo = FALSE)
      add_to_dashboard(pp, section = section,
                       title = paste0(pat_label, " (",
                                      length(meds), " meds, ",
                                      nrow(pl), " LOTs)"))
    }, error = function(e)
      log_msg("  skip journey for ", pid, ": ", conditionMessage(e)))
  }
  log_msg("  ", cohort_def$label, ": ", k, " journey examples (>=2 LOTs)")
}

# ---- Q1 + Q4: category sankeys per cohort ---------------------------
# Regimen-acronym -> drug-token map. Built-in defaults cover only
# combos whose drug tokens are confirmed in the pipeline spec
# (BORT / LENA / DARA per scripts/build_lot2_5_spec.py); for the
# rest (KRd, IRd, DKd, etc.) provide a CSV at REGIMEN_ACRONYM_CSV
# with columns acronym, drugs. Drugs are space/comma/slash separated
# MED_ABBR tokens (e.g. "CARF LENA"). Steroid tokens in the drugs
# list are stripped at expansion since LOT_BASE_MEDS is steroid-free.
BUILTIN_ACRONYMS <- list(
  "VRD" = c("BORT", "LENA"),
  "VR"  = c("BORT", "LENA"),
  "VD"  = c("BORT"),
  "RD"  = c("LENA"),
  "DRD" = c("DARA", "LENA"),
  "DVD" = c("DARA", "BORT")
)

load_acronym_map <- function() {
  m <- BUILTIN_ACRONYMS
  user_path <- Sys.getenv("REGIMEN_ACRONYM_CSV", unset = "")
  if (!nzchar(user_path) || !file.exists(user_path)) return(m)
  df <- tryCatch(read.csv(user_path, stringsAsFactors = FALSE,
                          check.names = FALSE),
                 error = function(e) NULL)
  if (is.null(df) || nrow(df) == 0) return(m)
  ncols <- tolower(names(df))
  ac_i  <- which(ncols %in% c("acronym", "regimen", "shorthand",
                              "code"))[1]
  dr_i  <- which(ncols %in% c("drugs", "tokens", "med_abbrs",
                              "expansion"))[1]
  if (is.na(ac_i) || is.na(dr_i)) {
    log_msg("  REGIMEN_ACRONYM_CSV missing acronym/drugs columns; ",
            "ignored. Found: ", paste(names(df), collapse = ", "))
    return(m)
  }
  for (i in seq_len(nrow(df))) {
    ac <- toupper(trimws(as.character(df[[ac_i]])[i]))
    if (!nzchar(ac)) next
    raw <- toupper(as.character(df[[dr_i]])[i])
    drugs <- strsplit(raw, "[[:space:]/+,\\-]+", perl = TRUE)[[1]]
    drugs <- drugs[nzchar(drugs) &
                    !drugs %in% c("DEX", "DEXA", "DEXAMETHASONE",
                                   "PRED", "PREDNISONE")]
    if (length(drugs) > 0) m[[ac]] <- drugs
  }
  m
}

load_category_lookup <- function() {
  cat_path <- Sys.getenv("REGIMEN_CATEGORIES_CSV", unset = "")
  if (!nzchar(cat_path) || !file.exists(cat_path)) return(NULL)
  ext <- tolower(tools::file_ext(cat_path))
  df <- tryCatch({
    if (ext %in% c("xlsx", "xls")) {
      if (!requireNamespace("readxl", quietly = TRUE)) {
        log_msg("  readxl not installed - cannot read ", cat_path,
                "; convert to CSV or install readxl.")
        return(structure(list(), bad = TRUE, path = cat_path,
                          cols = "(xlsx, readxl unavailable)"))
      }
      as.data.frame(readxl::read_excel(cat_path), check.names = FALSE)
    } else {
      read.csv(cat_path, stringsAsFactors = FALSE, check.names = FALSE)
    }
  }, error = function(e) {
    log_msg("  category file read failed: ", conditionMessage(e)); NULL
  })
  if (is.null(df) || nrow(df) == 0)
    return(structure(list(), bad = TRUE, path = cat_path))
  ncols <- tolower(names(df))
  reg_i <- which(ncols %in% c("regimen", "lot_base_meds", "med", "meds",
                              "treatment", "regimen_name"))[1]
  cat_i <- which(ncols %in% c("category", "regimen_category",
                              "treatment_category", "class"))[1]
  if (is.na(reg_i) || is.na(cat_i))
    return(structure(list(), bad = TRUE, path = cat_path,
                     cols = paste(names(df), collapse = ", ")))

  # Tokeniser splits on whitespace / "/" / "+" / "," / "-" so xlsx
  # rows like "Bort, Lena, Dexa" or "BORT/LENA/DEXA" normalise to
  # the same sorted uppercase token vector after steroid stripping.
  # NOTE: shorthand regimen acronyms ("VRd", "KRd") are SINGLE
  # tokens after this step (VRD, KRD); the multi-drug expansion is
  # handled separately by categorise_regimen() against the acronym
  # map, not by the tokeniser. Steroids (DEX/DEXA/PRED) are stripped
  # because current LOT_BASE_MEDS excludes them (lot_program.R:688)
  # until Julia's Q2 update lands.
  STEROID_TOKENS <- c("DEX", "DEXA", "DEXAMETHASONE",
                       "PRED", "PREDNISONE")
  norm_regimen <- function(s, strip_steroids = TRUE) {
    if (is.na(s) || !nzchar(trimws(as.character(s))))
      return(character(0))
    toks <- strsplit(toupper(as.character(s)), "[[:space:]/+,\\-]+",
                     perl = TRUE)[[1]]
    toks <- toks[nzchar(toks)]
    if (strip_steroids) toks <- toks[!toks %in% STEROID_TOKENS]
    sort(unique(toks))
  }
  norm_key <- function(s, strip_steroids = TRUE)
    paste(norm_regimen(s, strip_steroids), collapse = " ")

  reg_raw <- trimws(as.character(df[[reg_i]]))
  cat_raw <- trimws(as.character(df[[cat_i]]))
  acronyms <- load_acronym_map()

  # Build lookup_norm / lookup_nosterd by iterating rows so we can
  # ALSO add expanded-drug-token keys for acronym rows. Without this,
  # a category row like "VRd -> PI+IMID" only produces a key "VRD",
  # so a LOT_BASE_MEDS of "BORT LENA" still hits (uncategorised) -
  # the acronym tier in categorise_regimen() only fires when the
  # INCOMING regimen is the acronym, which never happens for
  # LOT_BASE_MEDS (always drug-token form). Adding the expanded key
  # at lookup-build time fixes the direction.
  acronym_collapse <- function(s)
    gsub("[[:space:]/+,\\-]+", "", toupper(as.character(s)),
         perl = TRUE)

  add_pair <- function(map, key, val) {
    if (!nzchar(key) || key %in% names(map)) return(map)
    map[[key]] <- val
    map
  }
  lookup_norm    <- list()
  lookup_nosterd <- list()
  for (i in seq_along(reg_raw)) {
    reg <- reg_raw[i]; cat <- cat_raw[i]
    lookup_norm    <- add_pair(lookup_norm,    norm_key(reg, FALSE), cat)
    lookup_nosterd <- add_pair(lookup_nosterd, norm_key(reg, TRUE),  cat)
    single <- acronym_collapse(reg)
    if (nzchar(single) && single %in% names(acronyms)) {
      drugs <- acronyms[[single]]
      drugs <- drugs[!drugs %in% STEROID_TOKENS]
      k     <- paste(sort(unique(drugs)), collapse = " ")
      lookup_norm    <- add_pair(lookup_norm,    k, cat)
      lookup_nosterd <- add_pair(lookup_nosterd, k, cat)
    }
  }
  list(path           = cat_path,
       norm_regimen   = norm_regimen,
       norm_key       = norm_key,
       acronyms       = acronyms,
       lookup         = setNames(cat_raw, reg_raw),
       lookup_norm    = unlist(lookup_norm),
       lookup_nosterd = unlist(lookup_nosterd))
}

# Match LOT_BASE_MEDS or an xlsx regimen cell to a category. Tries
# (in order):
#   1. verbatim string match
#   2. normalised match (strip whitespace/slashes/+/-, uppercase, sort)
#   3. normalised + steroid-stripped match (current LOT regimens
#      are steroid-free)
#   4. acronym expansion (VRd -> BORT LENA, etc.) using
#      BUILTIN_ACRONYMS + any user CSV from REGIMEN_ACRONYM_CSV.
#      Built-in coverage is intentionally small (V/R/D combos using
#      BORT/LENA/DARA, the tokens confirmed in the pipeline spec);
#      KRd / IRd / DKd / etc. need the user CSV.
# Returns NA when no tier matches; the caller surfaces as
# "(uncategorised)".
categorise_regimen <- function(reg, cat_data) {
  if (is.na(reg) || !nzchar(trimws(as.character(reg))))
    return(NA_character_)
  if (reg %in% names(cat_data$lookup))
    return(unname(cat_data$lookup[reg]))
  k_norm <- cat_data$norm_key(reg, FALSE)
  if (nzchar(k_norm) && k_norm %in% names(cat_data$lookup_norm))
    return(unname(cat_data$lookup_norm[k_norm]))
  k_strip <- cat_data$norm_key(reg, TRUE)
  if (nzchar(k_strip) && k_strip %in% names(cat_data$lookup_nosterd))
    return(unname(cat_data$lookup_nosterd[k_strip]))

  # Acronym expansion: collapse whitespace/separators and lookup as
  # a single uppercase key. If matched, treat the expanded drugs as
  # a normalised regimen and try the lookup again.
  single <- gsub("[[:space:]/+,\\-]+", "", toupper(as.character(reg)),
                  perl = TRUE)
  if (nzchar(single) && single %in% names(cat_data$acronyms)) {
    drugs <- cat_data$acronyms[[single]]
    k <- paste(sort(unique(drugs)), collapse = " ")
    if (k %in% names(cat_data$lookup_nosterd))
      return(unname(cat_data$lookup_nosterd[k]))
    if (k %in% names(cat_data$lookup_norm))
      return(unname(cat_data$lookup_norm[k]))
  }
  NA_character_
}

build_category_pair <- function(con, lot_long, n_from, n_to, cat_data,
                                 cohort_def) {
  section <- paste0("BY_CATEGORY_", cohort_def$section_suffix)
  filt <- cohort_filter_sql(cohort_def)
  # INNER JOIN, not LEFT - Julia's Q3 says no non-progressor patients
  # in the Sankey view, so the (no LOTn) bucket is dropped at source.
  pairs <- db_q(con, glue("
    WITH a AS (
      SELECT cast(PATID as string) AS PATID, trim(LOT_BASE_MEDS) AS reg_from
      FROM {lot_long}
      WHERE LOT_NUM = {n_from}
        AND LOT_BASE_MEDS IS NOT NULL AND trim(LOT_BASE_MEDS) <> ''{filt}
    ),
    b AS (
      SELECT cast(PATID as string) AS PATID, trim(LOT_BASE_MEDS) AS reg_to
      FROM {lot_long}
      WHERE LOT_NUM = {n_to}
        AND LOT_BASE_MEDS IS NOT NULL AND trim(LOT_BASE_MEDS) <> ''{filt}
    )
    SELECT a.PATID, a.reg_from, b.reg_to
    FROM a JOIN b ON a.PATID = b.PATID
  "))
  if (nrow(pairs) == 0) return(invisible())

  uncat <- "(uncategorised)"
  pairs$cat_from <- vapply(pairs$reg_from, function(r) {
    v <- categorise_regimen(r, cat_data); if (is.na(v)) uncat else v
  }, character(1))
  pairs$cat_to <- vapply(pairs$reg_to, function(r) {
    v <- categorise_regimen(r, cat_data); if (is.na(v)) uncat else v
  }, character(1))

  links <- aggregate(PATID ~ cat_from + cat_to, data = pairs,
                     FUN = function(x) length(unique(x)))
  names(links)[3] <- "n_patients"
  links <- links[order(-links$n_patients), , drop = FALSE]

  src_lab <- paste0("L", n_from, ": ", links$cat_from)
  tgt_lab <- paste0("L", n_to, ": ", links$cat_to)
  fu_sankey(src_lab, tgt_lab, links$n_patients,
            section = section,
            title   = paste0("LOT", n_from, " -> LOT", n_to,
                             " by regimen category (",
                             cohort_def$label, ")"))

  tbl_df <- links
  names(tbl_df) <- c(paste0("LOT", n_from, "_category"),
                     paste0("LOT", n_to, "_category"),
                     "n_patients")
  save_table(tbl_df, section = section,
             title = paste0("LOT", n_from, " -> LOT", n_to,
                            " category counts (", cohort_def$label, ")"))
}

build_category_for_cohort <- function(con, lot_long, cohort_def, cat_data) {
  section <- paste0("BY_CATEGORY_", cohort_def$section_suffix)
  if (is.null(cat_data)) {
    add_html_card(paste0(
      '<div style="font-family:system-ui;padding:14px">',
      '<h3>Regimen-category sankeys (pending CSV) - ',
      esc_html(cohort_def$label), '</h3>',
      '<p style="color:#555">Per Julia Q1: pending the ',
      '<em>MM Treatment Table for Protocol.xlsx</em>. Point ',
      '<code>REGIMEN_CATEGORIES_CSV</code> at the file ',
      '(<code>.xlsx</code> is accepted via <code>readxl</code>). ',
      'Expected headers: one of <code>regimen</code> / ',
      '<code>lot_base_meds</code> / <code>med</code> / ',
      '<code>treatment</code>, plus one of <code>category</code> / ',
      '<code>regimen_category</code> / <code>treatment_category</code>.',
      '</p>',
      '<p style="color:#555">Matching tiers: verbatim &rarr; ',
      'normalised (split on whitespace / "/" / "+" / "-" / ",", ',
      'uppercase, sort) &rarr; steroid-stripped (DEX/DEXA/PRED ',
      'removed - current <code>LOT_BASE_MEDS</code> excludes ',
      'steroids until Julia\'s Q2 lands) &rarr; <b>acronym ',
      'expansion</b>. When the xlsx side has an acronym row ',
      '(e.g. <code>VRd</code>), the lookup also gets the ',
      'expanded-drug-token key (<code>BORT LENA</code>), so a ',
      'LOT regimen of <code>BORT LENA</code> matches that ',
      'category. Built-in acronyms cover V/R/D combos using ',
      'BORT / LENA / DARA only (the tokens confirmed in the ',
      'pipeline spec); add a CSV at ',
      '<code>REGIMEN_ACRONYM_CSV</code> with columns ',
      '<code>acronym, drugs</code> to extend (e.g. ',
      '<code>KRd, CARF LENA</code>). Acronym xlsx rows whose ',
      'acronym is not in the map will still fall to ',
      '<code>(uncategorised)</code>.</p></div>'),
      section = section,
      title = paste0("Categories (", cohort_def$label, ", pending)"))
    return(invisible())
  }
  if (isTRUE(attr(cat_data, "bad"))) {
    add_html_card(paste0(
      '<div style="font-family:system-ui;padding:14px">',
      '<h3>Regimen-category CSV could not be parsed</h3>',
      '<p style="color:#555">Cohort: ', esc_html(cohort_def$label),
      '. Check the CSV at <code>',
      esc_html(attr(cat_data, "path") %||% ""),
      '</code> has a recognised <code>regimen</code> / ',
      '<code>category</code> column pair.</p></div>'),
      section = section,
      title = paste0("Categories (", cohort_def$label, ", bad CSV)"))
    return(invisible())
  }
  for (n in 1:4) build_category_pair(con, lot_long, n, n + 1L,
                                      cat_data, cohort_def)
}

# ---- Q3 helper: focused LOTn->LOTn+1 sankeys per cohort -------------
# Julia Q3 applies here too: the sankey must NOT showcase patients
# with no subsequent LOT, so we INNER-JOIN LOTn and LOTn+1 and drop
# the (no LOTn) bucket entirely.
build_focused_pair <- function(con, lot_long, n_from, n_to, cohort_def) {
  section <- paste0("LOT", n_from, "_TO_LOT", n_to, "_",
                    cohort_def$section_suffix)
  filt <- cohort_filter_sql(cohort_def)
  pairs <- db_q(con, glue("
    WITH a AS (
      SELECT cast(PATID as string) AS PATID, trim(LOT_BASE_MEDS) AS reg_from
      FROM {lot_long}
      WHERE LOT_NUM = {n_from}
        AND LOT_BASE_MEDS IS NOT NULL AND trim(LOT_BASE_MEDS) <> ''{filt}
    ),
    b AS (
      SELECT cast(PATID as string) AS PATID, trim(LOT_BASE_MEDS) AS reg_to
      FROM {lot_long}
      WHERE LOT_NUM = {n_to}
        AND LOT_BASE_MEDS IS NOT NULL AND trim(LOT_BASE_MEDS) <> ''{filt}
    )
    SELECT a.PATID, a.reg_from, b.reg_to
    FROM a JOIN b ON a.PATID = b.PATID
  "))
  if (nrow(pairs) == 0) return(invisible())

  src_counts <- aggregate(PATID ~ reg_from, data = pairs,
                          FUN = function(x) length(unique(x)))
  names(src_counts)[2] <- "n_patients"
  src_counts <- src_counts[order(-src_counts$n_patients), , drop = FALSE]
  top_from <- head(src_counts$reg_from, TOP_N)

  sub <- pairs[pairs$reg_from %in% top_from, , drop = FALSE]
  tgt_counts <- aggregate(PATID ~ reg_to, data = sub,
                          FUN = function(x) length(unique(x)))
  names(tgt_counts)[2] <- "n_patients"
  tgt_counts <- tgt_counts[order(-tgt_counts$n_patients), , drop = FALSE]
  top_to <- head(tgt_counts$reg_to, TOP_N)
  sub$tgt_node <- ifelse(sub$reg_to %in% top_to, sub$reg_to, "Other")

  links <- aggregate(PATID ~ reg_from + tgt_node, data = sub,
                     FUN = function(x) length(unique(x)))
  names(links)[3] <- "n_patients"
  links <- links[order(-links$n_patients), , drop = FALSE]

  src_lab <- paste0("L", n_from, ": ", links$reg_from)
  tgt_lab <- paste0("L", n_to, ": ", links$tgt_node)
  fu_sankey(src_lab, tgt_lab, links$n_patients,
            section = section,
            title   = paste0("LOT", n_from, " -> LOT", n_to,
                             " focused (", cohort_def$label, ")"))

  tbl_df <- links
  names(tbl_df) <- c(paste0("LOT", n_from, "_regimen"),
                     paste0("LOT", n_to, "_regimen"),
                     "n_patients")
  save_table(tbl_df, section = section,
             title = paste0("LOT", n_from, " -> LOT", n_to,
                            " counts (", cohort_def$label, ")"))
}

# ---- Q2 steroid scoping card (no pipeline change applied) -----------
build_steroid_card <- function() {
  add_html_card(paste0(
    '<div style="font-family:system-ui;padding:14px;max-width:900px">',
    '<h3>Q2 - Steroid inclusion in LOT regimens (pipeline change pending)</h3>',
    '<p style="color:#555">Per Julia: the team wants to include steroids ',
    'in the LOT. Today’s LOT build explicitly excludes them ',
    '(<code>WHERE MAP_MED_CLASS &lt;&gt; \'STEROID\'</code> in ',
    '<code>lot_program.R:679</code> and the LOT2-5 induction-meds ',
    'step). Switching steroids on is a <b>pipeline-level change + ',
    'codelist addition + full rerun</b>; not applied here pending ',
    'Julia’s confirmed LOT-rule update.</p>',
    '<p style="color:#555;margin-bottom:6px">HCPCS codes Julia listed ',
    '(from the June 5 PDF; OCR was imperfect so confirm before ',
    'codelist load):</p>',
    '<table style="border-collapse:collapse;font-size:13px" border="1" ',
    'cellpadding="6">',
    '<tr style="background:#f0f3f5"><th>HCPCS</th><th>Drug</th></tr>',
    '<tr><td>J8540</td><td>Dexamethasone (oral)</td></tr>',
    '<tr><td>J7512</td><td>Prednisone (oral)</td></tr>',
    '<tr><td>J1100</td><td>Dexamethasone sodium phosphate (inj)</td></tr>',
    '<tr><td>J1101</td><td>Dexamethasone (inj)</td></tr>',
    '</table>',
    '<p style="color:#555;font-size:13px;margin-top:10px">',
    'Julia also flagged "quite a few NDC codes" — those need a ',
    'dedicated codelist pull. Suggested next steps once rules are ',
    'confirmed: (1) extend <code>cl_mma_codelist.csv</code> with ',
    'STEROID HCPCS + NDC rows mapping to a single ',
    '<code>STEROID</code> class and per-drug abbrevs (e.g. ',
    '<code>DEXA</code>, <code>PRED</code>); (2) remove the ',
    '<code>MAP_MED_CLASS &lt;&gt; \'STEROID\'</code> exclusion in the ',
    'induction-meds steps; (3) rerun pipeline; (4) regenerate ',
    'dashboards. Onkar to confirm whether the LOT length / ',
    'discontinuation logic also needs adjustment so steroid-only ',
    'gaps don’t fragment a line.</p></div>'),
    section = "STEROID_NOTE",
    title = "Q2 steroid inclusion (scoping)")
}

`%||%` <- function(x, y) if (is.null(x)) y else x

build_cohort_def_card <- function(con, lot_long, final_tbl, n_ash) {
  n_all <- tryCatch(
    as.numeric(db_q(con, glue("SELECT count(DISTINCT cast(PATID as string)) AS n FROM {final_tbl}"))$n),
    error = function(e) NA_real_)
  ach_pct <- if (isTRUE(n_all > 0)) round(100 * n_ash / n_all, 1) else NA_real_

  add_html_card(paste0(
    '<div style="font-family:system-ui;padding:14px;max-width:900px">',
    '<h3>Cohort definitions</h3>',
    '<table style="border-collapse:collapse;font-size:13px" border="1" ',
    'cellpadding="6">',
    '<tr style="background:#f0f3f5"><th>Cohort</th><th>n patients</th>',
    '<th>Criteria</th></tr>',
    '<tr><td>Whole delivered cohort</td><td>',
    format(n_all, big.mark = ","), '</td>',
    '<td>Final post-exclusion cohort from <code>',
    esc_html(final_tbl), '</code>.</td></tr>',
    '<tr><td>Ashley’s planned study cohort</td><td>',
    format(n_ash, big.mark = ","),
    if (!is.na(ach_pct)) paste0(' (', ach_pct, '% of whole)') else '',
    '</td><td>',
    '1L treatment start (<code>LOT_LONG.LOT_START_DT</code> at ',
    '<code>LOT_NUM=1</code>) &ge; ', esc_html(ELIGIBLE_1L_FROM),
    '; no <code>', esc_html(BELA_TOKEN), '</code> exposure anywhere ',
    '— excluded if the token appears in <code>LOT_BASE_MEDS</code> ',
    'at <b>any</b> LOT_NUM <i>or</i> in ',
    '<code>MAP_STACKED.MAP_MED_TYPE</code> (true any-exposure, ',
    'covers belantamab claims that did not surface inside a base ',
    'regimen string).',
    '</td></tr>',
    '</table>',
    if (isTRUE(.CE_ENFORCED)) paste0(
      '<p style="color:#1a7a3a;font-size:13px;margin-top:10px">',
      '<b>Enforced here</b> (member_enrollment readable, or reused ',
      'from <code>', esc_html(IE_COHORT_VIEW), '</code>):</p>',
      '<ul style="color:#1a7a3a;font-size:13px;margin-top:0">',
      '<li>CE &ge; ', CE_PRE_LOT_DAYS, ' days before 1L treatment ',
      'start (gap &le; ', CE_GAP_DAYS, ' d).</li>',
      '<li>CE &ge; ', CE_PRE_MM_DAYS, ' days before MM diagnosis ',
      'date (gap &le; ', CE_GAP_DAYS, ' d).</li></ul>')
    else paste0(
      '<p style="color:#b06000;font-size:13px;margin-top:10px">',
      '<b>CE windows NOT applied</b> - member_enrollment not readable ',
      'and no <code>', esc_html(IE_COHORT_VIEW), '</code> view found. ',
      'Run <code>lot_ie_cohort.R</code> first (it materialises that ',
      'view) or set <code>MEMBER_ENROLLMENT_TBL</code>, then rerun.</p>'),
    '<p style="color:#b06000;font-size:13px;margin-top:10px">',
    '<b>Remaining limitations (not silently dropped):</b></p>',
    '<ul style="color:#b06000;font-size:13px;margin-top:0">',
    '<li>CE &ge; <b>3 months follow-up</b> after 1L index - not ',
    'enforced; needs an enrollment-end-date check not currently ',
    'surfaced.</li>',
    '<li>Adult age &ge; 18 at MM-dx calendar year - applied upstream ',
    'in the base cohort but not re-checked here.</li>',
    '<li><b>Baseline-window mismatch</b>: the Ashley cohort starts ',
    'from the delivered <code>ELIG_COH_FINAL</code>, so the ',
    'other-malignancy / pregnancy / no-baseline-MM-therapy ',
    'exclusions were applied against the pipeline\'s baseline window ',
    '(<code>baseline_days = 183</code>, anchored to MM-dx ',
    '<code>INDEX_DATE</code>), NOT Julia\'s "12 months before 1L ',
    'treatment start" window. A patient excluded under the existing ',
    'rules might be eligible under the Ashley rules, and vice versa. ',
    'True Ashley parity requires a pipeline rerun with ',
    'baseline_days=365 anchored to LOT1 start, then re-applying the ',
    'baseline-window exclusions against that.</li>',
    '</ul>',
    '<p style="color:#555;font-size:13px">',
    'Note: <code>ELIG_COH_FINAL.INDEX_DATE</code> is the MM diagnosis ',
    'qualifying date (<code>pipeline_steps.R:356</code>), NOT the 1L ',
    'treatment start, so Julia\'s 2017-01-01 cutoff is correctly ',
    'applied against <code>LOT1.LOT_START_DT</code> ',
    '(<code>lot_program.R:686</code>) instead.',
    '</p></div>'),
    section = "COHORT_DEF",
    title = "Cohort definitions + Ashley criterion limits")
}

main <- function() {
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")
  cfg$build_dashboard <<- TRUE

  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn,
                        pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  lot_long  <- wrk("LOT_LONG")
  map_tbl   <- wrk("MAP_STACKED")
  final_tbl <- wrk(cfg$input_cohort_table)
  enr_tbl   <- cdm_src(ENR_TBL_NAME)

  ok <- function(tbl) isTRUE(tryCatch(
    nrow(db_q(con, glue("SELECT 1 FROM {tbl} LIMIT 1"))) >= 0,
    error = function(e) FALSE))
  if (!ok(lot_long))  stop("Cannot read ", lot_long, ". Run the pipeline first.")
  if (!ok(final_tbl)) stop("Cannot read ", final_tbl, " for cohort definition.")
  if (!ok(map_tbl))   log_msg("WARN: ", map_tbl,
                              " not readable; journey examples will be skipped.")

  dashboard_items <<- list()

  n_ash <- build_ashley_cohort(con, lot_long, map_tbl, final_tbl, enr_tbl,
                                 have_map = ok(map_tbl),
                                 have_enr = ok(enr_tbl))
  log_msg("Ashley cohort size: ", n_ash,
          if (isTRUE(.CE_ENFORCED)) " (full IE criteria incl. CE windows)"
          else " (CE windows NOT applied - see cohort card)")

  cohorts <- list(
    list(label = "whole cohort",         section_suffix = "ALL",
         is_ashley = FALSE),
    list(label = "Ashley planned study", section_suffix = "ASH",
         is_ashley = TRUE)
  )

  build_cohort_def_card(con, lot_long, final_tbl, n_ash)
  build_steroid_card()

  cat_data <- load_category_lookup()

  for (cd in cohorts) {
    if (ok(map_tbl)) build_journeys(con, lot_long, map_tbl, cd)
    for (n in 1:4) build_focused_pair(con, lot_long, n, n + 1L, cd)
    build_category_for_cohort(con, lot_long, cd, cat_data)
  }

  build_dashboard(
    out_name     = "julia_jun08_qs_dashboard.html",
    header_title = "MM LOT &mdash; Julia June 08 follow-up",
    header_sub   = paste0("Cohort defs &bull; Steroid scoping &bull; ",
                          "Journeys (whole / Ashley) &bull; ",
                          "Focused LOT pairs &bull; ",
                          "By category &nbsp;&mdash;&nbsp; ",
                          "pick a Category above")
  )
  log_msg("June 08 follow-up dashboard written to ",
          file.path(cfg$output_dir, "julia_jun08_qs_dashboard.html"))
}

if (!interactive()) main()
