#!/usr/bin/env Rscript
# What build_nndm() does, driven rather than grepped for. The rules in R/steps
# are held to the protocol by the checks below; this is about the runner
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
           "pin_override_csv", "check_contract",
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
           "build_ndmm_preg_codes",
           "build_ndmm_pregnancy_patids", "build_ndmm_belantamab_patids",
           "build_ndmm_flags", "build_ndmm_belantamab_scope_counts",
           "build_ndmm_fu_ce_counts",
           "ndmm_counts",
           "check_attrition_monotonic", "build_ndmm_cohort_table",
           "check_ndmm_cohort", "build_ndmm_belantamab_reconcile",
           "write_attrition",
           "write_codelist_metadata", "write_run_metadata",
           "report_fillins")
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

cat("\n-- the two files this package ships for filling in --\n")
# Both default to the copy beside the code, so a checkout has a file to edit
# rather than a setting to find out about. Left unpinned they would be "", and
# an unpinned path reads as a file that is not there - which is also what an
# empty file means, so nothing downstream would notice.
FILLINS <- c(mm_adjacent_csv = "mm_adjacent_overrides.csv",
             eligible_1l_csv = "eligible_1l_agents.csv",
             primary_groups_csv = "primary_tumor_groups.csv")
pp <- ce0$pin_override_csv(setNames(as.list(rep("", length(FILLINS))), names(FILLINS)),
                           "/pkg")
ok(all(vapply(names(FILLINS), function(k)
        identical(pp[[k]], file.path("/pkg", "codelists", FILLINS[[k]])), logical(1))),
   paste0("all ", length(FILLINS), " fill-in files default to the copy beside the code"))
pp2 <- ce0$pin_override_csv(setNames(as.list(paste0("/x/", names(FILLINS), ".csv")),
                                     names(FILLINS)), "/pkg")
ok(all(vapply(names(FILLINS), function(k)
        identical(pp2[[k]], paste0("/x/", k, ".csv")), logical(1))),
   "...and the environment wins when it names one")
# A default pointing at nothing is the same as no default.
ok(all(file.exists(file.path(ROOT, "codelists", FILLINS))),
   "...and every one of them is actually in the package")
ok(all(vapply(FILLINS, function(f)
        length(readLines(file.path(ROOT, "codelists", f), warn = FALSE)) == 1L,
        logical(1))),
   "shipped with a header and no rows, so nothing changes until someone fills one in")

cat("\n-- the per-code answer a tumour-group label cannot give --\n")
# SECONDARY MALIGNANT NEOPLASM OF BONE is overridden as MM bone disease, but
# C79.51 is equally a breast primary metastatic to bone. The label cannot tell
# them apart, so a row in mm_adjacent_overrides.csv decides the code. Driven
# through the real loader, on real files: what it does with a malformed row is
# the whole point of it.
OVCSV <- file.path(tmp, "mm_adjacent_overrides.csv")
drive_ov <- function(lines) {
  writeLines(lines, OVCSV)
  tryCatch(load_override_csv(OVCSV), error = conditionMessage)
}
ok(is.null(load_override_csv(file.path(tmp, "nope.csv"))),
   "a file that is not there means the labels decide, and is not a failure")
# Not by clearing the option: other_malig.csv's hash is already in it and the
# metadata test below reads it. Named before and after instead, which also
# proves this call is what added it.
had_ov <- "mm_adjacent_overrides.csv" %in% names(getOption("nndm_codelist_md5", list()))
ok(is.null(drive_ov("dx,icd_family,override,note")),
   "...and neither is the empty file this package ships")
# Absent and empty behave alike but are not alike, and only one is a decision.
ok(!had_ov && "mm_adjacent_overrides.csv" %in% names(getOption("nndm_codelist_md5")),
   "...though the empty one is hashed, so the run says it read it")
got <- drive_ov(c("dx,icd_family,override,note",
                  "C79.51,ICD10,0,breast primary in this cohort",
                  "C9000,9,1,myeloma bone disease"))
ok(is.character(got) && grepl("('C7951', 'ICD10', 0)", got, fixed = TRUE),
   "a listed code reaches the SQL normalised, punctuation stripped")
ok(is.character(got) && grepl("('C9000', 'ICD9', 1)", got, fixed = TRUE),
   "...and its ICD family spelled however the file spelled it")
# Each of these is a typo in a file whose only purpose is to be exact, so it
# stops the run. A dropped row would read as a decision that had been made.
ok(grepl("override must be 0 or 1", drive_ov(c("dx,icd_family,override,note",
   "C7951,ICD10,yes,")), fixed = TRUE),
   "an override that is not 0 or 1 stops the run")
ok(grepl("must say ICD9 or ICD10", drive_ov(c("dx,icd_family,override,note",
   "C7951,ICD11,1,")), fixed = TRUE),
   "an ICD family nobody can act on stops the run")
ok(grepl("blank once punctuation is stripped", drive_ov(c("dx,icd_family,override,note",
   "---,ICD10,1,")), fixed = TRUE),
   "a code that normalises to nothing stops the run, not matches every claim")
ok(grepl("two answers for", drive_ov(c("dx,icd_family,override,note",
   "C7951,ICD10,1,", "C79.51,ICD-10,0,")), fixed = TRUE),
   "and one code given two answers stops the run rather than one winning")
ok(grepl("missing", drive_ov(c("dx,icd_family", "C7951,ICD10")), fixed = TRUE),
   "a file without the columns is refused, not read as empty")

