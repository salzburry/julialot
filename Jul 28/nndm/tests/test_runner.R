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
sys.source(file.path(ROOT, "R", "codelists.R"), envir = globalenv())
# The NDMM_* constants are what the SQL reads, and check_constants() compares
# them against cfg. Loaded here the same way load_nndm_modules() loads them.
sys.source(file.path(ROOT, "R", "nndm_constants.R"), envir = globalenv())
bl   <- paste(readLines(file.path(ROOT, "R", "build_nndm.R"), warn = FALSE), collapse = "\n")
body <- sub(".*build_nndm <- function\\([^)]*\\) \\{", "", bl)

SETTINGS <- c("STUDY_END", "LOT1_FROM", "STUDY_START", "PRE_LOT1_DAYS",
              "FU_CE_DAYS", "GAP_DAYS", "DOMINO_RUN_ID", "PROJECT_WORK_SCHEMA",
              "DOMINO_USER_NAME", "OBJECT_PREFIX")
clear <- function() for (v in SETTINGS) Sys.unsetenv(v)
clear()

cat("\n-- the runner calls its phases, in order --\n")
ORDER <- c("check_settings", "pin_output_schema", "pin_prefix", "check_contract",
           "check_constants", "set_lot_config", "check_upstream", "write_build_status",
           "build_enrollment_spans_ndmm", "build_lot1_starts_ndmm",
           "build_ndmm_mma_codelist", "build_ndmm_therapy_pre_lot1",
           "build_ndmm_other_malig_codes",
           "build_ndmm_med_claim_header_and_confinement",
           "build_ndmm_other_malig_pre_lot1", "build_ndmm_preg_codes",
           "build_ndmm_pregnancy_patids", "build_ndmm_flags",
           "build_lot_long_filtered", "ndmm_counts",
           "check_attrition_monotonic", "write_attrition",
           "write_codelist_metadata")
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
             tbl_med_proc = "med_procedure", tbl_confinement = "confinement",
             tbl_member_enroll = "member_enrollment",
             cohort_table = "OVERALL_COH_FINAL")
drive_up <- function(unreadable = character(0)) {
  assign("db_q", function(con, sql) {
    for (u in unreadable) if (grepl(u, sql, fixed = TRUE)) stop("cannot read")
    data.frame(x = 1L)
  }, envir = ue)
  tryCatch({ ue$check_upstream(NULL, UCFG); NULL }, error = conditionMessage)
}
ok(is.null(drive_up()), "all nine inputs readable lets the run start")
msg <- drive_up("wk.p_LOT_LONG")
ok(!is.null(msg) && grepl("wk.p_LOT_LONG", msg, fixed = TRUE) &&
     grepl("Jul 28/lot", msg, fixed = TRUE),
   "a missing built table is named, with the build that makes it")
msg <- drive_up("wk.p_OVERALL_COH_FINAL")
ok(!is.null(msg) && grepl("Jul 28/overall", msg, fixed = TRUE),
   "...and the cohort table points at the cohort build, not the LOT build")
msg <- drive_up("cdm.t_member_enrollment")
ok(!is.null(msg) && grepl("member_enrollment", msg, fixed = TRUE),
   "member_enrollment too - the first table the run reads")
msg <- drive_up("cdm.t_confinement")
ok(!is.null(msg) && grepl("confinement", msg, fixed = TRUE),
   "a missing raw CDM table stops it too - the other-cancer rule needs it")
msg <- drive_up(c("wk.p_MAP_STACKED", "cdm.t_rx"))
ok(!is.null(msg) && grepl("MAP_STACKED", msg, fixed = TRUE) &&
     grepl("rx", msg, fixed = TRUE),
   "and two missing inputs are both reported, not just the first")

