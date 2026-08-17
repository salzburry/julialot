#!/usr/bin/env Rscript
# What each melphalan decision is worth, as a number per cell.
#
#   DATABRICKS_PWD=... DOMINO_USER_NAME=usr00000 \
#     Rscript exploration/melphalan/read_melp_decisions.R
#
# read_melp_asks.R answers the three questions. This answers a different one:
# the rule was built out of several decisions, some of them settled by the
# request and some assumed, and each one moved patients. A single before-and-
# after on line counts cannot say which decision did what, so a reviewer cannot
# tell a well-founded change from a guess that happened to be quiet.
#
# One block per decision, counting the population that decision touches. Read
# against the reference cell each is the group at risk; against a rule cell it
# is what the decision did to them.
#
# Every statement is a SELECT. It builds nothing and changes no rule.
#
# The last block is the one to read first. UNOWNED counts melphalan doses that
# ended up in no line at all, which is the failure mode every ownership
# decision here exists to prevent - and the one place a remaining gap shows up
# as a number rather than as a paragraph.

.script_dir <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
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

out_dir <- melp_out_dir(.script_dir)
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
DECISION_CSV <- "melp_decision_impact.csv"
unlink(file.path(out_dir, DECISION_CSV))

stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")
con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

cells <- melp_cell_plan(MELP_CELLS,
                        trimws(Sys.getenv("AUG1_PREFIX_BASE", unset = "melp_")))
tbl <- function(cell, name) paste0(cfg$catalog, ".", schema, ".", cell$prefix, name)

# Same provenance the asks reader uses. A decision measured across two cohort
# attempts or two code versions is not measuring the decision.
status <- setNames(lapply(cells, function(c_i) cell_status(con, c_i)),
                   vapply(cells, function(c_i) c_i$id, character(1)))
inputs <- melp_read_inputs(con, cells, status)
if (identical(melp_check_code(inputs, LOT_ROOT), FALSE))
  stop("These cells were not built by the engine code reading them. Rebuild ",
       "all ", length(cells), " with run_aug1_melp.R before reading them.",
       call. = FALSE)
st   <- melp_settings(inputs)
MELP <- toupper(trimws(st$melp_med_abbr %||% cfg$melp_med_abbr %||% "MELP"))
EXPO <- as.integer(st$melp_exposure_days  %||% cfg$melp_exposure_days)
REST <- as.integer(st$melp_restart_days   %||% cfg$melp_restart_days)
ADV  <- as.integer(st$melp_advance_days   %||% cfg$melp_advance_days)

cat("All ", length(cells), " cells: cohort attempt ", inputs[[1]]$COHORT_RUN_ID[1],
    ", same code and settings. exposure=", EXPO, "d restart=", REST,
    "d advance=", ADV, "d\n", sep = "")

