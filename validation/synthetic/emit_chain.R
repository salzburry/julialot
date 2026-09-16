#!/usr/bin/env Rscript
# Emit every statement the LOT build issues, in order, for a fixed med universe.
#
#   Rscript validation/synthetic/emit_chain.R <out_dir>
#
# The point is that nothing here is retyped. run_step/materialize/db_exec are
# stubbed to capture what the engine actually produces, so the SQL that gets
# tested is the SQL that ships. Change a step file and the emitted text changes
# with it - a test written against a copy could not say that.
#
# Three settings are read from the environment so a run can be differenced
# against itself: CONFIRM_DAYS (lot_discon_confirm_days), CART_RULE
# (apply_cart_induction_rule) and MELP_RULE (apply_melp_rule). Everything else
# is the contract.
#
# MELP_RULE, MAP_FOLDIN and OWN_RETURN_FOLD read their DEFAULTS out of the engine's own
# config.csv rather than written here. The rest of this cfg is a hand copy of CONTRACT, which is
# tolerable for settings that rarely move; the melphalan mode is not, because
# it decides whether a whole rule is in the emitted SQL. Copied by hand, this
# harness would go on certifying the algorithm the study used to ship while
# reporting green.
#
# Not part of the merge gate. See README.md in this directory.

args <- commandArgs(trailingOnly = TRUE)
OUT  <- if (length(args) >= 1) args[1] else tempdir()
dir.create(OUT, showWarnings = FALSE, recursive = TRUE)

HERE <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (!length(a)) getwd()
  else dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]), fixed = TRUE)))
})
REPO   <- dirname(dirname(HERE))
source(file.path(HERE, "study_folder.R"))

STUDY  <- study_folder_with(REPO, c("lot", "engine", "R"))
ENGINE <- file.path(REPO, STUDY, "lot", "engine", "R")
NDMM   <- file.path(REPO, STUDY, "ndmm", "R")
`%||%` <- function(a, b) if (is.null(a)) b else a
if (!nzchar(STUDY)) study_folder_quit("engine", STUDY)

library(glue)

# The engine's shipped default for one setting, read from its config.csv.
engine_default <- function(name, fallback = "") {
  f <- file.path(dirname(ENGINE), "config.csv")
  if (!file.exists(f)) return(fallback)
  d <- utils::read.csv(f, stringsAsFactors = FALSE)
  i <- match(name, trimws(as.character(d$name)))
  if (is.na(i)) return(fallback)
  v <- trimws(as.character(d$value[i]))
  if (is.na(v) || !nzchar(v)) fallback else v
}

# MELP is in the universe so MELP_RULE has something to act on. It is not drawn
# into random histories - run_synthetic.py plants the melphalan patients instead
# - because a conditioning dose is a specific shape, not a drug taken at random.
MEDS    <- c("LEN", "BORT", "DARA", "POMA", "CYCLO", "CARF", "MELP")
CLASSES <- c("IMID", "PI", "MAB", "ALKY")

# The universe the chain is emitted for. The seven above are what the drawn
# and planted patients use, and they stay the default so every existing run
# emits the same text as before.
#
# A replay of REAL patients needs the real universe instead: the emitted SQL
# carries one LOT1_MED_<x> / LOT1_CLASS_<x> column per member, so a drug
# missing from the list is a drug the emitted build cannot flag - it would
# answer a different question from the one the warehouse answered.
env_list <- function(nm, dflt) {
  raw <- trimws(Sys.getenv(nm, unset = ""))
  if (!nzchar(raw)) return(dflt)
  v <- unique(trimws(strsplit(raw, ",", fixed = TRUE)[[1]]))
  v <- v[nzchar(v)]
  if (!length(v)) stop(nm, " was set but names no medication.", call. = FALSE)
  bad <- v[!grepl("^[A-Za-z][A-Za-z0-9_]*$", v)]
  if (length(bad))
    stop(nm, " carries ", paste(bad, collapse = ", "), ". Each becomes a column ",
         "name in the emitted SQL, so it has to be a bare name.", call. = FALSE)
  v
}
MEDS    <- env_list("LOT_MEDS", MEDS)
CLASSES <- env_list("LOT_CLASSES", CLASSES)

e <- new.env(parent = globalenv())
SQL <- character(0)
assign("%||%", function(a, b) if (is.null(a)) b else a, e)
assign("cfg", list(
  lot_discon_confirm_days = as.integer(Sys.getenv("CONFIRM_DAYS", unset = "90")),
  medical_day_supply = 28L, map_discon_gap_days = 90L,
  induction_window_days = 60L, lot_n_induction_window_days = 30L,
  cart_consolidation_days = 45L, sct_auto_window_days = 13L,
  sct_auto_gap_days = 60L, sct_tandem_days = 180L, max_lot = 5L,
  apply_cart_induction_rule =
    as.logical(Sys.getenv("CART_RULE", unset = "TRUE")),
  apply_melp_rule = Sys.getenv("MELP_RULE",
                               unset = engine_default("APPLY_MELP_RULE")),
  melp_med_abbr = "MELP",
  apply_map_foldin = toupper(Sys.getenv(
    "MAP_FOLDIN", unset = engine_default("APPLY_MAP_FOLDIN", "FALSE"))) == "TRUE",
  # The returning-drug rule, LOT_RULES.md 4.3. Default read from the engine's
  # own config.csv, like the two above, so the harness compares what ships.
  apply_own_return_fold = toupper(Sys.getenv(
    "OWN_RETURN_FOLD",
    unset = engine_default("APPLY_OWN_RETURN_FOLD", "FALSE"))) == "TRUE",
  melp_exposure_days = 30L,
  melp_simple_course_days =
    as.integer(engine_default("MELP_SIMPLE_COURSE_DAYS", "28")),
  study_end = "2026-03-31"), e)

