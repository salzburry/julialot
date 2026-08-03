#!/usr/bin/env Rscript
# What build_nndm() does, driven rather than grepped for. The rules in R/steps
# are held to the study rules by the checks below; this is about the runner
# around them - the guards, the attrition, and the order.
#
#   Rscript "nndm/tests/test_runner.R"

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
ORDER <- c("check_settings", "pin_output_schema", "pin_prefix",
           "check_contract",
           "check_choices", "check_constants", "set_lot_config",
           "check_no_active_run", "check_upstream", "write_build_status",
           "clear_run_rows",
           "build_ndmm_mm_dx_codes", "build_ndmm_mm_claim_header",
           "build_ndmm_mm_dx_events", "build_ndmm_mm_qualifying",
           "build_ndmm_demographics", "build_ndmm_base_cohort",
           "build_enrollment_spans_ndmm",
           "build_ndmm_mma_codelist", "check_ndc_shape",
           "build_ndmm_belantamab_codes", "build_ndmm_index_ineligible_codes",
           "build_ndmm_lot1_index", "build_ndmm_index_agents",
           "build_ndmm_therapy_pre_lot1",
           "build_ndmm_other_malig_codes", "build_ndmm_mm_adjacent_groups",
           "build_ndmm_mm_adjacent_codes", "build_ndmm_other_malig_groups",
           "build_ndmm_med_claim_header_and_confinement",
           "build_ndmm_other_malig_pre_lot1", "build_ndmm_other_malig_grain",
           "build_ndmm_preg_codes", "build_ndmm_clintrial_codes",
           "check_icd_flag",
           "build_ndmm_pregnancy_patids", "build_ndmm_belantamab_patids",
           "build_ndmm_flags",
           "build_ndmm_clintrial_flags", "report_ndmm_clintrial",
           "build_ndmm_fu_ce_counts",
           "ndmm_counts",
           "check_attrition_monotonic", "build_ndmm_cohort_table",
           "check_ndmm_cohort", "build_ndmm_belantamab_reconcile",
           "write_attrition",
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
# Inputs are checked before anything is built, or the first missing one
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
# apart, and what lets the steps call wrk() without knowing the prefix.
assign("cfg", pin_prefix(base, "study_a_"), envir = globalenv())
ok(identical(wrk("LOT_LONG"), "hive_metastore.wk.study_a_LOT_LONG"),
   "wrk() prefixes an input table")
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
   "the build depends on no table another build in this folder makes")
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
# each one must be pinned - read from the file rather than listed by hand,
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

cat("\n-- a code list whose icd_family is not one we know stops the run --\n")
# The normalising CASE has no third branch, so an unrecognised family reads as
# ICD10. Both lists are joined to claims on family as well as code, so such a
# row matches nothing: on mm_dx.csv a diagnosis that qualifies nobody, on
# other_malig.csv a cancer code that excludes nobody. Neither errors, neither
# warns, and the cohort is wrong in a direction nothing downstream can see.
ie <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "codelists.R"), envir = ie)
assign("log_msg", function(...) invisible(NULL), envir = ie)
fam <- function(dx, family) {
  df <- data.frame(dx = dx, icd_family = family, stringsAsFactors = FALSE)
  tryCatch({ ie$check_icd_family(df, "mm_dx.csv"); "" }, error = conditionMessage)
}
ok(identical(fam(c("C9000", "2030", "C9001", "20301"),
                 c("10", "9", "ICD-10", "ICD9DIAG")), ""),
   "every spelling either family is written in passes")
ok(nzchar(fam(c("C9000", "2030"), c("ICD9DX", "ICD10"))),
   "one nobody anticipated stops the run rather than reading as ICD10")
# read.csv maps "" to NA here, so an unfilled column and a missing one look the
# same. This is what an unfilled column actually looks like.
ok(nzchar(fam("C9000", NA)) && nzchar(fam("C9000", "   ")),
   "and so does a blank, which is the case that reaches production")
ok(identical(fam(c("C9000", "---"), c("ICD10", NA)), ""),
   "a row with no usable dx is dropped by the build, so it is not an alarm")

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
# Nine: the belantamab exclusion is split, and the half this package can
# see - belantamab before the 1L index - is a step of this funnel. The other
# half is applied over lines in lot. See DECISIONS.md #2.
ok(length(keys) == 9L, paste0("nine steps, one per criterion (", length(keys), ")"))

cat("\n-- the funnel adds the criteria in the study's order --\n")
# ndmm_counts() decides the order the funnel reads in, and no comparison to
# another file can hold that order. What holds it is this:
# each step's SQL is read back and must be the
# step above it plus exactly one flag, in the order the criteria are listed:
# inclusions first, then exclusions.
FLAGS <- c("CE_pre_lot1_12mo", "CE_lot1_fu", "NO_PRIOR_MM_TX",
           "NO_OTHER_CANCER_PRE_LOT1", "NO_PREGNANCY",
           "NO_BELANTAMAB_PRE_LOT1")
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
# Five, not six: the cumulative loop stops one short of the last criterion, and
# the final row reads NDMM_PATIDS rather than spelling the conjunction out. So
# NO_BELANTAMAB_PRE_LOT1, the last criterion, is checked by that row instead.
want <- c("CE_pre_lot1_12mo", "CE_lot1_fu", "NO_PRIOR_MM_TX",
          "NO_OTHER_CANCER_PRE_LOT1", "NO_PREGNANCY")
ok(identical(added, want),
   if (identical(added, want)) "and they arrive in the listed order, pregnancy eighth"
   else paste0("the criteria arrive as ", paste(added, collapse = " -> ")))
# The ADVISORY flag - belantamab anywhere in the study period - still decides
# nothing. Matched with a boundary, or it would find NO_BELANTAMAB_PRE_LOT1,
# which is a criterion and does narrow the last row. See DECISIONS.md #2.
ok(!any(grepl("NO_BELANTAMAB(?!_PRE_LOT1)", CSQL, perl = TRUE)),
   "the whole-study-period belantamab flag narrows no step of this funnel")
ok(grepl(ce$NDMM_PATIDS, CSQL[9], fixed = TRUE),
   "and the last step reads the cohort view rather than repeating the conjunction")
# NDMM_PATIDS's WHERE is generated now, so read the clause rather than the file.
# What the cohort applies is what NDMM_CRITERIA says, and that is what has to
# carry all six flags for the last row to be the one above it plus belantamab.
where <- ndmm_criteria_where()
ok(all(vapply(FLAGS, grepl, logical(1), x = where, fixed = TRUE)),
   paste0("which applies all ", length(FLAGS),
          " flags, so the last row really is the one above it plus belantamab"))
ok(identical(vapply(NDMM_CRITERIA, function(cr) cr$flag, character(1)), FLAGS),
   "and NDMM_CRITERIA holds those flags, in the order the funnel adds them")
fl <- paste(readLines(file.path(ROOT, "R", "steps", "06_flags.R"), warn = FALSE),
            collapse = "\n")
ok(grepl("WHERE {ndmm_criteria_where()}", fl, fixed = TRUE),
   "the cohort view takes its conjunction from that list, not a written-out one")
