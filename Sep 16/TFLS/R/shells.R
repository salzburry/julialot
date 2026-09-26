# The shells, as data: five CSVs, read once and checked hard.
#
# They are meant to be edited by hand, so every mistake the code could
# otherwise carry into a published table stops the run here, naming the file
# and the row. A shell asking for a statistic nothing implements is a defect in
# the shell, not a blank cell in the output.
#
# Sourced first: the helpers below are used by every other file in R/.

`%||%` <- function(a, b) if (is.null(a)) b else a

# Text as it is meant to be compared: never NA, never padded.
chr <- function(x) {
  x <- as.character(x)
  x[is.na(x)] <- ""
  trimws(x)
}

blank <- function(x) !nzchar(chr(x))

# A whole number, or NA when the text is not one. Kept apart from as.integer()
# so "3.5" and "3 " are told apart from "three".
as_int <- function(x) {
  x <- chr(x)
  out <- suppressWarnings(as.numeric(x))
  out[!nzchar(x)] <- NA_real_
  bad <- !is.na(out) & out != round(out)
  out[bad] <- NA_real_
  as.integer(out)
}

# --- refusals ---------------------------------------------------------------
#
# Two conditions, because they mean different things to the runner: a shell
# file that is not there yet is a delivery still being written, and a shell
# file that is there and wrong is a defect to fix.

shell_stop <- function(file, row, ...) {
  where <- if (length(row) != 1L || is.na(row)) "" else paste0(" row ", row)
  stop(structure(
    list(message = paste0("TFLS SHELL ERROR: shells/", file, where, ": ", ...),
         call = NULL),
    class = c("tfls_shell_error", "error", "condition")))
}

shell_missing_stop <- function(files) {
  stop(structure(
    list(message = paste0(
      "TFLS SHELL ERROR: these shell files are not in shells/ yet: ",
      paste(files, collapse = ", "), "."), call = NULL),
    class = c("tfls_missing_shells", "error", "condition")))
}

# --- reading ----------------------------------------------------------------

# Everything is read as text and parsed here, so a column of orders holding one
# stray word does not silently become NA for the whole column.
tfls_read_csv <- function(path) {
  d <- utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE,
                       colClasses = "character", na.strings = character(0))
  if (ncol(d)) names(d)[1] <- sub("^\ufeff", "", names(d)[1])
  names(d) <- tolower(trimws(names(d)))
  for (cl in names(d)) d[[cl]] <- chr(d[[cl]])
  d
}

# What each file has to carry, what it may carry, and the other spellings an
# editor might reasonably use for the same column.
TFLS_SHELL_SCHEMA <- list(
  tables = list(
    required = c("table_id", "title"),
    optional = c("sheet", "objective", "notes"),
    alias = list(table_id = c("id", "table"), title = c("table_title", "name"),
                 objective = c("objectives", "purpose"),
                 notes = c("note", "comment"))),
  columns = list(
    required = c("table_id", "label"),
    optional = c("order", "column_id", "group", "cohort", "line", "class",
                 "subgroup", "period", "note"),
    alias = list(table_id = c("id", "table"),
                 label = c("column_label", "header", "column"),
                 order = c("col_order", "column_order", "position"),
                 column_id = c("col_id", "key"),
                 group = c("column_group", "group_label", "header_group",
                           "spanner"),
                 line = c("lot", "lot_num", "line_num", "line_of_therapy"),
                 class = c("regimen_class", "class_id", "regimen"),
                 subgroup = c("stratum", "split"),
                 period = c("window", "phase"),
                 note = c("footnote", "marker"))),
  rows = list(
    required = c("table_id", "order", "label", "stat"),
    optional = c("section", "indent", "source", "measure", "filter", "note"),
    alias = list(table_id = c("id", "table"),
                 order = c("row_order", "position", "seq"),
                 label = c("row_label", "text"),
                 stat = c("statistic", "summary"),
                 section = c("is_section", "heading"),
                 indent = c("level", "depth"),
                 source = c("source_table", "study_table", "reads"),
                 measure = c("variable", "column", "facet"),
                 filter = c("restriction", "where"),
                 note = c("footnote", "marker"))),
  regimen_classes = list(
    required = c("class_id", "label"),
    optional = c("order", "soc_categories", "requires_drug", "note"),
    alias = list(class_id = c("id", "class"), label = c("class_label", "name"),
                 soc_categories = c("soc_category", "categories", "soc",
                                    "soc_cats", "soc_category_values"),
                 requires_drug = c("requires_med", "drug", "med_abbr"))),
  footnotes = list(
    required = c("table_id", "text"),
    optional = c("marker", "order"),
    alias = list(table_id = c("id", "table"),
                 marker = c("note", "symbol", "footnote", "marker_id", "ref"),
                 text = c("footnote_text", "note_text", "body", "label"))))

