#!/usr/bin/env Rscript
# Three questions, among patients who receive melphalan anywhere in follow-up:
#
#   1. the change in duration of each line after applying the melphalan rule
#   2. for every line, how many LOTs contain melphalan and how many are
#      melphalan on its own
#   3. how many receive an SCT in a melphalan-containing LOT, by line
#
#   DATABRICKS_PWD=... DOMINO_USER_NAME=usr00000 \
#     Rscript exploration/melphalan/read_melp_asks.R
#
# Reads the cells run_aug1_melp.R has already built and writes three CSVs.
# Every statement is a SELECT: it builds nothing and changes no rule.

.script_dir <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  # Rscript renders a space in a path as ~+~, so a folder with one in its name
  # resolves to nothing without this.
  if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                            fixed = TRUE))) else getwd()
})
LOT_ROOT <- normalizePath(file.path(.script_dir, "..", "..", "lot", "engine"), mustWork = TRUE)

source(file.path(LOT_ROOT, "R", "load_inputs.R"))
load_pipeline_inputs(LOT_ROOT, "config.csv")
for (f in c("config_lot.R", "db_utils_lot.R"))
  source(file.path(LOT_ROOT, "R", f))
source(file.path(.script_dir, "R", "cells.R"))

cfg <- get("cfg_defaults", envir = globalenv())
schema <- Sys.getenv("PROJECT_WORK_SCHEMA",
            unset = Sys.getenv("DOMINO_USER_NAME", unset = ""))
if (!nzchar(schema))
  stop("No work schema. Set DOMINO_USER_NAME or PROJECT_WORK_SCHEMA.", call. = FALSE)
cfg$work_schema <- schema
set_lot_config(cfg)

MELP <- toupper(trimws(cfg$melp_med_abbr %||% "MELP"))
out_dir <- melp_out_dir(.script_dir)
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")
con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

cells <- melp_cell_plan(MELP_CELLS,
                        trimws(Sys.getenv("AUG1_PREFIX_BASE", unset = "melp_")))
tbl <- function(cell, name) paste0(cfg$catalog, ".", schema, ".", cell$prefix, name)

# Provenance, through the package's own checks rather than a second set here.
# Readable tables and a CAR-T setting are not enough to make three cells
# comparable: melp_read_inputs / melp_check_inputs hold them to one cohort
# attempt, one code hash, one code-list set and one study window, and
# melp_check_deviations holds each to exactly its own intended deviation and
# the reference to none. Without those, three cells built over two cohort
# attempts read as a melphalan effect.
status <- setNames(lapply(cells, function(c_i) cell_status(con, c_i)),
                   vapply(cells, function(c_i) c_i$id, character(1)))
inputs <- melp_read_inputs(con, cells, status)

# A code-fingerprint mismatch is a stop here, not the warning it is elsewhere.
# This script reads cells some earlier run built, and a rule-on cell built by
# older engine code answers the question about that engine rather than this
# one. The reference cell is the reason it cannot be shrugged off: with the
# rule off, melp_lot1_ctes emits nothing, so the reference is whatever the
# engine was on the day it ran while the two rule-on cells carry the rule AND
# whatever else that day's code did. A difference between them is then two
# changes, and nothing in the CSVs would say so.
if (identical(melp_check_code(inputs, LOT_ROOT), FALSE))
  stop("These cells were not built by the engine code reading them. Rebuild ",
       "all ", length(cells), " with run_aug1_melp.R before reading them - a ",
       "melphalan number off older code cannot be compared with this one.",
       call. = FALSE)
st <- melp_settings(inputs)
cat("All ", length(cells), " cells: cohort attempt ", inputs[[1]]$COHORT_RUN_ID[1],
    " / ", inputs[[1]]$COHORT_STAMP[1],
    ", same code, code lists, window and settings\n", sep = "")

# The CAR-T 60-day induction rule is the build these questions are asked of.
# Off the cells' own recorded settings, and a stop rather than a warning: over
# a build without it the answers would be about two changes at once and
# nothing in the CSVs would say so.
cart <- vapply(inputs, function(r) {
  v <- melp_parse_settings(r$CONTRACT_SETTINGS[1])[["apply_cart_induction_rule"]]
  if (is.null(v)) NA_character_ else toupper(trimws(v))
}, character(1))
if (any(is.na(cart) | cart != "TRUE"))
  stop("The CAR-T 60-day induction rule is not recorded as applied in: ",
       paste(names(cart)[is.na(cart) | cart != "TRUE"], collapse = ", "),
       ". Rebuild those cells before reading them.", call. = FALSE)
cat("CAR-T 60-day induction rule applied in all ", length(cells), " cells\n", sep = "")

# The melphalan abbreviation comes off the cells too, not off this session's
# config - the tables were written by an earlier run and it is that run's
# abbreviation the regimen strings carry.
MELP <- toupper(trimws(st$melp_med_abbr %||% MELP))

# Melphalan anywhere in follow-up, through the package's own definition and
# fixed once from the reference cell. Each cell's own melphalan patients would
# let the population move with the rule, and a difference would not say whether
# the lines changed or the people did.
ref <- cells[[which(vapply(cells, function(c_i) is.na(c_i$mode), logical(1)))[1]]]
denom <- paste0("(", melp_exposed_sql(tbl(ref, "MAP_STACKED"), MELP), ")")
cat("Melphalan anywhere in follow-up: ",
    db_q(con, paste0("SELECT count(*) AS n FROM ", denom, " d"))$n[1],
    " patients\n", sep = "")

lines_of <- function(cell)
  paste0(tbl(cell, "LOT_LONG_FINAL"), " l INNER JOIN ", denom, " d",
         " ON cast(l.PATID as string) = cast(d.PATID as string)")

