# Runner for the dashboard build. Standalone: one module, pointed at a cohort
# table and the prefix the LOT run wrote under.
#
# Runs after the cohort build and the LOT build, reads what they produced, and
# writes one HTML file. It creates no table and changes no number, so it can be
# re-run against a finished study as often as anyone wants.
#
# Nothing here names a cohort or decides what is shown - that is sections.R.

# Settings that decide what a dashboard run means. Everything that varies per
# run - the cohort, the prefixes, where the file goes - is an argument instead.
CONTRACT <- list(
  catalog = "hive_metastore",
  dsn     = "RWDE",
  top_n   = 10L,
  journeys_per_category = 3L
)

BOOL_SETTINGS <- "EXPORT_CSV"
INT_SETTINGS  <- c("TOP_N", "MAX_RETRIES", "JOURNEYS_PER_CATEGORY",
                   "ATTRITION_WINDOW")

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
  # It becomes a column name - n_30, n_60, n_90 - so a fourth value names a
  # column that does not exist and the panel fails with the warehouse's word
  # for it rather than ours. Those three are the columns the overall build
  # writes, and it computes no others.
  w <- trimws(Sys.getenv("ATTRITION_WINDOW", unset = ""))
  if (nzchar(w) && !(w %in% c("30", "60", "90")))
    bad <- c(bad, paste0("ATTRITION_WINDOW='", w, "' (want 30, 60 or 90)"))
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
  # ATTRITION_TABLE reaches SQL the same way the cohort table does - pasted
  # after the prefix into an identifier - so it is held to the same rule. It was
  # the one configurable name that was not, which would have turned a space or a
  # dotted name into a malformed identifier and a panel that says the query
  # failed, while every other bad name is refused up front.
  for (v in list(c("ATTRITION_TABLE", "attrition_table"),
                 c("FU_CE_COUNTS_TABLE", "fu_ce_counts_table"))) {
    at <- trimws(as.character(cfg[[v[2]]] %||% ""))
    if (!nzchar(at) || !grepl("^[A-Za-z_][A-Za-z0-9_]*$", at))
      stop(v[1], " '", at, "' is not a table name. Give the table only, ",
           "without a schema - the prefix and schema are added for you.",
           call. = FALSE)
  }
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
                         journeys_per_category = cfg$journeys_per_category,
                         attrition_window = cfg$attrition_window,
                         owner_run = cfg$owner_run,
                         cohort_run = cfg$cohort_run))
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

# Point the attrition section at the funnel the cohort build actually wrote.
#
# ATTRITION_TABLE makes the name configurable. The shape is not: it is whatever
# the cohort build chose, so the layout is DETECTED - DESCRIBE the table and
# match its columns - rather than a second setting that can disagree with the
# warehouse.
#
# Also where the funnel is checked against the cohort LOT actually read. lot
# records COHORT_RUN_ID, so this is an exact comparison against the funnel's
# own RUN_ID. Timestamps could not answer it: a cohort rebuilt WHILE LOT was
# running is newer than the cohort LOT read but older than LOT's finish.
# The CE-window panel, tied to the cohort LOT read, the same way the funnel is.
#
# Its table is CREATE OR REPLACE, so a cohort rebuilt under this prefix takes
# it with it - and the panel would then price a window against a cohort that is
# not the one the lines below it came from.
#
# The stamp is new, so a cohort built before it has no RUN_ID column and
# selecting one would fail the panel outright. DESCRIBE decides: stamped and
# tied, stamped and gone, or unstamped and labelled as untied.

