#!/usr/bin/env Rscript
# ============================================================
# GSK MM LOT - Part 2: Lines of Therapy (LOT) Analysis
#
# Implements Part 2 specifications (based on provided PDFs):
#   5A. MMA_MED    - MM-approved + steroid medication claims pull
#   5B. MAP_MED    - Medication Available Period algorithm (pushout/runout)
#   6.  LOT1_BASE  - LOT1 induction regimen identification
#   7.  SCT        - Stem Cell Transplant detection (AUTO/ALLO/CART)
#
# Key references (provided by user):
#   - mma med.pdf
#   - map med.pdf        (pushout/runout logic + Figure 3 example)
#   - lot1base.pdf
#   - sct.pdf            (SCT detection: AUTO/ALLO/CART)
#   - tab 40.pdf         (CL_MMA_ROLLUP)
#   - tab 41 sample.pdf  (CL_MMA_CODELIST)
#   - optum data dict.pdf (field validation)
#   - optum business rules.pdf (join/filter logic guidance)
#
# Input:  ELIG_COH_FINAL (output of Part 1 attrition pipeline, new_code.R)
# Output: MAP_STACKED, LOT1_BASE, LOT1_SCT, LOT1_BASE_END
#
# IMPORTANT - MAP algorithm corrections vs prior versions:
#   1. Medical claims: NO pushout (per map med.pdf page 5: "Pushout is
#      not implemented"). Medical runout always = DATE_SERVICE + DAY_SUPPLY - 1.
#   2. Pharmacy claims: pushout only when new claim arrives BEFORE current
#      rx_runout. When pharmacy claim arrives AFTER rx_runout (but within
#      med_runout), pharmacy resets without pushout (per Figure 3, iter 4).
#   3. The simplified "sum pharmacy day supply" approach is incorrect when
#      pharmacy expires mid-MAP (kept alive by medical) and later resets.
#      The aggregate() state machine handles this correctly.
# ============================================================
suppressPackageStartupMessages({
  library(DBI)
  library(odbc)
  library(glue)
  library(dplyr)
})

# ============================================================
# CONFIGURATION
# ============================================================
cfg <- list(
  # Connection
  dsn = Sys.getenv("DATABRICKS_DSN", unset = "RWDE"),
  pwd = Sys.getenv("DATABRICKS_PWD", unset = ""),

  # Databricks catalog + schemas
  catalog     = Sys.getenv("DATABRICKS_CATALOG", unset = "hive_metastore"),
  cdm_schema  = Sys.getenv("OPTUM_CDM_SCHEMA", unset = "clnprw_optum"),
  ref_schema  = Sys.getenv("PROJECT_REF_SCHEMA",
                           unset = Sys.getenv("DOMINO_USER_NAME", unset = "gsk_mm_lot_ref")),
  work_schema = Sys.getenv("PROJECT_WORK_SCHEMA",
                           unset = Sys.getenv("DOMINO_USER_NAME", unset = "gsk_mm_lot_work")),

  # Clinformatics CDM base tables (validated against optum data dict.pdf)
  tbl_medical  = "medical",
  tbl_med_proc = "med_procedure",
  tbl_med_diag = "med_diagnosis",
  tbl_rx       = "rx",

  # Use cumulative quarterly tables (t_<table>_YYYYqQ) like Part 1
  use_quarterly_tables = as.logical(Sys.getenv("USE_QUARTERLY_TABLES", unset = "TRUE")),
  study_end            = Sys.getenv("STUDY_END", unset = "2025-06-30"),

  # Cohort input (Part 1 output)
  input_cohort_table = Sys.getenv("INPUT_COHORT_TABLE", unset = "ELIG_COH_FINAL"),

  # Part 2 parameters
  induction_window_days = as.integer(Sys.getenv("INDUCTION_WINDOW_DAYS", unset = "60")),
  map_discon_gap_days   = as.integer(Sys.getenv("MAP_DISCON_GAP_DAYS", unset = "90")),
  lot_discon_gap_days   = as.integer(Sys.getenv("LOT_DISCON_GAP_DAYS", unset = "90")),
  medical_day_supply    = as.integer(Sys.getenv("MEDICAL_DAY_SUPPLY", unset = "28")),

  # Per-medication-class medical day supply overrides.
  # Injectable drugs have different dosing schedules — using a flat default
  # for all medications overstates/understates MAP durations. These overrides
  # allow per-class assumptions (days) to replace the global medical_day_supply.
  # Key = MED_CLASS from mma_rollup, Value = day supply assumption.
  medical_day_supply_overrides = list(
    PROTINHIB  = 21,  # Proteasome inhibitors (e.g., bortezomib): weekly/biweekly in 21-day cycles
    IMMUNOMOD  = 28,  # IMiDs (lenalidomide, pomalidomide): 21 days on / 7 off = 28-day cycle
    MABS       = 28,  # Monoclonal antibodies (daratumumab, elotuzumab): monthly after ramp-up
    ACD38      = 28,  # Anti-CD38 (daratumumab, isatuximab): 28-day cycle maintenance
    ALKYLATOR  = 28,  # Alkylating agents (cyclophosphamide, melphalan): 28-day cycles
    MUSTAND    = 28   # Nitrogen mustards: 28-day cycles
  ),

  # Code list sourcing (priority: CSV > embedded > ref_schema table)
  codelist_dir         = Sys.getenv("CODELIST_DIR", unset = "/mnt/code/codelist"),
  use_embedded_codes   = as.logical(Sys.getenv("USE_EMBEDDED_CODES", unset = "FALSE")),
  cl_mma_rollup_tbl    = Sys.getenv("CL_MMA_ROLLUP_TBL", unset = "cl_mma_rollup"),
  cl_mma_codelist_tbl  = Sys.getenv("CL_MMA_CODELIST_TBL", unset = "cl_mma_codelist"),
  permissible_subs_tbl = Sys.getenv("PERMISSIBLE_SUBS_TBL", unset = "permissible_subs"),
  cl_sct_codelist_tbl  = Sys.getenv("CL_SCT_CODELIST_TBL", unset = "cl_sct_codelist"),

  # SCT parameters (per sct.pdf spec section 7)
  # Per sct.pdf: window is earliest_date through earliest_date + 13 (14-day span)
  # datediff(x, cur_start) <= 13 means days 0..13 inclusive = 14-day window
  sct_auto_window_days = as.integer(Sys.getenv("SCT_AUTO_WINDOW_DAYS", unset = "13")),
  sct_auto_gap_days    = as.integer(Sys.getenv("SCT_AUTO_GAP_DAYS", unset = "60")),
  sct_tandem_days      = as.integer(Sys.getenv("SCT_TANDEM_DAYS", unset = "180")),

  # Persist outputs
  persist_to_schema = as.logical(Sys.getenv("PERSIST_TO_SCHEMA", unset = "TRUE")),

  # Output directory for figures
  output_dir = Sys.getenv("OUTPUT_DIR", unset = "/mnt/results"),

  # Retry controls
  max_retries = 4,
  base_sleep  = 5
)

run_id <- Sys.getenv("DOMINO_RUN_ID", unset = format(Sys.time(), "%Y%m%d%H%M%S"))

# ============================================================
# LOGGING + HELPERS
# ============================================================
SEP   <- strrep("=", 70)
DASH  <- strrep("-", 70)

log_msg <- function(...) {
  cat(sprintf("[%s] ", format(Sys.time(), "%Y-%m-%d %H:%M:%S")), ..., "\n")
  flush.console()
}

stop_if_blank <- function(x, msg) {
  if (!nzchar(x)) stop(msg)
}

full_name <- function(schema, object) {
  paste0(cfg$catalog, ".", schema, ".", object)
}

cdm <- function(tbl) full_name(cfg$cdm_schema, tbl)
ref <- function(tbl) full_name(cfg$ref_schema, tbl)
wrk <- function(tbl) full_name(cfg$work_schema, tbl)

get_quarter_suffix <- function(end_date) {
  dt <- as.Date(end_date)
  year <- as.integer(format(dt, "%Y"))
  qtr  <- ceiling(as.integer(format(dt, "%m")) / 3)
  sprintf("%dq%d", year, qtr)
}

cdm_src <- function(base_tbl) {
  if (isTRUE(cfg$use_quarterly_tables)) {
    qsuffix <- get_quarter_suffix(cfg$study_end)
    cdm(paste0("t_", base_tbl, "_", qsuffix))
  } else {
    cdm(base_tbl)
  }
}

# Generate SQL CASE expression for per-class medical day supply
# Returns SQL like: CASE WHEN c.CL_MED_CLASS = 'PROTINHIB' THEN 21 ... ELSE 28 END
medical_day_supply_sql <- function(class_col = "c.CL_MED_CLASS") {
  overrides <- cfg$medical_day_supply_overrides
  if (is.null(overrides) || length(overrides) == 0) {
    return(as.character(cfg$medical_day_supply))
  }
  whens <- vapply(names(overrides), function(cls) {
    sprintf("WHEN %s = '%s' THEN %d", class_col, cls, as.integer(overrides[[cls]]))
  }, character(1))
  paste0("CASE ", paste(whens, collapse = " "), " ELSE ", cfg$medical_day_supply, " END")
}

with_retry <- function(fn, max_retries = cfg$max_retries, base_sleep = cfg$base_sleep) {
  # Patterns indicating permanent SQL/semantic errors that should NOT be retried
  permanent_error_patterns <- c(
    "AnalysisException", "AMBIGUOUS_REFERENCE", "AMBIGUOUS REFERENCE",
    "ParseException", "Syntax error", "TABLE_OR_VIEW_NOT_FOUND",
    "UNRESOLVED_COLUMN", "cannot resolve"
  )
  attempt <- 1
  repeat {
    out <- tryCatch(fn(), error = function(e) e)
    if (!inherits(out, "error")) return(out)
    msg <- conditionMessage(out)
    is_permanent <- any(vapply(permanent_error_patterns, function(p) grepl(p, msg, ignore.case = TRUE), logical(1)))
    if (is_permanent || attempt >= max_retries) {
      if (is_permanent && attempt < max_retries) {
        log_msg("Permanent error (not retrying): ", msg)
      }
      stop(out)
    }
    sleep_s <- base_sleep * (2^(attempt - 1))
    log_msg("Retryable failure: ", msg)
    log_msg("Retrying in ", sleep_s, "s (attempt ", attempt + 1, "/", max_retries, ")")
    Sys.sleep(sleep_s)
    attempt <- attempt + 1
  }
}

db_exec <- function(con, sql) {
  with_retry(function() DBI::dbExecute(con, sql))
}

db_q <- function(con, sql) {
  with_retry(function() DBI::dbGetQuery(con, sql))
}

# ============================================================
# CODE LIST SOURCING (CSV > embedded > ref schema tables)
# ============================================================
load_codelist_csv <- function(csv_name, col_spec) {
  csv_path <- file.path(cfg$codelist_dir, csv_name)
  if (!file.exists(csv_path)) return(NULL)
  tryCatch({
    df <- read.csv(csv_path, stringsAsFactors = FALSE, na.strings = c("", "NA", "NaN"))
    missing <- setdiff(col_spec, names(df))
    if (length(missing) > 0) {
      stop(glue("CSV {csv_name} missing columns: {paste(missing, collapse=', ')}"))
    }
    df <- df[, col_spec, drop = FALSE]
    if (nrow(df) == 0) {
      log_msg("WARNING: CSV ", csv_path, " has no data rows, skipping")
      return(NULL)
    }
    esc <- function(x) {
      if (is.na(x) || is.null(x) || x == "") return("NULL")
      x <- gsub("'", "''", as.character(x))
      paste0("'", x, "'")
    }
    rows <- apply(df, 1, function(r) paste0("(", paste(vapply(r, esc, character(1)), collapse = ", "), ")"))
    sql <- paste0("SELECT * FROM (VALUES\n  ", paste(rows, collapse = ",\n  "), "\n) AS t(",
                  paste(col_spec, collapse = ", "), ")")
    log_msg("Loaded codelist from CSV: ", csv_path, " (", nrow(df), " rows)")
    sql
  }, error = function(e) {
    log_msg("WARNING: Failed to load CSV ", csv_path, ": ", e$message)
    NULL
  })
}

get_code_source <- function(embedded_fn, external_tbl, csv_name = NULL, col_spec = NULL) {
  if (!is.null(csv_name) && !is.null(col_spec) && dir.exists(cfg$codelist_dir)) {
    csv_sql <- load_codelist_csv(csv_name, col_spec)
    if (!is.null(csv_sql)) return(paste0("(", csv_sql, ") src"))
  }
  if (isTRUE(cfg$use_embedded_codes)) return(paste0("(", embedded_fn(), ") src"))
  ref(external_tbl)
}

# ------------------------------------------------------------
# Embedded Tab 40 (rollup) - minimal fallback only
# ------------------------------------------------------------
embedded_mma_rollup <- function() {
  "
  SELECT * FROM (VALUES
    ('bortezomib',      'PROTINHIB', 'BORT', 0, NULL, 0, 0),
    ('carfilzomib',     'PROTINHIB', 'CARF', 0, NULL, 0, 0),
    ('ixazomib',        'PROTINHIB', 'IXAZ', 1, NULL, 0, 0),
    ('lenalidomide',    'IMMUNOMOD', 'LENA', 1, 'BORT', 0, 0),
    ('pomalidomide',    'IMMUNOMOD', 'POMA', 1, NULL, 0, 0),
    ('daratumumab',     'ACD38',     'DARA', 0, NULL, 0, 0),
    ('dexamethasone',   'STEROID',   'DEXA', 0, NULL, 0, 0),
    ('prednisone',      'STEROID',   'PRED', 0, NULL, 0, 0)
  ) AS t(
    CL_MEDICATION_FULL,
    CL_MED_CLASS,
    CL_MED_ABBR,
    MONOMAINTENANCE,
    DUALMAINTENANCEWITH,
    CONDITIONING,
    USED_FOR_OTHER_CANCERS
  )
  "
}

# ------------------------------------------------------------
# Embedded Tab 41 (code list) - minimal fallback only
# ------------------------------------------------------------
embedded_mma_codelist <- function() {
  "
  SELECT * FROM (VALUES
    ('HCPCS', 'J9041',       'bortezomib',   'PROTINHIB', 'BORT'),
    ('HCPCS', 'J9047',       'carfilzomib',  'PROTINHIB', 'CARF'),
    ('NDC',   '00409170001', 'bortezomib',   'PROTINHIB', 'BORT'),
    ('NDC',   '76075010101', 'carfilzomib',  'PROTINHIB', 'CARF'),
    ('NDC',   '59572050121', 'lenalidomide', 'IMMUNOMOD', 'LENA'),
    ('NDC',   '00054413025', 'prednisone',  'STEROID',   'PRED')
  ) AS t(
    CL_CODE_TYPE,
    CL_CODE,
    CL_MEDICATION_FULL,
    CL_MED_CLASS,
    CL_MED_ABBR
  )
  "
}

# ------------------------------------------------------------
# Permissible substitutions
# ------------------------------------------------------------
embedded_permissible_subs <- function() {
  "
  SELECT * FROM (VALUES
    ('DARA', 'DARA'),
    ('BORT', 'IXAZ'),
    ('IXAZ', 'BORT')
  ) AS t(original_med, substitute_med)
  "
}

# ------------------------------------------------------------
# Embedded SCT codelist (Tab 47 - SCT procedure codes)
# AUTO = autologous, ALLO = allogeneic, CART = CAR-T
# Note: CPT 38241 = autologous (AUTO), CPT 38240 = allogeneic (ALLO)
# per AMA CPT definitions. This is correct despite appearing reversed.
# ------------------------------------------------------------
embedded_sct_codelist <- function() {
  "
  SELECT * FROM (VALUES
    ('HCPCS', '38241',  'AUTO'),
    ('HCPCS', '38240',  'ALLO'),
    ('HCPCS', 'S2150',  'ALLO'),
    ('HCPCS', 'Q2042',  'CART'),
    ('HCPCS', 'Q2054',  'CART'),
    ('HCPCS', 'Q2055',  'CART'),
    ('HCPCS', 'Q2056',  'CART')
  ) AS t(
    CL_CODE_TYPE,
    CL_CODE,
    SCT_TYPE
  )
  "
}

# ============================================================
# PIPELINE STEP RUNNER
# ============================================================
run_step <- function(con, name, sql, qc = NULL) {
  log_msg(SEP)
  log_msg("STEP ", name)
  log_msg(SEP)
  t0 <- proc.time()
  db_exec(con, sql)
  elapsed <- (proc.time() - t0)[["elapsed"]]
  log_msg("  Completed in ", round(elapsed, 1), "s")
  if (!is.null(qc) && nzchar(qc)) {
    out <- db_q(con, qc)
    print(out)
  }
  invisible(TRUE)
}

# ============================================================
# DESCRIPTIVES + FIGURES
# ============================================================
# Generates summary tables + ggplot2 figures for QC and reporting.
# Figures saved to cfg$output_dir as PNG.
# A single combined interactive HTML dashboard is generated at the end.

has_ggplot2 <- requireNamespace("ggplot2", quietly = TRUE)
has_plotly  <- requireNamespace("plotly", quietly = TRUE) &&
               requireNamespace("htmlwidgets", quietly = TRUE)
has_dt      <- requireNamespace("DT", quietly = TRUE)
has_jsonlite  <- requireNamespace("jsonlite", quietly = TRUE)
has_base64enc <- requireNamespace("base64enc", quietly = TRUE)
if (has_ggplot2) {
  suppressPackageStartupMessages(library(ggplot2))
}

# ---- Dashboard collector: accumulates widgets for the combined HTML ----
dashboard_items <- list()

add_to_dashboard <- function(widget, section, title, type = "figure") {
  dashboard_items[[length(dashboard_items) + 1]] <<- list(
    widget = widget, section = section, title = title, type = type
  )
}

# ---- Shared visual theme and palette ----
lot_palette <- c(
  "#2E86AB", "#A23B72", "#F18F01", "#C73E1D", "#3B1F2B",
  "#44BBA4", "#E94F37", "#393E41", "#8D5A97", "#5FAD56",
  "#F2D0A4", "#3F88C5", "#D72638", "#140F2D", "#F49D37"
)
lot_class_palette <- c(
  "IMMUNOMOD"  = "#2E86AB",
  "PROTINHIB"  = "#A23B72",
  "MUSTARD"    = "#F18F01",
  "ACD38"      = "#C73E1D",
  "STEROID"    = "#44BBA4",
  "ABCMA"      = "#8D5A97",
  "ASLAMF7"    = "#3F88C5",
  "MELP"       = "#3B1F2B",
  "TOPOINHIB"  = "#E94F37",
  "HIST"       = "#5FAD56",
  "NUCLEAR"    = "#F49D37",
  "BLC21"      = "#D72638",
  "ATCELL"     = "#F2D0A4",
  "UNV"        = "#140F2D",
  "PLAT"       = "#393E41"
)

theme_lot <- function(base_size = 13) {
  theme_minimal(base_size = base_size) %+replace%
    theme(
      plot.title       = element_text(face = "bold", size = base_size + 2, margin = margin(b = 10)),
      plot.subtitle    = element_text(color = "grey40", size = base_size, margin = margin(b = 12)),
      plot.caption     = element_text(color = "grey50", size = base_size - 3, hjust = 0),
      panel.grid.major = element_line(color = "grey90", linewidth = 0.3),
      panel.grid.minor = element_blank(),
      axis.title       = element_text(face = "bold", size = base_size - 1),
      axis.text        = element_text(size = base_size - 2),
      legend.position  = "top",
      legend.title     = element_text(face = "bold", size = base_size - 1),
      legend.text      = element_text(size = base_size - 2),
      plot.margin      = margin(15, 15, 15, 15)
    )
}

save_plot <- function(p, filename, width = 10, height = 6, section = "", title = "") {
  if (!has_ggplot2) return(invisible(NULL))
  dir.create(cfg$output_dir, showWarnings = FALSE, recursive = TRUE)
  out_path <- file.path(cfg$output_dir, filename)
  tryCatch({
    ggsave(out_path, plot = p, width = width, height = height, dpi = 150, bg = "white")
    log_msg("  Figure saved: ", out_path)
  }, error = function(e) {
    log_msg("  WARNING: Could not save figure ", filename, ": ", e$message)
  })
  # Collect interactive version for dashboard
  if (has_plotly) {
    tryCatch({
      pp <- plotly::ggplotly(p, tooltip = "text") |>
        plotly::layout(
          hoverlabel = list(bgcolor = "white", font = list(size = 12)),
          margin = list(t = 60, b = 60)
        ) |>
        plotly::config(displayModeBar = TRUE, displaylogo = FALSE,
                       modeBarButtonsToRemove = list("lasso2d", "select2d"))
      add_to_dashboard(pp, section, title, type = "figure")
    }, error = function(e) {
      log_msg("  WARNING: Could not create interactive figure for dashboard: ", e$message)
    })
  }
}

# Collect a data table for the dashboard (DT does NOT require plotly)
save_table <- function(df, section, title) {
  if (!has_dt || !requireNamespace("htmlwidgets", quietly = TRUE)) return(invisible(NULL))
  tryCatch({
    # Convert integer64 columns for display
    for (col in names(df)) {
      if (inherits(df[[col]], "integer64")) df[[col]] <- as.numeric(df[[col]])
    }
    dt <- DT::datatable(df, rownames = FALSE,
                         options = list(pageLength = 15, scrollX = TRUE,
                                        dom = "ftip"),
                         class = "display compact stripe hover")
    add_to_dashboard(dt, section, title, type = "table")
  }, error = function(e) {
    log_msg("  WARNING: Could not create table for dashboard: ", e$message)
  })
}

# Add a raw HTML card to the dashboard (for overview/QC — no htmlwidget needed)
add_html_card <- function(html_content, section, title) {
  dashboard_items[[length(dashboard_items) + 1]] <<- list(
    html = html_content, section = section, title = title, type = "html_card"
  )
}