# The counts take it from the same list. What must not come back is a step file
# writing the conjunction out for itself - two or more criteria tested together
# is a second copy of the rule that decides who is in the cohort. One flag on
# its own is not that: the belantamab reconciliation reads NO_BELANTAMAB to say
# which way the proxy went on each row, which is a label, not a criterion.
step_files <- list.files(file.path(ROOT, "R", "steps"), "[.]R$", full.names = TRUE)
conj <- Filter(Negate(is.null), lapply(step_files, function(p) {
  txt <- paste(readLines(p, warn = FALSE), collapse = "\n")
  hit <- FLAGS[vapply(FLAGS, function(f)
    grepl(paste0(f, "[[:space:]]*=[[:space:]]*[01]"), txt), logical(1))]
  if (length(hit) >= 2L) paste0(basename(p), ": ", paste(hit, collapse = ", "))
}))
ok(length(conj) == 0,
   if (length(conj)) paste0("a step writes the conjunction out again -- ",
                            paste(unlist(conj), collapse = "; "))
   else "and no step file tests two criteria flags together for itself")

cat("\n-- a funnel that grows is not a count --\n")
mk <- function(v) setNames(as.list(v), keys)
ok(is.null(tryCatch({ check_attrition_monotonic(mk(c(100,90,80,70,60,50,40,30,20,10))); NULL },
                    error = conditionMessage)),
   "a funnel that only narrows passes")
msg <- tryCatch({ check_attrition_monotonic(mk(c(100,90,80,70,60,50,55,20,10))); "" },
                error = conditionMessage)
ok(grepl("grows at step 7", msg, fixed = TRUE) &&
     grepl(ATTRITION_STEPS[[7]]$label, msg, fixed = TRUE),
   "a step larger than the one above it stops the build, naming the step")
msg <- tryCatch({ check_attrition_monotonic(mk(c(100,90,80,70,60,50,40,30,0))); "" },
                error = conditionMessage)
ok(grepl("empty", msg, fixed = TRUE),
   "and an empty final cohort is reported rather than published")
ok(!is.null(tryCatch({ check_attrition_monotonic(mk(c(0,0,0,0,0,0,0,0,0,0))); NULL },
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
ae$write_attrition(NULL, list(), mk(c(1000,900,800,700,600,500,400,300,200)))
ins <- grep("INSERT", ASQL, value = TRUE)[1]
ok(!is.na(ins) && length(gregexpr("('R1',", ins, fixed = TRUE)[[1]]) == 9L,
   "nine rows, one per step")
ok(grepl("'Patients with a qualifying MM diagnosis'", ins, fixed = TRUE) &&
     grepl("no pregnancy in study period", ins, fixed = TRUE),
   "labelled by criterion, so the table reads without the code")
ok(grepl(", 300,", ins, fixed = TRUE) && grepl(", 30,", ins, fixed = TRUE),
   "with the count and its percentage of the starting population")
# A DELETE and an INSERT retried apart would double the rows.
ok(any(vapply(AUNITS, function(g) any(grepl("DELETE", g, fixed = TRUE)) &&
                any(grepl("INSERT", g, fixed = TRUE)), logical(1))),
   "cleared and rewritten as one retried unit")
# A count of exactly 100000 renders as 1e+05 through as.character.
ASQL <- character(0); AUNITS <- list()
ae$write_attrition(NULL, list(), mk(c(1e6,1e5,1e5,1e5,1e5,1e5,1e5,1e5,1e5,1e5)))
ins <- grep("INSERT", ASQL, value = TRUE)[1]
ok(!grepl("e+0", ins, fixed = TRUE) && grepl("1000000", ins, fixed = TRUE),
   "counts reach SQL as digits, not as R prints them")

cat("\n-- two runs on one prefix would overwrite each other --\n")
# Not a theoretical hazard: checkpoint() repoints every session view at the
# prefixed table it just replaced, so a second run replaces tables the first is
# reading through. Driven, not read: the whole point is what the function does
# with the rows it gets back.
na <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "build_nndm.R"), envir = na)
assign("log_msg", function(...) invisible(NULL), envir = na)
assign("wrk", function(x) paste0("wk.p_", x), envir = na)
assign("run_id", "R2", envir = na)
NAQ <- character(0)
drive_na <- function(rows) {
  NAQ <<- character(0)
  assign("db_q", function(con, s) { NAQ <<- c(NAQ, s); rows }, envir = na)
  tryCatch({ na$check_no_active_run(NULL, list(object_prefix = "p_")); NULL },
           error = conditionMessage)
}
ok(is.null(drive_na(data.frame(RUN_ID = character(0), UPDATED_AT = character(0)))),
   "a prefix nobody else is building is fine")
ok(any(grepl("STATE = 'started'", NAQ, fixed = TRUE)) &&
     any(grepl("OBJECT_PREFIX = 'p_'", NAQ, fixed = TRUE)) &&
     any(grepl("RUN_ID <> 'R2'", NAQ, fixed = TRUE)) &&
     any(grepl("wk.p_NDMM_BUILD_STATUS", NAQ, fixed = TRUE)),
   "...asked of started runs on this prefix, excluding this one")
msg <- drive_na(data.frame(RUN_ID = "R1", UPDATED_AT = "2026-07-30 09:00:00"))
ok(!is.null(msg) && grepl("R1", msg, fixed = TRUE) &&
     grepl("NDMM_IGNORE_ACTIVE_RUN", msg, fixed = TRUE),
   "another run on the same prefix stops it, named, with the way out")
# A months-old timestamp is how an operator tells a live run from a corpse.
ok(!is.null(msg) && grepl("2026-07-30 09:00:00", msg, fixed = TRUE),
   "...and says when that run started, not just that it did")
# A killed process leaves 'started' behind for ever, so there has to be one.
Sys.setenv(NDMM_IGNORE_ACTIVE_RUN = "TRUE")
ok(is.null(drive_na(data.frame(RUN_ID = "R1", UPDATED_AT = "x"))),
   "...and the override lets a run past a row a dead process left")
Sys.unsetenv("NDMM_IGNORE_ACTIVE_RUN")
ok(!is.null(drive_na(data.frame(RUN_ID = "R1", UPDATED_AT = "x"))),
   "which holds only while it is set")
# No table on a first run, and nothing to collide with.
assign("db_q", function(con, s) stop("TABLE_OR_VIEW_NOT_FOUND"), envir = na)
ok(!inherits(tryCatch(na$check_no_active_run(NULL, list(object_prefix = "p_")),
                      error = function(e) e), "error"),
   "and a first run, with no status table yet, is not blocked by its absence")
# The first thing the run asks the warehouse, and so before it writes its own
# row: a refused run leaves the prefix as it found it, and does not sit through
# twenty input probes first. Against the parsed body rather than ORDER, so
# it holds even if ORDER is reordered to match a runner that no longer does
# this, and against the parsed body rather than the file text, so a mention in
# a comment is not read as a call.
i_na <- regexpr("check_no_active_run(con, cfg)", body, fixed = TRUE)
i_up <- regexpr("check_upstream(con, cfg)", body, fixed = TRUE)
i_bs <- regexpr('write_build_status(con, cfg, "started")', body, fixed = TRUE)
ok(i_na > 0 && i_up > 0 && i_bs > 0 && i_na < i_up && i_na < i_bs,
   "the check runs before this run reads or writes anything else")

cat("\n-- a second attempt does not inherit the first's rows --\n")
# run_id is fixed when config.R is sourced, so a re-run in one session writes
# under the same id. Every writer clears its own rows, but only if reached.
# Which tables those are is derived, not restated: each *_COLS declaring a
# RUN_ID column is a run-scoped table, and the run has to clear all of them.
cr <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "build_nndm.R"), envir = cr)
assign("log_msg", function(...) CRLOG <<- c(CRLOG, paste0(...)), envir = cr)
assign("wrk", function(x) paste0("wk.p_", x), envir = cr)
assign("run_id", "R1", envir = cr)
colsets <- grep("_COLS$", ls(cr), value = TRUE)
scoped  <- vapply(colsets, function(nm) "RUN_ID" %in% names(get(nm, envir = cr)),
                  logical(1))