assign("materialize", function(con, step, view, name, body, qc = NULL) {
  SQL <<- c(SQL, paste0("CREATE OR REPLACE TABLE T_", name, " AS ", body),
                 paste0("CREATE OR REPLACE TEMPORARY VIEW ", view,
                        " AS SELECT * FROM T_", name))
  invisible(paste0("T_", name)) }, e)
# retry_as_unit is the engine's "these statements retry together" marker.
# Collected the same way either way: the harness replays them in order.
assign("run_step", function(con, name, sql, qc = NULL, retry_as_unit = FALSE)
  { SQL <<- c(SQL, sql); TRUE }, e)
assign("db_exec", function(con, sql) { SQL <<- c(SQL, sql); invisible(NULL) }, e)
assign("lot_out", function(n) paste0("T_", n), e)
assign("log_msg", function(...) invisible(NULL), e)
assign("sanitize_col", function(x) gsub("[^A-Za-z0-9]+", "_", toupper(x)), e)
# build_lot2_5 asks the connection two things: the med/class universe, and
# whether the previous line produced rows. Emitting is not running, and the
# statement TEXT for LOT_N does not depend on that count - so a nonzero answer
# just means all five lines are emitted, and the ones no patient reaches come
# out empty at run time.
assign("db_q", function(con, sql) {
  if (grepl("CL_MED_ABBR", sql))  return(data.frame(MED_ABBR = MEDS, stringsAsFactors = FALSE))
  if (grepl("CL_MED_CLASS", sql)) return(data.frame(MED_CLASS = CLASSES, stringsAsFactors = FALSE))
  data.frame(n = 1L)
}, e)

sys.source(file.path(ENGINE, "melp_rule.R"), e)
if (file.exists(file.path(ENGINE, "foldin_rule.R")))
  sys.source(file.path(ENGINE, "foldin_rule.R"), e)
sys.source(file.path(ENGINE, "cart_rule.R"), e)
if (file.exists(file.path(ENGINE, "prior_regimen.R")))
  sys.source(file.path(ENGINE, "prior_regimen.R"), e)
if (file.exists(file.path(ENGINE, "continuing_meds.R")))
  sys.source(file.path(ENGINE, "continuing_meds.R"), e)
for (f in c("04_lot1_base.R", "05b_lot1_sct.R", "06_lot1_end.R", "10_lot2_5_base.R"))
  sys.source(file.path(ENGINE, "steps", f), e)

flag_exprs <- function(vals, col, prefix)
  paste(sprintf("max(case when im.%s = '%s' then 1 else 0 end) as LOT1_%s_%s",
                col, vals, prefix, vals), collapse = ",\n      ")
ctx <- list(meds = MEDS, classes = CLASSES, sanitize_col = e$sanitize_col,
            med_flag_exprs   = flag_exprs(MEDS, "MED_ABBR", "MED"),
            class_flag_exprs = flag_exprs(CLASSES, "MED_CLASS", "CLASS"))

# A step's QC read is a bare expression in its caller, so the stubbed db_q's
# return value autoprints. Nothing here wants that output; only the last line
# of this script is meant for the caller.
sink(tempfile())
invisible(e$phase_lot1_base(NULL, ctx))
invisible(e$phase_lot1_sct(NULL, ctx))
invisible(e$phase_lot1_end(NULL, ctx))
invisible(e$build_lot2_5(NULL, induction_window_days = 30L, cart_consolidation_days = 45L,
               sct_tandem_days = 180L, allo_lot_span = "single_day", max_lot = 5L,
               apply_cart_induction_rule = e$cfg$apply_cart_induction_rule,
               lot1_induction_window_days = 60L))
sink()
writeLines(paste(SQL, collapse = "\n;;;\n"), file.path(OUT, "full_chain.sql"))

# The 2L/3L cohorts, off the lines the chain above builds. Only when the study
# folder carries the cohort build: a folder that ships the engine alone still
# has a full LOT chain to emit, and dying here threw that away too.
sub_src <- file.path(NDMM, "build_subsequent.R")
n_sub <- 0L
if (file.exists(sub_src)) {
s <- new.env(parent = globalenv())
assign("sql_text", function(x) if (is.na(x)) "NULL" else paste0("'", x, "'"), s)
sys.source(sub_src, s)
for (n in c(2L, 3L))
  writeLines(s$subseq_cohort_sql(n, if (n == 2L) "coh_1l" else "coh_2l",
                                 paste0("coh_", n, "l"),
                                 pre_days = 365L, fu_days = 90L,
                                 lines_tbl = "lot_long_final",
                                 spans_tbl = "spans", spans_strict_tbl = "spans_strict",
                                 run_id = "R1", lot_run = "L1", coh_run = "C1",
                                 coh_stamp = "S1", lot_stamp = "T1", attempt = "A1"),
             file.path(OUT, paste0("sub_", n, "l.sql")))
n_sub <- 2L
}

cat("emitted ", length(SQL), " LOT statements + ", n_sub, " cohort statements",
    " from '", STUDY, "' to ", OUT, "\n", sep = "")
