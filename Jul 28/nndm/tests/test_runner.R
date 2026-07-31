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

# config.csv the way the build applies it, so the constants and cfg_defaults
# below see the same settings a real run does. Both read the environment when
# they are sourced.
sys.source(file.path(ROOT, "R", "load_inputs.R"), envir = globalenv())
load_pipeline_inputs(ROOT, "config.csv")

env <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "build_nndm.R"), envir = env)
for (f in ls(env)) assign(f, get(f, envir = env), envir = globalenv())
sys.source(file.path(ROOT, "R", "config.R"), envir = globalenv())
sys.source(file.path(ROOT, "R", "db_utils.R"), envir = globalenv())
sys.source(file.path(ROOT, "R", "codelists.R"), envir = globalenv())
# The NDMM_* constants are what the SQL reads, and check_constants() compares
# them against cfg. Loaded here the same way load_nndm_modules() loads them.
sys.source(file.path(ROOT, "R", "nndm_constants.R"), envir = globalenv())
sys.source(file.path(ROOT, "R", "standalone_constants.R"), envir = globalenv())
bl   <- paste(readLines(file.path(ROOT, "R", "build_nndm.R"), warn = FALSE), collapse = "\n")
# The parsed body, not the file text: a call named only in a comment is not a
# call, and matching raw text counted one. parse() drops comments outright.
body <- local({
  fn <- NULL
  for (e in parse(file.path(ROOT, "R", "build_nndm.R"), keep.source = FALSE))
    if (is.call(e) && identical(as.character(e[[1]]), "<-") &&
        identical(as.character(e[[2]]), "build_nndm")) fn <- e[[3]]
  if (is.null(fn)) stop("build_nndm() not found")
  paste(deparse(fn), collapse = "\n")
})

SETTINGS <- c("STUDY_END", "LOT1_FROM", "STUDY_START", "PRE_LOT1_DAYS",
              "FU_CE_DAYS", "GAP_DAYS", "DOMINO_RUN_ID", "PROJECT_WORK_SCHEMA",
              "DOMINO_USER_NAME", "OBJECT_PREFIX")
clear <- function() for (v in SETTINGS) Sys.unsetenv(v)
clear()

cat("\n-- the runner calls its phases, in order --\n")
ORDER <- c("check_settings", "pin_output_schema", "pin_prefix", "check_contract",
           "check_constants", "set_lot_config", "check_upstream", "write_build_status",
           "build_ndmm_mm_dx_codes", "build_ndmm_mm_claim_header",
           "build_ndmm_mm_dx_events", "build_ndmm_mm_qualifying",
           "build_ndmm_demographics", "build_ndmm_base_cohort",
           "build_enrollment_spans_ndmm",
           "build_ndmm_mma_codelist", "check_ndc_shape",
           "build_ndmm_belantamab_codes", "build_ndmm_index_ineligible_codes",
           "build_ndmm_lot1_index", "build_ndmm_index_agents",
           "build_ndmm_therapy_pre_lot1",
           "build_ndmm_other_malig_codes", "build_ndmm_mm_adjacent_groups",
           "build_ndmm_med_claim_header_and_confinement",
           "build_ndmm_other_malig_pre_lot1", "build_ndmm_preg_codes",
           "build_ndmm_pregnancy_patids", "build_ndmm_belantamab_patids",
           "build_ndmm_belantamab_scope_counts",
           "build_ndmm_flags",
           "ndmm_counts",
           "check_attrition_monotonic", "build_ndmm_cohort_table",
           "check_ndmm_cohort", "write_attrition",
           "write_codelist_metadata", "write_run_metadata")
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
# The NDC profile has to see the codelist view and the LOT1 starts it scopes
# to, and has to run before the scan whose matching it is about.
ok(at[["build_ndmm_mma_codelist"]] < at[["check_ndc_shape"]] &&
     at[["check_ndc_shape"]] < at[["build_ndmm_therapy_pre_lot1"]],
   "the NDC shape is profiled after its inputs exist and before the scan uses them")

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
             tbl_member_elig = "member_cont_enrollment", tbl_dod = "dod")
drive_up <- function(unreadable = character(0)) {
  assign("db_q", function(con, sql) {
    for (u in unreadable) if (grepl(u, sql, fixed = TRUE)) stop("cannot read")
    data.frame(x = 1L)
  }, envir = ue)
  tryCatch({ ue$check_upstream(NULL, UCFG); NULL }, error = conditionMessage)
}
ok(is.null(drive_up()), "all eight raw inputs readable lets the run start")
# There are no built inputs any more: this package reads raw CDM and its code
# lists, which is what lets it be handed to someone on its own.
ok(length(upstream_tables(cfg_defaults)) == 0L,
   "the build depends on no table another build in this repository makes")
msg <- drive_up("cdm.t_dod")
ok(!is.null(msg) && grepl("dod", msg, fixed = TRUE),
   "the death table is preflighted - the demographics step needs it")
msg <- drive_up("cdm.t_member_cont_enrollment")
ok(!is.null(msg) && grepl("member_cont_enrollment", msg, fixed = TRUE),
   "...and the eligibility table, which carries sex and birth year")
msg <- drive_up("cdm.t_member_enrollment")
ok(!is.null(msg) && grepl("member_enrollment", msg, fixed = TRUE),
   "member_enrollment too - the first table the run reads")
msg <- drive_up("cdm.t_confinement")
ok(!is.null(msg) && grepl("confinement", msg, fixed = TRUE),
   "a missing raw CDM table stops it too - the other-cancer rule needs it")
msg <- drive_up(c("cdm.t_member_enrollment", "cdm.t_rx"))
ok(!is.null(msg) && grepl("member_enrollment", msg, fixed = TRUE) &&
     grepl("rx", msg, fixed = TRUE),
   "and two missing inputs are both reported, not just the first")

cat("\n-- the preflight covers every table a step actually reads --\n")
# The list of raw tables was hand-maintained and had drifted: member_enrollment
# feeds both enrollment-span builds, was not in it, and so the preflight passed
# and the run died in phase one. Read the tables out of the steps instead of
# trusting the list.
consts0 <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "nndm_constants.R"), envir = consts0)
sys.source(file.path(ROOT, "R", "standalone_constants.R"), envir = consts0)
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
kl <- c(readLines(file.path(ROOT, "R", "nndm_constants.R"), warn = FALSE),
        readLines(file.path(ROOT, "R", "standalone_constants.R"), warn = FALSE))
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
ok(grepl("'Patients with a qualifying MM diagnosis'", ins, fixed = TRUE) &&
     grepl("no belantamab in any LOT", ins, fixed = TRUE),
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

cat("\n-- the population this build derives for itself --\n")
# No parent cohort table any more. The MM diagnosis, the age gate and the 1L
# index are all derived here, so they are driven here. No database, so the SQL
# the real functions emit is read back.
se <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "nndm_constants.R"), envir = se)
sys.source(file.path(ROOT, "R", "standalone_constants.R"), envir = se)
sys.source(file.path(ROOT, "R", "steps", "00_mm_cohort.R"), envir = se)
sys.source(file.path(ROOT, "R", "steps", "00b_lot1_index.R"), envir = se)
assign("log_msg", function(...) invisible(NULL), envir = se)
assign("cfg", cfg_defaults, envir = se)
SSQL <- character(0)
assign("db_exec", function(con, s) { SSQL <<- c(SSQL, s); TRUE }, envir = se)
assign("load_codelist_csv", function(...) "(SELECT 1) src", envir = se)

