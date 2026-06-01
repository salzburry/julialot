#!/usr/bin/env Rscript
# Focused MM LOT follow-up sankeys (Julia, "MM LOT FU Q's").
#
#   Rscript lot_fu_qs.R
#
# Builds a SEPARATE single self-contained HTML dashboard
# (lot_fu_qs_dashboard.html) from the persisted LOT_LONG with:
#
#   1. Focused LOT1->LOT2 sankey (Julia Q I.1). Top-N LOT1 regimens,
#      then - among only those patients - the top-N LOT2 regimens they
#      progressed to. The "(no LOT2)" bucket is shown separately and
#      does NOT consume a top-N slot. Remainder real regimens are
#      bucketed as "Other" so the total stays consistent.
#   2. Same focused pattern for LOT2->LOT3, LOT3->LOT4, LOT4->LOT5
#      (Julia Q I.2).
#   3. Regimen-category sankeys (Julia Q I.3). Wired - when
#      REGIMEN_CATEGORIES_CSV points to a regimen->category mapping it
#      is loaded and LOT1->LOT5 sankeys are rendered with regimen
#      strings collapsed to category labels. Until the MM Treatment
#      Table for Protocol xlsx is finalised the section renders a
#      clear placeholder explaining the expected CSV schema.
#   4. Approval-status sankeys (Julia Q I.4) - placeholder pending an
#      approval table (REGIMEN_APPROVALS_CSV); schema TBD with
#      clinical because approval status varies by LOT and calendar
#      year.
#   5. Sequential SCT/CART events analysis (Julia Q II) - event-based,
#      unioning all three places SCT/CART events live in LOT_LONG:
#        (a) LOT_START_TYPE - SCT/CART starting a new LOT;
#        (b) LOT_BASE_END_REASON - SCT/CART ending a LOT (event date
#            = LOT_BASE_END_DT + 1 per lot2_5_base.R's end-date rule),
#            so terminal SCTs with no next LOT are still captured;
#        (c) LOT_TX_AUTO_DT_1 / LOT_TX_AUTO_DT_2 - in-LOT AUTOs.
#      Deduped on (PATID, event_dt, event_type) and ordered by date.
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
  no_lot_label <- paste0("(no LOT", n_to, ")")
  sub$reg_to_label <- ifelse(is.na(sub$reg_to) | sub$reg_to == "",
                              no_lot_label,
                              as.character(sub$reg_to))

  # Rank only the real LOTn_to regimens for the top-N; the "(no LOTn)"
  # bucket is always shown separately so it does not consume a top-N
  # slot (otherwise non-progression can edge a real regimen off the
  # ranking and the chart no longer reads as "top 10 LOT2 regimens").
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

esc_html <- function(s) {
  s <- gsub("&", "&amp;", as.character(s), fixed = TRUE)
  s <- gsub("<", "&lt;",  s, fixed = TRUE)
  gsub(">", "&gt;", s, fixed = TRUE)
}

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
  list(
    path   = cat_csv,
    lookup = setNames(trimws(as.character(df[[cat_i]])),
                      trimws(as.character(df[[reg_i]])))
  )
}

build_category_pair <- function(con, lot_long, n_from, n_to, lookup) {
  section <- "BY_CATEGORY"
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
                             " by regimen category"))

  tbl_df <- links
  names(tbl_df) <- c(paste0("LOT", n_from, "_category"),
                     paste0("LOT", n_to, "_category"),
                     "n_patients")
  save_table(tbl_df, section = section,
             title = paste0("LOT", n_from, " -> LOT", n_to,
                            " category-transition counts"))
}

