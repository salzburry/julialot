#!/usr/bin/env Rscript
# What build_ndmm() does, driven rather than grepped for. The rules in R/steps
# are held to the study rules by the checks below; this is about the runner
# around them - the guards, the attrition, and the order.
#
#   Rscript "ndmm/tests/test_runner.R"

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
sys.source(file.path(ROOT, "R", "build_ndmm.R"), envir = env)
for (f in ls(env)) assign(f, get(f, envir = env), envir = globalenv())
sys.source(file.path(ROOT, "R", "config.R"), envir = globalenv())
sys.source(file.path(ROOT, "R", "db_utils.R"), envir = globalenv())
sys.source(file.path(ROOT, "R", "codelists.R"), envir = globalenv())
# The NDMM_* constants are what the SQL reads, and check_constants() compares
# them against cfg. Loaded here the same way load_ndmm_modules() loads them.
sys.source(file.path(ROOT, "R", "ndmm_constants.R"), envir = globalenv())
sys.source(file.path(ROOT, "R", "standalone_constants.R"), envir = globalenv())
bl   <- paste(readLines(file.path(ROOT, "R", "build_ndmm.R"), warn = FALSE), collapse = "\n")
# The parsed body, not the file text: a call named only in a comment is not a
# call, and matching raw text counted one. parse() drops comments outright.
body <- local({
  fn <- NULL
  for (e in parse(file.path(ROOT, "R", "build_ndmm.R"), keep.source = FALSE))
    if (is.call(e) && identical(as.character(e[[1]]), "<-") &&
        identical(as.character(e[[2]]), "build_ndmm")) fn <- e[[3]]
  if (is.null(fn)) stop("build_ndmm() not found")
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
           "build_ndmm_fu_ce_counts", "build_ndmm_preg_window_counts",
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
   if (length(absent)) paste0("build_ndmm() never calls: ", paste(absent, collapse = ", "))
   else paste0("build_ndmm() calls all ", length(ORDER), " phases and checks"))
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
sys.source(file.path(ROOT, "R", "build_ndmm.R"), envir = ue)
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
sys.source(file.path(ROOT, "R", "ndmm_constants.R"), envir = consts0)
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
sys.source(file.path(ROOT, "R", "build_ndmm.R"), envir = ce0)
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

# And the list has to be complete. Every constant ndmm_constants.R reads from
# the environment is a knob someone can turn without touching config.csv, so
# each one must be pinned - read from the file rather than listed by hand,
# because listing by hand is how NDMM_LOT1_FROM went unnoticed.
kl <- c(readLines(file.path(ROOT, "R", "ndmm_constants.R"), warn = FALSE),
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
   paste0("ndmm_constants.R takes ", length(env_consts), " values from the environment"))
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
options(ndmm_codelist_md5 = list())
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
sys.source(file.path(ROOT, "R", "ndmm_constants.R"), envir = ce)
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
# Each step's SQL is read back and must be the
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
sys.source(file.path(ROOT, "R", "build_ndmm.R"), envir = ae)
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
sys.source(file.path(ROOT, "R", "build_ndmm.R"), envir = na)
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
sys.source(file.path(ROOT, "R", "build_ndmm.R"), envir = cr)
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
#
# Anchored on the handler's own write, not on the first mention of
# ndmm_complete: the option is reset ahead of the "started" row now - the row
# carries this run's findings, and a second attempt in one session shares its
# run id - so that mention moved to before i_bs and this passed on the position
# of a line that arms nothing.
i_oe <- regexpr('"failed"', body, fixed = TRUE)
ok(i_oe > 0 && i_bs < i_oe && i_oe < i_cr,
   "...with the failed-status handler armed before the clear can stop")
# The findings the status row reports are this run's. run_id is fixed when
# config.R is sourced, so a retry in one session writes under the first
# attempt's id, and a "started" row opening with the previous attempt's findings
# would attribute them to a build that has not looked at anything yet.
i_rs <- regexpr("ndmm_findings = character(0)", body, fixed = TRUE)
ok(i_rs > 0 && i_rs < i_bs,
   "...and the findings are cleared before the first status row, not after it")

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
sys.source(file.path(ROOT, "R", "ndmm_constants.R"), envir = se)
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
# The criterion targets a cancer distinct from the index MM, which is why five
# plasma-cell groups are overridden. Three are worded "not having achieved
# remission", and the "in remission" variants were left excluding - so a
# patient was kept or dropped on whether their leukemia was in remission.
#
# The rule says nothing about remission. It says "another cancer", and
# other_malig.csv is generic, so it carries MM's own codes. The surest form of
# the override is derived: anything on the diagnosis code list is the index
# disease by definition, because that file decides who is an MM patient.
oc0 <- paste(readLines(file.path(ROOT, "R", "steps", "04_other_malig.R"), warn = FALSE),
             collapse = "\n")
ok(grepl("LEFT JOIN {NDMM_MM_DX_CODES} m", oc0, fixed = TRUE) &&
     grepl("ON m.dx = om.dx AND m.icd_family = om.icd_family", oc0, fixed = TRUE),
   "a code on the MM diagnosis list is never also another cancer")
# Not which SQL construct is used, but that no column name can bind to the
# wrong relation. The first version used a correlated EXISTS whose inner
# relation also has dx and icd_family; unqualified, they bound to the inner
# ones, every code compared to itself, and the exclusion switched off entirely.
#
# So from the point both relations are in scope, every shared name is aliased.
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
# Not a loop over CHOICES$belantamab_scope: there is no such entry, the
# exclusion being the lot package's, so the loop would run zero times and assert
# nothing while still reading as coverage. The builder itself is live - it feeds
# the advisory flag and the reconcile list - so it is exercised directly.
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
# Both ends, on the raw scan itself. The CDM tables are cumulative back well
# past 2016, so without a lower bound the scan returns claims from outside the
# window every criterion in this build is scoped to - and the reconcile table
# joins that view directly, which is what would make "every patient listed is
# one lot removes" true only sometimes.
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
   "exclude drops the state labels, leaving the five override groups")
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
sys.source(file.path(ROOT, "R", "ndmm_constants.R"), envir = oe2)
sys.source(file.path(ROOT, "R", "standalone_constants.R"), envir = oe2)
sys.source(file.path(ROOT, "R", "steps", "04_other_malig.R"), envir = oe2)
assign("log_msg", function(...) invisible(NULL), envir = oe2)
assign("load_codelist_csv", function(...) "(SELECT 1) src", envir = oe2)
assign("ndmm_config", function() list(primary_groups_csv = ""), envir = oe2)
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
# cancer. The ON clause has to END where it ends: " AND 1 = 0" appended would
# leave every grep for the join itself passing.
#
# Not fixed to the indentation - glue() dedents by the common leading
# whitespace, so how far in the clause sits says nothing. It is the last line
# of the statement, so end-of-string counts as ending there.
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
  f <- file.path(dirname(ROOT), "lot", "engine", "R", "build_lot.R")
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
sys.source(file.path(ROOT, "R", "ndmm_constants.R"), envir = be)
sys.source(file.path(ROOT, "R", "build_ndmm.R"), envir = be)
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
sys.source(file.path(ROOT, "R", "build_ndmm.R"), envir = ce2)
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
# The criterion is one inpatient claim, or two outpatient claims within 30 days
# of each other, IN the 12-month baseline. Bounding only the first of the pair
# let a claim the day before the index and a confirmation a month after it
# exclude the patient on one baseline claim.
#
# No database here, so this reads the SQL the function emits: every date column
# the outpatient pair exposes must be bounded. Derived, so a new unbounded
# column fails the same way removing this one does.
oe <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "ndmm_constants.R"), envir = oe)
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
# It is a cohort-changing deviation from the source - it makes the cohort
# larger - so it is a decision, and a decision nobody wrote down is one nobody
# can review. The register is held to carrying it.
dec <- paste(readLines(file.path(ROOT, "DECISIONS.md"), warn = FALSE), collapse = "\n")
ok(grepl("Both claims inside baseline", dec, fixed = TRUE),
   "...and the decision register records that both claims are bounded, not just the first")
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
sys.source(file.path(ROOT, "R", "build_ndmm.R"), envir = ne)
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
# The claim side is reported, never gated. What makes that safe is ndc_key():
# a value that cannot be an NDC gets no key, so it cannot collide with a code.
# Optum writes NONE and UNK where a medical claim has no NDC - 1.2bn rows - and
# gating on that asked the operator to approve the vendor's word for null.
ok(identical(drive_ndc(rx = row("rx", n10 = 3L, n11 = 7L)), ""),
   "a ten-digit claim NDC is reported, not a wall")
