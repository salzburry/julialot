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

# Two cells of a three-way comparison are not a smaller answer, they are a
# different one, so a missing cell stops the run.
for (c_i in cells)
  for (nm in c("LOT_LONG_FINAL", "MAP_STACKED"))
    tryCatch(db_q(con, paste0("SELECT 1 FROM ", tbl(c_i, nm), " LIMIT 1")),
             error = function(e)
               stop("Cell '", c_i$id, "' has no ", tbl(c_i, nm),
                    ". Build the cells first with run_aug1_melp.R.", call. = FALSE))

# The build these questions are asked of has the CAR-T 60-day induction rule
# applied. Read back off what each cell recorded, not off the code, and a stop
# rather than a warning: over a build without it the answers below would be
# about two changes at once and nothing in the CSVs would say so.
cart <- vapply(cells, function(c_i) {
  s <- tryCatch(db_q(con, paste0("SELECT CONTRACT_SETTINGS FROM ",
                                 tbl(c_i, "LOT_RUN_METADATA"),
                                 " LIMIT 1"))$CONTRACT_SETTINGS[1],
                error = function(e) NA_character_)
  if (is.na(s) || !grepl("apply_cart_induction_rule=", s, fixed = TRUE))
    return(NA_character_)
  toupper(trimws(sub("^.*apply_cart_induction_rule=([^|]*).*$", "\\1", s)))
}, character(1))
names(cart) <- vapply(cells, function(c_i) c_i$id, character(1))
bad <- names(cart)[is.na(cart) | cart != "TRUE"]
if (length(bad))
  stop("The CAR-T 60-day induction rule is not recorded as applied in: ",
       paste(bad, collapse = ", "), ". Rebuild those cells before reading them.",
       call. = FALSE)
cat("CAR-T 60-day induction rule applied in all ", length(cells), " cells\n", sep = "")

# Melphalan anywhere in follow-up, fixed once from the reference cell and used
# for every cell. Each cell's own melphalan patients would let the population
# move with the rule, and a difference would not say whether the lines changed
# or the people did. map_stacked is bounded to the patient's observation, so
# "anywhere in the table" is "anywhere in follow-up".
ref <- cells[[which(vapply(cells, function(c_i) is.na(c_i$mode), logical(1)))[1]]]
denom <- paste0("(SELECT DISTINCT PATID FROM ", tbl(ref, "MAP_STACKED"),
                " WHERE upper(trim(MAP_MED_TYPE)) = '", MELP, "')")
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
# Any transplant the line carries: autologous, allogeneic or CAR-T.
q3 <- per_cell(function(c_i) paste0("
  SELECT l.LOT_NUM,
         count(DISTINCT l.PATID) AS N_PATIENTS_MELP_LOT,
         count(DISTINCT CASE WHEN coalesce(l.LOT_TX_AUTO_FLG, 0) = 1
                               OR coalesce(l.LOT_ALLO_LOT_FLG, 0) = 1
                               OR coalesce(l.LOT_CART_LOT_FLG, 0) = 1
                             THEN l.PATID END) AS N_PATIENTS_WITH_SCT
  FROM ", lines_of(c_i), "
  WHERE array_contains(split(coalesce(l.LOT_BASE_MEDS, ''), ' '), '", MELP, "')
  GROUP BY l.LOT_NUM ORDER BY l.LOT_NUM"))

write_out <- function(d, name, title) {
  cat("\n", title, "\n", sep = "")
  if (is.null(d) || !nrow(d)) { cat("  (no rows)\n"); return(invisible()) }
  print(d, row.names = FALSE)
  utils::write.csv(d, file.path(out_dir, name), row.names = FALSE)
  cat("  -> ", file.path(out_dir, name), "\n", sep = "")
}

write_out(q1, "melp_ask1_line_duration.csv", "1. Duration of each line")
write_out(q2, "melp_ask2_melp_lots_by_line.csv",
          "2. LOTs containing melphalan, and LOTs that are melphalan alone")
write_out(q3, "melp_ask3_sct_in_melp_lot.csv",
          "3. An SCT inside a melphalan-containing LOT")