per_cell <- function(body) do.call(rbind, lapply(cells, function(c_i) {
  d <- db_q(con, paste0(body(c_i)))
  if (!nrow(d)) NULL else cbind(CELL = c_i$id, d, stringsAsFactors = FALSE)
}))

# --- 1. duration of each line ------------------------------------------------
q1 <- per_cell(function(c_i) paste0("
  SELECT l.LOT_NUM,
         count(DISTINCT l.PATID)                   AS N_PATIENTS,
         count(*)                                  AS N_LINES,
         percentile_approx(l.LOT_BASE_LENGTH, 0.5) AS MEDIAN_DAYS,
         round(avg(l.LOT_BASE_LENGTH), 1)          AS MEAN_DAYS
  FROM ", lines_of(c_i), "
  GROUP BY l.LOT_NUM ORDER BY l.LOT_NUM"))

# The change against the reference, so the answer is a difference rather than
# three tables to subtract by eye.
if (!is.null(q1)) {
  r <- q1[q1$CELL == ref$id, c("LOT_NUM", "MEDIAN_DAYS", "MEAN_DAYS")]
  names(r) <- c("LOT_NUM", "REF_MEDIAN", "REF_MEAN")
  q1 <- merge(q1, r, by = "LOT_NUM", all.x = TRUE)
  q1$MEDIAN_CHANGE <- q1$MEDIAN_DAYS - q1$REF_MEDIAN
  q1$MEAN_CHANGE   <- round(q1$MEAN_DAYS - q1$REF_MEAN, 1)
  q1 <- q1[order(q1$CELL, q1$LOT_NUM),
           c("CELL", "LOT_NUM", "N_PATIENTS", "N_LINES",
             "MEDIAN_DAYS", "MEDIAN_CHANGE", "MEAN_DAYS", "MEAN_CHANGE")]
}

# --- 2. melphalan-containing and melphalan-only LOTs, every line ------------
# ANY_MELP is a LOT whose regimen holds melphalan, among other drugs or on its
# own. MELP_MONO is the subset where melphalan is the whole regimen.
# array_contains over the split string, not LIKE, so a drug whose abbreviation
# merely contains MELP cannot match.
q2 <- per_cell(function(c_i) paste0("
  SELECT l.LOT_NUM,
         count(DISTINCT l.PATID) AS N_PATIENTS,
         count(DISTINCT CASE WHEN array_contains(
                 split(coalesce(l.LOT_BASE_MEDS, ''), ' '), '", MELP, "')
                             THEN l.PATID END) AS N_ANY_MELP,
         count(DISTINCT CASE WHEN trim(coalesce(l.LOT_BASE_MEDS, '')) = '", MELP, "'
                             THEN l.PATID END) AS N_MELP_MONO
  FROM ", lines_of(c_i), "
  GROUP BY l.LOT_NUM ORDER BY l.LOT_NUM"))

# --- 3. an SCT inside a melphalan-containing LOT -----------------------------
# A melphalan LOT here is one with a melphalan DOSE between its start and end,
# not one whose regimen string holds melphalan. The two differ, and the regimen
# string is the wrong one for this question: a melphalan dose outside the
# induction window never reaches LOT_BASE_MEDS, and an ALLO line has a blank
# regimen by construction - allo_lot_span is single_day - so a dose given on
# that day would be dropped by a regimen test.
#
# The transplant expression is melp_sct_sql(), the package's own. It counts
# AUTO anywhere in the line and ALLO as the line's start type, and leaves CAR-T
# out: a one-day ALLO line has no inside for a transplant to sit in, and CAR-T
# is a separate question rather than a third term in this total.
q3 <- per_cell(function(c_i) paste0("
  SELECT l.LOT_NUM,
         count(DISTINCT l.PATID) AS N_PATIENTS_MELP_LOT,
         count(DISTINCT CASE WHEN ", melp_sct_sql(), " THEN l.PATID END)
                                 AS N_PATIENTS_WITH_SCT
  FROM ", lines_of(c_i), "
  WHERE EXISTS (SELECT 1 FROM ", tbl(c_i, "MAP_STACKED"), " ms
                 WHERE cast(ms.PATID as string) = cast(l.PATID as string)
                   AND upper(trim(ms.MAP_MED_TYPE)) = '", MELP, "'
                   AND ms.MAP_START_DT >= l.LOT_START_DT
                   AND ms.MAP_START_DT <= l.LOT_BASE_END_DT)
  GROUP BY l.LOT_NUM ORDER BY l.LOT_NUM"))

# A query with no rows still writes, so an earlier run's file cannot sit there
# looking like this one's answer.
write_out <- function(d, name, title) {
  cat("\n", title, "\n", sep = "")
  f <- file.path(out_dir, name)
  if (is.null(d) || !nrow(d)) {
    cat("  (no rows)\n")
    utils::write.csv(data.frame(), f, row.names = FALSE)
  } else {
    print(d, row.names = FALSE)
    utils::write.csv(d, f, row.names = FALSE)
  }
  cat("  -> ", f, "\n", sep = "")
}

# A cell rebuilt between the first query and the last would mix two builds, so
# the read is held to the attempt it started on before anything is written.
melp_status_unchanged(con, cells, status)

write_out(q1, "melp_ask1_line_duration.csv", "1. Duration of each line")
write_out(q2, "melp_ask2_melp_lots_by_line.csv",
          "2. LOTs containing melphalan, and LOTs that are melphalan alone")
write_out(q3, "melp_ask3_sct_in_melp_lot.csv",
          "3. An SCT inside a melphalan-containing LOT")