cat("\n-- one label per code is the wrong grain for \"another cancer\" --\n")
# Path B pairs two outpatient claims on a code-list label, and a label is one
# ICD code's description. A cancer at two subsites, or one coded in remission
# and once not, is two labels and never pairs - so the criterion under-detects
# and the cohort is too large, which is the direction that puts patients in a
# study they do not belong in.
PGCSV <- file.path(tmp, "primary_tumor_groups.csv")
drive_pg <- function(lines) {
  writeLines(lines, PGCSV)
  tryCatch(load_primary_groups_csv(PGCSV), error = conditionMessage)
}
ok(is.null(load_primary_groups_csv(file.path(tmp, "nope3.csv"))),
   "no map means each label is its own group, and is not a failure")
ok(is.null(drive_pg("tumor_group,primary_tumor_group,note")),
   "...and neither is the empty file this package ships")
got <- drive_pg(c("tumor_group,primary_tumor_group,note",
                  "breast ca upper outer,BREAST,subsite",
                  "BREAST CA NOS,breast,"))
ok(is.character(got) && grepl("('BREAST CA UPPER OUTER', 'BREAST')", got, fixed = TRUE) &&
     grepl("('BREAST CA NOS', 'BREAST')", got, fixed = TRUE),
   "two labels map onto one group, upper-cased so both sides match")
# The alias columns must not be named after the code list's own, or an
# unqualified reference could bind to the wrong relation - the bug this file
# already had once.
ok(is.character(got) && grepl("AS t(pg_label, pg_primary)", got, fixed = TRUE),
   "...under names nothing in the code list shares")
ok(grepl("must both be filled in", drive_pg(c("tumor_group,primary_tumor_group,note",
   "BREAST, ,")), fixed = TRUE),
   "a half-filled row stops the run rather than mapping a label to nothing")
ok(grepl("two primary groups", drive_pg(c("tumor_group,primary_tumor_group,note",
   "BREAST,A,", "breast,B,")), fixed = TRUE),
   "and one label mapped twice stops the run")

# The grain question is answerable with no map at all, which is the point: an
# empty map cannot size its own absence.
ge <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "nndm_constants.R"), envir = ge)
sys.source(file.path(ROOT, "R", "standalone_constants.R"), envir = ge)
sys.source(file.path(ROOT, "R", "steps", "00b_lot1_index.R"), envir = ge)
assign("log_msg", function(...) invisible(NULL), envir = ge)
assign("wrk", function(x) paste0("wk.p_", x), envir = ge)
GSQL <- character(0)
assign("db_exec", function(con, sql) { GSQL <<- c(GSQL, sql); invisible(TRUE) },
       envir = ge)
assign("db_q", function(con, sql) data.frame(
  GRAIN = c("same code-list label", "as configured", "any label at all"),
  N_EXCLUDED = c(100L, 100L, 140L)), envir = ge)
ge$build_ndmm_other_malig_grain(NULL, cfg_defaults)
gr <- GSQL[1]
ok(grepl("NDMM_OTHER_MALIG_GRAIN", gr, fixed = TRUE) &&
     grepl("'same code-list label'", gr, fixed = TRUE) &&
     grepl("'as configured'", gr, fixed = TRUE) &&
     grepl("'any label at all'", gr, fixed = TRUE),
   "the grain is costed at the finest, the configured and the coarsest grouping")
ok(length(gregexpr("PARTITION BY PATID", gr, fixed = TRUE)[[1]]) == 3L &&
     grepl("PARTITION BY PATID, tumor_group", gr, fixed = TRUE) &&
     grepl("PARTITION BY PATID, primary_group", gr, fixed = TRUE),
   "...each pairing on its own grouping, and the coarsest on none")
# Off the events view, or this would scan med_diagnosis three more times.
ok(!grepl("med_diagnosis", gr, fixed = TRUE) &&
     length(gregexpr("_ndmm_other_malig_events", gr, fixed = TRUE)[[1]]) == 6L,
   "read off the materialised events, not by scanning the claims again")
# The same baseline bounds the criterion uses, or it answers a different question.
ok(length(gregexpr("op.next_dt  BETWEEN", gr, fixed = TRUE)[[1]]) == 3L &&
     grepl("datediff(next_dt, event_dt) <= 30", gr, fixed = TRUE),
   "bounded by the same baseline and the same 30 days as criterion 7")

cat("\n-- which agents may set the 1L index --\n")
# S6.2.1.1 names an eligible-treatment list; Annex 2 is an analysis grouping
# and a stand-alone document, so this build reads one if it is written down and
# otherwise lets any MM therapy set the index.
ELCSV <- file.path(tmp, "eligible_1l_agents.csv")
drive_el <- function(lines) {
  writeLines(lines, ELCSV)
  tryCatch(load_eligible_agents_csv(ELCSV), error = conditionMessage)
}
ok(is.null(load_eligible_agents_csv(file.path(tmp, "nope2.csv"))),
   "no file means any MM therapy can set the index, and is not a failure")
ok(is.null(drive_el("med_abbr,eligible,note")),
   "...and neither is the empty file this package ships")
got <- drive_el(c("med_abbr,eligible,note", "kyp,0,later lines only"))
ok(is.list(got) && identical(got$deny, "KYP") && length(got$allow) == 0,
   "a row of 0 bars an agent and leaves everything else able to set the index")
got <- drive_el(c("med_abbr,eligible,note", "BOR,1,", "len,1,", "KYP,0,"))
ok(is.list(got) && identical(got$allow, c("BOR", "LEN")) &&
     identical(got$deny, "KYP"),
   "...and any row of 1 turns it into an allowlist, upper-cased to match")