SSQL <- character(0); se$build_ndmm_mm_qualifying(NULL)
q <- SSQL[1]
ok(grepl("WHERE inpatient_flg = 1", q, fixed = TRUE) &&
     grepl("AND mm_dx_strict_flg = 1", q, fixed = TRUE),
   "one inpatient claim qualifies, and only a strict 203.0x/C90.0x code does")
ok(grepl(paste0("datediff(next_dt, svc_dt) <= ", se$NDMM_OUTPATIENT_WINDOW), q, fixed = TRUE),
   paste0("two outpatient claims qualify within ", se$NDMM_OUTPATIENT_WINDOW,
          " days, the window S6.2.1.1 fixes"))
ok(grepl("WHERE outpatient_flg = 1", q, fixed = TRUE),
   "...and the pair is built from outpatient claims only")

SSQL <- character(0); se$build_ndmm_base_cohort(NULL)
b <- SSQL[1]
ok(grepl(paste0("(year(q.MM_DX_DT) - m.YRDOB) >= ", se$NDMM_MIN_AGE), b, fixed = TRUE),
   paste0("age is ", se$NDMM_MIN_AGE, " or over in the diagnosis year, by calendar year"))
# The age gate sits in the CTE that the ranking reads, not after it. A patient
# who is 17 at their first qualifying date and 18 at the next is in the cohort,
# and ranking first would lose them.
filt <- sub("\\),\\s*ranked AS.*", "", sub(".*WITH filtered AS \\(", "", b))
ok(grepl("YRDOB) >=", filt, fixed = TRUE),
   "and it is applied before the earliest qualifying date is picked, not after")
ok(grepl("ORDER BY MM_DX_DT) AS rn", b, fixed = TRUE) &&
     grepl("WHERE rn = 1", b, fixed = TRUE),
   "the earliest date that passes is the diagnosis date, not the latest")

SSQL <- character(0)
se$build_ndmm_lot1_index(NULL, "cdm.medical", "cdm.rx")
x <- SSQL[1]
n_arms <- length(gregexpr("INNER JOIN _ndmm_base_cohort b", x, fixed = TRUE)[[1]])
ok(n_arms == 4L,
   paste0("the index is looked for in all four claim sources (", n_arms, ")"))
ok(length(gregexpr(">= b.MM_DX_DT", x, fixed = TRUE)[[1]]) == 4L,
   "every one of them requires the treatment to be on or after the diagnosis")
ok(length(gregexpr(paste0(">= date('", se$NDMM_LOT1_FROM, "')"), x, fixed = TRUE)[[1]]) == 4L,
   "...and on or after the eligible-treatment cutoff")
ok(length(gregexpr(paste0("<= date('", cfg_defaults$study_end, "')"), x,
                   fixed = TRUE)[[1]]) == 4L,
   "...and inside the study period")
ok(length(gregexpr("WHERE bl.code IS NULL", x, fixed = TRUE)[[1]]) == 4L,
   "an ineligible agent cannot set the index, on every one of the four arms")
ok(grepl("_ndmm_index_ineligible", x, fixed = TRUE),
   "...and the ineligible set is the one build_ndmm_index_ineligible_codes builds")
ok(any(grepl("min(tx_dt) AS LOT1_START_DT", SSQL, fixed = TRUE)),
   "the index is the first such claim, which is what S6.2.1.1 defines it as")
ok(grepl("_ndmm_mma_codelist", x, fixed = TRUE),
   "and MM treatment means the same code list the prior-therapy scan uses")

cat("\n-- a plasma-cell disorder in remission is not another cancer --\n")
# The other-cancer criterion targets a cancer distinct from the index MM, which
# is why five plasma-cell tumour groups are overridden. Three are worded "not
# having achieved remission", and apr_30_2026 left the "in remission" variants
# excluding - so an identical patient was kept or dropped depending on whether
# their plasma cell leukemia was in remission.
ok(identical(cfg_defaults$mm_adjacent_remission, "override"),
   "by default remission variants are overridden too, like their counterparts")
ok(all(grepl("REMISSION", se$NDMM_MM_ADJACENT_REMISSION_LABELS, fixed = TRUE)),
   paste0("the ", length(se$NDMM_MM_ADJACENT_REMISSION_LABELS),
          " of them are named, not matched by a pattern that could catch more"))
# Each remission label is the counterpart of one that is already overridden.
stem <- function(x) trimws(sub("(NOT HAVING ACHIEVED REMISSION|IN REMISSION)$", "", x))
ok(all(stem(se$NDMM_MM_ADJACENT_REMISSION_LABELS) %in%
         stem(se$NDMM_MM_ADJACENT_OVERRIDE)),
   "and each names a condition the override already covers in its other state")
assign("NDMM_MM_ADJACENT_REMISSION", "override", envir = se)
ok(setequal(se$ndmm_mm_adjacent_groups(),
            c(se$NDMM_MM_ADJACENT_OVERRIDE, se$NDMM_MM_ADJACENT_REMISSION_LABELS)),
   "override covers both halves")
assign("NDMM_MM_ADJACENT_REMISSION", "exclude", envir = se)
ok(setequal(se$ndmm_mm_adjacent_groups(), se$NDMM_MM_ADJACENT_OVERRIDE),
   "exclude restores apr_30_2026's five, so the two can be compared")
assign("NDMM_MM_ADJACENT_REMISSION", "sometimes", envir = se)
ok(grepl("is not a setting",
         tryCatch({ se$ndmm_mm_adjacent_groups(); "" }, error = conditionMessage),
         fixed = TRUE),
   "and anything else stops the run rather than silently overriding nothing")
assign("NDMM_MM_ADJACENT_REMISSION", "override", envir = se)
# The five stay required; the remission ones do not. Absence of the five means
# the override silently fails, absence of a remission label just means this
# code list does not carry the wording.
oc <- paste(readLines(file.path(ROOT, "R", "steps", "04_other_malig.R"), warn = FALSE),
            collapse = "\n")
ok(grepl("IN ({req_in})", oc, fixed = TRUE) &&
     grepl("req    <- gsub(\"'\", \"''\", NDMM_MM_ADJACENT_OVERRIDE)", oc, fixed = TRUE),
   "the fail-loud count is against the five required labels, not the proposal")