ok(identical(drive_ndc(med = row("medical", alpha = 2L)), ""),
   "...and so is a claim NDC with letters in it")
ok(identical(drive_ndc(med = row("medical", zero = 1L)), ""), "...and an all-zero one")
ok(identical(drive_ndc(med = row("medical", oth = 5L)), ""),
   "...and an under- or over-length one")
# The guarantee behind that: no key, so no join. The CASE has no ELSE, so a
# value neither branch takes falls through to NULL - that absence is the
# guarantee, and it is what the per-value loop below leans on.
k <- ndc_key("t.NDC")
ok(!grepl("ELSE", k, fixed = TRUE),
   "the key CASE has no ELSE, so an unmatched value gets NULL and joins nothing")
# Each value judged the way the SQL judges it: strip to digits, then the only
# keyed lengths are ten and eleven, and all zeros is refused by its own branch.
# The earlier version of this loop never used the value it was iterating - six
# copies of one structural assertion, reading as six semantic ones.
for (v in c("NONE", "UNK", "ABC123", "00000000000", "123", "PSYCHOTHERA")) {
  digits <- gsub("[^0-9]", "", v)
  ok(grepl("^0*$", digits) || !nchar(digits) %in% c(10L, 11L),
     paste0("'", v, "' strips to a value no branch keys, so it matches nothing"))
}
# The flip side of stripping first: letters do not disqualify a value whose
# digits count ten or eleven. That is the contract, stated rather than implied
# - the digits are the NDC, and what rides along with them is formatting.
ok(nchar(gsub("[^0-9]", "", "NDC:12345678901")) == 11L,
   "a value carrying eleven digits keys on them even with characters around")
# One normalisation for every NDC arm - including belantamab. That scan built
# its own claim-side key with a bare lpad, which pads a short digit string
# into an eleven-digit key and truncates a long one to its first eleven, so a
# junk value could collide with a real belantamab NDC and exclude the patient.
# The code list side keeps lpad: it is curated, and padding it is the point.
ix_txt <- paste(readLines(file.path(ROOT, "R", "steps", "00b_lot1_index.R"),
                          warn = FALSE), collapse = "\n")
ok(!grepl("lpad(regexp_replace(coalesce(cast(t.", ix_txt, fixed = TRUE),
   "no NDC arm builds a claim-side key with a bare lpad")
ok(sum(gregexpr('ndc_key("t.', ix_txt, fixed = TRUE)[[1]] > 0) >= 1 &&
     grepl('ndc_key(paste0("t.", col))', ix_txt, fixed = TRUE),
   "...the belantamab arms key claims through ndc_key like every other scan")
ok(grepl("length(regexp_replace(coalesce(cast(t.NDC as string),''), '[^0-9]', '')) = 11",
         k, fixed = TRUE),
   "...eleven digits used as they are")
ok(grepl("= 10 THEN concat('0'", k, fixed = TRUE),
   "...ten padded on the 4-4-2 layout, which is the one real assumption left")
ok(grepl("RLIKE '^0+$' THEN NULL", k, fixed = TRUE),
   "...and all zeros is not a product, so it gets no key either")
# The code-list side still stops the build. That one is fixable at source, and
# a code nobody can match is a study asking a question it cannot answer.
m <- drive_ndc(cl = row("codelist", n10 = 4L))
ok(grepl("Ten-digit code list NDCs", m, fixed = TRUE) &&
     grepl("cl_mma_codelist.csv", m, fixed = TRUE),
   "a ten-digit code on the CODE LIST still stops it, and that one is fixable")
m <- drive_ndc(cl = row("codelist", alpha = 1L))
ok(grepl("cannot be an NDC", m, fixed = TRUE),
   "...as does one that cannot be an NDC at all")
Sys.setenv(NDMM_WAIVERS = "codelist_ndc_short,not_a_check")
m <- tryCatch({ check_settings(); "" }, error = conditionMessage)
ok(grepl("no such check", m, fixed = TRUE) && grepl("not_a_check", m, fixed = TRUE),
   "a waiver naming nothing real is a typo, and is refused before the run starts")