ok(grepl("eligible must be 0 or 1", drive_el(c("med_abbr,eligible,note",
   "BOR,maybe,")), fixed = TRUE),
   "an eligible that is not 0 or 1 stops the run")
ok(grepl("med_abbr is blank", drive_el(c("med_abbr,eligible,note",
   " ,1,")), fixed = TRUE),
   "a blank agent stops the run rather than allowing nothing")
ok(grepl("two answers for", drive_el(c("med_abbr,eligible,note",
   "BOR,1,", "bor,0,")), fixed = TRUE),
   "and one agent listed twice stops the run")

# The allowlist is the ineligible view read the other way round, so the scan
# needs no change. Driven, because "only these agents" is the claim.
ie <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "nndm_constants.R"), envir = ie)
sys.source(file.path(ROOT, "R", "standalone_constants.R"), envir = ie)
sys.source(file.path(ROOT, "R", "steps", "00b_lot1_index.R"), envir = ie)
assign("log_msg", function(...) invisible(NULL), envir = ie)
assign("db_q", function(con, sql) data.frame(n = 3L), envir = ie)
IESQL <- character(0)
assign("db_exec", function(con, sql) { IESQL <<- c(IESQL, sql); invisible(TRUE) },
       envir = ie)
drive_ie <- function(el) {
  IESQL <<- character(0)
  assign("nndm_config", function() list(eligible_1l_csv = "x.csv"), envir = ie)
  assign("load_eligible_agents_csv", function(p) el, envir = ie)
  tryCatch({ ie$build_ndmm_index_ineligible_codes(NULL); IESQL[1] },
           error = conditionMessage)
}
i0 <- drive_ie(NULL)
ok(grepl("LIKE 'BEL%'", i0, fixed = TRUE) && !grepl("NOT IN", i0, fixed = TRUE),
   "with no list, only belantamab is barred and nothing is an allowlist")
i1 <- drive_ie(list(allow = character(0), deny = "KYP"))
ok(grepl("LIKE 'KYP'", i1, fixed = TRUE) && !grepl("NOT IN", i1, fixed = TRUE),
   "a deny row bars that agent, the same as the environment variable does")
i2 <- drive_ie(list(allow = c("BOR", "LEN"), deny = character(0)))
ok(grepl("upper(trim(med_abbr)) NOT IN ('BOR', 'LEN')", i2, fixed = TRUE),
   "an allow list makes every agent it does not name ineligible")
ok(grepl("LIKE 'BEL%'", i2, fixed = TRUE),
   "...and belantamab stays barred whatever the list says")
# An allowed agent that is not on the code list bars itself, silently, and its
# patients leave at step 3. That is the opposite failure to the deny case.
assign("db_q", function(con, sql) data.frame(n = 0L), envir = ie)
m <- drive_ie(list(allow = "NOSUCH", deny = character(0)))
ok(is.character(m) && grepl("matches no row", m, fixed = TRUE) &&
     grepl("attrition", m, fixed = TRUE),
   "an allowed agent that is not on the code list stops the run, and says why")

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
# The loader above recorded other_malig.csv for real; the rest are stubbed so
# the completeness check passes and the write can be inspected.
real <- getOption("nndm_codelist_md5", list())
options(nndm_codelist_md5 = modifyList(
  setNames(lapply(CODELIST_FILES, function(f) list(md5 = strrep("b", 32), n_rows = 1L)),
           CODELIST_FILES), real))
MSQL <- character(0)
m <- tryCatch({ me$write_codelist_metadata(NULL, list()); "" }, error = conditionMessage)
ins <- grep("INSERT", MSQL, value = TRUE)[1]
ok(!is.na(ins) && grepl("'other_malig.csv'", ins, fixed = TRUE),
   "every codelist read is written out by name")
ok(!is.na(ins) && grepl(unname(tools::md5sum(file.path(tmp, "other_malig.csv"))),
                        ins, fixed = TRUE),
   "...with the md5 of the file that was actually read")
# All four, not merely some: three of four would still have been published.
full <- setNames(lapply(CODELIST_FILES, function(f)
  list(md5 = strrep("a", 32), n_rows = 5L)), CODELIST_FILES)
options(nndm_codelist_md5 = full)
MSQL <- character(0)
ok(identical(tryCatch({ me$write_codelist_metadata(NULL, list()); "" },
                      error = conditionMessage), ""),
   "all four code lists recorded is what a complete run looks like")
options(nndm_codelist_md5 = full[-2])
m <- tryCatch({ me$write_codelist_metadata(NULL, list()); "" }, error = conditionMessage)
ok(grepl(CODELIST_FILES[2], m, fixed = TRUE) && grepl("not reproducible", m, fixed = TRUE),
   "one missing stops the run, naming the file")
options(nndm_codelist_md5 = modifyList(full, setNames(list(list(md5 = "nope", n_rows = 1L)),
                                                      CODELIST_FILES[1])))
m <- tryCatch({ me$write_codelist_metadata(NULL, list()); "" }, error = conditionMessage)
ok(grepl("not usable", m, fixed = TRUE),
   "...and a hash that is not a hash is not a record of anything")
options(nndm_codelist_md5 = list())
MSQL <- character(0)
m <- tryCatch({ me$write_codelist_metadata(NULL, list()); "" }, error = conditionMessage)
ok(grepl("not reproducible", m, fixed = TRUE),
   "and a run that recorded no hashes stops rather than publishing untraceable counts")