# Was this table written after the moment LOT recorded reading that cohort?
#
# Three answers, not two. A refused query, a missing stamp column, a LOT run
# that recorded no stamp and a timestamp as.POSIXct() will not take must not
# collapse into FALSE - "not a later attempt", the one thing none of them
# establishes - and the panel would go out labelled as though it had been
# checked.
#
#   TRUE  written after the stamp - a later attempt under the same run id
#   FALSE written at or before it - the attempt LOT read
#   NA    could not tell
#
# First column by position: the alias is ours, the case it comes back in is the
# driver's.
stamp_is_newer <- function(con, sql, st) {
  when <- function(x) {
    x <- as.character(x)
    if (!length(x) || is.na(x[1]) || !nzchar(trimws(x[1]))) return(NA_real_)
    t <- suppressWarnings(tryCatch(as.POSIXct(x[1], tz = "UTC"),
                                   error = function(e) NULL))
    if (!length(t) || is.na(t[1])) NA_real_ else as.numeric(t[1])
  }
  d <- tryCatch(db_q(con, sql), error = function(e) NULL)
  got <- if (is.null(d) || !nrow(d) || !ncol(d)) NULL else d[[1]][1]
  a <- when(got); b <- when(st)
  if (is.na(a) || is.na(b)) return(NA)
  a > b
}

# What a panel pinned to a run id may claim about the attempt behind it.
UNVERIFIED_ATTEMPT <- " (attempt not verified)"

resolve_fu_ce_window <- function(secs, con, inputs, have, owner) {
  i <- which(vapply(secs, function(s) identical(s$name, "fu_ce_window"), logical(1)))
  if (!length(i) || !isTRUE(have[["fu_ce_counts"]])) return(secs)
  sec  <- secs[[i]]
  cols <- table_cols(con, inputs$fu_ce_counts)
  untied <- function(why) {
    sec$label <- paste0(sec$label, " - not tied to the LOT run below it")
    log_msg("  Note: ", why, " so the CE-window panel cannot be tied to the ",
            "cohort behind the numbers.")
    secs[[i]] <- sec; secs
  }
  if (!length(cols))
    return(untied(paste0("the columns of ", inputs$fu_ce_counts, " could not be read,")))
  if (!("RUN_ID" %in% cols))
    return(untied(paste0(inputs$fu_ce_counts, " predates the run stamp,")))
  cr <- owner$cohort_run
  if (is.null(cr) || is.na(cr) || !nzchar(cr))
    return(untied("no cohort run id was recorded by the LOT build,"))
  # A read that failed and rows that are absent are different findings; the
  # panel must not claim the rows are missing when the count never ran.
  n <- tryCatch(db_q(con, paste0("SELECT count(*) AS n FROM ", inputs$fu_ce_counts,
                                 " WHERE RUN_ID = '", cr, "'"))$n,
                error = function(e) e)
  if (inherits(n, "error")) {
    sec$skip <- paste0(inputs$fu_ce_counts, " could not be counted for cohort ",
                       "run ", cr, ": ", conditionMessage(n))
    log_msg("  skip  fu_ce_window - count failed: ", conditionMessage(n))
    secs[[i]] <- sec; return(secs)
  }
  if (is.na(n) || n < 1) {
    sec$skip <- paste0(
      "the follow-up-enrolment windows for cohort run ", cr, " - the cohort LOT ",
      "read - are not in ", inputs$fu_ce_counts, ". What is there ",
      "prices a window against a different cohort refresh.")
    log_msg("  skip  fu_ce_window - no rows for cohort run ", cr)
    secs[[i]] <- sec; return(secs)
  }
  # Same run id is not the same attempt. A cohort re-run keeps its run id and
  # replaces this table under it, so rows matching cr can belong to a LATER
  # attempt than the one LOT read. The stamp LOT recorded is the status row's
  # timestamp at that moment; a table written after it is a later attempt,
  # whatever its run id says. Same test the funnel makes, on the column the
  # cohort build now writes for it.
  newer <- if (!("RECORDED_AT" %in% cols)) NA else
    stamp_is_newer(con, paste0("SELECT max(RECORDED_AT) AS T FROM ",
                               inputs$fu_ce_counts, " WHERE RUN_ID = '", cr, "'"),
                   owner$cohort_stamp)
  if (isTRUE(newer)) {
    sec$skip <- paste0(
      "the follow-up-enrolment windows under cohort run ", cr, " were ",
      "rewritten after LOT read that cohort, so they are a later attempt ",
      "under the same run id.")
    log_msg("  skip  fu_ce_window - run ", cr, " rewritten after LOT read it")
    secs[[i]] <- sec; return(secs)
  }
  sec$sql <- sub("FROM {fu_ce_counts}",
                 "FROM {fu_ce_counts}\n         WHERE RUN_ID = '{cohort_run}'",
                 sec$sql, fixed = TRUE)
  # The run id is pinned either way - those are the rows that are there. The
  # label stops short of calling them the ATTEMPT LOT read.
  sec$label <- paste0(sec$label, " - cohort run ", cr,
                      if (is.na(newer)) UNVERIFIED_ATTEMPT else "")
  if (is.na(newer))
    log_msg("  Note: fu_ce_window is pinned to cohort run ", cr, ", but which ",
            "ATTEMPT under that id wrote these rows could not be compared ",
            "against the moment LOT read the cohort. A re-run keeps the id.")
  secs[[i]] <- sec
  secs
}