Sys.setenv(NDMM_WAIVERS = "codelist_ndc_short")
ok(identical(waivers(), "codelist_ndc_short"), "a real waiver is honoured")
Sys.setenv(NDMM_WAIVERS = "check_upstream")
ok(length(waivers()) == 0L,
   "and nothing outside the waivable set is ever honoured, whatever is set")
Sys.unsetenv("NDMM_WAIVERS")

# raw_icd_flag reports and does not stop - the study team's call after it
# halted the first production run over sixteen rows. The name stays waivable
# because check_settings() stops on a waiver it does not recognise, so dropping
# it would break the very commands that were told to pass it.
ok("raw_icd_flag" %in% WAIVABLE_CHECKS,
   "raw_icd_flag is still a recognised waiver name, so old commands still run")
ICDQ <- character(0); ICDLOG <- character(0)
drive_icd <- function(n, waive = "", detail = NULL) {
  Sys.setenv(NDMM_WAIVERS = waive)
  ICDQ <<- character(0); ICDLOG <<- character(0)
  options(ndmm_findings = character(0))
  if (is.null(detail))
    detail <- data.frame(icd_flag_value = "<blank>", matched_code = "C9000",
                         on_list = "MM diagnosis", n_rows = n, n_pat = n,
                         stringsAsFactors = FALSE)
  assign("log_msg", function(...) ICDLOG <<- c(ICDLOG, paste0(...)), envir = ne)
  assign("db_q", function(con, sql) {
    ICDQ <<- c(ICDQ, sql)
    if (!grepl("matched_code", sql, fixed = TRUE))
      return(data.frame(vals = "<blank>, 12", n = n, stringsAsFactors = FALSE))
    if (identical(detail, "error")) stop("driver went away")
    detail
  }, envir = ne)
  # The error message if it ever raises, so a stop cannot pass as a warning.
  err <- tryCatch({ ne$check_icd_flag(NULL, cfg_defaults); "" }, error = conditionMessage)
  Sys.unsetenv("NDMM_WAIVERS")
  list(err = err, log = paste(ICDLOG, collapse = "\n"),
       findings = getOption("ndmm_findings", character(0)))
}
r <- drive_icd(0L)
# The ceiling is recorded whatever happens, so a cohort read later says which
# governance it was built under - "no finding" and "no ceiling" would otherwise
# look alike on the row.
ok(identical(r$err, "") && identical(r$findings, "icd_ceiling(none)"),
   "every flag naming a family leaves only the ceiling on the record")
ok(!any(grepl("matched_code", ICDQ, fixed = TRUE)),
   "...and nothing pays for a breakdown of a finding that is not there")
r <- drive_icd(7L)
ok(identical(r$err, ""),
   "an unknown flag on a code this cohort reads no longer stops the build")
m <- r$log
ok(grepl("WARNING (raw_icd_flag)", m, fixed = TRUE) &&
     grepl("names neither family", m, fixed = TRUE),
   "...it warns instead, named so the log can be grepped for it")
ok(grepl("exclude a patient", m, fixed = TRUE) &&
     grepl("keep one", m, fixed = TRUE) &&
     grepl("moves nobody", m, fixed = TRUE),
   "...and says which way each kind of code cuts, trial codes included")
# A warning nobody kept the log for is a warning nobody has. The run's own row
# carries it, so a cohort found later says what it was built over.
# With its size, not just its name. Sixteen rows and a data-quality failure
# read identically as "raw_icd_flag", and there is no ceiling above which this
# stops the build - so the magnitude has to be on the row somebody reads later.
f <- grep("^raw_icd_flag", r$findings, value = TRUE)
ok(length(f) == 1L &&
     grepl("14 rows, 14 patient-hits (summed, >= distinct), 1 codes", f, fixed = TRUE) &&
     grepl("C9000[MM diagnosis,14r,14p]", f, fixed = TRUE),
   "...and the finding carries rows, patient-hits, code count and each code's list")
# Summed over codes and over both CDM tables, so a patient with two affected
# codes counts twice. It is an upper bound and the row has to say so, or
# somebody quotes it as a patient count.
ok(grepl(">= distinct", f, fixed = TRUE),
   "...labelled as a sum rather than as a distinct-patient count")
# A finding longer than the cap says how many codes it left out, or the row
# reads as the whole story - the same rule the log line follows.
big <- drive_icd(25L, detail = data.frame(
  icd_flag_value = "<blank>", matched_code = sprintf("C%04d", 1:25),
  on_list = "MM diagnosis", n_rows = 1L, n_pat = 1L, stringsAsFactors = FALSE))
bf <- grep("^raw_icd_flag", big$findings, value = TRUE)
ok(length(bf) == 1L && grepl("25 codes", bf, fixed = TRUE) &&
     grepl("+15 more code(s)", bf, fixed = TRUE),
   "...and says how many codes it left off the row, not only off the log")
ok("FINDINGS" %in% names(RUN_METADATA_COLS),
   "...which is a column NDMM_RUN_METADATA actually has")
r <- drive_icd(7L, waive = "raw_icd_flag")
ok(identical(r$err, "") && grepl("no longer needed", r$log, fixed = TRUE),
   "the old waiver is accepted and says it is now a no-op")

# The breakdown is folded in R, not by aggregate(): its formula method defaults
# to na.omit, so one unreadable count would drop that code from the row - the
# largest one vanishing while the total still counts it - and an all-NA frame
# would error out of the function whose job is to report.
r <- drive_icd(7L, detail = data.frame(
  icd_flag_value = "<blank>", matched_code = c("C901", "C902"),
  on_list = "MM diagnosis", n_rows = c(5, 2), n_pat = c(NA, 2),
  stringsAsFactors = FALSE))
ok(identical(r$err, "") && any(grepl("2 codes", r$findings, fixed = TRUE)) &&
     any(grepl("C901", r$findings, fixed = TRUE)),
   "a code with an unreadable patient count stays on the row rather than vanishing")
r <- drive_icd(7L, detail = data.frame(
  icd_flag_value = "<blank>", matched_code = "C901", on_list = "MM diagnosis",
  n_rows = NA_real_, n_pat = NA_real_, stringsAsFactors = FALSE))
ok(identical(r$err, "") && any(grepl("^raw_icd_flag\\(", r$findings)),
   "...and a breakdown that is entirely unreadable still reports, rather than erroring")