# The list the study team has to look at.
SSQL <- character(0)
assign("db_q", function(con, sql) data.frame(
  TUMOR_GROUP = c("PLASMA CELL LEUKEMIA IN REMISSION", "AMYLOIDOSIS"),
  OVERRIDDEN = c(1L, 0L), N_CODES = c(4L, 9L)), envir = se)
se$build_ndmm_mm_adjacent_groups(NULL, cfg_defaults)
g <- SSQL[1]
ok(grepl("NDMM_MM_ADJACENT_GROUPS", g, fixed = TRUE),
   "every plasma-cell-looking group on the code list is written out for review")
for (k in c("%REMISSION%", "%PLASMACYTOMA%", "%PLASMA CELL%", "%GAMMOPATHY%", "%MYELOMA%"))
  ok(grepl(k, g, fixed = TRUE), paste0("...including anything matching ", k))
ok(grepl("max(is_mm_adjacent_override)", g, fixed = TRUE),
   "with whether the override reaches it, which is the question being asked")

cat("\n-- what \"belantamab in any LOT\" is taken to mean --\n")
# Lines of therapy do not exist when this runs - the LOT algorithm runs over
# the cohort this build produces - so the exclusion is a claims proxy, and
# apr_30_2026's proxy had no lower bound at all: a claim from before the study
# period excluded the patient, which is wrong under any reading of "any LOT".
drive_bel <- function(scope = "study_period") {
  assign("NDMM_BELANTAMAB_SCOPE", scope, envir = se)
  SSQL <<- character(0)
  m <- tryCatch({ se$build_ndmm_belantamab_patids(NULL, "cdm.medical", "cdm.rx"); "" },
                error = conditionMessage)
  list(msg = m, tx = SSQL[1], pat = SSQL[2])
}
r <- drive_bel()
ok(identical(r$msg, ""), "the default scope builds")
ok(length(gregexpr("<= date('", r$tx, fixed = TRUE)[[1]]) == 4L,
   "every claim arm is bounded above by the end of the study period")
ok(grepl(paste0("b.bel_dt >= date('", se$NDMM_STUDY_START, "')"), r$pat, fixed = TRUE),
   "and by default bounded below at the start of it - lines exist nowhere else")
ok(grepl("INNER JOIN _ndmm_lot1_starts", r$pat, fixed = TRUE),
   "scoped to the 1L candidates, so it excludes from this cohort and not at large")
r <- drive_bel("from_index")
ok(grepl("b.bel_dt >= l1.LOT1_START_DT", r$pat, fixed = TRUE),
   "from_index reads it strictly: on or after the date the patient's lines start")
r <- drive_bel("whenever")
ok(grepl("is not a scope", r$msg, fixed = TRUE),
   "a scope nobody defined stops the run rather than quietly excluding everyone")
assign("NDMM_BELANTAMAB_SCOPE", "study_period", envir = se)
# The dates are kept on the claims so all three readings can be counted, and
# the run reports what the choice costs instead of leaving it to be guessed.
ok(grepl("cast(t.{dt} as date) AS bel_dt", r$tx, fixed = TRUE) ||
     grepl("AS bel_dt", r$tx, fixed = TRUE),
   "each belantamab claim keeps its date, which is what makes the comparison possible")
SSQL <- character(0)
assign("db_q", function(con, sql) data.frame(SCOPE = c("ever", "study_period", "from_index"),
                                             N_PATIENTS = c(120L, 118L, 90L)), envir = se)
se$build_ndmm_belantamab_scope_counts(NULL, cfg_defaults)
sc <- SSQL[1]
ok(grepl("NDMM_BELANTAMAB_SCOPE_COUNTS", sc, fixed = TRUE),
   "the three readings are counted into a table every run")
for (k in c("'ever'", "'study_period'", "'from_index'"))
  ok(grepl(k, sc, fixed = TRUE), paste0("...including ", k))
ok(length(gregexpr("count(DISTINCT b.PATID)", sc, fixed = TRUE)[[1]]) == 3L,
   "by patients, so the numbers can be compared against the attrition")

cat("\n-- which agents may set the index, and which set one --\n")
# S6.2.1.1 says the eligible treatments exclude "those restricted to later LOTs
# (see exclusion criteria)", and S6.2.1.2 names one therapy: belantamab. So the
# default restricts nothing else. A name added here shrinks the cohort by a
# rule the protocol does not state, which is why it is pinned and recorded.
ok(identical(cfg_defaults$index_excluded_abbrs, "") &&
     identical(cfg_defaults$index_excluded_codes, ""),
   "nothing beyond belantamab is barred from setting the index by default")
ok("NDMM_INDEX_EXCLUDED_ABBRS" %in% vapply(CONSTANT_SETTINGS, function(s) s$const,
                                           character(1)),
   "and if something is barred, the setting is pinned like anything that moves the count")
drive_inel <- function(extra = "", codes = "", matches = 3L) {
  assign("NDMM_INDEX_EXCLUDED_ABBRS", extra, envir = se)
  assign("NDMM_INDEX_EXCLUDED_CODES", codes, envir = se)
  SSQL <<- character(0)
  assign("db_q", function(con, sql) data.frame(n = matches), envir = se)
  m <- tryCatch({ se$build_ndmm_index_ineligible_codes(NULL); "" }, error = conditionMessage)
  list(msg = m, sql = SSQL[1])
}
r <- drive_inel("")
ok(identical(r$msg, "") && grepl(se$NDMM_BELANTAMAB_ABBR, r$sql, fixed = TRUE),
   "with nothing named, belantamab alone is ineligible")
ok(length(gregexpr("LIKE '", r$sql, fixed = TRUE)[[1]]) == 1L,
   "...one pattern, not a wider net than the protocol asks for")
r <- drive_inel("CART,TALQ")
ok(grepl("'CART'", r$sql, fixed = TRUE) && grepl("'TALQ'", r$sql, fixed = TRUE) &&
     grepl(se$NDMM_BELANTAMAB_ABBR, r$sql, fixed = TRUE),
   "named agents join belantamab, and belantamab is never dropped")
r <- drive_inel("NOSUCHAGENT", matches = 0L)
ok(grepl("matches no row", r$msg, fixed = TRUE) &&
     grepl("NOSUCHAGENT", r$msg, fixed = TRUE),
   "a name that matches no code stops the run - it would read as a restriction and do nothing")
# By code as well as by name: the study team may have the HCPCS or the NDC and
# not the code list's own abbreviation.
r <- drive_inel(codes = "HCPCS:J9999")
ok(grepl("code_type = 'HCPCS'", r$sql, fixed = TRUE) &&
     grepl("code = 'J9999'", r$sql, fixed = TRUE),
   "a TYPE:CODE entry bars that code of that type")
r <- drive_inel(codes = "J9999")
ok(grepl("code = 'J9999'", r$sql, fixed = TRUE) &&
     !grepl("code_type = ", r$sql, fixed = TRUE),
   "...and a bare code bars it whatever the type")
