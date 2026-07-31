#!/usr/bin/env Rscript
# What build_nndm() does, driven rather than grepped for. The rules in R/steps
# are held to the source by test_same_as_source.R; this is about the runner
# around them - the guards, the attrition, and the order.
#
#   Rscript "Jul 28/nndm/tests/test_runner.R"

ROOT <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                                 fixed = TRUE))) else getwd()
  dirname(d)
})
source(file.path(ROOT, "tests", "testutil.R"))

env <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "build_nndm.R"), envir = env)
for (f in ls(env)) assign(f, get(f, envir = env), envir = globalenv())
sys.source(file.path(ROOT, "R", "config.R"), envir = globalenv())
sys.source(file.path(ROOT, "R", "db_utils.R"), envir = globalenv())
bl   <- paste(readLines(file.path(ROOT, "R", "build_nndm.R"), warn = FALSE), collapse = "\n")
body <- sub(".*build_nndm <- function\\([^)]*\\) \\{", "", bl)

SETTINGS <- c("STUDY_END", "LOT1_FROM", "STUDY_START", "PRE_LOT1_DAYS",
              "FU_CE_DAYS", "GAP_DAYS", "DOMINO_RUN_ID", "PROJECT_WORK_SCHEMA",
              "DOMINO_USER_NAME", "OBJECT_PREFIX")
clear <- function() for (v in SETTINGS) Sys.unsetenv(v)
clear()

cat("\n-- the runner calls its phases, in order --\n")
ORDER <- c("check_settings", "pin_output_schema", "pin_prefix", "check_contract",
           "set_lot_config", "check_upstream", "write_build_status",
           "build_enrollment_spans_ndmm", "build_lot1_starts_ndmm",
           "build_ndmm_mma_codelist", "build_ndmm_therapy_pre_lot1",
           "build_ndmm_other_malig_codes",
           "build_ndmm_med_claim_header_and_confinement",
           "build_ndmm_other_malig_pre_lot1", "build_ndmm_preg_codes",
           "build_ndmm_pregnancy_patids", "build_ndmm_flags",
           "build_lot_long_filtered", "ndmm_counts",
           "check_attrition_monotonic", "write_attrition")
at <- vapply(ORDER, function(f) {
  m <- regexpr(paste0("(?<![A-Za-z0-9_.])", f, "\\("), body, perl = TRUE)
  if (m == -1) NA_integer_ else as.integer(m)
}, integer(1))
absent <- names(at)[is.na(at)]
ok(length(absent) == 0,
   if (length(absent)) paste0("build_nndm() never calls: ", paste(absent, collapse = ", "))
   else paste0("build_nndm() calls all ", length(ORDER), " phases and checks"))
ok(!any(is.na(at)) && !is.unsorted(at[!is.na(at)]), "and calls them in that order")
# Upstream is checked before anything is built, or the first missing input
# surfaces as a failed join rather than as a named table.
ok(at[["check_upstream"]] < at[["build_enrollment_spans_ndmm"]],
   "every input is checked before the first phase runs")
# The funnel is checked before it is written, so a fan-out is not published.
ok(at[["check_attrition_monotonic"]] < at[["write_attrition"]],
   "and the attrition is checked before it is written")

cat("\n-- settings that would build a different cohort --\n")
for (bad in c("2025/06/30", "30-06-2025", "nonsense")) {
  Sys.setenv(LOT1_FROM = bad)
  ok(grepl("LOT1_FROM", tryCatch({ check_settings(); "" }, error = conditionMessage),
           fixed = TRUE),
     paste0("LOT1_FROM='", bad, "' is refused"))
  clear()
}
for (bad in c("365.5", "3e2", "-1")) {
  Sys.setenv(PRE_LOT1_DAYS = bad)
  ok(grepl("want a whole number",
           tryCatch({ check_settings(); "" }, error = conditionMessage), fixed = TRUE),
     paste0("PRE_LOT1_DAYS='", bad, "' is refused, not truncated"))
  clear()
}
Sys.setenv(DOMINO_RUN_ID = "R1'; DROP TABLE x; --")
ok(grepl("DOMINO_RUN_ID", tryCatch({ check_settings(); "" }, error = conditionMessage),
         fixed = TRUE),
   "a run id that would not survive being quoted is refused")
clear()
ok(identical(tryCatch({ check_settings(); "" }, error = conditionMessage), ""),
   "...and an unset environment is fine")