unlink(tmp, recursive = TRUE)

cat("\n-- the run says which rule fill-ins it had --\n")
# Each fill-in already says at the point it is read that it was empty, but that
# is three lines in the middle of a long log, and an empty file reads exactly
# like a path that was never set. A deploy that pointed CODELIST_DIR at
# production and missed these three env vars is the case worth catching.
fe <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "build_nndm.R"), envir = fe)
assign("wrk", function(x) paste0("wk.p_", x), envir = fe)
FLOG <- character(0)
assign("log_msg", function(...) FLOG <<- c(FLOG, paste0(...)), envir = fe)
drive_fill <- function(opt) {
  options(nndm_codelist_md5 = opt); FLOG <<- character(0)
  r <- fe$report_fillins(list()); list(r = r, log = paste(FLOG, collapse = "\n"))
}
ok(length(fe$FILLIN_FILES) == 3 &&
     all(c("eligible_1l_agents.csv", "mm_adjacent_overrides.csv",
           "primary_tumor_groups.csv") %in% names(fe$FILLIN_FILES)),
   "the three files that decide an open rule are the three it reports on")

all_in <- drive_fill(list(
  eligible_1l_agents.csv    = list(md5 = "aa11", n_rows = 42L),
  mm_adjacent_overrides.csv = list(md5 = "bb22", n_rows = 7L),
  primary_tumor_groups.csv  = list(md5 = "cc33", n_rows = 310L)))
ok(length(all_in$r$empty) == 0 && length(all_in$r$used) == 3 &&
     grepl("3 supplied, 0 empty", all_in$log, fixed = TRUE),
   "a run with all three supplied says so, with each row count and hash")
ok(!grepl(">", all_in$log, fixed = TRUE),
   "...and raises nothing, so the marker means something when it appears")

none_in <- drive_fill(list(
  eligible_1l_agents.csv    = list(md5 = "d41d8", n_rows = 0L),
  mm_adjacent_overrides.csv = list(md5 = "d41d8", n_rows = 0L),
  primary_tumor_groups.csv  = list(md5 = "d41d8", n_rows = 0L)))
ok(length(none_in$r$empty) == 3 &&
     grepl("0 supplied, 3 empty", none_in$log, fixed = TRUE),
   "a run on the shipped placeholders says that, once, at the end")
ok(all(vapply(unname(unlist(fe$FILLIN_FILES)), grepl, logical(1),
              x = none_in$log, fixed = TRUE)),
   "...naming what each empty file leaves the build doing instead")
ok(grepl("NDMM_CODELIST_METADATA", none_in$log, fixed = TRUE),
   "...and where to check the paths it actually read")

# Read-and-empty is a decision; never-read is a deploy that did not reach the
# file. write_codelist_metadata() stops on the second, so this says which.
mixed <- drive_fill(list(eligible_1l_agents.csv = list(md5 = "aa11", n_rows = 42L),
                         mm_adjacent_overrides.csv = list(md5 = "d41d8", n_rows = 0L)))
ok(grepl("1 supplied, 2 empty", mixed$log, fixed = TRUE) &&
     grepl("primary_tumor_groups.csv: NOT READ", mixed$log, fixed = TRUE) &&
     grepl("mm_adjacent_overrides.csv: empty", mixed$log, fixed = TRUE),
   "and a file never read is told apart from one read and empty")

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
# the line-for-line comparison holds nothing here. What holds it is this:
# each step's SQL is read back and must be the
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
# twenty upstream probes first. Against the parsed body rather than ORDER, so
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
ok(grepl(paste0("(year(f.MM_DX_DT) - m.YRDOB) >= ", se$NDMM_MIN_AGE), b, fixed = TRUE),
   paste0("age is ", se$NDMM_MIN_AGE, " or over in the diagnosis year, by calendar year"))
ok(grepl("ORDER BY q.MM_DX_DT) AS rn", b, fixed = TRUE) &&
     grepl("WHERE rn = 1", b, fixed = TRUE),
   "the earliest qualifying date is the diagnosis date, not the latest")
# The ranking runs first and cannot see age. It used to be the other way round,
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
# having achieved remission", and the source build left the "in remission" variants
# excluding - so an identical patient was kept or dropped depending on whether
# their plasma cell leukemia was in remission.
# The protocol says nothing about remission. It says "another cancer" - other
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
# CONTRACT is what the cohort is; these are where the protocol is silent or the
# data has to answer. Pinning them in CONTRACT was a contradiction - the README
# told the analyst to set them and check_contract() refused the run.
ok(length(intersect(names(CHOICES), names(CONTRACT))) == 0,
   "no setting is both a contract term and a choice")
base_ch <- modifyList(cfg_defaults, list(work_schema = "wk", object_prefix = "p_"))
ok(identical(tryCatch({ check_contract(base_ch); "" }, error = conditionMessage), "") &&
     identical(tryCatch({ check_choices(base_ch); "" }, error = conditionMessage), ""),
   "the shipped settings satisfy both")
