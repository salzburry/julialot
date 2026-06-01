#!/usr/bin/env Rscript
# Focused MM LOT follow-up sankeys (Julia, "MM LOT FU Q's").
#
#   Rscript lot_fu_qs.R
#
# Builds a SEPARATE single self-contained HTML dashboard
# (lot_fu_qs_dashboard.html) from the persisted LOT_LONG with:
#
#   1. Focused LOT1->LOT2 sankey (Julia Q I.1)
#      Top-N LOT1 regimens, then - among only those patients - the
#      top-N LOT2 regimens they progressed to. Remainder targets get
#      bucketed as "Other" so the total stays consistent.
#   2. Same focused pattern for LOT2->LOT3, LOT3->LOT4, LOT4->LOT5
#      (Julia Q I.2).
#   3. Regimen-category sankey placeholder (Julia Q I.3, pending the
#      MM Treatment Table for Protocol xlsx; reads
#      REGIMEN_CATEGORIES_CSV env var when ready).
#   4. Sequential SCT/CART events analysis (Julia Q II) - per-patient
#      sequence string, patient-count table, sankey of consecutive
#      type transitions.
#
# Reads only the persisted work-schema LOT_LONG; builds nothing; safe
# to run any time after the cohort+LOT pipeline has completed.

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

# Local sankey helper - mirrors lot_long_dashboard.R's make_sankey but
# accepts the dashboard section/title rather than hard-coding "SANKEY".
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