build_category_sankeys <- function(con, lot_long) {
  section <- "BY_CATEGORY"
  cat_csv <- Sys.getenv("REGIMEN_CATEGORIES_CSV", unset = "")

  if (!nzchar(cat_csv) || !file.exists(cat_csv)) {
    add_html_card(paste0(
      '<div style="font-family:system-ui;padding:14px">',
      '<h3>Regimen-category sankeys (placeholder)</h3>',
      '<p style="color:#555">Per Julia: pending the ',
      '<em>MM Treatment Table for Protocol.xlsx</em> (final version ',
      'forthcoming). Save it as a 2-column CSV with headers ',
      '<code>regimen</code> and <code>category</code> (other accepted ',
      'pairs: <code>lot_base_meds</code> / ',
      '<code>regimen_category</code>), then set ',
      '<code>REGIMEN_CATEGORIES_CSV</code> to its path and rerun. ',
      'LOT1-&gt;LOT5 category sankeys will then appear here ',
      'automatically.</p></div>'),
      section = section, title = "Regimen categories (pending xlsx)")
    return(invisible())
  }

  cat_data <- load_category_lookup()
  if (is.null(cat_data) || isTRUE(attr(cat_data, "bad"))) {
    found_cols <- if (!is.null(attr(cat_data, "cols")))
      attr(cat_data, "cols") else "(none)"
    add_html_card(paste0(
      '<div style="font-family:system-ui;padding:14px">',
      '<h3>Regimen-category CSV could not be parsed</h3>',
      '<p style="color:#555">Found <code>',
      esc_html(cat_csv), '</code> but could not locate a ',
      '<code>regimen</code>/<code>category</code> column pair. ',
      'Columns seen: <code>', esc_html(found_cols), '</code>. ',
      'Expected one header from <code>regimen</code> / ',
      '<code>lot_base_meds</code> / <code>med</code> / <code>meds</code> ',
      'and one from <code>category</code> / ',
      '<code>regimen_category</code> / <code>treatment_category</code>.',
      '</p></div>'),
      section = section, title = "Regimen categories (bad CSV)")
    return(invisible())
  }

  log_msg("Regimen categories: loaded ",
          length(cat_data$lookup), " mappings from ", cat_data$path)
  add_html_card(paste0(
    '<div style="font-family:system-ui;padding:14px">',
    '<h3>Regimen-category sankeys</h3>',
    '<p style="color:#555;font-size:13px">Mapping loaded from <code>',
    esc_html(cat_data$path), '</code> (',
    format(length(cat_data$lookup), big.mark = ","),
    ' regimen-&gt;category rows). Regimens not in the mapping appear ',
    'as <code>(uncategorised)</code>.</p></div>'),
    section = section, title = "Categories source")

  for (n in 1:4) build_category_pair(con, lot_long, n, n + 1L,
                                      cat_data$lookup)
}

build_approval_status <- function(con, lot_long) {
  section <- "BY_APPROVAL"
  appr_csv <- Sys.getenv("REGIMEN_APPROVALS_CSV", unset = "")
  if (!nzchar(appr_csv) || !file.exists(appr_csv)) {
    add_html_card(paste0(
      '<div style="font-family:system-ui;padding:14px">',
      '<h3>Approval-status sankeys (placeholder)</h3>',
      '<p style="color:#555">Julia Q I.4 - whether the drug was ',
      'FDA-approved for the LOT it appears in. Approval status varies ',
      'by line of therapy AND by calendar year (the study window is ',
      'long and approvals change over time), so this needs an external ',
      'approval table. Save it as a CSV with columns ',
      '<code>med_abbr</code>, <code>lot_num</code> (or ranges), and ',
      '<code>effective_date</code> (or <code>start_date</code> / ',
      '<code>end_date</code>), then set ',
      '<code>REGIMEN_APPROVALS_CSV</code> to its path. The full ',
      'approval schema is pending Julia / clinical input.</p></div>'),
      section = section, title = "Approval status (pending schema)")
    return(invisible())
  }
  add_html_card(paste0(
    '<div style="font-family:system-ui;padding:14px">',
    '<h3>Approval-status CSV detected</h3>',
    '<p style="color:#555">Found <code>', esc_html(appr_csv),
    '</code> but the approval-table schema has not been agreed ',
    'with clinical yet. Once the columns are confirmed this section ',
    'will tag every LOT regimen as approved / off-label / pending and ',
    'render approval-status sankeys per LOT.</p></div>'),
    section = section, title = "Approval status (schema TBD)")
}