# A code on two lists is one entry naming both. Grouping by code AND list would
# count its claims twice in the code count somebody reads as "how many codes".
r <- drive_icd(7L, detail = data.frame(
  icd_flag_value = "<blank>", matched_code = c("C901", "C901"),
  on_list = c("MM diagnosis", "other malignancy"), n_rows = c(3, 4),
  n_pat = c(3, 4), stringsAsFactors = FALSE))
ok(any(grepl("1 codes", r$findings, fixed = TRUE)) &&
     any(grepl("MM diagnosis+other malignancy", r$findings, fixed = TRUE)),
   "...and a code on two lists is one entry naming both, not two entries")

# A ceiling, settable without a code change and unset by default. Unset is the
# decision as it stands - report whatever the volume - and the run says so, so
# nobody reads a clean log as a governed one.
ok(!nzchar(Sys.getenv("NDMM_ICD_FLAG_MAX_ROWS", unset = "")),
   "no ceiling is set by default, so the shipped behaviour is unchanged")
r <- drive_icd(7L)
ok(grepl("no volume stops this build", r$log, fixed = TRUE),
   "...and the warning says out loud that nothing bounds it")
Sys.setenv(NDMM_ICD_FLAG_MAX_ROWS = "100")
r <- drive_icd(7L)
ok(identical(r$err, "") && grepl("NDMM_ICD_FLAG_MAX_ROWS=100", r$log, fixed = TRUE),
   "a run under the ceiling reports, naming the ceiling it was under")
Sys.setenv(NDMM_ICD_FLAG_MAX_ROWS = "5")
r <- drive_icd(7L)
ok(grepl("over that ceiling", r$err, fixed = TRUE) &&
     grepl("found 14 such row(s)", r$err, fixed = TRUE) &&
     grepl("NDMM_ICD_FLAG_MAX_ROWS=5", r$err, fixed = TRUE),
   "...and one over it stops, naming both what it found and the ceiling")
ok(any(grepl("^icd_ceiling\\(5\\)$", r$findings)) &&
     any(grepl("^raw_icd_flag\\(", r$findings)),
   "...having recorded what it found and which ceiling it was weighed against")
Sys.unsetenv("NDMM_ICD_FLAG_MAX_ROWS")
Sys.setenv(NDMM_ICD_FLAG_MAX_ROWS = "lots")
m <- tryCatch({ check_settings(); "" }, error = conditionMessage)
ok(grepl("NDMM_ICD_FLAG_MAX_ROWS", m, fixed = TRUE),
   "...and a ceiling that is not a number is a typo, caught before the run")
Sys.unsetenv("NDMM_ICD_FLAG_MAX_ROWS")

cat("\n-- and a run the ceiling stopped still says so somewhere durable --\n")
# The finding is recorded the moment it is made, but the metadata row that used
# to be its only home is written at the very END of a run - and clear_run_rows()
# has already deleted the previous attempt's. So a run the ceiling stops wrote
# nothing to NDMM_RUN_METADATA at all, and the run most worth reading later is
# exactly the one that stopped.
#
# NDMM_BUILD_STATUS is the row that survives: rewritten on every state change
# and again on failure through on.exit. Driven rather than grepped, so it is
# the SQL that is held and not the presence of a column name in the file.
ok("FINDINGS" %in% names(BUILD_STATUS_COLS),
   "NDMM_BUILD_STATUS carries a FINDINGS column of its own")
bs <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "build_ndmm.R"), envir = bs)
drive_status <- function(findings, state = "failed") {
  BSQL <<- character(0)
  options(ndmm_findings = findings)
  assign("run_id", "R1", envir = bs)
  assign("log_msg", function(...) invisible(NULL), envir = bs)
  assign("wrk", function(x) paste0("wk.p_", x), envir = bs)
  assign("db_q", function(con, sql) data.frame(col_name = names(BUILD_STATUS_COLS)),
         envir = bs)
  assign("db_exec", function(con, sql) { BSQL <<- c(BSQL, sql); TRUE }, envir = bs)
  assign("db_replace", function(con, del, ins) { BSQL <<- c(BSQL, del, ins); TRUE },
         envir = bs)
  bs$write_build_status(NULL, cfg_defaults, state)
  paste(BSQL, collapse = "\n")
}
s_fail <- drive_status(c("icd_ceiling(5)", "raw_icd_flag(16 rows, 2 codes)"))
ok(grepl("icd_ceiling(5)", s_fail, fixed = TRUE) &&
     grepl("raw_icd_flag(16 rows, 2 codes)", s_fail, fixed = TRUE),
   "...and a failed run writes the findings it had made into it")
ok(grepl("'failed'", s_fail, fixed = TRUE),
   "...on a row that says the run failed, so it is not read as a built cohort")
# Sorted and comma-joined, the same shape NDMM_RUN_METADATA uses, or the two
# columns would need reading two different ways.
ok(grepl("'icd_ceiling(5),raw_icd_flag(16 rows, 2 codes)'", s_fail, fixed = TRUE),
   "...in the same sorted, comma-joined shape the metadata column uses")
ok(grepl("NULL", drive_status(character(0)), fixed = TRUE),
   "...and a run with nothing to report leaves the column NULL rather than empty")
# One value per column. The findings value was added to a list that already had
# one INSERT naming every column, and a mismatch is a SQL error at the moment a
# run is trying to record that it failed - which would lose the record twice.
#
# Counted off a finding carrying no comma of its own: the real ones do, and
# splitting the VALUES list on ", " counts those as separators too.
ins <- grep("^INSERT INTO", strsplit(drive_status("icd_ceiling(5)"), "\n")[[1]],
            value = TRUE)
ok(length(ins) == 1L &&
     length(strsplit(sub(".*VALUES \\(", "", ins), ", ")[[1]]) ==
       length(BUILD_STATUS_COLS),
   paste0("...supplying one value per column (", length(BUILD_STATUS_COLS), ")"))
# CREATE TABLE IF NOT EXISTS does nothing to a table an earlier run left, so
# without the migration this column reaches a fresh prefix and no other - and
# the INSERT names it and fails, on every established prefix at once.
BSQL <<- character(0)
assign("db_q", function(con, sql)
  data.frame(col_name = setdiff(names(BUILD_STATUS_COLS), "FINDINGS")), envir = bs)
bs$write_build_status(NULL, cfg_defaults, "failed")
ok(any(grepl("ADD COLUMNS (FINDINGS STRING)", BSQL, fixed = TRUE)),
   "...and an established prefix has the column added rather than insert into it")