cat("\n-- the prefix, which is the only thing that names a cohort --\n")
base <- list(catalog = "hive_metastore", work_schema = "wk")
for (bad in list(NULL, "", "9study_", "study", "st udy_"))
  ok(inherits(tryCatch(pin_prefix(base, bad), error = function(e) e), "error"),
     paste0("prefix ", if (is.null(bad)) "NULL" else paste0("'", bad, "'"), " is refused"))
# No prefix at all is the likely mistake, so that message says how to give one
# rather than describing the shape of a prefix that was never typed.
ok(grepl("build.R", tryCatch({ pin_prefix(base, NULL); "" }, error = conditionMessage),
         fixed = TRUE),
   "and no prefix at all is answered with how to supply one")
ok(identical(pin_prefix(base, "study_a_")$object_prefix, "study_a_"),
   "a name ending in _ is accepted")
# Every table, read or written, carries it - that is what keeps two cohorts
# apart, and what lets the ported steps call wrk() unchanged.
assign("cfg", pin_prefix(base, "study_a_"), envir = globalenv())
ok(identical(wrk("LOT_LONG"), "hive_metastore.wk.study_a_LOT_LONG"),
   "wrk() prefixes an upstream table")
ok(identical(wrk("NDMM_COHORT"), "hive_metastore.wk.study_a_NDMM_COHORT"),
   "...and an output, so both belong to the same cohort")
assign("cfg", pin_prefix(base, "study_b_"), envir = globalenv())
ok(!identical(wrk("LOT_LONG"), "hive_metastore.wk.study_a_LOT_LONG"),
   "and a second cohort reads none of the first's tables")

cat("\n-- the contract --\n")
full <- modifyList(cfg_defaults, list(work_schema = "wk", object_prefix = "p_"))
ok(identical(tryCatch({ check_contract(full); "" }, error = conditionMessage), ""),
   "the shipped settings satisfy the contract")
for (k in c("lot1_from", "fu_ce_days", "pre_lot1_days", "gap_days", "study_end")) {
  drift <- full; drift[[k]] <- if (is.numeric(drift[[k]])) drift[[k]] + 1L else "1999-01-01"
  ok(grepl(k, tryCatch({ check_contract(drift); "" }, error = conditionMessage), fixed = TRUE),
     paste0(k, " drifting from the contract stops the build, named"))
}

cat("\n-- every input is present, or the run says which is not --\n")
ue <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "build_nndm.R"), envir = ue)
assign("log_msg", function(...) invisible(NULL), envir = ue)
assign("wrk", function(x) paste0("wk.p_", x), envir = ue)
assign("cdm_src", function(x) paste0("cdm.t_", x), envir = ue)
UCFG <- list(tbl_medical = "medical", tbl_rx = "rx", tbl_med_diag = "med_diagnosis",
             tbl_med_proc = "med_procedure", tbl_confinement = "confinement")
drive_up <- function(unreadable = character(0)) {
  assign("db_q", function(con, sql) {
    for (u in unreadable) if (grepl(u, sql, fixed = TRUE)) stop("cannot read")
    data.frame(x = 1L)
  }, envir = ue)
  tryCatch({ ue$check_upstream(NULL, UCFG); NULL }, error = conditionMessage)
}
ok(is.null(drive_up()), "all eight inputs readable lets the run start")
msg <- drive_up("wk.p_LOT_LONG")
ok(!is.null(msg) && grepl("wk.p_LOT_LONG", msg, fixed = TRUE) &&
     grepl("Jul 28/lot", msg, fixed = TRUE),
   "a missing built table is named, with the build that makes it")
msg <- drive_up("wk.p_ELIG_COH_FINAL")
ok(!is.null(msg) && grepl("Jul 28/overall", msg, fixed = TRUE),
   "...and ELIG_COH_FINAL points at the cohort build, not the LOT build")
msg <- drive_up("cdm.t_confinement")
ok(!is.null(msg) && grepl("confinement", msg, fixed = TRUE),
   "a missing raw CDM table stops it too - the other-cancer rule needs it")
msg <- drive_up(c("wk.p_MAP_STACKED", "cdm.t_rx"))
ok(!is.null(msg) && grepl("MAP_STACKED", msg, fixed = TRUE) &&
     grepl("rx", msg, fixed = TRUE),
   "and two missing inputs are both reported, not just the first")