TFLS_SHELL_FILES <- c(tables = "tables.csv", columns = "columns.csv",
                      rows = "rows.csv",
                      regimen_classes = "regimen_classes.csv",
                      footnotes = "footnotes.csv")

# A file's columns under the names the rest of the code uses. A required column
# nobody can find is a refusal that says what was found instead, because the
# fix is a rename in the file.
shell_columns_resolved <- function(d, file, schema) {
  found <- names(d)
  for (nm in names(schema$alias)) {
    if (nm %in% names(d)) next
    hit <- intersect(schema$alias[[nm]], names(d))
    if (length(hit)) names(d)[match(hit[1], names(d))] <- nm
  }
  miss <- setdiff(schema$required, names(d))
  if (length(miss))
    shell_stop(file, NA, "no column named ", paste(miss, collapse = ", "),
               ". The columns in the file are: ", paste(found, collapse = ", "),
               ".")
  # character(0) rather than "" for the default: a file with a header and no
  # rows is legal - a table may have no footnotes - and assigning a length-one
  # default to a frame of no rows is an error rather than an empty column.
  for (nm in schema$optional)
    if (!nm %in% names(d)) d[[nm]] <- rep("", nrow(d))
  d[, c(schema$required, schema$optional), drop = FALSE]
}

# --- measures and filters ---------------------------------------------------
#
# A measure names a column, and optionally a value of it: AGE_YEARS, or
# SEX=Female. The comparison may be spelled out (AGE_YEARS>=75) and a value may
# be a list (RACE=White|Black), because a shell row often stands for a band.

TFLS_MEASURE_OPS <- c("!=", ">=", "<=", "==", "=", ">", "<")

parse_measure <- function(x) {
  raw <- chr(x)
  out <- list(raw = raw, column = "", op = "", value = character(0),
              ok = TRUE, why = "")
  if (!nzchar(raw)) return(out)
  # The FIRST comparison in the text is the one that splits it, and the longest
  # spelling of it wins. Everything after it is the value, whatever it holds: a
  # band is often written as a literal, as in AGE_BAND=<75 years, and cutting
  # that at its '<' would lose the band.
  at <- vapply(TFLS_MEASURE_OPS, function(o) regexpr(o, raw, fixed = TRUE)[1],
               integer(1))
  hit <- which(at > 0L)
  if (!length(hit)) {
    out$column <- raw
  } else {
    first <- min(at[hit])
    cand <- TFLS_MEASURE_OPS[at == first]
    op <- cand[which.max(nchar(cand))]
    out$column <- trimws(substr(raw, 1, first - 1L))
    rest <- trimws(substr(raw, first + nchar(op), nchar(raw)))
    out$op <- if (identical(op, "==")) "=" else op
    out$value <- trimws(strsplit(rest, "|", fixed = TRUE)[[1]])
    if (!nzchar(rest) || !length(out$value) || any(!nzchar(out$value))) {
      out$ok <- FALSE
      out$why <- paste0("'", raw, "' names no value on the right of '", op, "'")
      return(out)
    }
  }
  if (!grepl("^[A-Za-z][A-Za-z0-9_.]*$", out$column)) {
    out$ok <- FALSE
    out$why <- paste0("'", raw, "' does not start with a column name")
  }
  out
}

