# The requested table shells, filled here.
#
# The shells are a sibling delivery: five CSVs saying which tables exist, what
# each column selects and what each row reads, and the code that fills them
# from a finished study run. This file loads that code and hands it the
# dashboard's own reader, so a shell cell and the same figure on a tab come
# from one table read one way.
#
# Nothing here computes a number. The engine does the filling and the
# suppression; this decides which scenario it reads, at which floor, and how
# the finished table is drawn.

# The engine's own files, in the order it loads them: the helpers in shells.R
# are used by everything after it.
TFLS_ENGINE_FILES <- c("classes.R", "shells.R", "stats.R", "suppress.R",
                       "fill.R", "render.R")

# Sourced into an environment of its own, never into this one, and one whose
# parent is the attached packages rather than the workspace.
#
# Both folders define drop_identifiers(), km_estimate() and km_median(), and
# one silently taking the other's would be a second opinion of a disclosure
# rule. The workspace is skipped for the same reason: a name defined out here -
# get(), even - must not reach inside the engine and change what it does.
.TFLS_LOADED <- new.env(parent = emptyenv())

# Where the shells are: DASH_TFLS_DIR, or the sibling folder next to the
# dashboard. The same fallback global.R uses for the study package, for the
# same reason - a relative default is right when the app is started from this
# folder and wrong when it is started from anywhere else.
tfls_dir <- function(dir = DASH_CFG$tfls_dir) {
  if (!nzchar(dir %||% "")) dir <- "../TFLS"
  if (dir.exists(dir)) return(dir)
  # The dashboard's own folder, as global.R resolved it at startup.
  root <- mget(".dash_dir", envir = globalenv(),
               ifnotfound = list(getwd()))[[1]]
  alt <- file.path(dirname(root), "TFLS")
  if (dir.exists(alt)) return(alt)
  dir
}

# Why the panel cannot draw, in the words it shows. The environment variable
# is named because that is the fix; the path is not, because a page several
# people can open is not the place for one.
TFLS_ABSENT <- paste(
  "The table shells are not beside the dashboard, so this tab has nothing to",
  "fill. Set DASH_TFLS_DIR to the folder holding shells/ and R/. Every other",
  "tab is unaffected.")

# The engine and the shells, loaded once per directory.
#
# Returns ok = FALSE and a reason rather than stopping: a missing sibling
# folder is a deployment that left one delivery out, and the rest of the page
# still has numbers on it.
tfls_ready <- function(dir = tfls_dir()) {
  key <- paste0("dir:", dir)
  if (!is.null(.TFLS_LOADED[[key]])) return(.TFLS_LOADED[[key]])
  no <- function(why) list(ok = FALSE, why = why, dir = dir, env = NULL,
                           shells = NULL)
  out <- if (!dir.exists(dir) ||
             !all(file.exists(file.path(dir, "R", TFLS_ENGINE_FILES))))
    no(TFLS_ABSENT)
  else tryCatch({
    e <- new.env(parent = parent.env(globalenv()))
    for (f in TFLS_ENGINE_FILES) sys.source(file.path(dir, "R", f), envir = e)
    # The engine checks the shell files hard and names the file and the row
    # when one is wrong. That refusal is what the panel shows: these files are
    # edited by hand, and the fix is in the file it names.
    list(ok = TRUE, why = "", dir = dir, env = e,
         shells = e$load_shells(file.path(dir, "shells")))
  }, error = function(e) no(conditionMessage(e)))
  .TFLS_LOADED[[key]] <- out
  out
}

# --- reading, at the floor --------------------------------------------------

# The reader the engine asks for: a function of one table name giving back a
# data frame or NULL. It is the dashboard's own reader and not a second one -
# bound to the run the sidebar names, restricted to the cohorts that run built,
# and preferring the released copy where the run wrote one.
shell_reader <- function(src, scenario, prefer_release = TRUE)
  function(table) read_scenario_table(src, scenario, table, prefer_release)

