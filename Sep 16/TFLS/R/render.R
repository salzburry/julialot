# A filled table, written out: markdown to read, and a tidy CSV to work with.
#
# Both keep the shell's own order and nesting - the rows in the order the shell
# put them, at the indent the shell gave them, under the headings the shell
# wrote - because the order of a table shell is part of what was asked for.
#
# Markdown collapses leading spaces, so the indent is written as a
# non-breaking space entity; a reader that shows the raw text still shows the
# nesting, and one that renders it lines the labels up.

md_escape <- function(x) gsub("|", "\\|", chr(x), fixed = TRUE)

indent_prefix <- function(n) {
  n <- suppressWarnings(as.integer(n))
  if (length(n) != 1L || is.na(n) || n <= 0L) return("")
  paste(rep("&nbsp;&nbsp;", n), collapse = "")
}

# The label as it prints: indented, and carrying its footnote marker.
#
# A marker is printed only where the table has a footnote of that name. The
# note column is also used to say why a row reads what it reads, and a
# paragraph of that in a table cell is not a marker.
row_label_md <- function(label, indent, note, markers = character(0)) {
  paste0(indent_prefix(indent), md_escape(label),
         if (blank(note) || !chr(note) %in% chr(markers)) ""
         else paste0(" [", chr(note), "]"))
}

# The header cell: the group above the column, where the shell grouped them.
column_header_md <- function(label, group)
  paste0(if (blank(group)) "" else paste0(md_escape(group), "<br>"),
         md_escape(label))

# The columns of a filled table, in the shell's order.
filled_columns <- function(cells) {
  i <- !duplicated(cells$COLUMN_ID)
  d <- cells[i, c("COLUMN_ID", "COLUMN_LABEL", "COLUMN_GROUP", "COLUMN_ORDER"),
             drop = FALSE]
  d[order(d$COLUMN_ORDER), , drop = FALSE]
}

# The rows of a filled table, in the shell's order.
filled_rows <- function(cells) {
  i <- !duplicated(cells$ROW_ORDER)
  d <- cells[i, c("ROW_ORDER", "ROW_LABEL", "INDENT", "SECTION", "NOTE"),
             drop = FALSE]
  d[order(d$ROW_ORDER), , drop = FALSE]
}

cell_text <- function(cells, row_order, column_id) {
  i <- which(cells$ROW_ORDER == row_order & cells$COLUMN_ID == column_id)
  if (!length(i)) return("")
  md_escape(cells$TEXT[i[1]])
}

# One table as markdown, with its title, its objective, its footnotes and a
# line saying what was withheld and what could not be filled.
render_markdown <- function(filled, sh) {
  tid <- filled$table_id
  cells <- filled$cells
  meta <- sh$tables[sh$tables$table_id == tid, , drop = FALSE]
  cols <- filled_columns(cells)
  rows <- filled_rows(cells)
  fn <- shell_footnotes_of(sh, tid)
  markers <- chr(fn$marker)
  out <- c(paste0("## ", tid, ". ", chr(meta$title[1])), "")
  if (nrow(meta) && !blank(meta$objective[1]))
    out <- c(out, paste0("*", chr(meta$objective[1]), "*"), "")
  if (nrow(meta) && !blank(meta$notes[1]))
    out <- c(out, chr(meta$notes[1]), "")
  out <- c(out,
           paste0("| ", paste(c("", vapply(seq_len(nrow(cols)), function(i)
             column_header_md(cols$COLUMN_LABEL[i], cols$COLUMN_GROUP[i]),
             character(1))), collapse = " | "), " |"),
           paste0("|", paste(rep("---", nrow(cols) + 1L), collapse = "|"), "|"))
  for (i in seq_len(nrow(rows))) {
    lab <- row_label_md(rows$ROW_LABEL[i], rows$INDENT[i], rows$NOTE[i],
                        markers)
    if (rows$SECTION[i] == 1L) {
      out <- c(out, paste0("| **", lab, "** | ",
                           paste(rep("", nrow(cols)), collapse = " | "), " |"))
      next
    }
    vals <- vapply(cols$COLUMN_ID, function(cid)
      cell_text(cells, rows$ROW_ORDER[i], cid), character(1))
    out <- c(out, paste0("| ", lab, " | ", paste(vals, collapse = " | "), " |"))
  }
  if (nrow(fn)) {
    out <- c(out, "")
    for (i in seq_len(nrow(fn)))
      out <- c(out, paste0(chr(fn$marker[i]), ". ", chr(fn$text[i])))
  }
  c(out, "", render_caption(filled), "")
}

# What a reader has to be told about the table above: the floor in force, how
# many cells it withheld, and how many rows nothing could fill.
render_caption <- function(filled) {
  cells <- filled$cells
  live <- cells$SECTION == 0L
  n_supp <- sum(cells$SUPPRESSED[live] == 1L)
  n_unf <- sum(cells$FILLED[live] == 0L)
  paste(c(paste0(
    "Counts are over a claims database: a code is evidence of a claim, not ",
    "of a diagnosis, and an absence is evidence of neither. Cells resting on ",
    "fewer than ", filled$floor_n, " are withheld and print as ",
    suppressed_text(filled$floor_n), "; ", n_supp, " of ", sum(live),
    " cells here are withheld, and ", n_unf,
    " could not be filled (see tfls_unfilled.csv)."),
    filled$notes %||% character(0)), collapse = " ")
}

# Every table, one document.
render_all_markdown <- function(filled, sh, title = "TFLS") {
  out <- c(paste0("# ", title), "",
           "The requested table shells, filled from a finished study run.",
           "Every number comes from a table the study package wrote.", "")
  for (f in filled) out <- c(out, render_markdown(f, sh), "")
  out
}

# The same table, tidy: one row per cell, in the shell's order. Nothing
# patient-level can reach here - a cell is a summary - and the writer checks
# again on the way out.
render_csv <- function(filled) {
  cells <- filled$cells
  keep <- c("TABLE_ID", "ROW_ORDER", "ROW_LABEL", "INDENT", "SECTION",
            "SECTION_LABEL", "NOTE", "COLUMN_ORDER", "COLUMN_ID",
            "COLUMN_LABEL", "COLUMN_GROUP", "STAT", "SOURCE", "MEASURE",
            "VALUE", "LOW", "HIGH", "N", "DENOM", "TEXT", "FILLED",
            "SUPPRESSED", "REASON_KIND", "REASON")
  out <- cells[order(cells$ROW_ORDER, cells$COLUMN_ORDER),
               intersect(keep, names(cells)), drop = FALSE]
  rownames(out) <- NULL
  out
}