derived <- paste0("NDMM_", sub("_COLS$", "", colsets[scoped]))
# The name convention is asserted, not assumed: if a *_COLS stops mapping onto
# a declared output, this says so rather than deriving a table nobody writes.
ok(length(derived) >= 4 && all(derived %in% DELIVERABLES),
   "every run-scoped table declares its columns and is a declared deliverable")
# Everything but the status table, whose row for this run is rewritten just
# before this runs - and clearing which would delete the "started" row that
# stops the next run colliding with this one.
ok(setequal(cr$RUN_SCOPED_TABLES, setdiff(derived, "NDMM_BUILD_STATUS")),
   "and every one of them is cleared up front, bar the status row itself")

CRLOG <- character(0); CRSQL <- character(0)
assign("db_exec", function(con, s) { CRSQL <<- c(CRSQL, s); invisible(TRUE) },
       envir = cr)
cr$clear_run_rows(NULL, list())
ok(length(CRSQL) == length(cr$RUN_SCOPED_TABLES) &&
     all(vapply(cr$RUN_SCOPED_TABLES, function(t)
       any(grepl(paste0("DELETE FROM wk.p_", t, " WHERE RUN_ID = 'R1'"),
                 CRSQL, fixed = TRUE)), logical(1))),
   "one delete per table, scoped to this run and nobody else's")

# A first run has none of these tables, and that is not a failure.
CRLOG <- character(0)
assign("db_exec", function(con, s) stop("TABLE_OR_VIEW_NOT_FOUND"), envir = cr)
ok(!inherits(tryCatch(cr$clear_run_rows(NULL, list()), error = function(e) e),
             "error") && length(CRLOG) == 0,
   "a table that does not exist yet is not a failure, and not a warning either")

# But a delete that was refused leaves exactly the rows this exists to remove,
# under this run's id, describing a cohort this run did not build. Warning and
# carrying on published them.
CRLOG <- character(0)
assign("db_exec", function(con, s) stop("PERMISSION_DENIED"), envir = cr)
m <- tryCatch({ cr$clear_run_rows(NULL, list()); "" }, error = conditionMessage)
ok(nzchar(m), "any other failure stops the build rather than warning past it")
ok(length(gregexpr("PERMISSION_DENIED", m, fixed = TRUE)[[1]]) ==
     length(cr$RUN_SCOPED_TABLES) &&
     all(vapply(cr$RUN_SCOPED_TABLES, function(t)
       grepl(paste0("wk.p_", t), m, fixed = TRUE), logical(1))),
   "...naming every table it could not clear, not the first one it hit")

# After the status row, so the run is marked started whatever the clear does,
# and before the first step, so no writer is reached with stale rows in place.
i_cr <- regexpr("clear_run_rows(con, cfg)", body, fixed = TRUE)
i_p1 <- regexpr("build_ndmm_mm_dx_codes(con)", body, fixed = TRUE)
ok(i_cr > 0 && i_p1 > 0 && i_bs < i_cr && i_cr < i_p1,
   "cleared after the status row and before the first phase")
# And the failed-status handler is registered before it, or a stop in the clear
# would leave the status at "started" for ever and check_no_active_run() would
# refuse every later run on the prefix.
i_oe <- regexpr("nndm_complete", body, fixed = TRUE)
ok(i_oe > 0 && i_bs < i_oe && i_oe < i_cr,
   "...with the failed-status handler armed before the clear can stop")

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
# No cohort table from anywhere else. The MM diagnosis, the age gate and the 1L
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
          " days, the window the study fixes"))
ok(grepl("WHERE outpatient_flg = 1", q, fixed = TRUE),
   "...and the pair is built from outpatient claims only")

SSQL <- character(0); se$build_ndmm_base_cohort(NULL)
b <- SSQL[1]
ok(grepl(paste0("(year(f.MM_DX_DT) - m.YRDOB) >= ", se$NDMM_MIN_AGE), b, fixed = TRUE),
   paste0("age is ", se$NDMM_MIN_AGE, " or over in the diagnosis year, by calendar year"))
ok(grepl("ORDER BY q.MM_DX_DT) AS rn", b, fixed = TRUE) &&
     grepl("WHERE rn = 1", b, fixed = TRUE),
   "the earliest qualifying date is the diagnosis date, not the latest")
# The ranking runs first and cannot see age. The other way round,
# and what said so was `sub(".*WITH filtered AS \\(", "", b)` - an extraction
# anchored on a CTE name. Rename the CTE and sub() matches nothing and hands
# back the whole query, which contains the age test wherever it sits, so the
# assertion passed under either behaviour. The split has to have found
# something now, and that is its own assertion rather than a silent fallback.
i_fd <- regexpr("first_dx AS (", b, fixed = TRUE)
ok(i_fd > 0, "the earliest diagnosis is chosen in a step of its own")
pre <- if (i_fd > 0) substring(b, 1, i_fd - 1) else b
ok(i_fd > 0 && grepl("row_number()", pre, fixed = TRUE) &&
     !grepl("YRDOB", pre, fixed = TRUE) &&
     !grepl(se$NDMM_MEMBER_DEMO, pre, fixed = TRUE),
   "...and it is picked before age is known, so 17-then-18 is dropped, not moved")

SSQL <- character(0)
se$build_ndmm_lot1_index(NULL, "cdm.medical", "cdm.rx", "cdm.med_procedure")
x <- SSQL[1]
# Five sources: medical PROC_CD, medical BILL_PROC_CD, medical NDC, rx NDC and
# med_procedure PROC. The last is the program spec's T_MED_PROCEDURE (PROC)
# join to CL_MMA_CODELIST, added so a drug given as a procedure is not missed.
n_arms <- length(gregexpr("INNER JOIN _ndmm_base_cohort b", x, fixed = TRUE)[[1]])
ok(n_arms == 5L,
   paste0("the index is looked for in all five claim sources (", n_arms, ")"))
ok(grepl("cdm.med_procedure t", x, fixed = TRUE) &&
     grepl("cast(t.PROC as string)", x, fixed = TRUE),
   "...including med_procedure, on its PROC column")
ok(length(gregexpr(">= b.MM_DX_DT", x, fixed = TRUE)[[1]]) == 5L,
   "every one of them requires the treatment to be on or after the diagnosis")
ok(length(gregexpr(paste0(">= date('", se$NDMM_LOT1_FROM, "')"), x, fixed = TRUE)[[1]]) == 5L,
   "...and on or after the eligible-treatment cutoff")
ok(length(gregexpr(paste0("<= date('", cfg_defaults$study_end, "')"), x,
                   fixed = TRUE)[[1]]) == 5L,
   "...and inside the study period")
ok(length(gregexpr("WHERE bl.code IS NULL", x, fixed = TRUE)[[1]]) == 5L,
   "an ineligible agent cannot set the index, on every one of the five arms")
ok(grepl("_ndmm_index_ineligible", x, fixed = TRUE),
   "...and the ineligible set is the one build_ndmm_index_ineligible_codes builds")
ok(any(grepl("min(tx_dt) AS LOT1_START_DT", SSQL, fixed = TRUE)),
   "the index is the first such claim, which is how the index is defined")
ok(grepl("_ndmm_mma_codelist", x, fixed = TRUE),
   "and MM treatment means the same code list the prior-therapy scan uses")

