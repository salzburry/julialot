# What a run declared, and what that makes its own.
#
# A run writes only the modules it selected, for the cohorts it selected, and
# leaves every other table and every other cohort's rows under the prefix as
# the previous run left them. That is what makes a partial re-run cheap, and it
# means a completed run's prefix can hold tables the run never wrote and rows
# it never built. Reading whatever sits there would publish a module that did
# not run, a cohort that was not selected and a release the run never made, all
# under this run's name.
#
# So a run is bound by its own record of what it did: MODULES, COHORTS and the
# readings behind its optional outputs, which S_RUN_METADATA carries. That is
# the dashboard's contract - scenario_table_status() and restrict_to_cohorts()
# in dashboard/R/sources.R - applied here rather than a second one invented
# beside it, so a shell cell and the same figure on a page cannot rest on
# different rows.

# --- the run's own record ---------------------------------------------------

# The newest row of a metadata table: by UPDATED_AT where it carries one,
# otherwise the last row written.
newest_row <- function(df) {
  if (is.null(df) || !nrow(df)) return(NULL)
  o <- if ("UPDATED_AT" %in% names(df))
    order(as.character(df$UPDATED_AT), decreasing = TRUE) else rev(seq_len(nrow(df)))
  df[o[1], , drop = FALSE]
}

row_field <- function(row, nm)
  if (is.null(row) || !nm %in% names(row)) "" else chr(row[[nm]][1])

# The identity a run is bound by: the id, and the state and timestamp that tell
# one build under that id from another. A run id is not a build - the same id
# is kept for every build inside one session - so all three are compared.
run_identity <- function(row)
  paste(row_field(row, "RUN_ID"), row_field(row, "STATE"),
        row_field(row, "UPDATED_AT"), sep = "\r")

# A semicolon-separated field of the metadata row, as the package writes
# COHORTS and MODULES.
run_list_field <- function(md, nm) {
  v <- trimws(strsplit(row_field(md, nm), ";", fixed = TRUE)[[1]])
  v[nzchar(v)]
}

# The readings a run recorded, as a named list of values.
#
# The package writes them as "key=value; key=value (note)", and a note may hold
# a semicolon of its own - "study_start=2016-01-01 (upstream, verified; this
# run was set to 2018-01-01)" is exactly the entry worth reading - so the split
# is on the separators outside the brackets and not on every semicolon.
split_readings <- function(raw) {
  ch <- strsplit(chr(raw), "", fixed = TRUE)[[1]]
  depth <- 0L; out <- character(0); cur <- character(0)
  for (k in ch) {
    if (identical(k, "(")) depth <- depth + 1L
    else if (identical(k, ")")) depth <- max(0L, depth - 1L)
    if (identical(k, ";") && depth == 0L) {
      out <- c(out, paste(cur, collapse = "")); cur <- character(0)
    } else cur <- c(cur, k)
  }
  trimws(c(out, paste(cur, collapse = "")))
}

run_readings <- function(raw) {
  out <- list()
  for (p in split_readings(raw)) {
    if (!nzchar(p)) next
    # "key=value (note)": the note is provenance and not part of the value.
    v <- sub("[[:space:]]*\\([^)]*\\)$", "", p)
    eq <- regexpr("=", v, fixed = TRUE)[1]
    if (eq < 1L) next
    key <- trimws(substr(v, 1L, eq - 1L))
    # A key written twice keeps its first reading, so a lookup and a listing
    # of the names cannot disagree.
    if (nzchar(key) && is.null(out[[key]]))
      out[[key]] <- trimws(substring(v, eq + 1L))
  }
  out
}

# One S_RUN_METADATA row as the declaration everything below is bound by.
run_scope <- function(md)
  list(run_id = row_field(md, "RUN_ID"), state = row_field(md, "STATE"),
       cohorts = run_list_field(md, "COHORTS"),
       modules = run_list_field(md, "MODULES"),
       readings = run_readings(row_field(md, "OPEN_QUESTION_READINGS")),
       recoverable = row_field(md, "RELEASE_RECOVERABLE"),
       recoverable_tables = row_field(md, "RELEASE_RECOVERABLE_TABLES"))