# A subgroup is a filter, optionally against a named table: the neuropathy
# flag is on one table and the interval a malignancy fell in is on another, and
# the column has to say which it means.
#
#   S_COMORB_SUBGROUP:CONCEPT=neuropathy&HAS_HISTORY=1
#   S_MALIGNANCY:LOT_AFTER_WHICH>=2
#   AGE_BAND=18-44|45-64|65-74
parse_subgroup <- function(x) {
  raw <- chr(x)
  out <- list(raw = raw, table = "", terms = list(), ok = TRUE, why = "")
  if (!nzchar(raw)) return(out)
  rest <- raw
  if (grepl("^[A-Za-z][A-Za-z0-9_]*[[:space:]]*:", raw)) {
    i <- regexpr(":", raw, fixed = TRUE)[1]
    out$table <- trimws(substr(raw, 1, i - 1L))
    rest <- trimws(substr(raw, i + 1L, nchar(raw)))
  }
  out$terms <- parse_filter(rest)
  if (!length(out$terms)) {
    out$ok <- FALSE
    out$why <- paste0("'", raw, "' names a table but no restriction on it")
    return(out)
  }
  bad <- Filter(function(t) !isTRUE(t$ok), out$terms)
  if (length(bad)) { out$ok <- FALSE; out$why <- bad[[1]]$why }
  out
}

# A filter is any number of measure terms, separated by ; or &.
parse_filter <- function(x) {
  raw <- chr(x)
  if (!nzchar(raw)) return(list())
  parts <- trimws(strsplit(raw, "[;&]")[[1]])
  parts <- parts[nzchar(parts)]
  lapply(parts, parse_measure)
}

# A space-separated list as a vector, upper-cased. The engine writes a regimen
# with a pipe between its drugs and a shell writes it with a space, and both
# mean the same list.
split_list <- function(x) {
  v <- toupper(chr(x))
  if (!nzchar(v)) return(character(0))
  v <- trimws(strsplit(v, "[[:space:]|,+]+")[[1]])
  unique(v[nzchar(v)])
}

# --- validation -------------------------------------------------------------

# Every value of a column has to be a whole number, or the run stops on the row
# that is not.
check_int_col <- function(d, cl, file, required = TRUE, min = NA, max = NA) {
  v <- as_int(d[[cl]])
  for (i in seq_len(nrow(d))) {
    if (blank(d[[cl]][i])) {
      if (required)
        shell_stop(file, i, "no ", cl, " on '", d$label[i], "'.")
      next
    }
    if (is.na(v[i]))
      shell_stop(file, i, cl, " is '", d[[cl]][i], "', which is not a whole ",
                 "number.")
    if (!is.na(min) && v[i] < min || !is.na(max) && v[i] > max)
      shell_stop(file, i, cl, " is ", v[i], ", outside ", min, " to ", max, ".")
  }
  v
}

# By the number the order is, not the text it is written in: "1" and "01" are
# one position, and two things at one position have no order between them -
# the rendering kept one and dropped the other.
check_unique_order <- function(d, file) {
  key <- paste(d$table_id, as_int(d$order), sep = "\r")
  dup <- duplicated(key) & !blank(d$order)
  if (any(dup)) {
    i <- which(dup)[1]
    shell_stop(file, i, "table ", d$table_id[i], " already has a row at order ",
               d$order[i], " ('", d$label[i], "'). Two rows at one position ",
               "have no order between them.")
  }
  invisible(TRUE)
}

# What a statistic can do with its measure and its filter, checked before
# anything is filled, because what it cannot use it used to drop without a
# word.
#
# A curve's measure is its endpoint and nothing else: a comparison on it was
# never applied. The month a probability is read at is one number, at or after
# the index - the first of several was taken, and a negative month read as a
# certainty before follow-up began - and a month on any other statistic was
# skipped.
check_row_arguments <- function(row, measure, file, i) {
  stat <- chr(row$stat)
  if (!nzchar(stat)) return(invisible(TRUE))
  km <- stat %in% c("km_events", "km_censored", "km_median", "km_prob")
  if (km && nzchar(chr(measure$op)))
    shell_stop(file, i, "'", row$label, "' reads the curve '", measure$raw,
               "', and a curve's measure is its endpoint alone. Give the ",
               "endpoint, and put '", measure$op, "' in the filter.")
  months <- Filter(function(t) identical(toupper(chr(t$column)), "MONTHS"),
                   parse_filter(row$filter))
  if (!identical(stat, "km_prob")) {
    if (length(months))
      shell_stop(file, i, "'", row$label, "' names a month (", months[[1]]$raw,
                 "), which only a km_prob row reads. On a ", stat,
                 " row it would be ignored.")
    return(invisible(TRUE))
  }
  if (length(months) != 1L)
    shell_stop(file, i, "'", row$label, "' is a survival probability and needs ",
               "exactly one MONTHS= in its filter; it has ", length(months), ".")
  m <- months[[1]]
  y <- suppressWarnings(as.numeric(m$value))
  if (!identical(m$op, "=") || length(m$value) != 1L || is.na(y) ||
      !is.finite(y) || y < 0)
    shell_stop(file, i, "'", row$label, "' reads the curve at '", m$raw,
               "'. A probability is read at one month, a number at or after ",
               "the index: MONTHS=12.")
  invisible(TRUE)
}