# The floor the engine is given. The sidebar's, raised by the package's own,
# and then raised again by the engine's - three tests that can only ever
# withhold more, and none of which can lower another.
shell_floor <- function(viewer_floor, package_min_n = 25L, ready = NULL) {
  fl <- effective_floor(viewer_floor, package_min_n)
  if (is.null(ready) || !isTRUE(ready$ok)) return(fl)
  ready$env$tfls_floor(fl)
}

# Every shell table, filled from this scenario and suppressed TOGETHER.
#
# A table filled on its own is closed against its own sums only. T5c's age
# columns split T4's Overall, and that sum exists only with both tables in
# hand: filled one at a time, the page printed T4's 200 and T5c's 180 while
# withholding the 20 aged 75 or over - and 200 - 180 is 20. fill_all() closes
# the tables against each other, as the written outputs always were, so every
# table this panel draws comes out of one such fill.
#
# `cache` keeps finished fills by scenario, run and setting, so picking another
# table does not fill them all again; the app passes one and a test need not.
# A fill during which the run moved is not kept - its rows can be two runs' -
# and the panel's own check after the fill still decides whether anything is
# drawn.
.TFLS_FILLS <- new.env(parent = emptyenv())

shell_fill_all <- function(ready, src, scenario, floor_n,
                           tte_eligible_only = FALSE, prefer_release = TRUE,
                           package_min_n = 25L, cache = NULL) {
  e <- ready$env
  fl <- shell_floor(floor_n, package_min_n, ready)
  key <- paste(ready$dir, scenario$prefix, scenario$run_id, scenario$state,
               scenario$updated_at, fl, isTRUE(tte_eligible_only),
               isTRUE(prefer_release), sep = "\r")
  if (is.environment(cache) && !is.null(cache[[key]])) return(cache[[key]])
  ctx <- e$fill_context(shell_reader(src, scenario, prefer_release),
                        ready$shells$classes,
                        tte_eligible_only = isTRUE(tte_eligible_only))
  all <- e$fill_all(ready$shells, ctx, fl)
  # The engine's own guard, on the way to the page rather than on the way to a
  # file. A cell is a summary and nothing patient-level can reach one, and this
  # is where that is checked rather than assumed.
  for (f in all) e$assert_no_identifiers(f$cells, "this table")
  if (is.environment(cache) && isTRUE(scenario_is_current(src, scenario))) {
    if (length(ls(cache, all.names = TRUE)) >= 8L)
      rm(list = ls(cache, all.names = TRUE), envir = cache)
    cache[[key]] <- all
  }
  all
}

# One shell table, out of that fill.
shell_fill <- function(ready, table_id, src, scenario, floor_n,
                       tte_eligible_only = FALSE, prefer_release = TRUE,
                       package_min_n = 25L, cache = NULL) {
  all <- shell_fill_all(ready, src, scenario, floor_n, tte_eligible_only,
                        prefer_release, package_min_n, cache)
  filled <- all[[table_id]]
  if (is.null(filled)) stop("the shells have no table ", table_id, call. = FALSE)
  filled
}

# The tables a viewer may pick, by the title the shell gives them.
shell_table_choices <- function(ready) {
  tb <- ready$shells$tables
  stats::setNames(tb$table_id, paste0(tb$table_id, ". ", tb$title))
}

# --- drawing ----------------------------------------------------------------