# Whether the run recorded a setting as TRUE. Missing is not TRUE: a run that
# recorded no reading of a switch cannot vouch for the table it turns on.
reading_is_true <- function(scope, setting)
  identical(toupper(chr(scope$readings[[setting]] %||% "")), "TRUE")

# --- what the package writes, and which module writes it --------------------
#
# Off the study package's own registry, R/registry.R: MODULES declares the
# outputs of each module and OPTIONAL_FEATURES the two a switch turns on.
# Restated here as data because a snapshot is filled where the package is not
# installed and cannot be asked, and because this must decide the same way in
# both modes. A table the registry names and this list does not is reported
# unfilled by name rather than read from whatever sits under the prefix.

# The tables the release module publishes a suppressed copy of, which is
# SUPPRESSION_SPEC in the package's registry.
TFLS_RELEASED_TABLES <- c("S_SAFETY_RATES", "S_HCRU_RATES", "S_MALIGNANCY_RATES",
                          "S_PATTERNS", "S_SWITCH", "S_TX_ATTRITION")

TFLS_MODULE_OUTPUTS <- list(
  spine = "S_SPINE",
  cohorts = "S_COHORT",
  attrition = "S_ATTRITION",
  periods = c("S_PERIODS", "S_LOT_PERIODS"),
  demographics = "S_DEMOGRAPHICS",
  comorbidity = c("S_COMORBIDITY", "S_COMORB_SUBGROUP", "S_FRAILTY"),
  soc = "S_SOC",
  safety = c("S_SAFETY_EVENTS", "S_SAFETY_COUNTED", "S_SAFETY_RATES"),
  hcru = c("S_HCRU_EVENTS", "S_HCRU_RATES"),
  malignancy = c("S_MALIGNANCY", "S_MALIGNANCY_DATES", "S_MALIGNANCY_RATES"),
  tte = "S_TTE",
  patterns = c("S_PATTERNS", "S_SWITCH", "S_TX_ATTRITION"),
  release = paste0(TFLS_RELEASED_TABLES, "_RELEASE"))

# The outputs a module writes only when a switch asks for it, and the setting
# that asks. A run that did not record the switch did not write the table,
# whatever a previous run left under the prefix.
TFLS_OPTIONAL_OUTPUTS <- c(S_FRAILTY = "frailty",
                           S_COMORB_SUBGROUP = "comorbid_subgroups")

# The module that writes a table, or NA for a table no module declares.
run_table_owner <- function(table) {
  t <- toupper(chr(table))
  for (m in names(TFLS_MODULE_OUTPUTS))
    if (t %in% TFLS_MODULE_OUTPUTS[[m]]) return(m)
  NA_character_
}

# --- the verdict ------------------------------------------------------------

# Whether a table under this prefix is this run's, and if not why not, in the
# words the unfilled list prints.
#
# One verdict for every site that asks, so the reader and a reason cannot
# disagree. A table is the run's only if the run's own metadata names the
# module that writes it, and - for a module's optional output - if the run
# recorded that output's switch on.
#
# The run's STATE is not asked here. The dashboard asks it per table because it
# draws several runs at once; a run that is not complete stops this command in
# bind_run() instead, since a document half from one build is not one to write.
run_table_status <- function(scope, table) {
  t <- toupper(chr(table))
  yes <- list(ok = TRUE, why = "")
  no <- function(why) list(ok = FALSE, why = why)
  # The run's own record, and the input cohort table, which is not one of its
  # outputs: what may be read from that one is the runner's to say, not this.
  if (identical(t, "S_RUN_METADATA") || t %in% TFLS_COHORT_TABLE_NAMES)
    return(yes)
  # The lines are the LOT run's tables and not this run's outputs. The
  # metadata records which build of them this run read and the reader keys
  # them by it, so this run's module list says nothing about them.
  if (grepl("^LOT_", t)) return(yes)
  own <- run_table_owner(t)
  if (is.na(own))
    return(no(paste0(t, " is not a table the study package writes, so no run ",
                     "can be shown to have written it")))
  if (!own %in% scope$modules)
    return(no(paste0(t, " is written by the ", own, " module, which this run ",
                     "did not run: its own metadata records the module(s) ",
                     run_modules_text(scope), ". Whatever sits under the ",
                     "prefix is a previous run's")))
  setting <- unname(TFLS_OPTIONAL_OUTPUTS[t])
  if (!is.na(setting) && !reading_is_true(scope, setting))
    return(no(paste0(t, " is written only when ", toupper(setting),
                     " is on, which this run did not record")))
  yes
}