cat("\n-- the attrition steps match what the counts return --\n")
# The labels are read off ATTRITION_STEPS but the numbers come from
# ndmm_counts(), so a key that does not exist there yields NULL and a row with
# no count. Driven against the real function rather than compared by eye.
ce <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "nndm_constants.R"), envir = ce)
sys.source(file.path(ROOT, "R", "steps", "07_cohort.R"), envir = ce)
assign("log_msg", function(...) invisible(NULL), envir = ce)
assign("wrk", function(x) paste0("wk.", x), envir = ce)
assign("run_step", function(...) invisible(TRUE), envir = ce)
assign("db_exec", function(...) invisible(TRUE), envir = ce)
n_seen <- 0L
assign("db_q", function(con, sql) { n_seen <<- n_seen + 1L; data.frame(n = 100L - n_seen) },
       envir = ce)
got <- ce$ndmm_counts(NULL, "LL", "EC")
keys <- vapply(ATTRITION_STEPS, function(s) s$key, character(1))
ok(all(keys %in% names(got)),
   paste0("every attrition step names a count the build produces (",
          length(keys), ")"))
ok(setequal(keys, names(got)),
   "and every count produced appears in the attrition, none dropped")
ok(length(keys) == 9L, paste0("nine steps, one per criterion (", length(keys), ")"))

cat("\n-- a funnel that grows is not a count --\n")
mk <- function(v) setNames(as.list(v), keys)
ok(is.null(tryCatch({ check_attrition_monotonic(mk(c(100,90,80,70,60,50,40,30,20))); NULL },
                    error = conditionMessage)),
   "a funnel that only narrows passes")
msg <- tryCatch({ check_attrition_monotonic(mk(c(100,90,80,70,60,50,40,45,20))); "" },
                error = conditionMessage)
ok(grepl("grows at step 8", msg, fixed = TRUE) && grepl("follow-up CE", msg, fixed = TRUE),
   "a step larger than the one above it stops the build, naming the step")
msg <- tryCatch({ check_attrition_monotonic(mk(c(100,90,80,70,60,50,40,30,0))); "" },
                error = conditionMessage)
ok(grepl("empty", msg, fixed = TRUE),
   "and an empty final cohort is reported rather than published")
ok(!is.null(tryCatch({ check_attrition_monotonic(mk(c(0,0,0,0,0,0,0,0,0))); NULL },
                     error = conditionMessage)),
   "a funnel that starts empty stops too, rather than reading as flat")

cat("\n-- the attrition reaches the warehouse --\n")
ae <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "build_nndm.R"), envir = ae)
assign("log_msg", function(...) invisible(NULL), envir = ae)
assign("wrk", function(x) paste0("wk.p_", x), envir = ae)
assign("run_id", "R1", envir = ae)
ASQL <- character(0); AUNITS <- list()
akeep <- function(g) { ASQL <<- c(ASQL, g); AUNITS[[length(AUNITS) + 1L]] <<- g; TRUE }
assign("db_exec", function(con, s) akeep(s), envir = ae)
assign("db_replace", function(con, ...) akeep(c(...)), envir = ae)
ASQL <- character(0); AUNITS <- list()
ae$write_attrition(NULL, list(), mk(c(1000,900,800,700,600,500,400,300,250)))
ins <- grep("INSERT", ASQL, value = TRUE)[1]
ok(!is.na(ins) && length(gregexpr("('R1',", ins, fixed = TRUE)[[1]]) == 9L,
   "nine rows, one per step")
ok(grepl("'Patients in LOT_LONG'", ins, fixed = TRUE) &&
     grepl("no pregnancy in study period", ins, fixed = TRUE),
   "labelled by criterion, so the table reads without the code")
ok(grepl(", 250,", ins, fixed = TRUE) && grepl(", 25,", ins, fixed = TRUE),
   "with the count and its percentage of the starting population")
# A DELETE and an INSERT retried apart would double the rows.
ok(any(vapply(AUNITS, function(g) any(grepl("DELETE", g, fixed = TRUE)) &&
                any(grepl("INSERT", g, fixed = TRUE)), logical(1))),
   "cleared and rewritten as one retried unit")
# A count of exactly 100000 renders as 1e+05 through as.character.
ASQL <- character(0); AUNITS <- list()
ae$write_attrition(NULL, list(), mk(c(1e6,1e5,1e5,1e5,1e5,1e5,1e5,1e5,1e5)))
ins <- grep("INSERT", ASQL, value = TRUE)[1]
ok(!grepl("e+0", ins, fixed = TRUE) && grepl("1000000", ins, fixed = TRUE),
   "counts reach SQL as digits, not as R prints them")