# The exposure chain, rebuilt here as a read. It is the engine's own shape -
# doses less than melp_exposure_days apart are one administration, chained
# rather than pairwise - because a decision counted over raw doses would count
# a three-dose administration as two pairs.
expo_sql <- function(cell) paste0("
  WITH doses AS (
    SELECT PATID, MAP_START_DT AS DOSE_DT
    FROM ", tbl(cell, "MAP_STACKED"),
    " WHERE upper(trim(MAP_MED_TYPE)) = '", MELP, "'
    GROUP BY PATID, MAP_START_DT
  ),
  runs AS (
    SELECT PATID, DOSE_DT,
           CASE WHEN datediff(DOSE_DT,
                  lag(DOSE_DT) OVER (PARTITION BY PATID ORDER BY DOSE_DT))
                     < ", EXPO, " THEN 0 ELSE 1 END AS IS_NEW
    FROM doses
  ),
  dose_expo AS (
    SELECT PATID, DOSE_DT,
           min(DOSE_DT) OVER (PARTITION BY PATID, E) AS EXPO_DT
    FROM (SELECT PATID, DOSE_DT,
                 sum(IS_NEW) OVER (PARTITION BY PATID ORDER BY DOSE_DT
                                   ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS E
          FROM runs) r
  ),
  expo AS (SELECT DISTINCT PATID, EXPO_DT FROM dose_expo),
  paired AS (
    SELECT PATID, EXPO_DT,
           lead(EXPO_DT) OVER (PARTITION BY PATID ORDER BY EXPO_DT) AS NEXT_DT
    FROM expo
  )")

per_cell <- function(body) do.call(rbind, lapply(cells, function(c_i) {
  d <- db_q(con, body(c_i))
  if (!nrow(d)) NULL else cbind(CELL = c_i$id, d, stringsAsFactors = FALSE)
}))

# --- 1. the branch populations ------------------------------------------------
# How many exposures each branch of the request decides. This is the size of
# the rule itself: a branch with no patients in it moved nothing whatever the
# code does, and one with many is where the answer comes from.
#
# INSIDE is judged against the line the exposure falls in, the way the engine
# judges it, rather than against LOT1 for everyone.
branch <- per_cell(function(c_i) paste0(expo_sql(c_i), ",
  judged AS (
    SELECT p.PATID, p.EXPO_DT, p.NEXT_DT,
           datediff(p.NEXT_DT, p.EXPO_DT) AS GAP,
           l.LOT_NUM,
           CASE WHEN p.EXPO_DT <= date_add(l.LOT_START_DT,
                  CASE l.LOT_START_TYPE
                    WHEN 'SCT_ALLO' THEN 0
                    WHEN 'CART'     THEN ", cfg$cart_consolidation_days - 1, "
                    ELSE CASE WHEN l.LOT_NUM = 1
                              THEN ", cfg$induction_window_days - 1, "
                              ELSE ", cfg$lot_n_induction_window_days - 1, " END
                  END)
                THEN 1 ELSE 0 END AS INSIDE
    FROM paired p
    INNER JOIN ", tbl(c_i, "LOT_LONG_FINAL"), " l
      ON l.PATID = p.PATID
     AND p.EXPO_DT BETWEEN l.LOT_START_DT AND l.LOT_BASE_END_DT
  )
  SELECT CASE WHEN GAP IS NULL             THEN 'no next exposure - no branch applies'
              WHEN INSIDE = 1 AND GAP <  ", ADV,  " THEN 'A.1 in, next <", ADV, " - does not advance'
              WHEN INSIDE = 1                       THEN 'A.2 in, next >=", ADV, " - later advances'
              WHEN GAP <  ", REST, "                THEN 'B.1 out, next <", REST, " - advances at the FIRST dose'
              WHEN GAP <  ", ADV,  "                THEN 'B.2 out, ", REST, "-", ADV - 1, " - neither advances'
              ELSE                                       'B.3 out, next >=", ADV, " - later advances'
         END                     AS BRANCH,
         count(*)                AS N_EXPOSURES,
         count(DISTINCT PATID)   AS N_PATIENTS
  FROM judged GROUP BY 1 ORDER BY 1"))

# --- 2. the ownership decision, as the number it exists to keep at zero -------
# Every non-advancing exposure is supposed to sit inside the line it belongs
# to. A dose in no line is that decision failing, and it is the one number that
# does not need interpreting: it should be zero, and where it is not, the LOT
# start type of the line the dose sits after says which gap produced it.
#
# The known open case is a B.2 pair after a CAR-T-only or single-day ALLO line:
# those lines end on their own start date before any run-out is consulted, so
# carrying the run-out cannot reach the dose. It will show here as rows whose
# PRIOR_LINE_TYPE is CART or SCT_ALLO. Anything else is a gap nobody has
# named yet.
unowned <- per_cell(function(c_i) paste0("
  WITH doses AS (
    SELECT DISTINCT PATID, MAP_START_DT AS DOSE_DT
    FROM ", tbl(c_i, "MAP_STACKED"),
    " WHERE upper(trim(MAP_MED_TYPE)) = '", MELP, "'
  ),
  orphan AS (
    SELECT d.PATID, d.DOSE_DT
    FROM doses d
    WHERE EXISTS (SELECT 1 FROM ", tbl(c_i, "LOT_LONG_FINAL"), " c
                   WHERE c.PATID = d.PATID)
      AND d.DOSE_DT >= (SELECT min(c.LOT_START_DT) FROM ", tbl(c_i, "LOT_LONG_FINAL"), " c
                         WHERE c.PATID = d.PATID)
      AND NOT EXISTS (SELECT 1 FROM ", tbl(c_i, "LOT_LONG_FINAL"), " l
                       WHERE l.PATID = d.PATID
                         AND d.DOSE_DT BETWEEN l.LOT_START_DT AND l.LOT_BASE_END_DT)
  )
  SELECT coalesce((SELECT l.LOT_START_TYPE FROM ", tbl(c_i, "LOT_LONG_FINAL"), " l
                    WHERE l.PATID = o.PATID AND l.LOT_BASE_END_DT < o.DOSE_DT
                    ORDER BY l.LOT_BASE_END_DT DESC LIMIT 1), '(none)') AS PRIOR_LINE_TYPE,
         count(*)              AS N_DOSES,
         count(DISTINCT PATID) AS N_PATIENTS
  FROM orphan o GROUP BY 1 ORDER BY 1"))

# --- 3. the hold, as the length it added -------------------------------------
# The line-ownership decisions are all implemented by carrying a line's run-out
# to a non-advancing exposure. This is what that carrying is worth: lines whose
# last melphalan dose sits after every other agent's cover ended, so the line
# reaches the dose only because the rule carried it.
hold <- per_cell(function(c_i) paste0("
  WITH last_melp AS (
    SELECT l.PATID, l.LOT_NUM, l.LOT_START_DT, l.LOT_BASE_END_DT,
           l.LOT_BASE_END_REASON, l.LOT_BASE_LENGTH,
           max(ms.MAP_START_DT) AS LAST_MELP_DT
    FROM ", tbl(c_i, "LOT_LONG_FINAL"), " l
    INNER JOIN ", tbl(c_i, "MAP_STACKED"), " ms
      ON ms.PATID = l.PATID
     AND upper(trim(ms.MAP_MED_TYPE)) = '", MELP, "'
     AND ms.MAP_START_DT BETWEEN l.LOT_START_DT AND l.LOT_BASE_END_DT
    GROUP BY l.PATID, l.LOT_NUM, l.LOT_START_DT, l.LOT_BASE_END_DT,
             l.LOT_BASE_END_REASON, l.LOT_BASE_LENGTH
  ),
  other_cover AS (
    SELECT lm.PATID, lm.LOT_NUM, max(ms.MAP_END_DT) AS OTHER_END_DT
    FROM last_melp lm
    INNER JOIN ", tbl(c_i, "MAP_STACKED"), " ms
      ON ms.PATID = lm.PATID
     AND upper(trim(ms.MAP_MED_TYPE)) <> '", MELP, "'
     AND ms.MAP_MED_CLASS <> 'STEROID'
     AND ms.MAP_START_DT <= lm.LOT_BASE_END_DT
     AND ms.MAP_END_DT   >= lm.LOT_START_DT
    GROUP BY lm.PATID, lm.LOT_NUM
  )
  SELECT lm.LOT_NUM,
         count(*)                                        AS N_LINES_WITH_MELP,
         sum(CASE WHEN oc.OTHER_END_DT IS NULL
                    OR lm.LAST_MELP_DT > oc.OTHER_END_DT
                  THEN 1 ELSE 0 END)                     AS N_HELD_TO_THE_DOSE,
         percentile_approx(CASE WHEN oc.OTHER_END_DT IS NOT NULL
                                 AND lm.LAST_MELP_DT > oc.OTHER_END_DT
                                THEN datediff(lm.LAST_MELP_DT, oc.OTHER_END_DT) END, 0.5)
                                                         AS MEDIAN_DAYS_ADDED
  FROM last_melp lm
  LEFT JOIN other_cover oc ON oc.PATID = lm.PATID AND oc.LOT_NUM = lm.LOT_NUM
  GROUP BY lm.LOT_NUM ORDER BY lm.LOT_NUM"))

show <- function(d, title, note = NULL) {
  cat("\n", title, "\n", sep = "")
  if (!is.null(note)) cat("  ", note, "\n", sep = "")
  if (is.null(d) || !nrow(d)) cat("  (no rows)\n") else print(d, row.names = FALSE)
  d
}

melp_status_unchanged(con, cells, status)

show(branch,  "1. How many exposures each branch of the request decides")
show(unowned, "2. Melphalan doses inside NO line",
     "should be empty; CART / SCT_ALLO rows are the known open case")
show(hold,    "3. Lines reaching their last melphalan dose only because the rule carried them")

rows <- do.call(rbind, lapply(
  list(list("branch-populations", branch),
       list("doses-in-no-line",   unowned),
       list("held-to-the-dose",   hold)),
  function(x) if (is.null(x[[2]])) NULL else
    data.frame(DECISION = x[[1]],
               MEASURE  = apply(x[[2]], 1, function(r)
                 paste(names(x[[2]]), r, sep = "=", collapse = "; ")),
               stringsAsFactors = FALSE)))
f <- file.path(out_dir, DECISION_CSV)
utils::write.csv(if (is.null(rows)) data.frame() else rows, f, row.names = FALSE)
cat("\n  -> ", f, "\n", sep = "")
