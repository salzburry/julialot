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
#   Q3  Patient journeys filtered to multi-LOT patients only
#       (max LOT_NUM >= 2). Mirrors the LOT1-5 dashboard's MED
#       JOURNEY style.
#   Q4  Ashley's planned study cohort - best-effort filter from
#       persisted columns. Criteria enforceable now: INDEX_DATE on
#       or after 2017-01-01, no belantamab in 1L. Criteria that
#       need new pipeline derivation (flagged in the Cohort
#       Definition card, not silently dropped): >=6 months CE
#       before MM diagnosis date (current pipeline only verifies
#       the >=12 months CE before INDEX_DATE).
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

# Builds the Ashley-cohort PATID vector by applying the criteria we
# CAN enforce from persisted columns. Returns a character vector of
# PATIDs; an empty vector means no patient survives the filter (the
# caller logs and degrades gracefully).
build_ashley_cohort <- function(con, lot_long, final_tbl) {
  log_msg("Building Ashley's planned study cohort filter")
  ash <- tryCatch(db_q(con, glue("
    WITH base AS (
      SELECT cast(PATID as string) AS PATID, INDEX_DATE
      FROM {final_tbl}
      WHERE INDEX_DATE >= cast('{ELIGIBLE_1L_FROM}' as date)
    ),
    bela1l AS (
      SELECT DISTINCT cast(PATID as string) AS PATID
      FROM {lot_long}
      WHERE LOT_NUM = 1
        AND LOT_BASE_MEDS IS NOT NULL
        AND array_contains(split(LOT_BASE_MEDS, ' '), '{BELA_TOKEN}')
    )
    SELECT b.PATID, b.INDEX_DATE
    FROM base b
    LEFT JOIN bela1l x ON b.PATID = x.PATID
    WHERE x.PATID IS NULL
  ")), error = function(e) {
    log_msg("  Ashley cohort build failed: ", conditionMessage(e))
    NULL
  })
  if (is.null(ash) || nrow(ash) == 0) return(character(0))
  unique(ash$PATID)
}

cohort_filter_sql <- function(cohort_def) {
  if (is.null(cohort_def$patids)) return("")
  if (length(cohort_def$patids) == 0)
    return(" AND PATID IN ('')")
  paste0(" AND cast(PATID as string) IN (",
         paste(sprintf("'%s'", gsub("'", "''", cohort_def$patids)),
               collapse = ","),
         ")")
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
load_category_lookup <- function() {
  cat_csv <- Sys.getenv("REGIMEN_CATEGORIES_CSV", unset = "")
  if (!nzchar(cat_csv) || !file.exists(cat_csv)) return(NULL)
  df <- tryCatch(read.csv(cat_csv, stringsAsFactors = FALSE,
                          check.names = FALSE),
                 error = function(e) NULL)
  if (is.null(df) || nrow(df) == 0)
    return(structure(list(), bad = TRUE, path = cat_csv))
  ncols <- tolower(names(df))
  reg_i <- which(ncols %in% c("regimen", "lot_base_meds", "med", "meds",
                              "treatment", "regimen_name"))[1]
  cat_i <- which(ncols %in% c("category", "regimen_category",
                              "treatment_category", "class"))[1]
  if (is.na(reg_i) || is.na(cat_i))
    return(structure(list(), bad = TRUE, path = cat_csv,
                     cols = paste(names(df), collapse = ", ")))
  list(path = cat_csv,
       lookup = setNames(trimws(as.character(df[[cat_i]])),
                         trimws(as.character(df[[reg_i]]))))
}

build_category_pair <- function(con, lot_long, n_from, n_to, lookup,
                                 cohort_def) {
  section <- paste0("BY_CATEGORY_", cohort_def$section_suffix)
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
    FROM a LEFT JOIN b ON a.PATID = b.PATID
  "))
  if (nrow(pairs) == 0) return(invisible())

  uncat        <- "(uncategorised)"
  no_lot_label <- paste0("(no LOT", n_to, ")")
  pairs$cat_from <- ifelse(pairs$reg_from %in% names(lookup),
                            unname(lookup[pairs$reg_from]), uncat)
  pairs$cat_to <- ifelse(is.na(pairs$reg_to) | pairs$reg_to == "",
                          no_lot_label,
                  ifelse(pairs$reg_to %in% names(lookup),
                          unname(lookup[pairs$reg_to]), uncat))

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
      '<em>MM Treatment Table for Protocol.xlsx</em>. Save it as a ',
      'CSV with columns <code>regimen</code> + <code>category</code> ',
      '(or <code>lot_base_meds</code> / <code>regimen_category</code>), ',
      'then set <code>REGIMEN_CATEGORIES_CSV</code> and rerun. ',
      'LOT1-&gt;5 category sankeys for this cohort will then appear ',
      'here.</p></div>'),
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
                                      cat_data$lookup, cohort_def)
}