run_modules_text <- function(scope)
  if (!length(scope$modules)) "none" else paste(scope$modules, collapse = ", ")

# --- the reader -------------------------------------------------------------

# The rows of a table that belong to this run: the cohorts it selected.
#
# A 2L partition a previous run built sits beside the 1L this run rebuilt, and
# a column selecting 2L would otherwise summarise the previous run's patients
# under this run's name. A table with no COHORT column is not per cohort and
# passes whole; a run that recorded no cohorts owns no rows.
run_cohort_rows <- function(d, scope) {
  if (is.null(d) || !nrow(d) || !has_col(d, "COHORT")) return(d)
  if (!length(scope$cohorts)) return(d[0, , drop = FALSE])
  d[chr(d[[col_of(d, "COHORT")]]) %in% chr(scope$cohorts), , drop = FALSE]
}

# --- the run's own verdict on its release ------------------------------------
#
# The package's release module withholds every cell under the floor and then
# records what it could not close: the groups where exactly one withheld cell
# is still the group's total less the published rest. That finding travels in
# S_RUN_METADATA, as a sentence in RELEASE_RECOVERABLE and as a list of the
# tables it is about in RELEASE_RECOVERABLE_TABLES.
#
# It has to be applied HERE too, and not only by the dashboard, because these
# shells are what a study hands out. Filling them at a higher floor does not
# close it: the recoverable cell is in the released copy this reads FROM, and
# subtraction inside that source happened before anything here saw it.
#
# Same four answers the dashboard reads, and the same fail-closed shape:
#
#   "none"                        nothing to refuse
#   a finding                     refuse the tables the run named, or - where
#                                 it named none this can trust - every
#                                 released one
#   "release module did not run"  refuse every released table: that run has
#                                 not been shown to have no recoverable cell,
#                                 it has not looked
#   nothing at all                refuse nothing, and say so
#
# The fourth is the one case this does not refuse, and it is deliberate. That
# is the snapshot job's gate, and refusing here as well would stop every shell
# built from a run taken before the column existed - a large harm against a
# risk the caption states instead.

TFLS_RELEASE_NOT_RECORDED <- "no record"

# What the verdict blocks, in the run's own words. "" where it blocks nothing.
#
# The clean sentinel is matched without regard to case. This column is read
# back from a warehouse and from CSV and may have been through a hand edit or
# an upstream normalisation, and "NONE" said in capitals is the same answer -
# treating it as a finding would refuse every released table of a run that has
# nothing wrong with it. Only the clean sentinel is folded: everything else is
# a finding whatever its case, so this can lift a needless refusal and cannot
# turn a finding into a clear.
release_verdict <- function(scope) {
  v <- chr(scope$recoverable %||% "")
  if (!nzchar(v) || identical(toupper(v), "NA"))
    return(TFLS_RELEASE_NOT_RECORDED)
  if (identical(toupper(v), "NONE")) return("")
  v
}