for (k in c("belantamab_scope", "mm_adjacent_states")) {
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
for (v in CHOICES$belantamab_scope) {
  assign("NDMM_BELANTAMAB_SCOPE", v, envir = se)
  SSQL <- character(0)
  ok(identical(tryCatch({ se$build_ndmm_belantamab_patids(NULL, "m", "r"); "" },
                        error = conditionMessage), ""),
     paste0("belantamab_scope='", v, "' is one the code actually handles"))
}
assign("NDMM_BELANTAMAB_SCOPE", "study_period", envir = se)
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

# And the codes themselves, in the shape mm_adjacent_overrides.csv wants, so
# deciding one is a copy and an edit. Only the overridden ones: the whole
# other-cancer code list is thousands of rows and would bury the question.
SSQL <- character(0)
assign("db_q", function(con, sql) data.frame(n = 7L), envir = se)
se$build_ndmm_mm_adjacent_codes(NULL, cfg_defaults)
ac <- SSQL[1]
ok(grepl("NDMM_MM_ADJACENT_CODES", ac, fixed = TRUE) &&
     grepl("WHERE is_mm_adjacent_override = 1", ac, fixed = TRUE),
   "the codes kept as the index disease are written out, and only those")
ok(all(vapply(c("DX", "ICD_FAMILY", "OVERRIDE"), function(c0)
        grepl(paste0("AS ", c0), ac, fixed = TRUE), logical(1))),
   "...under the column names the overrides CSV uses, so it pastes in")

cat("\n-- the other-cancer code list, driven --\n")
# Held here, driven, not only compared as text. The mm_dx join sits
# inside a block that suite splices out wholesale before comparing, so once the
# block grew to take in the overrides join, breaking the mm_dx join stopped
# being noticed there. Driven, it cannot go quiet
# again whatever the splice covers.
oe2 <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "nndm_constants.R"), envir = oe2)
sys.source(file.path(ROOT, "R", "standalone_constants.R"), envir = oe2)
sys.source(file.path(ROOT, "R", "steps", "04_other_malig.R"), envir = oe2)
assign("log_msg", function(...) invisible(NULL), envir = oe2)
assign("load_codelist_csv", function(...) "(SELECT 1) src", envir = oe2)
assign("nndm_config", function()
  list(mm_adjacent_csv = "x.csv", primary_groups_csv = ""), envir = oe2)
assign("db_q", function(con, sql)
  data.frame(n = length(oe2$NDMM_MM_ADJACENT_OVERRIDE)), envir = oe2)
OSQL <- character(0)
assign("db_exec", function(con, sql) { OSQL <<- c(OSQL, sql); invisible(TRUE) },
       envir = oe2)
drive_om <- function(frag) {
  OSQL <<- character(0)
  assign("load_override_csv", function(path) frag, envir = oe2)
  oe2$build_ndmm_other_malig_codes(NULL)
  OSQL[1]
}
o0 <- drive_om(NULL)
# The join that says a code on mm_dx.csv is the index disease, not another
# cancer. The ON clause has to end where it ends: " AND 1 = 0" appended to it
# would leave every grep for the join itself passing.
# Written against the indentation rather than fixed to it: glue() dedents a
# template by its common leading whitespace, so how far in the ON clause sits
# says nothing about the join. What matters is unchanged - the clause is those
# two conditions and ends there, so " AND 1 = 0" appended to it would still
# break this while leaving a grep for the join itself passing.
ok(grepl(paste0("LEFT JOIN ", oe2$NDMM_MM_DX_CODES,
                " m[ \t]*\n[ \t]*ON m\\.dx = om\\.dx",
                " AND m\\.icd_family = om\\.icd_family[ \t]*\n"),
         o0),
   "a code on the MM diagnosis list cannot also make a patient an other-cancer case")
# No file, no join: an empty VALUES list is not valid SQL, and a join matching
# nothing would read as a file that had been consulted.
ok(!grepl("ovr.override", o0, fixed = TRUE) &&
     !grepl("LEFT JOIN (SELECT", o0, fixed = TRUE),
   "with no overrides file, nothing about overrides reaches the query")
o1 <- drive_om("(SELECT * FROM (VALUES ('C7951', 'ICD10', 0)) AS t(dx, icd_family, override)) ovr")
ok(grepl("WHEN ovr.override IS NOT NULL THEN ovr.override ", o1, fixed = TRUE) &&
     grepl("ON ovr.dx = om.dx AND ovr.icd_family = om.icd_family", o1, fixed = TRUE),
   "and with one, the listed code is joined and asked first")
# First, or the label would win and the file would be decoration.
ok(regexpr("ovr.override IS NOT NULL", o1, fixed = TRUE) <
     regexpr("trim(om.tumor_group) IN", o1, fixed = TRUE),
   "...before the tumour-group label, which is the whole point of listing it")

cat("\n-- what the follow-up CE window costs, at each reading of it --\n")
# FU_CE_DAYS=0 is the one setting here resting on a relay rather than a
# document. Nobody can sign it off against a number nobody has, so the run
# produces the number. The windows are derived from the configured value, so
# the table always contains the row this run used, whatever it is set to.
for (d in c(0L, 45L, 90L)) {
  assign("NDMM_FU_CE_DAYS", d, envir = se)
  w <- se$ndmm_fu_ce_windows()
  ok(d %in% w && all(c(0L, 90L) %in% w) && !is.unsorted(w) && !any(duplicated(w)),
     paste0("with FU_CE_DAYS=", d, " the windows are ", paste(w, collapse = "/"),
            " - this run's and the protocol's, once each"))
}
assign("NDMM_FU_CE_DAYS", 0L, envir = se)
SSQL <- character(0)
assign("db_q", function(con, sql) data.frame(
  FU_CE_RULE = c("0 days", "90 days"), N_PASSING_CRITERION_5 = c(900L, 700L),
  N_COHORT = c(500L, 400L), IS_THIS_RUN = c(1L, 0L)), envir = se)