cat("\n-- a plasma-cell disorder in remission is not another cancer --\n")
# The other-cancer criterion targets a cancer distinct from the index MM, which
# is why five plasma-cell tumour groups are overridden. Three are worded "not
# having achieved remission", and the source build left the "in remission" variants
# excluding - so an identical patient was kept or dropped depending on whether
# their plasma cell leukemia was in remission.
# The rule says nothing about remission. It says "another cancer" - other
# than the index MM - and other_malig.csv is the study's generic code list, so
# it carries MM's own codes. The override is what makes the criterion mean what
# it says, and the surest form of it is derived: anything on the diagnosis code
# list is the index disease by definition, because that same file decides who
# is an MM patient.
oc0 <- paste(readLines(file.path(ROOT, "R", "steps", "04_other_malig.R"), warn = FALSE),
             collapse = "\n")
ok(grepl("LEFT JOIN {NDMM_MM_DX_CODES} m", oc0, fixed = TRUE) &&
     grepl("ON m.dx = om.dx AND m.icd_family = om.icd_family", oc0, fixed = TRUE),
   "a code on the MM diagnosis list is never also another cancer")
# The rule that matters is not which SQL construct is used but that no column
# name can bind to the wrong relation. The first version put this in a
# correlated EXISTS whose inner relation has columns called dx and icd_family
# too; unqualified, they bound to the inner ones, the predicate compared each
# MM code to itself, and every other-cancer code came back overridden - the
# exclusion switched off entirely, and the test asserted the text of it.
#
# So: from the point the two relations are both in scope, every reference to a
# name they share has to carry an alias.
shared <- c("dx", "icd_family", "tumor_group")
# The final SELECT onward: from there both relations are visible. Inside the om
# CTE only {src} is in scope, so bare names there are unambiguous.
outer <- sub("(?s).*?(SELECT om[.]tumor_group)", "\\1", oc0, perl = TRUE)
outer <- sub('(?s)"\\)\\).*', "", outer, perl = TRUE)
# Comment lines out first. A name in a comment binds to nothing, and leaving
# them in made this fail for prose that explains the very rule it checks -
# which trains people to reword comments instead of qualifying columns.
outer <- paste(grep("^\\s*--", strsplit(outer, "\n")[[1]], value = TRUE,
                    invert = TRUE), collapse = "\n")
bare <- Filter(function(k)
  grepl(paste0("(?<![A-Za-z0-9_.'])", k, "(?![A-Za-z0-9_(])"), outer, perl = TRUE),
  shared)
ok(nchar(outer) > 0 && grepl("LEFT JOIN", outer, fixed = TRUE),
   "the join and the flag are read back out of the statement")
ok(length(bare) == 0,
   if (length(bare))
     paste0("unqualified where both relations are in scope, so it can bind to ",
            "the wrong one: ", paste(bare, collapse = ", "))
   else paste0("every one of ", paste(shared, collapse = "/"),
               " is alias-qualified once both relations are in scope"))
ok(grepl("m.dx = om.dx", oc0, fixed = TRUE),
   "and the join compares normalised values on both sides, not expressions")
# The join has to reach the flag. A LEFT JOIN nothing reads is just a slower
# query with the exclusion still wrong.
ok(grepl("IN ({ovr_in}) OR m.dx IS NOT NULL", oc0, fixed = TRUE),
   "the flag is set by the join as well as by the label list")
ok(grepl("AND regexp_replace(trim(dx), '[^A-Za-z0-9]', '') <> ''", oc0, fixed = TRUE),
   "and a code that is blank once normalised is still dropped before any of it")

cat("\n-- a run choice is a choice, not a redefinition of the cohort --\n")
# CONTRACT is what the cohort is; these are where nothing is settled or the
# data has to answer. Pinning them in CONTRACT was a contradiction - the README
# told the analyst to set them and check_contract() refused the run.
ok(length(intersect(names(CHOICES), names(CONTRACT))) == 0,
   "no setting is both a contract term and a choice")
base_ch <- modifyList(cfg_defaults, list(work_schema = "wk", object_prefix = "p_"))
ok(identical(tryCatch({ check_contract(base_ch); "" }, error = conditionMessage), "") &&
     identical(tryCatch({ check_choices(base_ch); "" }, error = conditionMessage), ""),
   "the shipped settings satisfy both")
for (k in c("mm_adjacent_states")) {
  alt <- setdiff(CHOICES[[k]], base_ch[[k]])[1]
  ok(identical(tryCatch({ check_choices(modifyList(base_ch, setNames(list(alt), k))); "" },
                        error = conditionMessage), ""),
     paste0(k, "='", alt, "' is allowed, so the README's rerun works"))
  m <- tryCatch({ check_choices(modifyList(base_ch, setNames(list("nonsense"), k))); "" },
                error = conditionMessage)
  ok(grepl(k, m, fixed = TRUE) && grepl("nonsense", m, fixed = TRUE),
     paste0("...and a value ", k, " may not take is refused, named"))
}
ok(identical(tryCatch({ check_choices(modifyList(base_ch,
       list(index_excluded_abbrs = "CART,TALQ"))); "" }, error = conditionMessage), ""),
   "naming agents to exclude is allowed - that is what the review table is for")
m <- tryCatch({ check_choices(modifyList(base_ch,
       list(index_excluded_codes = "J9999'; DROP TABLE x; --"))); "" },
     error = conditionMessage)
ok(grepl("would not survive", m, fixed = TRUE),
   "but not something that would not survive being put in a query")
# The allowed values have to be the values the code handles. A list that says
# yes to something the switch says no to is a run that passes its own check and
# then stops inside a step.
for (v in CHOICES$mm_adjacent_states) {
  assign("NDMM_MM_ADJACENT_STATES", v, envir = se)
  # error = conditionMessage would hand back a character string too, which is
  # how this assertion first passed for a value the switch rejects.
  got <- tryCatch(se$ndmm_mm_adjacent_groups(), error = function(e) e)
  ok(!inherits(got, "error") && length(got) >= length(se$NDMM_MM_ADJACENT_OVERRIDE),
     paste0("mm_adjacent_states='", v, "' is one the code actually handles"))
}
assign("NDMM_MM_ADJACENT_STATES", "override", envir = se)
# This used to loop over CHOICES$belantamab_scope. That entry went when the
# exclusion moved to the lot package, so the loop ran zero times and asserted
# nothing while still reading as coverage. The builder itself is still live - it
# feeds the advisory flag and the reconcile list - so it is exercised directly.
SSQL <- character(0)
ok(identical(tryCatch({ se$build_ndmm_belantamab_patids(NULL, "m", "r", "mp"); "" },
                      error = conditionMessage), ""),
   "the belantamab scan still builds, for the advisory flag and the reconcile list")

cat("\n-- belantamab is one whole abbreviation, the same one lot matches --\n")
# A prefix 'BEL%' here and a whole value in lot would let the two
# packages recognised the same drug two different ways. Both are exact now,
# which agrees - and which makes a second spelling on the code list invisible,
# so the builder asks for the neighbours rather than assuming there are none.
be <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "standalone_constants.R"), envir = be)
sys.source(file.path(ROOT, "R", "steps", "00b_lot1_index.R"), envir = be)
for (nm in c("NDMM_MMA_CODELIST", "NDMM_BELANTAMAB_CODES"))
  assign(nm, nm, envir = be)
assign("log_msg", function(...) invisible(NULL), envir = be)
BSQL <- character(0)
# The CREATE goes through db_exec and the checks through db_q, and the
# whole-abbreviation match is in the CREATE - so both have to be recorded or
# the assertion below reads an empty set and passes on nothing.
assign("db_exec", function(con, sql) { BSQL <<- c(BSQL, sql); invisible(TRUE) },
       envir = be)