# The filled table as HTML, in the shell's own order.
#
# html_table() draws a plain grid, and a shell is not one: it has section
# headings spanning the table, labels indented under them and a column header
# in two lines. So it is built here from the same escaping helper, with the
# engine's own ordering and indentation rather than a second reading of them.
#
# The number of rows is the shell file's, not the data's, so there is nothing
# here to truncate.
shell_grid_html <- function(ready, filled) {
  e <- ready$env
  cells <- filled$cells
  e$assert_no_identifiers(cells, "this table")
  cols <- e$filled_columns(cells)
  rows <- e$filled_rows(cells)
  markers <- e$chr(e$shell_footnotes_of(ready$shells, filled$table_id)$marker)
  # A marker prints only where the table has a footnote of that name: the note
  # column also carries why a row reads what it reads, and a paragraph of that
  # in a label is not a marker.
  label_html <- function(i) {
    n <- e$chr(rows$NOTE[i])
    paste0(e$indent_prefix(rows$INDENT[i]), html_escape(rows$ROW_LABEL[i]),
           if (nzchar(n) && n %in% markers) paste0(" [", html_escape(n), "]")
           else "")
  }
  head_html <- paste0("<th></th>", paste(vapply(seq_len(nrow(cols)), function(i)
    sprintf("<th>%s%s</th>",
            if (nzchar(e$chr(cols$COLUMN_GROUP[i])))
              paste0(html_escape(cols$COLUMN_GROUP[i]), "<br>") else "",
            html_escape(cols$COLUMN_LABEL[i])), character(1)), collapse = ""))
  body <- vapply(seq_len(nrow(rows)), function(i) {
    if (rows$SECTION[i] == 1L)
      return(sprintf('<tr class="sec"><td colspan="%d">%s</td></tr>',
                     nrow(cols) + 1L, label_html(i)))
    tds <- vapply(cols$COLUMN_ID, function(cid) {
      # The cell's own text, and whether the engine withheld it. Read here
      # rather than through the engine's markdown cell, which escapes for a
      # pipe table and not for a page.
      k <- which(cells$ROW_ORDER == rows$ROW_ORDER[i] & cells$COLUMN_ID == cid)
      if (!length(k)) return("<td></td>")
      sprintf('<td class="%s">%s</td>',
              if (cells$SUPPRESSED[k[1]] == 1L) "supp" else "",
              html_escape(cells$TEXT[k[1]]))
    }, character(1))
    sprintf("<tr><td>%s</td>%s</tr>", label_html(i), paste(tds, collapse = ""))
  }, character(1))
  paste0('<div class="wide"><table class="grid"><thead><tr>', head_html,
         "</tr></thead><tbody>", paste(body, collapse = ""),
         "</tbody></table></div>")
}

# What a reader has to be told about the table above: the floor in force, how
# many cells it withheld, how a withheld cell prints, and how many rows nothing
# could fill.
shell_withheld_note <- function(ready, filled) {
  cells <- filled$cells
  live <- cells$SECTION == 0L
  sprintf(paste("%s of %s cells are withheld at a floor of %s and print as",
                "%s, never as a blank that could be read as a zero; %s could",
                "not be filled. Counts are over a claims database: a code is",
                "evidence of a claim, not of a diagnosis, and an absence is",
                "evidence of neither."),
          fmt_num(sum(cells$SUPPRESSED[live] == 1L), 0), fmt_num(sum(live), 0),
          fmt_num(filled$floor_n, 0),
          ready$env$suppressed_text(filled$floor_n),
          fmt_num(sum(cells$FILLED[live] == 0L), 0))
}

# The table, its caption, its footnotes and that line.
shell_panel_html <- function(ready, filled) {
  e <- ready$env
  tb <- ready$shells$tables
  meta <- tb[tb$table_id == filled$table_id, , drop = FALSE]
  fn <- e$shell_footnotes_of(ready$shells, filled$table_id)
  note <- function(x) sprintf('<p class="note">%s</p>', x)
  paste0(
    sprintf('<p class="cap">%s. %s</p>', html_escape(filled$table_id),
            html_escape(meta$title[1])),
    if (nzchar(e$chr(meta$objective[1])))
      note(html_escape(meta$objective[1])) else "",
    if (nzchar(e$chr(meta$notes[1]))) note(html_escape(meta$notes[1])) else "",
    shell_grid_html(ready, filled),
    if (nrow(fn)) note(paste(sprintf("%s. %s", html_escape(fn$marker),
                                     html_escape(fn$text)), collapse = "<br>"))
    else "",
    note(html_escape(shell_withheld_note(ready, filled))),
    if (length(filled$notes))
      note(html_escape(paste(filled$notes, collapse = " "))) else "")
}