resolve_attrition <- function(secs, con, inputs, have, cfg, owner) {
  i <- which(vapply(secs, function(s) identical(s$name, "attrition"), logical(1)))
  if (!length(i) || !isTRUE(have[["attrition"]])) return(secs)
  sec <- secs[[i]]

  cols <- table_cols(con, inputs$attrition)
  if (!length(cols)) {
    sec$skip <- paste0("the columns of ", inputs$attrition, " could not be read, ",
                       "so which funnel layout it is cannot be decided.")
    secs[[i]] <- sec; return(secs)
  }
  hit <- Filter(function(L) all(toupper(L$cols) %in% cols), ATTRITION_LAYOUTS)
  if (!length(hit)) {
    sec$skip <- paste0(
      inputs$attrition, " is not a funnel shape this dashboard reads. It has: ",
      paste(cols, collapse = ", "), ". Known layouts: ",
      paste(vapply(ATTRITION_LAYOUTS, function(L)
        paste0(L$name, " (", paste(L$cols, collapse = ", "), ")"),
        character(1)), collapse = "; "), ".")
    secs[[i]] <- sec; return(secs)
  }
  # More than one match would mean two layouts are not distinguishable by their
  # columns, which is a registry bug rather than a warehouse one.
  if (length(hit) > 1L)
    stop("ATTRITION_LAYOUTS: ", paste(vapply(hit, `[[`, character(1), "name"),
         collapse = " and "), " both match the columns of ", inputs$attrition,
         ". Two layouts that cannot be told apart cannot be chosen between.",
         call. = FALSE)
  L <- hit[[1]]
  sec$sql <- L$sql
  log_msg("  Attrition layout: ", L$name, " (", inputs$attrition, ")")
  if (identical(L$name, "overall"))
    sec$label <- paste0(sec$label, " - ", cfg$attrition_window,
                        "-day outpatient window")

  # Show the funnel belonging to the cohort LOT read, or show none.
  #
  # Warning text over the wrong rows is not enough: the numbers on the panel
  # would still be a different cohort refresh, and a funnel is read as the
  # funnel for the study beside it. So the query is pinned to the recorded
  # cohort run where that is known, and the panel is skipped when that run's
  # rows are gone.
  cr <- owner$cohort_run
  if (is.null(cr) || is.na(cr) || !nzchar(cr)) {
    # Nothing recorded the link. Say so on the panel rather than in a log
    # nobody reading the HTML will see.
    sec$label <- paste0(sec$label, " - not tied to the LOT run below it")
    log_msg("  Note: no cohort run id recorded, so this funnel cannot be tied ",
            "to the cohort behind the numbers.")
    secs[[i]] <- sec; return(secs)
  }
  n <- tryCatch(db_q(con, paste0(
         "SELECT count(*) AS n FROM ", inputs$attrition,
         " WHERE ", L$run_col, " = '", cr, "'"))$n, error = function(e) e)
  if (inherits(n, "error")) {
    sec$skip <- paste0(inputs$attrition, " could not be counted for run ", cr,
                       ": ", conditionMessage(n))
    log_msg("  skip  attrition - count failed: ", conditionMessage(n))
    secs[[i]] <- sec; return(secs)
  }
  if (is.na(n) || n < 1) {
    sec$skip <- paste0(
      "the cohort funnel for run ", cr, " - the cohort LOT read - is not in ",
      inputs$attrition, ". The newest funnel there describes a ",
      "different cohort refresh, so showing it beside these lines would be a ",
      "funnel for one cohort above the numbers for another.")
    log_msg("  skip  attrition - no rows for cohort run ", cr)
    secs[[i]] <- sec; return(secs)
  }
  # Same run id is not the same attempt. A cohort re-run keeps its run id and
  # rewrites its attrition under it, so the rows matching cr may belong to a
  # LATER attempt than the one LOT read. The stamp LOT recorded is the status
  # row's timestamp at that moment; a funnel written after it is a later
  # attempt, whatever its run id says.
  newer <- stamp_is_newer(con, paste0("SELECT max(", L$stamp, ") AS T FROM ",
                                      inputs$attrition, " WHERE ", L$run_col,
                                      " = '", cr, "'"), owner$cohort_stamp)
  if (isTRUE(newer)) {
    sec$skip <- paste0(
      "the funnel under cohort run ", cr, " was rewritten after LOT read it, ",
      "so it is a later attempt under the same run id. The cohort behind ",
      "these lines no longer has a funnel in ", inputs$attrition, ".")
    log_msg("  skip  attrition - run ", cr, " rewritten after LOT read it")
    secs[[i]] <- sec; return(secs)
  }
  sec$sql   <- L$sql_run
  # Same three-way label as the CE-window panel above.
  sec$label <- paste0(sec$label, " - cohort run ", cr,
                      if (is.na(newer)) UNVERIFIED_ATTEMPT else "")
  if (is.na(newer))
    log_msg("  Note: the funnel is pinned to cohort run ", cr, ", but which ",
            "ATTEMPT under that id wrote it could not be compared against the ",
            "moment LOT read the cohort. A re-run keeps the id.")
  secs[[i]] <- sec
  secs
}