se$build_ndmm_fu_ce_counts(NULL, cfg_defaults)
fc <- SSQL[1]
ok(grepl("NDMM_FU_CE_COUNTS", fc, fixed = TRUE) &&
     grepl("(0, '0 days', cast(NULL as int))", fc, fixed = TRUE) &&
     grepl("(90, '90 days', cast(NULL as int))", fc, fixed = TRUE),
   "every window is counted in one pass, including the protocol's")
# The build takes a day count, so "3 months" is applied as 90 days. The exact
# reading lands 0-2 days later, and the difference should be a number.
ok(grepl("add_months(idx.LOT1_START_DT, w.months)", fc, fixed = TRUE) &&
     grepl("'3 months (exact)'", fc, fixed = TRUE),
   "...and the exact 3-month reading beside it, which days cannot express")
# The same three bounds the flag itself uses, or this would answer a different
# question from the criterion it is about.
ok(grepl("least(CASE WHEN w.months IS NULL", fc, fixed = TRUE) &&
     grepl("coalesce(idx.DEATH_DT", fc, fixed = TRUE) &&
     grepl("_ndmm_enroll_spans_strict", fc, fixed = TRUE),
   "bounded by death and the study end, on no-gap spans, as criterion 5 is")
# A criterion count alone would not say what the choice costs the cohort. Every
# criterion but the one this table varies has to be in that conjunction, and it
# comes from NDMM_CRITERIA - so a criterion added to the cohort lands here too
# instead of leaving the row too large.
ok(grepl(ndmm_criteria_where(except = "CE_lot1_fu", alias = "f."), fc,
         fixed = TRUE) &&
     grepl("AS N_COHORT", fc, fixed = TRUE),
   "and the whole conjunction, so each row is a cohort size not a criterion count")
ok(!grepl("f.CE_lot1_fu", fc, fixed = TRUE),
   "...with the follow-up CE taken from cov.CE_fu, the window this row is about")
ok(grepl(paste0("cov.sort_key = ", se$NDMM_FU_CE_DAYS), fc, fixed = TRUE),
   "with the row this run actually applied marked, so the table reads alone")

cat("\n-- what \"belantamab in any LOT\" is taken to mean --\n")
# Lines of therapy do not exist when this runs - the LOT algorithm runs over
# the cohort this build produces - so the exclusion is a claims proxy, and
# the source build's proxy had no lower bound at all: a claim from before the study
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
# Each source only matches the code types it can carry. Without it a PROC_CD
# matches an NDC row once both are stripped to alphanumerics, and an NDC
# matches an HCPCS row once both are stripped to digits - excluding a patient
# for a belantamab claim they never had. The other scans always did this.
ok(length(gregexpr("c.code_type", r$tx, fixed = TRUE)[[1]]) == 4L,
   "every belantamab arm constrains the code type, as the other scans do")
ok(grepl("c.code_type IN ('HCPCS','CPT')", r$tx, fixed = TRUE) &&
     grepl("c.code_type IN ('HCPCS')", r$tx, fixed = TRUE) &&
     length(gregexpr("c.code_type = 'NDC'", r$tx, fixed = TRUE)[[1]]) == 2L,
   "PROC_CD to HCPCS/CPT, BILL_PROC_CD to HCPCS, both NDC columns to NDC")
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
                                             N_PATIENTS = c(120L, 118L, 90L),
                                             N_COHORT = c(400L, 402L, 430L),
                                             IS_THIS_RUN = c(0L, 1L, 0L)), envir = se)
se$build_ndmm_belantamab_scope_counts(NULL, cfg_defaults)
sc <- SSQL[1]
ok(grepl("NDMM_BELANTAMAB_SCOPE_COUNTS", sc, fixed = TRUE),
   "the three readings are counted into a table every run")
# Against the row list, not the whole statement: every reading also appears in
# the CTE that builds the sets, so grepping the statement would pass with a
# reading dropped from what is actually reported.
sp_line <- grep("sp AS (SELECT", strsplit(sc, "\n")[[1]], fixed = TRUE, value = TRUE)[1]
for (k in c("'ever'", "'study_period'", "'from_index'"))
  ok(!is.na(sp_line) && grepl(k, sp_line, fixed = TRUE),
     paste0("...including ", k))
ok(length(gregexpr("SELECT 'ever' AS SCOPE, b.PATID", sc, fixed = TRUE)[[1]]) == 1L &&
     grepl("count(DISTINCT scd.PATID)", sc, fixed = TRUE),
   "by patients, so the numbers can be compared against the attrition")
# A claim count alone does not say what the choice costs: some of the patients
# a wider proxy catches were already gone on another criterion.
ok(grepl(ndmm_criteria_where(except = "NO_BELANTAMAB", alias = "f."), sc,
         fixed = TRUE) &&
     grepl("AS N_COHORT", sc, fixed = TRUE) &&
     grepl("_ndmm_flags_all", sc, fixed = TRUE),
   "...and the whole conjunction beside it, so each row is a cohort size")
ok(!grepl("f.NO_BELANTAMAB", sc, fixed = TRUE),
   "...with belantamab taken from this row's own reading, not the flag")
ok(grepl(paste0("sp.SCOPE = '", se$NDMM_BELANTAMAB_SCOPE, "'"), sc, fixed = TRUE),
   "with the reading this run applied marked, so the table reads alone")

# "In any LOT" is exact only once lines exist, which is after this build. So
# the run emits what the reconciliation needs rather than claiming to be exact.
SSQL <- character(0)
assign("db_q", function(con, sql) data.frame(n_kept = 3L, n_dropped = 2L,
                                             n_pat = 5L, n_claims = 7L), envir = se)