mk_bela_q <- function(n_codes, others) function(con, sql) {
  BSQL <<- c(BSQL, sql)
  if (grepl("count(*)", sql, fixed = TRUE)) data.frame(n = n_codes)
  else data.frame(med_abbr = others)
}
assign("db_q", mk_bela_q(4L, character(0)), envir = be)
ok(identical(tryCatch({ be$build_ndmm_belantamab_codes(NULL); "" },
                      error = conditionMessage), ""),
   "one abbreviation with codes under it, and nothing else BEL*, is accepted")
ok(any(grepl("upper(trim(med_abbr)) = 'BELA'", BSQL, fixed = TRUE)) &&
     !any(grepl("upper(trim(med_abbr)) LIKE 'BELA'", BSQL, fixed = TRUE)),
   "...matched as a whole abbreviation, not as a pattern")
assign("db_q", mk_bela_q(0L, character(0)), envir = be)
msg <- tryCatch({ be$build_ndmm_belantamab_codes(NULL); "" }, error = conditionMessage)
ok(grepl("No row of cl_mma_codelist.csv has CL_MED_ABBR = 'BELA'", msg, fixed = TRUE),
   "an abbreviation matching no code stops the build, as before")
# The case the exact match introduces: BELA is on the list AND so is another
# spelling. Every row under the other one is missed entirely, and
# both packages agree with each other while both miss it.
assign("db_q", mk_bela_q(4L, c("BELAMAF")), envir = be)
msg <- tryCatch({ be$build_ndmm_belantamab_codes(NULL); "" }, error = conditionMessage)
ok(grepl("'BELAMAF'", msg, fixed = TRUE) && grepl("BELANTAMAB_MED_ABBR", msg, fixed = TRUE),
   "a second BEL* abbreviation stops the build, naming it and lot's setting")
ok(identical(be$NDMM_BELANTAMAB_ABBR, "BELA"),
   "and the default is BELA, which is what lot's CONTRACT pins")

cat("\n-- the belantamab scan is the study period, both ends --\n")
# The upper bound was always here; the lower one was not, and the CDM tables
# are cumulative back well past 2016. So the raw view could return a claim from
# outside the window every criterion in this build is scoped to. The pre-index
# criterion never counted those - it reads NDMM_BELANTAMAB_PATIDS, which used to
# carry its own bound - but the reconcile table joined the raw view and did,
# which made "every patient listed is one lot removes" true only sometimes.
for (nm in c("NDMM_BELANTAMAB_TX", "NDMM_BELANTAMAB_PATIDS", "NDMM_LOT1_STARTS"))
  assign(nm, nm, envir = be)
assign("NDMM_STUDY_START", "2016-01-01", envir = be)
assign("cfg", list(study_end = "2026-03-31"), envir = be)
BSQL <- character(0)
be$build_ndmm_belantamab_patids(NULL, "med", "rx", "mp")
scan_sql <- BSQL[1]; patids_sql <- BSQL[2]
n_lo <- length(gregexpr("date('2016-01-01')", scan_sql, fixed = TRUE)[[1]])
n_hi <- length(gregexpr("date('2026-03-31')", scan_sql, fixed = TRUE)[[1]])
ok(n_lo == 5L && n_hi == 5L,
   paste0("all five claim arms are bounded at both ends (", n_lo, " lower, ",
          n_hi, " upper)"))
# And exactly once, at the source. A second copy in the view that reads it is
# one more place for the two to drift apart.
ok(!grepl("2016-01-01", patids_sql, fixed = TRUE),
   "the view over it does not repeat the bound")
ok(grepl("b.bel_dt < l1.LOT1_START_DT", patids_sql, fixed = TRUE),
   "...it only asks which side of the index the claim falls")

cat("\n-- the handover list is bounded by the patient's own follow-up --\n")
# The study period is not the window lot reads. lot bounds every claim by the
# patient's OBS_END_DT, so a belantamab claim dated after they died is inside
# the study period, would have been in this table, and is invisible to lot -
# listing it overstates what the LOT run is going to remove. Read off
# NDMM_COHORT, which carries ENDDATE, rather than off the flags view.
assign("wrk", function(x) paste0("wk.", x), envir = be)
BSQL <- character(0)
be$build_ndmm_belantamab_reconcile(NULL, list())
rec <- BSQL[1]
ok(grepl("b.bel_dt <= c.ENDDATE", rec, fixed = TRUE),
   "the claim has to fall on or before the patient's ENDDATE")
ok(grepl("FROM wk.NDMM_COHORT c", rec, fixed = TRUE),
   "...which it gets from the cohort table, already carrying its own dates")
# The old shape: flags plus a written-out criteria conjunction. NDMM_COHORT is
# that set with the dates on it, so the join does the same work with less.
ok(!grepl("EXCLUDED_BY_PROXY", rec, fixed = TRUE) &&
     !grepl("NDMM_FLAGS_ALL", rec, fixed = TRUE),
   "and the proxy column and the flags join are both gone")
ok(regexpr("VIEW {NDMM_MM_DX_CODES}", paste(unlist(lapply(step_files, readLines,
             warn = FALSE)), collapse = "\n"), fixed = TRUE) > 0,
   "that list is built by this package, not assumed to exist")

ok(identical(cfg_defaults$mm_adjacent_states, "override"),
   "by default remission variants are overridden too, like their counterparts")
ok(all(grepl("IN REMISSION|IN RELAPSE", se$NDMM_MM_ADJACENT_STATE_LABELS)),
   paste0("the ", length(se$NDMM_MM_ADJACENT_STATE_LABELS),
          " of them are named, not matched by a pattern that could catch more"))
# other_malig.csv carries each plasma-cell condition in three states. Every one
# named here is another state of a condition the override already covers, so
# nothing new is being exempted - only the same disease in a different phase.
stem <- function(x)
  trimws(sub("(NOT HAVING ACHIEVED REMISSION|IN REMISSION|IN RELAPSE)$", "", x))
ok(all(stem(se$NDMM_MM_ADJACENT_STATE_LABELS) %in%
         stem(se$NDMM_MM_ADJACENT_OVERRIDE)),
   "and each names a condition the override already covers in another state")
# The invariant, not a count: a condition overridden in one state is overridden
# in all of them. Half a triple is how the original list came to exclude a
# plasma cell leukemia for being in remission while keeping one that was not.
staged <- se$NDMM_MM_ADJACENT_OVERRIDE[
  grepl("NOT HAVING ACHIEVED REMISSION", se$NDMM_MM_ADJACENT_OVERRIDE, fixed = TRUE)]
missing_state <- unlist(lapply(stem(staged), function(k)
  setdiff(paste(k, c("IN REMISSION", "IN RELAPSE")),
          se$NDMM_MM_ADJACENT_STATE_LABELS)))
ok(length(missing_state) == 0,
   if (length(missing_state)) paste0("overridden in one state but not another: ",
                                     paste(missing_state, collapse = "; "))
   else paste0("every one of the ", length(staged),
               " conditions is overridden in all three of its states"))
assign("NDMM_MM_ADJACENT_STATES", "override", envir = se)
ok(setequal(se$ndmm_mm_adjacent_groups(),
            c(se$NDMM_MM_ADJACENT_OVERRIDE, se$NDMM_MM_ADJACENT_STATE_LABELS)),
   "override covers both halves")
assign("NDMM_MM_ADJACENT_STATES", "exclude", envir = se)
ok(setequal(se$ndmm_mm_adjacent_groups(), se$NDMM_MM_ADJACENT_OVERRIDE),
   "exclude restores the source build's five, so the two can be compared")