# MAX_LOT is a second copy of the LOT build's setting, so it can disagree with
# the run being drawn, and the transitions are generated from it.
#
# Compared against what the run was CONFIGURED to build - the LOT build records
# max_lot in LOT_RUN_METADATA - not against how far patients got. Only one of
# those is a problem. A run configured to LOT6 while this says 5 leaves LOT5 to
# LOT6 on no panel. A run where nobody REACHED LOT5 is not a mismatch at all:
# Every patient flowing into "No LOT5" is the finding, and lowering MAX_LOT
# would delete the panel carrying it.
#
# Nothing here stops the run: every other panel is still true.
check_max_lot <- function(con, inputs, have, cfg) {
  col <- function(d, nm) {
    if (is.null(d)) return(NULL)
    i <- match(toupper(nm), toupper(names(d)))
    if (is.na(i)) NULL else d[[i]]
  }
  # RUN_TIMESTAMP is what this table calls its clock.
  meta <- if (isTRUE(have[["run_meta"]])) tryCatch(db_q(con, paste0(
    "SELECT * FROM ", inputs$run_meta,
    " WHERE CONTRACT_SETTINGS IS NOT NULL ORDER BY RUN_TIMESTAMP DESC LIMIT 1")),
    error = function(e) NULL) else NULL
  cs <- col(meta, "CONTRACT_SETTINGS")
  built <- if (is.null(cs) || !length(cs)) NA_integer_ else
    suppressWarnings(as.integer(sub(".*(^|\\|)max_lot=([0-9]+).*", "\\2",
                                    as.character(cs[1]))))
  if (!is.na(built)) {
    if (built != cfg$max_lot)
      log_msg("WARNING: MAX_LOT here is ", cfg$max_lot, " but the LOT run was ",
              "built with max_lot=", built, " (CONTRACT_SETTINGS in ",
              inputs$run_meta, "). The Transitions tab draws ",
              max(cfg$max_lot - 1L, 0L), " panel(s); that run has ",
              max(built - 1L, 0L), ". Set MAX_LOT to ", built, ".")
    return(invisible(built))
  }
  # No contract recorded - an older lot. Fall back to the lines on disk, and
  # warn only in the direction that loses a panel: a line ABOVE this setting is
  # in the tables and undrawn. Below it says nothing, because a line nobody
  # reached and a line never configured look identical from here.
  if (!isTRUE(have[["lot_final"]])) return(invisible(NULL))
  seen <- tryCatch(as.integer(db_q(con, paste0(
    "SELECT max(LOT_NUM) AS n FROM ", inputs$lot_final))$n), error = function(e) NA)
  if (length(seen) != 1L || is.na(seen)) return(invisible(NULL))
  if (seen > cfg$max_lot)
    log_msg("WARNING: MAX_LOT is ", cfg$max_lot, " but this run has lines up to ",
            "LOT", seen, ". The Transitions tab stops at LOT", cfg$max_lot,
            ", so the moves above it are in the tables and on no panel. Set ",
            "MAX_LOT to ", seen, ".")
  invisible(seen)
}

