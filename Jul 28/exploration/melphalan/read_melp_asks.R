#!/usr/bin/env Rscript
# The three questions asked on 2026-08-14, among patients who receive
# melphalan anywhere in follow-up:
#
#   1. the change in duration of each line after applying the rule
#   2. the regimen distribution for each line, and how many still get 2L
#      melphalan alone
#   3. how many receive an SCT in a melphalan-containing LOT, by line
#
# All three are asked of a build with the CAR-T 60-day induction rule applied.
# That rule is the engine's, not this script's, and it was part of the same
# request: a CAR-T inside line 1's 60-day window belongs to line 1 and does not
# start line 2. So it is a PRECONDITION here and not a fourth answer - the
# script reads it back off each cell and refuses to report anything if a cell
# was built without it, because those three tables would then describe a build
# nobody asked for.
#
#   DATABRICKS_PWD=... DOMINO_USER_NAME=usr00000 \
#     Rscript exploration/melphalan/read_melp_asks.R
#
# Reads the cells run_aug1_melp.R has already built and writes three CSVs. It
# builds nothing and changes nothing: every statement is a SELECT.
#
# The denominator is fixed once, from the reference cell, and used for every
# cell. Taking each cell's own melphalan patients would let the population move
# with the rule, and then a difference in the numbers would not say whether the
# lines changed or the people did.

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
  stop("No work schema. Set DOMINO_USER_NAME or PROJECT_WORK_SCHEMA.",
       call. = FALSE)
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

# A cell whose tables are missing stops the run. Two cells of a three-way
# comparison are not a smaller answer, they are a different one.
for (c_i in cells)
  for (nm in c("LOT_LONG_FINAL", "MAP_STACKED")) {
    t <- tbl(c_i, nm)
    tryCatch(db_q(con, paste0("SELECT 1 FROM ", t, " LIMIT 1")),
             error = function(e)
               stop("Cell '", c_i$id, "' has no ", t, ". Build the cells first ",
                    "with run_aug1_melp.R.", call. = FALSE))
  }