# Stripped, not padded: the code list stores its codes stripped too, and the
# eleven-digit padding happens at the join. Padding here would stop a
# ten-digit code list entry matching the ten-digit code someone typed.
r <- drive_inel(codes = "ndc:50242-040-62")
ok(grepl("code_type = 'NDC'", r$sql, fixed = TRUE) &&
     grepl("code = '5024204062'", r$sql, fixed = TRUE),
   "punctuation is stripped and the type uppercased, the same as the code list")
r <- drive_inel(codes = "HCPCS:J0000", matches = 0L)
ok(grepl("matches no row", r$msg, fixed = TRUE) && grepl("J0000", r$msg, fixed = TRUE),
   "a code not on the therapy list stops the run too - barring it would do nothing")
r <- drive_inel("CART", "HCPCS:J9999")
ok(grepl("'CART'", r$sql, fixed = TRUE) && grepl("J9999", r$sql, fixed = TRUE) &&
     grepl(se$NDMM_BELANTAMAB_ABBR, r$sql, fixed = TRUE),
   "names and codes combine, and belantamab survives both")
assign("NDMM_INDEX_EXCLUDED_ABBRS", "", envir = se)
assign("NDMM_INDEX_EXCLUDED_CODES", "", envir = se)

# The list the protocol gestures at and no document here contains: what the
# data says actually set an index.
SSQL <- character(0)
assign("db_q", function(con, sql) data.frame(MED_ABBR = c("LEN", "BOR"),
                                             N_PATIENTS = c(900L, 700L)), envir = se)
se$build_ndmm_index_agents(NULL, cfg_defaults)
a <- SSQL[1]
ok(grepl("CREATE OR REPLACE TABLE", a, fixed = TRUE) &&
     grepl("NDMM_INDEX_AGENTS", a, fixed = TRUE),
   "the agents that set an index are written to a table, not only logged")
ok(grepl("tx.tx_dt = l1.LOT1_START_DT", a, fixed = TRUE),
   "counted on the index date itself, so it is what set the index and not any later claim")
ok(grepl("count(DISTINCT PATID)", a, fixed = TRUE),
   "...by patients, so one agent's many claims do not read as many patients")
ok(grepl("_ndmm_index_tx", a, fixed = TRUE),
   "and read off the scan the index came from, not a second pass over the claims")

# Belantamab is how exclusion 4 is applied and how the index scan knows what to
# skip. If the abbreviation matches nothing, both silently stop working.
assign("db_q", function(con, sql) data.frame(n = 0L), envir = se)
m <- tryCatch({ se$build_ndmm_belantamab_codes(NULL); "" }, error = conditionMessage)
ok(grepl("No row of cl_mma_codelist.csv", m, fixed = TRUE) &&
     grepl(se$NDMM_BELANTAMAB_ABBR, m, fixed = TRUE),
   "a belantamab abbreviation that matches nothing stops the run, named")
assign("db_q", function(con, sql) data.frame(n = 7L), envir = se)
ok(identical(tryCatch({ se$build_ndmm_belantamab_codes(NULL); "" },
                      error = conditionMessage), ""),
   "...and one that matches lets it go on")

cat("\n-- the cohort is a cohort the LOT build can be pointed at --\n")
# The next stage runs the LOT algorithm over these patients, so this table is
# its input. Jul 28/lot reads ten columns off whatever cohort it is given, and
# NDMM_COHORT was PATID alone - that build would have stopped at its own input
# check before doing anything.
lot_req <- local({
  f <- file.path(dirname(ROOT), "lot", "R", "build_lot.R")
  if (!file.exists(f)) return(NULL)
  e <- new.env(); eval(parse(text = paste(
    grep("^REQUIRED_COHORT_COLS", readLines(f, warn = FALSE)), collapse = "")), e)
  ln <- readLines(f, warn = FALSE)
  i <- grep("^REQUIRED_COHORT_COLS <- ", ln)
  if (!length(i)) return(NULL)
  j <- i; while (!grepl("\\)\\s*$", ln[j])) j <- j + 1L
  eval(parse(text = paste(ln[i:j], collapse = "\n")))
})
if (is.null(lot_req)) {
  cat("  ---- Jul 28/lot is not beside this folder; its column list was NOT read\n")
} else {
  ok(setequal(NDMM_COHORT_COLS, lot_req),
     paste0("NDMM_COHORT declares exactly what Jul 28/lot requires (",
            length(lot_req), " columns), read from that build not copied"))
}
be <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "nndm_constants.R"), envir = be)
sys.source(file.path(ROOT, "R", "build_nndm.R"), envir = be)
assign("log_msg", function(...) invisible(NULL), envir = be)
assign("wrk", function(x) paste0("wk.p_", x), envir = be)
BSQL <- character(0)
assign("run_step", function(con, name, sql, qc = NULL) { BSQL <<- c(BSQL, sql); TRUE },
       envir = be)
assign("NDMM_BASE_COHORT", "_ndmm_base_cohort", envir = be)
be$build_ndmm_cohort_table(NULL, cfg_defaults)
csql <- BSQL[1]
ok(!is.na(csql) && grepl("l1.LOT1_START_DT AS INDEX_DATE", csql, fixed = TRUE),
   "the index date is the 1L start, not the parent's MM-diagnosis index")
# The outer SELECT only. Every one of these names also appears in a CTE, so
# checking the whole statement would pass on a column the table never gets.
sel <- sub("\\s*FROM idx i.*", "", sub("(?s).*\\n\\s*SELECT i\\.PATID", "SELECT i.PATID",
                                     csql, perl = TRUE))
for (c in setdiff(NDMM_COHORT_COLS, "PATID"))
  ok(grepl(paste0("(AS +", c, "|[. ]", c, ")(?![_A-Za-z0-9])"), sel, perl = TRUE),
     paste0(c, " is a column of the table, not just a name inside a CTE"))
# Anything that depends on where the anchor sits has to be recomputed at it.
ok(grepl("year(i.INDEX_DATE) - d.YRDOB", csql, fixed = TRUE),
   "age is computed at the 1L index, not inherited from the MM-diagnosis one")
ok(grepl("date_add(i.INDEX_DATE, 1)", csql, fixed = TRUE) &&
     length(gregexpr("date_add(i.INDEX_DATE, 1)", csql, fixed = TRUE)[[1]]) == 2L,
   "and both follow-up lengths run from it")
ok(grepl("b.DEATH_DT < i.INDEX_DATE", csql, fixed = TRUE) &&
     grepl("THEN i.INDEX_DATE ELSE b.DEATH_DT", csql, fixed = TRUE),
   "an imputed death between the diagnosis and the 1L index is re-clamped at the index")
ok(grepl("s.cov_start <= i.INDEX_DATE", csql, fixed = TRUE) &&
     grepl("s.cov_end   >= i.INDEX_DATE", csql, fixed = TRUE),
   "the CE end is the span covering the 1L index, so it moves with the anchor too")
ok(grepl("GDR_CD, YRDOB", csql, fixed = TRUE) &&
     grepl("_ndmm_base_cohort", csql, fixed = TRUE),
   "only the demographics are carried across - they do not depend on an anchor")

