# Runner for the dashboard build. Standalone: one module, pointed at a cohort
# table and the prefix the LOT run wrote under.
#
# It runs after the cohort build and the LOT build, reads what they produced,
# and writes one HTML file. It creates no warehouse table and changes no
# number - which is what lets it be re-run against a finished study as often as
# anyone wants without touching the study.
#
# Nothing here names a cohort, and nothing here decides what the dashboard
# shows: that is sections.R.

`%||%` <- function(a, b) if (is.null(a)) b else a

# Settings that decide what a dashboard run means. Everything that varies per
# run - the cohort, the prefixes, where the file goes - is an argument instead.
CONTRACT <- list(
  catalog = "hive_metastore",
  dsn     = "RWDE",
  top_n   = 10L,
  journeys_per_category = 3L
)

BOOL_SETTINGS <- "EXPORT_CSV"
INT_SETTINGS  <- c("TOP_N", "MAX_RETRIES", "JOURNEYS_PER_CATEGORY")

check_settings <- function() {
  bad <- character(0)
  for (v in BOOL_SETTINGS) {
    x <- Sys.getenv(v, unset = "")
    # as.logical("Y") is NA, which reads as FALSE - so an operator who asked for
    # the export in the wrong word would get no files and no complaint.
    if (nzchar(x) && !(toupper(x) %in% c("TRUE", "FALSE")))
      bad <- c(bad, paste0(v, "='", x, "' (want TRUE or FALSE)"))
  }
  for (v in INT_SETTINGS) {
    x <- trimws(Sys.getenv(v, unset = ""))
    # The text, not what coercion makes of it: as.integer("10.5") is 10, so a
    # decimal would pass and the run would use a number nobody asked for.
    if (nzchar(x) && !grepl("^[0-9]+$", x))
      bad <- c(bad, paste0(v, "='", x, "' (want a whole number)"))
  }
  s <- Sys.getenv("PROJECT_WORK_SCHEMA", unset = "")
  if (grepl(".", s, fixed = TRUE))
    bad <- c(bad, paste0("PROJECT_WORK_SCHEMA='", s,
                         "' is catalog.schema; it wants a schema name"))
  # Every SHOW_<NAME> is read as TRUE/FALSE and a third value stops the build.
  # A dashboard with a panel silently missing is worse than one that refuses to
  # build, because the gap is invisible in the output.
  for (sec in DASHBOARD_SECTIONS) {
    x <- Sys.getenv(paste0("SHOW_", toupper(sec$name)), unset = "")
    if (nzchar(x) && !(toupper(x) %in% c("TRUE", "FALSE")))
      bad <- c(bad, paste0("SHOW_", toupper(sec$name), "='", x,
                           "' (want TRUE or FALSE)"))
  }
  if (length(bad))
    stop("Settings that would build a different dashboard:\n  ",
         paste(bad, collapse = "\n  "), call. = FALSE)
  invisible(TRUE)
}

pin_output_schema <- function(cfg) {
  schema <- Sys.getenv("PROJECT_WORK_SCHEMA",
              unset = Sys.getenv("DOMINO_USER_NAME",
                unset = Sys.getenv("DOMINO_STARTING_USERNAME", unset = "")))
  if (!nzchar(schema))
    stop("No schema to read from. Set DOMINO_USER_NAME to the schema the ",
         "cohort and LOT builds wrote into, or PROJECT_WORK_SCHEMA to override.",
         call. = FALSE)
  if (!grepl("^[A-Za-z_][A-Za-z0-9_]*$", schema))
    stop("Schema '", schema, "' is not a schema name.", call. = FALSE)
  cfg$work_schema <- schema
  cfg
}