se$build_ndmm_belantamab_reconcile(NULL, cfg_defaults)
rc <- SSQL[1]
ok(grepl("NDMM_BELANTAMAB_RECONCILE", rc, fixed = TRUE) &&
     grepl("_ndmm_belantamab_tx", rc, fixed = TRUE),
   "the patients still to adjudicate carry their own belantamab claims")
# Read off the flags, not the cohort. The cohort is what the proxy let through,
# so a table built from it cannot show a patient the proxy removed - and
# over-exclusion is the error that costs patients. Both sides have to be here or
# an empty result reads as "exact" when it only means "nobody kept has a claim".
ok(grepl("_ndmm_flags_all", rc, fixed = TRUE) &&
     !grepl("NDMM_COHORT", rc, fixed = TRUE),
   "read off the flags, so a patient the proxy excluded can still appear")
ok(grepl("AS EXCLUDED_BY_PROXY", rc, fixed = TRUE),
   "...and each row says which way the proxy went, so the two are told apart")
# Every other criterion passing, or the table fills with patients a second
# criterion had already removed - whose belantamab claim decides nothing.
ok(grepl(ndmm_criteria_where(except = "NO_BELANTAMAB", alias = "f."), rc,
         fixed = TRUE),
   "...scoped to patients whose membership turns on this decision alone")
ok(grepl("INNER JOIN", rc, fixed = TRUE) && !grepl("LEFT JOIN", rc, fixed = TRUE),
   "joined, not outer-joined, so the table is what has to be looked at and no more")
ok(grepl("b.bel_dt", rc, fixed = TRUE) &&
     grepl("datediff(b.bel_dt, l1.LOT1_START_DT)", rc, fixed = TRUE),
   "with the claim date and its offset from index, which is what places it in a line")

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
# This table is the sheet the allowlist is built from, so it cannot be a table
# of winners: under an allowlist the winners are the allowed ones and it would
# only ever confirm itself.
ok(grepl("FROM universe u", a, fixed = TRUE) &&
     grepl("coalesce(n.N_PATIENTS, 0)", a, fixed = TRUE),
   "every agent on the code list is listed, including the ones that set none")