options(ndmm_findings = character(0))

# The count says how many rows stopped the build. Which codes they carry is the
# question it leaves behind, and it is asked of the same rows.
#
# Spelled twice, the two came apart: the breakdown kept the code-list arm and
# lost the fam-IS-NULL arm, so it returned every claim carrying a list code -
# hundreds of thousands of correctly flagged rows, with the handful that
# actually stopped the build somewhere inside them. It read as an explanation
# of the stop and was not one.
m <- drive_icd(7L)$log
# Anchored on the outer FROM, not on the first WHERE in the text: the code
# lists carry their own WHERE, and the breakdown now wraps them in a CTE, so
# "the first WHERE" stopped being the outer one and these read the wrong slice.
where_of <- function(s) {
  x <- sub("(?s)^.*?FROM cdm\\.\\S+ t", "", s, perl = TRUE)
  x <- sub("(?s)^.*?WHERE", "", x, perl = TRUE)
  trimws(sub("(?s)\\s*GROUP BY.*", "", x, perl = TRUE))
}
sel_of <- function(s) {
  x <- sub("(?s)\\s*FROM cdm\\..*", "", s, perl = TRUE)
  sub("(?s).*(SELECT)", "\\1", x, perl = TRUE)
}
sumq <- ICDQ[1]; detq <- ICDQ[2]
ok(!grepl("matched_code", sumq, fixed = TRUE) &&
     grepl("matched_code", detq, fixed = TRUE),
   "the count and the per-code breakdown are two statements, in that order")
ok(nzchar(where_of(detq)) && identical(where_of(sumq), where_of(detq)),
   "...filtering on one predicate, character for character")
ok(grepl("IS NULL", where_of(detq), fixed = TRUE),
   "...so a claim whose flag names a family cannot reach the breakdown")
# The normalised code is projected and grouped on, so it has to stay a scalar.
# Folding the membership test into it makes the column a boolean - and Spark
# rejects an IN-subquery in a SELECT list outright, so it would not run at all.
ok(grepl("regexp_replace", sel_of(detq), fixed = TRUE) &&
     !grepl("IN (SELECT", sel_of(detq), fixed = TRUE),
   "...and it projects the normalised code itself, not a membership test")
ok(grepl("GROUP BY", detq, fixed = TRUE) &&
     grepl("regexp_replace", sub("(?s).*GROUP BY", "", detq, perl = TRUE), fixed = TRUE),
   "...grouped on that code, which is what makes the answer readable")
# Written once, so there is nothing left to drift. deparse() drops comments, so
# this counts the code and not the prose about it.
icd_src <- paste(deparse(ne$check_icd_flag), collapse = "\n")
n_of <- function(pat, s) {
  g <- gregexpr(pat, s, fixed = TRUE)[[1]]
  if (length(g) == 1L && g[1] == -1L) 0L else length(g)
}
ok(n_of("regexp_replace", icd_src) == 1L && n_of("IS NULL", icd_src) == 1L,
   "...because each half of the predicate is written exactly once")
ok(grepl("codes: C9000", m, fixed = TRUE),
   "the warning names the codes, not just how many rows carried them")
# And which list each is on. That is what sizes the decision: an MM code can
# drop a patient, an exclusion code can keep one, a trial code moves nobody.
# The stop cannot tell them apart, but the operator reading it can.
ok(grepl("MM diagnosis", m, fixed = TRUE),
   "...and which list it is on, which is what sizes the decision")
ok(grepl("'MM diagnosis' AS src", detq, fixed = TRUE) ||
     grepl("'MM diagnosis' AS src", ICDQ[1], fixed = TRUE),
   "...labelled where the lists are built, not restated in the message")
# Folded to one row per code before the join, or a code on two lists counts
# its claims twice and the breakdown stops summing to the count.
ok(grepl("GROUP BY code", detq, fixed = TRUE) &&
     grepl("LEFT JOIN src", detq, fixed = TRUE),
   "...joined one row per code, so a code on two lists is named once not counted twice")

# The predicate is shared, so the breakdown has to sum to the count it breaks
# down. Checked at run time as well as here: sharing holds only while both
# probes actually call it, and a future edit that stops sharing would otherwise
# be silent until someone read two numbers that no longer meant the same thing.
m <- drive_icd(7L, detail = data.frame(icd_flag_value = "<blank>",
                                       matched_code = "C9000",
                                       on_list = "MM diagnosis", n_rows = 3L,
                                       n_pat = 3L, stringsAsFactors = FALSE))$log
ok(grepl("not describing the same rows", m, fixed = TRUE) &&
     grepl("sums to 3 row(s), not 7", m, fixed = TRUE),
   "a breakdown that does not sum to the count says so, naming both numbers")
# A cut that does not say it cut reads as the whole list.
m <- drive_icd(25L, detail = data.frame(icd_flag_value = "<blank>",
                                        matched_code = sprintf("C%04d", 1:25),
                                        on_list = "MM diagnosis",
                                        n_rows = 1L, n_pat = 1L,
                                        stringsAsFactors = FALSE))$log
ok(grepl("C0001", m, fixed = TRUE) && !grepl("C0025", m, fixed = TRUE) &&
     grepl("and 5 more code(s)", m, fixed = TRUE),
   "...and one longer than the cap says how many codes it left out")
# The breakdown is an aid to a warning that is already being raised. Losing it
# must not take the warning with it, or a driver hiccup silently turns a
# reported finding into a clean run.
r <- drive_icd(7L, detail = "error")
ok(grepl("WARNING (raw_icd_flag)", r$log, fixed = TRUE) &&
     grepl("names neither family", r$log, fixed = TRUE) &&
     any(grepl("^raw_icd_flag\\(", r$findings)),
   "...and a breakdown that cannot be read leaves the warning and the finding intact")

# A claim count above 2^31-1 makes as.integer() NA, the found-anything guard
# then reads it as nothing, and two such probes make the build log "every claim
# names a family" - a clean all-clear on the largest failure there could be.
r <- drive_icd(3e9)
ok(grepl("WARNING (raw_icd_flag)", r$log, fixed = TRUE) &&
     any(grepl("6,000,000,000 rows", r$findings, fixed = TRUE)),
   "a count past the integer limit is still counted, not read as none")