build_focused_pair <- function(con, lot_long, n_from, n_to) {
  section <- paste0("LOT", n_from, "_TO_LOT", n_to)
  log_msg("Focused pair: LOT", n_from, " -> LOT", n_to)

  pairs <- db_q(con, glue("
    WITH a AS (
      SELECT cast(PATID as string) AS PATID,
             trim(LOT_BASE_MEDS)   AS reg_from
      FROM {lot_long}
      WHERE LOT_NUM = {n_from}
        AND LOT_BASE_MEDS IS NOT NULL AND trim(LOT_BASE_MEDS) <> ''
    ),
    b AS (
      SELECT cast(PATID as string) AS PATID,
             trim(LOT_BASE_MEDS)   AS reg_to
      FROM {lot_long}
      WHERE LOT_NUM = {n_to}
        AND LOT_BASE_MEDS IS NOT NULL AND trim(LOT_BASE_MEDS) <> ''
    )
    SELECT a.PATID, a.reg_from, b.reg_to
    FROM a LEFT JOIN b ON a.PATID = b.PATID
  "))

  if (nrow(pairs) == 0) {
    add_html_card(paste0(
      '<div style="font-family:system-ui;padding:14px">',
      '<h3>LOT', n_from, ' -> LOT', n_to, '</h3>',
      '<p style="color:#555">No patients with a LOT', n_from,
      ' regimen.</p></div>'),
      section = section,
      title = paste0("LOT", n_from, " -> LOT", n_to, " (no data)"))
    return(invisible())
  }

  # Distinct-patient counts for source regimens; take top-N.
  src_counts <- aggregate(PATID ~ reg_from, data = pairs,
                          FUN = function(x) length(unique(x)))
  names(src_counts)[2] <- "n_patients"
  src_counts <- src_counts[order(-src_counts$n_patients), , drop = FALSE]
  top_from <- head(src_counts$reg_from, TOP_N)

  sub <- pairs[pairs$reg_from %in% top_from, , drop = FALSE]
  sub$reg_to_label <- ifelse(is.na(sub$reg_to) | sub$reg_to == "",
                              paste0("(no LOT", n_to, ")"),
                              as.character(sub$reg_to))

  tgt_counts <- aggregate(PATID ~ reg_to_label, data = sub,
                          FUN = function(x) length(unique(x)))
  names(tgt_counts)[2] <- "n_patients"
  tgt_counts <- tgt_counts[order(-tgt_counts$n_patients), , drop = FALSE]
  top_to <- head(tgt_counts$reg_to_label, TOP_N)

  sub$tgt_node <- ifelse(sub$reg_to_label %in% top_to,
                          sub$reg_to_label, "Other")

  links <- aggregate(PATID ~ reg_from + tgt_node, data = sub,
                     FUN = function(x) length(unique(x)))
  names(links)[3] <- "n_patients"
  links <- links[order(-links$n_patients), , drop = FALSE]

  # Prefix labels with the LOT number so the sankey reads clearly when
  # the same regimen appears as both a source and a target.
  src_lab <- paste0("L", n_from, ": ", links$reg_from)
  tgt_lab <- paste0("L", n_to, ": ", links$tgt_node)

  fu_sankey(src_lab, tgt_lab, links$n_patients,
            section = section,
            title   = paste0("LOT", n_from, " -> LOT", n_to,
                             " (focused: top ", TOP_N,
                             " sources, top ", TOP_N,
                             " targets, remainder = Other)"))

  tbl_df <- links
  names(tbl_df) <- c(paste0("LOT", n_from, "_regimen"),
                     paste0("LOT", n_to, "_regimen"),
                     "n_patients")
  save_table(tbl_df, section = section,
             title = paste0("LOT", n_from, " -> LOT", n_to,
                            " transition counts"))
}

build_category_placeholder <- function() {
  section <- "BY_CATEGORY"
  cat_csv <- Sys.getenv("REGIMEN_CATEGORIES_CSV", unset = "")
  if (nzchar(cat_csv) && file.exists(cat_csv)) {
    esc <- function(s) gsub("<", "&lt;",
                            gsub("&", "&amp;", as.character(s), fixed = TRUE),
                            fixed = TRUE)
    add_html_card(paste0(
      '<div style="font-family:system-ui;padding:14px">',
      '<h3>Regimen categories (mapping found, not yet wired)</h3>',
      '<p style="color:#555">Categories CSV at <code>',
      esc(cat_csv), '</code>. ',
      'Wire-up pending Julia confirming the exact mapping schema ',
      '(expected columns: <code>regimen</code>, <code>category</code>). ',
      'Once confirmed this section will render LOT1-&gt;5 sankeys ',
      'with regimen strings collapsed to category labels.</p></div>'),
      section = section, title = "Regimen categories (mapping pending)")
  } else {
    add_html_card(paste0(
      '<div style="font-family:system-ui;padding:14px">',
      '<h3>Regimen-category sankeys (placeholder)</h3>',
      '<p style="color:#555">Per Julia: pending the ',
      '<em>MM Treatment Table for Protocol.xlsx</em> ',
      '(final version forthcoming). Once the categorisation is ',
      'available, save it as a 2-column CSV ',
      '(<code>regimen, category</code>) and set ',
      '<code>REGIMEN_CATEGORIES_CSV</code> to its path before ',
      'rerunning this script. Sankeys grouped by category will then ',
      'appear here.</p></div>'),
      section = section, title = "Regimen categories (pending xlsx)")
  }
}

build_sct_cart_sequence <- function(con, lot_long) {
  section <- "SCT_CART_SEQ"
  log_msg("Sequential SCT/CART events")

  evt <- db_q(con, glue("
    SELECT cast(PATID as string) AS PATID,
           LOT_NUM,
           LOT_START_TYPE,
           cast(cast(LOT_START_DT as date) as string) AS LOT_START_DT
    FROM {lot_long}
    WHERE LOT_START_TYPE IN ('SCT_AUTO','SCT_ALLO','SCT_CART',
                              'CART','CART_INIT')
    ORDER BY PATID, LOT_NUM
  "))

  if (nrow(evt) == 0) {
    add_html_card(paste0(
      '<div style="font-family:system-ui;padding:14px">',
      '<h3>Sequential SCT/CART events</h3>',
      '<p style="color:#555">No LOT_LONG rows have ',
      'LOT_START_TYPE in the SCT/CART set.</p></div>'),
      section = section, title = "Sequential SCT/CART (none)")
    return(invisible())
  }

  evt$LOT_NUM <- as.integer(evt$LOT_NUM)
  evt <- evt[order(evt$PATID, evt$LOT_NUM), , drop = FALSE]

  by_pat <- split(evt, evt$PATID)
  pat_seq <- data.frame(
    PATID    = names(by_pat),
    n_events = vapply(by_pat, nrow, integer(1)),
    sequence = vapply(by_pat,
                      function(d) paste(d$LOT_START_TYPE, collapse = " -> "),
                      character(1)),
    lots     = vapply(by_pat,
                      function(d) paste0("L", d$LOT_NUM, collapse = "/"),
                      character(1)),
    stringsAsFactors = FALSE
  )

  total_pat   <- nrow(pat_seq)
  multi_pat   <- sum(pat_seq$n_events >= 2)
  triple_plus <- sum(pat_seq$n_events >= 3)

  pat_count <- aggregate(PATID ~ sequence,
                          data = pat_seq, FUN = length)
  names(pat_count)[2] <- "n_patients"
  pat_count <- pat_count[order(-pat_count$n_patients), , drop = FALSE]

  add_html_card(paste0(
    '<div style="font-family:system-ui;padding:14px">',
    '<h3>Sequential SCT/CART events summary</h3>',
    '<table style="border-collapse:collapse;font-size:13px" ',
    'border="1" cellpadding="6">',
    '<tr style="background:#f0f3f5"><th>Metric</th><th>n patients</th></tr>',
    '<tr><td>Patients with any SCT/CART event</td><td>',
    format(total_pat, big.mark = ","), '</td></tr>',
    '<tr><td>Patients with &ge;2 SCT/CART events (sequential)</td><td>',
    format(multi_pat, big.mark = ","), '</td></tr>',
    '<tr><td>Patients with &ge;3 SCT/CART events</td><td>',
    format(triple_plus, big.mark = ","), '</td></tr>',
    '</table></div>'),
    section = section, title = "Summary counts")

  save_table(pat_count, section = section,
             title = "Patient counts by SCT/CART event sequence")

  pairs <- do.call(rbind, lapply(by_pat, function(d) {
    if (nrow(d) < 2) return(NULL)
    data.frame(from  = d$LOT_START_TYPE[-nrow(d)],
               to    = d$LOT_START_TYPE[-1],
               PATID = d$PATID[-1],
               stringsAsFactors = FALSE)
  }))

  if (!is.null(pairs) && nrow(pairs) > 0) {
    link_counts <- aggregate(PATID ~ from + to, data = pairs,
                              FUN = function(x) length(unique(x)))
    names(link_counts)[3] <- "n_patients"
    link_counts <- link_counts[order(-link_counts$n_patients), , drop = FALSE]

    src_lab <- paste0("From: ", link_counts$from)
    tgt_lab <- paste0("To: ",   link_counts$to)
    fu_sankey(src_lab, tgt_lab, link_counts$n_patients,
              section = section,
              title   = "Consecutive SCT/CART transitions")

    save_table(link_counts, section = section,
               title = "Consecutive SCT/CART transition counts")
  }
}

main <- function() {
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")
  cfg$build_dashboard <<- TRUE

  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn,
                        pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  lot_long <- wrk("LOT_LONG")
  log_msg("LOT FU Qs - reading ", lot_long)

  if (!isTRUE(tryCatch(
        nrow(db_q(con, glue("SELECT 1 FROM {lot_long} LIMIT 1"))) >= 0,
        error = function(e) FALSE))) {
    stop("Cannot read ", lot_long,
         ". Build LOT_LONG (run_pipeline.R / LOT2-5 stage) first.")
  }

  dashboard_items <<- list()

  for (n in 1:4) build_focused_pair(con, lot_long, n, n + 1L)
  build_category_placeholder()
  build_sct_cart_sequence(con, lot_long)

  build_dashboard(
    out_name     = "lot_fu_qs_dashboard.html",
    header_title = "MM LOT &mdash; Focused Follow-up Q&apos;s",
    header_sub   = paste0("LOT1&rarr;2 &bull; LOT2&rarr;3 &bull; ",
                          "LOT3&rarr;4 &bull; LOT4&rarr;5 &bull; ",
                          "By category (pending) &bull; ",
                          "SCT/CART sequence &nbsp;&mdash;&nbsp; ",
                          "pick a Category above")
  )
  log_msg("LOT FU Qs dashboard written to ",
          file.path(cfg$output_dir, "lot_fu_qs_dashboard.html"))
}

if (!interactive()) main()