# Build and save the single combined HTML dashboard
build_dashboard <- function() {
  if (length(dashboard_items) == 0) {
    log_msg("  Skipping dashboard (no items collected).")
    return(invisible(NULL))
  }
  if (!has_jsonlite || !has_base64enc) {
    log_msg("  Skipping dashboard (jsonlite or base64enc not available).")
    return(invisible(NULL))
  }

  dir.create(cfg$output_dir, showWarnings = FALSE, recursive = TRUE)
  dash_path <- file.path(cfg$output_dir, "lot_dashboard.html")

  tryCatch({
    tab_buttons   <- list()
    tab_panels    <- list()
    plotly_specs  <- list()   # JSON specs for plotly figures
    sections      <- unique(sapply(dashboard_items, `[[`, "section"))

    for (idx in seq_along(dashboard_items)) {
      item   <- dashboard_items[[idx]]
      tab_id <- paste0("tab", idx)

      active_class <- if (idx == 1) "active" else ""
      section_tag  <- paste0('<span class="section-tag">', item$section, '</span> ')
      tab_buttons[[idx]] <- sprintf(
        '<button class="tab-btn %s" onclick="showTab(\'%s\', this)" data-section="%s">%s%s</button>',
        active_class, tab_id, item$section, section_tag, item$title
      )

      if (item$type == "figure") {
        # Plotly figures: extract JSON spec, render client-side with shared plotly.js
        # This avoids pandoc dependency, data URI size limits, and saves ~3MB per figure
        plotly_json <- tryCatch({
          jsonlite::toJSON(item$widget$x, auto_unbox = TRUE, force = TRUE, null = "null")
        }, error = function(e) NULL)

        if (!is.null(plotly_json)) {
          div_id <- paste0("plotly_", idx)
          plotly_specs[[div_id]] <- as.character(plotly_json)
          tab_panels[[idx]] <- sprintf(
            '<div id="%s" class="tab-content" style="display:%s"><div id="%s" style="width:100%%;min-height:500px;"></div></div>',
            tab_id, if (idx == 1) "block" else "none", div_id
          )
        } else {
          # Fallback: empty panel with error message
          tab_panels[[idx]] <- sprintf(
            '<div id="%s" class="tab-content" style="display:%s"><p style="color:#C73E1D;padding:20px;">Figure could not be rendered.</p></div>',
            tab_id, if (idx == 1) "block" else "none"
          )
        }
      } else {
        # Tables and HTML cards: base64 data URI iframes (these work fine)
        if (item$type == "html_card") {
          widget_html <- item$html
        } else {
          tmp_file <- tempfile(fileext = ".html")
          htmlwidgets::saveWidget(item$widget, tmp_file, selfcontained = TRUE)
          widget_html <- paste(readLines(tmp_file, warn = FALSE), collapse = "\n")
          unlink(tmp_file)
        }
        encoded <- base64enc::base64encode(charToRaw(widget_html))
        iframe_height <- if (item$type == "table") "600" else "500"
        tab_panels[[idx]] <- sprintf(
          '<div id="%s" class="tab-content" style="display:%s"><iframe src="data:text/html;base64,%s" style="width:100%%;height:%spx;border:none;" sandbox="allow-scripts allow-same-origin" onload="resizeIframe(this)"></iframe></div>',
          tab_id, if (idx == 1) "block" else "none", encoded, iframe_height
        )
      }
    }

    # Build section filter buttons
    section_filters <- paste0(
      '<button class="filter-btn active" onclick="filterSection(\'ALL\', this)">All</button>\n',
      paste(sprintf(
        '<button class="filter-btn" onclick="filterSection(\'%s\', this)">%s</button>',
        sections, sections
      ), collapse = "\n")
    )

    # Build plotly specs as a single JSON object keyed by div id
    plotly_specs_json <- paste0("var PLOTLY_SPECS = {\n",
      paste(sapply(names(plotly_specs), function(div_id) {
        sprintf('  "%s": %s', div_id, plotly_specs[[div_id]])
      }), collapse = ",\n"),
    "\n};")

    # Bundle plotly.js from the installed R package (no CDN / no internet needed)
    plotly_js_code <- ""
    if (length(plotly_specs) > 0) {
      plotly_js_files <- list.files(
        system.file("htmlwidgets/lib", package = "plotly"),
        pattern = "plotly[^/]*\\.min\\.js$",
        recursive = TRUE, full.names = TRUE
      )
      if (length(plotly_js_files) == 0) {
        # Fallback: try non-minified
        plotly_js_files <- list.files(
          system.file("htmlwidgets/lib", package = "plotly"),
          pattern = "plotly[^/]*\\.js$",
          recursive = TRUE, full.names = TRUE
        )
      }
      if (length(plotly_js_files) > 0) {
        plotly_js_code <- paste(readLines(plotly_js_files[1], warn = FALSE), collapse = "\n")
        log_msg("  Bundled plotly.js from: ", plotly_js_files[1],
                " (", round(file.size(plotly_js_files[1]) / 1e6, 1), " MB)")
      } else {
        log_msg("  WARNING: Could not find plotly.js in installed package. Figures may not render.")
      }
    }
    plotly_script_tag <- if (nchar(plotly_js_code) > 0) {
      paste0("<script>", plotly_js_code, "</script>")
    } else ""

    html_doc <- paste0('<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>LOT Part 2 - Interactive Dashboard</title>
', plotly_script_tag, '
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    background: #f5f6fa; color: #2d3436;
  }
  .header {
    background: linear-gradient(135deg, #2E86AB 0%, #1a5276 100%);
    color: white; padding: 28px 32px;
    box-shadow: 0 2px 8px rgba(0,0,0,0.15);
  }
  .header h1 { font-size: 26px; font-weight: 700; margin-bottom: 6px; }
  .header p  { font-size: 14px; opacity: 0.85; }
  .nav-bar {
    position: sticky; top: 0; z-index: 100;
    background: white; box-shadow: 0 1px 3px rgba(0,0,0,0.06);
  }
  .filter-bar {
    display: flex; flex-wrap: wrap; gap: 4px; padding: 10px 32px;
    border-bottom: 1px solid #eee; background: #fafafa;
  }
  .filter-btn {
    padding: 5px 14px; border: 1px solid #dfe6e9; border-radius: 20px;
    background: white; color: #636e72; cursor: pointer;
    font-size: 12px; font-weight: 600; text-transform: uppercase;
    letter-spacing: 0.5px; transition: all 0.15s;
  }
  .filter-btn:hover { background: #dfe6e9; }
  .filter-btn.active { background: #1a5276; color: white; border-color: #1a5276; }
  .tab-bar {
    display: flex; flex-wrap: wrap; gap: 6px;
    padding: 10px 32px;
    border-bottom: 1px solid #dfe6e9;
  }
  .tab-btn {
    padding: 8px 14px; border: 1px solid #dfe6e9; border-radius: 6px;
    background: #f5f6fa; color: #636e72; cursor: pointer;
    font-size: 12.5px; font-weight: 500; transition: all 0.15s;
    display: inline-flex; align-items: center; gap: 4px;
  }
  .tab-btn:hover { background: #dfe6e9; color: #2d3436; }
  .tab-btn.active { background: #2E86AB; color: white; border-color: #2E86AB; }
  .tab-btn.active .section-tag { background: rgba(255,255,255,0.25); color: white; }
  .tab-btn.hidden { display: none; }
  .section-tag {
    font-size: 10px; font-weight: 700; text-transform: uppercase;
    background: #dfe6e9; color: #636e72; padding: 2px 6px;
    border-radius: 3px; letter-spacing: 0.5px;
  }
  .tab-content { padding: 16px 32px; }
  .tab-content iframe { border: none; width: 100%; min-height: 500px; }
</style>
</head>
<body>
<div class="header">
  <h1>LOT Part 2 &mdash; Interactive Dashboard</h1>
  <p>MMA_MED &bull; MAP &bull; LOT1_BASE &bull; SCT &bull; Patient Journey &nbsp;|&nbsp; Generated ', format(Sys.time(), "%Y-%m-%d %H:%M"), '</p>
</div>
<div class="nav-bar">
<div class="filter-bar">
', section_filters, '
</div>
<div class="tab-bar">
', paste(tab_buttons, collapse = "\n"), '
</div>
</div>
', paste(tab_panels, collapse = "\n"), '
<script>
function resizeIframe(iframe) {
  try { iframe.style.height = iframe.contentWindow.document.body.scrollHeight + 40 + "px"; } catch(e) {}
  setTimeout(function() {
    try { iframe.style.height = iframe.contentWindow.document.body.scrollHeight + 40 + "px"; } catch(e) {}
  }, 800);
  setTimeout(function() {
    try { iframe.style.height = iframe.contentWindow.document.body.scrollHeight + 40 + "px"; } catch(e) {}
  }, 2000);
}
// Track which plotly divs have been rendered
var renderedPlots = {};
function renderPlotlyIfVisible(divId) {
  if (renderedPlots[divId]) {
    Plotly.Plots.resize(divId);
    return;
  }
  var el = document.getElementById(divId);
  if (!el || el.offsetParent === null) return;
  var spec = PLOTLY_SPECS[divId];
  if (spec) {
    Plotly.newPlot(divId, spec.data || [], spec.layout || {}, spec.config || {displayModeBar:true,displaylogo:false});
    renderedPlots[divId] = true;
  }
}
function showTab(tabId, btn) {
  document.querySelectorAll(".tab-content").forEach(function(el) { el.style.display = "none"; });
  document.querySelectorAll(".tab-btn").forEach(function(el) { el.classList.remove("active"); });
  document.getElementById(tabId).style.display = "block";
  btn.classList.add("active");
  // Render/resize plotly if this tab has one
  var plotDiv = document.querySelector("#" + tabId + " [id^=plotly_]");
  if (plotDiv) {
    setTimeout(function() { renderPlotlyIfVisible(plotDiv.id); }, 100);
  }
  // Resize iframes
  var iframe = document.querySelector("#" + tabId + " iframe");
  if (iframe) { setTimeout(function() { resizeIframe(iframe); }, 300); }
}
function filterSection(section, btn) {
  document.querySelectorAll(".filter-btn").forEach(function(el) { el.classList.remove("active"); });
  btn.classList.add("active");
  document.querySelectorAll(".tab-btn").forEach(function(el) {
    if (section === "ALL" || el.getAttribute("data-section") === section) {
      el.classList.remove("hidden");
    } else {
      el.classList.add("hidden");
    }
  });
  var activeTab = document.querySelector(".tab-btn.active");
  if (activeTab && activeTab.classList.contains("hidden")) {
    var firstVisible = document.querySelector(".tab-btn:not(.hidden)");
    if (firstVisible) firstVisible.click();
  }
}
// Plotly figure specs — all figures share one copy of plotly.js
', plotly_specs_json, '
// Render the first visible plotly chart on load
document.addEventListener("DOMContentLoaded", function() {
  var firstPlot = document.querySelector(".tab-content[style*=block] [id^=plotly_]");
  if (firstPlot) { setTimeout(function() { renderPlotlyIfVisible(firstPlot.id); }, 200); }
});
</script>
</body>
</html>')

    writeLines(html_doc, dash_path)
    log_msg("  Dashboard saved: ", dash_path)

  }, error = function(e) {
    log_msg("  WARNING: Could not build dashboard: ", conditionMessage(e))
  })
}

print_descriptives <- function(con) {
  cat("\n")
  cat(SEP, "\n")
  cat("        PART 2 DESCRIPTIVE SUMMARY                    \n")
  cat(SEP, "\n")

  # --------------------------------------------------------
  # 0a. Overview tab — run metadata + dynamic counts (FIRST tab)
  # --------------------------------------------------------
  tryCatch({
    # Dynamic run counts
    cohort_n   <- tryCatch(as.numeric(db_q(con, "SELECT count(DISTINCT PATID) AS n FROM lot_patient_input")$n), error = function(e) NA)
    mma_n      <- tryCatch(as.numeric(db_q(con, "SELECT count(*) AS n FROM mma_med_processed")$n), error = function(e) NA)
    mma_pat_n  <- tryCatch(as.numeric(db_q(con, "SELECT count(DISTINCT PATID) AS n FROM mma_med_processed")$n), error = function(e) NA)
    map_n      <- tryCatch(as.numeric(db_q(con, "SELECT count(*) AS n FROM map_stacked")$n), error = function(e) NA)
    map_pat_n  <- tryCatch(as.numeric(db_q(con, "SELECT count(DISTINCT PATID) AS n FROM map_stacked")$n), error = function(e) NA)
    lot1_n     <- tryCatch(as.numeric(db_q(con, "SELECT count(*) AS n FROM lot1_base")$n), error = function(e) NA)
    sct_n      <- tryCatch(as.numeric(db_q(con, "SELECT sum(CASE WHEN LOT1_TX_ENDDATE IS NOT NULL THEN 1 ELSE 0 END) AS n FROM lot1_sct")$n), error = function(e) NA)
    censored_n <- tryCatch({
      r <- db_q(con, "
        SELECT sum(case when ENDDATE_CE < ENDDATE then 1 else 0 end) AS n_cens,
               count(*) AS n_total
        FROM lot_patient_input
      ")
      list(n = as.numeric(r$n_cens), pct = round(100 * as.numeric(r$n_cens) / max(as.numeric(r$n_total), 1), 1))
    }, error = function(e) list(n = NA, pct = NA))

    fmt <- function(x) if (is.na(x)) "N/A" else format(x, big.mark = ",")

    overview_html <- paste0('<!DOCTYPE html><html><head>
<meta charset="UTF-8">
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
         background: #fff; padding: 24px; color: #2d3436; }
  h2 { font-size: 20px; color: #1a5276; margin-bottom: 16px; }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 14px; margin-bottom: 24px; }
  .card { background: #f5f6fa; border-radius: 8px; padding: 16px; border: 1px solid #dfe6e9; }
  .card h3 { font-size: 11px; color: #636e72; text-transform: uppercase;
             letter-spacing: 0.5px; margin-bottom: 6px; }
  .card .val { font-size: 24px; font-weight: 700; color: #2d3436; }
  .card .sub { font-size: 12px; color: #636e72; margin-top: 4px; }
  table { border-collapse: collapse; width: 100%; margin-top: 12px; }
  th, td { text-align: left; padding: 8px 12px; border-bottom: 1px solid #eee; font-size: 13px; }
  th { background: #f5f6fa; font-weight: 600; color: #636e72; text-transform: uppercase;
       letter-spacing: 0.5px; font-size: 11px; }
</style></head><body>
<h2>Run Overview</h2>
<div class="grid">
  <div class="card"><h3>Run ID</h3><div class="val" style="font-size:16px;word-break:break-all;">', run_id, '</div>
    <div class="sub">Generated: ', format(Sys.time(), "%Y-%m-%d %H:%M:%S"), '</div></div>
  <div class="card"><h3>Cohort Patients</h3><div class="val">', fmt(cohort_n), '</div></div>
  <div class="card"><h3>MMA Claims</h3><div class="val">', fmt(mma_n), '</div>
    <div class="sub">', fmt(mma_pat_n), ' patients</div></div>
  <div class="card"><h3>MAPs</h3><div class="val">', fmt(map_n), '</div>
    <div class="sub">', fmt(map_pat_n), ' patients</div></div>
  <div class="card"><h3>LOT1 Patients</h3><div class="val">', fmt(lot1_n), '</div></div>
  <div class="card"><h3>LOT-Ending SCT</h3><div class="val">', fmt(sct_n), '</div>
    <div class="sub">Patients with SCT ending LOT1</div></div>
  <div class="card"><h3>Censored (OBS_END)</h3><div class="val">',
    if (!is.na(censored_n$pct)) paste0(censored_n$pct, "%") else "N/A", '</div>
    <div class="sub">', fmt(censored_n$n), ' patients</div></div>
</div>
<h2>Configuration</h2>
<table>
<tr><th>Parameter</th><th>Value</th></tr>
<tr><td>CDM Schema</td><td>', cfg$cdm_schema, '</td></tr>
<tr><td>Work Schema</td><td>', cfg$work_schema, '</td></tr>
<tr><td>Input Cohort Table</td><td>', cfg$input_cohort_table, '</td></tr>
<tr><td>Induction Window</td><td>', cfg$induction_window_days, ' days</td></tr>
<tr><td>MAP Discontinuation Gap</td><td>', cfg$map_discon_gap_days, ' days</td></tr>
<tr><td>Medical Day Supply</td><td>', cfg$medical_day_supply, ' days</td></tr>
<tr><td>LOT Discontinuation Gap</td><td>', cfg$lot_discon_gap_days, ' days</td></tr>
</table>
</body></html>')
    add_html_card(overview_html, section = "OVERVIEW", title = "Run Overview")
  }, error = function(e) {
    log_msg("  WARNING: Overview tab generation failed: ", conditionMessage(e))
  })

  # --------------------------------------------------------
  # 0b. QC Summary tab — pass/fail validation checks (SECOND tab)
  # --------------------------------------------------------
  tryCatch({
    qc_rows <- list()
    add_qc <- function(check, value, status) {
      qc_rows[[length(qc_rows) + 1]] <<- sprintf(
        '<tr><td>%s</td><td>%s</td><td class="%s">%s</td></tr>',
        check, value,
        if (status == "PASS") "pass" else if (status == "WARN") "warn" else "fail",
        status
      )
    }

    orphan_n <- tryCatch({
      as.numeric(db_q(con, "
        SELECT count(DISTINCT c.CL_MED_ABBR) AS n
        FROM mma_codelist c LEFT JOIN mma_rollup r ON c.CL_MED_ABBR = r.CL_MED_ABBR
        WHERE r.CL_MED_ABBR IS NULL
      ")$n)
    }, error = function(e) NA)
    if (!is.na(orphan_n)) add_qc("Codelist meds not in rollup", orphan_n,
                                  if (orphan_n == 0) "PASS" else "WARN")

    uncoded_n <- tryCatch({
      as.numeric(db_q(con, "
        SELECT count(DISTINCT r.CL_MED_ABBR) AS n
        FROM mma_rollup r LEFT JOIN mma_codelist c ON r.CL_MED_ABBR = c.CL_MED_ABBR
        WHERE c.CL_MED_ABBR IS NULL
      ")$n)
    }, error = function(e) NA)
    if (!is.na(uncoded_n)) add_qc("Rollup meds with zero codes", uncoded_n,
                                   if (uncoded_n == 0) "PASS" else "WARN")

    multi_n <- tryCatch({
      as.numeric(db_q(con, "
        SELECT count(*) AS n FROM (
          SELECT CL_MED_ABBR FROM mma_codelist
          GROUP BY CL_MED_ABBR HAVING count(DISTINCT CL_MED_CLASS) > 1
        )
      ")$n)
    }, error = function(e) NA)
    if (!is.na(multi_n)) add_qc("MED_ABBR mapped to multiple classes", multi_n,
                                 if (multi_n == 0) "PASS" else "WARN")

    bad_maps <- tryCatch({
      as.numeric(db_q(con, "SELECT count(*) AS n FROM map_stacked WHERE MAP_END_DT < MAP_START_DT")$n)
    }, error = function(e) NA)
    if (!is.na(bad_maps)) add_qc("MAPs with END_DT < START_DT", bad_maps,
                                  if (bad_maps == 0) "PASS" else "FAIL")

    runout_mm <- tryCatch({
      as.numeric(db_q(con, "
        SELECT count(*) AS n FROM map_stacked
        WHERE MAP_END_DT <> greatest(
          coalesce(MAP_RX_RUNOUT_DT, cast('1900-01-01' as date)),
          coalesce(MAP_MED_RUNOUT_DT, cast('1900-01-01' as date)))
        AND MAP_END_DT IS NOT NULL
      ")$n)
    }, error = function(e) NA)
    if (!is.na(runout_mm)) add_qc("MAPs where END != max(runouts)", runout_mm,
                                   if (runout_mm == 0) "PASS" else "WARN")

    lot1_past <- tryCatch({
      as.numeric(db_q(con, "
        SELECT sum(case when lb.LOT1_BASE_END_DT > p.OBS_END_DT then 1 else 0 end) AS n
        FROM lot1_base_end lb INNER JOIN lot_patient_input p ON lb.PATID = p.PATID
      ")$n)
    }, error = function(e) NA)
    if (!is.na(lot1_past)) add_qc("LOT1 END_DT past OBS_END_DT", lot1_past,
                                   if (lot1_past == 0) "PASS" else "WARN")

    sct_both <- tryCatch({
      as.numeric(db_q(con, "
        SELECT sum(CASE WHEN LOT1_SCT_AUTO_TAND_FLG = 1 AND LOT1_SCT_AUTO_SING_FLG = 1 THEN 1 ELSE 0 END) AS n
        FROM lot1_sct
      ")$n)
    }, error = function(e) NA)
    if (!is.na(sct_both)) add_qc("SCT: both tandem AND single flag", sct_both,
                                  if (sct_both == 0) "PASS" else "FAIL")

    sct_past <- tryCatch({
      as.numeric(db_q(con, "
        SELECT sum(CASE WHEN sct.LOT1_TX_ENDDATE IS NOT NULL
                    AND sct.LOT1_TX_ENDDATE > lb.OBS_END_DT THEN 1 ELSE 0 END) AS n
        FROM lot1_sct sct INNER JOIN lot1_base lb ON sct.PATID = lb.PATID
      ")$n)
    }, error = function(e) NA)
    if (!is.na(sct_past)) add_qc("SCT end date past OBS_END_DT", sct_past,
                                  if (sct_past == 0) "PASS" else "WARN")

    n_pass <- sum(sapply(qc_rows, function(r) grepl('class="pass"', r)))
    n_total <- length(qc_rows)

    qc_html <- paste0('<!DOCTYPE html><html><head>
<meta charset="UTF-8">
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
         background: #fff; padding: 24px; color: #2d3436; }
  h2 { font-size: 20px; color: #1a5276; margin-bottom: 8px; }
  .summary { font-size: 14px; color: #636e72; margin-bottom: 16px; }
  table { border-collapse: collapse; width: 100%; }
  th, td { text-align: left; padding: 10px 14px; border-bottom: 1px solid #eee; font-size: 13px; }
  th { background: #f5f6fa; font-weight: 600; color: #636e72; text-transform: uppercase;
       letter-spacing: 0.5px; font-size: 11px; }
  .pass { color: #00b894; font-weight: 700; }
  .warn { color: #fdcb6e; font-weight: 700; }
  .fail { color: #d63031; font-weight: 700; }
</style></head><body>
<h2>QC Validation Summary</h2>
<p class="summary">', n_pass, ' / ', n_total, ' checks passed</p>
<table>
<tr><th>Check</th><th>Value</th><th>Status</th></tr>
', paste(qc_rows, collapse = "\n"), '
</table>
</body></html>')
    add_html_card(qc_html, section = "QC", title = "QC Summary")
  }, error = function(e) {
    log_msg("  WARNING: QC summary tab generation failed: ", conditionMessage(e))
  })

  # --------------------------------------------------------
  # 1. MMA_MED Summary
  # --------------------------------------------------------
  tryCatch({
    cat("\n", DASH, "\n")
    cat("  5A. MMA_MED (Medication Claims) Summary\n")
    cat(DASH, "\n")

    mma_stats <- db_q(con, "
      SELECT
        count(*)                                     AS n_rows,
        count(DISTINCT PATID)                        AS n_patients,
        count(DISTINCT MED_ABBR)                     AS n_meds,
        sum(case when CLAIM_TYPE='pharmacy' then 1 else 0 end) AS n_pharmacy,
        sum(case when CLAIM_TYPE='medical'  then 1 else 0 end) AS n_medical,
        min(DATE_SERVICE) AS min_date,
        max(DATE_SERVICE) AS max_date,
        avg(DAY_SUPPLY)   AS avg_day_supply,
        percentile_approx(DAY_SUPPLY, 0.5) AS median_day_supply
      FROM mma_med_processed
    ")
    cat(sprintf("  Total claims (de-duped):     %s\n", format(mma_stats$n_rows, big.mark = ",")))
    cat(sprintf("  Distinct patients:           %s\n", format(mma_stats$n_patients, big.mark = ",")))
    cat(sprintf("  Distinct medications:        %s\n", format(mma_stats$n_meds, big.mark = ",")))
    cat(sprintf("  Pharmacy claims:             %s\n", format(mma_stats$n_pharmacy, big.mark = ",")))
    cat(sprintf("  Medical claims:              %s\n", format(mma_stats$n_medical, big.mark = ",")))
    cat(sprintf("  Date range:                  %s to %s\n", mma_stats$min_date, mma_stats$max_date))
    cat(sprintf("  Avg day supply:              %.1f (median: %.0f)\n",
                mma_stats$avg_day_supply, mma_stats$median_day_supply))

    # Claims by medication
    med_dist <- db_q(con, "
      SELECT MED_ABBR, MED_CLASS,
             count(*) AS n_claims,
             count(DISTINCT PATID) AS n_patients,
             sum(case when CLAIM_TYPE='pharmacy' then 1 else 0 end) AS n_rx,
             sum(case when CLAIM_TYPE='medical' then 1 else 0 end) AS n_med
      FROM mma_med_processed
      GROUP BY MED_ABBR, MED_CLASS
      ORDER BY count(DISTINCT PATID) DESC
    ")
    cat("\n")
    cat(sprintf("  %-8s %-12s %10s %10s %8s %8s\n", "Med", "Class", "Claims", "Patients", "RX", "Medical"))
    cat(strrep("-", 62), "\n")
    for (i in seq_len(nrow(med_dist))) {
      r <- med_dist[i, ]
      cat(sprintf("  %-8s %-12s %10s %10s %8s %8s\n",
                  r$MED_ABBR, r$MED_CLASS,
                  format(r$n_claims, big.mark = ","),
                  format(r$n_patients, big.mark = ","),
                  format(r$n_rx, big.mark = ","),
                  format(r$n_med, big.mark = ",")))
    }

    # Figure 1: Patients by medication (bar chart)
    if (has_ggplot2 && nrow(med_dist) > 0) {
      med_dist$n_patients <- as.numeric(med_dist$n_patients)
      med_dist$n_claims   <- as.numeric(med_dist$n_claims)
      med_dist$n_rx       <- as.numeric(med_dist$n_rx)
      med_dist$n_med      <- as.numeric(med_dist$n_med)
      p1 <- ggplot(med_dist,
                    aes(x = reorder(MED_ABBR, -n_patients), y = n_patients,
                        fill = MED_CLASS, text = paste0(
                          "Med: ", MED_ABBR, "\nClass: ", MED_CLASS,
                          "\nPatients: ", format(n_patients, big.mark = ","),
                          "\nClaims: ", format(n_claims, big.mark = ",")))) +
        geom_bar(stat = "identity", width = 0.75) +
        geom_text(aes(label = format(n_patients, big.mark = ",")),
                  vjust = -0.4, size = 3, color = "grey30") +
        scale_fill_manual(values = lot_class_palette, na.value = "grey50") +
        scale_y_continuous(labels = scales::comma_format(), expand = expansion(mult = c(0, 0.12))) +
        labs(title = "MMA_MED: Patients by Medication",
             subtitle = paste0("N = ", format(sum(med_dist$n_patients), big.mark = ","),
                               " patient-medication combinations across ",
                               nrow(med_dist), " medications"),
             x = NULL, y = "Distinct Patients", fill = "Drug Class") +
        theme_lot() +
        theme(axis.text.x = element_text(angle = 45, hjust = 1, size = 10))
      save_plot(p1, "fig01_mma_patients_by_med.png",
               section = "MMA_MED", title = "Fig 1: Patients by Medication")
      save_table(med_dist, section = "MMA_MED",
                 title = "Table: MMA Claims by Medication")
    }

    # Figure 2: Pharmacy vs Medical claims stacked bar
    if (has_ggplot2 && nrow(med_dist) > 0) {
      claim_long <- rbind(
        data.frame(MED_ABBR = med_dist$MED_ABBR, MED_CLASS = med_dist$MED_CLASS,
                   CLAIM_TYPE = "Pharmacy", N = as.numeric(med_dist$n_rx)),
        data.frame(MED_ABBR = med_dist$MED_ABBR, MED_CLASS = med_dist$MED_CLASS,
                   CLAIM_TYPE = "Medical",  N = as.numeric(med_dist$n_med))
      )
      # Compute total claims per med for correct ordering
      total_by_med <- tapply(claim_long$N, claim_long$MED_ABBR, sum)
      claim_long$MED_ABBR <- factor(claim_long$MED_ABBR,
                                     levels = names(sort(total_by_med, decreasing = TRUE)))
      p2 <- ggplot(claim_long,
                    aes(x = MED_ABBR, y = N, fill = CLAIM_TYPE,
                        text = paste0("Med: ", MED_ABBR, "\nType: ", CLAIM_TYPE,
                                      "\nClaims: ", format(N, big.mark = ",")))) +
        geom_bar(stat = "identity", position = "stack", width = 0.75) +
        scale_fill_manual(values = c("Pharmacy" = "#2E86AB", "Medical" = "#C73E1D")) +
        scale_y_continuous(labels = scales::comma_format(), expand = expansion(mult = c(0, 0.08))) +
        labs(title = "MMA_MED: Claims by Type and Medication",
             subtitle = "Pharmacy (NDC-based) vs Medical (procedure/NDC) claim sources",
             x = NULL, y = "Claim Count", fill = "Claim Type") +
        theme_lot() +
        theme(axis.text.x = element_text(angle = 45, hjust = 1, size = 10))
      save_plot(p2, "fig02_mma_claims_by_type.png",
               section = "MMA_MED", title = "Fig 2: Claims by Type")
    }

    # Day supply distribution
    ds_dist <- db_q(con, "
      SELECT CLAIM_TYPE,
             min(DAY_SUPPLY) AS min_ds,
             percentile_approx(DAY_SUPPLY, 0.25) AS p25_ds,
             percentile_approx(DAY_SUPPLY, 0.5)  AS median_ds,
             percentile_approx(DAY_SUPPLY, 0.75) AS p75_ds,
             max(DAY_SUPPLY) AS max_ds,
             avg(DAY_SUPPLY) AS mean_ds
      FROM mma_med_processed
      GROUP BY CLAIM_TYPE
    ")
    cat("\n  Day Supply Distribution:\n")
    cat(sprintf("  %-10s %6s %6s %6s %6s %6s %8s\n", "Type", "Min", "P25", "Med", "P75", "Max", "Mean"))
    cat(strrep("-", 55), "\n")
    for (i in seq_len(nrow(ds_dist))) {
      r <- ds_dist[i, ]
      cat(sprintf("  %-10s %6.0f %6.0f %6.0f %6.0f %6.0f %8.1f\n",
                  r$CLAIM_TYPE, r$min_ds, r$p25_ds, r$median_ds, r$p75_ds, r$max_ds, r$mean_ds))
    }

  }, error = function(e) {
    log_msg("WARN: MMA_MED descriptives failed: ", conditionMessage(e))
  })

  # --------------------------------------------------------
  # 2. MAP Summary
  # --------------------------------------------------------
  cat("\n", DASH, "\n")
  cat("  5B. MAP_MED (Medication Available Periods) Summary\n")
  cat(DASH, "\n")

  # Use a subquery for MAP length to avoid percentile_approx on expression
  map_stats <- tryCatch(db_q(con, "
    SELECT
      count(*)               AS n_maps,
      count(DISTINCT PATID)  AS n_patients,
      count(DISTINCT MAP_MED_TYPE) AS n_meds,
      avg(map_length)        AS avg_map_length,
      percentile_approx(map_length, 0.5) AS median_map_length,
      min(map_length)        AS min_map_length,
      max(map_length)        AS max_map_length,
      sum(CAST(MAP_DISCON_FLG AS INT)) AS n_discon
    FROM (
      SELECT *, datediff(MAP_END_DT, MAP_START_DT) + 1 AS map_length
      FROM map_stacked
    )
  "), error = function(e) {
    log_msg("WARN: MAP stats query failed: ", conditionMessage(e))
    data.frame()
  })
  if (nrow(map_stats) > 0) {
    cat(sprintf("  Total MAPs:                  %s\n", format(map_stats$n_maps, big.mark = ",")))
    cat(sprintf("  Distinct patients:           %s\n", format(map_stats$n_patients, big.mark = ",")))
    cat(sprintf("  Distinct medications:        %s\n", format(map_stats$n_meds, big.mark = ",")))
    cat(sprintf("  MAP length (days):           mean=%.1f, median=%.0f, range=[%s, %s]\n",
                map_stats$avg_map_length, map_stats$median_map_length,
                format(map_stats$min_map_length, big.mark = ","),
                format(map_stats$max_map_length, big.mark = ",")))
    cat(sprintf("  MAPs with discontinuation:   %s (%.1f%%)\n",
                format(map_stats$n_discon, big.mark = ","),
                100 * map_stats$n_discon / max(map_stats$n_maps, 1)))
  }

  # MAPs per patient distribution
  maps_per_pt <- tryCatch(db_q(con, "
    SELECT n_maps, count(*) AS n_patients
    FROM (SELECT PATID, count(*) AS n_maps FROM map_stacked GROUP BY PATID)
    GROUP BY n_maps
    ORDER BY n_maps
  "), error = function(e) {
    log_msg("WARN: MAPs per patient query failed: ", conditionMessage(e))
    data.frame()
  })
  if (nrow(maps_per_pt) > 0) {
    cat("\n  MAPs per patient distribution:\n")
    cat(sprintf("  %-8s %10s\n", "# MAPs", "Patients"))
    cat(strrep("-", 22), "\n")
    for (i in seq_len(min(nrow(maps_per_pt), 15))) {
      r <- maps_per_pt[i, ]
      cat(sprintf("  %-8s %10s\n", format(as.integer(r$n_maps)), format(r$n_patients, big.mark = ",")))
    }
    if (nrow(maps_per_pt) > 15) cat("  ... (truncated)\n")
  }

  # MAP by medication
  map_by_med <- tryCatch(db_q(con, "
    SELECT
      MAP_MED_TYPE AS med,
      MAP_MED_CLASS AS class,
      count(*) AS n_maps,
      count(DISTINCT PATID) AS n_patients,
      avg(datediff(MAP_END_DT, MAP_START_DT) + 1) AS avg_map_days,
      sum(CAST(MAP_DISCON_FLG AS INT)) AS n_discon,
      sum(CASE WHEN MAP_RX_RUNOUT_DT IS NOT NULL AND MAP_MED_RUNOUT_DT IS NOT NULL THEN 1 ELSE 0 END) AS n_both_types
    FROM map_stacked
    GROUP BY MAP_MED_TYPE, MAP_MED_CLASS
    ORDER BY count(DISTINCT PATID) DESC
  "), error = function(e) {
    log_msg("WARN: MAP by med query failed: ", conditionMessage(e))
    data.frame()
  })
  if (nrow(map_by_med) > 0) {
    cat("\n")
    cat(sprintf("  %-8s %-12s %6s %8s %10s %7s %9s\n",
                "Med", "Class", "MAPs", "Patients", "Avg Days", "Discon", "Both Src"))
    cat(strrep("-", 66), "\n")
    for (i in seq_len(nrow(map_by_med))) {
      r <- map_by_med[i, ]
      cat(sprintf("  %-8s %-12s %6s %8s %9.1f %7s %9s\n",
                  r$med, r$class,
                  format(r$n_maps, big.mark = ","),
                  format(r$n_patients, big.mark = ","),
                  r$avg_map_days,
                  format(r$n_discon, big.mark = ","),
                  format(r$n_both_types, big.mark = ",")))
    }
  }

  # Figure 3: MAP length distribution (histogram via SQL-binned counts)
  tryCatch({
    if (has_ggplot2) {
      map_bins <- db_q(con, "
        SELECT bin_start, count(*) AS n
        FROM (
          SELECT floor((datediff(MAP_END_DT, MAP_START_DT) + 1) / 30) * 30 AS bin_start
          FROM map_stacked
        )
        GROUP BY bin_start
        ORDER BY bin_start
      ")
      if (nrow(map_bins) > 0) {
        map_bins$bin_start <- as.numeric(map_bins$bin_start)
        map_bins$n         <- as.numeric(map_bins$n)
        median_map <- if (nrow(map_stats) > 0) as.numeric(map_stats$median_map_length) else NA
        p3 <- ggplot(map_bins, aes(x = bin_start, y = n,
                                    text = paste0("Days: ", bin_start, "-", bin_start + 29,
                                                  "\nMAPs: ", format(n, big.mark = ",")))) +
          geom_bar(stat = "identity", width = 28, fill = "#2E86AB", alpha = 0.85) +
          { if (!is.na(median_map)) geom_vline(xintercept = median_map,
                     linetype = "dashed", color = "#C73E1D", linewidth = 0.8) } +
          { if (!is.na(median_map)) annotate("text", x = median_map + 25, y = Inf, vjust = 2, hjust = 0,
                   label = paste0("Median: ", round(median_map), " days"),
                   color = "#C73E1D", fontface = "bold", size = 3.8) } +
          scale_x_continuous(breaks = seq(0, max(map_bins$bin_start, na.rm = TRUE), by = 90)) +
          scale_y_continuous(labels = scales::comma_format(), expand = expansion(mult = c(0, 0.1))) +
          labs(title = "MAP Length Distribution",
               subtitle = paste0(format(sum(map_bins$n), big.mark = ","), " medication-available periods, 30-day bins"),
               x = "MAP Length (days)", y = "Number of MAPs") +
          theme_lot()
        save_plot(p3, "fig03_map_length_distribution.png",
                 section = "MAP", title = "Fig 3: MAP Length Distribution")
      }
    }
  }, error = function(e) {
    log_msg("WARN: fig03 MAP length distribution failed: ", conditionMessage(e))
  })

  # Figure 4: MAP count by medication (bar)
  tryCatch({
    if (has_ggplot2 && nrow(map_by_med) > 0) {
      map_by_med$n_patients <- as.numeric(map_by_med$n_patients)
      map_by_med$n_maps     <- as.numeric(map_by_med$n_maps)
      map_by_med$n_discon   <- as.numeric(map_by_med$n_discon)
      p4 <- ggplot(map_by_med,
                    aes(x = reorder(med, -n_patients), y = n_patients, fill = class,
                        text = paste0("Med: ", med, "\nClass: ", class,
                                      "\nPatients: ", format(n_patients, big.mark = ","),
                                      "\nMAPs: ", format(n_maps, big.mark = ","),
                                      "\nAvg Days: ", round(avg_map_days, 1)))) +
        geom_bar(stat = "identity", width = 0.75) +
        geom_text(aes(label = format(n_patients, big.mark = ",")),
                  vjust = -0.4, size = 3, color = "grey30") +
        scale_fill_manual(values = lot_class_palette, na.value = "grey50") +
        scale_y_continuous(labels = scales::comma_format(), expand = expansion(mult = c(0, 0.12))) +
        labs(title = "MAP: Patients by Medication",
             subtitle = "Medication-available periods across all drug classes",
             x = NULL, y = "Distinct Patients", fill = "Drug Class") +
        theme_lot() +
        theme(axis.text.x = element_text(angle = 45, hjust = 1, size = 10))
      save_plot(p4, "fig04_map_patients_by_med.png",
               section = "MAP", title = "Fig 4: MAP Patients by Medication")
      map_by_med$avg_map_days <- round(as.numeric(map_by_med$avg_map_days), 1)
      save_table(map_by_med, section = "MAP",
                 title = "Table: MAP Summary by Medication")
    }
  }, error = function(e) {
    log_msg("WARN: fig04 MAP patients by med failed: ", conditionMessage(e))
  })

  # --------------------------------------------------------
  # 3. LOT1 Summary
  # --------------------------------------------------------
  tryCatch({
    cat("\n", DASH, "\n")
    cat("  6. LOT1_BASE Summary\n")
    cat(DASH, "\n")

    lot1_stats <- db_q(con, "
      SELECT
        count(*) AS n_patients,
        avg(datediff(LOT1_START_DT, INDEX_DATE)) AS avg_days_to_lot1,
        avg(LOT1_MED_CNT) AS avg_induction_meds,
        avg(LOT1_BASE_LENGTH) AS avg_lot1_length,
        percentile_approx(LOT1_BASE_LENGTH, 0.5) AS median_lot1_length,
        min(LOT1_BASE_LENGTH) AS min_lot1_length,
        max(LOT1_BASE_LENGTH) AS max_lot1_length,
        sum(case when LOT1_BASE_DISCON_DT is not null then 1 else 0 end) AS n_discon,
        sum(case when LOT1_BASE_1ST_ADD_MED_DT is not null then 1 else 0 end) AS n_add_med
      FROM lot1_base
    ")
    cat(sprintf("  Total LOT1 patients:         %s\n", format(lot1_stats$n_patients, big.mark = ",")))
    cat(sprintf("  Avg days index->LOT1:        %.1f\n", lot1_stats$avg_days_to_lot1))
    cat(sprintf("  Avg induction meds:          %.1f\n", lot1_stats$avg_induction_meds))
    cat(sprintf("  LOT1 length (days):          mean=%.1f, median=%.0f, range=[%s, %s]\n",
                lot1_stats$avg_lot1_length, lot1_stats$median_lot1_length,
                format(lot1_stats$min_lot1_length, big.mark = ","),
                format(lot1_stats$max_lot1_length, big.mark = ",")))
    cat(sprintf("  With discontinuation date:   %s (%.1f%%)\n",
                format(lot1_stats$n_discon, big.mark = ","),
                100 * lot1_stats$n_discon / max(lot1_stats$n_patients, 1)))
    cat(sprintf("  With medication add:         %s (%.1f%%)\n",
                format(lot1_stats$n_add_med, big.mark = ","),
                100 * lot1_stats$n_add_med / max(lot1_stats$n_patients, 1)))

    # LOT1 end reasons
    end_reasons <- db_q(con, "
      SELECT LOT1_BASE_END_REASON, count(*) AS n,
             avg(datediff(LOT1_BASE_END_DT, LOT1_START_DT) + 1) AS avg_length
      FROM lot1_base_end
      GROUP BY LOT1_BASE_END_REASON
      ORDER BY count(*) DESC
    ")
    total_lot1 <- lot1_stats$n_patients
    cat("\n  LOT1 BASE End Reasons:\n")
    cat(sprintf("  %-20s %10s %8s %10s\n", "Reason", "N", "%", "Avg Days"))
    cat(strrep("-", 52), "\n")
    for (i in seq_len(nrow(end_reasons))) {
      r <- end_reasons[i, ]
      cat(sprintf("  %-20s %10s %7.1f%% %10.1f\n",
                  r$LOT1_BASE_END_REASON,
                  format(r$n, big.mark = ","),
                  100 * r$n / max(total_lot1, 1),
                  r$avg_length))
    }

    # Induction regimen distribution (Top 25)
    regimens <- db_q(con, "
      SELECT
        LOT1_BASE_MEDS AS regimen,
        count(*) AS n_patients,
        avg(LOT1_BASE_LENGTH) AS avg_length,
        avg(LOT1_MED_CNT) AS avg_meds
      FROM lot1_base
      GROUP BY LOT1_BASE_MEDS
      ORDER BY count(*) DESC
      LIMIT 25
    ")
    cat("\n  Top 25 LOT1 Induction Regimens:\n")
    cat(sprintf("  %-40s %8s %7s %9s\n", "Regimen", "N", "%", "Avg Days"))
    cat(strrep("-", 68), "\n")
    for (i in seq_len(nrow(regimens))) {
      r <- regimens[i, ]
      cat(sprintf("  %-40s %8s %6.1f%% %8.1f\n",
                  substr(r$regimen, 1, 40),
                  format(r$n_patients, big.mark = ","),
                  100 * r$n_patients / max(total_lot1, 1),
                  r$avg_length))
    }

    # Figure 5: LOT1 induction regimen frequency (top 15 horizontal bar)
    if (has_ggplot2 && nrow(regimens) > 0) {
      regimens$n_patients <- as.numeric(regimens$n_patients)
      top15 <- head(regimens, 15)
      top15$pct <- 100 * top15$n_patients / as.numeric(max(total_lot1, 1))
      top15$regimen <- factor(top15$regimen, levels = rev(top15$regimen))
      p5 <- ggplot(top15, aes(x = regimen, y = n_patients,
                               text = paste0("Regimen: ", regimen,
                                             "\nPatients: ", format(n_patients, big.mark = ","),
                                             "\n% of LOT1: ", round(pct, 1), "%",
                                             "\nAvg Length: ", round(avg_length, 0), " days"))) +
        geom_bar(stat = "identity", fill = "#44BBA4", width = 0.7) +
        geom_text(aes(label = paste0(format(n_patients, big.mark = ","),
                                     " (", round(pct, 1), "%)")),
                  hjust = -0.05, size = 3.2, color = "grey30") +
        coord_flip() +
        scale_y_continuous(labels = scales::comma_format(), expand = expansion(mult = c(0, 0.2))) +
        labs(title = "LOT1: Top 15 Induction Regimens",
             subtitle = paste0("Out of ", format(as.numeric(total_lot1), big.mark = ","), " LOT1 patients"),
             x = NULL, y = "Number of Patients") +
        theme_lot() +
        theme(legend.position = "none")
      save_plot(p5, "fig05_lot1_top_regimens.png", width = 12, height = 7,
               section = "LOT1", title = "Fig 5: Top 15 Induction Regimens")
      regimens$avg_length <- round(as.numeric(regimens$avg_length), 1)
      regimens$avg_meds   <- round(as.numeric(regimens$avg_meds), 1)
      save_table(regimens, section = "LOT1",
                 title = "Table: Top 25 Induction Regimens")
    }

    # Figure 6: LOT1 base length distribution (SQL-binned to avoid OOM)
    if (has_ggplot2) {
      lot1_bins <- db_q(con, "
        SELECT floor(LOT1_BASE_LENGTH / 30) * 30 AS bin_start,
               count(*) AS n
        FROM lot1_base
        WHERE LOT1_BASE_LENGTH IS NOT NULL
        GROUP BY floor(LOT1_BASE_LENGTH / 30) * 30
        ORDER BY bin_start
      ")
      lot1_median <- db_q(con, "
        SELECT percentile_approx(LOT1_BASE_LENGTH, 0.5) AS median_len
        FROM lot1_base
        WHERE LOT1_BASE_LENGTH IS NOT NULL
      ")
      if (nrow(lot1_bins) > 0) {
        lot1_bins$bin_start  <- as.numeric(lot1_bins$bin_start)
        lot1_bins$n          <- as.numeric(lot1_bins$n)
        median_len <- if (nrow(lot1_median) > 0) as.numeric(lot1_median$median_len) else NA
        p6 <- ggplot(lot1_bins, aes(x = bin_start, y = n,
                                     text = paste0("Days: ", bin_start, "-", bin_start + 29,
                                                   "\nPatients: ", format(n, big.mark = ",")))) +
          geom_bar(stat = "identity", width = 28, fill = "#44BBA4", alpha = 0.85) +
          { if (!is.na(median_len)) geom_vline(xintercept = median_len,
                     linetype = "dashed", color = "#C73E1D", linewidth = 0.8) } +
          { if (!is.na(median_len)) annotate("text", x = median_len + 25, y = Inf, vjust = 2, hjust = 0,
                   label = paste0("Median: ", round(median_len), " days"),
                   color = "#C73E1D", fontface = "bold", size = 3.8) } +
          scale_x_continuous(breaks = seq(0, max(lot1_bins$bin_start, na.rm = TRUE), by = 180)) +
          scale_y_continuous(labels = scales::comma_format(), expand = expansion(mult = c(0, 0.1))) +
          labs(title = "LOT1 BASE Length Distribution",
               subtitle = paste0(format(sum(lot1_bins$n), big.mark = ","),
                                 " patients, 30-day bins"),
               x = "LOT1 BASE Length (days)", y = "Number of Patients") +
          theme_lot()
        save_plot(p6, "fig06_lot1_base_length.png",
                 section = "LOT1", title = "Fig 6: LOT1 Length Distribution")
      }
    }

    # Figure 7: LOT1 end reason bar chart
    if (has_ggplot2 && nrow(end_reasons) > 0) {
      end_reasons$n <- as.numeric(end_reasons$n)
      end_reasons$pct <- 100 * end_reasons$n / sum(end_reasons$n)
      end_reason_colors <- c(
        "DISCONTINUATION" = "#C73E1D", "MED_ADD" = "#F18F01",
        "CENSORED" = "#2E86AB", "SCT_AUTO" = "#A23B72",
        "SCT_ALLO" = "#8D5A97", "SCT_CART" = "#3F88C5", "SCT" = "#393E41"
      )
      p7 <- ggplot(end_reasons,
                    aes(x = reorder(LOT1_BASE_END_REASON, -n), y = n,
                        fill = LOT1_BASE_END_REASON,
                        text = paste0("Reason: ", LOT1_BASE_END_REASON,
                                      "\nPatients: ", format(n, big.mark = ","),
                                      "\n%: ", round(pct, 1), "%",
                                      "\nAvg LOT1 Length: ", round(avg_length, 0), " days"))) +
        geom_bar(stat = "identity", width = 0.7) +
        geom_text(aes(label = paste0(format(n, big.mark = ","), "\n(", round(pct, 1), "%)")),
                  vjust = -0.3, size = 3.5, color = "grey20") +
        scale_fill_manual(values = end_reason_colors) +
        scale_y_continuous(labels = scales::comma_format(), expand = expansion(mult = c(0, 0.15))) +
        labs(title = "LOT1 BASE End Reasons",
             subtitle = paste0("How LOT1 ended for ", format(sum(end_reasons$n), big.mark = ","), " patients"),
             x = NULL, y = "Number of Patients") +
        theme_lot() +
        theme(legend.position = "none")
      save_plot(p7, "fig07_lot1_end_reasons.png", width = 8, height = 6,
               section = "LOT1", title = "Fig 7: LOT1 End Reasons")
      end_reasons$avg_length <- round(as.numeric(end_reasons$avg_length), 1)
      end_reasons$pct        <- round(end_reasons$pct, 1)
      save_table(end_reasons, section = "LOT1",
                 title = "Table: LOT1 End Reasons")
    }

    # Figure 8: Induction med count distribution
    if (has_ggplot2) {
      med_cnt <- db_q(con, "
        SELECT LOT1_MED_CNT, count(*) AS n
        FROM lot1_base
        GROUP BY LOT1_MED_CNT
        ORDER BY LOT1_MED_CNT
      ")
      if (nrow(med_cnt) > 0) {
        med_cnt$n   <- as.numeric(med_cnt$n)
        med_cnt$LOT1_MED_CNT <- as.numeric(med_cnt$LOT1_MED_CNT)
        med_cnt$pct <- 100 * med_cnt$n / sum(med_cnt$n)
        p8 <- ggplot(med_cnt, aes(x = factor(LOT1_MED_CNT), y = n,
                                   text = paste0("Meds: ", LOT1_MED_CNT,
                                                 "\nPatients: ", format(n, big.mark = ","),
                                                 "\n%: ", round(pct, 1), "%"))) +
          geom_bar(stat = "identity", fill = "#2E86AB", width = 0.65) +
          geom_text(aes(label = paste0(format(n, big.mark = ","), "\n(", round(pct, 1), "%)")),
                    vjust = -0.3, size = 3.5, color = "grey20") +
          scale_y_continuous(labels = scales::comma_format(), expand = expansion(mult = c(0, 0.15))) +
          labs(title = "LOT1: Number of Induction Medications per Patient",
               subtitle = "How many distinct medications each patient received in induction",
               x = "Number of Induction Meds", y = "Patients") +
          theme_lot()
        save_plot(p8, "fig08_lot1_med_count.png", width = 8, height = 6,
                 section = "LOT1", title = "Fig 8: Induction Med Count")
      }
    }

    # Drug class distribution
    cat("\n  LOT1 Drug Class Distribution (from induction meds):\n")
    class_dist <- db_q(con, "
      SELECT MED_CLASS, count(DISTINCT PATID) AS n_patients
      FROM lot1_induction_meds
      GROUP BY MED_CLASS
      ORDER BY count(DISTINCT PATID) DESC
    ")
    cat(sprintf("  %-20s %10s %8s\n", "Class", "Patients", "%"))
    cat(strrep("-", 42), "\n")
    for (i in seq_len(nrow(class_dist))) {
      r <- class_dist[i, ]
      cat(sprintf("  %-20s %10s %7.1f%%\n",
                  r$MED_CLASS, format(r$n_patients, big.mark = ","),
                  100 * r$n_patients / max(total_lot1, 1)))
    }

  }, error = function(e) {
    log_msg("WARN: LOT1 descriptives failed: ", conditionMessage(e))
  })

  # --------------------------------------------------------
  # 4. SCT Summary
  # --------------------------------------------------------
  tryCatch({
    cat("\n", DASH, "\n")
    cat("  7. SCT (Stem Cell Transplant) Summary\n")
    cat(DASH, "\n")

    sct_raw_stats <- tryCatch(db_q(con, "
      SELECT SCT_TYPE, count(*) AS n_claims, count(DISTINCT PATID) AS n_patients
      FROM sct_claims_raw
      GROUP BY SCT_TYPE
      ORDER BY SCT_TYPE
    "), error = function(e) data.frame())
    if (nrow(sct_raw_stats) > 0) {
      cat("  Raw SCT claims by type:\n")
      cat(sprintf("  %-8s %10s %10s\n", "Type", "Claims", "Patients"))
      cat(strrep("-", 32), "\n")
      for (i in seq_len(nrow(sct_raw_stats))) {
        r <- sct_raw_stats[i, ]
        cat(sprintf("  %-8s %10s %10s\n",
                    r$SCT_TYPE, format(r$n_claims, big.mark = ","),
                    format(r$n_patients, big.mark = ",")))
      }
    } else {
      cat("  No SCT claims found.\n")
    }

    sct_lot1_stats <- tryCatch(db_q(con, "
      SELECT
        count(*) AS n_patients,
        sum(CASE WHEN LOT1_TX_AUTO_DT_1 IS NOT NULL THEN 1 ELSE 0 END) AS n_with_auto,
        sum(CASE WHEN FIRST_ALLO_DT IS NOT NULL THEN 1 ELSE 0 END) AS n_with_allo,
        sum(CASE WHEN FIRST_CART_DT IS NOT NULL THEN 1 ELSE 0 END) AS n_with_cart,
        sum(LOT1_SCT_AUTO_TAND_FLG) AS n_tandem,
        sum(LOT1_SCT_AUTO_SING_FLG) AS n_single_auto,
        sum(CASE WHEN LOT1_TX_ENDDATE IS NOT NULL THEN 1 ELSE 0 END) AS n_sct_end
      FROM lot1_sct
    "), error = function(e) data.frame())
    if (nrow(sct_lot1_stats) > 0) {
      cat(sprintf("\n  LOT1 SCT Summary (of %s LOT1 patients):\n",
                  format(sct_lot1_stats$n_patients, big.mark = ",")))
      cat(sprintf("    With AUTO SCT:      %s (%.1f%%)\n",
                  format(sct_lot1_stats$n_with_auto, big.mark = ","),
                  100 * sct_lot1_stats$n_with_auto / max(sct_lot1_stats$n_patients, 1)))
      cat(sprintf("      Tandem AUTO:      %s\n", format(sct_lot1_stats$n_tandem, big.mark = ",")))
      cat(sprintf("      Single AUTO:      %s\n", format(sct_lot1_stats$n_single_auto, big.mark = ",")))
      cat(sprintf("    With ALLO SCT:      %s (%.1f%%)\n",
                  format(sct_lot1_stats$n_with_allo, big.mark = ","),
                  100 * sct_lot1_stats$n_with_allo / max(sct_lot1_stats$n_patients, 1)))
      cat(sprintf("    With CAR-T:         %s (%.1f%%)\n",
                  format(sct_lot1_stats$n_with_cart, big.mark = ","),
                  100 * sct_lot1_stats$n_with_cart / max(sct_lot1_stats$n_patients, 1)))
      cat(sprintf("    SCT ending LOT1:    %s (%.1f%%)\n",
                  format(sct_lot1_stats$n_sct_end, big.mark = ","),
                  100 * sct_lot1_stats$n_sct_end / max(sct_lot1_stats$n_patients, 1)))
    }

    # SCT end reason breakdown
    sct_end_reasons <- tryCatch(db_q(con, "
      SELECT
        CASE LOT1_TX_ENDDATE_REASON
          WHEN 1 THEN 'AUTO' WHEN 2 THEN 'ALLO' WHEN 3 THEN 'CART' ELSE 'NONE'
        END AS SCT_END_TYPE,
        count(*) AS n
      FROM lot1_sct
      WHERE LOT1_TX_ENDDATE IS NOT NULL
      GROUP BY LOT1_TX_ENDDATE_REASON
      ORDER BY LOT1_TX_ENDDATE_REASON
    "), error = function(e) data.frame())
    if (nrow(sct_end_reasons) > 0) {
      cat("\n  SCT End Reason (within patients whose LOT1 ends due to SCT):\n")
      cat(sprintf("  %-8s %10s\n", "Type", "N"))
      cat(strrep("-", 20), "\n")
      for (i in seq_len(nrow(sct_end_reasons))) {
        r <- sct_end_reasons[i, ]
        cat(sprintf("  %-8s %10s\n", r$SCT_END_TYPE, format(r$n, big.mark = ",")))
      }
    }

    cat("\n", SEP, "\n")
    cat("  END OF DESCRIPTIVE SUMMARY\n")
    cat(SEP, "\n")

  }, error = function(e) {
    log_msg("WARN: SCT descriptives failed: ", conditionMessage(e))
  })

  # --------------------------------------------------------
  # 5. Patient journey timelines — sample of interesting patients
  # --------------------------------------------------------
  tryCatch({
    if (has_plotly) {
      # Find interesting patients: those with med restarts (MAP_CNT >= 2),
      # add-meds, or SCT events. Sample up to 20.
      journey_pats <- db_q(con, "
        WITH interesting AS (
          -- Patients with same-med restarts
          SELECT DISTINCT PATID, 'restart' AS reason
          FROM map_stacked WHERE MAP_CNT >= 2
          UNION
          -- Patients with add-med
          SELECT DISTINCT PATID, 'add_med'
          FROM lot1_base WHERE LOT1_BASE_1ST_ADD_MED_DT IS NOT NULL
          UNION
          -- Patients with SCT
          SELECT DISTINCT PATID, 'sct'
          FROM lot1_sct WHERE LOT1_TX_ENDDATE IS NOT NULL
        )
        SELECT PATID, concat_ws(',', collect_set(reason)) AS reasons
        FROM interesting
        GROUP BY PATID
        ORDER BY length(concat_ws(',', collect_set(reason))) DESC
        LIMIT 20
      ")

      if (nrow(journey_pats) > 0) {
        pat_ids_sql <- paste0("('", paste(journey_pats$PATID, collapse = "','"), "')")

        # Get MAP segments for these patients
        journey_maps <- db_q(con, glue("
          SELECT m.PATID, m.MAP_MED_TYPE AS MED, m.MAP_MED_CLASS AS CLASS,
                 m.MAP_START_DT, m.MAP_END_DT, m.MAP_CNT,
                 m.MAP_DISCON_FLG,
                 datediff(m.MAP_END_DT, m.MAP_START_DT) + 1 AS MAP_DAYS
          FROM map_stacked m
          WHERE m.PATID IN {pat_ids_sql}
          ORDER BY m.PATID, m.MAP_MED_TYPE, m.MAP_START_DT
        "))

        # Get LOT1 milestones
        journey_milestones <- db_q(con, glue("
          SELECT lb.PATID,
                 lb.LOT1_START_DT,
                 lb.LOT1_BASE_1ST_ADD_MED_DT,
                 lbe.LOT1_BASE_END_DT,
                 lbe.LOT1_BASE_END_REASON,
                 sct.LOT1_1ST_SCT_DT AS SCT_DT
          FROM lot1_base lb
          LEFT JOIN lot1_base_end lbe ON lb.PATID = lbe.PATID
          LEFT JOIN lot1_sct sct ON lb.PATID = sct.PATID
          WHERE lb.PATID IN {pat_ids_sql}
        "))

        if (nrow(journey_maps) > 0) {
          # Convert types
          journey_maps$MAP_START_DT <- as.Date(journey_maps$MAP_START_DT)
          journey_maps$MAP_END_DT   <- as.Date(journey_maps$MAP_END_DT)
          journey_maps$MAP_CNT      <- as.numeric(journey_maps$MAP_CNT)
          journey_maps$MAP_DAYS     <- as.numeric(journey_maps$MAP_DAYS)

          # Render one plotly timeline per patient, collect them
          # Use first 10 patients max for dashboard size
          show_pats <- unique(journey_maps$PATID)[1:min(10, length(unique(journey_maps$PATID)))]

          for (pid in show_pats) {
            pat_maps <- journey_maps[journey_maps$PATID == pid, ]
            if (nrow(pat_maps) == 0) next
            pat_ms   <- journey_milestones[journey_milestones$PATID == pid, ]
            reasons  <- if (pid %in% journey_pats$PATID) {
              journey_pats$reasons[journey_pats$PATID == pid]
            } else ""

            # Build plotly shapes for Gantt bars
            # Y-axis: medication names, X-axis: dates
            meds <- sort(unique(pat_maps$MED))
            med_y <- setNames(seq_along(meds), meds)

            shapes <- list()
            annotations <- list()
            hover_texts <- list()

            for (j in seq_len(nrow(pat_maps))) {
              row <- pat_maps[j, ]
              y_pos <- med_y[row$MED]
              color <- if (row$CLASS %in% names(lot_class_palette)) lot_class_palette[row$CLASS] else "#636e72"
              # Make restart segments slightly different shade
              alpha_val <- if (row$MAP_CNT > 1) 0.6 else 0.85

              shapes[[length(shapes) + 1]] <- list(
                type = "rect",
                x0 = as.character(row$MAP_START_DT),
                x1 = as.character(row$MAP_END_DT),
                y0 = y_pos - 0.35,
                y1 = y_pos + 0.35,
                fillcolor = color,
                opacity = alpha_val,
                line = list(color = color, width = 1),
                layer = "below"
              )
            }

            # Milestone vertical lines
            vlines <- list()
            if (nrow(pat_ms) > 0) {
              ms <- pat_ms[1, ]
              add_vline <- function(dt, label, color) {
                if (!is.na(dt) && !is.null(dt)) {
                  vlines[[length(vlines) + 1]] <<- list(
                    type = "line", x0 = as.character(dt), x1 = as.character(dt),
                    y0 = 0.3, y1 = length(meds) + 0.7,
                    line = list(color = color, width = 2, dash = "dash"),
                    layer = "above"
                  )
                  annotations[[length(annotations) + 1]] <<- list(
                    x = as.character(dt), y = length(meds) + 0.6,
                    text = label, showarrow = FALSE,
                    font = list(size = 10, color = color),
                    xanchor = "left", textangle = -30
                  )
                }
              }
              add_vline(as.Date(ms$LOT1_START_DT), "LOT1 Start", "#2E86AB")
              add_vline(as.Date(ms$LOT1_BASE_1ST_ADD_MED_DT), "Add Med", "#F18F01")
              add_vline(as.Date(ms$LOT1_BASE_END_DT), paste0("LOT1 End (", ms$LOT1_BASE_END_REASON, ")"), "#C73E1D")
              add_vline(as.Date(ms$SCT_DT), "SCT", "#8D5A97")
            }

            all_shapes <- c(shapes, vlines)

            # Create invisible scatter for hover
            hover_df <- data.frame(
              x = pat_maps$MAP_START_DT + as.integer((pat_maps$MAP_END_DT - pat_maps$MAP_START_DT) / 2),
              y = med_y[pat_maps$MED],
              text = paste0(
                "Med: ", pat_maps$MED,
                "\nClass: ", pat_maps$CLASS,
                "\nStart: ", pat_maps$MAP_START_DT,
                "\nEnd: ", pat_maps$MAP_END_DT,
                "\nDays: ", pat_maps$MAP_DAYS,
                "\nMAP #", pat_maps$MAP_CNT,
                {
                  discon_flg <- pat_maps$MAP_DISCON_FLG
                  if (is.null(discon_flg)) discon_flg <- rep(0L, nrow(pat_maps))
                  ifelse(discon_flg == 1, "\nDiscon: Yes", "")
                }
              ),
              stringsAsFactors = FALSE
            )

            # Anonymized patient label
            pat_label <- paste0("Patient ", which(show_pats == pid))
            pp <- plotly::plot_ly(hover_df, x = ~x, y = ~y, text = ~text,
                                  type = "scatter", mode = "markers",
                                  marker = list(size = 1, opacity = 0),
                                  hoverinfo = "text") |>
              plotly::layout(
                title = list(text = paste0(pat_label, " — Medication Journey"),
                             font = list(size = 14)),
                xaxis = list(title = "", type = "date",
                             gridcolor = "#eee"),
                yaxis = list(title = "", tickmode = "array",
                             tickvals = seq_along(meds),
                             ticktext = meds,
                             range = c(0.3, length(meds) + 0.8),
                             gridcolor = "#eee"),
                shapes = all_shapes,
                annotations = annotations,
                showlegend = FALSE,
                margin = list(l = 100, t = 50, b = 40, r = 30),
                plot_bgcolor = "#fafafa",
                paper_bgcolor = "white"
              ) |>
              plotly::config(displayModeBar = TRUE, displaylogo = FALSE,
                             modeBarButtonsToRemove = list("lasso2d", "select2d"))

            add_to_dashboard(pp, section = "JOURNEY",
                             title = paste0(pat_label, " (", reasons, ")"))
          }
          log_msg("  Patient journey timelines added: ", length(show_pats), " patients")
        }
      } else {
        log_msg("  No interesting patients found for journey timelines.")
      }
    }
  }, error = function(e) {
    log_msg("WARN: Patient journey timelines failed: ", conditionMessage(e))
  })

  # --------------------------------------------------------
  # 6. Restart / Gap Summary Table
  # --------------------------------------------------------
  tryCatch({
    restart_summary <- db_q(con, "
      WITH gaps AS (
        SELECT
          a.PATID, a.MAP_MED_TYPE AS MED, a.MAP_MED_CLASS AS CLASS,
          a.MAP_CNT,
          datediff(a.MAP_START_DT, b.MAP_END_DT) - 1 AS gap_days
        FROM map_stacked a
        INNER JOIN map_stacked b
          ON a.PATID = b.PATID
          AND a.MAP_MED_TYPE = b.MAP_MED_TYPE
          AND a.MAP_CNT = b.MAP_CNT + 1
      )
      SELECT
        MED, CLASS,
        count(DISTINCT PATID) AS n_patients_with_restart,
        count(*) AS n_restarts,
        round(avg(gap_days), 1) AS avg_gap_days,
        percentile_approx(gap_days, 0.25) AS p25_gap,
        percentile_approx(gap_days, 0.5) AS median_gap,
        percentile_approx(gap_days, 0.75) AS p75_gap,
        max(gap_days) AS max_gap
      FROM gaps
      GROUP BY MED, CLASS
      ORDER BY count(DISTINCT PATID) DESC
    ")
    if (nrow(restart_summary) > 0) {
      for (col in c("avg_gap_days", "p25_gap", "median_gap", "p75_gap", "max_gap")) {
        restart_summary[[col]] <- as.numeric(restart_summary[[col]])
      }
      restart_summary$n_patients_with_restart <- as.numeric(restart_summary$n_patients_with_restart)
      restart_summary$n_restarts <- as.numeric(restart_summary$n_restarts)
      save_table(restart_summary, section = "JOURNEY",
                 title = "Table: Restart/Gap Summary by Medication")
      log_msg("  Restart/gap summary table added.")
    }
  }, error = function(e) {
    log_msg("WARN: Restart/gap summary failed: ", conditionMessage(e))
  })

  # --------------------------------------------------------
  # 7. True regimen-state timeline (contiguous regimen segments)
  #    Derives change-point intervals where the active med set is constant.
  #    Y-axis: regimen labels (e.g., "BORT+LENA"), X-axis: date range.
  #    Gaps between segments are visible as whitespace.
  # --------------------------------------------------------
  tryCatch({
    if (has_plotly) {
      # Select patients with interesting regimen transitions:
      # add-med events, restarts, or multiple distinct regimens
      regimen_pats <- db_q(con, "
        WITH change_patients AS (
          SELECT PATID FROM lot1_base WHERE LOT1_BASE_1ST_ADD_MED_DT IS NOT NULL
          UNION
          SELECT PATID FROM map_stacked WHERE MAP_CNT >= 2
          UNION
          SELECT PATID FROM (
            SELECT PATID, count(DISTINCT MAP_MED_TYPE) AS n_meds
            FROM map_stacked GROUP BY PATID HAVING count(DISTINCT MAP_MED_TYPE) >= 2
          )
        )
        SELECT DISTINCT PATID FROM change_patients LIMIT 8
      ")

      if (nrow(regimen_pats) > 0) {
        rp_ids_sql <- paste0("('", paste(regimen_pats$PATID, collapse = "','"), "')")

        # Get all MAPs for these patients
        reg_maps <- db_q(con, glue("
          SELECT PATID, MAP_MED_TYPE AS MED, MAP_MED_CLASS AS CLASS,
                 MAP_START_DT, MAP_END_DT, MAP_CNT
          FROM map_stacked
          WHERE PATID IN {rp_ids_sql}
          ORDER BY PATID, MAP_START_DT, MAP_MED_TYPE
        "))

        # Get milestones
        reg_ms <- db_q(con, glue("
          SELECT lb.PATID, lb.LOT1_START_DT,
                 lb.LOT1_BASE_1ST_ADD_MED_DT, lb.LOT1_BASE_MEDS,
                 lbe.LOT1_BASE_END_DT, lbe.LOT1_BASE_END_REASON
          FROM lot1_base lb
          LEFT JOIN lot1_base_end lbe ON lb.PATID = lbe.PATID
          WHERE lb.PATID IN {rp_ids_sql}
        "))

        if (nrow(reg_maps) > 0) {
          reg_maps$MAP_START_DT <- as.Date(reg_maps$MAP_START_DT)
          reg_maps$MAP_END_DT   <- as.Date(reg_maps$MAP_END_DT)

          show_reg_pats <- unique(reg_maps$PATID)[1:min(6, length(unique(reg_maps$PATID)))]

          for (pid in show_reg_pats) {
            pat_m <- reg_maps[reg_maps$PATID == pid, ]
            pat_info <- reg_ms[reg_ms$PATID == pid, ]

            # --- Derive regimen segments from MAP change points ---
            # Collect all boundary dates (MAP starts and MAP ends + 1 day)
            boundary_dates <- sort(unique(c(pat_m$MAP_START_DT, pat_m$MAP_END_DT + 1)))

            segments <- list()
            for (k in seq_len(length(boundary_dates) - 1)) {
              seg_start <- boundary_dates[k]
              seg_end   <- boundary_dates[k + 1] - 1  # inclusive end

              # Which MAPs are active during this segment?
              active <- pat_m[pat_m$MAP_START_DT <= seg_start & pat_m$MAP_END_DT >= seg_end, ]
              if (nrow(active) > 0) {
                active_meds <- paste(sort(unique(active$MED)), collapse = "+")
                segments[[length(segments) + 1]] <- data.frame(
                  start = seg_start, end = seg_end,
                  regimen = active_meds,
                  n_meds = length(unique(active$MED)),
                  stringsAsFactors = FALSE
                )
              }
              # If no MAPs active, this is a gap — no segment added, shows as whitespace
            }

            if (length(segments) == 0) next
            seg_df <- do.call(rbind, segments)

            # Merge consecutive segments with the same regimen
            merged <- list(seg_df[1, ])
            for (k in seq_len(nrow(seg_df))[-1]) {
              prev <- merged[[length(merged)]]
              curr <- seg_df[k, ]
              if (curr$regimen == prev$regimen && curr$start <= prev$end + 1) {
                # Extend previous segment
                merged[[length(merged)]]$end <- max(prev$end, curr$end)
              } else {
                merged[[length(merged) + 1]] <- curr
              }
            }
            seg_df <- do.call(rbind, merged)
            seg_df$days <- as.numeric(seg_df$end - seg_df$start) + 1

            # Assign y-positions: unique regimens
            reg_labels <- unique(seg_df$regimen)
            reg_y <- setNames(seq_along(reg_labels), reg_labels)

            # Color palette for regimens (cycle through a set)
            reg_colors <- c("#2E86AB", "#44BBA4", "#F18F01", "#C73E1D", "#A23B72",
                           "#3F88C5", "#8D5A97", "#636e72", "#E8A87C", "#41B3A3")

            shapes <- list()
            for (j in seq_len(nrow(seg_df))) {
              row <- seg_df[j, ]
              y_pos <- reg_y[row$regimen]
              color <- reg_colors[((y_pos - 1) %% length(reg_colors)) + 1]

              shapes[[length(shapes) + 1]] <- list(
                type = "rect",
                x0 = as.character(row$start), x1 = as.character(row$end),
                y0 = y_pos - 0.35, y1 = y_pos + 0.35,
                fillcolor = color, opacity = 0.85,
                line = list(color = color, width = 1),
                layer = "below"
              )
            }

            # Milestone vertical lines
            vlines <- list()
            annotations <- list()
            if (nrow(pat_info) > 0) {
              ms <- pat_info[1, ]
              add_vline3 <- function(dt, label, color) {
                if (!is.na(dt) && !is.null(dt)) {
                  vlines[[length(vlines) + 1]] <<- list(
                    type = "line", x0 = as.character(dt), x1 = as.character(dt),
                    y0 = 0.3, y1 = length(reg_labels) + 0.7,
                    line = list(color = color, width = 2, dash = "dash"), layer = "above"
                  )
                  annotations[[length(annotations) + 1]] <<- list(
                    x = as.character(dt), y = length(reg_labels) + 0.6,
                    text = label, showarrow = FALSE,
                    font = list(size = 10, color = color),
                    xanchor = "left", textangle = -30
                  )
                }
              }
              add_vline3(as.Date(ms$LOT1_START_DT), "LOT1 Start", "#2E86AB")
              add_vline3(as.Date(ms$LOT1_BASE_1ST_ADD_MED_DT), "Add Med", "#F18F01")
              add_vline3(as.Date(ms$LOT1_BASE_END_DT),
                         paste0("LOT1 End (", ms$LOT1_BASE_END_REASON, ")"), "#C73E1D")
            }

            # Hover trace
            hover_df3 <- data.frame(
              x = seg_df$start + as.integer((seg_df$end - seg_df$start) / 2),
              y = reg_y[seg_df$regimen],
              text = paste0("Regimen: ", seg_df$regimen,
                           "\nStart: ", seg_df$start, "\nEnd: ", seg_df$end,
                           "\nDays: ", seg_df$days,
                           "\nMeds: ", seg_df$n_meds),
              stringsAsFactors = FALSE
            )

            pat_idx <- which(show_reg_pats == pid)
            regimen_label <- if (nrow(pat_info) > 0) pat_info$LOT1_BASE_MEDS[1] else "?"
            pp2 <- plotly::plot_ly(hover_df3, x = ~x, y = ~y, text = ~text,
                                    type = "scatter", mode = "markers",
                                    marker = list(size = 1, opacity = 0),
                                    hoverinfo = "text") |>
              plotly::layout(
                title = list(
                  text = paste0("Regimen State ", pat_idx, " [", regimen_label, "]"),
                  font = list(size = 14)),
                xaxis = list(title = "", type = "date", gridcolor = "#eee"),
                yaxis = list(title = "", tickmode = "array",
                             tickvals = seq_along(reg_labels), ticktext = reg_labels,
                             range = c(0.3, length(reg_labels) + 0.8), gridcolor = "#eee"),
                shapes = c(shapes, vlines),
                annotations = annotations,
                showlegend = FALSE,
                margin = list(l = 140, t = 50, b = 40, r = 30),
                plot_bgcolor = "#fafafa", paper_bgcolor = "white"
              ) |>
              plotly::config(displayModeBar = TRUE, displaylogo = FALSE,
                             modeBarButtonsToRemove = list("lasso2d", "select2d"))

            add_to_dashboard(pp2, section = "JOURNEY",
                             title = paste0("Regimen State ", pat_idx, ": ", regimen_label))
          }
          log_msg("  Regimen-state timelines added: ", length(show_reg_pats), " patients")
        }
      }
    }
  }, error = function(e) {
    log_msg("WARN: Regimen-state timelines failed: ", conditionMessage(e))
  })

  # --------------------------------------------------------
  # 8. Improved distribution views — zoomed to p95
  # --------------------------------------------------------
  tryCatch({
    if (has_ggplot2) {
      # MAP length zoomed
      map_p95 <- tryCatch(
        as.numeric(db_q(con, "SELECT percentile_approx(datediff(MAP_END_DT, MAP_START_DT) + 1, 0.95) AS p95 FROM map_stacked")$p95),
        error = function(e) NA)
      if (!is.na(map_p95)) {
        map_bins_z <- db_q(con, glue("
          SELECT floor((datediff(MAP_END_DT, MAP_START_DT) + 1) / 30) * 30 AS bin_start,
                 count(*) AS n
          FROM map_stacked
          WHERE datediff(MAP_END_DT, MAP_START_DT) + 1 <= {round(map_p95 * 1.1)}
          GROUP BY floor((datediff(MAP_END_DT, MAP_START_DT) + 1) / 30) * 30
          ORDER BY bin_start
        "))
        if (nrow(map_bins_z) > 0) {
          map_bins_z$bin_start <- as.numeric(map_bins_z$bin_start)
          map_bins_z$n <- as.numeric(map_bins_z$n)
          map_median_z <- tryCatch(
            as.numeric(db_q(con, "SELECT percentile_approx(datediff(MAP_END_DT, MAP_START_DT) + 1, 0.5) AS m FROM map_stacked")$m),
            error = function(e) NA)
          pz1 <- ggplot(map_bins_z, aes(x = bin_start, y = n,
                        text = paste0("Days: ", bin_start, "-", bin_start + 29,
                                      "\nMAPs: ", format(n, big.mark = ",")))) +
            geom_bar(stat = "identity", width = 28, fill = "#2E86AB", alpha = 0.85) +
            { if (!is.na(map_median_z)) geom_vline(xintercept = map_median_z,
                       linetype = "dashed", color = "#C73E1D", linewidth = 0.8) } +
            { if (!is.na(map_median_z)) annotate("text", x = map_median_z + 15, y = Inf, vjust = 2, hjust = 0,
                     label = paste0("Median: ", round(map_median_z), "d"),
                     color = "#C73E1D", fontface = "bold", size = 3.8) } +
            scale_x_continuous(breaks = seq(0, max(map_bins_z$bin_start, na.rm = TRUE), by = 90)) +
            scale_y_continuous(labels = scales::comma_format(), expand = expansion(mult = c(0, 0.1))) +
            labs(title = "MAP Length Distribution (Zoomed to P95)",
                 subtitle = paste0("Clipped at ", round(map_p95), " days (95th percentile); ",
                                   format(sum(map_bins_z$n), big.mark = ","), " MAPs shown"),
                 x = "MAP Length (days)", y = "Number of MAPs") +
            theme_lot()
          save_plot(pz1, "fig03b_map_length_zoomed.png",
                   section = "MAP", title = "Fig 3b: MAP Length (Zoomed)")
        }
      }

      # LOT1 length zoomed
      lot1_p95 <- tryCatch(
        as.numeric(db_q(con, "SELECT percentile_approx(LOT1_BASE_LENGTH, 0.95) AS p95 FROM lot1_base WHERE LOT1_BASE_LENGTH IS NOT NULL")$p95),
        error = function(e) NA)
      if (!is.na(lot1_p95)) {
        lot1_bins_z <- db_q(con, glue("
          SELECT floor(LOT1_BASE_LENGTH / 30) * 30 AS bin_start,
                 count(*) AS n
          FROM lot1_base
          WHERE LOT1_BASE_LENGTH IS NOT NULL AND LOT1_BASE_LENGTH <= {round(lot1_p95 * 1.1)}
          GROUP BY floor(LOT1_BASE_LENGTH / 30) * 30
          ORDER BY bin_start
        "))
        if (nrow(lot1_bins_z) > 0) {
          lot1_bins_z$bin_start <- as.numeric(lot1_bins_z$bin_start)
          lot1_bins_z$n <- as.numeric(lot1_bins_z$n)
          lot1_median_z <- tryCatch(
            as.numeric(db_q(con, "SELECT percentile_approx(LOT1_BASE_LENGTH, 0.5) AS m FROM lot1_base WHERE LOT1_BASE_LENGTH IS NOT NULL")$m),
            error = function(e) NA)
          pz2 <- ggplot(lot1_bins_z, aes(x = bin_start, y = n,
                        text = paste0("Days: ", bin_start, "-", bin_start + 29,
                                      "\nPatients: ", format(n, big.mark = ",")))) +
            geom_bar(stat = "identity", width = 28, fill = "#44BBA4", alpha = 0.85) +
            { if (!is.na(lot1_median_z)) geom_vline(xintercept = lot1_median_z,
                       linetype = "dashed", color = "#C73E1D", linewidth = 0.8) } +
            { if (!is.na(lot1_median_z)) annotate("text", x = lot1_median_z + 15, y = Inf, vjust = 2, hjust = 0,
                     label = paste0("Median: ", round(lot1_median_z), "d"),
                     color = "#C73E1D", fontface = "bold", size = 3.8) } +
            scale_x_continuous(breaks = seq(0, max(lot1_bins_z$bin_start, na.rm = TRUE), by = 90)) +
            scale_y_continuous(labels = scales::comma_format(), expand = expansion(mult = c(0, 0.1))) +
            labs(title = "LOT1 Length Distribution (Zoomed to P95)",
                 subtitle = paste0("Clipped at ", round(lot1_p95), " days (95th percentile); ",
                                   format(sum(lot1_bins_z$n), big.mark = ","), " patients shown"),
                 x = "LOT1 Length (days)", y = "Number of Patients") +
            theme_lot()
          save_plot(pz2, "fig06b_lot1_length_zoomed.png",
                   section = "LOT1", title = "Fig 6b: LOT1 Length (Zoomed)")
        }
      }
    }
  }, error = function(e) {
    log_msg("WARN: Zoomed distribution views failed: ", conditionMessage(e))
  })

  # --------------------------------------------------------
  # 9. SCT zero-state card (when no SCT events detected)
  # --------------------------------------------------------
  tryCatch({
    sct_event_n <- tryCatch(
      as.numeric(db_q(con, "SELECT sum(CASE WHEN LOT1_TX_ENDDATE IS NOT NULL THEN 1 ELSE 0 END) AS n FROM lot1_sct")$n),
      error = function(e) 0)
    sct_codes_n <- tryCatch(
      as.numeric(db_q(con, "SELECT count(*) AS n FROM sct_codelist")$n),
      error = function(e) NA)
    sct_raw_n <- tryCatch(
      as.numeric(db_q(con, "SELECT count(*) AS n FROM sct_claims_raw")$n),
      error = function(e) 0)

    if (sct_event_n == 0) {
      sct_html <- paste0('<!DOCTYPE html><html><head><meta charset="UTF-8">
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
         background: #fff; padding: 32px; color: #2d3436; }
  .zero-state { text-align: center; padding: 60px 24px; }
  .zero-state h2 { font-size: 22px; color: #636e72; margin-bottom: 12px; }
  .zero-state p  { font-size: 14px; color: #b2bec3; margin-bottom: 8px; }
  .info-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
               gap: 12px; max-width: 600px; margin: 24px auto 0; }
  .info-card { background: #f5f6fa; border-radius: 8px; padding: 14px;
               border: 1px solid #dfe6e9; text-align: left; }
  .info-card h4 { font-size: 11px; color: #636e72; text-transform: uppercase;
                  letter-spacing: 0.5px; margin-bottom: 4px; }
  .info-card .val { font-size: 18px; font-weight: 700; color: #2d3436; }
</style></head><body>
<div class="zero-state">
  <h2>No LOT-Ending SCT Events</h2>
  <p>No stem cell transplant events ended LOT1 in this run.</p>
  <p>Raw SCT claims may still exist but did not meet LOT-ending criteria. This may be expected if the cohort does not include transplant-eligible patients.</p>
  <div class="info-grid">
    <div class="info-card"><h4>SCT Codes Loaded</h4><div class="val">',
        if (!is.na(sct_codes_n)) format(sct_codes_n, big.mark = ",") else "N/A",
        '</div></div>
    <div class="info-card"><h4>Raw SCT Claims Found</h4><div class="val">',
        format(sct_raw_n, big.mark = ","),
        '</div></div>
    <div class="info-card"><h4>SCT Ending LOT1</h4><div class="val">0</div></div>
  </div>
</div></body></html>')
      add_html_card(sct_html, section = "SCT", title = "SCT Summary")
      log_msg("  SCT zero-state card added.")
    } else {
      # ------- SCT data exists — build populated SCT tab -------
      log_msg("  Building SCT dashboard section (", sct_event_n, " LOT-ending events)...")

      # Query SCT summary stats
      sct_stats <- tryCatch(db_q(con, "
        SELECT
          count(*) AS n_patients,
          sum(CASE WHEN LOT1_TX_AUTO_DT_1 IS NOT NULL THEN 1 ELSE 0 END) AS n_with_auto,
          sum(CASE WHEN FIRST_ALLO_DT IS NOT NULL THEN 1 ELSE 0 END) AS n_with_allo,
          sum(CASE WHEN FIRST_CART_DT IS NOT NULL THEN 1 ELSE 0 END) AS n_with_cart,
          sum(LOT1_SCT_AUTO_TAND_FLG) AS n_tandem,
          sum(LOT1_SCT_AUTO_SING_FLG) AS n_single_auto,
          sum(CASE WHEN LOT1_TX_ENDDATE IS NOT NULL THEN 1 ELSE 0 END) AS n_sct_end
        FROM lot1_sct
      "), error = function(e) data.frame())

      # Query raw claims by type
      sct_raw_by_type <- tryCatch(db_q(con, "
        SELECT SCT_TYPE, count(*) AS n_claims, count(DISTINCT PATID) AS n_patients
        FROM sct_claims_raw
        GROUP BY SCT_TYPE
        ORDER BY SCT_TYPE
      "), error = function(e) data.frame())

      # Query end reasons
      sct_end_reasons <- tryCatch(db_q(con, "
        SELECT
          CASE LOT1_TX_ENDDATE_REASON
            WHEN 1 THEN 'AUTO' WHEN 2 THEN 'ALLO' WHEN 3 THEN 'CART' ELSE 'OTHER'
          END AS SCT_END_TYPE,
          count(*) AS n
        FROM lot1_sct
        WHERE LOT1_TX_ENDDATE IS NOT NULL
        GROUP BY LOT1_TX_ENDDATE_REASON
        ORDER BY LOT1_TX_ENDDATE_REASON
      "), error = function(e) data.frame())

      # Build SCT summary HTML card
      sfmt <- function(x) if (is.null(x) || is.na(x)) "0" else format(as.numeric(x), big.mark = ",")
      spct <- function(x, total) if (is.null(x) || is.na(x) || is.null(total) || is.na(total) || total == 0) "0.0" else sprintf("%.1f", 100 * as.numeric(x) / as.numeric(total))

      n_pat <- if (nrow(sct_stats) > 0) as.numeric(sct_stats$n_patients) else 0

      # Build raw claims rows for the table
      raw_rows <- ""
      if (nrow(sct_raw_by_type) > 0) {
        for (i in seq_len(nrow(sct_raw_by_type))) {
          r <- sct_raw_by_type[i, ]
          raw_rows <- paste0(raw_rows, '<tr><td>', r$SCT_TYPE, '</td><td>',
                             format(as.numeric(r$n_claims), big.mark = ","), '</td><td>',
                             format(as.numeric(r$n_patients), big.mark = ","), '</td></tr>')
        }
      }

      # Build end reason rows
      end_rows <- ""
      if (nrow(sct_end_reasons) > 0) {
        for (i in seq_len(nrow(sct_end_reasons))) {
          r <- sct_end_reasons[i, ]
          end_rows <- paste0(end_rows, '<tr><td>', r$SCT_END_TYPE, '</td><td>',
                             format(as.numeric(r$n), big.mark = ","), '</td></tr>')
        }
      }

      sct_summary_html <- paste0('<!DOCTYPE html><html><head><meta charset="UTF-8">
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
         background: #fff; padding: 24px; color: #2d3436; }
  h2 { font-size: 20px; color: #1a5276; margin-bottom: 16px; }
  h3.section { font-size: 16px; color: #2d3436; margin: 24px 0 12px; border-bottom: 2px solid #dfe6e9; padding-bottom: 6px; }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); gap: 14px; margin-bottom: 24px; }
  .card { background: #f5f6fa; border-radius: 8px; padding: 16px; border: 1px solid #dfe6e9; }
  .card h4 { font-size: 11px; color: #636e72; text-transform: uppercase;
             letter-spacing: 0.5px; margin-bottom: 6px; }
  .card .val { font-size: 24px; font-weight: 700; color: #2d3436; }
  .card .sub { font-size: 12px; color: #636e72; margin-top: 4px; }
  .card.highlight { background: #A23B72; border-color: #A23B72; }
  .card.highlight h4, .card.highlight .val, .card.highlight .sub { color: #fff; }
  table { border-collapse: collapse; width: 100%; margin-top: 8px; margin-bottom: 16px; }
  th, td { text-align: left; padding: 8px 12px; border-bottom: 1px solid #eee; font-size: 13px; }
  th { background: #f5f6fa; font-weight: 600; color: #636e72; text-transform: uppercase;
       letter-spacing: 0.5px; font-size: 11px; }
</style></head><body>
<h2>Stem Cell Transplant (SCT) Summary</h2>
<div class="grid">
  <div class="card highlight"><h4>LOT-Ending SCT</h4><div class="val">', sfmt(sct_event_n), '</div>
    <div class="sub">Patients with SCT ending LOT1</div></div>
  <div class="card"><h4>LOT1 Patients</h4><div class="val">', sfmt(n_pat), '</div></div>
  <div class="card"><h4>With AUTO SCT</h4><div class="val">',
        if (nrow(sct_stats) > 0) sfmt(sct_stats$n_with_auto) else "0", '</div>
    <div class="sub">', if (nrow(sct_stats) > 0) spct(sct_stats$n_with_auto, n_pat) else "0.0", '% of LOT1</div></div>
  <div class="card"><h4>Tandem AUTO</h4><div class="val">',
        if (nrow(sct_stats) > 0) sfmt(sct_stats$n_tandem) else "0", '</div></div>
  <div class="card"><h4>Single AUTO</h4><div class="val">',
        if (nrow(sct_stats) > 0) sfmt(sct_stats$n_single_auto) else "0", '</div></div>
  <div class="card"><h4>With ALLO SCT</h4><div class="val">',
        if (nrow(sct_stats) > 0) sfmt(sct_stats$n_with_allo) else "0", '</div>
    <div class="sub">', if (nrow(sct_stats) > 0) spct(sct_stats$n_with_allo, n_pat) else "0.0", '% of LOT1</div></div>
  <div class="card"><h4>With CAR-T</h4><div class="val">',
        if (nrow(sct_stats) > 0) sfmt(sct_stats$n_with_cart) else "0", '</div>
    <div class="sub">', if (nrow(sct_stats) > 0) spct(sct_stats$n_with_cart, n_pat) else "0.0", '% of LOT1</div></div>
  <div class="card"><h4>Raw SCT Claims</h4><div class="val">', sfmt(sct_raw_n), '</div></div>
  <div class="card"><h4>SCT Codes Loaded</h4><div class="val">',
        if (!is.na(sct_codes_n)) format(sct_codes_n, big.mark = ",") else "N/A", '</div></div>
</div>

<h3 class="section">SCT End Reason Breakdown</h3>
<p style="font-size:13px;color:#636e72;">Which SCT type ended LOT1 for each patient (priority: earliest event)</p>
<table>
<tr><th>SCT Type</th><th>Patients</th></tr>
', end_rows, '
</table>

<h3 class="section">Raw SCT Claims by Type</h3>
<p style="font-size:13px;color:#636e72;">All SCT procedure claims found in the cohort (before LOT-ending logic)</p>
<table>
<tr><th>SCT Type</th><th>Claims</th><th>Patients</th></tr>
', raw_rows, '
</table>
</body></html>')
      add_html_card(sct_summary_html, section = "SCT", title = "SCT Summary")

      # SCT end reason bar chart (if ggplot2 available and data exists)
      if (has_ggplot2 && nrow(sct_end_reasons) > 0) {
        sct_end_reasons$n <- as.numeric(sct_end_reasons$n)
        sct_end_reasons$pct <- 100 * sct_end_reasons$n / sum(sct_end_reasons$n)
        sct_type_colors <- c("AUTO" = "#A23B72", "ALLO" = "#8D5A97",
                             "CART" = "#3F88C5", "OTHER" = "#636e72")
        p_sct <- ggplot(sct_end_reasons,
                         aes(x = reorder(SCT_END_TYPE, -n), y = n,
                             fill = SCT_END_TYPE,
                             text = paste0("Type: ", SCT_END_TYPE,
                                           "\nPatients: ", format(n, big.mark = ","),
                                           "\n%: ", round(pct, 1), "%"))) +
          geom_bar(stat = "identity", width = 0.65) +
          geom_text(aes(label = paste0(format(n, big.mark = ","), "\n(", round(pct, 1), "%)")),
                    vjust = -0.3, size = 3.8, color = "grey20") +
          scale_fill_manual(values = sct_type_colors) +
          scale_y_continuous(labels = scales::comma_format(), expand = expansion(mult = c(0, 0.2))) +
          labs(title = "LOT1 SCT End Reasons by Type",
               subtitle = paste0(format(sum(sct_end_reasons$n), big.mark = ","),
                                 " patients with SCT ending LOT1"),
               x = NULL, y = "Number of Patients") +
          theme_lot() +
          theme(legend.position = "none")
        save_plot(p_sct, "fig_sct_end_reasons.png", width = 7, height = 5,
                 section = "SCT", title = "Fig: SCT End Reasons")
      }

      # SCT details table: patient-level SCT data
      sct_detail <- tryCatch(db_q(con, "
        SELECT
          CASE LOT1_TX_ENDDATE_REASON
            WHEN 1 THEN 'AUTO' WHEN 2 THEN 'ALLO' WHEN 3 THEN 'CART' ELSE 'NONE'
          END AS END_REASON,
          LOT1_SCT_AUTO_TAND_FLG AS TANDEM,
          LOT1_SCT_AUTO_SING_FLG AS SINGLE_AUTO,
          LOT1_TX_AUTO_DT_1 AS AUTO_DT_1,
          LOT1_TX_AUTO_DT_2 AS AUTO_DT_2,
          FIRST_ALLO_DT,
          FIRST_CART_DT,
          LOT1_TX_ENDDATE AS SCT_END_DT,
          LOT1_1ST_SCT_DT AS FIRST_SCT_DT
        FROM lot1_sct
        WHERE LOT1_TX_ENDDATE IS NOT NULL
           OR LOT1_TX_AUTO_DT_1 IS NOT NULL
           OR FIRST_ALLO_DT IS NOT NULL
           OR FIRST_CART_DT IS NOT NULL
        ORDER BY LOT1_TX_ENDDATE_REASON, LOT1_TX_ENDDATE
      "), error = function(e) data.frame())
      if (nrow(sct_detail) > 0) {
        save_table(sct_detail, section = "SCT",
                   title = "Table: SCT Patient Details")
      }

      log_msg("  SCT dashboard section built with ", sct_event_n, " LOT-ending events.")
    }
  }, error = function(e) {
    log_msg("WARN: SCT zero-state card failed: ", conditionMessage(e))
  })

  # --------------------------------------------------------
  # 10. Sankey / alluvial flow: Regimen -> Med Count -> End Reason
  # --------------------------------------------------------
  tryCatch({
    if (has_plotly) {
      flow_data <- db_q(con, "
        SELECT
          CASE
            WHEN lb.LOT1_BASE_MEDS IN ('BORT LENA', 'BORT', 'LENA', 'BORT DARA LENA',
                                     'BORT CYCL', 'DARA LENA', 'BORT DARA',
                                     'CARF LENA', 'BORT CYCL DARA LENA', 'DARA')
            THEN lb.LOT1_BASE_MEDS
            ELSE 'OTHER'
          END AS regimen,
          CAST(lb.LOT1_MED_CNT AS STRING) AS med_count,
          lbe.LOT1_BASE_END_REASON AS end_reason,
          count(*) AS n
        FROM lot1_base lb
        INNER JOIN lot1_base_end lbe ON lb.PATID = lbe.PATID
        GROUP BY 1, 2, 3
        ORDER BY n DESC
      ")

      if (nrow(flow_data) > 0) {
        flow_data$n <- as.numeric(flow_data$n)

        # Build Sankey node/link structure
        regimens_u <- sort(unique(flow_data$regimen))
        medcnts_u  <- sort(unique(flow_data$med_count))
        reasons_u  <- sort(unique(flow_data$end_reason))

        # Node labels: regimen nodes, then med_count nodes, then end_reason nodes
        node_labels <- c(regimens_u,
                        paste0(medcnts_u, " med(s)"),
                        reasons_u)

        n_reg <- length(regimens_u)
        n_mc  <- length(medcnts_u)

        reg_idx <- setNames(seq_along(regimens_u) - 1, regimens_u)
        mc_idx  <- setNames(seq_along(medcnts_u) - 1 + n_reg, medcnts_u)
        er_idx  <- setNames(seq_along(reasons_u) - 1 + n_reg + n_mc, reasons_u)

        # Links: regimen -> med_count
        link1 <- aggregate(n ~ regimen + med_count, data = flow_data, FUN = sum)
        # Links: med_count -> end_reason
        link2 <- aggregate(n ~ med_count + end_reason, data = flow_data, FUN = sum)

        sources <- c(reg_idx[link1$regimen], mc_idx[link2$med_count])
        targets <- c(mc_idx[link1$med_count], er_idx[link2$end_reason])
        values  <- c(link1$n, link2$n)

        # Color nodes by type
        reg_colors <- rep("#2E86AB", n_reg)
        mc_colors  <- rep("#44BBA4", n_mc)
        er_colors  <- sapply(reasons_u, function(r) {
          switch(r, DISCONTINUATION = "#C73E1D", MED_ADD = "#F18F01",
                 CENSORED = "#2E86AB", SCT_AUTO = "#A23B72",
                 SCT_ALLO = "#8D5A97", SCT_CART = "#3F88C5", "#636e72")
        })
        node_colors <- c(reg_colors, mc_colors, er_colors)

        # Link colors — semi-transparent version of source node
        hex_to_rgba <- function(hex, alpha = 0.3) {
          r <- strtoi(substr(hex, 2, 3), 16)
          g <- strtoi(substr(hex, 4, 5), 16)
          b <- strtoi(substr(hex, 6, 7), 16)
          sprintf("rgba(%d,%d,%d,%.1f)", r, g, b, alpha)
        }
        link_colors <- sapply(sources + 1, function(i) hex_to_rgba(node_colors[i]))

        ps <- plotly::plot_ly(
          type = "sankey",
          orientation = "h",
          node = list(
            pad = 15, thickness = 20,
            line = list(color = "black", width = 0.5),
            label = node_labels,
            color = node_colors
          ),
          link = list(
            source = as.integer(sources),
            target = as.integer(targets),
            value = as.numeric(values),
            color = link_colors
          )
        ) |>
          plotly::layout(
            title = list(text = "Patient Flow: Regimen → Med Count → End Reason",
                         font = list(size = 16)),
            font = list(size = 11),
            margin = list(l = 20, r = 20, t = 50, b = 30)
          ) |>
          plotly::config(displayModeBar = TRUE, displaylogo = FALSE)

        add_to_dashboard(ps, section = "LOT1", title = "Fig 9: Patient Flow (Sankey)")
        log_msg("  Sankey flow chart added.")
      }
    }
  }, error = function(e) {
    log_msg("WARN: Sankey flow chart failed: ", conditionMessage(e))
  })

  # --------------------------------------------------------
  # 11. CYCLO Monotherapy Deep-Dive (separate output files)
  # Writes to {output_dir}/cyclo_mono/ as standalone CSVs.
  #
  # Two cohort definitions produced:
  #   STRICT:           LOT1_BASE_MEDS = 'CYCL', LOT1_MED_CNT = 1
  #   STEROID-TOLERANT: only non-steroid induction med is CYCLO
  #                     (allows CYCLO + DEXA/PRED etc.)
  #
  # Outputs:
  # (1) 3 possible diagnosis dates under 30/60/90-day OP windows
  # (2) subsequent non-CYCLO non-steroid MM treatments
  # (3) SCT timing relative to CYCLO start AND all 3 dx dates
  # --------------------------------------------------------
  tryCatch({
    # --- Cohort A: Strict CYCLO monotherapy (no steroids) ---
    cyclo_strict <- db_q(con, "
      SELECT lb.PATID, lb.INDEX_DATE, lb.LOT1_START_DT, lb.LOT1_BASE_MEDS,
             lb.LOT1_BASE_DISCON_DT, lb.LOT1_BASE_LENGTH, lb.LOT1_MED_CNT,
             lb.OBS_END_DT, lb.DEATH_DT, lb.GDR_CD, lb.AGE_INDEX_YR,
             'STRICT' AS COHORT_DEF
      FROM lot1_base lb
      WHERE lb.LOT1_BASE_MEDS = 'CYCL'
        AND lb.LOT1_MED_CNT = 1
    ")

    # --- Cohort B: Steroid-tolerant CYCLO monotherapy ---
    # Only non-steroid induction med is CYCLO (steroids allowed alongside)
    cyclo_steroid_tol <- db_q(con, glue("
      WITH induction_meds AS (
        SELECT DISTINCT
          ms.PATID,
          ms.MAP_MED_TYPE AS MED_ABBR,
          ms.MAP_MED_CLASS AS MED_CLASS
        FROM map_stacked ms
        INNER JOIN lot1_start l1 ON ms.PATID = l1.PATID
        WHERE ms.MAP_START_DT >= l1.LOT1_START_DT
          AND ms.MAP_START_DT <= date_add(l1.LOT1_START_DT, {cfg$induction_window_days - 1})
      ),
      non_steroid_summary AS (
        SELECT
          PATID,
          count(DISTINCT CASE WHEN MED_CLASS <> 'STEROID' THEN MED_ABBR END) AS N_NONSTEROID,
          max(CASE WHEN MED_CLASS <> 'STEROID' AND MED_ABBR = 'CYCL' THEN 1 ELSE 0 END) AS HAS_CYCLO
        FROM induction_meds
        GROUP BY PATID
      )
      SELECT lb.PATID, lb.INDEX_DATE, lb.LOT1_START_DT, lb.LOT1_BASE_MEDS,
             lb.LOT1_BASE_DISCON_DT, lb.LOT1_BASE_LENGTH, lb.LOT1_MED_CNT,
             lb.OBS_END_DT, lb.DEATH_DT, lb.GDR_CD, lb.AGE_INDEX_YR,
             'STEROID_TOLERANT' AS COHORT_DEF
      FROM lot1_base lb
      INNER JOIN non_steroid_summary ns ON lb.PATID = ns.PATID
      WHERE ns.N_NONSTEROID = 1
        AND ns.HAS_CYCLO = 1
    "))

    n_strict  <- nrow(cyclo_strict)
    n_steroid <- nrow(cyclo_steroid_tol)
    log_msg("  CYCLO monotherapy — strict: ", n_strict,
            ", steroid-tolerant: ", n_steroid,
            " (delta: ", n_steroid - n_strict, " patients with CYCLO + steroid)")

    # Use steroid-tolerant as the primary cohort (most common clinical interpretation)
    cyclo_pats <- cyclo_steroid_tol
    n_cyclo    <- n_steroid

    if (n_cyclo > 0) {
      cyclo_dir <- file.path(cfg$output_dir, "cyclo_mono")
      dir.create(cyclo_dir, showWarnings = FALSE, recursive = TRUE)

      # Write both rosters
      write.csv(cyclo_strict, file.path(cyclo_dir, "cyclo_mono_patients_strict.csv"), row.names = FALSE)
      write.csv(cyclo_steroid_tol, file.path(cyclo_dir, "cyclo_mono_patients_steroid_tolerant.csv"), row.names = FALSE)
      log_msg("  Wrote: cyclo_mono_patients_strict.csv (N=", n_strict,
              "), cyclo_mono_patients_steroid_tolerant.csv (N=", n_steroid, ")")

      pat_ids_sql <- paste0("('", paste(cyclo_pats$PATID, collapse = "','"), "')")

      # --- (1) Three possible diagnosis dates (30/60/90-day OP windows) ---
      allflags_tbl <- tryCatch({
        tbl_name <- wrk("ELIG_COH_ALLFLAGS")
        test <- db_q(con, glue("SELECT 1 FROM {tbl_name} LIMIT 1"))
        tbl_name
      }, error = function(e) NULL)

      if (!is.null(allflags_tbl)) {
        dx_dates <- db_q(con, glue("
          WITH window_dates AS (
            SELECT
              af.PATID,
              min(CASE WHEN af.inpt_qual = 1 OR af.outpt2_30 = 1
                       THEN af.INDEX_DATE END) AS DX_DT_30,
              min(CASE WHEN af.inpt_qual = 1 OR af.outpt2_60 = 1
                       THEN af.INDEX_DATE END) AS DX_DT_60,
              min(CASE WHEN af.inpt_qual = 1 OR af.outpt2_90 = 1
                       THEN af.INDEX_DATE END) AS DX_DT_90
            FROM {allflags_tbl} af
            WHERE af.PATID IN {pat_ids_sql}
            GROUP BY af.PATID
          ),
          with_lot1 AS (
            SELECT
              w.PATID,
              lb.LOT1_START_DT AS CYCLO_START_DT,
              w.DX_DT_30,
              w.DX_DT_60,
              w.DX_DT_90,
              datediff(lb.LOT1_START_DT, w.DX_DT_30) AS DAYS_DX30_TO_CYCLO,
              datediff(lb.LOT1_START_DT, w.DX_DT_60) AS DAYS_DX60_TO_CYCLO,
              datediff(lb.LOT1_START_DT, w.DX_DT_90) AS DAYS_DX90_TO_CYCLO,
              datediff(w.DX_DT_60, w.DX_DT_30) AS DIFF_60v30,
              datediff(w.DX_DT_90, w.DX_DT_30) AS DIFF_90v30
            FROM window_dates w
            INNER JOIN lot1_base lb ON w.PATID = lb.PATID
          )
          SELECT * FROM with_lot1 ORDER BY PATID
        "))

        if (nrow(dx_dates) > 0) {
          write.csv(dx_dates, file.path(cyclo_dir, "cyclo_mono_dx_dates.csv"), row.names = FALSE)

          # Summary stats
          n_same_all   <- sum(!is.na(dx_dates$DX_DT_30) & !is.na(dx_dates$DX_DT_90) &
                              dx_dates$DX_DT_30 == dx_dates$DX_DT_90, na.rm = TRUE)
          n_diff_30v90 <- sum(!is.na(dx_dates$DIFF_90v30) & dx_dates$DIFF_90v30 != 0, na.rm = TRUE)
          n_only_90    <- sum(is.na(dx_dates$DX_DT_30) & !is.na(dx_dates$DX_DT_90), na.rm = TRUE)
          n_only_60    <- sum(is.na(dx_dates$DX_DT_30) & !is.na(dx_dates$DX_DT_60), na.rm = TRUE)

          dx_summary <- data.frame(
            Metric = c("Total CYCLO mono patients (steroid-tolerant)",
                        "Same dx date under all windows",
                        "Different date: 30d vs 90d window",
                        "Qualify under 90d but NOT 30d",
                        "Qualify under 60d but NOT 30d"),
            N = c(n_cyclo, n_same_all, n_diff_30v90, n_only_90, n_only_60),
            stringsAsFactors = FALSE
          )
          if (any(!is.na(dx_dates$DIFF_90v30) & dx_dates$DIFF_90v30 != 0)) {
            shifted <- dx_dates[!is.na(dx_dates$DIFF_90v30) & dx_dates$DIFF_90v30 != 0, ]
            dx_summary <- rbind(dx_summary, data.frame(
              Metric = c("Mean shift 90d vs 30d (days)",
                          "Median shift 90d vs 30d (days)"),
              N = c(round(mean(as.numeric(shifted$DIFF_90v30), na.rm = TRUE), 1),
                    round(median(as.numeric(shifted$DIFF_90v30), na.rm = TRUE), 0)),
              stringsAsFactors = FALSE
            ))
          }
          write.csv(dx_summary, file.path(cyclo_dir, "cyclo_mono_dx_summary.csv"), row.names = FALSE)
          log_msg("  Wrote: cyclo_mono_dx_dates.csv, cyclo_mono_dx_summary.csv")
        }
      } else {
        log_msg("  WARN: ELIG_COH_ALLFLAGS not found; skipping diagnosis date sensitivity.")
      }

      # --- (2) Subsequent MM treatments post-CYCLO initiation ---
      # Excludes both CYCLO itself and steroids (non-anti-MM supportive)
      post_cyclo_tx <- db_q(con, glue("
        SELECT
          ms.PATID,
          ms.MAP_MED_TYPE AS MED,
          ms.MAP_MED_CLASS AS CLASS,
          ms.MAP_START_DT,
          ms.MAP_END_DT,
          datediff(ms.MAP_END_DT, ms.MAP_START_DT) + 1 AS MAP_DAYS,
          lb.LOT1_START_DT AS CYCLO_START_DT,
          datediff(ms.MAP_START_DT, lb.LOT1_START_DT) AS DAYS_FROM_CYCLO_START,
          ms.MAP_CNT
        FROM map_stacked ms
        INNER JOIN lot1_base lb
          ON ms.PATID = lb.PATID
        WHERE lb.PATID IN {pat_ids_sql}
          AND ms.MAP_MED_TYPE <> 'CYCL'
          AND ms.MAP_MED_CLASS <> 'STEROID'
          AND ms.MAP_START_DT > lb.LOT1_START_DT
        ORDER BY ms.PATID, ms.MAP_START_DT
      "))

      if (nrow(post_cyclo_tx) > 0) {
        write.csv(post_cyclo_tx, file.path(cyclo_dir, "cyclo_mono_subsequent_tx_detail.csv"), row.names = FALSE)

        post_tx_summary <- db_q(con, glue("
          WITH post AS (
            SELECT
              ms.PATID, ms.MAP_MED_TYPE AS MED, ms.MAP_MED_CLASS AS CLASS,
              min(ms.MAP_START_DT) AS FIRST_TX_START_DT,
              datediff(min(ms.MAP_START_DT), lb.LOT1_START_DT) AS DAYS_FROM_CYCLO
            FROM map_stacked ms
            INNER JOIN lot1_base lb ON ms.PATID = lb.PATID
            WHERE lb.PATID IN {pat_ids_sql}
              AND ms.MAP_MED_TYPE <> 'CYCL'
              AND ms.MAP_MED_CLASS <> 'STEROID'
              AND ms.MAP_START_DT > lb.LOT1_START_DT
            GROUP BY ms.PATID, ms.MAP_MED_TYPE, ms.MAP_MED_CLASS, lb.LOT1_START_DT
          )
          SELECT MED, CLASS,
                 count(DISTINCT PATID) AS n_patients,
                 avg(DAYS_FROM_CYCLO) AS avg_days_from_cyclo,
                 min(DAYS_FROM_CYCLO) AS min_days,
                 percentile_approx(DAYS_FROM_CYCLO, 0.25) AS p25_days,
                 percentile_approx(DAYS_FROM_CYCLO, 0.5) AS median_days,
                 percentile_approx(DAYS_FROM_CYCLO, 0.75) AS p75_days,
                 max(DAYS_FROM_CYCLO) AS max_days
          FROM post
          GROUP BY MED, CLASS
          ORDER BY count(DISTINCT PATID) DESC
        "))
        write.csv(post_tx_summary, file.path(cyclo_dir, "cyclo_mono_subsequent_tx_summary.csv"), row.names = FALSE)
        log_msg("  Wrote: cyclo_mono_subsequent_tx_detail.csv, cyclo_mono_subsequent_tx_summary.csv")
      } else {
        log_msg("  No subsequent (non-CYCLO, non-steroid) treatments found.")
      }

      # --- (3) SCT timing relative to CYCLO start AND all 3 dx dates ---
      # Build SCT query; if allflags available, include DX_DT_30/60/90 offsets
      sct_dx_cols <- ""
      sct_dx_join <- ""
      if (!is.null(allflags_tbl)) {
        sct_dx_join <- glue("
          LEFT JOIN (
            SELECT PATID,
              min(CASE WHEN inpt_qual = 1 OR outpt2_30 = 1 THEN INDEX_DATE END) AS DX_DT_30,
              min(CASE WHEN inpt_qual = 1 OR outpt2_60 = 1 THEN INDEX_DATE END) AS DX_DT_60,
              min(CASE WHEN inpt_qual = 1 OR outpt2_90 = 1 THEN INDEX_DATE END) AS DX_DT_90
            FROM {allflags_tbl}
            WHERE PATID IN {pat_ids_sql}
            GROUP BY PATID
          ) dx ON sct.PATID = dx.PATID")
        sct_dx_cols <- ",
          dx.DX_DT_30, dx.DX_DT_60, dx.DX_DT_90,
          CASE WHEN sct.LOT1_1ST_SCT_DT IS NOT NULL
            THEN datediff(sct.LOT1_1ST_SCT_DT, dx.DX_DT_30) END AS DAYS_DX30_TO_SCT,
          CASE WHEN sct.LOT1_1ST_SCT_DT IS NOT NULL
            THEN datediff(sct.LOT1_1ST_SCT_DT, dx.DX_DT_60) END AS DAYS_DX60_TO_SCT,
          CASE WHEN sct.LOT1_1ST_SCT_DT IS NOT NULL
            THEN datediff(sct.LOT1_1ST_SCT_DT, dx.DX_DT_90) END AS DAYS_DX90_TO_SCT"
      }

      cyclo_sct <- db_q(con, glue("
        SELECT
          sct.PATID,
          lb.LOT1_START_DT AS CYCLO_START_DT,
          sct.LOT1_TX_AUTO_DT_1,
          sct.LOT1_TX_AUTO_DT_2,
          sct.FIRST_ALLO_DT,
          sct.FIRST_CART_DT,
          sct.LOT1_1ST_SCT_DT,
          sct.LOT1_TX_ENDDATE,
          sct.LOT1_TX_ENDDATE_REASON,
          sct.LOT1_SCT_AUTO_TAND_FLG,
          sct.LOT1_SCT_AUTO_SING_FLG,
          CASE WHEN sct.LOT1_1ST_SCT_DT IS NOT NULL
            THEN datediff(sct.LOT1_1ST_SCT_DT, lb.LOT1_START_DT)
          END AS DAYS_CYCLO_TO_SCT
          {sct_dx_cols}
        FROM lot1_sct sct
        INNER JOIN lot1_base lb ON sct.PATID = lb.PATID
        {sct_dx_join}
        WHERE lb.PATID IN {pat_ids_sql}
        ORDER BY sct.PATID
      "))

      n_with_sct <- sum(!is.na(cyclo_sct$LOT1_1ST_SCT_DT))
      log_msg("  CYCLO patients with SCT: ", n_with_sct, " / ", n_cyclo)

      write.csv(cyclo_sct, file.path(cyclo_dir, "cyclo_mono_sct_detail.csv"), row.names = FALSE)

      # SCT summary
      sct_summary <- data.frame(
        Metric = c("Total CYCLO mono patients (steroid-tolerant)",
                    "With any SCT", "Pct with SCT"),
        Value = c(n_cyclo, n_with_sct, paste0(round(100 * n_with_sct / n_cyclo, 1), "%")),
        stringsAsFactors = FALSE
      )
      if (n_with_sct > 0) {
        sct_with <- cyclo_sct[!is.na(cyclo_sct$LOT1_1ST_SCT_DT), ]
        n_auto <- sum(!is.na(sct_with$LOT1_TX_AUTO_DT_1))
        n_allo <- sum(!is.na(sct_with$FIRST_ALLO_DT))
        n_cart <- sum(!is.na(sct_with$FIRST_CART_DT))
        n_tand <- sum(sct_with$LOT1_SCT_AUTO_TAND_FLG == 1, na.rm = TRUE)
        sct_summary <- rbind(sct_summary, data.frame(
          Metric = c("AUTO SCT", "ALLO SCT", "CART", "Tandem AUTO",
                      "Mean days CYCLO start -> 1st SCT",
                      "Median days CYCLO start -> 1st SCT"),
          Value = c(n_auto, n_allo, n_cart, n_tand,
                    round(mean(as.numeric(sct_with$DAYS_CYCLO_TO_SCT), na.rm = TRUE), 1),
                    round(median(as.numeric(sct_with$DAYS_CYCLO_TO_SCT), na.rm = TRUE), 0)),
          stringsAsFactors = FALSE
        ))
        # Add per-window dx-to-SCT timing if available
        if ("DAYS_DX30_TO_SCT" %in% names(sct_with)) {
          sct_summary <- rbind(sct_summary, data.frame(
            Metric = c("Mean days Dx(30d) -> 1st SCT",
                        "Median days Dx(30d) -> 1st SCT",
                        "Mean days Dx(60d) -> 1st SCT",
                        "Median days Dx(60d) -> 1st SCT",
                        "Mean days Dx(90d) -> 1st SCT",
                        "Median days Dx(90d) -> 1st SCT"),
            Value = c(round(mean(as.numeric(sct_with$DAYS_DX30_TO_SCT), na.rm = TRUE), 1),
                      round(median(as.numeric(sct_with$DAYS_DX30_TO_SCT), na.rm = TRUE), 0),
                      round(mean(as.numeric(sct_with$DAYS_DX60_TO_SCT), na.rm = TRUE), 1),
                      round(median(as.numeric(sct_with$DAYS_DX60_TO_SCT), na.rm = TRUE), 0),
                      round(mean(as.numeric(sct_with$DAYS_DX90_TO_SCT), na.rm = TRUE), 1),
                      round(median(as.numeric(sct_with$DAYS_DX90_TO_SCT), na.rm = TRUE), 0)),
            stringsAsFactors = FALSE
          ))
        }
      }
      write.csv(sct_summary, file.path(cyclo_dir, "cyclo_mono_sct_summary.csv"), row.names = FALSE)
      log_msg("  Wrote: cyclo_mono_sct_detail.csv, cyclo_mono_sct_summary.csv")
      log_msg("  CYCLO monotherapy output directory: ", cyclo_dir)
    } else {
      log_msg("  No CYCLO monotherapy patients found in LOT1 (either definition).")
    }
  }, error = function(e) {
    log_msg("WARN: CYCLO monotherapy analysis failed: ", conditionMessage(e))
  })

  # Build combined interactive dashboard
  build_dashboard()
}

# ============================================================
# MAIN
# ============================================================
main <- function() {
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")

  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  log_msg("Connected. Run ID: ", run_id)
  log_msg("Configuration:")
  log_msg("  CDM Schema:        ", cfg$cdm_schema)
  log_msg("  Work Schema:       ", cfg$work_schema)
  log_msg("  Input Cohort:      ", cfg$input_cohort_table)
  log_msg("  Induction Window:  ", cfg$induction_window_days, " days")
  log_msg("  MAP Discon Gap:    ", cfg$map_discon_gap_days, " days")
  log_msg("  Medical Day Supply: ", cfg$medical_day_supply, " days")
  log_msg("  LOT Discon Gap:    ", cfg$lot_discon_gap_days, " days")

  # ----------------------------------------------------------
  # STEP 0: Register code lists as TEMP views
  # ----------------------------------------------------------
  rollup_src <- get_code_source(
    embedded_fn = embedded_mma_rollup,
    external_tbl = cfg$cl_mma_rollup_tbl,
    csv_name = "cl_mma_rollup.csv",
    col_spec = c("CL_MEDICATION_FULL", "CL_MED_CLASS", "CL_MED_ABBR",
                 "MONOMAINTENANCE", "DUALMAINTENANCEWITH", "CONDITIONING", "USED_FOR_OTHER_CANCERS")
  )

  codelist_src <- get_code_source(
    embedded_fn = embedded_mma_codelist,
    external_tbl = cfg$cl_mma_codelist_tbl,
    csv_name = "cl_mma_codelist.csv",
    col_spec = c("CL_CODE_TYPE", "CL_CODE", "CL_MEDICATION_FULL", "CL_MED_CLASS", "CL_MED_ABBR")
  )

  subs_src <- get_code_source(
    embedded_fn = embedded_permissible_subs,
    external_tbl = cfg$permissible_subs_tbl,
    csv_name = "permissible_subs.csv",
    col_spec = c("original_med", "substitute_med")
  )

  sct_src <- get_code_source(
    embedded_fn = embedded_sct_codelist,
    external_tbl = cfg$cl_sct_codelist_tbl,
    csv_name = "cl_sct_codelist.csv",
    col_spec = c("CL_CODE_TYPE", "CL_CODE", "SCT_TYPE")
  )

  run_step(con, "S00_mma_rollup", glue("
    CREATE OR REPLACE TEMPORARY VIEW mma_rollup AS
    SELECT
      lower(trim(CL_MEDICATION_FULL)) AS CL_MEDICATION_FULL,
      upper(trim(CL_MED_CLASS))       AS CL_MED_CLASS,
      upper(trim(CL_MED_ABBR))        AS CL_MED_ABBR,
      -- Tab 40 fields can be 'YES', 'YES mainly...', 1, 0, or NULL.
      -- Robust parsing: treat 'YES%' or '1' as 1, everything else as 0.
      CASE WHEN upper(trim(cast(MONOMAINTENANCE AS string))) LIKE 'YES%'
            OR  trim(cast(MONOMAINTENANCE AS string)) = '1'
           THEN 1 ELSE 0 END AS MONOMAINTENANCE,
      CASE
        WHEN DUALMAINTENANCEWITH IS NULL
          OR upper(trim(cast(DUALMAINTENANCEWITH AS string))) IN ('', 'NULL', 'NONE', 'NA', 'N/A')
          THEN NULL
        ELSE upper(trim(cast(DUALMAINTENANCEWITH AS string)))
      END AS DUALMAINTENANCEWITH,
      CASE WHEN upper(trim(cast(CONDITIONING AS string))) LIKE 'YES%'
            OR  trim(cast(CONDITIONING AS string)) = '1'
           THEN 1 ELSE 0 END AS CONDITIONING,
      CASE WHEN upper(trim(cast(USED_FOR_OTHER_CANCERS AS string))) LIKE 'YES%'
            OR  trim(cast(USED_FOR_OTHER_CANCERS AS string)) = '1'
           THEN 1 ELSE 0 END AS USED_FOR_OTHER_CANCERS
    FROM {rollup_src}
  "), qc = "SELECT count(*) AS n_rows, count(DISTINCT CL_MED_ABBR) AS n_meds,
            sum(MONOMAINTENANCE) AS n_monomaint, sum(CONDITIONING) AS n_conditioning,
            sum(USED_FOR_OTHER_CANCERS) AS n_other_cancer FROM mma_rollup")

  run_step(con, "S01_mma_codelist", glue("
    CREATE OR REPLACE TEMPORARY VIEW mma_codelist AS
    SELECT
      upper(trim(CL_CODE_TYPE)) AS CL_CODE_TYPE,
      upper(regexp_replace(trim(CL_CODE), '[^A-Za-z0-9]', '')) AS CL_CODE,
      lower(trim(CL_MEDICATION_FULL)) AS CL_MEDICATION_FULL,
      upper(trim(CL_MED_CLASS))       AS CL_MED_CLASS,
      upper(trim(CL_MED_ABBR))        AS CL_MED_ABBR
    FROM {codelist_src}
    WHERE CL_CODE IS NOT NULL AND trim(CL_CODE) <> ''
      AND CL_CODE_TYPE IS NOT NULL AND trim(CL_CODE_TYPE) <> ''
  "), qc = "SELECT count(*) AS n_rows, count(DISTINCT CL_MED_ABBR) AS n_meds, count(DISTINCT CL_CODE_TYPE) AS n_code_types FROM mma_codelist")

  run_step(con, "S02_permissible_subs", glue("
    CREATE OR REPLACE TEMPORARY VIEW permissible_subs AS
    SELECT
      upper(trim(original_med))   AS original_med,
      upper(trim(substitute_med)) AS substitute_med
    FROM {subs_src}
    WHERE original_med IS NOT NULL AND substitute_med IS NOT NULL
  "), qc = "SELECT count(*) AS n_rows, count(DISTINCT original_med) AS n_orig_meds FROM permissible_subs")

  # ----------------------------------------------------------
  # Codelist <-> Rollup consistency QC
  # ----------------------------------------------------------
  log_msg("Checking codelist <-> rollup consistency...")
  tryCatch({
    # Codelist meds not in rollup (will be missing class/flag info)
    orphan_meds <- db_q(con, "
      SELECT c.CL_MED_ABBR, count(*) AS n_codes
      FROM mma_codelist c
      LEFT JOIN mma_rollup r ON c.CL_MED_ABBR = r.CL_MED_ABBR
      WHERE r.CL_MED_ABBR IS NULL
      GROUP BY c.CL_MED_ABBR
      ORDER BY n_codes DESC
    ")
    if (nrow(orphan_meds) > 0) {
      log_msg("  WARNING: Codelist meds NOT in rollup (will have NULL class/flags):")
      print(orphan_meds)
    } else {
      log_msg("  OK: All codelist meds found in rollup.")
    }

    # Reverse check: rollup meds with ZERO codes in codelist (therapy would be
    # completely undetectable — silent drop of an entire medication)
    uncoded_meds <- db_q(con, "
      SELECT r.CL_MED_ABBR, r.CL_MED_CLASS
      FROM mma_rollup r
      LEFT JOIN mma_codelist c ON r.CL_MED_ABBR = c.CL_MED_ABBR
      WHERE c.CL_MED_ABBR IS NULL
      ORDER BY r.CL_MED_CLASS, r.CL_MED_ABBR
    ")
    if (nrow(uncoded_meds) > 0) {
      log_msg("  WARNING: Rollup meds with ZERO codes in codelist (will never be extracted!):")
      print(uncoded_meds)
    } else {
      log_msg("  OK: All rollup meds have at least one code in codelist.")
    }

    # Validate CL_CODE_TYPE values are exactly the expected set
    code_types <- db_q(con, "
      SELECT CL_CODE_TYPE, count(*) AS n_codes
      FROM mma_codelist
      GROUP BY CL_CODE_TYPE
      ORDER BY CL_CODE_TYPE
    ")
    log_msg("  Code type distribution in codelist:")
    print(code_types)
    unexpected_types <- setdiff(code_types$CL_CODE_TYPE, c("NDC", "HCPCS", "ICD"))
    if (length(unexpected_types) > 0) {
      log_msg("  WARNING: Unexpected CL_CODE_TYPE values: ", paste(unexpected_types, collapse = ", "))
      log_msg("  These codes will NOT be matched by the extraction logic!")
    }

    # MED_ABBR mapping to >1 class (min() will hide this)
    multi_class <- db_q(con, "
      SELECT CL_MED_ABBR, count(DISTINCT CL_MED_CLASS) AS n_classes,
             concat_ws(', ', collect_set(CL_MED_CLASS)) AS classes
      FROM mma_codelist
      GROUP BY CL_MED_ABBR
      HAVING count(DISTINCT CL_MED_CLASS) > 1
    ")
    if (nrow(multi_class) > 0) {
      log_msg("  WARNING: MED_ABBR maps to multiple classes (min() will pick one):")
      print(multi_class)
    } else {
      log_msg("  OK: Each MED_ABBR maps to exactly one class.")
    }
  }, error = function(e) {
    log_msg("  WARNING: Codelist consistency QC failed: ", e$message)
  })

  # Fetch med/class lists for dynamic flag generation
  meds <- db_q(con, "SELECT DISTINCT CL_MED_ABBR FROM mma_rollup ORDER BY CL_MED_ABBR")$CL_MED_ABBR
  classes <- db_q(con, "SELECT DISTINCT CL_MED_CLASS FROM mma_rollup ORDER BY CL_MED_CLASS")$CL_MED_CLASS
  if (length(meds) == 0) stop("mma_rollup has 0 medications after load/clean.")
  if (length(classes) == 0) stop("mma_rollup has 0 classes after load/clean.")
  log_msg("Rollup meds: ", paste(meds, collapse = ", "))
  log_msg("Rollup classes: ", paste(classes, collapse = ", "))

  # Dynamic flag expressions
  # Sanitize both med abbreviations and class names for safe SQL column names
  sanitize_col <- function(x) gsub("[^A-Za-z0-9]+", "_", toupper(x))
  med_flag_exprs <- paste0(
    vapply(meds, function(m) glue("max(case when im.MED_ABBR = '{m}' then 1 else 0 end) as LOT1_MED_{sanitize_col(m)}"), character(1)),
    collapse = ",\n      "
  )
  sanitize_class <- sanitize_col  # alias for backward compatibility
  class_flag_exprs <- paste0(
    vapply(classes, function(cl) glue("max(case when im.MED_CLASS = '{cl}' then 1 else 0 end) as LOT1_CLASS_{sanitize_class(cl)}"), character(1)),
    collapse = ",\n      "
  )

  # ----------------------------------------------------------
  # STEP 1: Load Part 1 cohort
  # ----------------------------------------------------------
  # OBS_END_DT = observable follow-up end = min(study_end, death, disenrollment)
  # This is ENDDATE_CE from Part 1, NOT ENDDATE (which ignores disenrollment).
  # Using ENDDATE would create fake follow-up after disenrollment, causing:
  #   - false "confirmed" discontinuations (appear to have 90 days post-runout)
  #   - detecting add-meds/claims during unobservable periods
  run_step(con, "S03_patient_input", glue("
    CREATE OR REPLACE TEMPORARY VIEW lot_patient_input AS
    SELECT
      PATID,
      cast(INDEX_DATE AS date) AS INDEX_DATE,
      cast(ENDDATE AS date)    AS ENDDATE,
      cast(ENDDATE_CE AS date) AS ENDDATE_CE,
      -- OBS_END_DT: canonical observation end for all LOT/MAP logic
      -- Prefers ENDDATE_CE (accounts for disenrollment); falls back to ENDDATE
      coalesce(cast(ENDDATE_CE AS date), cast(ENDDATE AS date)) AS OBS_END_DT,
      cast(DEATH_DT AS date)   AS DEATH_DT,
      GDR_CD,
      YRDOB,
      AGE_INDEX_YR,
      FU_DAYS,
      FU_DAYS_CE
    FROM {wrk(cfg$input_cohort_table)}
  "), qc = "
    SELECT count(*) AS n_patients, min(INDEX_DATE) AS min_index, max(OBS_END_DT) AS max_obs_end,
           sum(case when ENDDATE_CE < ENDDATE then 1 else 0 end) AS n_disenrolled_before_enddate
    FROM lot_patient_input")

  # ----------------------------------------------------------
  # STEP 2 (5A): MMA_MED - Raw extraction
  # Sources: medical (PROC_CD, BILL_PROC_CD, NDC), med_procedure (PROC), rx (NDC)
  # ----------------------------------------------------------
  run_step(con, "S04_mma_med_raw", glue("
    CREATE OR REPLACE TEMPORARY VIEW mma_med_raw AS
    WITH codelist AS (
      SELECT /*+ BROADCAST */ * FROM mma_codelist
    ),
    -- 1) Medical claims - PROC_CD (HCPCS)
    -- Day supply uses per-class overrides when configured (e.g., PROTINHIB=21)
    med_proc_cd AS (
      SELECT
        m.PATID,
        cast(m.FST_DT AS date) AS DATE_SERVICE,
        {medical_day_supply_sql()} AS DAY_SUPPLY,
        'medical' AS CLAIM_TYPE,
        'med_proc_cd' AS CLAIM_SOURCE,
        c.CL_CODE AS CODE,
        c.CL_CODE_TYPE AS CODE_TYPE,
        c.CL_MED_ABBR AS MED_ABBR,
        c.CL_MED_CLASS AS MED_CLASS
      FROM {cdm_src(cfg$tbl_medical)} m
      INNER JOIN lot_patient_input p ON m.PATID = p.PATID
      INNER JOIN codelist c
        ON c.CL_CODE_TYPE = 'HCPCS'
       AND upper(regexp_replace(coalesce(cast(m.PROC_CD as string),''), '[^A-Za-z0-9]', '')) = c.CL_CODE
      WHERE cast(m.FST_DT AS date) >= p.INDEX_DATE
        AND cast(m.FST_DT AS date) <= p.OBS_END_DT
    ),
    -- 2) Medical claims - BILL_PROC_CD (HCPCS)
    med_bill_proc_cd AS (
      SELECT
        m.PATID,
        cast(m.FST_DT AS date) AS DATE_SERVICE,
        {medical_day_supply_sql()} AS DAY_SUPPLY,
        'medical' AS CLAIM_TYPE,
        'med_bill_proc' AS CLAIM_SOURCE,
        c.CL_CODE AS CODE,
        c.CL_CODE_TYPE AS CODE_TYPE,
        c.CL_MED_ABBR AS MED_ABBR,
        c.CL_MED_CLASS AS MED_CLASS
      FROM {cdm_src(cfg$tbl_medical)} m
      INNER JOIN lot_patient_input p ON m.PATID = p.PATID
      INNER JOIN codelist c
        ON c.CL_CODE_TYPE = 'HCPCS'
       AND upper(regexp_replace(coalesce(cast(m.BILL_PROC_CD as string),''), '[^A-Za-z0-9]', '')) = c.CL_CODE
      WHERE cast(m.FST_DT AS date) >= p.INDEX_DATE
        AND cast(m.FST_DT AS date) <= p.OBS_END_DT
    ),
    -- 3) Medical claims - NDC field (NDC-coded drug administrations on medical)
    med_ndc AS (
      SELECT
        m.PATID,
        cast(m.FST_DT AS date) AS DATE_SERVICE,
        {medical_day_supply_sql()} AS DAY_SUPPLY,
        'medical' AS CLAIM_TYPE,
        'med_ndc' AS CLAIM_SOURCE,
        c.CL_CODE AS CODE,
        c.CL_CODE_TYPE AS CODE_TYPE,
        c.CL_MED_ABBR AS MED_ABBR,
        c.CL_MED_CLASS AS MED_CLASS
      FROM {cdm_src(cfg$tbl_medical)} m
      INNER JOIN lot_patient_input p ON m.PATID = p.PATID
      INNER JOIN codelist c
        ON c.CL_CODE_TYPE = 'NDC'
       -- Normalize both sides to NDC11 (lpad stripped value to 11 digits with zeros)
       AND lpad(regexp_replace(coalesce(cast(m.NDC as string),''), '[^0-9]', ''), 11, '0')
         = lpad(regexp_replace(c.CL_CODE, '[^0-9]', ''), 11, '0')
      WHERE cast(m.NDC as string) IS NOT NULL AND trim(cast(m.NDC as string)) <> ''
        AND cast(m.FST_DT AS date) >= p.INDEX_DATE
        AND cast(m.FST_DT AS date) <= p.OBS_END_DT
    ),
    -- 4) med_procedure table: REMOVED — Optum med_procedure.PROC contains ICD
    -- procedure codes, not HCPCS/NDC drug codes. The MMA codelist only has HCPCS
    -- and NDC codes for medication identification, so matching against ICD procedure
    -- codes is not meaningful. SCT extraction (S12) correctly matches ICD procedure
    -- codes from this table using the SCT codelist.
    -- 5) Pharmacy (rx) claims (NDC)
    rx_claims AS (
      SELECT
        r.PATID,
        cast(r.FILL_DT AS date) AS DATE_SERVICE,
        cast(r.DAYS_SUP AS int) AS DAY_SUPPLY,
        'pharmacy' AS CLAIM_TYPE,
        'rx_ndc' AS CLAIM_SOURCE,
        c.CL_CODE AS CODE,
        c.CL_CODE_TYPE AS CODE_TYPE,
        c.CL_MED_ABBR AS MED_ABBR,
        c.CL_MED_CLASS AS MED_CLASS
      FROM {cdm_src(cfg$tbl_rx)} r
      INNER JOIN lot_patient_input p ON r.PATID = p.PATID
      INNER JOIN codelist c
        ON c.CL_CODE_TYPE = 'NDC'
       -- Normalize both sides to NDC11 (lpad stripped value to 11 digits with zeros)
       AND lpad(regexp_replace(coalesce(cast(r.NDC as string),''), '[^0-9]', ''), 11, '0')
         = lpad(regexp_replace(c.CL_CODE, '[^0-9]', ''), 11, '0')
      WHERE cast(r.FILL_DT AS date) >= p.INDEX_DATE
        AND cast(r.FILL_DT AS date) <= p.OBS_END_DT
    )
    SELECT * FROM med_proc_cd
    UNION ALL SELECT * FROM med_bill_proc_cd
    UNION ALL SELECT * FROM med_ndc
    UNION ALL SELECT * FROM rx_claims
  "), qc = "
    SELECT
      count(*) AS n_rows,
      count(DISTINCT PATID) AS n_patients,
      count(DISTINCT MED_ABBR) AS n_meds,
      sum(case when CLAIM_TYPE='pharmacy' then 1 else 0 end) AS n_pharmacy_rows,
      sum(case when CLAIM_TYPE='medical' then 1 else 0 end) AS n_medical_rows,
      -- Source contribution audit (Item 9B: confirms each source path is active)
      sum(case when CLAIM_SOURCE='med_proc_cd' then 1 else 0 end) AS n_from_proc_cd,
      sum(case when CLAIM_SOURCE='med_bill_proc' then 1 else 0 end) AS n_from_bill_proc,
      sum(case when CLAIM_SOURCE='med_ndc' then 1 else 0 end) AS n_from_med_ndc,
      sum(case when CLAIM_SOURCE='rx_ndc' then 1 else 0 end) AS n_from_rx_ndc
    FROM mma_med_raw")

  # Enrich + dedup (mma med.pdf spec)
  run_step(con, "S05_mma_med_processed", glue("
    CREATE OR REPLACE TEMPORARY VIEW mma_med_processed AS
    WITH enriched AS (
      SELECT
        r.PATID,
        r.CODE,
        r.CODE_TYPE,
        r.CLAIM_TYPE,
        r.DATE_SERVICE,
        r.DAY_SUPPLY,
        r.MED_ABBR,
        r.MED_CLASS,
        CASE WHEN coalesce(ru.CONDITIONING,0) = 1 THEN 'Yes' ELSE 'No' END AS MED_COND,
        CASE WHEN coalesce(ru.USED_FOR_OTHER_CANCERS,0) = 1 THEN 'Yes' ELSE 'No' END AS MED_OTHER_CANCER
      FROM mma_med_raw r
      LEFT JOIN mma_rollup ru
        ON r.MED_ABBR = ru.CL_MED_ABBR
    ),
    filtered AS (
      SELECT *
      FROM enriched
      WHERE NOT (CLAIM_TYPE = 'pharmacy' AND (DAY_SUPPLY IS NULL OR DAY_SUPPLY < 1))
    ),
    dedup AS (
      -- Dedup per spec: within (PATID, MED_ABBR, DATE_SERVICE, CLAIM_TYPE)
      -- keep max DAY_SUPPLY (pharmacy) or single row (medical, all 28)
      SELECT
        PATID,
        MED_ABBR,
        DATE_SERVICE,
        CLAIM_TYPE,
        max(DAY_SUPPLY) AS DAY_SUPPLY,
        -- Deterministic dedup: min() for reproducibility across runs
        min(CODE) AS CODE,
        min(CODE_TYPE) AS CODE_TYPE,
        min(MED_CLASS) AS MED_CLASS,
        min(MED_COND) AS MED_COND,
        min(MED_OTHER_CANCER) AS MED_OTHER_CANCER
      FROM filtered
      GROUP BY PATID, MED_ABBR, DATE_SERVICE, CLAIM_TYPE
    )
    SELECT * FROM dedup
  "), qc = "
    SELECT
      count(*) AS n_rows,
      sum(case when CLAIM_TYPE='pharmacy' then 1 else 0 end) AS n_pharmacy_rows,
      sum(case when CLAIM_TYPE='medical' then 1 else 0 end) AS n_medical_rows,
      min(DAY_SUPPLY) AS min_day_supply,
      max(DAY_SUPPLY) AS max_day_supply
    FROM mma_med_processed")

  # Sanity check
  bad_ds <- db_q(con, "SELECT count(*) AS n_bad FROM mma_med_processed WHERE CLAIM_TYPE='pharmacy' AND (DAY_SUPPLY IS NULL OR DAY_SUPPLY < 1)")$n_bad
  if (bad_ds > 0) stop(glue("Post-filter: found {bad_ds} pharmacy rows with invalid DAY_SUPPLY."))

  # ----------------------------------------------------------
  # STEP 3 (5B): MAP_MED - Medication Available Period algorithm
  #
  # CORRECTED per map med.pdf (page 5):
  #   "Medical runout date ... Pushout is not implemented."
  #
  # Pharmacy pushout rules (per Figure 3):
  #   - If new pharmacy claim DATE_SERVICE <= current rx_runout:
  #     pushout = rx_runout - DATE_SERVICE + 1
  #     new rx_runout = DATE_SERVICE + DAY_SUPPLY - 1 + pushout
  #   - If new pharmacy claim DATE_SERVICE > current rx_runout
  #     (but still within MAP via med_runout):
  #     rx_runout RESETS to DATE_SERVICE + DAY_SUPPLY - 1 (NO pushout)
  #
  # Medical: ALWAYS DATE_SERVICE + DAY_SUPPLY - 1 (no pushout ever)
  #
  # MAP boundary: new MAP when DATE_SERVICE > max(rx_runout, med_runout)
  # ----------------------------------------------------------
  map_struct_type <- "array<struct<MAP_CNT:int,MAP_START_DT:date,MAP_RX_RUNOUT_DT:date,MAP_MED_RUNOUT_DT:date,MAP_END_DT:date>>"
  min_date <- "cast('1900-01-01' as date)"

  run_step(con, "S06_map_med", glue("
    CREATE OR REPLACE TEMPORARY VIEW map_med AS
    WITH claims AS (
      SELECT
        PATID,
        MED_ABBR,
        MED_CLASS,
        DATE_SERVICE AS dt,
        CLAIM_TYPE  AS claim_type,
        cast(DAY_SUPPLY as int) AS ds
      FROM mma_med_processed
    ),
    grouped AS (
      SELECT
        PATID,
        MED_ABBR,
        min(MED_CLASS) AS MED_CLASS,  -- deterministic; should be 1:1 with MED_ABBR via rollup
        -- Sort: by date, then pharmacy before medical on same date (type_ord=0 for rx).
        -- Design choice: pharmacy processed first on same-day ties. This is safe because:
        --   rx pushout only depends on rx_runout (not med_runout),
        --   and medical never has pushout, so order on same day doesn't distort either.
        -- Spec doesn't mandate tie-break order; this choice is documented and deterministic.
        sort_array(collect_list(named_struct(
          'dt', dt,
          'type_ord', case when claim_type='pharmacy' then 0 else 1 end,
          'type', claim_type,
          'ds', ds
        ))) AS claims_arr
      FROM claims
      GROUP BY PATID, MED_ABBR
    ),
    maps AS (
      SELECT
        PATID,
        MED_ABBR,
        MED_CLASS,
        explode(
          aggregate(
            claims_arr,
            -- Accumulator: current MAP state
            named_struct(
              'map_cnt', 0,
              'cur_start', cast(null as date),
              'rx_runout', cast(null as date),
              'med_runout', cast(null as date),
              'maps', cast(array() as {map_struct_type})
            ),
            -- Merge function: process each claim
            (s, x) -> CASE
              -- CASE 1: First claim ever (no current MAP open)
              WHEN s.cur_start IS NULL THEN
                named_struct(
                  'map_cnt', 1,
                  'cur_start', x.dt,
                  'rx_runout', CASE WHEN x.type='pharmacy' THEN date_add(x.dt, x.ds - 1) ELSE NULL END,
                  'med_runout', CASE WHEN x.type='medical' THEN date_add(x.dt, x.ds - 1) ELSE NULL END,
                  'maps', s.maps
                )
              -- CASE 2: Claim beyond both runouts -> close current MAP, start new
              WHEN x.dt > greatest(coalesce(s.rx_runout, {min_date}), coalesce(s.med_runout, {min_date})) THEN
                named_struct(
                  'map_cnt', s.map_cnt + 1,
                  'cur_start', x.dt,
                  'rx_runout', CASE WHEN x.type='pharmacy' THEN date_add(x.dt, x.ds - 1) ELSE NULL END,
                  'med_runout', CASE WHEN x.type='medical' THEN date_add(x.dt, x.ds - 1) ELSE NULL END,
                  'maps', array_append(
                    s.maps,
                    named_struct(
                      'MAP_CNT', s.map_cnt,
                      'MAP_START_DT', s.cur_start,
                      'MAP_RX_RUNOUT_DT', s.rx_runout,
                      'MAP_MED_RUNOUT_DT', s.med_runout,
                      'MAP_END_DT', greatest(coalesce(s.rx_runout, {min_date}), coalesce(s.med_runout, {min_date}))
                    )
                  )
                )
              -- CASE 3: Claim within current MAP -> update runouts
              ELSE
                named_struct(
                  'map_cnt', s.map_cnt,
                  'cur_start', s.cur_start,
                  -- PHARMACY RUNOUT UPDATE
                  'rx_runout', CASE
                    WHEN x.type='pharmacy' THEN
                      CASE
                        -- First pharmacy claim in this MAP
                        WHEN s.rx_runout IS NULL THEN date_add(x.dt, x.ds - 1)
                        -- Pharmacy claim WITHIN current rx coverage -> PUSHOUT
                        -- pushout = rx_runout - DATE_SERVICE + 1
                        -- new rx_runout = DATE_SERVICE + DS - 1 + pushout = rx_runout + DS
                        WHEN x.dt <= s.rx_runout THEN
                          date_add(s.rx_runout, x.ds)
                        -- Pharmacy claim AFTER rx_runout but still in MAP (via med_runout)
                        -- -> RESET without pushout (per Figure 3, iteration 4)
                        ELSE
                          date_add(x.dt, x.ds - 1)
                      END
                    -- Not a pharmacy claim: rx_runout unchanged
                    ELSE s.rx_runout
                  END,
                  -- MEDICAL RUNOUT UPDATE
                  -- Per map med.pdf page 5: "Pushout is not implemented" for medical.
                  -- Always: DATE_SERVICE + DAY_SUPPLY - 1.
                  -- greatest() is a safety belt: if a same-day or out-of-order claim
                  -- produces an earlier runout, we keep the existing later one.
                  'med_runout', CASE
                    WHEN x.type='medical' THEN
                      CASE
                        WHEN s.med_runout IS NULL THEN date_add(x.dt, x.ds - 1)
                        ELSE greatest(s.med_runout, date_add(x.dt, x.ds - 1))
                      END
                    ELSE s.med_runout
                  END,
                  'maps', s.maps
                )
            END,
            -- Finalize: flush the last open MAP
            s -> CASE
              WHEN s.cur_start IS NULL THEN cast(array() as {map_struct_type})
              ELSE array_append(
                s.maps,
                named_struct(
                  'MAP_CNT', s.map_cnt,
                  'MAP_START_DT', s.cur_start,
                  'MAP_RX_RUNOUT_DT', s.rx_runout,
                  'MAP_MED_RUNOUT_DT', s.med_runout,
                  'MAP_END_DT', greatest(coalesce(s.rx_runout, {min_date}), coalesce(s.med_runout, {min_date}))
                )
              )
            END
          )
        ) AS map_rec
      FROM grouped
    ),
    base AS (
      SELECT
        m.PATID,
        m.MED_ABBR,
        m.MED_CLASS,
        map_rec.MAP_CNT           AS MAP_CNT,
        map_rec.MAP_START_DT      AS MAP_START_DT,
        map_rec.MAP_RX_RUNOUT_DT  AS MAP_RX_RUNOUT_DT,
        map_rec.MAP_MED_RUNOUT_DT AS MAP_MED_RUNOUT_DT,
        CASE WHEN map_rec.MAP_END_DT = {min_date} THEN NULL ELSE map_rec.MAP_END_DT END AS MAP_END_DT
      FROM maps m
    ),
    with_next AS (
      SELECT
        b.*,
        lead(MAP_START_DT) OVER (PARTITION BY PATID, MED_ABBR ORDER BY MAP_CNT) AS NEXT_MAP_START_DT
      FROM base b
    )
    SELECT
      w.PATID,
      w.MED_ABBR,
      w.MED_CLASS,
      w.MAP_CNT,
      w.MAP_START_DT,
      w.MAP_RX_RUNOUT_DT,
      w.MAP_MED_RUNOUT_DT,
      w.MAP_END_DT,
      w.MED_ABBR AS MAP_MED_TYPE,
      w.MED_CLASS AS MAP_MED_CLASS,
      CASE
        WHEN w.NEXT_MAP_START_DT IS NOT NULL
          AND datediff(w.NEXT_MAP_START_DT, w.MAP_END_DT) > {cfg$map_discon_gap_days}
          THEN 1
        WHEN w.NEXT_MAP_START_DT IS NULL
          AND datediff(p.OBS_END_DT, w.MAP_END_DT) > {cfg$map_discon_gap_days}
          THEN 1
        ELSE 0
      END AS MAP_DISCON_FLG
    FROM with_next w
    INNER JOIN lot_patient_input p ON w.PATID = p.PATID
    WHERE w.MAP_END_DT IS NOT NULL
  "), qc = "
    SELECT
      count(*) AS n_maps,
      count(DISTINCT PATID) AS n_patients,
      count(DISTINCT MED_ABBR) AS n_meds,
      avg(datediff(MAP_END_DT, MAP_START_DT) + 1) AS avg_map_len_days,
      sum(MAP_DISCON_FLG) AS n_discontinuations
    FROM map_med")

  # ----------------------------------------------------------
  # STEP 4: MAP_STACKED
  # ----------------------------------------------------------
  run_step(con, "S07_map_stacked", "
    CREATE OR REPLACE TEMPORARY VIEW map_stacked AS
    SELECT * FROM map_med
  ", qc = "SELECT count(*) AS n_rows FROM map_stacked")

  # ----------------------------------------------------------
  # STEP 5 (6): LOT1_BASE
  # ----------------------------------------------------------
  run_step(con, "S08_lot1_start", "
    CREATE OR REPLACE TEMPORARY VIEW lot1_start AS
    SELECT
      ms.PATID,
      min(ms.MAP_START_DT) AS LOT1_START_DT
    FROM map_stacked ms
    WHERE ms.MAP_MED_CLASS <> 'STEROID'
    GROUP BY ms.PATID
  ", qc = "SELECT count(*) AS n_patients_with_lot1, min(LOT1_START_DT) AS min_lot1_start, max(LOT1_START_DT) AS max_lot1_start FROM lot1_start")

  run_step(con, "S09_lot1_induction_meds", glue("
    CREATE OR REPLACE TEMPORARY VIEW lot1_induction_meds AS
    SELECT DISTINCT
      ms.PATID,
      l1.LOT1_START_DT,
      ms.MAP_MED_TYPE AS MED_ABBR,
      ms.MAP_MED_CLASS AS MED_CLASS
    FROM map_stacked ms
    INNER JOIN lot1_start l1
      ON ms.PATID = l1.PATID
    WHERE ms.MAP_START_DT >= l1.LOT1_START_DT
      AND ms.MAP_START_DT <= date_add(l1.LOT1_START_DT, {cfg$induction_window_days - 1})
  "), qc = "
    SELECT count(*) AS n_rows, count(DISTINCT PATID) AS n_patients, avg(cnt) AS avg_induction_meds
    FROM (SELECT PATID, count(DISTINCT MED_ABBR) AS cnt FROM lot1_induction_meds GROUP BY PATID)")

  # LOT1 BASE: induction meds + permissible subs, discon, first add
  run_step(con, "S10_lot1_base", glue("
    CREATE OR REPLACE TEMPORARY VIEW lot1_base AS
    WITH base_meds AS (
      SELECT PATID, MED_ABBR
      FROM lot1_induction_meds
      UNION
      SELECT im.PATID, ps.substitute_med AS MED_ABBR
      FROM lot1_induction_meds im
      INNER JOIN permissible_subs ps
        ON im.MED_ABBR = ps.original_med
    ),
    -- DECISION: Steroid MAPs are included in base_meds (per spec: induction includes
    -- all meds in the window including steroids). This means steroid MAPs can extend
    -- LOT1_BASE_DISCON_DT. If stakeholders prefer to exclude steroids from the
    -- discontinuation computation (common analytic tweak), filter base_meds above
    -- to exclude steroid MED_CLASS, but keep steroid flags in LOT1_BASE_MEDS.
    discon_raw AS (
      SELECT
        ms.PATID,
        max(ms.MAP_END_DT) AS RAW_DISCON_DT
      FROM map_stacked ms
      INNER JOIN lot1_start l1 ON ms.PATID = l1.PATID
      INNER JOIN base_meds bm
        ON ms.PATID = bm.PATID
       AND ms.MAP_MED_TYPE = bm.MED_ABBR
      WHERE ms.MAP_START_DT >= l1.LOT1_START_DT
      GROUP BY ms.PATID
    ),
    discon AS (
      SELECT
        p.PATID,
        CASE
          WHEN d.RAW_DISCON_DT IS NOT NULL AND datediff(p.OBS_END_DT, d.RAW_DISCON_DT) > {cfg$lot_discon_gap_days}
            THEN d.RAW_DISCON_DT
          ELSE NULL
        END AS LOT1_BASE_DISCON_DT
      FROM lot_patient_input p
      LEFT JOIN discon_raw d ON p.PATID = d.PATID
    ),
    med_summary AS (
      SELECT
        im.PATID,
        min(im.LOT1_START_DT) AS LOT1_START_DT,  -- same for all rows per PATID; min for determinism
        count(DISTINCT im.MED_ABBR) AS LOT1_MED_CNT,
        concat_ws(' ', sort_array(collect_set(im.MED_ABBR))) AS LOT1_BASE_MEDS,
        {med_flag_exprs},
        {class_flag_exprs}
      FROM lot1_induction_meds im
      GROUP BY im.PATID
    ),
    base_core AS (
      SELECT
        p.PATID,
        p.INDEX_DATE,
        p.ENDDATE,
        p.OBS_END_DT,
        p.DEATH_DT,
        p.GDR_CD,
        p.YRDOB,
        p.AGE_INDEX_YR,
        ms.LOT1_START_DT,
        ms.LOT1_MED_CNT,
        ms.LOT1_BASE_MEDS,
        d.LOT1_BASE_DISCON_DT,
        {paste0('ms.', paste(c(paste0('LOT1_MED_', vapply(meds, sanitize_col, character(1))), paste0('LOT1_CLASS_', vapply(classes, sanitize_class, character(1)))), collapse = ', ms.'))}
      FROM lot_patient_input p
      INNER JOIN med_summary ms ON p.PATID = ms.PATID
      LEFT JOIN discon d ON p.PATID = d.PATID
    ),
    first_add_candidates AS (
      SELECT
        ms.PATID,
        ms.MAP_START_DT,
        ms.MAP_MED_TYPE
      FROM map_stacked ms
      INNER JOIN base_core bc ON ms.PATID = bc.PATID
      LEFT JOIN base_meds bm
        ON ms.PATID = bm.PATID AND ms.MAP_MED_TYPE = bm.MED_ABBR
      WHERE bm.MED_ABBR IS NULL
        AND ms.MAP_START_DT >= bc.LOT1_START_DT
        AND ms.MAP_START_DT <= coalesce(bc.LOT1_BASE_DISCON_DT, bc.OBS_END_DT)
        -- NOTE: Steroids excluded as add-meds per clinical convention; confirm with spec owner
        AND ms.MAP_MED_CLASS <> 'STEROID'
    ),
    first_add_dt AS (
      SELECT PATID, min(MAP_START_DT) AS ADD_START_DT
      FROM first_add_candidates
      GROUP BY PATID
    ),
    first_add_pick AS (
      SELECT
        c.PATID,
        date_sub(d.ADD_START_DT, 1) AS LOT1_BASE_1ST_ADD_MED_DT,
        -- Spec says "random" for same-day ties; we use min() for determinism (deliberate deviation)
        min(c.MAP_MED_TYPE) AS LOT1_BASE_1ST_ADD_MED
      FROM first_add_candidates c
      INNER JOIN first_add_dt d
        ON c.PATID = d.PATID AND c.MAP_START_DT = d.ADD_START_DT
      GROUP BY c.PATID, d.ADD_START_DT
    )
    SELECT
      bc.PATID, bc.INDEX_DATE, bc.ENDDATE, bc.OBS_END_DT, bc.DEATH_DT,
      bc.GDR_CD, bc.YRDOB, bc.AGE_INDEX_YR,
      bc.LOT1_START_DT, bc.LOT1_MED_CNT, bc.LOT1_BASE_MEDS,
      bc.LOT1_BASE_DISCON_DT,
      -- Recompute LOT1_BASE_LENGTH accounting for MED_ADD end reason
      CASE
        WHEN fa.LOT1_BASE_1ST_ADD_MED_DT IS NOT NULL
         AND (bc.LOT1_BASE_DISCON_DT IS NULL OR fa.LOT1_BASE_1ST_ADD_MED_DT <= bc.LOT1_BASE_DISCON_DT)
        THEN datediff(fa.LOT1_BASE_1ST_ADD_MED_DT, bc.LOT1_START_DT) + 1
        WHEN bc.LOT1_BASE_DISCON_DT IS NOT NULL
        THEN datediff(bc.LOT1_BASE_DISCON_DT, bc.LOT1_START_DT) + 1
        ELSE datediff(bc.OBS_END_DT, bc.LOT1_START_DT) + 1
      END AS LOT1_BASE_LENGTH,
      {paste0('bc.', paste(c(paste0('LOT1_MED_', vapply(meds, sanitize_col, character(1))), paste0('LOT1_CLASS_', vapply(classes, sanitize_class, character(1)))), collapse = ', bc.'))},
      fa.LOT1_BASE_1ST_ADD_MED_DT,
      fa.LOT1_BASE_1ST_ADD_MED
    FROM base_core bc
    LEFT JOIN first_add_pick fa
      ON bc.PATID = fa.PATID
  "), qc = "
    SELECT
      count(*) AS n_patients,
      avg(LOT1_MED_CNT) AS avg_induction_meds,
      avg(LOT1_BASE_LENGTH) AS avg_base_length,
      sum(case when LOT1_BASE_DISCON_DT is not null then 1 else 0 end) as n_with_discon_dt,
      sum(case when LOT1_BASE_1ST_ADD_MED_DT is not null then 1 else 0 end) as n_with_add_med
    FROM lot1_base")

  # ----------------------------------------------------------
  # STEP 7 (SCT): Stem Cell Transplant detection
  # Per sct.pdf spec section 7:
  #   - AUTO: 14-day window grouping + 60-day gap + 180-day tandem
  #   - ALLO/CART: simple sequential dates
  #   - ALLO/CART immediately end LOT1
  #   - Single AUTO allowed; tandem pair allowed; excess AUTO ends LOT1
  #
  # NOTE: Maintenance (mono/dual) specs not yet provided.
  # ----------------------------------------------------------

  # S11: Register SCT codelist
  # Normalize CL_CODE_TYPE to canonical values:
  #   ICD10PROC / ICD10PCS            → 'ICD10PROC' (matches med_procedure.PROC with ICD_FLAG=10)
  #   ICD9PROC                        → 'ICD9PROC'  (matches med_procedure.PROC with ICD_FLAG=9)
  #   ICD10DIAG / ICD10DX             → 'ICD10DIAG' (matches med_diagnosis.DIAG with ICD_FLAG=10)
  #   ICD9DIAG / ICD9DX               → 'ICD9DIAG'  (matches med_diagnosis.DIAG with ICD_FLAG=9)
  #   HCPCS                           → 'HCPCS'     (matches medical.PROC_CD)
  # Normalize SCT_TYPE: Allogenic→ALLO, Autologous→AUTO, CAR-T→CART
  run_step(con, "S11_sct_codelist", glue("
    CREATE OR REPLACE TEMPORARY VIEW sct_codelist AS
    SELECT
      CASE
        WHEN upper(trim(CL_CODE_TYPE)) IN ('ICD10PROC', 'ICD10PCS') THEN 'ICD10PROC'
        WHEN upper(trim(CL_CODE_TYPE)) = 'ICD9PROC' THEN 'ICD9PROC'
        WHEN upper(trim(CL_CODE_TYPE)) LIKE '%PROC%'
          OR upper(trim(CL_CODE_TYPE)) = 'ICD' THEN 'ICD10PROC'
        WHEN upper(trim(CL_CODE_TYPE)) IN ('ICD10DIAG', 'ICD10DX', 'DIAG10')
          OR upper(trim(CL_CODE_TYPE)) LIKE 'ICD%10%DIAG%' THEN 'ICD10DIAG'
        WHEN upper(trim(CL_CODE_TYPE)) IN ('ICD9DIAG', 'ICD9DX', 'ICD9', 'DIAG9')
          OR upper(trim(CL_CODE_TYPE)) LIKE 'ICD%9%DIAG%' THEN 'ICD9DIAG'
        WHEN upper(trim(CL_CODE_TYPE)) IN ('DIAG', 'DX', 'DIAGNOSIS') THEN 'ICD10DIAG'
        WHEN upper(trim(CL_CODE_TYPE)) IN ('CPT', 'CPT4') THEN 'HCPCS'
        ELSE upper(trim(CL_CODE_TYPE))
      END AS CL_CODE_TYPE,
      upper(regexp_replace(trim(CL_CODE), '[^A-Za-z0-9]', '')) AS CL_CODE,
      CASE
        WHEN upper(trim(SCT_TYPE)) LIKE 'ALLO%' THEN 'ALLO'
        WHEN upper(trim(SCT_TYPE)) LIKE 'AUTO%' THEN 'AUTO'
        WHEN upper(trim(SCT_TYPE)) IN ('CAR-T', 'CART', 'CAR_T') THEN 'CART'
        WHEN upper(trim(SCT_TYPE)) IN ('UNKNOWN', 'UNK', 'OTHER', 'SCT', 'HSCT',
                                        'HCT', 'STEM CELL', 'TRANSPLANT', 'BMT')
          THEN 'UNKNOWN'
        ELSE upper(trim(SCT_TYPE))
      END AS SCT_TYPE
    FROM {sct_src}
    WHERE CL_CODE IS NOT NULL AND trim(CL_CODE) <> ''
      AND SCT_TYPE IS NOT NULL AND trim(SCT_TYPE) <> ''
  "), qc = "SELECT SCT_TYPE, CL_CODE_TYPE, count(*) AS n_codes FROM sct_codelist GROUP BY SCT_TYPE, CL_CODE_TYPE ORDER BY SCT_TYPE, CL_CODE_TYPE")

  # S12: Extract raw SCT claims from MEDICAL + MED_PROCEDURE
  run_step(con, "S12_sct_claims_raw", glue("
    CREATE OR REPLACE TEMPORARY VIEW sct_claims_raw AS
    WITH sct_codes AS (
      SELECT /*+ BROADCAST */ * FROM sct_codelist
    ),
    -- Medical PROC_CD (contains CPT/HCPCS per Optum business rules)
    med_proc AS (
      SELECT m.PATID, cast(m.FST_DT AS date) AS DATE_SERVICE,
             s.SCT_TYPE, s.CL_CODE AS CODE, 'med_proc_cd' AS SRC
      FROM {cdm_src(cfg$tbl_medical)} m
      INNER JOIN lot_patient_input p ON m.PATID = p.PATID
      INNER JOIN sct_codes s
        ON s.CL_CODE_TYPE = 'HCPCS'
       AND upper(regexp_replace(coalesce(cast(m.PROC_CD as string),''), '[^A-Za-z0-9]', '')) = s.CL_CODE
      WHERE cast(m.FST_DT AS date) >= p.INDEX_DATE
        AND cast(m.FST_DT AS date) <= p.OBS_END_DT
    ),
    -- Medical BILL_PROC_CD (also CPT/HCPCS per Optum business rules)
    med_bill AS (
      SELECT m.PATID, cast(m.FST_DT AS date) AS DATE_SERVICE,
             s.SCT_TYPE, s.CL_CODE AS CODE, 'med_bill_proc' AS SRC
      FROM {cdm_src(cfg$tbl_medical)} m
      INNER JOIN lot_patient_input p ON m.PATID = p.PATID
      INNER JOIN sct_codes s
        ON s.CL_CODE_TYPE = 'HCPCS'
       AND upper(regexp_replace(coalesce(cast(m.BILL_PROC_CD as string),''), '[^A-Za-z0-9]', '')) = s.CL_CODE
      WHERE cast(m.FST_DT AS date) >= p.INDEX_DATE
        AND cast(m.FST_DT AS date) <= p.OBS_END_DT
    ),
    -- MED_PROCEDURE PROC (ICD-9/ICD-10 procedure codes + HCPCS safety net)
    medproc AS (
      SELECT mp.PATID, cast(mp.FST_DT AS date) AS DATE_SERVICE,
             s.SCT_TYPE, s.CL_CODE AS CODE, 'med_procedure' AS SRC
      FROM {cdm_src(cfg$tbl_med_proc)} mp
      INNER JOIN lot_patient_input p ON mp.PATID = p.PATID
      INNER JOIN sct_codes s
        ON (  (s.CL_CODE_TYPE = 'ICD10PROC'
               AND coalesce(upper(mp.ICD_FLAG), '') NOT IN ('9', 'ICD9', 'ICD-9'))
           OR (s.CL_CODE_TYPE = 'ICD9PROC'
               AND upper(mp.ICD_FLAG) IN ('9', 'ICD9', 'ICD-9'))
           OR s.CL_CODE_TYPE = 'HCPCS'
           )
       AND upper(regexp_replace(coalesce(cast(mp.PROC as string),''), '[^A-Za-z0-9]', '')) = s.CL_CODE
      WHERE cast(mp.FST_DT AS date) >= p.INDEX_DATE
        AND cast(mp.FST_DT AS date) <= p.OBS_END_DT
    ),
    -- MED_DIAGNOSIS DIAG (ICD-10/ICD-9 diagnosis codes)
    med_diag AS (
      SELECT d.PATID, cast(d.FST_DT AS date) AS DATE_SERVICE,
             s.SCT_TYPE, s.CL_CODE AS CODE, 'med_diagnosis' AS SRC
      FROM {cdm_src(cfg$tbl_med_diag)} d
      INNER JOIN lot_patient_input p ON d.PATID = p.PATID
      INNER JOIN sct_codes s
        ON (  (s.CL_CODE_TYPE = 'ICD10DIAG'
               AND coalesce(upper(d.ICD_FLAG), '') NOT IN ('9', 'ICD9', 'ICD-9'))
           OR (s.CL_CODE_TYPE = 'ICD9DIAG'
               AND upper(d.ICD_FLAG) IN ('9', 'ICD9', 'ICD-9'))
           )
       AND upper(regexp_replace(coalesce(cast(d.DIAG as string),''), '[^A-Za-z0-9]', '')) = s.CL_CODE
      WHERE cast(d.FST_DT AS date) >= p.INDEX_DATE
        AND cast(d.FST_DT AS date) <= p.OBS_END_DT
    ),
    combined AS (
      SELECT * FROM med_proc
      UNION ALL SELECT * FROM med_bill
      UNION ALL SELECT * FROM medproc
      UNION ALL SELECT * FROM med_diag
    )
    -- Deduplicate: one record per (PATID, DATE_SERVICE, SCT_TYPE)
    SELECT PATID, DATE_SERVICE, SCT_TYPE, min(CODE) AS CODE
    FROM combined
    GROUP BY PATID, DATE_SERVICE, SCT_TYPE
  "), qc = "
    SELECT SCT_TYPE, count(*) AS n_claims, count(DISTINCT PATID) AS n_patients,
           min(DATE_SERVICE) AS min_date, max(DATE_SERVICE) AS max_date
    FROM sct_claims_raw
    GROUP BY SCT_TYPE
    ORDER BY SCT_TYPE")

  # NOTE: SCT CTEs include SRC column for debug traceability (dropped during dedup).
  # To audit source contributions, query the combined CTE directly before dedup.

  # S13: AUTO SCT date processing (per sct.pdf)
  #
  # Step 1: Group AUTO claims into 14-day windows (claims within 14 days of
  #         window start are in same window). Per spec, select the LAST (max)
  #         date in each window, NOT the first -- first claims are workup
  #         activity, last claim is the actual transplant.
  #
  # Tandem boundary adjustment: when a 14-day window overlaps the 180-day
  # tandem boundary (from the previous finalized TX date), select the date
  # closest to the boundary rather than the window max. This ensures accurate
  # tandem determination. Computed as min |date - boundary| over all dates
  # in the window. (See sct.pdf example: TX_AUTO1=09MAY2018, 180-day mark
  # ~05NOV2018, window 06NOV-20NOV picks 07NOV instead of 20NOV.)
  #
  # Step 2: Apply 60-day minimum gap between events (merge if < 60 days apart).
  # Result: finalized TX dates for AUTO SCT per patient.
  run_step(con, "S13_tx_auto_dates", glue("
    CREATE OR REPLACE TEMPORARY VIEW tx_auto_dates AS
    WITH auto_dates AS (
      SELECT DISTINCT PATID, DATE_SERVICE AS dt
      FROM sct_claims_raw
      WHERE SCT_TYPE = 'AUTO'
    ),
    grouped AS (
      SELECT PATID,
             sort_array(collect_list(dt)) AS dates_arr
      FROM auto_dates
      GROUP BY PATID
    ),
    -- Phase 1 + 2 combined: 14-day windowing with tandem-aware date selection
    -- + 60-day gap merging in a single pass.
    --
    -- State tracks:
    --   tx_dates: finalized TX dates array
    --   cur_start: start of current 14-day window (first date in window)
    --   cur_max_dt: last (max) date in current window (default selection)
    --   cur_boundary_dt: date in window closest to tandem boundary
    --   cur_boundary_dist: abs distance of cur_boundary_dt to tandem boundary
    --   last_tx_dt: last finalized TX date (for tandem boundary + 60-day gap)
    processed AS (
      SELECT PATID,
        aggregate(
          dates_arr,
          named_struct(
            'tx_dates', cast(array() as array<date>),
            'cur_start', cast(null as date),
            'cur_max_dt', cast(null as date),
            'cur_boundary_dt', cast(null as date),
            'cur_boundary_dist', cast(null as int),
            'last_tx_dt', cast(null as date)
          ),
          (s, x) -> CASE
            -- First claim ever: start first window
            WHEN s.cur_start IS NULL THEN
              named_struct(
                'tx_dates', s.tx_dates,
                'cur_start', x,
                'cur_max_dt', x,
                'cur_boundary_dt', cast(null as date),
                'cur_boundary_dist', cast(null as int),
                'last_tx_dt', s.last_tx_dt
              )
            -- Within 14-day window: update max + tandem boundary tracking
            WHEN datediff(x, s.cur_start) <= {cfg$sct_auto_window_days} THEN
              named_struct(
                'tx_dates', s.tx_dates,
                'cur_start', s.cur_start,
                'cur_max_dt', x,  -- x >= cur_max_dt since sorted
                -- Track date closest to tandem boundary, BUT only when date is
                -- within window_days of the boundary (i.e., window overlaps or
                -- is adjacent to the 180-day mark). When far from boundary,
                -- cur_boundary_dt stays NULL so coalesce() falls back to max.
                'cur_boundary_dt', CASE
                  WHEN s.last_tx_dt IS NULL THEN NULL
                  WHEN abs(datediff(x, date_add(s.last_tx_dt, {cfg$sct_tandem_days} - 1)))
                       <= {cfg$sct_auto_window_days}
                   AND (s.cur_boundary_dist IS NULL
                        OR abs(datediff(x, date_add(s.last_tx_dt, {cfg$sct_tandem_days} - 1)))
                           < s.cur_boundary_dist)
                    THEN x
                  WHEN s.cur_boundary_dt IS NOT NULL THEN s.cur_boundary_dt
                  ELSE NULL
                END,
                'cur_boundary_dist', CASE
                  WHEN s.last_tx_dt IS NULL THEN NULL
                  WHEN abs(datediff(x, date_add(s.last_tx_dt, {cfg$sct_tandem_days} - 1)))
                       <= {cfg$sct_auto_window_days}
                   AND (s.cur_boundary_dist IS NULL
                        OR abs(datediff(x, date_add(s.last_tx_dt, {cfg$sct_tandem_days} - 1)))
                           < s.cur_boundary_dist)
                    THEN abs(datediff(x, date_add(s.last_tx_dt, {cfg$sct_tandem_days} - 1)))
                  WHEN s.cur_boundary_dist IS NOT NULL THEN s.cur_boundary_dist
                  ELSE NULL
                END,
                'last_tx_dt', s.last_tx_dt
              )
            -- Beyond 14-day window: finalize current window, start new
            ELSE
              -- Select date: use boundary-closest if tandem boundary active, else max
              -- Then apply 60-day gap: only keep if >= 60 days from last_tx_dt
              CASE
                WHEN s.last_tx_dt IS NOT NULL
                 AND datediff(
                       coalesce(s.cur_boundary_dt, s.cur_max_dt),
                       s.last_tx_dt
                     ) < {cfg$sct_auto_gap_days}
                THEN
                  -- Too close to last TX: discard window, start new
                  named_struct(
                    'tx_dates', s.tx_dates,
                    'cur_start', x,
                    'cur_max_dt', x,
                    -- Only init boundary tracking if x is near the boundary
                    'cur_boundary_dt', CASE
                      WHEN s.last_tx_dt IS NOT NULL
                       AND abs(datediff(x, date_add(s.last_tx_dt, {cfg$sct_tandem_days} - 1)))
                           <= {cfg$sct_auto_window_days}
                      THEN x
                      ELSE NULL
                    END,
                    'cur_boundary_dist', CASE
                      WHEN s.last_tx_dt IS NOT NULL
                       AND abs(datediff(x, date_add(s.last_tx_dt, {cfg$sct_tandem_days} - 1)))
                           <= {cfg$sct_auto_window_days}
                      THEN abs(datediff(x, date_add(s.last_tx_dt, {cfg$sct_tandem_days} - 1)))
                      ELSE NULL
                    END,
                    'last_tx_dt', s.last_tx_dt
                  )
                ELSE
                  -- Valid TX: finalize and start new window
                  named_struct(
                    'tx_dates', array_append(
                      s.tx_dates,
                      coalesce(s.cur_boundary_dt, s.cur_max_dt)
                    ),
                    'cur_start', x,
                    'cur_max_dt', x,
                    -- Init boundary tracking relative to newly finalized TX
                    'cur_boundary_dt', CASE
                      WHEN abs(datediff(
                             x,
                             date_add(coalesce(s.cur_boundary_dt, s.cur_max_dt), {cfg$sct_tandem_days} - 1)
                           )) <= {cfg$sct_auto_window_days}
                      THEN x
                      ELSE NULL
                    END,
                    'cur_boundary_dist', CASE
                      WHEN abs(datediff(
                             x,
                             date_add(coalesce(s.cur_boundary_dt, s.cur_max_dt), {cfg$sct_tandem_days} - 1)
                           )) <= {cfg$sct_auto_window_days}
                      THEN abs(datediff(
                             x,
                             date_add(coalesce(s.cur_boundary_dt, s.cur_max_dt), {cfg$sct_tandem_days} - 1)
                           ))
                      ELSE NULL
                    END,
                    'last_tx_dt', coalesce(s.cur_boundary_dt, s.cur_max_dt)
                  )
                END
          END,
          -- Finalize: flush last open window
          s -> CASE
            WHEN s.cur_start IS NULL THEN s.tx_dates
            -- Apply 60-day gap check for last window
            WHEN s.last_tx_dt IS NOT NULL
             AND datediff(
                   coalesce(s.cur_boundary_dt, s.cur_max_dt),
                   s.last_tx_dt
                 ) < {cfg$sct_auto_gap_days}
            THEN s.tx_dates
            ELSE array_append(
              s.tx_dates,
              coalesce(s.cur_boundary_dt, s.cur_max_dt)
            )
          END
        ) AS tx_dates
      FROM grouped
    ),
    exploded AS (
      SELECT PATID, posexplode(tx_dates) AS (pos, TX_DT)
      FROM processed
    )
    SELECT PATID, pos + 1 AS TX_SEQ, TX_DT
    FROM exploded
  "), qc = "
    SELECT count(*) AS n_auto_tx_events, count(DISTINCT PATID) AS n_patients,
           min(TX_SEQ) AS min_seq, max(TX_SEQ) AS max_seq
    FROM tx_auto_dates")

  # S14: ALLO and CART sequential dates (simple ordering)
  run_step(con, "S14_tx_allo_cart_dates", "
    CREATE OR REPLACE TEMPORARY VIEW tx_allo_cart_dates AS
    WITH allo_dates AS (
      SELECT DISTINCT PATID, DATE_SERVICE AS dt
      FROM sct_claims_raw
      WHERE SCT_TYPE = 'ALLO'
    ),
    cart_dates AS (
      SELECT DISTINCT PATID, DATE_SERVICE AS dt
      FROM sct_claims_raw
      WHERE SCT_TYPE = 'CART'
    ),
    allo_seq AS (
      SELECT PATID, 'ALLO' AS SCT_TYPE, dt AS TX_DT,
             row_number() OVER (PARTITION BY PATID ORDER BY dt) AS TX_SEQ
      FROM allo_dates
    ),
    cart_seq AS (
      SELECT PATID, 'CART' AS SCT_TYPE, dt AS TX_DT,
             row_number() OVER (PARTITION BY PATID ORDER BY dt) AS TX_SEQ
      FROM cart_dates
    )
    SELECT * FROM allo_seq
    UNION ALL
    SELECT * FROM cart_seq
  ", qc = "
    SELECT SCT_TYPE, count(*) AS n_events, count(DISTINCT PATID) AS n_patients
    FROM tx_allo_cart_dates
    GROUP BY SCT_TYPE
    ORDER BY SCT_TYPE")

  # S15: LOT1 SCT variables
  # Derives: LOT1_TX_AUTO_DT_1/2, TAND_FLG, SING_FLG,
  #          LOT1_TX_ENDDATE, LOT1_TX_ENDDATE_REASON, LOT1_1ST_SCT_DT
  run_step(con, "S15_lot1_sct", glue("
    CREATE OR REPLACE TEMPORARY VIEW lot1_sct AS
    WITH lot1 AS (
      SELECT PATID, LOT1_START_DT, OBS_END_DT FROM lot1_base
    ),
    -- AUTO dates within LOT1 observation window
    -- Censored at earliest ALLO/CART: ALLO and CART immediately end LOT1,
    -- so AUTO events after an ALLO/CART are not relevant to LOT1.
    earliest_non_auto AS (
      SELECT ac.PATID, min(ac.TX_DT) AS FIRST_NON_AUTO_DT
      FROM tx_allo_cart_dates ac
      INNER JOIN lot1 l ON ac.PATID = l.PATID
      WHERE ac.SCT_TYPE IN ('ALLO', 'CART')
        AND ac.TX_DT >= l.LOT1_START_DT
        AND ac.TX_DT <= l.OBS_END_DT
      GROUP BY ac.PATID
    ),
    auto_in_lot1 AS (
      SELECT a.PATID, a.TX_DT,
             row_number() OVER (PARTITION BY a.PATID ORDER BY a.TX_DT) AS LOT1_SEQ
      FROM tx_auto_dates a
      INNER JOIN lot1 l ON a.PATID = l.PATID
      LEFT JOIN earliest_non_auto ena ON a.PATID = ena.PATID
      WHERE a.TX_DT >= l.LOT1_START_DT
        AND a.TX_DT <= l.OBS_END_DT
        AND (ena.FIRST_NON_AUTO_DT IS NULL OR a.TX_DT < ena.FIRST_NON_AUTO_DT)
    ),
    auto_pivot AS (
      SELECT PATID,
        max(CASE WHEN LOT1_SEQ = 1 THEN TX_DT END) AS AUTO_DT_1,
        max(CASE WHEN LOT1_SEQ = 2 THEN TX_DT END) AS AUTO_DT_2,
        max(CASE WHEN LOT1_SEQ = 3 THEN TX_DT END) AS AUTO_DT_3
      FROM auto_in_lot1
      GROUP BY PATID
    ),
    -- First ALLO date within LOT1
    first_allo AS (
      SELECT ac.PATID, min(ac.TX_DT) AS ALLO_DT
      FROM tx_allo_cart_dates ac
      INNER JOIN lot1 l ON ac.PATID = l.PATID
      WHERE ac.SCT_TYPE = 'ALLO'
        AND ac.TX_DT >= l.LOT1_START_DT
        AND ac.TX_DT <= l.OBS_END_DT
      GROUP BY ac.PATID
    ),
    -- First CART date within LOT1
    first_cart AS (
      SELECT ac.PATID, min(ac.TX_DT) AS CART_DT
      FROM tx_allo_cart_dates ac
      INNER JOIN lot1 l ON ac.PATID = l.PATID
      WHERE ac.SCT_TYPE = 'CART'
        AND ac.TX_DT >= l.LOT1_START_DT
        AND ac.TX_DT <= l.OBS_END_DT
      GROUP BY ac.PATID
    ),
    -- Check for ALLO between AUTO_DT_1 and AUTO_DT_2 (inclusive, per spec)
    -- Spec: tandem disqualified if ALLO exists such that AUTO_DT_1 <= ALLO <= AUTO_DT_2
    allo_between AS (
      SELECT ap.PATID,
        sum(CASE WHEN ac.TX_DT >= ap.AUTO_DT_1 AND ac.TX_DT <= ap.AUTO_DT_2
                 THEN 1 ELSE 0 END) AS n_allo_between
      FROM auto_pivot ap
      LEFT JOIN tx_allo_cart_dates ac
        ON ap.PATID = ac.PATID AND ac.SCT_TYPE = 'ALLO'
      WHERE ap.AUTO_DT_2 IS NOT NULL
      GROUP BY ap.PATID
    ),
    -- Derive tandem flag and LOT-ending AUTO date
    sct_derived AS (
      SELECT
        l.PATID,
        ap.AUTO_DT_1 AS LOT1_TX_AUTO_DT_1,
        ap.AUTO_DT_2 AS LOT1_TX_AUTO_DT_2,
        -- Tandem: two AUTO SCTs within 180 days, no ALLO between
        CASE
          WHEN ap.AUTO_DT_2 IS NOT NULL
           AND datediff(ap.AUTO_DT_2, ap.AUTO_DT_1) + 1 <= {cfg$sct_tandem_days}
           AND coalesce(ab.n_allo_between, 0) = 0
          THEN 1 ELSE 0
        END AS LOT1_SCT_AUTO_TAND_FLG,
        -- Single AUTO: has first AUTO but not a valid tandem
        CASE
          WHEN ap.AUTO_DT_1 IS NOT NULL
           AND NOT (ap.AUTO_DT_2 IS NOT NULL
                    AND datediff(ap.AUTO_DT_2, ap.AUTO_DT_1) + 1 <= {cfg$sct_tandem_days}
                    AND coalesce(ab.n_allo_between, 0) = 0)
          THEN 1 ELSE 0
        END AS LOT1_SCT_AUTO_SING_FLG,
        -- LOT-ending AUTO: excess AUTO beyond what's allowed
        -- Tandem -> 3rd AUTO ends LOT1; Single -> 2nd AUTO ends LOT1
        CASE
          WHEN ap.AUTO_DT_2 IS NOT NULL
           AND datediff(ap.AUTO_DT_2, ap.AUTO_DT_1) + 1 <= {cfg$sct_tandem_days}
           AND coalesce(ab.n_allo_between, 0) = 0
          THEN ap.AUTO_DT_3
          WHEN ap.AUTO_DT_1 IS NOT NULL
          THEN ap.AUTO_DT_2
          ELSE NULL
        END AS ENDING_AUTO_DT,
        fa.ALLO_DT AS FIRST_ALLO_DT,
        fc.CART_DT AS FIRST_CART_DT
      FROM lot1 l
      LEFT JOIN auto_pivot ap ON l.PATID = ap.PATID
      LEFT JOIN allo_between ab ON l.PATID = ab.PATID
      LEFT JOIN first_allo fa ON l.PATID = fa.PATID
      LEFT JOIN first_cart fc ON l.PATID = fc.PATID
    )
    SELECT
      sd.*,
      -- LOT1_TX_ENDDATE: earliest LOT-ending SCT event - 1 day
      CASE
        WHEN coalesce(sd.ENDING_AUTO_DT, sd.FIRST_ALLO_DT, sd.FIRST_CART_DT) IS NOT NULL
        THEN date_sub(
          least(
            coalesce(sd.ENDING_AUTO_DT, cast('9999-12-31' as date)),
            coalesce(sd.FIRST_ALLO_DT,  cast('9999-12-31' as date)),
            coalesce(sd.FIRST_CART_DT,   cast('9999-12-31' as date))
          ), 1)
        ELSE NULL
      END AS LOT1_TX_ENDDATE,
      -- LOT1_TX_ENDDATE_REASON: 1=AUTO, 2=ALLO, 3=CART (whichever is earliest)
      CASE
        WHEN coalesce(sd.ENDING_AUTO_DT, sd.FIRST_ALLO_DT, sd.FIRST_CART_DT) IS NULL THEN NULL
        WHEN coalesce(sd.ENDING_AUTO_DT, cast('9999-12-31' as date))
             <= coalesce(sd.FIRST_ALLO_DT, cast('9999-12-31' as date))
         AND coalesce(sd.ENDING_AUTO_DT, cast('9999-12-31' as date))
             <= coalesce(sd.FIRST_CART_DT, cast('9999-12-31' as date))
        THEN 1
        WHEN coalesce(sd.FIRST_ALLO_DT, cast('9999-12-31' as date))
             <= coalesce(sd.FIRST_CART_DT, cast('9999-12-31' as date))
        THEN 2
        ELSE 3
      END AS LOT1_TX_ENDDATE_REASON,
      -- LOT1_1ST_SCT_DT: first SCT of any type during LOT1
      CASE
        WHEN coalesce(sd.LOT1_TX_AUTO_DT_1, sd.FIRST_ALLO_DT, sd.FIRST_CART_DT) IS NOT NULL
        THEN least(
          coalesce(sd.LOT1_TX_AUTO_DT_1, cast('9999-12-31' as date)),
          coalesce(sd.FIRST_ALLO_DT,     cast('9999-12-31' as date)),
          coalesce(sd.FIRST_CART_DT,      cast('9999-12-31' as date))
        )
        ELSE NULL
      END AS LOT1_1ST_SCT_DT
    FROM sct_derived sd
  "), qc = "
    SELECT
      count(*) AS n_patients,
      sum(CASE WHEN LOT1_TX_AUTO_DT_1 IS NOT NULL THEN 1 ELSE 0 END) AS n_with_auto,
      sum(CASE WHEN FIRST_ALLO_DT IS NOT NULL THEN 1 ELSE 0 END) AS n_with_allo,
      sum(CASE WHEN FIRST_CART_DT IS NOT NULL THEN 1 ELSE 0 END) AS n_with_cart,
      sum(LOT1_SCT_AUTO_TAND_FLG) AS n_tandem,
      sum(LOT1_SCT_AUTO_SING_FLG) AS n_single_auto,
      sum(CASE WHEN LOT1_TX_ENDDATE IS NOT NULL THEN 1 ELSE 0 END) AS n_with_sct_end
    FROM lot1_sct")

  # S16: LOT1_BASE_END - Final end reason incorporating SCT
  # End reason priority: SCT > MED_ADD > DISCONTINUATION > CENSORED
  # SCT takes highest priority because it definitively ends the LOT.
  run_step(con, "S16_lot1_base_end", "
    CREATE OR REPLACE TEMPORARY VIEW lot1_base_end AS
    SELECT
      lb.*,
      sct.LOT1_TX_AUTO_DT_1,
      sct.LOT1_TX_AUTO_DT_2,
      sct.LOT1_SCT_AUTO_TAND_FLG,
      sct.LOT1_SCT_AUTO_SING_FLG,
      sct.LOT1_TX_ENDDATE,
      sct.LOT1_TX_ENDDATE_REASON,
      sct.LOT1_1ST_SCT_DT,
      sct.FIRST_ALLO_DT,
      sct.FIRST_CART_DT,
      -- End reason: SCT > MED_ADD (at or before discon) > DISCONTINUATION > CENSORED
      CASE
        WHEN sct.LOT1_TX_ENDDATE IS NOT NULL
         AND (lb.LOT1_BASE_1ST_ADD_MED_DT IS NULL OR sct.LOT1_TX_ENDDATE <= lb.LOT1_BASE_1ST_ADD_MED_DT)
         AND (lb.LOT1_BASE_DISCON_DT IS NULL OR sct.LOT1_TX_ENDDATE <= lb.LOT1_BASE_DISCON_DT)
        THEN CASE sct.LOT1_TX_ENDDATE_REASON
               WHEN 1 THEN 'SCT_AUTO'
               WHEN 2 THEN 'SCT_ALLO'
               WHEN 3 THEN 'SCT_CART'
               ELSE 'SCT'
             END
        WHEN lb.LOT1_BASE_1ST_ADD_MED_DT IS NOT NULL
         AND (lb.LOT1_BASE_DISCON_DT IS NULL OR lb.LOT1_BASE_1ST_ADD_MED_DT <= lb.LOT1_BASE_DISCON_DT)
        THEN 'MED_ADD'
        WHEN lb.LOT1_BASE_DISCON_DT IS NOT NULL THEN 'DISCONTINUATION'
        ELSE 'CENSORED'
      END AS LOT1_BASE_END_REASON,
      CASE
        WHEN sct.LOT1_TX_ENDDATE IS NOT NULL
         AND (lb.LOT1_BASE_1ST_ADD_MED_DT IS NULL OR sct.LOT1_TX_ENDDATE <= lb.LOT1_BASE_1ST_ADD_MED_DT)
         AND (lb.LOT1_BASE_DISCON_DT IS NULL OR sct.LOT1_TX_ENDDATE <= lb.LOT1_BASE_DISCON_DT)
        THEN sct.LOT1_TX_ENDDATE
        WHEN lb.LOT1_BASE_1ST_ADD_MED_DT IS NOT NULL
         AND (lb.LOT1_BASE_DISCON_DT IS NULL OR lb.LOT1_BASE_1ST_ADD_MED_DT <= lb.LOT1_BASE_DISCON_DT)
        THEN lb.LOT1_BASE_1ST_ADD_MED_DT
        WHEN lb.LOT1_BASE_DISCON_DT IS NOT NULL THEN lb.LOT1_BASE_DISCON_DT
        ELSE lb.OBS_END_DT
      END AS LOT1_BASE_END_DT
    FROM lot1_base lb
    LEFT JOIN lot1_sct sct ON lb.PATID = sct.PATID
  ", qc = "
    SELECT LOT1_BASE_END_REASON, count(*) AS n
    FROM lot1_base_end
    GROUP BY LOT1_BASE_END_REASON
    ORDER BY LOT1_BASE_END_REASON")

  log_msg("NOTE: Maintenance (mono/dual) specs not yet provided; LOT1_BASE_END_REASON")
  log_msg("      does not yet include MAINTENANCE_START. Will need integration when available.")

  # ----------------------------------------------------------
  # NDC Format QC (Fix #5 from review)
  # Validates NDC length match between codelist and claims
  # ----------------------------------------------------------
  log_msg("Running NDC format QC...")
  tryCatch({
    ndc_qc_codelist <- db_q(con, "
      SELECT length(CL_CODE) AS ndc_len, count(*) AS n
      FROM mma_codelist
      WHERE CL_CODE_TYPE = 'NDC'
      GROUP BY length(CL_CODE)
      ORDER BY length(CL_CODE)
    ")
    log_msg("  NDC length distribution in codelist:")
    print(ndc_qc_codelist)

    # Restrict to cohort PATIDs + date window to avoid full RX scan
    ndc_qc_rx <- db_q(con, glue("
      SELECT length(upper(regexp_replace(coalesce(cast(r.NDC as string),''), '[^A-Za-z0-9]', ''))) AS ndc_len,
             count(*) AS n
      FROM {cdm_src(cfg$tbl_rx)} r
      INNER JOIN lot_patient_input p ON r.PATID = p.PATID
      WHERE cast(r.NDC as string) IS NOT NULL AND trim(cast(r.NDC as string)) <> ''
        AND cast(r.FILL_DT AS date) >= p.INDEX_DATE
        AND cast(r.FILL_DT AS date) <= p.OBS_END_DT
      GROUP BY length(upper(regexp_replace(coalesce(cast(r.NDC as string),''), '[^A-Za-z0-9]', '')))
      ORDER BY ndc_len
    "))
    log_msg("  NDC length distribution in RX claims:")
    print(ndc_qc_rx)

    # Check for mismatches
    codelist_lens <- ndc_qc_codelist$ndc_len
    rx_lens <- ndc_qc_rx$ndc_len
    if (length(intersect(codelist_lens, rx_lens)) == 0 && length(codelist_lens) > 0 && length(rx_lens) > 0) {
      log_msg("  WARNING: NDC lengths in codelist and RX table DO NOT OVERLAP!")
      log_msg("  This may cause silent misses in pharmacy claim matching.")
      log_msg("  Codelist lengths: ", paste(codelist_lens, collapse = ", "))
      log_msg("  RX table lengths: ", paste(rx_lens, collapse = ", "))
    }
  }, error = function(e) {
    log_msg("  WARNING: NDC QC failed: ", e$message)
  })

  # ----------------------------------------------------------
  # Validation QC Suite (Fix #10 from review)
  # Must-run validations for MAP + LOT correctness
  # ----------------------------------------------------------
  log_msg("Running validation QC suite...")
  tryCatch({
    # A) MMA_MED coverage by source
    log_msg("  [A] MMA_MED extraction coverage:")
    coverage <- db_q(con, "
      SELECT CODE_TYPE, CLAIM_TYPE, count(*) AS n_claims, count(DISTINCT PATID) AS n_patients, count(DISTINCT MED_ABBR) AS n_meds
      FROM mma_med_processed
      GROUP BY CODE_TYPE, CLAIM_TYPE
      ORDER BY CODE_TYPE, CLAIM_TYPE
    ")
    print(coverage)

    # B) MAP correctness spot checks
    log_msg("  [B] MAP algorithm spot checks:")
    # Check no MAP has end < start
    bad_maps <- db_q(con, "SELECT count(*) AS n_bad FROM map_stacked WHERE MAP_END_DT < MAP_START_DT")$n_bad
    log_msg("    MAPs with END < START: ", bad_maps, if (bad_maps > 0) " ** INVESTIGATE **" else " (OK)")

    # Check MAP_END_DT = max(rx_runout, med_runout)
    runout_check <- db_q(con, "
      SELECT count(*) AS n_mismatch
      FROM map_stacked
      WHERE MAP_END_DT <> greatest(
        coalesce(MAP_RX_RUNOUT_DT, cast('1900-01-01' as date)),
        coalesce(MAP_MED_RUNOUT_DT, cast('1900-01-01' as date))
      )
      AND MAP_END_DT IS NOT NULL
    ")$n_mismatch
    log_msg("    MAPs where END_DT != max(rx_runout, med_runout): ", runout_check,
            if (runout_check > 0) " ** INVESTIGATE **" else " (OK)")

    # MAPs with both rx and med sources (mixed claim type coverage)
    both_src <- db_q(con, "
      SELECT count(*) AS n_maps_both_sources
      FROM map_stacked
      WHERE MAP_RX_RUNOUT_DT IS NOT NULL AND MAP_MED_RUNOUT_DT IS NOT NULL
    ")$n_maps_both_sources
    log_msg("    MAPs with both pharmacy + medical sources: ", format(both_src, big.mark = ","))

    # C) ENDDATE_CE vs ENDDATE sensitivity
    log_msg("  [C] OBS_END_DT (ENDDATE_CE) sensitivity:")
    ce_sens <- db_q(con, "
      SELECT
        sum(case when ENDDATE_CE < ENDDATE then 1 else 0 end) AS n_disenrolled_early,
        count(*) AS n_total,
        avg(case when ENDDATE_CE < ENDDATE then datediff(ENDDATE, ENDDATE_CE) else 0 end) AS avg_gap_days
      FROM lot_patient_input
    ")
    log_msg("    Patients disenrolled before study ENDDATE: ",
            format(ce_sens$n_disenrolled_early, big.mark = ","),
            " / ", format(ce_sens$n_total, big.mark = ","),
            " (", round(100 * ce_sens$n_disenrolled_early / max(ce_sens$n_total, 1), 1), "%)")
    log_msg("    Avg gap (ENDDATE - ENDDATE_CE): ", round(ce_sens$avg_gap_days, 1), " days")

    # D) LOT1 completeness
    log_msg("  [D] LOT1 completeness:")
    lot1_check <- db_q(con, "
      SELECT
        count(*) AS n_lot1,
        sum(case when lb.LOT1_BASE_END_DT > p.OBS_END_DT then 1 else 0 end) AS n_end_past_obs
      FROM lot1_base_end lb
      INNER JOIN lot_patient_input p ON lb.PATID = p.PATID
    ")
    log_msg("    LOT1 patients: ", format(lot1_check$n_lot1, big.mark = ","))
    log_msg("    LOT1_BASE_END_DT > OBS_END_DT: ", lot1_check$n_end_past_obs,
            if (lot1_check$n_end_past_obs > 0) " ** INVESTIGATE **" else " (OK)")

    # E) Rollup flag sanity
    log_msg("  [E] Rollup flag validation:")
    flag_check <- db_q(con, "
      SELECT CL_MED_ABBR, CL_MED_CLASS, MONOMAINTENANCE, CONDITIONING, USED_FOR_OTHER_CANCERS
      FROM mma_rollup
      ORDER BY CL_MED_CLASS, CL_MED_ABBR
    ")
    print(flag_check)

    # F) SCT consistency
    log_msg("  [F] SCT validation:")
    sct_check <- db_q(con, "
      SELECT
        sum(CASE WHEN LOT1_TX_ENDDATE IS NOT NULL AND LOT1_TX_ENDDATE > lb.OBS_END_DT THEN 1 ELSE 0 END)
          AS n_sct_end_past_obs,
        sum(CASE WHEN LOT1_SCT_AUTO_TAND_FLG = 1 AND LOT1_SCT_AUTO_SING_FLG = 1 THEN 1 ELSE 0 END)
          AS n_both_tandem_and_single,
        sum(CASE WHEN LOT1_TX_AUTO_DT_1 IS NOT NULL AND LOT1_TX_AUTO_DT_1 < lb.LOT1_START_DT THEN 1 ELSE 0 END)
          AS n_auto_before_lot1
      FROM lot1_sct sct
      INNER JOIN lot1_base lb ON sct.PATID = lb.PATID
    ")
    log_msg("    SCT end date past OBS_END_DT: ", sct_check$n_sct_end_past_obs,
            if (sct_check$n_sct_end_past_obs > 0) " ** INVESTIGATE **" else " (OK)")
    log_msg("    Both tandem AND single flag: ", sct_check$n_both_tandem_and_single,
            if (sct_check$n_both_tandem_and_single > 0) " ** BUG **" else " (OK)")
    log_msg("    AUTO DT_1 before LOT1_START: ", sct_check$n_auto_before_lot1,
            if (sct_check$n_auto_before_lot1 > 0) " ** INVESTIGATE **" else " (OK)")

    log_msg("Validation QC suite complete.")
  }, error = function(e) {
    log_msg("WARNING: Validation QC suite failed: ", e$message)
  })

  # ----------------------------------------------------------
  # Descriptives + Figures
  # ----------------------------------------------------------
  log_msg("Generating descriptive summary and figures...")
  print_descriptives(con)

  # ----------------------------------------------------------
  # Persist outputs
  # ----------------------------------------------------------
  if (isTRUE(cfg$persist_to_schema)) {
    run_step(con, "S17_persist_map_stacked", glue("
      CREATE OR REPLACE TABLE {wrk('MAP_STACKED')} AS
      SELECT * FROM map_stacked
    "), qc = glue("SELECT count(*) AS n_rows FROM {wrk('MAP_STACKED')}"))

    run_step(con, "S18_persist_lot1_base", glue("
      CREATE OR REPLACE TABLE {wrk('LOT1_BASE')} AS
      SELECT * FROM lot1_base
    "), qc = glue("SELECT count(*) AS n_rows FROM {wrk('LOT1_BASE')}"))

    run_step(con, "S19_persist_lot1_sct", glue("
      CREATE OR REPLACE TABLE {wrk('LOT1_SCT')} AS
      SELECT * FROM lot1_sct
    "), qc = glue("SELECT count(*) AS n_rows FROM {wrk('LOT1_SCT')}"))

    run_step(con, "S20_persist_lot1_base_end", glue("
      CREATE OR REPLACE TABLE {wrk('LOT1_BASE_END')} AS
      SELECT * FROM lot1_base_end
    "), qc = glue("SELECT count(*) AS n_rows FROM {wrk('LOT1_BASE_END')}"))

    # Persist MMA_MED_PROCESSED — foundation exposure table for QA/traceability
    run_step(con, "S21_persist_mma_med_processed", glue("
      CREATE OR REPLACE TABLE {wrk('MMA_MED_PROCESSED')} AS
      SELECT * FROM mma_med_processed
    "), qc = glue("SELECT count(*) AS n_rows FROM {wrk('MMA_MED_PROCESSED')}"))

    # Persist run metadata — parameters + key counts for rerun comparison
    tryCatch({
      cohort_n <- as.numeric(db_q(con, "SELECT count(DISTINCT PATID) AS n FROM lot_patient_input")$n)
      mma_n    <- as.numeric(db_q(con, "SELECT count(*) AS n FROM mma_med_processed")$n)
      map_n    <- as.numeric(db_q(con, "SELECT count(*) AS n FROM map_stacked")$n)
      lot1_n   <- as.numeric(db_q(con, "SELECT count(*) AS n FROM lot1_base")$n)

      # Create metadata table if not exists, then append this run
      run_step(con, "S22a_create_metadata_table", glue("
        CREATE TABLE IF NOT EXISTS {wrk('LOT_RUN_METADATA')} (
          RUN_ID STRING, RUN_TIMESTAMP TIMESTAMP,
          CDM_SCHEMA STRING, WORK_SCHEMA STRING, INPUT_COHORT_TABLE STRING,
          INDUCTION_WINDOW_DAYS INT, MAP_DISCON_GAP_DAYS INT,
          MEDICAL_DAY_SUPPLY INT, LOT_DISCON_GAP_DAYS INT,
          N_COHORT_PATIENTS BIGINT, N_MMA_CLAIMS BIGINT,
          N_MAPS BIGINT, N_LOT1_PATIENTS BIGINT
        )
      "))
      # Delete any prior row for this exact run_id (idempotent re-runs)
      run_step(con, "S22b_dedup_metadata", glue("
        DELETE FROM {wrk('LOT_RUN_METADATA')} WHERE RUN_ID = '{run_id}'
      "))
      run_step(con, "S22c_insert_run_metadata", glue("
        INSERT INTO {wrk('LOT_RUN_METADATA')}
        SELECT
          '{run_id}' AS RUN_ID,
          current_timestamp() AS RUN_TIMESTAMP,
          '{cfg$cdm_schema}' AS CDM_SCHEMA,
          '{cfg$work_schema}' AS WORK_SCHEMA,
          '{cfg$input_cohort_table}' AS INPUT_COHORT_TABLE,
          {cfg$induction_window_days} AS INDUCTION_WINDOW_DAYS,
          {cfg$map_discon_gap_days} AS MAP_DISCON_GAP_DAYS,
          {cfg$medical_day_supply} AS MEDICAL_DAY_SUPPLY,
          {cfg$lot_discon_gap_days} AS LOT_DISCON_GAP_DAYS,
          {cohort_n} AS N_COHORT_PATIENTS,
          {mma_n} AS N_MMA_CLAIMS,
          {map_n} AS N_MAPS,
          {lot1_n} AS N_LOT1_PATIENTS
      "))
    }, error = function(e) {
      log_msg("  WARNING: Run metadata persist failed: ", conditionMessage(e))
    })

    # Persist QC summary — one row per check for governance
    tryCatch({
      qc_checks <- list()
      add_persist_qc <- function(name, val) {
        status <- if (is.na(val)) "ERROR" else if (val == 0) "PASS" else "WARN"
        qc_checks[[length(qc_checks) + 1]] <<- glue(
          "SELECT '{name}' AS CHECK_NAME, {if (is.na(val)) 'NULL' else val} AS CHECK_VALUE, '{status}' AS CHECK_STATUS, '{run_id}' AS RUN_ID"
        )
      }

      orphan_n <- tryCatch(as.numeric(db_q(con, "
        SELECT count(DISTINCT c.CL_MED_ABBR) AS n
        FROM mma_codelist c LEFT JOIN mma_rollup r ON c.CL_MED_ABBR = r.CL_MED_ABBR
        WHERE r.CL_MED_ABBR IS NULL")$n), error = function(e) NA)
      add_persist_qc("CODELIST_ORPHAN_MEDS", orphan_n)

      bad_maps <- tryCatch(as.numeric(db_q(con, "SELECT count(*) AS n FROM map_stacked WHERE MAP_END_DT < MAP_START_DT")$n), error = function(e) NA)
      add_persist_qc("MAP_END_BEFORE_START", bad_maps)

      lot1_past <- tryCatch(as.numeric(db_q(con, "
        SELECT sum(case when lb.LOT1_BASE_END_DT > p.OBS_END_DT then 1 else 0 end) AS n
        FROM lot1_base_end lb INNER JOIN lot_patient_input p ON lb.PATID = p.PATID")$n), error = function(e) NA)
      add_persist_qc("LOT1_END_PAST_OBS", lot1_past)

      sct_both <- tryCatch(as.numeric(db_q(con, "
        SELECT sum(CASE WHEN LOT1_SCT_AUTO_TAND_FLG = 1 AND LOT1_SCT_AUTO_SING_FLG = 1 THEN 1 ELSE 0 END) AS n
        FROM lot1_sct")$n), error = function(e) NA)
      add_persist_qc("SCT_TANDEM_AND_SINGLE", sct_both)

      if (length(qc_checks) > 0) {
        qc_union <- paste(qc_checks, collapse = "\n        UNION ALL\n        ")
        # Create QC table if not exists, then append this run's checks
        run_step(con, "S23a_create_qc_table", glue("
          CREATE TABLE IF NOT EXISTS {wrk('LOT_QC_SUMMARY')} (
            CHECK_NAME STRING, CHECK_VALUE BIGINT, CHECK_STATUS STRING, RUN_ID STRING
          )
        "))
        run_step(con, "S23b_dedup_qc", glue("
          DELETE FROM {wrk('LOT_QC_SUMMARY')} WHERE RUN_ID = '{run_id}'
        "))
        run_step(con, "S23c_insert_qc_summary", glue("
          INSERT INTO {wrk('LOT_QC_SUMMARY')}
          {qc_union}
        "))
      }
    }, error = function(e) {
      log_msg("  WARNING: QC summary persist failed: ", conditionMessage(e))
    })

  } else {
    log_msg("Persist disabled (PERSIST_TO_SCHEMA=FALSE).")
  }

  log_msg(SEP)
  log_msg("LOT Part 2 complete.")
  log_msg("Temporary views: mma_med_processed, map_stacked, lot1_base, lot1_sct, lot1_base_end")
  if (isTRUE(cfg$persist_to_schema)) {
    log_msg("Persisted tables in work schema: MAP_STACKED, LOT1_BASE, LOT1_SCT, LOT1_BASE_END, MMA_MED_PROCESSED, LOT_RUN_METADATA, LOT_QC_SUMMARY")
  }
  if (has_ggplot2) {
    log_msg("Figures saved to: ", cfg$output_dir)
  }
  log_msg(SEP)

  invisible(TRUE)
}

if (sys.nframe() == 0) {
  main()
}