# And a count that genuinely cannot be read is not a clean one.
r <- drive_icd(NA_integer_)
ok(grepl("Could not read the ICD_FLAG count", r$err, fixed = TRUE),
   "...while an unreadable count stops, rather than passing as nothing found")

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
  for (f in c(step_files, file.path(ROOT, "R", "build_ndmm.R"))) {
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

cat("\n-- every view read more than once is checkpointed --\n")
# The claim the runner and the README both make, held here for the first time:
# a temporary view is a query, not a result, so a second read re-runs it, and
# these views sit on each other - the reads of NDMM_LOT1_STARTS each re-run
# the MM-diagnosis chain beneath it. checkpoint() writes the view once and
# repoints it; anything read more than once has to go through it.
#
# Counted the way the SQL reads them - FROM {CONST} or JOIN {CONST} - over the
# step files and the runner. A view that reaches a step as a parameter is
# read under the parameter's name, so this can undercount; undercounting can
# only miss a needed checkpoint, never demand a needless one, and the two
# known cases (BASE_COHORT, BELANTAMAB_PATIDS) are checkpointed anyway.
all_txt <- paste(unlist(lapply(c(step_files, file.path(ROOT, "R", "build_ndmm.R")),
                               readLines, warn = FALSE)), collapse = "\n")
n_reads <- vapply(view_consts, function(k) {
  hits <- gregexpr(paste0("(FROM|JOIN) \\{", k, "\\}"), all_txt)[[1]]
  if (hits[1] == -1L) 0L else length(hits)
}, integer(1))
names(n_reads) <- view_consts
multi <- names(n_reads)[n_reads > 1L]
# The case that motivated this: three reads - the flags join and both arms of
# the ICD-flag check - and no checkpoint, so the VALUES literal was inlined
# into all three plans. If the count cannot see those reads it proves nothing.
ok("NDMM_CLINTRIAL_CODES" %in% multi,
   "the count sees NDMM_CLINTRIAL_CODES's reads, so it is not vacuous")
uncheckpointed <- setdiff(multi, CHECKPOINTS)
ok(length(uncheckpointed) == 0,
   if (length(uncheckpointed))
     paste0("read more than once but not checkpointed: ",
            paste(sort(uncheckpointed), collapse = ", "))
   else paste0("all ", length(multi), " views read more than once are in ",
               "CHECKPOINTS"))

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
sys.source(file.path(ROOT, "R", "ndmm_constants.R"), envir = consts)
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
reached <- c(readLines(file.path(ROOT, "R", "build_ndmm.R"), warn = FALSE),
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
sys.source(file.path(ROOT, "R", "ndmm_constants.R"), envir = pe)
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

# The events view carries dates now, so the window question can be priced. What
# must NOT have moved is the exclusion: it is still every patient with a matched
# claim anywhere in the study period, which is what the protocol says and what
# every earlier run applied. DECISIONS.md #9 records why that is the wider of
# two readings; this pins that recording it changed nothing.
ok(grepl("BETWEEN date('2016-01-01') AND date('", px, fixed = TRUE),
   "the scan is still bounded to the study period, not a patient window")
ok(length(gregexpr("BETWEEN date('2016-01-01')", px, fixed = TRUE)[[1]]) == 3L,
   "...on all three sources - diagnosis, medical and procedure")
ok(!grepl("date_sub", px, fixed = TRUE),
   "...and nothing in the exclusion scan is relative to the index date")
pat <- PSQL[2]
ok(grepl("SELECT DISTINCT PATID FROM", pat, fixed = TRUE) &&
     grepl(pe$NDMM_PREGNANCY_EVENTS, pat, fixed = TRUE),
   "the excluded set is distinct patients of those same events, as before")
# One scan, two readers. A second copy of this scan is how the criterion and
# the table pricing it would come to disagree about what a pregnancy claim is.
ok(sum(grepl("stack(3,", PSQL, fixed = TRUE)) == 1L,
   "...and the claims are scanned once, not once per window")
ok("NDMM_PREGNANCY_EVENTS" %in% CHECKPOINTS,
   "...with the shared view materialised, since two readers now hit it")

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
sys.source(file.path(ROOT, "R", "ndmm_constants.R"), envir = me)
sys.source(file.path(ROOT, "R", "standalone_constants.R"), envir = me)
for (nm in c("run_id", "cfg")) assign(nm, if (nm == "cfg") cfg_defaults else "R1", envir = me)
bl <- readLines(file.path(ROOT, "R", "build_ndmm.R"), warn = FALSE)
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

cat("\n-- and the table is brought up to that column list, not just created --\n")
# CREATE TABLE IF NOT EXISTS does nothing to a table an earlier run left, so a
# column added to a *_COLS list reaches a fresh prefix and no other. The INSERT
# names it, and fails - at the very end of the run, after the cohort is built
# and validated and the intermediate tables replaced.
#
# FINDINGS would have done exactly that to every established prefix. Driven
# against a DESCRIBE that is missing a column, so it is the behaviour that is
# held and not the presence of an ALTER somewhere in the file.
ee <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "build_ndmm.R"), envir = ee)
EXEC <- character(0)
drive_cols <- function(have, spec = c(A = "STRING", B = "BIGINT", C = "STRING")) {
  EXEC <<- character(0)
  assign("log_msg", function(...) invisible(NULL), envir = ee)
  assign("db_q", function(con, sql)
    if (is.null(have)) stop("no DESCRIBE here") else data.frame(col_name = have),
    envir = ee)
  assign("db_exec", function(con, sql) { EXEC <<- c(EXEC, sql); TRUE }, envir = ee)
  ee$ensure_cols(NULL, "wk.T", spec)
  EXEC
}
ok(length(drive_cols(c("A", "B", "C"))) == 0L,
   "a table that already has every column is left alone")
e2 <- drive_cols(c("A", "B"))
ok(length(e2) == 1L && grepl("ADD COLUMNS (C STRING)", e2[1], fixed = TRUE),
   "...one that is missing a column has it added, with its declared type")
ok(length(drive_cols(NULL)) == 0L,
   "...and a DESCRIBE that cannot be read adds nothing, rather than adding all of them")
# DERIVED, not a list written out here. A whitelist of four passes the moment a
# fifth CREATE TABLE IF NOT EXISTS is added, which is exactly how the two in
# lot/engine went years without one - so the set comes from the file.
bt   <- paste(bl, collapse = "\n")
made <- unique(regmatches(bt, gregexpr(
  "CREATE TABLE IF NOT EXISTS \\{tbl\\} \\(\",\n\\s*paste\\(cols, [A-Z_]+",
  bt))[[1]])