cat("\n-- the preflight covers every table a step actually reads --\n")
# The list of raw tables was hand-maintained and had drifted: member_enrollment
# feeds both enrollment-span builds, was not in it, and so the preflight passed
# and the run died in phase one. Read the tables out of the steps instead of
# trusting the list.
consts0 <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "nndm_constants.R"), envir = consts0)
step_files <- list.files(file.path(ROOT, "R", "steps"), "\\.R$", full.names = TRUE)
read_raw <- unique(unlist(lapply(step_files, function(f) {
  s <- paste(readLines(f, warn = FALSE), collapse = "\n")
  a <- unlist(regmatches(s, gregexpr("(?<=cdm_src\\()[^)]+(?=\\))", s, perl = TRUE)))
  unlist(lapply(trimws(a), function(x) {
    if (grepl("^['\"].*['\"]$", x)) gsub("^['\"]|['\"]$", "", x)
    else if (grepl("^cfg\\$", x)) cfg_defaults[[sub("^cfg\\$", "", x)]]
    else if (exists(x, envir = consts0, inherits = FALSE)) get(x, envir = consts0)
    else NULL
  }))
})))
declared <- raw_tables(cfg_defaults)
ok(length(read_raw) > 0, paste0("the steps name ", length(read_raw), " raw CDM tables"))
undeclared <- setdiff(read_raw, declared)
ok(length(undeclared) == 0,
   if (length(undeclared)) paste0("read by a step but never preflighted: ",
                                  paste(undeclared, collapse = ", "))
   else "and check_upstream() checks every one of them before phase one")
ok("member_enrollment" %in% declared,
   "member_enrollment among them - the first table the run touches")

cat("\n-- the settings the SQL uses, not the ones cfg holds --\n")
# check_contract() reads cfg. The queries read the NDMM_* constants, which have
# their own environment variables - NDMM_LOT1_FROM is not LOT1_FROM. Setting it
# moved the 1L cutoff with the contract still passing.
ce0 <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "build_nndm.R"), envir = ce0)
base_cfg <- modifyList(cfg_defaults, list(work_schema = "wk", object_prefix = "p_"))
ok(identical(tryCatch({ check_constants(base_cfg); "" }, error = conditionMessage), ""),
   "the shipped constants match the contract they are checked against")
for (s in CONSTANT_SETTINGS) {
  keep <- get(s$const, envir = globalenv())
  assign(s$const, if (is.numeric(keep)) keep + 1L else "1999-01-01",
         envir = globalenv())
  m <- tryCatch({ check_constants(base_cfg); "" }, error = conditionMessage)
  assign(s$const, keep, envir = globalenv())
  ok(grepl(s$const, m, fixed = TRUE),
     paste0(s$const, " drifting from ", s$cfg, " stops the build, named"))
}

# And the list has to be complete. Every constant nndm_constants.R reads from
# the environment is a knob someone can turn without touching config.csv, so
# each one must be pinned - derived from the file rather than listed by hand,
# because listing by hand is how NDMM_LOT1_FROM went unnoticed.
kl <- readLines(file.path(ROOT, "R", "nndm_constants.R"), warn = FALSE)
env_consts <- unique(sub("^\\s*([A-Za-z_.][A-Za-z0-9_.]*)\\s*<-.*", "\\1",
                         grep("^\\s*[A-Za-z_.][A-Za-z0-9_.]*\\s*<-.*Sys\\.getenv",
                              kl, value = TRUE)))
# Only the ones a step reads: a constant nothing uses cannot move the cohort.
steps_txt <- paste(unlist(lapply(step_files, readLines, warn = FALSE)), collapse = "\n")
env_consts <- env_consts[vapply(env_consts, function(k)
  grepl(paste0("(?<![A-Za-z0-9_.])", k, "(?![A-Za-z0-9_.])"), steps_txt, perl = TRUE),
  logical(1))]
pinned <- vapply(CONSTANT_SETTINGS, function(s) s$const, character(1))
unpinned <- setdiff(env_consts, pinned)
ok(length(env_consts) > 0,
   paste0("nndm_constants.R takes ", length(env_consts), " values from the environment"))
ok(length(unpinned) == 0,
   if (length(unpinned)) paste0("settable from the environment but never checked: ",
                                paste(unpinned, collapse = ", "))
   else "and every one of them is checked against the contract")
ok("NDMM_LOT1_FROM" %in% pinned,
   "NDMM_LOT1_FROM among them - its variable is not LOT1_FROM")