# ---- Q3 helper: focused LOTn->LOTn+1 sankeys per cohort -------------
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
    FROM a LEFT JOIN b ON a.PATID = b.PATID
  "))
  if (nrow(pairs) == 0) return(invisible())

  src_counts <- aggregate(PATID ~ reg_from, data = pairs,
                          FUN = function(x) length(unique(x)))
  names(src_counts)[2] <- "n_patients"
  src_counts <- src_counts[order(-src_counts$n_patients), , drop = FALSE]
  top_from <- head(src_counts$reg_from, TOP_N)

  sub <- pairs[pairs$reg_from %in% top_from, , drop = FALSE]
  no_lot_label <- paste0("(no LOT", n_to, ")")
  sub$reg_to_label <- ifelse(is.na(sub$reg_to) | sub$reg_to == "",
                              no_lot_label,
                              as.character(sub$reg_to))
  tgt_counts <- aggregate(PATID ~ reg_to_label, data = sub,
                          FUN = function(x) length(unique(x)))
  names(tgt_counts)[2] <- "n_patients"
  tgt_counts <- tgt_counts[order(-tgt_counts$n_patients), , drop = FALSE]
  tgt_real <- tgt_counts[tgt_counts$reg_to_label != no_lot_label,
                          , drop = FALSE]
  top_to <- head(tgt_real$reg_to_label, TOP_N)
  sub$tgt_node <- ifelse(sub$reg_to_label %in% top_to, sub$reg_to_label,
                  ifelse(sub$reg_to_label == no_lot_label, no_lot_label,
                  "Other"))

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

build_cohort_def_card <- function(con, lot_long, final_tbl, ash_ids) {
  n_all <- tryCatch(
    as.numeric(db_q(con, glue("SELECT count(DISTINCT cast(PATID as string)) AS n FROM {final_tbl}"))$n),
    error = function(e) NA_real_)
  n_ash   <- length(ash_ids)
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
    'INDEX_DATE &ge; ', esc_html(ELIGIBLE_1L_FROM), '; ',
    'no <code>', esc_html(BELA_TOKEN), '</code> token in LOT1 regimen.',
    '</td></tr>',
    '</table>',
    '<p style="color:#b06000;font-size:13px;margin-top:10px">',
    '<b>Limitation flag (not silently dropped):</b> Julia’s Ashley ',
    'criterion of <i>&ge;6 months continuous enrolment before MM ',
    'diagnosis</i> is NOT yet enforceable from persisted columns ',
    '(current pipeline verifies CE &ge; 12 months before INDEX_DATE, ',
    'and uses MM-dx in the qualifying step but does not surface ',
    'a separate "CE before MM-dx" column on the final table). If ',
    'this criterion materially shrinks the cohort, we need a new ',
    'derivation step. Same for the implicit &ge;18 at MM-dx ',
    'criterion - verified upstream but not re-checked here.',
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

  ok <- function(tbl) isTRUE(tryCatch(
    nrow(db_q(con, glue("SELECT 1 FROM {tbl} LIMIT 1"))) >= 0,
    error = function(e) FALSE))
  if (!ok(lot_long))  stop("Cannot read ", lot_long, ". Run the pipeline first.")
  if (!ok(final_tbl)) stop("Cannot read ", final_tbl, " for cohort definition.")
  if (!ok(map_tbl))   log_msg("WARN: ", map_tbl,
                              " not readable; journey examples will be skipped.")

  dashboard_items <<- list()

  ash_ids <- build_ashley_cohort(con, lot_long, final_tbl)
  log_msg("Ashley cohort size (best-effort): ", length(ash_ids))

  cohorts <- list(
    list(label = "whole cohort",         section_suffix = "ALL",
         patids = NULL),
    list(label = "Ashley planned study", section_suffix = "ASH",
         patids = ash_ids)
  )

  build_cohort_def_card(con, lot_long, final_tbl, ash_ids)
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