assign("NDMM_MM_ADJACENT_STATES", "sometimes", envir = se)
ok(grepl("is not a setting",
         tryCatch({ se$ndmm_mm_adjacent_groups(); "" }, error = conditionMessage),
         fixed = TRUE),
   "and anything else stops the run rather than silently overriding nothing")
assign("NDMM_MM_ADJACENT_STATES", "override", envir = se)
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
for (k in c("%REMISSION%", "%RELAPSE%", "%PLASMACYTOMA%", "%PLASMA CELL%",
            "%GAMMOPATHY%", "%MYELOMA%"))
  ok(grepl(k, g, fixed = TRUE), paste0("...including anything matching ", k))
ok(grepl("max(is_mm_adjacent_override)", g, fixed = TRUE),
   "with whether the override reaches it, which is the question being asked")

# And the codes themselves, so deciding one is reading a table rather than a
# research task. Only the overridden ones: the whole other-cancer code list is
# thousands of rows and would bury the question.
SSQL <- character(0)
assign("db_q", function(con, sql) data.frame(n = 7L), envir = se)
se$build_ndmm_mm_adjacent_codes(NULL, cfg_defaults)
ac <- SSQL[1]
ok(grepl("NDMM_MM_ADJACENT_CODES", ac, fixed = TRUE) &&
     grepl("WHERE is_mm_adjacent_override = 1", ac, fixed = TRUE),
   "the codes kept as the index disease are written out, and only those")
ok(all(vapply(c("DX", "ICD_FAMILY", "OVERRIDE", "TUMOR_GROUP"), function(c0)
        grepl(paste0("AS ", c0), ac, fixed = TRUE), logical(1))),
   "...naming the label that kept each one, which is what decides the next")

cat("\n-- the other-cancer code list, driven --\n")
# Held here, driven, not only compared as text. The mm_dx join sits inside a
# block that suite splices out wholesale before comparing, so breaking it
# stopped being noticed there. Driven, it cannot go quiet again whatever the
# splice covers.
oe2 <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "nndm_constants.R"), envir = oe2)
sys.source(file.path(ROOT, "R", "standalone_constants.R"), envir = oe2)
sys.source(file.path(ROOT, "R", "steps", "04_other_malig.R"), envir = oe2)
assign("log_msg", function(...) invisible(NULL), envir = oe2)
assign("load_codelist_csv", function(...) "(SELECT 1) src", envir = oe2)
assign("nndm_config", function() list(primary_groups_csv = ""), envir = oe2)
assign("db_q", function(con, sql)
  data.frame(n = length(oe2$NDMM_MM_ADJACENT_OVERRIDE)), envir = oe2)
OSQL <- character(0)
assign("db_exec", function(con, sql) { OSQL <<- c(OSQL, sql); invisible(TRUE) },
       envir = oe2)
drive_om <- function() {
  OSQL <<- character(0)
  oe2$build_ndmm_other_malig_codes(NULL)
  OSQL[1]
}
o0 <- drive_om()
# The join that says a code on mm_dx.csv is the index disease, not another
# cancer. The ON clause has to end where it ends: " AND 1 = 0" appended to it
# would leave every grep for the join itself passing.
# Written against the indentation rather than fixed to it: glue() dedents a
# template by its common leading whitespace, so how far in the ON clause sits
# says nothing about the join. What matters is unchanged - the clause is those
# two conditions and ends there, so " AND 1 = 0" appended to it would still
# break this while leaving a grep for the join itself passing. It is now the
# last line of the statement, so end-of-string counts as ending there.
ok(grepl(paste0("LEFT JOIN ", oe2$NDMM_MM_DX_CODES,
                " m[ \t]*\n[ \t]*ON m\\.dx = om\\.dx",
                " AND m\\.icd_family = om\\.icd_family[ \t]*(\n|$)"),
         o0),
   "a code on the MM diagnosis list cannot also make a patient an other-cancer case")
# The label list is the only thing that decides this, so every label in it has
# to reach the query. other_malig.csv carries 1,618 labels over 1,643 codes, so
# naming one picks out a code and a per-code file would say nothing more.
for (lbl in oe2$ndmm_mm_adjacent_groups())
  ok(grepl(paste0("'", lbl, "'"), o0, fixed = TRUE),
     paste0("kept as the index disease: ", lbl))
# Whole-string, not a prefix: SECONDARY MALIGNANT NEOPLASM OF BONE keeps C79.51
# and must not reach C79.52, whose label ends OF BONE MARROW. See DECISIONS.md.
ok(grepl("trim(om.tumor_group) IN (", o0, fixed = TRUE) &&
     !grepl("om.tumor_group LIKE", o0, fixed = TRUE),
   "matched whole, so a longer label naming a different code is not swept in")

cat("\n-- the cohort is a cohort the LOT build can be pointed at --\n")
# The next stage runs the LOT algorithm over these patients, so this table is
# its input. the lot build reads ten columns off whatever cohort it is given, and
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
  cat("  ---- the lot build is not beside this folder; its column list was NOT read\n")
} else {
  ok(setequal(NDMM_COHORT_COLS, lot_req),
     paste0("NDMM_COHORT declares exactly what the lot build requires (",
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
   "the index date is the 1L start, not the MM-diagnosis date")
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
   "only the demographics come over unchanged - they do not move with an anchor")

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
ok(grepl("the lot build", m, fixed = TRUE), "...and so is who needs it")
m <- drive_chk(rows = 12L, pat = 10L)
ok(grepl("fans out", m, fixed = TRUE),
   "a repeated PATID stops it - it would multiply every join a LOT run makes")
m <- drive_chk(noidx = 3L)
ok(grepl("no INDEX_DATE", m, fixed = TRUE),
   "so does a row with no index date, which is the day every window runs from")
m <- drive_chk(backwards = 2L)
ok(grepl("end before they begin", m, fixed = TRUE),
   "a cohort row whose follow-up ends before the index stops the build")
# The floor is NDMM_FU_CE_DAYS, not 1. Criterion 5 requires enrolment through
# index + FU_CE_DAYS, so a patient who passed it has at least that much
# follow-up; a hard-coded 1 stopped the run on a patient the one-day rule
# admits - ENDDATE on the index, from a clamped death or an index on the study
# end. The two definitions of "one day of follow-up" have to be the same one.
m <- drive_chk(nofu = 4L)
ok(grepl("less follow-up than criterion 5", m, fixed = TRUE) &&
     grepl(paste0("FU_DAYS < ", se$NDMM_FU_CE_DAYS), m, fixed = TRUE),
   "...and so does one with less follow-up than criterion 5 asked for")
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
# Two statements now: the claim scan, and the rule over it. Picked by what it
# creates rather than by position, so splitting it again does not silently
# point this at the wrong one.
sql <- grep("outpatient_pairs", OSQL, fixed = TRUE, value = TRUE)[1]
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
   "within 30 days of each other, as the rule is written")
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
   "scoped to the base cohort and back to a year before each diagnosis")
# The belantamab exclusion runs over the whole study period by default, so a
# patient diagnosed in 2025 can have a 2016 NDC the exclusion reads. A profile
# anchored only at the diagnosis would never look at it.
ok(any(grepl("least(date('", NSQL, fixed = TRUE)) &&
     any(grepl("date_sub(b.MM_DX_DT", NSQL, fixed = TRUE)),
   "...or the start of the study if that is earlier, which the exclusion reaches back to")
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
# Read from the runner's own body, not from ORDER: a call added back to the
# runner has to show up here, or the scan would not follow it and the table it
# writes would go unnoticed.
step_fns <- unlist(lapply(step_files, function(f)
  ls(local({ e <- new.env(); suppressWarnings(try(sys.source(f, envir = e), silent = TRUE)); e }))))