cat("\n-- the codelist allowlist, executed rather than described --\n")
# CODELIST_FILES named two files while the steps asked for three, so every
# production run died inside build_ndmm_other_malig_codes(). Nothing executed
# that path. Read the requested names out of the steps, and drive the real
# loader for each.
asked <- unique(unlist(lapply(step_files, function(f) {
  s <- paste(readLines(f, warn = FALSE), collapse = "\n")
  m <- unlist(regmatches(s, gregexpr('load_codelist_csv\\(\\s*"[^"]+"', s, perl = TRUE)))
  sub('.*"([^"]+)"', "\\1", m)
})))
ok(length(asked) > 0, paste0("the steps load ", length(asked), " code lists"))
notallowed <- setdiff(asked, CODELIST_FILES)
ok(length(notallowed) == 0,
   if (length(notallowed)) paste0("requested but not in CODELIST_FILES: ",
                                  paste(notallowed, collapse = ", "))
   else "and every one of them is a file this build is defined on")
tmp <- file.path(tempdir(), paste0("cl", as.integer(Sys.time())))
dir.create(tmp, showWarnings = FALSE, recursive = TRUE)
assign("cfg", modifyList(cfg_defaults, list(codelist_dir = tmp)), envir = globalenv())
options(nndm_codelist_md5 = list())
writeLines(c("dx,icd_family,tumor_group", "C349,ICD10,LUNG"),
           file.path(tmp, "other_malig.csv"))
got <- tryCatch(load_codelist_csv("other_malig.csv", c("dx", "icd_family", "tumor_group")),
                error = conditionMessage)
ok(is.character(got) && grepl("VALUES", got, fixed = TRUE),
   "the other-cancer codelist loads - the allowlist no longer rejects it")
ok(grepl("'C349'", got, fixed = TRUE), "...with its rows in the SQL fragment")
writeLines("x,y", file.path(tmp, "not_a_codelist.csv"))
m <- tryCatch({ load_codelist_csv("not_a_codelist.csv", c("x", "y")); "" },
              error = conditionMessage)
ok(grepl("not one of the files", m, fixed = TRUE),
   "and a file nobody declared is still refused, present or not")

cat("\n-- which code lists built the cohort --\n")
# The hashes were collected into an option and dropped. A cohort that cannot be
# traced to the files that built it is not reproducible.
me <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "build_nndm.R"), envir = me)
assign("log_msg", function(...) invisible(NULL), envir = me)
assign("wrk", function(x) paste0("wk.p_", x), envir = me)
assign("run_id", "R1", envir = me)
MSQL <- character(0)
assign("db_exec", function(con, s) { MSQL <<- c(MSQL, s); TRUE }, envir = me)
assign("db_replace", function(con, ...) { MSQL <<- c(MSQL, c(...)); TRUE }, envir = me)
m <- tryCatch({ me$write_codelist_metadata(NULL, list()); "" }, error = conditionMessage)
ins <- grep("INSERT", MSQL, value = TRUE)[1]
ok(!is.na(ins) && grepl("'other_malig.csv'", ins, fixed = TRUE),
   "every codelist read is written out by name")
ok(!is.na(ins) && grepl(unname(tools::md5sum(file.path(tmp, "other_malig.csv"))),
                        ins, fixed = TRUE),
   "...with the md5 of the file that was actually read")
options(nndm_codelist_md5 = list())
MSQL <- character(0)
m <- tryCatch({ me$write_codelist_metadata(NULL, list()); "" }, error = conditionMessage)
ok(grepl("cannot be traced", m, fixed = TRUE),
   "and a run that recorded no hashes stops rather than publishing untraceable counts")
unlink(tmp, recursive = TRUE)

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
n_seen <- 0L; CSQL <- character(0)
assign("db_q", function(con, sql) {
  n_seen <<- n_seen + 1L; CSQL <<- c(CSQL, sql); data.frame(n = 100L - n_seen)
}, envir = ce)
got <- ce$ndmm_counts(NULL, "LL", "EC")
keys <- vapply(ATTRITION_STEPS, function(s) s$key, character(1))
ok(all(keys %in% names(got)),
   paste0("every attrition step names a count the build produces (",
          length(keys), ")"))