cat("\n-- and it is checked before anyone is handed it --\n")
ce2 <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "build_nndm.R"), envir = ce2)
assign("log_msg", function(...) invisible(NULL), envir = ce2)
assign("wrk", function(x) paste0("wk.p_", x), envir = ce2)
drive_chk <- function(cols = NDMM_COHORT_COLS, pat = 10L, rows = pat, noidx = 0L,
                      expect = pat, backwards = 0L, nofu = 0L) {
  assign("db_q", function(con, sql) {
    if (grepl("DESCRIBE", sql, fixed = TRUE)) data.frame(col_name = cols)
    else data.frame(n_rows = rows, n_pat = pat, n_noidx = noidx,
                    n_backwards = backwards, n_nofu = nofu)
  }, envir = ce2)
  tryCatch({ ce2$check_ndmm_cohort(NULL, list(), expect); "" }, error = conditionMessage)
}
ok(identical(drive_chk(), ""), "a well-formed cohort passes")
m <- drive_chk(cols = setdiff(NDMM_COHORT_COLS, c("INDEX_DATE", "FU_DAYS_CE")))
ok(grepl("INDEX_DATE", m, fixed = TRUE) && grepl("FU_DAYS_CE", m, fixed = TRUE),
   "a missing column is named here, not at the far end of the next build")
ok(grepl("Jul 28/lot", m, fixed = TRUE), "...and so is who needs it")
m <- drive_chk(rows = 12L, pat = 10L)
ok(grepl("fans out", m, fixed = TRUE),
   "a repeated PATID stops it - it would multiply every join a LOT run makes")
m <- drive_chk(noidx = 3L)
ok(grepl("no INDEX_DATE", m, fixed = TRUE),
   "so does a row with no index date, which is the day every window runs from")
m <- drive_chk(backwards = 2L)
ok(grepl("end before they begin", m, fixed = TRUE),
   "a cohort row whose follow-up ends before the index stops the build")
m <- drive_chk(nofu = 4L)
ok(grepl("no follow-up at all", m, fixed = TRUE),
   "...and so does one with no follow-up window for a LOT run to measure")
m <- drive_chk(pat = 9L, expect = 10L)  # rows follows pat, so this is not a fan-out
ok(grepl("attrition ends at", m, fixed = TRUE),
   "and a cohort that disagrees with its own funnel is not published")
ok(identical(drive_chk(expect = NA_integer_), ""),
   "an unknown expected count is not treated as a mismatch")

cat("\n-- the other-cancer pair has to sit in the baseline --\n")
# The criterion is >=1 inpatient claim, or >=2 outpatient claims within 30 days
# of each other, IN the 12-month 1L baseline. The source bounded only the first
# of the outpatient pair, so a claim the day before the index and its
# confirmation a month after it excluded the patient on one baseline claim.
#
# There is no database here, so this reads the SQL the real function emits
# rather than running it: for every date column the outpatient pair exposes,
# the join must bound it. Derived rather than matched, so a new unbounded date
# column fails the same way removing this one does.
oe <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "nndm_constants.R"), envir = oe)
sys.source(file.path(ROOT, "R", "steps", "04_other_malig.R"), envir = oe)
assign("log_msg", function(...) invisible(NULL), envir = oe)
assign("cfg", cfg_defaults, envir = oe)
OSQL <- character(0)
assign("db_exec", function(con, s) { OSQL <<- c(OSQL, s); TRUE }, envir = oe)
oe$build_ndmm_other_malig_pre_lot1(NULL, "cdm.med_diagnosis")
sql <- OSQL[1]
ok(!is.na(sql) && grepl("outpatient_pairs", sql, fixed = TRUE),
   "the real function emitted the other-cancer SQL")
cte  <- sub(".*outpatient_pairs AS \\(", "", sql); cte <- sub("FROM with_next.*", "", cte)
join <- sub(".*LEFT JOIN outpatient_pairs op", "", sql); join <- sub("WHERE .*", "", join)
pair_dates <- unique(unlist(regmatches(cte, gregexpr("(?<=AS )[a-z_]+_dt|(?<![A-Za-z_.])next_dt",
                                                     cte, perl = TRUE))))
ok(setequal(pair_dates, c("first_dt", "next_dt")),
   paste0("the pair exposes exactly the two claim dates (",
          paste(sort(pair_dates), collapse = ", "), ")"))
unbounded <- Filter(function(d)
  !grepl(paste0("op.", d, "\\s+BETWEEN l1.pre_lot1_start AND l1.pre_lot1_end"),
         join, perl = TRUE), pair_dates)
ok(length(unbounded) == 0,
   if (length(unbounded)) paste0("outpatient claim dates the join leaves outside ",
                                 "the baseline: ", paste(unbounded, collapse = ", "))
   else "and the join requires both of them to fall in the 12-month baseline")
ok(grepl("op.diff_days <= 30", join, fixed = TRUE),
   "within 30 days of each other, as the protocol writes it")
# The inpatient arm is one claim, so it has one date and it is bounded too.
ipj <- sub(".*LEFT JOIN inpatient_flag ip", "", sql); ipj <- sub("LEFT JOIN outpatient_pairs.*", "", ipj)
ok(grepl("ip.event_dt BETWEEN l1.pre_lot1_start AND l1.pre_lot1_end", ipj, fixed = TRUE),
   "the single inpatient claim is bounded by the same window")
ok(grepl("date_sub(LOT1_START_DT, 365) AS pre_lot1_start", sql, fixed = TRUE) &&
     grepl("date_sub(LOT1_START_DT, 1)", sql, fixed = TRUE),
   "and that window is [index - 365, index - 1] - it ends before the index date")

cat("\n-- NDCs that the padding would get wrong --\n")
# The prior-therapy join strips non-digits and left-pads to eleven. That is the
# 4-4-2 layout only; a 5-3-2 or 5-4-1 ten-digit code pads to a different key, so
# a real prior therapy is missed or the wrong drug matched - and the patient's
# inclusion turns on it. Driven with a stub profile, because there is no
# warehouse here and what matters is which shapes stop the run.
ne <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "build_nndm.R"), envir = ne)
assign("log_msg", function(...) invisible(NULL), envir = ne)
assign("cdm_src", function(x) paste0("cdm.t_", x), envir = ne)
assign("NDMM_BASE_COHORT", "_ndmm_base_cohort", envir = ne)
assign("NDMM_MMA_CODELIST", "_cl", envir = ne)
assign("NDMM_PRE_LOT1_DAYS", 365L, envir = ne)
row <- function(src, n = 10L, n11 = 10L, n10 = 0L, oth = 0L, alpha = 0L,
                nodig = 0L, zero = 0L)
  data.frame(SOURCE = src, n_ndc = n, n_11 = n11, n_10 = n10, n_other = oth,
             n_alpha = alpha, n_nodigit = nodig, n_zero = zero,
             stringsAsFactors = FALSE)