called <- Filter(function(nm)
  regexpr(paste0("(?<![A-Za-z0-9_.])", nm, "\\("), body, perl = TRUE) != -1, step_fns)
# And ORDER has to name every one of them, so the phase list cannot fall behind
# the runner it describes.
# ndmm_final_count() reads the funnel's last row out of what ndmm_counts()
# returned. It lives beside it in 07_cohort.R but writes nothing, so ORDER -
# which is the list of steps that build things - does not name it.
extra <- setdiff(called, c(ORDER, "ndmm_final_count"))
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
   else "every table the run names is declared as an output or as an input")
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


cat("\n-- pregnancy reads every column a code could be in --\n")
# The rule covers diagnosis, procedure and revenue codes. BILL_PROC_CD is
# the facility-claim procedure code, and the therapy and SCT scans here
# already read it - pregnancy did not, so a pregnancy HCPCS code populated only
# there kept the patient. Driven, so the arm cannot quietly go away.
pe <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "nndm_constants.R"), envir = pe)
sys.source(file.path(ROOT, "R", "standalone_constants.R"), envir = pe)
sys.source(file.path(ROOT, "R", "steps", "05_pregnancy.R"), envir = pe)
assign("icd_family_sql", function(col, nine, ten)
  paste0("CASE ", col, " WHEN '9' THEN '", nine, "' ELSE '", ten, "' END"), envir = pe)
assign("cfg", cfg_defaults, envir = pe)
PSQL <- character(0)
assign("db_exec", function(con, sql) { PSQL <<- c(PSQL, sql); invisible(TRUE) }, envir = pe)
pe$build_ndmm_pregnancy_patids(NULL, "cdm.med_diagnosis", "cdm.medical", "cdm.med_procedure")
px <- PSQL[1]
ok(grepl("m.BILL_PROC_CD", px, fixed = TRUE) &&
     grepl("s.BILL_PROC_CD", px, fixed = TRUE),
   "the medical scan reads BILL_PROC_CD as well as PROC_CD")
ok(grepl("stack(3,", px, fixed = TRUE),
   "...as a third arm of the one medical pass, not a second scan")
ok(length(gregexpr("'HCPCS',", px, fixed = TRUE)[[1]]) == 2L,
   "...typed HCPCS, the way the therapy scan treats that column")

cat("\n-- a pregnancy code type nothing reads stops the run --\n")
# Every other named thing here stops when it matches nothing. This code list was
# the exemption: a CPT-typed delivery code would load, join, and match zero.
assign("load_codelist_csv", function(...) "(SELECT 1) src", envir = pe)
assign("log_msg", function(...) invisible(NULL), envir = pe)
drive_pc <- function(rows) {
  assign("db_q", function(con, sql) rows, envir = pe)
  tryCatch({ pe$build_ndmm_preg_codes(NULL); "" }, error = conditionMessage)
}
ok(identical(drive_pc(data.frame(code_type = character(0), n = integer(0))), ""),
   "a file whose types the scan all emits passes")
m <- drive_pc(data.frame(code_type = "CPT", n = 12L))
ok(grepl("code type(s) no claim source produces", m, fixed = TRUE) &&
     grepl("CPT", m, fixed = TRUE) && grepl("12", m, fixed = TRUE),
   "one it does not stops the run, naming the type and the count")
ok(grepl("keep those", m, fixed = TRUE),
   "...and says the patients would be kept, which is the failure")
assign("db_q", function(con, sql) stop("no such view"), envir = pe)
ok(grepl("cannot", tryCatch({ pe$build_ndmm_preg_codes(NULL); "" },
                            error = conditionMessage), fixed = TRUE),
   "and a check that could not run is not read as a pass")
ok(setequal(pe$NDMM_PREG_CODE_TYPES,
            c("ICD9DIAG", "ICD10DIAG", "ICD9PROC", "ICD10PROC", "HCPCS", "REV")),
   "the six types the guard allows are the six the scan emits")

cat("\n-- the run-metadata INSERT names as many columns as it supplies --\n")
# A column list and a VALUES list that disagree is a SQL error at the very end
# of a run - after the cohort and the attrition are written, before the run is
# marked complete. Nothing here caught it when BELANTAMAB_SCOPE was removed
# from the values and left in the column list, so count them.
me <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "nndm_constants.R"), envir = me)
sys.source(file.path(ROOT, "R", "standalone_constants.R"), envir = me)
for (nm in c("run_id", "cfg")) assign(nm, if (nm == "cfg") cfg_defaults else "R1", envir = me)
bl <- readLines(file.path(ROOT, "R", "build_nndm.R"), warn = FALSE)
i <- grep("^RUN_METADATA_COLS <- c\\(", bl)
j <- i + which(grepl("\\)\\s*$", bl[i:length(bl)]))[1] - 1L
eval(parse(text = paste(bl[i:j], collapse = "\n")), envir = me)
k <- grep("^write_run_metadata <- function", bl)
l <- k + which(bl[k:length(bl)] == "}")[1] - 1L
body_txt <- paste(bl[k:l], collapse = "\n")
# The VALUES list is the glue string; count its top-level {...} interpolations
vals <- regmatches(body_txt, gregexpr("\\{sql_(text|count)\\(", body_txt))[[1]]
ok(length(me$RUN_METADATA_COLS) == length(vals) + 1L,
   paste0("the INSERT supplies one value per column (", length(vals),
          " interpolated + current_timestamp() vs ",
          length(me$RUN_METADATA_COLS), " columns)"))
ok(!any(grepl("BELANTAMAB_SCOPE", names(me$RUN_METADATA_COLS), fixed = TRUE)),
   "and the scope column went with the setting that fed it")

cat("\n-- every setting config.csv ships is one the code reads --\n")
# NDMM_BELANTAMAB_SCOPE outlived the code that read it: the belantamab claims
# proxy moved to the lot package, every reader went, and the row stayed - still
# describing a proxy that decides nothing, still looking like a knob. Nothing
# here noticed, because nothing compared the two. The lot package has had this
# check; this one did not.
#
# One direction only. The platform supplies names this file has no business
# carrying - DATABRICKS_PWD, the DOMINO_* variables - so a name read but not
# shipped is normal. A name shipped but never read is not: it either does
# nothing, or it is a typo for one that would have.
cnames <- local({
  rows <- read.csv(file.path(ROOT, "config.csv"), stringsAsFactors = FALSE,
                   comment.char = "#")
  n <- trimws(as.character(rows$name))
  n[nzchar(n) & !startsWith(n, "#")]
})
read_env <- local({
  fs <- list.files(file.path(ROOT, "R"), "[.]R$", full.names = TRUE, recursive = TRUE)
  txt <- paste(unlist(lapply(fs, readLines, warn = FALSE)), collapse = "\n")
  unique(gsub('^Sys\\.getenv\\("|"$', "",
              regmatches(txt, gregexpr('Sys\\.getenv\\("[A-Z0-9_]+"', txt))[[1]]))
})
unread <- setdiff(cnames, read_env)
ok(length(unread) == 0,
   if (length(unread)) paste0("config.csv ships settings nothing reads: ",
                              paste(unread, collapse = ", "))
   else paste0("all ", length(cnames), " settings in config.csv are read by R/"))