# The LOT funnel belongs to one LOT run, and the dashboard reads one LOT run.
#
# Simpler than the cohort funnel: LOT_ATTRITION's RUN_ID is the LOT run's own,
# this run's rows are cleared before the build, and resolve_owner_run() has
# already refused a latest run that did not finish. So rows under owner_run are
# this attempt's.
#
# What is left is the table holding rows for some OTHER run, whose tables have
# since been replaced - one run's funnel above another run's numbers.
resolve_lot_attrition <- function(secs, con, inputs, have, cfg) {
  mine <- which(vapply(secs, function(s)
    isTRUE(s$needs[1] == "lot_attrition"), logical(1)))
  if (!length(mine) || !isTRUE(have[["lot_attrition"]])) return(secs)
  n <- tryCatch(db_q(con, paste0("SELECT count(*) AS n FROM ",
                                 inputs$lot_attrition, " WHERE RUN_ID = '",
                                 cfg$owner_run, "'"))$n, error = function(e) NA)
  if (!is.na(n) && n >= 1) return(secs)
  why <- paste0(
    "the LOT funnel for run ", cfg$owner_run, " - the run that wrote the ",
    "tables on this page - is not in ", inputs$lot_attrition,
    ". The rows there belong to a different LOT run, so showing them would be ",
    "one run's funnel above another run's numbers.")
  for (i in mine) secs[[i]]$skip <- why
  log_msg("  skip  LOT attrition - no rows for run ", cfg$owner_run)
  secs
}