# TRUE / FALSE / Y / 1 / blank, and nothing else: a section flag reading "maybe"
# would silently become a data row.
parse_flag <- function(x, file, i, cl) {
  v <- toupper(chr(x))
  if (!nzchar(v)) return(FALSE)
  if (v %in% c("TRUE", "T", "YES", "Y", "1")) return(TRUE)
  if (v %in% c("FALSE", "F", "NO", "N", "0")) return(FALSE)
  shell_stop(file, i, cl, " is '", x, "', which is not TRUE or FALSE.")
}

# --- the five files ---------------------------------------------------------

load_shell_tables <- function(dir) {
  f <- TFLS_SHELL_FILES[["tables"]]
  d <- shell_columns_resolved(tfls_read_csv(file.path(dir, f)), f,
                              TFLS_SHELL_SCHEMA$tables)
  if (!nrow(d)) shell_stop(f, NA, "the file holds no tables.")
  d$label <- d$title
  for (i in seq_len(nrow(d))) {
    if (blank(d$table_id[i])) shell_stop(f, i, "no table_id.")
    if (blank(d$title[i]))
      shell_stop(f, i, "table ", d$table_id[i], " has no title.")
  }
  if (anyDuplicated(d$table_id)) {
    i <- which(duplicated(d$table_id))[1]
    shell_stop(f, i, "table_id ", d$table_id[i], " is already defined above.")
  }
  d
}

load_shell_classes <- function(dir) {
  f <- TFLS_SHELL_FILES[["regimen_classes"]]
  d <- shell_columns_resolved(tfls_read_csv(file.path(dir, f)), f,
                              TFLS_SHELL_SCHEMA$regimen_classes)
  if (!nrow(d)) shell_stop(f, NA, "the file defines no classes.")
  for (i in seq_len(nrow(d))) {
    if (blank(d$class_id[i])) shell_stop(f, i, "no class_id.")
    if (blank(d$label[i]))
      shell_stop(f, i, "class ", d$class_id[i], " has no label.")
    # A category the study package cannot write would produce an empty column
    # that reads as "nobody is in this class", which is the failure mode worth
    # stopping for: a typo here is invisible in the finished table.
    bad <- unknown_soc_categories(d$soc_categories[i])
    if (length(bad))
      shell_stop(f, i, "class ", d$class_id[i], " maps to '",
                 paste(bad, collapse = "', '"),
                 "', which the study does not write as a SOC category. The ",
                 "categories are: ", paste(TFLS_SOC_CATEGORIES, collapse = "; "),
                 ".")
    if (!blank(d$requires_drug[i])) {
      # A refinement of a category, so there has to be a category to refine.
      if (blank(d$soc_categories[i]))
        shell_stop(f, i, "class ", d$class_id[i], " requires the drug ",
                   chr(d$requires_drug[i]), " but names no SOC category, and ",
                   "a drug on its own is a second classifier rather than a ",
                   "refinement of the study's own.")
      if (!grepl("^[A-Za-z][A-Za-z0-9]*$", chr(d$requires_drug[i])))
        shell_stop(f, i, "class ", d$class_id[i], " requires '",
                   chr(d$requires_drug[i]), "', which is not a single drug ",
                   "abbreviation.")
    }
    if (class_is_overall(d$class_id[i]) && !blank(d$soc_categories[i]))
      shell_stop(f, i, "OVERALL is the column total and matches every line, ",
                 "so it cannot also name the categories '",
                 chr(d$soc_categories[i]), "'.")
  }
  if (anyDuplicated(d$class_id)) {
    i <- which(duplicated(d$class_id))[1]
    shell_stop(f, i, "class_id ", d$class_id[i], " is already defined above.")
  }
  d$order <- check_int_col(d, "order", f, required = FALSE)
  d$order[is.na(d$order)] <- which(is.na(d$order))
  d[order(d$order), , drop = FALSE]
}