NSQL <- character(0)
drive_ndc <- function(med = row("medical"), rx = row("rx"), cl = row("codelist"),
                      waive = "") {
  Sys.setenv(NDMM_WAIVERS = waive)
  i <- 0L
  assign("db_q", function(con, sql) {
    NSQL <<- c(NSQL, sql); i <<- i + 1L; list(med, rx, cl)[[i]]
  }, envir = ne)
  out <- tryCatch({ ne$check_ndc_shape(NULL, cfg_defaults); "" }, error = conditionMessage)
  Sys.unsetenv("NDMM_WAIVERS")
  out
}
NSQL <- character(0)
ok(identical(drive_ndc(), ""), "eleven digits everywhere lets the run go on")
ok(length(NSQL) == 3L &&
     any(grepl("cdm.t_medical", NSQL, fixed = TRUE)) &&
     any(grepl("cdm.t_rx", NSQL, fixed = TRUE)) &&
     any(grepl("_cl", NSQL, fixed = TRUE)),
   "both claim sources and the code list are profiled, not just the claims")
ok(any(grepl("_ndmm_base_cohort", NSQL, fixed = TRUE)) &&
     any(grepl("date_sub(b.MM_DX_DT, 365)", NSQL, fixed = TRUE)),
   "scoped to the base cohort and a window covering every NDC scan that follows")
ok(all(grepl("trim(cast(t.NDC as string)) <> ''", NSQL[1:2], fixed = TRUE)),
   "and every non-blank value is counted, including ones that cannot join")
m <- drive_ndc(rx = row("rx", n10 = 3L, n11 = 7L))
ok(grepl("Ten-digit claim NDCs", m, fixed = TRUE) && grepl("4-4-2", m, fixed = TRUE),
   "a ten-digit claim NDC stops the run, naming the layout the padding assumes")
ok(grepl("claim_ndc_short", m, fixed = TRUE),
   "...and says how the study team can accept it once they have checked")
ok(identical(drive_ndc(rx = row("rx", n10 = 3L, n11 = 7L), waive = "claim_ndc_short"), ""),
   "the waiver lets that one through")
m <- drive_ndc(med = row("medical", alpha = 2L), waive = "claim_ndc_short")
ok(grepl("cannot be an NDC", m, fixed = TRUE),
   "and waiving the short check does not waive the shape check")
m <- drive_ndc(cl = row("codelist", n10 = 4L))
ok(grepl("Ten-digit code list NDCs", m, fixed = TRUE) &&
     grepl("cl_mma_codelist.csv", m, fixed = TRUE),
   "a ten-digit code on the code list side stops it too, and that one is fixable")
m <- drive_ndc(med = row("medical", zero = 1L))
ok(grepl("cannot be an NDC", m, fixed = TRUE),
   "an all-zero NDC is caught though it is eleven digits - it is the key a missing value makes")
m <- drive_ndc(med = row("medical", oth = 5L))
ok(grepl("cannot be an NDC", m, fixed = TRUE), "so is an under- or over-length one")
Sys.setenv(NDMM_WAIVERS = "claim_ndc_short,not_a_check")
m <- tryCatch({ check_settings(); "" }, error = conditionMessage)
ok(grepl("no such check", m, fixed = TRUE) && grepl("not_a_check", m, fixed = TRUE),
   "a waiver naming nothing real is a typo, and is refused before the run starts")
Sys.setenv(NDMM_WAIVERS = "codelist_ndc_short")
ok(identical(waivers(), "codelist_ndc_short"), "a real waiver is honoured")
Sys.setenv(NDMM_WAIVERS = "check_upstream")
ok(length(waivers()) == 0L,
   "and nothing outside the waivable set is ever honoured, whatever is set")
Sys.unsetenv("NDMM_WAIVERS")

cat("\n-- what made this cohort, beside the cohort --\n")
re <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "build_nndm.R"), envir = re)
assign("log_msg", function(...) invisible(NULL), envir = re)
assign("wrk", function(x) paste0("wk.p_", x), envir = re)
assign("run_id", "R1", envir = re)
RSQL <- character(0)
assign("db_exec", function(con, s) { RSQL <<- c(RSQL, s); TRUE }, envir = re)
assign("db_replace", function(con, ...) { RSQL <<- c(RSQL, c(...)); TRUE }, envir = re)
options(nndm_waivers_applied = "claim_ndc_short")
Sys.setenv(NDMM_WAIVERS = "claim_ndc_short,codelist_ndc_short")
re$write_run_metadata(NULL, modifyList(cfg_defaults, list(object_prefix = "p_")),
                      ROOT, 1234)
Sys.unsetenv("NDMM_WAIVERS"); options(nndm_waivers_applied = character(0))
ins <- grep("INSERT", RSQL, value = TRUE)[1]
ok(!is.na(ins) && grepl(code_fingerprint(ROOT), ins, fixed = TRUE),
   "the run records the md5 of the code that made it")
ok(!is.na(ins) && grepl("lot1_from=2017-01-01", ins, fixed = TRUE) &&
     grepl("fu_ce_days=0", ins, fixed = TRUE),
   "...and the settings, so a cohort can be matched to a build not guessed at")
ok(!is.na(ins) && grepl("'BEL%'", ins, fixed = TRUE),
   "...and how it recognised belantamab, which is a code-list assumption")
ok(!is.na(ins) && grepl("'claim_ndc_short,codelist_ndc_short'", ins, fixed = TRUE) &&
     grepl("'claim_ndc_short'", ins, fixed = TRUE),
   "waivers asked for and waivers that fired are recorded apart")
ok(!is.na(ins) && grepl(", 1234,", ins, fixed = TRUE), "with the cohort size")
ok(any(vapply(RSQL, function(g) grepl("DELETE", g, fixed = TRUE), logical(1))),
   "and the run's own row is cleared first, so a re-run does not stack")
# Two runs of the same code and settings must agree, or the value says nothing.
ok(identical(code_fingerprint(ROOT), code_fingerprint(ROOT)) &&
     identical(contract_settings(), contract_settings()),
   "the fingerprint and the settings string are stable across calls")
# And across machines: both sort with method = "radix" because the default is
# collation-sensitive, so the same code would hash differently under a
# different locale. Needs a collation that differs from C to exercise - many
# containers ship only C locales, in which case this says so rather than
# passing on nothing.
keep_lc <- Sys.getlocale("LC_COLLATE")
alt <- Filter(function(l) nzchar(suppressWarnings(Sys.setlocale("LC_COLLATE", l))),
              c("en_US.UTF-8", "en_US.utf8", "en_GB.UTF-8", "de_DE.UTF-8"))