# The three kinds of gap the engine records, and whose each one is. A row
# nothing could fill is never a zero, so it is listed with its reason rather
# than left as an empty cell.
SHELL_REASON_LABEL <- c(
  not_in_run = paste("The run did not write the table, the column or the rows",
                     "these needed - a module that was switched off, or a code",
                     "list with nothing in it yet. The study team's to close."),
  shell = paste("The shell does not say enough: no source, no statistic, a",
                "class mapped to no category, or a filter that leaves more",
                "than one row. The shell's to close, and it is a file anyone",
                "can edit."),
  not_computable = paste("The statistic cannot be made from what the table",
                         "holds - a mean over a table of totals, a regimen",
                         "class on one. Ours to close, where it can be closed",
                         "at all."))

shell_unfilled_html <- function(ready, filled, max_rows = 5000L) {
  u <- filled$unfilled
  if (is.null(u) || !nrow(u))
    return('<p class="note">Every row of this table was filled.</p>')
  ready$env$assert_no_identifiers(u, "the rows nothing could fill")
  show <- c("ROW_LABEL", "COLUMN_LABEL", "STAT", "SOURCE", "MEASURE", "REASON")
  out <- lapply(ready$env$TFLS_REASON_KINDS, function(k) {
    d <- u[u$REASON_KIND == k, , drop = FALSE]
    if (!nrow(d)) return("")
    paste0(sprintf("<h5>%s (%s)</h5>", html_escape(k), fmt_num(nrow(d), 0)),
           sprintf('<p class="note">%s</p>',
                   html_escape(SHELL_REASON_LABEL[[k]])),
           html_table(d[, show, drop = FALSE], max_rows = max_rows))
  })
  paste(unlist(out), collapse = "")
}

# --- the class mapping ------------------------------------------------------

# What each column heading covers, off the one file that decides it.
#
# Nothing here classifies a regimen: the study package already assigned a
# category to every line, and this maps those categories onto the headings the
# shells ask for. So a column is changed by editing one line of that file.
shell_class_table <- function(ready) {
  e <- ready$env
  cl <- ready$shells$classes
  per <- function(f) vapply(seq_len(nrow(cl)), f, character(1))
  data.frame(
    CLASS = e$chr(cl$label),
    CLASS_ID = e$chr(cl$class_id),
    STUDY_CATEGORIES = per(function(i) {
      id <- e$chr(cl$class_id[i])
      if (e$class_is_overall(id))
        return("every line in the column's population")
      cats <- e$class_categories(id, cl)
      if (!length(cats))
        "no category yet, so every cell in this column reads as unfilled"
      else paste(cats, collapse = "; ")
    }),
    DRUG_REFINEMENT = per(function(i) {
      d <- e$class_requires_drug(cl$class_id[i], cl)
      if (nzchar(d)) paste0("only the lines whose regimen holds ", d)
      else "none"
    }),
    NOTE = e$chr(cl$note),
    stringsAsFactors = FALSE)
}

SHELL_CLASS_NOTE <- paste(
  "These are the columns of every table on this tab. They come from",
  "shells/regimen_classes.csv in the shells folder, one line per class:",
  "change what a class rolls up there and the columns change with it, with no",
  "code to edit. Nothing here classifies a regimen - the study package already",
  "assigned a category to each line, and this maps those categories onto the",
  "headings the shells ask for, so a category the study does not write is",
  "refused by name rather than quietly emptying a column.")

shell_class_html <- function(ready, max_rows = 5000L) {
  ready$env$assert_no_identifiers(ready$shells$classes, "the class mapping")
  paste0(sprintf('<p class="note">%s</p>', html_escape(SHELL_CLASS_NOTE)),
         html_table(shell_class_table(ready), max_rows = max_rows))
}