load_shell_columns <- function(dir, tables, classes) {
  f <- TFLS_SHELL_FILES[["columns"]]
  d <- shell_columns_resolved(tfls_read_csv(file.path(dir, f)), f,
                              TFLS_SHELL_SCHEMA$columns)
  if (!nrow(d)) shell_stop(f, NA, "the file holds no columns.")
  for (i in seq_len(nrow(d))) {
    if (blank(d$table_id[i])) shell_stop(f, i, "no table_id.")
    if (!d$table_id[i] %in% tables$table_id)
      shell_stop(f, i, "table ", d$table_id[i], " is not in tables.csv.")
    if (blank(d$label[i]))
      shell_stop(f, i, "the column in table ", d$table_id[i], " has no label.")
    if (!blank(d$class[i])) {
      sel <- class_selection(d$class[i], classes)
      if (identical(sel$kind, "unknown"))
        shell_stop(f, i, "column '", d$label[i], "' names a class the code ",
                   "cannot resolve: ", sel$why, ".")
    }
    if (!blank(d$subgroup[i])) {
      p <- parse_subgroup(d$subgroup[i])
      if (!p$ok)
        shell_stop(f, i, "column '", d$label[i], "' has a subgroup that ",
                   "cannot be read: ", p$why, ".")
      if (!nzchar(p$table) && exists("named_subgroup_value_why", mode = "function"))
        for (t in p$terms) {
          why <- named_subgroup_value_why(t)
          if (nzchar(why))
            shell_stop(f, i, "column '", d$label[i], "': ", why, ".")
        }
    }
  }
  # A column with no order keeps the order it was written in, so a file that
  # never used the column is still a table with columns in a fixed order.
  if (all(blank(d$order))) d$order <- as.character(seq_len(nrow(d)))
  d$order_n <- check_int_col(d, "order", f, required = TRUE)
  check_unique_order(d, f)
  d$column_id <- ifelse(blank(d$column_id),
                        paste0(d$table_id, "_C", d$order_n), d$column_id)
  # After the defaults are in, because a generated id can collide with one
  # written by hand. Two columns under one id are one column to everything
  # that finds a cell by it - the grid, the CSV, the suppression.
  dup <- duplicated(paste(d$table_id, toupper(chr(d$column_id)), sep = "\r"))
  if (any(dup)) {
    i <- which(dup)[1]
    shell_stop(f, i, "table ", d$table_id[i], " already has a column ",
               d$column_id[i], " - written above, or made from its order.")
  }
  d[order(d$table_id, d$order_n), , drop = FALSE]
}

load_shell_rows <- function(dir, tables, stats) {
  f <- TFLS_SHELL_FILES[["rows"]]
  d <- shell_columns_resolved(tfls_read_csv(file.path(dir, f)), f,
                              TFLS_SHELL_SCHEMA$rows)
  if (!nrow(d)) shell_stop(f, NA, "the file holds no rows.")
  d$section_flag <- FALSE
  for (i in seq_len(nrow(d))) {
    if (blank(d$table_id[i])) shell_stop(f, i, "no table_id.")
    if (!d$table_id[i] %in% tables$table_id)
      shell_stop(f, i, "table ", d$table_id[i], " is not in tables.csv.")
    if (blank(d$label[i]))
      shell_stop(f, i, "the row in table ", d$table_id[i], " has no label.")
    d$section_flag[i] <- parse_flag(d$section[i], f, i, "section")
    # A statistic nothing implements would print as an empty cell in a
    # published table, so it stops the run and names what is available.
    if (!blank(d$stat[i]) && !d$stat[i] %in% stats)
      shell_stop(f, i, "'", d$label[i], "' asks for the statistic '",
                 d$stat[i], "', which is not implemented. The statistics are: ",
                 paste(stats, collapse = ", "), ".")
    if (!d$section_flag[i] && blank(d$stat[i]) && !blank(d$source[i]))
      shell_stop(f, i, "'", d$label[i], "' reads ", d$source[i],
                 " but names no statistic.")
    p <- parse_measure(d$measure[i])
    if (!p$ok)
      shell_stop(f, i, "'", d$label[i], "' has a measure that cannot be read: ",
                 p$why, ".")
    for (q in parse_filter(d$filter[i]))
      if (!q$ok)
        shell_stop(f, i, "'", d$label[i], "' has a filter that cannot be read: ",
                   q$why, ".")
    check_row_arguments(d[i, , drop = FALSE], p, f, i)
  }
  d$order_n <- check_int_col(d, "order", f, required = TRUE)
  check_unique_order(d, f)
  d$indent_n <- check_int_col(d, "indent", f, required = FALSE, min = 0, max = 2)
  d$indent_n[is.na(d$indent_n)] <- 0L
  d[order(d$table_id, d$order_n), , drop = FALSE]
}