# The caller says which cohort and which prefix. Both end up in SQL identifiers,
# so both are held to what an identifier allows - the same check lot makes,
# for the same reason.
pin_target <- function(cfg, cohort_table, lot_prefix, cohort_prefix = NULL) {
  cohort_table <- trimws(as.character(cohort_table %||% ""))
  lot_prefix   <- trimws(as.character(lot_prefix %||% ""))
  cohort_prefix <- trimws(as.character(cohort_prefix %||% ""))
  if (!nzchar(cohort_table)) cohort_table <- cfg$input_cohort_table %||% ""
  if (!nzchar(lot_prefix))   lot_prefix   <- cfg$lot_prefix %||% ""
  if (!nzchar(cohort_prefix)) cohort_prefix <- cfg$cohort_prefix %||% ""
  if (!nzchar(cohort_table) || !nzchar(lot_prefix))
    stop("The dashboard needs a cohort table and the prefix the LOT run used.\n",
         "  Rscript build.R <COHORT_TABLE> <lot_prefix_> [<cohort_prefix_>]\n",
         "  or set INPUT_COHORT_TABLE and LOT_PREFIX.", call. = FALSE)
  if (!grepl("^[A-Za-z_][A-Za-z0-9_]*$", cohort_table))
    stop("Cohort table '", cohort_table, "' is not a table name. Give the ",
         "table only - the catalog and schema come from the settings.",
         call. = FALSE)
  for (p in list(c("LOT prefix", lot_prefix),
                 c("cohort prefix", cohort_prefix)))
    if (nzchar(p[2]) && !grepl("^[A-Za-z][A-Za-z0-9_]*_$", p[2]))
      stop(p[1], " '", p[2], "' should be a name ending in '_', e.g. mystudy_.",
           call. = FALSE)
  cfg$input_cohort_table <- cohort_table
  cfg$lot_prefix         <- lot_prefix
  cfg$cohort_prefix      <- cohort_prefix
  cfg
}

check_dash_contract <- function(cfg) {
  wrong <- Filter(Negate(is.null), lapply(names(CONTRACT), function(k) {
    if (isTRUE(all.equal(cfg[[k]], CONTRACT[[k]]))) NULL
    else paste0(k, " = ", format(cfg[[k]]), " (want ", format(CONTRACT[[k]]), ")")
  }))
  if (length(wrong))
    stop("This dashboard is defined as:\n  ", paste(unlist(wrong), collapse = "\n  "),
         call. = FALSE)
  if (!nzchar(cfg$output_dir %||% ""))
    stop("No output directory, so the dashboard would have nowhere to go.",
         call. = FALSE)
  invisible(TRUE)
}

load_dash_modules <- function(here) {
  source(file.path(here, "R", "load_inputs.R"))
  load_pipeline_inputs(here, "config.csv")
  for (f in c("config_dash.R", "db_utils_dash.R", "sections.R", "render.R"))
    source(file.path(here, "R", f))
  invisible(TRUE)
}

# Fill a section's {placeholders} from the resolved input names. Deliberately
# not glue(): a section's SQL is data, and the only names it may reach are the
# ones handed to it here - not whatever happens to be in scope.
fill_sql <- function(sql, inputs, cfg) {
  vals <- c(inputs, list(top_n = cfg$top_n,
                         journeys_per_category = cfg$journeys_per_category))
  for (nm in names(vals)) {
    v <- vals[[nm]]
    # A setting that is absent leaves its placeholder in place, so it comes out
    # of the check below by name. Substituting character(0) would instead throw
    # somewhere inside gsub, naming nothing.
    if (is.null(v) || !length(v) || is.na(v[1])) next
    sql <- gsub(paste0("{", nm, "}"), as.character(v[1]), sql, fixed = TRUE)
  }
  left <- regmatches(sql, gregexpr("\\{[A-Za-z_][A-Za-z0-9_]*\\}", sql))[[1]]
  if (length(left))
    stop("A section names something the run cannot fill: ",
         paste(unique(left), collapse = ", "),
         ". Either it is not an input, or the setting behind it is unset.",
         call. = FALSE)
  sql
}

# One panel. A section whose query fails does not take the dashboard with it -
# the other panels are still true, and a panel that says why it is missing is
# more use than a run that produced no file. The message goes in the panel and
# in the log, so it cannot be missed by reading only one of them.
build_panel <- function(con, sec, inputs, have, cfg) {
  missing <- sec$needs[!have[sec$needs]]
  if (length(missing)) {
    log_msg("  skip  ", sec$name, " - no ", paste(missing, collapse = ", "))
    return(list(name = sec$name, tab = sec$tab, label = sec$label, data = NULL,
                html = paste0('<p class="skip">Not shown: this run has no ',
                              paste(missing, collapse = ", "), " table.</p>")))
  }
  df <- tryCatch(db_q(con, fill_sql(sec$sql, inputs, cfg)),
                 error = function(e) e)
  if (inherits(df, "error")) {
    log_msg("  FAIL  ", sec$name, " - ", conditionMessage(df))
    return(list(name = sec$name, tab = sec$tab, label = sec$label, data = NULL,
                html = paste0('<p class="skip">Not shown: the query failed. ',
                              .h(conditionMessage(df)), "</p>")))
  }
  log_msg("  ok    ", sec$name, " (", nrow(df), " row(s))")
  # The frame is carried out beside the HTML, not re-queried: the CSV export
  # has to be the numbers on the page, or the two are a comparison waiting to
  # go wrong.
  list(name = sec$name, tab = sec$tab, label = sec$label, data = df,
       html = render_panel(sec$render, df, sec$pct %||% "none"))
}