cat("\n-- metastatic codes group together, primaries pair by category --\n")
# Two outpatient claims for metastases at different sites are still metastatic
# cancer, which the rule excludes on in its own right. Pairing them on site
# would ask for the same metastasis twice, so C78.7 (liver) and C79.51 (bone)
# would never confirm each other.
ok(exists("NDMM_METASTATIC_PREFIXES") && length(NDMM_METASTATIC_PREFIXES) >= 8,
   paste0("a named metastatic prefix list ships (", length(NDMM_METASTATIC_PREFIXES), ")"))
ok(all(c("C77", "C78", "C79", "C7B") %in% NDMM_METASTATIC_PREFIXES),
   "the ICD-10 secondary ranges are in it")
ok(all(c("196", "197", "198") %in% NDMM_METASTATIC_PREFIXES),
   "...and their ICD-9 equivalents")
# C80.0 is disseminated disease; C80.1 is a primary of unknown site and C80.2 is
# a transplant case. A bare "C80" prefix would take all three.
ok("C800" %in% NDMM_METASTATIC_PREFIXES && !("C80" %in% NDMM_METASTATIC_PREFIXES),
   "disseminated disease is C800, not C80 - the other two are not secondary")
ok("1990" %in% NDMM_METASTATIC_PREFIXES && !("199" %in% NDMM_METASTATIC_PREFIXES),
   "...and the same on the ICD-9 side")
msql <- ndmm_metastatic_sql("om.dx")
ok(grepl("om.dx LIKE 'C79%'", msql, fixed = TRUE) &&
     grepl("om.dx LIKE 'C800%'", msql, fixed = TRUE),
   "the predicate matches on prefixes of the stripped code")
ok(length(gregexpr("LIKE", msql, fixed = TRUE)[[1]]) == length(NDMM_METASTATIC_PREFIXES),
   "...one arm per prefix, so adding one to the list is the whole change")
om <- readLines(file.path(ROOT, "R", "steps", "04_other_malig.R"), warn = FALSE)
ok(any(grepl("THEN 'MET'", om, fixed = TRUE)),
   "metastatic codes collapse to one group")
ok(any(grepl("ELSE substr(om.dx, 1, 3) END AS primary_group", om, fixed = TRUE)),
   "...and everything else still pairs on the ICD category")
# The counterfactual has to keep the metastatic codes apart by the prefix each
# matched. Plain substr(dx,1,3) would put C800 back with C80.1 and C80.2 -
# deliberately outside the group - so the difference would net a pair the
# collapse ADDS against one it REMOVES and report them as one number.
ok(any(grepl("{met_own} AS category_group", om, fixed = TRUE)),
   "the counterfactual keeps met codes apart by prefix, not by ICD category")
own <- ndmm_metastatic_own_group_sql("om.dx")
ok(grepl("WHEN om.dx LIKE 'C800%' THEN 'C800'", own, fixed = TRUE),
   "...so C800 stays its own group rather than falling back to C80")
ok(grepl("ELSE substr(om.dx, 1, 3) END", own, fixed = TRUE),
   "...and everything else still falls back to the ICD category")
ok(any(grepl("AS met_prefix", om, fixed = TRUE)),
   "the matched prefix is kept, so the report can attribute by tier")
li <- readLines(file.path(ROOT, "R", "steps", "00b_lot1_index.R"), warn = FALSE)
ok(any(grepl("mets kept apart by prefix", li, fixed = TRUE)),
   "...and the grain table reports both, so the difference is a number")
# A code count says a prefix is represented on the list, not that it excluded
# anybody. These hold one tier out of the collapse and leave the rest
# configured, so the gap is that tier's own contribution in patients.
ok(any(grepl("collapse without C77/196", li, fixed = TRUE)) &&
     any(grepl("collapse without C800/1990", li, fixed = TRUE)),
   "the two watch-list tiers are priced in patients, not just in codes")
ok(any(grepl("grp_wo_nodal", om, fixed = TRUE)) &&
     any(grepl("grp_wo_dissem", om, fixed = TRUE)),
   "...off columns carried for the purpose, so no extra scan of the claims")

cat("\n-- clinical-trial evidence is descriptive, and stays that way --\n")
ct <- readLines(file.path(ROOT, "R", "steps", "08_clintrial.R"), warn = FALSE)
fl <- readLines(file.path(ROOT, "R", "steps", "06_flags.R"), warn = FALSE)
bn <- readLines(file.path(ROOT, "R", "build_nndm.R"), warn = FALSE)
# The whole point: clinical trial does not filter this cohort. The funnel is
# built from NDMM_CRITERIA, so a CLINTRIAL flag reaching that list, or the
# table it reads, would change the cohort silently.
crit_flags <- vapply(NDMM_CRITERIA, function(cr) cr$flag, character(1))
ok(!any(grepl("CLINTRIAL", crit_flags, fixed = TRUE)),
   "no clinical-trial flag is one of the cohort criteria")
ok(!any(grepl("CLINTRIAL", fl, fixed = TRUE)),
   "...and none is joined into NDMM_FLAGS_ALL, where every column is a criterion or feeds one")
# Built after the flags and joining nothing into them: the cohort is the same
# with this step as without it.
ok(regexpr("build_ndmm_flags(", paste(bn, collapse = "\n"), fixed = TRUE) <
     regexpr("build_ndmm_clintrial_flags(", paste(bn, collapse = "\n"), fixed = TRUE),
   "...it is built after the cohort flags, so it cannot feed them")
# The three windows partition the study period; the fourth spans two of them.
# Adding all four double-counts, which is exactly what the broad build's two
# overlapping flags invited.
ok(all(vapply(c("CLINTRIAL_PRE_DX", "CLINTRIAL_DX_TO_LOT1", "CLINTRIAL_POST_LOT1",
                "CLINTRIAL_PRE_LOT1_12MO"),
              function(w) any(grepl(paste0("AS ", w), ct, fixed = TRUE)), logical(1))),
   "the four windows are all cut at the 1L index or the diagnosis")
ok(any(grepl("do not add it to them", ct, fixed = TRUE)),
   "...and the run log says which of them overlap")
# The question the broad build's flags cannot answer: trial evidence between
# the MM diagnosis and the 1L start. Its baseline ends before the diagnosis
# index; its follow-up starts there and runs past LOT1.
ok(any(grepl("m.event_dt >= a.MM_DX_DT", ct, fixed = TRUE)) &&
     any(grepl("m.event_dt <  a.LOT1_START_DT", ct, fixed = TRUE)),
   "the diagnosis-to-1L window is its own column, which is the one that was missing")
ok(any(grepl("AS CLINTRIAL_DAYS_BEFORE_LOT1", ct, fixed = TRUE)),
   "...with the timing, not just a yes/no")
# A missing MM_DX_DT would put a patient in none of the three windows and read
# as no trial evidence anywhere.
ok(any(grepl("have no ", ct, fixed = TRUE)) &&
     any(grepl("MM_DX_DT. The three windows", ct, fixed = TRUE)),
   "a patient with no diagnosis date stops the build rather than reading as clean")
# Same file, same normalisation as the broad build, so a difference between
# the two cohorts is about the window and not about the codes.
ok(any(grepl('load_codelist_csv("clintrial.csv"', ct, fixed = TRUE)),
   "the codes come from clintrial.csv, the file the broad build reads")
ok("clintrial.csv" %in% CODELIST_FILES,
   "...and it is declared, so its md5 is recorded beside the other four")
# An unrecognised ICD flag must match neither family, not default to ICD-10.
ok(!any(grepl("ELSE 'ICD10' END", ct, fixed = TRUE)) &&
     sum(grepl("icd_family_sql(", ct, fixed = TRUE)) >= 2,
   "both ICD sources go through the three-way family rule")

report()