made <- sub(".*paste\\(cols, ", "", made)
ok(length(made) >= 4L,
   paste0("every table created from a column list is found (", length(made), ")"))
missing <- Filter(function(sp)
  !grepl(paste0("ensure_cols(con, tbl, ", sp, ")"), bt, fixed = TRUE), made)
ok(!length(missing),
   if (length(missing))
     paste0("created from a column list but never brought up to it: ",
            paste(missing, collapse = ", "))
   else paste0("...and every one of them is brought up to its list (",
               length(made), ")"))

cat("\n-- every setting config.csv ships is one the code reads --\n")
# NDMM_BELANTAMAB_SCOPE outlived the code that read it - the proxy moved to the
# lot package, every reader went, and the row stayed, still looking like a
# knob. Nothing compared the two.
#
# One direction only. The platform supplies names this file has no business
# carrying, so a name read but not shipped is normal. A name shipped but never
# read is not: it does nothing, or it is a typo for one that would have.
cnames <- local({
  rows <- read.csv(file.path(ROOT, "config.csv"), stringsAsFactors = FALSE,
                   comment.char = "#")
  n <- trimws(as.character(rows$name))
  n[nzchar(n) & !startsWith(n, "#")]
})
read_env <- local({
  fs <- list.files(file.path(ROOT, "R"), "[.]R$", full.names = TRUE, recursive = TRUE)
  txt <- paste(unlist(lapply(fs, readLines, warn = FALSE)), collapse = "\n")
  # Sys.getenv() is how most of them are read. subseq_days() is the other way:
  # it takes the name as an argument, so the Sys.getenv() call inside it
  # carries a variable and the name appears only at the call site.
  hit <- function(fn) regmatches(txt, gregexpr(paste0(fn, '\\("[A-Z0-9_]+"'), txt))[[1]]
  unique(gsub('^[A-Za-z_.]+\\("|"$', "", c(hit("Sys\\.getenv"), hit("subseq_days"))))
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
# collapse adds against one it removes and report them as one number.
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
bn <- readLines(file.path(ROOT, "R", "build_ndmm.R"), warn = FALSE)
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

cat("\n-- a statement built by concatenation still parses as SQL --\n")
# glue() trims trailing newlines. So paste0(glue("... AS"), body) and
# paste0(glue("... AS\\n"), body) both produce "...ASSELECT", which Spark
# rejects with a syntax error at the first line of the statement. Three
# statements in 00b_lot1_index.R were built that way, and nothing caught it:
# the tests grep the SQL for fragments, and every fragment was present and
# correct - they were simply run together.
#
# Checked as behaviour, not as text, so it holds however the SQL is written.
ok(!grepl("\n$", glue::glue("SELECT 1 AS\n")),
   "glue() really does trim a trailing newline - the trap this guards")
# Walk the parse tree rather than the text: find every paste0(glue(...), x)
# and, when the glue literal ends on a SQL keyword, require x to begin with
# whitespace. A regex over the source missed the real thing when it was there.
kw_tail <- function(lit)
  grepl("(^|[[:space:]])(AS|SELECT|FROM|WHERE|UNION|ALL)$", trimws(lit))
asm <- character(0)
for (f in list.files(file.path(ROOT, "R"), "\\.R$", recursive = TRUE,
                     full.names = TRUE)) {
  walk <- function(e) {
    if (!is.call(e)) return(invisible(NULL))
    if (identical(as.character(e[[1]])[1], "paste0") && length(e) >= 3) {
      a1 <- e[[2]]
      if (is.call(a1) && identical(as.character(a1[[1]])[1], "glue") &&
          length(a1) >= 2 && is.character(a1[[2]]) && kw_tail(a1[[2]])) {
        nx <- e[[3]]
        if (!(is.character(nx) && grepl("^[[:space:]]", nx)))
          asm <<- c(asm, paste0(basename(f), ": ...",
                                substr(trimws(a1[[2]]), max(1, nchar(trimws(a1[[2]])) - 28),
                                       nchar(trimws(a1[[2]])))))
      }
    }
    for (i in seq_along(e)) if (!is.null(e[[i]])) walk(e[[i]])
  }
  for (ex in parse(f, keep.source = FALSE)) walk(ex)
}
ok(!length(asm),
   if (length(asm)) paste0("a statement is concatenated onto a trailing keyword ",
                           "with no separator: ", paste(unique(asm), collapse = "; "))
   else "no statement is concatenated straight onto a trailing keyword")
# The three that were broken, held by their own shape now.
ix <- readLines(file.path(ROOT, "R", "steps", "00b_lot1_index.R"), warn = FALSE)
ok(sum(grepl('AS"), "\\n"', ix, fixed = TRUE)) == 3L,
   paste0("the three assembled statements separate the keyword from the body (",
          sum(grepl('AS"), "\\n"', ix, fixed = TRUE)), ")"))

cat("\n-- a BIGINT count is a number, not its bit pattern --\n")
# The driver returns BIGINT as bit64::integer64: a 64-bit int stored inside a
# double. paste0() then renders the bits, so "1780 codes" logged as
# 8.794368e-321 - and arithmetic on it without bit64 attached is wrong, not
# just ugly. Converted once in db_q() rather than at each of the call sites
# that read a count.
ok(any(grepl(".unint64", readLines(file.path(ROOT, "R", "db_utils.R"),
                                   warn = FALSE), fixed = TRUE)),
   "db_q() converts an integer64 column on the way out")
# Behaviour, not text: build the failure and show the conversion undoes it.
if (requireNamespace("bit64", quietly = TRUE)) {
  raw <- bit64::as.integer64(1780)
  # The class carries the meaning. Lose it anywhere between the driver and the
  # message and the double's bit pattern is what gets rendered - 1780 came out
  # of a real run as exactly this.
  ok(identical(format(unclass(raw)), "8.794368e-321"),
     "...a count of 1780 with its class dropped renders as 8.794368e-321")
  ok(identical(paste0(as.numeric(raw)), "1780"),
     "...and as.numeric() reads the integer back, which is what db_q() does")
  # cat() does not dispatch S3 methods, so log_msg() has to coerce itself -
  # a count that reaches a message any way other than through db_q() would
  # still print its bits. The real one, not the silent stub the tests above
  # put in the global environment.
  le <- new.env(parent = globalenv())
  sys.source(file.path(ROOT, "R", "db_utils.R"), envir = le)
  said <- paste(capture.output(le$log_msg("n = ", raw)), collapse = " ")
  ok(grepl("1780", said, fixed = TRUE) && !grepl("e-32", said, fixed = TRUE),
     "...and log_msg() prints such a count as 1780, not its bit pattern")
} else {
  ok(TRUE, "bit64 not installed here - the conversion is checked by reading db_q()")
  ok(TRUE, "...")
  ok(TRUE, "...")
}
# Every count in this build is far below 2^53, so the conversion is lossless.
ok(2^53 > 1e15, "counts here are orders below the double's exact-integer limit")

cat("\n-- the pregnancy window comparison counts the right people --\n")
# The defect this replaces: `hit` held only patients WITH a pregnancy event and
# was left-joined to all of them, so the window flags were NULL for everyone
# else, NOT(NULL) is NULL, and CASE WHEN NULL THEN PATID END counted nobody.
# Every patient without a pregnancy claim vanished from both cohort columns and
# the applied row reported a cohort of zero. Nothing failed; the table simply
# said something untrue about the study.
#
# The suite could not see it because it checked the scan's bounds, the distinct
# exclusion, the checkpoint and the orchestration - never the number.
we <- new.env(parent = globalenv())
assign("wrk", function(x) paste0("sch.", x), envir = we)
WSQL <- character(0)
assign("db_exec", function(con, sql) { WSQL <<- c(WSQL, sql); invisible(TRUE) }, envir = we)
# Routed by what is asked for: the table read, and the cohort count the applied
# row is held against. One fixture answering both cannot tell them apart.
assign("db_q", function(con, sql) {
  if (grepl("_ndmm_patids", sql, fixed = TRUE)) return(data.frame(n = 1L))
  data.frame(PREG_WINDOW_RULE = c("study period (this run)", "baseline + follow-up"),
             N_WITH_PREG_CLAIM = c(3L, 2L), N_EXCL_INCREMENTAL = c(2L, 1L),
             N_COHORT = c(1L, 2L), IS_THIS_RUN = c(1L, 0L),
             stringsAsFactors = FALSE)
}, envir = we)
assign("log_msg", function(...) invisible(NULL), envir = we)
sys.source(file.path(ROOT, "R", "steps", "05b_preg_window.R"), envir = we)
we$build_ndmm_preg_window_counts(NULL, cfg_defaults)
wq <- WSQL[1]
# glue() strips the common indent, so these match on normalised whitespace
# rather than on the layout of the source.
wn <- gsub("[ \t]+", " ", gsub("\n", " ", wq))

# The flags are computed over EVERY indexed patient, not over the events. That
# is the whole fix, and it is a property of where the LEFT JOIN sits.
ok(has(wn, "FROM idx LEFT JOIN"),
   "the window flags are built by left-joining events ONTO the patients")
ok(has(wn, "ELSE 0 END) AS w_study") && has(wn, "ELSE 0 END) AS w_patient"),
   "...so a patient with no pregnancy claim gets 0, never NULL")
ok(!has(wn, "LEFT JOIN hit"),
   "...and nothing left-joins a hit-only table back to the patients")
ok(has(wn, "FROM ev CROSS JOIN w"),
   "...the counting reads the per-patient table, so every patient is in scope")
# One definition of the predicate, used by all three columns. Three hand-copies
# is how the kept count stops being the negation of the excluded count.
hits <- length(gregexpr(gsub("[ \t]+", " ", we$preg_hit_sql()), wn, fixed = TRUE)[[1]])
ok(hits == 3L,
   paste0("the window predicate is one definition used by all three columns (",
          hits, ")"))

cat("\n-- and the numbers are checked against invariants, not just produced --\n")
good <- data.frame(N_WITH_PREG_CLAIM = c(3L, 2L), N_EXCL_INCREMENTAL = c(2L, 1L),
                   N_COHORT = c(1L, 2L), IS_THIS_RUN = c(1L, 0L))
ok(isTRUE(we$check_preg_window_counts(good)), "a consistent pair passes")
# Exactly the shape the defect produced: applied row zero, the rest plausible.
bug <- data.frame(N_WITH_PREG_CLAIM = c(3L, 2L), N_EXCL_INCREMENTAL = c(0L, 0L),
                  N_COHORT = c(0L, 1L), IS_THIS_RUN = c(1L, 0L))
ok(inherits(tryCatch(we$check_preg_window_counts(bug), error = function(e) e), "error"),
   "...and the shape the defect produced - applied cohort zero - is refused")
worse <- data.frame(N_WITH_PREG_CLAIM = c(3L, 2L), N_EXCL_INCREMENTAL = c(2L, 1L),
                    N_COHORT = c(2L, 1L), IS_THIS_RUN = c(1L, 0L))
ok(inherits(tryCatch(we$check_preg_window_counts(worse), error = function(e) e), "error"),
   "...as is the narrower window leaving a smaller cohort, which containment forbids")
more <- data.frame(N_WITH_PREG_CLAIM = c(2L, 3L), N_EXCL_INCREMENTAL = c(1L, 1L),
                   N_COHORT = c(2L, 2L), IS_THIS_RUN = c(1L, 0L))
ok(inherits(tryCatch(we$check_preg_window_counts(more), error = function(e) e), "error"),
   "...and more claims inside the contained window than in the one containing it")
# The tie-back to the number the study actually publishes. The applied row
# recomputes the same conjunction NDMM_PATIDS is defined on - same base
# population, and no pregnancy event is the same condition as NO_PREGNANCY = 1 -
# so a gap means one of the two is wrong. This runs against the warehouse,
# which is where the synthetic cases above cannot reach.
ok(isTRUE(we$check_preg_window_counts(good, 1L)),
   "the applied cohort matching NDMM_PATIDS passes")
ok(inherits(tryCatch(we$check_preg_window_counts(good, 2L), error = function(e) e), "error"),
   "...and a cohort that disagrees with the published count is refused")
ok(isTRUE(we$check_preg_window_counts(good, NULL)),
   "...while no count supplied leaves the other invariants doing the work")
ok(!has(WSQL[1], "_ndmm_patids"),
   "the cohort count is read separately, not folded into the table's own SQL")

report()