# One CSV per panel that produced rows, beside the HTML. Same numbers, because
# the frames come from the panels rather than from a second pass at the
# warehouse - a re-query could disagree with the page if anything moved.
#
# Nothing here is un-masked: patient_journeys masks PATID in its own SQL, so
# what reaches the file is what reaches the page. No section selects a raw
# identifier, and a test holds that.
write_csv_exports <- function(panels, cfg) {
  dir <- file.path(cfg$output_dir, cfg$csv_dir)
  dir.create(dir, showWarnings = FALSE, recursive = TRUE)
  # The folder is one run, not an accumulation. A panel switched off, a query
  # that failed, a panel that came back empty, or the same OUTPUT_DIR reused for
  # another cohort all leave a file from last time that looks current - the
  # names carry no cohort, prefix or run id to tell it apart. Clear first, so
  # what is here is what is on the page.
  #
  # Only .csv, and only this folder, which the dashboard created and owns.
  old <- list.files(dir, pattern = "[.]csv$", full.names = TRUE)
  if (length(old)) {
    unlink(old)
    log_msg("CSV export: cleared ", length(old), " file(s) from the previous run")
  }
  written <- 0L
  for (p in panels) {
    if (is.null(p$data) || !nrow(p$data)) next
    path <- file.path(dir, paste0(p$name, ".csv"))
    # na = "": an empty cell reads as absent in every spreadsheet, where the
    # text NA reads as a value and sorts among the words.
    utils::write.csv(p$data, path, row.names = FALSE, na = "")
    written <- written + 1L
  }
  log_msg("CSV export: ", written, " file(s) -> ", dir)
  invisible(written)
}

build_dashboard_run <- function(here, cohort_table, lot_prefix,
                                cohort_prefix = NULL) {
  check_settings()
  cfg <- pin_output_schema(cfg_defaults)
  cfg <- pin_target(cfg, cohort_table, lot_prefix, cohort_prefix)
  check_dash_contract(cfg)
  set_dash_config(cfg)

  secs <- enabled_sections()
  if (!length(secs))
    stop("Every section is switched off, so the dashboard would be empty. ",
         "Turn at least one SHOW_* on in config.csv.", call. = FALSE)

  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")
  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  log_msg(SEP)
  log_msg("Dashboard for ", cfg$input_cohort_table, " / ", cfg$lot_prefix, "*")
  log_msg("  Work schema:  ", cfg$work_schema)
  log_msg("  Sections:     ", length(secs), " of ", length(DASHBOARD_SECTIONS))

  inputs <- dashboard_inputs(cfg)
  validate_sections(DASHBOARD_SECTIONS, inputs)
  have <- probe_inputs(con, inputs)
  for (nm in names(inputs))
    log_msg("  ", if (have[[nm]]) "found  " else "MISSING", nm, ": ", inputs[[nm]])
  # LOT_LONG is the one nothing works without: every tab but the cohort one
  # reads it, and a dashboard of two panels is not worth writing.
  if (!isTRUE(have[["lot_long"]]))
    stop("No ", inputs$lot_long, ". The dashboard reads what the LOT build ",
         "produced, so it cannot run before that build has. Check the prefix.",
         call. = FALSE)

  panels <- lapply(secs, build_panel, con = con, inputs = inputs,
                   have = have, cfg = cfg)

  dir.create(cfg$output_dir, showWarnings = FALSE, recursive = TRUE)
  path <- file.path(cfg$output_dir, cfg$output_file)
  writeLines(render_document(
    panels,
    title = paste0(cfg$input_cohort_table, " - lines of therapy"),
    subtitle = paste0(length(panels), " panels | schema ", cfg$work_schema,
                      " | prefix ", cfg$lot_prefix, " | run ", run_id,
                      " | built ", format(Sys.time(), "%Y-%m-%d %H:%M"))), path)
  if (isTRUE(cfg$export_csv)) write_csv_exports(panels, cfg)
  else log_msg("CSV export off (EXPORT_CSV=FALSE)")
  log_msg("Dashboard written: ", path)
  log_msg(SEP)
  invisible(path)
}
