#!/usr/bin/env Rscript
# What each part of the melphalan rule is worth, as a number per cell.
#
#   DATABRICKS_PWD=... DOMINO_USER_NAME=usr00000 \
#     Rscript exploration/melphalan/read_melp_decisions.R
#
# read_melp_asks.R answers the three questions. This answers a different one.
# The rule is several parts - the branch table, the suppression, the ownership
# carry - and each part moves a different population. A single before-and-after
# on line counts cannot say which part did what.
#
# One block per part, counting the population it touches. Against the reference
# cell each block is the group at risk; against a rule cell it is what the part
# did to them.
#
# Every statement is a SELECT. It builds nothing and changes no rule.
#
# Block 2 is the one to read first. It counts melphalan doses in no line at
# all, which is the failure the ownership carry exists to prevent, and the one
# place a gap shows up as a number rather than as a paragraph.
#
# No block here is a counterfactual by itself. Each is a number for one cell.
# The effect of a rule part is the difference between the cells, which
# make_audit_workbook.R puts side by side. Where a block's own number is a
# population rather than an effect, the block says so.

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
melp_check_code(inputs, LOT_ROOT)
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
#
# LEFT JOIN to the lines, not INNER. An inner join keeps only the exposures
# inside a finished line, so the branch table adds up to less than the exposures
# there are and the missing ones are invisible - and an exposure in no line is
# the failure block 2 exists to count. They get a row of their own here.
#
# The engine judges an exposure against the line's OBSERVATION span, so it can
# decide one that the finished line does not end up containing. This is a read
# of the finished tables, so "in no line" is the most it can say about those.
branch <- per_cell(function(c_i) paste0(expo_sql(c_i), ",
  first_line AS (
    SELECT PATID, min(LOT_START_DT) AS FIRST_START_DT
    FROM ", tbl(c_i, "LOT_LONG_FINAL"), " GROUP BY PATID
  ),
  judged AS (
    SELECT p.PATID, p.EXPO_DT, p.NEXT_DT,
           datediff(p.NEXT_DT, p.EXPO_DT) AS GAP,
           l.LOT_NUM,
           CASE WHEN l.PATID IS NULL THEN NULL
                WHEN p.EXPO_DT <= date_add(l.LOT_START_DT,
                  CASE l.LOT_START_TYPE
                    WHEN 'SCT_ALLO' THEN 0
                    WHEN 'CART'     THEN ", cfg$cart_consolidation_days - 1, "
                    ELSE CASE WHEN l.LOT_NUM = 1
                              THEN ", cfg$induction_window_days - 1, "
                              ELSE ", cfg$lot_n_induction_window_days - 1, " END
                  END)
                THEN 1 ELSE 0 END AS INSIDE
    FROM paired p
    INNER JOIN first_line f
      ON f.PATID = p.PATID AND p.EXPO_DT >= f.FIRST_START_DT
    LEFT JOIN ", tbl(c_i, "LOT_LONG_FINAL"), " l
      ON l.PATID = p.PATID
     AND p.EXPO_DT BETWEEN l.LOT_START_DT AND l.LOT_BASE_END_DT
  )
  SELECT CASE WHEN INSIDE IS NULL         THEN 'in no line - no window to judge it against'
              WHEN GAP IS NULL             THEN 'no next exposure - no branch applies'
              WHEN INSIDE = 1 AND GAP <  ", ADV,  " THEN 'A.1 in, next <", ADV, " - does not advance'
              WHEN INSIDE = 1                       THEN 'A.2 in, next >=", ADV, " - later advances'
              WHEN GAP <  ", REST, "                THEN 'B.1 out, next <", REST, " - advances at the FIRST dose'
              WHEN GAP <  ", ADV,  "                THEN 'B.2 out, ", REST, "-", ADV - 1, " - neither advances'
              ELSE                                       'B.3 out, next >=", ADV, " - later advances'
         END                     AS BRANCH,
         count(*)                AS N_EXPOSURES,
         count(DISTINCT PATID)   AS N_PATIENTS
  FROM judged GROUP BY 1 ORDER BY 1"))

# --- 2. ownership: the number that should be zero ----------------------------
# Every non-advancing exposure has to sit inside the line it belongs to. A dose
# in no line is that rule failing, and it is the one number here that needs no
# interpreting. Where it is not zero, the LOT start type of the line before the
# dose says which gap produced it.
#
# One thing is NOT that failure, and is split out rather than counted in.
#
# AFTER_THE_CAP: the build stops at max_lot lines. A patient who reached the cap
# goes on being treated after the last line ends, and every one of those doses
# is outside every line by construction. Counting them as unowned would put a
# number in this block that no ownership rule can move. The synthetic harness
# carves the same doses out of the same invariant.
#
# PRIOR_LINE_TYPE is an attribution, not an excuse. A single-day ALLO line, and
# a CAR-T line with no consolidation drug, end on their own start date before
# any run-out is consulted. melp_line_type_guard() lets the hold override both
# short-circuits, so the line falls through to the ordinary cascade and reaches
# the dose - and every other end still outranks the carried run-out.
#
# So no row here is expected. With AFTER_THE_CAP = 'no', every row is a gap
# nobody has named, CART and SCT_ALLO included. The synthetic harness holds the
# same invariant, and its planted CAR-T-only B.2 patient exercises the guard:
# that patient's LOT2 is a CAR-T line with no regimen, and it owns both
# melphalan doses.
#
# max_by rather than a correlated subquery with LIMIT 1. Spark rejects a
# correlated scalar subquery that is not an aggregate, so the LIMIT form would
# have failed on the warehouse rather than returned the wrong answer - but it
# would have failed at the end of a long read.
unowned <- per_cell(function(c_i) paste0("
  WITH lines AS (
    SELECT PATID, min(LOT_START_DT) AS FIRST_START_DT,
           max(LOT_BASE_END_DT) AS LAST_END_DT, count(*) AS N_LINES
    FROM ", tbl(c_i, "LOT_LONG_FINAL"), " GROUP BY PATID
  ),
  doses AS (
    SELECT DISTINCT PATID, MAP_START_DT AS DOSE_DT
    FROM ", tbl(c_i, "MAP_STACKED"),
    " WHERE upper(trim(MAP_MED_TYPE)) = '", MELP, "'
  ),
  orphan AS (
    SELECT d.PATID, d.DOSE_DT,
           CASE WHEN ln.N_LINES >= ", cfg$max_lot, "
                 AND d.DOSE_DT > ln.LAST_END_DT THEN 'yes' ELSE 'no' END AS AFTER_THE_CAP
    FROM doses d
    INNER JOIN lines ln ON ln.PATID = d.PATID
    WHERE d.DOSE_DT >= ln.FIRST_START_DT
      AND NOT EXISTS (SELECT 1 FROM ", tbl(c_i, "LOT_LONG_FINAL"), " l
                       WHERE l.PATID = d.PATID
                         AND d.DOSE_DT BETWEEN l.LOT_START_DT AND l.LOT_BASE_END_DT)
  ),
  with_prior AS (
    SELECT o.PATID, o.DOSE_DT, o.AFTER_THE_CAP,
           coalesce(max_by(l.LOT_START_TYPE, l.LOT_BASE_END_DT), '(none)') AS PRIOR_LINE_TYPE
    FROM orphan o
    LEFT JOIN ", tbl(c_i, "LOT_LONG_FINAL"), " l
      ON l.PATID = o.PATID AND l.LOT_BASE_END_DT < o.DOSE_DT
    GROUP BY o.PATID, o.DOSE_DT, o.AFTER_THE_CAP
  )
  SELECT AFTER_THE_CAP, PRIOR_LINE_TYPE,
         count(*)              AS N_DOSES,
         count(DISTINCT PATID) AS N_PATIENTS
  FROM with_prior GROUP BY 1, 2 ORDER BY 1, 2"))

# --- 3. the hold: the population it can touch and the mark it leaves ---------
# The ownership carry moves a line's run-out to a non-advancing exposure. Two
# numbers, because they say different things and only one is the rule's own.
#
#   N_PAST_THE_REGIMEN     lines whose last melphalan dose sits after the last
#                          cover of the line's OWN regimen agents. This is the
#                          group at risk, not the rule's effect: it is nonzero
#                          in the reference cell too, because a line can reach
#                          such a dose for reasons that have nothing to do with
#                          the rule - melphalan in the regimen covering itself,
#                          an added drug or a death ending the line later, the
#                          LOT cap, or the end of observation.
#
#   N_ENDING_ON_A_MELP_DOSE   lines that end in DISCONTINUATION on exactly the
#                          date of their last melphalan dose. That is the hold's
#                          signature: melp_hold sets the run-out TO the dose, so
#                          a held line ends on it. Off the rule the two dates
#                          coincide only by accident, so the difference between
#                          the cells is what the carrying did.
#
# Neither is a counterfactual on its own. This script reports one number per
# cell; the comparison across cells is where the effect is.
#
# The cover is the line's own REGIMEN agents, read off LOT_BASE_MEDS, not every
# non-steroid drug overlapping the span. Any drug at all was the wrong set: a
# line's run-out is built from its regimen, so a single unrelated agent running
# late made the last melphalan dose look covered and took the line out of the
# count. Two things still separate this from the engine's own run-out, and both
# are one-directional:
#
#   a permissible substitute's cover counts toward the run-out and is not in
#   LOT_BASE_MEDS, so REGIMEN_END_DT can be early and the days over-stated;
#
#   the run-out chain stops at a confirmed gap in the drug's own episodes, and
#   this does not, so REGIMEN_END_DT can be late and the days under-stated.
hold <- per_cell(function(c_i) paste0("
  WITH last_melp AS (
    SELECT l.PATID, l.LOT_NUM, l.LOT_START_DT, l.LOT_BASE_END_DT,
           l.LOT_BASE_END_REASON, l.LOT_BASE_DISCON_DT, l.LOT_BASE_MEDS,
           max(ms.MAP_START_DT) AS LAST_MELP_DT
    FROM ", tbl(c_i, "LOT_LONG_FINAL"), " l
    INNER JOIN ", tbl(c_i, "MAP_STACKED"), " ms
      ON ms.PATID = l.PATID
     AND upper(trim(ms.MAP_MED_TYPE)) = '", MELP, "'
     AND ms.MAP_START_DT BETWEEN l.LOT_START_DT AND l.LOT_BASE_END_DT
    GROUP BY l.PATID, l.LOT_NUM, l.LOT_START_DT, l.LOT_BASE_END_DT,
             l.LOT_BASE_END_REASON, l.LOT_BASE_DISCON_DT, l.LOT_BASE_MEDS
  ),
  regimen_cover AS (
    SELECT lm.PATID, lm.LOT_NUM, max(ms.MAP_END_DT) AS REGIMEN_END_DT
    FROM last_melp lm
    INNER JOIN ", tbl(c_i, "MAP_STACKED"), " ms
      ON ms.PATID = lm.PATID
     AND upper(trim(ms.MAP_MED_TYPE)) <> '", MELP, "'
     AND array_contains(split(lm.LOT_BASE_MEDS, ' '), ms.MAP_MED_TYPE)
     AND ms.MAP_START_DT >= lm.LOT_START_DT
     AND ms.MAP_START_DT <= lm.LOT_BASE_END_DT
    GROUP BY lm.PATID, lm.LOT_NUM
  )
  SELECT lm.LOT_NUM,
         count(*)                                        AS N_LINES_WITH_MELP,
         sum(CASE WHEN rc.REGIMEN_END_DT IS NULL
                    OR lm.LAST_MELP_DT > rc.REGIMEN_END_DT
                  THEN 1 ELSE 0 END)                     AS N_PAST_THE_REGIMEN,
         sum(CASE WHEN lm.LOT_BASE_END_REASON = 'DISCONTINUATION'
                   AND lm.LOT_BASE_DISCON_DT = lm.LAST_MELP_DT
                  THEN 1 ELSE 0 END)                     AS N_ENDING_ON_A_MELP_DOSE,
         percentile_approx(CASE WHEN rc.REGIMEN_END_DT IS NOT NULL
                                 AND lm.LAST_MELP_DT > rc.REGIMEN_END_DT
                                THEN datediff(lm.LAST_MELP_DT, rc.REGIMEN_END_DT) END, 0.5)
                                                         AS MEDIAN_DAYS_PAST_THE_REGIMEN
  FROM last_melp lm
  LEFT JOIN regimen_cover rc ON rc.PATID = lm.PATID AND rc.LOT_NUM = lm.LOT_NUM
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
     paste0("AFTER_THE_CAP='no' should be EMPTY - CART and SCT_ALLO rows ",
            "included, since melp_line_type_guard reaches those lines.\n   ",
            "AFTER_THE_CAP='yes' is treatment past the ", cfg$max_lot,
            "-line cap and no ownership rule can move it"))
show(hold,    "3. Lines whose last melphalan dose sits past their own regimen's cover",
     paste0("N_PAST_THE_REGIMEN is the group at risk, not the effect. ",
            "N_ENDING_ON_A_MELP_DOSE is the hold's signature -\n   ",
            "read the difference between the cells, not the number in one"))

rows <- do.call(rbind, lapply(
  list(list("branch-populations",  branch),
       list("doses-in-no-line",    unowned),
       list("past-the-regimen",    hold)),
  function(x) if (is.null(x[[2]])) NULL else
    data.frame(DECISION = x[[1]],
               MEASURE  = apply(x[[2]], 1, function(r)
                 paste(names(x[[2]]), r, sep = "=", collapse = "; ")),
               stringsAsFactors = FALSE)))
f <- file.path(out_dir, DECISION_CSV)
utils::write.csv(if (is.null(rows)) data.frame() else melp_stamp(rows, inputs, status),
                 f, row.names = FALSE)
cat("\n  -> ", f, "\n", sep = "")