Sys.setlocale("LC_COLLATE", keep_lc)
if (length(alt)) {
  a <- code_fingerprint(ROOT); b <- contract_settings()
  Sys.setlocale("LC_COLLATE", alt[1])
  same <- identical(code_fingerprint(ROOT), a) && identical(contract_settings(), b)
  Sys.setlocale("LC_COLLATE", keep_lc)
  ok(same, paste0("and unchanged under ", alt[1], " - the same code hashes the same ",
                  "whatever the machine's collation"))
} else {
  cat("  ---- no collation differing from C on this machine; the locale ",
      "independence of code_fingerprint()/contract_settings() was NOT ",
      "exercised\n", sep = "")
}

cat("\n-- nothing is read before the step that builds it --\n")
# check_ndc_shape() joined NDMM_LOT1_STARTS and was called before the step that
# creates it. Nothing caught that: the phase list pins a handful of pairs by
# hand, and this was not one of them. So derive it - for every view any called
# function reads, the function that creates it has to be called earlier.
view_consts <- Filter(function(k) {
  v <- get(k, envir = consts0, inherits = FALSE)
  is.character(v) && length(v) == 1L && grepl("^_", v)
}, ls(consts0))
fn_bodies <- local({
  out <- list()
  for (f in c(step_files, file.path(ROOT, "R", "build_nndm.R"))) {
    ln <- readLines(f, warn = FALSE)
    starts <- grep("^([A-Za-z_.][A-Za-z0-9_.]*) <- function", ln)
    for (i in starts) {
      nm <- sub(" <- function.*", "", ln[i])
      e  <- grep("^}", ln); e <- e[e > i]
      if (length(e)) out[[nm]] <- ln[i:e[1]]
    }
  }
  out
})
view_names <- setNames(vapply(view_consts, function(k)
  get(k, envir = consts0, inherits = FALSE), character(1)), view_consts)
pos <- function(fn) {
  m <- regexpr(paste0("(?<![A-Za-z0-9_.])", fn, "\\("), body, perl = TRUE)
  if (m == -1) NA_integer_ else as.integer(m)
}
creates <- list(); readers <- list()
for (nm in names(fn_bodies)) {
  txt <- paste(fn_bodies[[nm]], collapse = "\n")
  for (k in view_consts) {
    tok <- paste0("{", k, "}")
    if (regexpr(tok, txt, fixed = TRUE) == -1) next
    if (regexpr(paste0("VIEW ", tok), txt, fixed = TRUE) > 0) creates[[k]] <- nm
    else readers[[k]] <- unique(c(readers[[k]], nm))
  }
}
too_early <- character(0)
for (k in names(readers)) {
  cr <- creates[[k]]
  if (is.null(cr)) next
  pc <- pos(cr)
  if (is.na(pc)) next
  for (rd in readers[[k]]) {
    pr <- pos(rd)
    if (!is.na(pr) && pr < pc)
      too_early <- c(too_early, paste0(rd, "() reads ", k, " before ", cr,
                                       "() builds it"))
  }
}
ok(length(creates) > 0,
   paste0("the runner's calls resolve to ", length(creates), " views with a builder"))
ok(length(too_early) == 0,
   if (length(too_early)) paste0("read before it exists -- ",
                                 paste(too_early, collapse = "; "))
   else "every view a called step reads is built by an earlier call")

cat("\n-- a view read twice is a query run twice --\n")
# Spark re-runs a temporary view on every read. These views sit on top of each
# other, so a second read of NDMM_LOT1_STARTS is a second run of the whole
# MM-diagnosis chain beneath it, over the raw claim tables. The list of what
# gets written to the schema is derived from the SQL rather than maintained by
# hand: count the reads, and anything read more than once has to be on it.
sql_txt <- paste(c(unlist(lapply(step_files, readLines, warn = FALSE)),
                   readLines(file.path(ROOT, "R", "build_nndm.R"), warn = FALSE)),
                 collapse = "\n")
reads <- vapply(view_consts, function(k) {
  n  <- length(gregexpr(paste0("{", k, "}"), sql_txt, fixed = TRUE)[[1]])
  n  <- if (regexpr(paste0("{", k, "}"), sql_txt, fixed = TRUE) == -1) 0L else n
  cr <- length(gregexpr(paste0("VIEW {", k, "}"), sql_txt, fixed = TRUE)[[1]])
  cr <- if (regexpr(paste0("VIEW {", k, "}"), sql_txt, fixed = TRUE) == -1) 0L else cr
  as.integer(n - cr)
}, integer(1))
hot <- names(reads)[reads > 1L]
# NDMM_LOT_LONG_FILT is not built at all.
hot <- setdiff(hot, "NDMM_LOT_LONG_FILT")
ok(length(hot) > 0, paste0("the SQL reads ", length(hot), " views more than once"))
unwritten <- setdiff(hot, CHECKPOINTS)
ok(length(unwritten) == 0,
   if (length(unwritten)) paste0("read more than once but re-run every time: ",
                                 paste(unwritten, collapse = ", "))
   else "and every one of them is written to the schema once instead")
ok("NDMM_LOT1_STARTS" %in% CHECKPOINTS && reads[["NDMM_LOT1_STARTS"]] >= 10L,
   paste0("NDMM_LOT1_STARTS among them - it is read ",
          reads[["NDMM_LOT1_STARTS"]], " times"))
# The two the count cannot see, because the flags step takes them as arguments.
ok(all(c("NDMM_BASE_COHORT", "NDMM_BELANTAMAB_PATIDS") %in% CHECKPOINTS),
   "and the two passed to a step as parameters, which the count cannot see")
ok(all(CHECKPOINTS %in% OUTPUTS),
   "each is declared an output, because each is a table the run leaves behind")

# Driven: the write, then the repoint, in that order and against the same name.
ke <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "build_nndm.R"), envir = ke)
assign("log_msg", function(...) invisible(NULL), envir = ke)
assign("wrk", function(x) paste0("wk.p_", x), envir = ke)
assign("NDMM_LOT1_STARTS", "_ndmm_lot1_starts", envir = ke)
KSQL <- character(0)
assign("db_exec", function(con, s) { KSQL <<- c(KSQL, s); TRUE }, envir = ke)
ke$checkpoint(NULL, "NDMM_LOT1_STARTS")
ok(length(KSQL) == 2L, "a checkpoint is two statements")
ok(grepl("CREATE OR REPLACE TABLE wk.p_NDMM_LOT1_STARTS AS SELECT * FROM _ndmm_lot1_starts",
         KSQL[1], fixed = TRUE),
   "the rows are written to a prefixed table in the work schema")
ok(grepl("CREATE OR REPLACE TEMPORARY VIEW _ndmm_lot1_starts AS SELECT * FROM wk.p_NDMM_LOT1_STARTS",
         KSQL[2], fixed = TRUE),
   "...and the view is repointed at it, so no step has to know")
# db_exec stops on failure, so a checkpoint that cannot be written stops the
# run rather than degrading to the view and taking hours without saying so.
# Fails only on the write, so this is about the write propagating and not
# about the repoint that follows it.
assign("db_exec", function(con, s)
  if (grepl("CREATE OR REPLACE TABLE", s, fixed = TRUE)) stop("write refused")
  else TRUE, envir = ke)