ok(grepl("CASE WHEN b.med_abbr IS NULL THEN 1 ELSE 0 END AS ELIGIBLE", a, fixed = TRUE) &&
     grepl("_ndmm_index_ineligible", a, fixed = TRUE),
   "...each saying whether this run would let it set an index")

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
# Every run choice reaches the row, or a cohort cannot say which choices made
# it - which is the whole reason they are allowed to vary.
for (k in names(CHOICES)) {
  v <- as.character(cfg_defaults[[k]])
  ok(grepl(if (nzchar(v)) paste0("'", v, "'") else "''", ins, fixed = TRUE) ||
       grepl("NULL", ins, fixed = TRUE),
     paste0(k, " is recorded on the run"))
}
ok(!is.na(ins) && grepl("'study_period'", ins, fixed = TRUE) &&
     grepl("'override'", ins, fixed = TRUE),
   "...the two named choices by their value, not as a blank")
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
builds <- list(NDMM_MM_DX_CODES = "build_ndmm_mm_dx_codes",
               NDMM_MM_DX_EVENTS = "build_ndmm_mm_dx_events",
               NDMM_MM_QUALIFYING = "build_ndmm_mm_qualifying",
               NDMM_BASE_COHORT = "build_ndmm_base_cohort",
               NDMM_ENROLL_SPANS = "build_enrollment_spans_ndmm",
               NDMM_MMA_CODELIST = "build_ndmm_mma_codelist",
               NDMM_BELANTAMAB_CODES = "build_ndmm_belantamab_codes",
               NDMM_LOT1_STARTS = "build_ndmm_lot1_index",
               NDMM_INDEX_TX = "build_ndmm_lot1_index",
               NDMM_ENROLL_SPANS_STRICT = "build_enrollment_spans_ndmm",
               NDMM_OTHER_MALIG_EVENTS = "build_ndmm_other_malig_pre_lot1",
               NDMM_INDEX_INELIGIBLE = "build_ndmm_index_ineligible_codes",
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

cat("\n-- the README names every table the run writes --\n")
# The deliverables list grew from five to thirteen and the README kept saying
# five, twice over. A reader who cannot see a table does not know to look at
# it, and every review table exists precisely to be looked at. Derived from
# OUTPUTS, so a table added later has to be written up or this fails.
readme <- paste(readLines(file.path(ROOT, "README.md"), warn = FALSE),
                collapse = "\n")
unnamed <- Filter(function(k) !grepl(k, readme, fixed = TRUE), OUTPUTS)
ok(length(unnamed) == 0,
   if (length(unnamed))
     paste0("written by the run but not named in the README: ",
            paste(unnamed, collapse = ", "))
   else paste0("all ", length(OUTPUTS), " outputs are named in the README"))
# And the fill-in files, which are useless if nobody knows they exist.
unnamed <- Filter(function(f) !grepl(f, readme, fixed = TRUE),
                  list.files(file.path(ROOT, "codelists"), "\\.csv$"))
ok(length(unnamed) == 0,
   if (length(unnamed))
     paste0("shipped for filling in but not named in the README: ",
            paste(unnamed, collapse = ", "))
   else "...as is every file this package ships to be filled in")
# And the setting that points each of them somewhere else. A file nobody can
# relocate is a file that has to be edited in place in a checkout, which is how
# a decision ends up living only on one person's disk.
cfg_txt <- paste(readLines(file.path(ROOT, "R", "config.R"), warn = FALSE),
                 collapse = "\n")
csv_vars <- unique(unlist(regmatches(cfg_txt,
  gregexpr('NDMM_[A-Z0-9_]*CSV', cfg_txt, perl = TRUE))))
unnamed <- Filter(function(v) !grepl(v, readme, fixed = TRUE), csv_vars)
ok(length(csv_vars) > 0 && length(unnamed) == 0,
   if (length(unnamed))
     paste0("reads a path from the environment but the README does not say so: ",
            paste(unnamed, collapse = ", "))
   else paste0("...and all ", length(csv_vars),
               " settings that relocate one are named too"))
# Every setting the package reads at all. Nine of thirty-seven were undocumented
# - the connection, the output schema, the raw table names - and a setting a
# reader cannot see is one they cannot set, so the default is not a default,
# it is the only value. Derived from the Sys.getenv calls, so a setting added
# later has to be written up.
env_files <- c("R/config.R", "R/nndm_constants.R", "R/standalone_constants.R",
               "R/build_nndm.R", "R/db_utils.R", "R/codelists.R")
env_vars <- sort(unique(unlist(lapply(env_files, function(f) {
  txt <- paste(readLines(file.path(ROOT, f), warn = FALSE), collapse = "\n")
  sub('.*"([A-Z0-9_]+)".*', "\\1",
      unlist(regmatches(txt, gregexpr('Sys[.]getenv[(]"[A-Z0-9_]+"', txt, perl = TRUE))))
}))))
unnamed <- Filter(function(v) !grepl(v, readme, fixed = TRUE), env_vars)
ok(length(env_vars) > 20 && length(unnamed) == 0,
   if (length(unnamed))
     paste0("read from the environment but not in the README: ",
            paste(unnamed, collapse = ", "))
   else paste0("every one of the ", length(env_vars),
               " settings the package reads is documented"))
# The funnel is the deliverable, so the README's version of it has to have as
# many steps as the build does. Rows, not labels: the labels are prose on a
# delivered table and are meant to be editable without a test change, which is
# also why they are not pinned. Adding or dropping a step is not
# prose, and this catches that.
att <- sub("(?s)\n## .*", "", sub("(?s).*## The attrition", "", readme, perl = TRUE),
           perl = TRUE)
steps_doc <- grep("^[|] [0-9]+ [|]", strsplit(att, "\n")[[1]])
ok(length(steps_doc) == length(ATTRITION_STEPS),
   paste0("the README's funnel has all ", length(ATTRITION_STEPS),
          " steps (found ", length(steps_doc), ")"))
# And the count written out in prose, which is where a number goes stale first.
WORDS <- c("one", "two", "three", "four", "five", "six", "seven", "eight",
           "nine", "ten", "eleven", "twelve")
wrong <- Filter(function(w) grepl(paste0(w, "-step"), readme, fixed = TRUE),
                setdiff(WORDS, WORDS[length(ATTRITION_STEPS)]))
ok(length(wrong) == 0,
   if (length(wrong)) paste0("the README calls it a ", wrong[1],
                             "-step funnel and it has ", length(ATTRITION_STEPS))
   else paste0("...and calls it a ", WORDS[length(ATTRITION_STEPS)], "-step funnel"))

cat("\n-- the README accounts for every step file --\n")
# Every step file is named. A file nobody wrote up is a rule nobody reviews.
steps_on_disk <- basename(list.files(file.path(ROOT, "R", "steps"), "\\.R$"))
unnamed <- Filter(function(f) !grepl(f, readme, fixed = TRUE), steps_on_disk)
ok(length(steps_on_disk) > 0 && length(unnamed) == 0,
   if (length(unnamed)) paste0("a step file the README does not account for: ",
                               paste(unnamed, collapse = ", "))
   else paste0("all ", length(steps_on_disk), " step files are accounted for"))

cat("\n-- the criteria section covers every criterion --\n")
# The section a reviewer holds against the protocol. One numbered row per
# attrition step, across its two tables - the two inherited from the parent and
# the seven applied here - because a criterion missing from the write-up is one
# nobody checks against S6.2.1.
crit <- sub("(?s)\n## .*", "",
            sub("(?s).*## The criteria as applied", "", readme, perl = TRUE),
            perl = TRUE)
nums <- as.integer(sub("^[|] ([0-9]+) [|].*", "\\1",
                       grep("^[|] [0-9]+ [|]", strsplit(crit, "\n")[[1]],
                            value = TRUE)))
ok(identical(sort(unique(nums)), seq_along(ATTRITION_STEPS)),
   if (!identical(sort(unique(nums)), seq_along(ATTRITION_STEPS)))
     paste0("the criteria tables describe steps ",
            paste(sort(unique(nums)), collapse = ","), " of ",
            length(ATTRITION_STEPS))
   else paste0("all ", length(ATTRITION_STEPS),
               " criteria are written up, numbered as the funnel numbers them"))
# Each one says which file applies it, so a reader can go and read the SQL.
rows <- grep("^[|] [0-9]+ [|]", strsplit(crit, "\n")[[1]], value = TRUE)
noref <- Filter(function(r) !grepl("[.]R`", r), rows)
ok(length(noref) == 0,
   if (length(noref)) paste0(length(noref),
                             " criteria do not say which file applies them")
   else "...each naming the file that applies it")

report()