# One panel. A section whose query fails does not take the dashboard with it -
# the other panels are still true, and a panel that says why it is missing is
# more use than a run that produced no file. The message goes in the panel and
# in the log, so it cannot be missed by reading only one of them.
build_panel <- function(con, sec, inputs, have, cfg) {
  # Set by resolve_attrition when the table is there but its shape is not one
  # this package can read. Distinct from a missing table, and worth saying so:
  # "no funnel" and "a funnel I cannot read" call for different fixes.
  if (!is.null(sec$skip)) {
    log_msg("  skip  ", sec$name, " - ", sec$skip)
    return(list(name = sec$name, tab = sec$tab, label = sec$label, data = NULL,
                html = paste0('<p class="skip">Not shown: ', .h(sec$skip), "</p>")))
  }
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

# One CSV per panel that produced rows, beside the HTML. The frames come from
# the panels, not a second pass at the warehouse, so the numbers match the page.
#
# Nothing here is un-masked: patient_journeys masks PATID in its own SQL, no
# section selects a raw identifier, and a test holds that.
#
# The folder is one run, not an accumulation. A panel switched off, a failed
# query, an empty panel or a reused OUTPUT_DIR each leaves a file from last
# time that looks current, because the names carry no run id.
#
# Only .csv, and only this folder, which the dashboard created and owns.
clear_csv_exports <- function(cfg, why) {
  dir <- file.path(cfg$output_dir, cfg$csv_dir)
  if (!dir.exists(dir)) return(invisible(0L))
  old <- list.files(dir, pattern = "[.]csv$", full.names = TRUE)
  if (length(old)) {
    unlink(old)
    log_msg("CSV export: cleared ", length(old), " file(s) from a previous run (",
            why, ")")
  } else if (!identical(why, "replaced by this run")) {
    log_msg("CSV export off (", why, ")")
  }
  invisible(length(old))
}

write_csv_exports <- function(panels, cfg) {
  dir <- file.path(cfg$output_dir, cfg$csv_dir)
  dir.create(dir, showWarnings = FALSE, recursive = TRUE)
  clear_csv_exports(cfg, "replaced by this run")
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
  # LOT_LONG_FINAL is the one nothing works without. It is the study
  # population, every clinical panel reads it, and it is written last - in the
  # line-criteria phase, after LOT_LONG. So a LOT run that died in between
  # leaves LOT_LONG behind and no final table, and requiring only LOT_LONG
  # would produce a file that looks like a finished dashboard while nearly
  # every panel on it says "not shown".
  if (!isTRUE(have[["lot_final"]]))
    stop("No ", inputs$lot_final, ". That table is the study population and ",
         "every clinical panel reads it. It is written after ", inputs$lot_long,
         ", in the line-criteria phase, so a LOT run that failed in between ",
         "leaves the one and not the other. Finish the LOT build, or check the ",
         "prefix.", call. = FALSE)

  # Which run these tables belong to, before anything reads them: this stops
  # the run outright when the last LOT build on the prefix did not finish.
  owner <- resolve_owner_run(con, inputs, have, cfg)
  cfg$owner_run  <- owner$run_id
  cfg$cohort_run <- owner$cohort_run
  set_dash_config(cfg)
  log_msg("  Owned by run: ", owner$run_id, if (owner$exact) " (LOT_BUILD_STATUS)"
          else paste0(" (newest completed metadata row - no ", inputs$build_st,
                      ", so this says a run finished, not that it wrote these",
                      " tables)"))

  secs <- resolve_attrition(secs, con, inputs, have, cfg, owner)
  secs <- resolve_fu_ce_window(secs, con, inputs, have, owner)
  secs <- resolve_lot_attrition(secs, con, inputs, have, cfg)
  check_max_lot(con, inputs, have, cfg)
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
  # Cleared either way. With the export off, last run's files would otherwise
  # sit beside this run's HTML looking current - the names carry no cohort,
  # prefix or run id to tell them apart, so "the CSV folder is this run" has to
  # hold when the answer is "no files" as much as when it is nineteen.
  if (isTRUE(cfg$export_csv)) write_csv_exports(panels, cfg)
  else clear_csv_exports(cfg, "EXPORT_CSV is FALSE")
  # The complete regimen distribution is a study-team deliverable, not just a
  # panel. Every other panel may degrade to "Not shown" and the dashboard is
  # still useful; this one absent means the deliverable silently did not ship,
  # so it stops the run instead.
  ar <- Filter(function(p) identical(p$name, "all_regimens"), panels)
  if (length(ar) == 1L && (is.null(ar[[1]]$data) || !nrow(ar[[1]]$data)))
    stop("The all_regimens panel produced no rows, so the complete ",
         "regimen-distribution CSV was not written. That table is the Q1 ",
         "deliverable; fix the read (see the FAIL line above) and re-run ",
         "rather than shipping a dashboard without it.", call. = FALSE)
  log_msg("Dashboard written: ", path)
  log_msg(SEP)
  invisible(path)
}