ok(grepl("write refused",
         tryCatch({ ke$checkpoint(NULL, "NDMM_LOT1_STARTS"); "" }, error = conditionMessage),
         fixed = TRUE),
   "a checkpoint that cannot be written stops the build")
# Every checkpoint is taken, and after the step that builds the view it names -
# checkpointing first would write an empty table and repoint the view at it,
# and the step would then rebuild the view and undo the whole thing.
builds <- list(NDMM_MM_DX_EVENTS = "build_ndmm_mm_dx_events",
               NDMM_MM_QUALIFYING = "build_ndmm_mm_qualifying",
               NDMM_BASE_COHORT = "build_ndmm_base_cohort",
               NDMM_ENROLL_SPANS = "build_enrollment_spans_ndmm",
               NDMM_MMA_CODELIST = "build_ndmm_mma_codelist",
               NDMM_BELANTAMAB_CODES = "build_ndmm_belantamab_codes",
               NDMM_LOT1_STARTS = "build_ndmm_lot1_index",
               NDMM_INDEX_TX = "build_ndmm_lot1_index",
               NDMM_OTHER_MALIG_CODES = "build_ndmm_other_malig_codes",
               NDMM_BELANTAMAB_PATIDS = "build_ndmm_belantamab_patids",
               NDMM_BELANTAMAB_TX = "build_ndmm_belantamab_patids",
               NDMM_PATIDS = "build_ndmm_flags")
# NDMM_FLAGS_ALL is checkpointed inside the step that builds it, not by the
# runner - NDMM_PATIDS is defined over it there and Spark inlines the plan.
fl_txt <- paste(readLines(file.path(ROOT, "R", "steps", "06_flags.R"), warn = FALSE),
                collapse = "\n")
ok(regexpr('checkpoint(con, "NDMM_FLAGS_ALL")', fl_txt, fixed = TRUE) > 0 &&
     regexpr('checkpoint(con, "NDMM_FLAGS_ALL")', fl_txt, fixed = TRUE) <
       regexpr("VIEW {NDMM_PATIDS}", fl_txt, fixed = TRUE),
   "NDMM_FLAGS_ALL is written before NDMM_PATIDS is defined over it")
ok(!grepl("could not materialize", fl_txt, fixed = TRUE),
   "and a write it cannot do is not warned past - it is a declared output")
for (k in setdiff(CHECKPOINTS, "NDMM_FLAGS_ALL")) {
  i <- regexpr(paste0('checkpoint(con, "', k, '")'), body, fixed = TRUE)
  j <- if (is.null(builds[[k]])) -1L else
    regexpr(paste0("(?<![A-Za-z0-9_.])", builds[[k]], "\\("), body, perl = TRUE)
  ok(i > 0 && j > 0 && j < i,
     paste0(k, " is checkpointed, after ", builds[[k]], "() has built it"))
}

cat("\n-- the outputs are all prefixed, and all declared --\n")
assign("cfg", pin_prefix(base, "p_"), envir = globalenv())
for (t in OUTPUTS)
  ok(grepl(paste0(".p_", t), wrk(t), fixed = TRUE),
     paste0(t, " is written under the cohort prefix"))
# Every table the run names, whether written as a literal or through a
# constant - and only from code the run reaches. 07_cohort.R still carries
# build_lot_long_filtered(), which the runner no longer calls; scanning the
# whole file would credit this package with a table nothing writes.
consts <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "nndm_constants.R"), envir = consts)
sys.source(file.path(ROOT, "R", "standalone_constants.R"), envir = consts)
# The bodies of the step functions the runner calls, plus the runner itself.
# Derived from the runner's own body, not from ORDER: a call added back to the
# runner has to show up here, or the scan would not follow it and the table it
# writes would go unnoticed.
step_fns <- unlist(lapply(step_files, function(f)
  ls(local({ e <- new.env(); suppressWarnings(try(sys.source(f, envir = e), silent = TRUE)); e }))))
called <- Filter(function(nm)
  regexpr(paste0("(?<![A-Za-z0-9_.])", nm, "\\("), body, perl = TRUE) != -1, step_fns)
# And ORDER has to name every one of them, so the phase list cannot fall behind
# the runner it describes.
extra <- setdiff(called, ORDER)
ok(length(extra) == 0,
   if (length(extra)) paste0("the runner calls step functions ORDER does not name: ",
                             paste(extra, collapse = ", "))
   else "ORDER names every step function the runner calls")
body_of_fn <- function(f, nm) {
  ln <- readLines(f, warn = FALSE)
  i <- grep(paste0("^", nm, " <- function"), ln)
  if (!length(i)) return(character(0))
  j <- grep("^}", ln); j <- j[j > i[1]]
  if (!length(j)) return(character(0))
  ln[i[1]:j[1]]
}
reached <- c(readLines(file.path(ROOT, "R", "build_nndm.R"), warn = FALSE),
             unlist(lapply(step_files, function(f)
               unlist(lapply(called, function(nm) body_of_fn(f, nm))))))
txt  <- paste(reached, collapse = "\n")
args <- unique(unlist(regmatches(txt, gregexpr("(?<=wrk\\()[^)]+(?=\\))", txt, perl = TRUE))))
named <- unique(unlist(lapply(args, function(a) {
  a <- trimws(a)
  if (grepl("^['\"].*['\"]$", a)) gsub("^['\"]|['\"]$", "", a)
  else if (exists(a, envir = consts, inherits = FALSE)) get(a, envir = consts)
  else NULL                       # wrk(t), the loop variable in check_upstream
})))
inputs <- names(upstream_tables(cfg_defaults))
ok(length(called) > 0,
   paste0("the scan follows the ", length(called), " step functions the runner calls"))
undeclared <- setdiff(named, c(OUTPUTS, inputs))
ok(length(undeclared) == 0,
   if (length(undeclared)) paste0("tables written but not declared: ",
                                  paste(undeclared, collapse = ", "))
   else "every table the run names is declared as an output or as an upstream input")
# And the other way. A declared output nothing writes is the same failure seen
# from the other side: the run reports complete and the table is not there.
# checkpoint() writes wrk(name) with the name in a variable, so the scan above
# cannot see those. They are covered instead by the loop that requires a
# checkpoint(con, "<name>") call in the runner for every one of them.
ck_txt <- paste(c(body, unlist(lapply(step_files, readLines, warn = FALSE))),
                collapse = "\n")
checkpointed <- Filter(function(k)
  regexpr(paste0('checkpoint(con, "', k, '")'), ck_txt, fixed = TRUE) > 0, CHECKPOINTS)
unwritten <- setdiff(OUTPUTS, c(named, checkpointed))
ok(length(unwritten) == 0,
   if (length(unwritten)) paste0("declared as an output but nothing the run ",
                                 "reaches writes it: ", paste(unwritten, collapse = ", "))
   else paste0("and every one of the ", length(OUTPUTS),
               " declared outputs is written by code the run reaches"))
clear()
report()