# The tables that verdict is about.
#
# The run's own list where it wrote one, and only where every name in it is a
# table that HAS a released copy: this field narrows a refusal, so a stale or
# hand-edited name would narrow it onto a table that does not exist and leave
# the recoverable one readable. One unrecognised name discards the list, and
# the sentence answers instead - which refuses every released table where it
# names none.
release_refused <- function(scope) {
  blocked <- release_verdict(scope)
  if (!nzchar(blocked) || identical(blocked, TFLS_RELEASE_NOT_RECORDED))
    return(character(0))
  parts <- toupper(trimws(strsplit(chr(scope$recoverable_tables %||% ""), ";",
                                   fixed = TRUE)[[1]]))
  parts <- parts[nzchar(parts)]
  if (length(parts) && all(parts %in% TFLS_RELEASED_TABLES))
    return(unique(parts))
  named <- TFLS_RELEASED_TABLES[vapply(TFLS_RELEASED_TABLES, function(t)
    grepl(t, blocked, fixed = TRUE), logical(1))]
  if (length(named)) named else TFLS_RELEASED_TABLES
}

# Whether this run has been told to fill the shells anyway. The dashboard and
# the snapshot job each have the same switch under their own name, because each
# is a separate way a run reaches people and none of them has been through the
# others.
tfls_allow_recoverable <- function()
  isTRUE(as.logical(Sys.getenv("TFLS_ALLOW_RECOVERABLE", "FALSE")))

# This run's tables, and nothing else under the prefix.
#
# `read_one` is a function of one table name giving back a data frame or NULL -
# files under a snapshot, or the study package's own connection - and the three
# rules over it are the ones above: a table the run's metadata does not claim
# reads as absent, a released copy is preferred only where the run ran the
# release module that writes it, and the rows are the cohorts the run selected.
run_reader <- function(read_one, scope) {
  # Why a read was refused, for the unfilled list. A refusal the status alone
  # cannot state - a declared release that is not there - is recorded here as
  # the read happens, because only the read knows.
  refused <- new.env(parent = emptyenv())
  blocked <- release_verdict(scope)
  no_go <- if (tfls_allow_recoverable()) character(0) else release_refused(scope)
  f <- function(table) {
    t <- toupper(chr(table))
    st <- run_table_status(scope, t)
    if (!isTRUE(st$ok)) return(NULL)
    # The run's own verdict on its release, before anything is read. The raw
    # table is NOT the answer here either: the released copy is what carries a
    # recoverable cell, and reading the raw one instead would publish
    # everything the release was run to remove.
    if (sub("_RELEASE$", "", t) %in% no_go) {
      assign(t, paste0(
        "this run's own record of its release says: ", blocked,
        ". A withheld cell that the rest of its group gives away is not ",
        "closed by filling a shell at a higher floor - the subtraction is in ",
        "the released copy this reads from. Regroup, or withhold a second ",
        "stratum, and re-run the release module. To fill the shells anyway, ",
        "knowing that, set TFLS_ALLOW_RECOVERABLE=TRUE"), envir = refused)
      return(NULL)
    }
    rel <- paste0(t, "_RELEASE")
    # Where the run published a released copy, that is what is read, so the
    # suppression is the package's own and not a second opinion of it. A
    # release a previous run left behind is not this run's and is not
    # preferred.
    if (!grepl("_RELEASE$", t) && isTRUE(run_table_status(scope, rel)$ok)) {
      d <- read_one(rel)
      # FAIL CLOSED. "The run never released" and "the run says it released
      # and the copy is not there" are different, and only the first may read
      # the raw table. Falling back on the second would publish the numbers
      # the release was run to remove, under a run that says it removed them -
      # a partial write or a deleted table would quietly undo the release.
      if (is.null(d) || !nrow(d)) {
        assign(t, paste0(
          "this run released ", t, ", so its released copy is what may be ",
          "read - and that copy is ",
          if (is.null(d)) "not under the prefix" else "there with no rows",
          ". The raw table is not read in its place: it holds what the ",
          "release was run to remove"), envir = refused)
        return(NULL)
      }
      return(run_cohort_rows(d, scope))
    }
    run_cohort_rows(read_one(t), scope)
  }
  attr(f, "refusals") <- refused
  f
}

# What a reader refused to read, and why, in its own words. Empty for a table
# it never refused.
reader_refusal <- function(reader, table) {
  e <- attr(reader, "refusals")
  t <- toupper(chr(table))
  if (is.null(e) || !exists(t, envir = e, inherits = FALSE)) return("")
  get(t, envir = e, inherits = FALSE)
}