cat("\n-- a run says whether its outputs belong together --\n")
ASQL <- character(0); AUNITS <- list()
ae$write_build_status(NULL, list(object_prefix = "p_"), "started")
ok(any(grepl("'started'", ASQL, fixed = TRUE)) &&
     any(grepl("N_NDMM", ASQL, fixed = TRUE)),
   "a status row is written when the run starts")
ASQL <- character(0); AUNITS <- list()
ae$write_build_status(NULL, list(object_prefix = "p_"), "complete", 1234)
ok(any(grepl(", 1234,", ASQL, fixed = TRUE)),
   "...and the completed row carries the cohort size")
ASQL <- character(0); AUNITS <- list()
ae$write_build_status(NULL, list(object_prefix = "p_"), "failed")
ok(any(grepl("NULL", ASQL, fixed = TRUE)),
   "a failed run records no size rather than a zero it did not measure")
# R fires on.exit handlers in registration order and the disconnect is
# registered first, so without after = FALSE the status write reaches a closed
# connection and its own try() swallows the failure.
i_dis <- regexpr("on.exit(try(DBI::dbDisconnect", bl, fixed = TRUE)
i_st  <- regexpr("nndm_complete", bl, fixed = TRUE)
ok(i_dis > 0 && i_st > i_dis && grepl("add = TRUE, after = FALSE", bl, fixed = TRUE),
   "the failed status is written before the connection closes")

cat("\n-- a retried write does not double the rows --\n")
# write_attrition and write_build_status both clear and rewrite their run's
# rows. db_replace is what makes that one retried unit; the two calls above ran
# against a stub, so drive the real one here. Retried apart, an INSERT whose
# acknowledgement was lost is sent again and the DELETE that would have cleared
# the first has already run - nine attrition rows become eighteen.
assign("cfg", modifyList(cfg_defaults, list(max_retries = 4, base_sleep = 0)),
       envir = globalenv())
log_msg <- function(...) invisible(NULL)
SENT <- character(0); n_ins <- 0L
db_exec_once <- function(con, sql) {
  SENT <<- c(SENT, sql)
  if (grepl("INSERT", sql, fixed = TRUE)) {
    n_ins <<- n_ins + 1L
    if (n_ins == 1L) stop("connection reset by peer")
  }
  invisible(TRUE)
}
db_replace(NULL, "DELETE FROM t WHERE RUN_ID = 'R1'", "INSERT INTO t VALUES (1)")
ok(sum(grepl("INSERT", SENT, fixed = TRUE)) == 2L,
   "a lost INSERT is sent again")
ok(sum(grepl("DELETE", SENT, fixed = TRUE)) == 2L,
   "...and its DELETE goes with it, so the second attempt starts from empty")
ok(identical(SENT[3], "DELETE FROM t WHERE RUN_ID = 'R1'"),
   "the retry replays the pair in order, DELETE before INSERT")

cat("\n-- the outputs are all prefixed, and all declared --\n")
assign("cfg", pin_prefix(base, "p_"), envir = globalenv())
for (t in OUTPUTS)
  ok(grepl(paste0(".p_", t), wrk(t), fixed = TRUE),
     paste0(t, " is written under the cohort prefix"))
# Every table this package names, across the runner and the ported steps, and
# whether it was written as a literal or through a constant. A step that starts
# writing a table nobody declared is the failure this is here for: OUTPUTS is
# what tells the next build which tables belong to this cohort.
consts <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "nndm_constants.R"), envir = consts)
srcs <- c(file.path(ROOT, "R", "build_nndm.R"),
          list.files(file.path(ROOT, "R", "steps"), "\\.R$", full.names = TRUE))
args <- unique(unlist(lapply(srcs, function(f) {
  s <- paste(readLines(f, warn = FALSE), collapse = "\n")
  unlist(regmatches(s, gregexpr("(?<=wrk\\()[^)]+(?=\\))", s, perl = TRUE)))
})))
named <- unique(unlist(lapply(args, function(a) {
  a <- trimws(a)
  if (grepl("^['\"].*['\"]$", a)) gsub("^['\"]|['\"]$", "", a)
  else if (exists(a, envir = consts, inherits = FALSE)) get(a, envir = consts)
  else NULL                       # wrk(t), the loop variable in check_upstream
})))
ok(length(named) >= length(OUTPUTS),
   paste0("the scan finds every named table, not a subset (", length(named), ")"))
undeclared <- setdiff(named, c(OUTPUTS, names(UPSTREAM)))
ok(length(undeclared) == 0,
   if (length(undeclared)) paste0("tables written but not declared: ",
                                  paste(undeclared, collapse = ", "))
   else "every table named is declared as an output or as an upstream input")
clear()
report()