# The precondition: every cell must carry the CAR-T 60-day induction rule.
#
# Read back off what each cell RECORDED, not off the code. A cell build sets
# only LOT_CONTRACT_OVERRIDE and APPLY_MELP_RULE, so it inherits the contract's
# apply_cart_induction_rule - but the file on disk describes the next build,
# and these tables were written by an earlier one.
#
# A stop, not a warning. The three answers below are about what the melphalan
# rule changes; computed over a build without the CAR-T rule they would be
# about two differences at once, and nothing in the CSVs would say so.
cart <- vapply(cells, function(c_i) {
  s <- tryCatch(db_q(con, paste0("
    SELECT CONTRACT_SETTINGS FROM ", tbl(c_i, "LOT_RUN_METADATA"),
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
       paste0(bad, " (", ifelse(is.na(cart[bad]), "not recorded", cart[bad]), ")",
              collapse = ", "),
       ". Rebuild those cells before reading them - the three answers below are ",
       "about what the melphalan rule changes, and over a build without the ",
       "CAR-T rule they would be about two changes at once.", call. = FALSE)
cat("CAR-T 60-day induction rule: applied in all ", length(cells),
    " cells\n", sep = "")

# The denominator: melphalan anywhere in follow-up, from the reference cell.
# map_stacked is bounded to the patient's own observation, so "anywhere in the
# table" is "anywhere in follow-up" without a date test.
ref <- cells[[which(vapply(cells, function(c_i) is.na(c_i$mode), logical(1)))[1]]]
denom <- paste0("(SELECT DISTINCT PATID FROM ", tbl(ref, "MAP_STACKED"),
                " WHERE upper(trim(MAP_MED_TYPE)) = '", MELP, "')")
n_denom <- db_q(con, paste0("SELECT count(*) AS n FROM ", denom, " d"))$n[1]
cat("\nMelphalan anywhere in follow-up: ", n_denom, " patients",
    " (from the reference cell, and used for every cell)\n", sep = "")

lines_of <- function(cell)
  paste0(tbl(cell, "LOT_LONG_FINAL"), " l INNER JOIN ", denom, " d",
         " ON cast(l.PATID as string) = cast(d.PATID as string)")

# --- 1. duration of each line -----------------------------------------------
q1 <- do.call(rbind, lapply(cells, function(c_i) {
  d <- db_q(con, paste0("
    SELECT l.LOT_NUM,
           count(*)                                    AS N_LINES,
           count(DISTINCT l.PATID)                     AS N_PATIENTS,
           round(avg(l.LOT_BASE_LENGTH), 1)            AS MEAN_DAYS,
           percentile_approx(l.LOT_BASE_LENGTH, 0.5)   AS MEDIAN_DAYS
    FROM ", lines_of(c_i), "
    GROUP BY l.LOT_NUM ORDER BY l.LOT_NUM"))
  if (!nrow(d)) return(NULL)
  cbind(CELL = c_i$id, d, stringsAsFactors = FALSE)
}))

# The change, against the reference, so the answer is a difference rather than
# three tables to subtract by eye.
if (!is.null(q1)) {
  base <- q1[q1$CELL == ref$id, c("LOT_NUM", "MEDIAN_DAYS", "MEAN_DAYS", "N_LINES")]
  names(base) <- c("LOT_NUM", "REF_MEDIAN", "REF_MEAN", "REF_N_LINES")
  q1 <- merge(q1, base, by = "LOT_NUM", all.x = TRUE)
  q1$MEDIAN_CHANGE  <- q1$MEDIAN_DAYS - q1$REF_MEDIAN
  q1$MEAN_CHANGE    <- round(q1$MEAN_DAYS - q1$REF_MEAN, 1)
  q1$N_LINES_CHANGE <- q1$N_LINES - q1$REF_N_LINES
  q1 <- q1[order(q1$CELL, q1$LOT_NUM), ]
}

# --- 2. regimens for each line ----------------------------------------------
q2 <- do.call(rbind, lapply(cells, function(c_i) {
  d <- db_q(con, paste0("
    SELECT l.LOT_NUM,
           coalesce(nullif(trim(l.LOT_BASE_MEDS), ''), '(none)') AS REGIMEN,
           count(DISTINCT l.PATID) AS N_PATIENTS
    FROM ", lines_of(c_i), "
    GROUP BY l.LOT_NUM, coalesce(nullif(trim(l.LOT_BASE_MEDS), ''), '(none)')
    ORDER BY l.LOT_NUM, N_PATIENTS DESC"))
  if (!nrow(d)) return(NULL)
  cbind(CELL = c_i$id, d, stringsAsFactors = FALSE)
}))

# The one the question names: 2L melphalan on its own.
q2_mono <- do.call(rbind, lapply(cells, function(c_i) {
  d <- db_q(con, paste0("
    SELECT count(DISTINCT l.PATID) AS N_PATIENTS
    FROM ", lines_of(c_i), "
    WHERE l.LOT_NUM = 2 AND trim(l.LOT_BASE_MEDS) = '", MELP, "'"))
  data.frame(CELL = c_i$id, LOT_NUM = 2L, REGIMEN = MELP,
             N_PATIENTS = d$N_PATIENTS[1], stringsAsFactors = FALSE)
}))

# --- 3. an SCT inside a melphalan-containing LOT ----------------------------
# Any transplant the line carries: autologous, allogeneic or CAR-T. A
# melphalan-containing LOT is one whose regimen string holds it.
q3 <- do.call(rbind, lapply(cells, function(c_i) {
  d <- db_q(con, paste0("
    SELECT l.LOT_NUM,
           count(DISTINCT l.PATID) AS N_PATIENTS_MELP_LOT,
           count(DISTINCT CASE WHEN coalesce(l.LOT_TX_AUTO_FLG, 0) = 1
                                 OR coalesce(l.LOT_ALLO_LOT_FLG, 0) = 1
                                 OR coalesce(l.LOT_CART_LOT_FLG, 0) = 1
                               THEN l.PATID END) AS N_PATIENTS_WITH_SCT
    FROM ", lines_of(c_i), "
    WHERE array_contains(split(coalesce(l.LOT_BASE_MEDS, ''), ' '), '", MELP, "')
    GROUP BY l.LOT_NUM ORDER BY l.LOT_NUM"))
  if (!nrow(d)) return(NULL)
  cbind(CELL = c_i$id, d, stringsAsFactors = FALSE)
}))

write_out <- function(d, name, title) {
  cat("\n", title, "\n", sep = "")
  if (is.null(d) || !nrow(d)) { cat("  (no rows)\n"); return(invisible()) }
  print(d, row.names = FALSE)
  f <- file.path(out_dir, name)
  utils::write.csv(d, f, row.names = FALSE)
  cat("  -> ", f, "\n", sep = "")
}

write_out(q1, "melp_ask1_line_duration.csv",
          "1. Duration of each line, and the change against the reference")
write_out(q2, "melp_ask2_regimens_by_line.csv",
          "2. Regimen distribution for each line")
write_out(q2_mono, "melp_ask2_2l_melp_mono.csv",
          "   ...and 2L melphalan on its own")
write_out(q3, "melp_ask3_sct_in_melp_lot.csv",
          "3. An SCT inside a melphalan-containing LOT, by line")

cat("\nDone. ", n_denom, " melphalan patients, ", length(cells), " cells.\n", sep = "")