load_shell_footnotes <- function(dir, tables) {
  f <- TFLS_SHELL_FILES[["footnotes"]]
  d <- shell_columns_resolved(tfls_read_csv(file.path(dir, f)), f,
                              TFLS_SHELL_SCHEMA$footnotes)
  if (!nrow(d)) return(d)
  for (i in seq_len(nrow(d))) {
    if (blank(d$table_id[i])) shell_stop(f, i, "no table_id.")
    if (!d$table_id[i] %in% tables$table_id)
      shell_stop(f, i, "table ", d$table_id[i], " is not in tables.csv.")
    if (blank(d$text[i]))
      shell_stop(f, i, "the footnote on table ", d$table_id[i], " has no text.")
  }
  d$order_n <- as_int(d$order)
  d$order_n[is.na(d$order_n)] <- seq_len(nrow(d))[is.na(d$order_n)]
  # A footnote with no marker takes the next letter within its table, which is
  # how it will print.
  for (tid in unique(d$table_id)) {
    i <- which(d$table_id == tid)
    i <- i[order(d$order_n[i])]
    need <- i[blank(d$marker[i])]
    if (length(need)) d$marker[need] <- letters[seq_along(need)]
  }
  d[order(d$table_id, d$order_n), , drop = FALSE]
}

# --- the five files together ------------------------------------------------

# The shells, validated. `stats` is the list of statistics the code implements;
# it is a parameter so the check is against what is loaded rather than against
# a second list kept here.
load_shells <- function(dir, stats = tfls_stat_names()) {
  want <- file.path(dir, TFLS_SHELL_FILES)
  missing <- TFLS_SHELL_FILES[!file.exists(want)]
  if (length(missing)) shell_missing_stop(missing)
  tables <- load_shell_tables(dir)
  classes <- load_shell_classes(dir)
  columns <- load_shell_columns(dir, tables, classes)
  rows <- load_shell_rows(dir, tables, stats)
  footnotes <- load_shell_footnotes(dir, tables)
  # A table nothing fills is a table that will print as a title over an empty
  # page, so it is refused where it is declared.
  for (i in seq_len(nrow(tables))) {
    tid <- tables$table_id[i]
    if (!any(rows$table_id == tid))
      shell_stop(TFLS_SHELL_FILES[["tables"]], i, "table ", tid,
                 " has no rows in rows.csv.")
    if (!any(columns$table_id == tid))
      shell_stop(TFLS_SHELL_FILES[["tables"]], i, "table ", tid,
                 " has no columns in columns.csv.")
  }
  list(dir = dir, tables = tables, columns = columns, rows = rows,
       classes = classes, footnotes = footnotes)
}

shell_table_ids <- function(sh) sh$tables$table_id
shell_columns_of <- function(sh, tid)
  sh$columns[sh$columns$table_id == tid, , drop = FALSE]
shell_rows_of <- function(sh, tid)
  sh$rows[sh$rows$table_id == tid, , drop = FALSE]
shell_footnotes_of <- function(sh, tid)
  sh$footnotes[sh$footnotes$table_id == tid, , drop = FALSE]