build_sct_cart_sequence <- function(con, lot_long) {
  section <- "SCT_CART_SEQ"
  log_msg("Sequential SCT/CART events (event-based, includes in-LOT AUTOs)")

  # SCT/CART events live in THREE places in LOT_LONG; a complete event
  # union must cover all of them, otherwise sequences silently drop
  # real procedures:
  #   (a) LOT_START_TYPE - SCT/CART that STARTS a new LOT
  #       (event date = LOT_START_DT).
  #   (b) LOT_BASE_END_REASON - SCT/CART that ENDED a LOT (the LOT was
  #       cut short by the procedure). Per lot2_5_base.R:758-774 the
  #       LOT end date is the procedure date minus 1, so the true
  #       event date is LOT_BASE_END_DT + 1. Without this branch a
  #       terminal SCT (e.g. CART_INIT ending LOT5 with no LOT6) is
  #       invisible to the sequence.
  #   (c) LOT_TX_AUTO_DT_1 / LOT_TX_AUTO_DT_2 - in-LOT AUTO events
  #       inside a non-SCT line of therapy.
  # Dedup on (PATID, event_dt, event_type) handles the legitimate
  # overlap where the same procedure both ENDS LOT_N and STARTS
  # LOT_N+1 on the same date.
  union_sql <- glue("
    SELECT cast(PATID as string)                    AS PATID,
           LOT_NUM,
           cast(cast(LOT_START_DT as date) as string) AS event_dt,
           LOT_START_TYPE                           AS event_type,
           'lot_start'                              AS event_source
    FROM {lot_long}
    WHERE LOT_START_TYPE IN ('SCT_AUTO','SCT_ALLO','SCT_CART',
                              'CART','CART_INIT')
    UNION ALL
    SELECT cast(PATID as string)                    AS PATID,
           LOT_NUM,
           cast(cast(date_add(LOT_BASE_END_DT, 1) as date) as string) AS event_dt,
           LOT_BASE_END_REASON                      AS event_type,
           'lot_end'                                AS event_source
    FROM {lot_long}
    WHERE LOT_BASE_END_REASON IN ('SCT_AUTO','SCT_ALLO','SCT_CART',
                                    'CART_INIT')
      AND LOT_BASE_END_DT IS NOT NULL
    UNION ALL
    SELECT cast(PATID as string)                    AS PATID,
           LOT_NUM,
           cast(cast(LOT_TX_AUTO_DT_1 as date) as string) AS event_dt,
           'SCT_AUTO'                               AS event_type,
           'in_lot_dt1'                             AS event_source
    FROM {lot_long}
    WHERE LOT_TX_AUTO_DT_1 IS NOT NULL
    UNION ALL
    SELECT cast(PATID as string)                    AS PATID,
           LOT_NUM,
           cast(cast(LOT_TX_AUTO_DT_2 as date) as string) AS event_dt,
           'SCT_AUTO'                               AS event_type,
           'in_lot_dt2'                             AS event_source
    FROM {lot_long}
    WHERE LOT_TX_AUTO_DT_2 IS NOT NULL
  ")
  evt <- tryCatch(db_q(con, union_sql), error = function(e) {
    log_msg("  SCT/CART event union failed (",
            conditionMessage(e),
            ") - in-LOT AUTO columns may be missing; falling back to ",
            "LOT_START_TYPE + LOT_BASE_END_REASON only. Sequences may ",
            "still undercount in-LOT AUTO events.")
    db_q(con, glue("
      SELECT cast(PATID as string)                    AS PATID,
             LOT_NUM,
             cast(cast(LOT_START_DT as date) as string) AS event_dt,
             LOT_START_TYPE                           AS event_type,
             'lot_start'                              AS event_source
      FROM {lot_long}
      WHERE LOT_START_TYPE IN ('SCT_AUTO','SCT_ALLO','SCT_CART',
                                'CART','CART_INIT')
      UNION ALL
      SELECT cast(PATID as string)                    AS PATID,
             LOT_NUM,
             cast(cast(date_add(LOT_BASE_END_DT, 1) as date) as string) AS event_dt,
             LOT_BASE_END_REASON                      AS event_type,
             'lot_end'                                AS event_source
      FROM {lot_long}
      WHERE LOT_BASE_END_REASON IN ('SCT_AUTO','SCT_ALLO','SCT_CART',
                                      'CART_INIT')
        AND LOT_BASE_END_DT IS NOT NULL
    "))
  })

  if (is.null(evt) || nrow(evt) == 0) {
    add_html_card(paste0(
      '<div style="font-family:system-ui;padding:14px">',
      '<h3>Sequential SCT/CART events</h3>',
      '<p style="color:#555">No SCT/CART events found in LOT_LONG.',
      '</p></div>'),
      section = section, title = "Sequential SCT/CART (none)")
    return(invisible())
  }

  evt$LOT_NUM <- as.integer(evt$LOT_NUM)
  evt$event_dt_d <- as.Date(evt$event_dt)
  evt <- evt[!is.na(evt$event_dt_d), , drop = FALSE]
  # Same physical event can surface twice if the LOT-start IS the AUTO
  # and LOT_TX_AUTO_DT_1 captured it too. Dedup on patient + date + type.
  evt <- evt[!duplicated(evt[, c("PATID", "event_dt_d", "event_type")]), ,
             drop = FALSE]
  evt <- evt[order(evt$PATID, evt$event_dt_d, evt$LOT_NUM), , drop = FALSE]

  by_pat <- split(evt, evt$PATID)
  pat_seq <- data.frame(
    PATID    = names(by_pat),
    n_events = vapply(by_pat, nrow, integer(1)),
    sequence = vapply(by_pat,
                      function(d) paste(d$event_type, collapse = " -> "),
                      character(1)),
    timeline = vapply(by_pat,
                      function(d) paste0(d$event_type, "@L", d$LOT_NUM,
                                          collapse = " -> "),
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
    '<p style="color:#555;font-size:13px">Event-based union of ',
    'LOT-start SCT/CART types (<code>LOT_START_TYPE</code>), ',
    'LOT-ending SCT/CART procedures ',
    '(<code>LOT_BASE_END_REASON</code>, event date = ',
    '<code>LOT_BASE_END_DT + 1</code>), and in-LOT AUTO events ',
    '(<code>LOT_TX_AUTO_DT_1</code> / <code>LOT_TX_AUTO_DT_2</code>), ',
    'deduped on (PATID, event date, event type).</p>',
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
    data.frame(from  = d$event_type[-nrow(d)],
               to    = d$event_type[-1],
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
              title   = "Consecutive SCT/CART transitions (event-based)")

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
  build_category_sankeys(con, lot_long)
  build_approval_status(con, lot_long)
  build_sct_cart_sequence(con, lot_long)

  build_dashboard(
    out_name     = "lot_fu_qs_dashboard.html",
    header_title = "MM LOT &mdash; Focused Follow-up Q&apos;s",
    header_sub   = paste0("LOT1&rarr;2 &bull; LOT2&rarr;3 &bull; ",
                          "LOT3&rarr;4 &bull; LOT4&rarr;5 &bull; ",
                          "By category &bull; By approval &bull; ",
                          "SCT/CART sequence &nbsp;&mdash;&nbsp; ",
                          "pick a Category above")
  )
  log_msg("LOT FU Qs dashboard written to ",
          file.path(cfg$output_dir, "lot_fu_qs_dashboard.html"))
}

if (!interactive()) main()