ok(setequal(keys, names(got)),
   "and every count produced appears in the attrition, none dropped")
ok(identical(keys, names(got)),
   "in the same order, so the labels sit against the counts they describe")
ok(length(keys) == 9L, paste0("nine steps, one per criterion (", length(keys), ")"))

cat("\n-- the funnel adds the criteria in the protocol's order --\n")
# ndmm_counts() is the one block this package rewrote rather than ported, so
# test_same_as_source.R swaps the source's version back in and holds nothing
# here. What holds it is this: each step's SQL is read back and must be the
# step above it plus exactly one flag, in the order Rev Round 2 S6.2.1.1 and
# then S6.2.1.2 list the criteria.
FLAGS <- c("CE_pre_lot1_12mo", "CE_lot1_fu", "NO_PRIOR_MM_TX",
           "NO_OTHER_CANCER_PRE_LOT1", "NO_PREGNANCY", "NO_BELANTAMAB")
flags_in <- function(s) FLAGS[vapply(FLAGS, grepl, logical(1), x = s, fixed = TRUE)]
sets <- lapply(CSQL, flags_in)
ok(length(CSQL) == 9L, paste0("one query per attrition row (", length(CSQL), ")"))
grew <- vapply(5:8, function(i)
  all(sets[[i - 1]] %in% sets[[i]]) && length(setdiff(sets[[i]], sets[[i - 1]])) == 1L,
  logical(1))
ok(all(grew),
   "each step is the step above it plus exactly one criterion, never a new set")
added <- c(sets[[4]], vapply(5:8, function(i) setdiff(sets[[i]], sets[[i - 1]]),
                             character(1)))
want <- c("CE_pre_lot1_12mo", "CE_lot1_fu", "NO_PRIOR_MM_TX",
          "NO_OTHER_CANCER_PRE_LOT1", "NO_PREGNANCY")
ok(identical(added, want),
   if (identical(added, want)) "and they arrive in protocol order, pregnancy eighth"
   else paste0("the criteria arrive as ", paste(added, collapse = " -> ")))
# Belantamab is the last exclusion S6.2.1.2 lists, so it must not narrow any
# earlier row - it enters only through NDMM_PATIDS, which the final step reads.
ok(!any(vapply(sets[1:8], function(s) "NO_BELANTAMAB" %in% s, logical(1))),
   "belantamab narrows no step before the last")
ok(grepl(ce$NDMM_PATIDS, CSQL[9], fixed = TRUE),
   "and the last step reads the cohort view rather than repeating the conjunction")
fl <- paste(readLines(file.path(ROOT, "R", "steps", "06_flags.R"), warn = FALSE),
            collapse = "\n")
patids <- sub(".*TEMPORARY VIEW \\{NDMM_PATIDS\\} AS", "", fl)
ok(all(vapply(FLAGS, grepl, logical(1), x = patids, fixed = TRUE)),
   paste0("which applies all ", length(FLAGS),
          " flags, so the last row really is the one above it plus belantamab"))

cat("\n-- a funnel that grows is not a count --\n")
mk <- function(v) setNames(as.list(v), keys)
ok(is.null(tryCatch({ check_attrition_monotonic(mk(c(100,90,80,70,60,50,40,30,20))); NULL },
                    error = conditionMessage)),
   "a funnel that only narrows passes")
msg <- tryCatch({ check_attrition_monotonic(mk(c(100,90,80,70,60,50,40,45,20))); "" },
                error = conditionMessage)
ok(grepl("grows at step 8", msg, fixed = TRUE) &&
     grepl(ATTRITION_STEPS[[8]]$label, msg, fixed = TRUE),
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
undeclared <- setdiff(named, c(OUTPUTS, names(upstream_tables(cfg_defaults))))
ok(length(undeclared) == 0,
   if (length(undeclared)) paste0("tables written but not declared: ",
                                  paste(undeclared, collapse = ", "))
   else "every table named is declared as an output or as an upstream input")
clear()
report()
