#!/usr/bin/env Rscript
# Checks on the question scripts' setup.
#
# These EXECUTE _setup.R rather than parsing it - parsing proved nothing, since
# a top-level expression using `%||%` before it is defined parses cleanly and
# dies on source. No warehouse: only the wiring, up to where a connection
# would be needed.
#
#   Rscript "analysis/questions/tests/test_setup.R"

ROOT <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                                 fixed = TRUE))) else getwd()
  dirname(d)
})
# Two levels, because the checks below read two kinds of thing. GROUP is the LOT
# group this package sits in - the engine and the other things that read a
# finished run. STUDY is the folder above it, where the cohort builds are: they
# are not part of the group, they are what a LOT run is pointed at. Resolved
# from this file rather than named, so either folder can be renamed.
GROUP <- dirname(ROOT)
STUDY <- dirname(GROUP)
# GROUP is analysis/ now, not the LOT group, so the engine and the dashboard
# are reached through the study folder.
LOT   <- file.path(STUDY, "lot")
DASHPKG <- file.path(STUDY, "reporting", "dashboard")

pass <- 0L; fail <- 0L
ok <- function(cond, what) {
  if (isTRUE(cond)) { pass <<- pass + 1L; cat("  ok     ", what, "\n") }
  else              { fail <<- fail + 1L; cat("  FAIL   ", what, "\n") }
}
runs  <- function(expr, what) ok(is.null(tryCatch({ expr; NULL },
                                 error = conditionMessage)), what)
stops <- function(expr, what) ok(!is.null(tryCatch({ expr; NULL },
                                 error = conditionMessage)), what)

VARS <- c("PROJECT_WORK_SCHEMA", "DOMINO_USER_NAME", "DOMINO_STARTING_USERNAME",
          "OBJECT_PREFIX", "QS_ALLOW_NO_PREFIX", "INPUT_COHORT_TABLE",
          "LOT_POPULATION", "LOT_COHORT", "BROAD_PREFIX", "TRIAL_PREFIX",
          "TRIAL_INDEX_TABLE", "QS_IGNORE_BUILD_STATE",
          "QS_IGNORE_TRIAL_BUILD_STATE", "QS_IGNORE_BROAD_BUILD_STATE")
clear <- function() for (v in VARS) Sys.unsetenv(v)

cat("\n-- sourcing it is enough to break it, so source it --\n")
# In a clean session, exactly as the documented command would.
runs(source(file.path(ROOT, "_setup.R")), "_setup.R sources in a bare session")
ok(exists("qs_setup") && is.function(qs_setup), "...and defines qs_setup()")
ok(exists("qs_tbl") && is.function(qs_tbl), "...and qs_tbl()")

cat("\n-- config.csv is read before the config is built --\n")
# config_lot.R turns environment variables into cfg_defaults the moment it is
# sourced. Loading config.csv afterwards cannot change a list that already
# exists, so these scripts would describe a run configured differently from the
# one they are reading.
body <- deparse(qs_setup)
i_csv <- grep("load_pipeline_inputs", body)[1]
i_cfg <- grep("config_lot\\.R", body)[1]
ok(!is.na(i_csv) && !is.na(i_cfg) && i_csv < i_cfg,
   "config.csv is loaded before config_lot.R, the way the build loads them")

cat("\n-- the run being asked about has to be named --\n")
clear()
Sys.setenv(DOMINO_USER_NAME = "usr00000")
stops(qs_setup(ROOT), "a blank OBJECT_PREFIX is refused, not read as unprefixed")
Sys.setenv(OBJECT_PREFIX = "ndmm")
stops(qs_setup(ROOT), "...and a prefix with no trailing underscore is refused")
Sys.setenv(OBJECT_PREFIX = "ndmm_; DROP TABLE x")
stops(qs_setup(ROOT), "...and anything that is not a prefix at all")
clear()
Sys.setenv(DOMINO_USER_NAME = "my schema", OBJECT_PREFIX = "ndmm_")
stops(qs_setup(ROOT), "a work schema that is not a schema name is refused")
clear()

cat("\n-- and then it resolves a real prefixed name --\n")
Sys.setenv(DOMINO_USER_NAME = "usr00000", OBJECT_PREFIX = "ndmm_")
# Several questions read the cohort for observation windows and index dates.
# Blank resolves to a name that is only the schema, and those sections would
# warn and run unbounded rather than stopping.
stops(qs_setup(ROOT), "a blank INPUT_COHORT_TABLE is refused")
Sys.setenv(INPUT_COHORT_TABLE = "sch.NDMM_COHORT")
stops(qs_setup(ROOT), "...and a qualified one, since the schema comes from settings")
Sys.setenv(INPUT_COHORT_TABLE = "ndmm_NDMM_COHORT")
runs(qs_setup(ROOT), "a named schema, prefix and cohort table set the config up")
cfg <- qs_setup(ROOT)
ok(identical(cfg$object_prefix, "ndmm_") && identical(cfg$work_schema, "usr00000"),
   "...with both pinned where the modules read them")
# The whole point: these tables carry the build's prefix, and wrk() does not
# add it. Asking for the unprefixed name usually finds nothing - but if an
# older unprefixed table is in the schema it finds that, and answers about a
# different study with nothing saying so.
ok(grepl("ndmm_LOT_LONG$", qs_tbl("LOT_LONG")),
   "qs_tbl() carries the prefix, so the table is that run's")
ok(!grepl("ndmm_", wrk("LOT_LONG")),
   "...which wrk() does not do, which is why the scripts stopped using it")
clear()
Sys.setenv(DOMINO_USER_NAME = "usr00000", QS_ALLOW_NO_PREFIX = "TRUE",
           INPUT_COHORT_TABLE = "NDMM_COHORT")
runs(qs_setup(ROOT), "a run that truly had no prefix can say so, explicitly")

cat("\n-- no script asks for a table the unprefixed way --\n")
qs <- list.files(ROOT, pattern = "_qs[.]R$", full.names = TRUE)
ok(length(qs) >= 5, paste0("the question scripts are here (", length(qs), ")"))
# wrk() is right for exactly one thing - the cohort table, whose whole physical
# name the caller passes. Every other table is a build's own prefixed output.
bad <- Filter(function(f) {
  w <- grep("\\bwrk\\(", readLines(f, warn = FALSE), value = TRUE)
  length(w) > 0 && !all(grepl("wrk(cfg$input_cohort_table)", w, fixed = TRUE))
}, qs)
ok(!length(bad),
   if (length(bad)) paste0("calls wrk() on a prefixed output: ",
                           paste(basename(bad), collapse = ", "))
   else "wrk() is used only for the cohort table; every output goes through qs_tbl()")
clear()

cat("\n-- every file a script sources is a different file, and exists --\n")
# validation_qs.R is an entry point; the vqs_* helpers were a separate file.
# Sourcing "validation_qs.R" from inside validation_qs.R is the entry point
# sourcing itself, before any helper is defined and before main() runs. It
# parses, so nothing but this would have said so.
srcs <- function(f) {
  m <- regmatches(readLines(f, warn = FALSE),
                  regexpr('source\\(file\\.path\\(\\.script_dir, "[^"]+"\\)\\)',
                          readLines(f, warn = FALSE)))
  unlist(regmatches(m, gregexpr('"[^"]+"', m)))
}
self <- Filter(function(f) paste0('"', basename(f), '"') %in% srcs(f), qs)
ok(!length(self),
   if (length(self)) paste0("sources itself: ", paste(basename(self), collapse = ", "))
   else "no script sources itself")
missing <- unlist(lapply(qs, function(f)
  Filter(function(n) !file.exists(file.path(ROOT, gsub('"', "", n))), srcs(f))))
ok(!length(missing),
   if (length(missing)) paste0("sources a file that is not here: ",
                               paste(unique(missing), collapse = ", "))
   else "every file they source is present")
ok(file.exists(file.path(ROOT, "validation_helpers.R")),
   "the vqs_* helpers are here as their own file")

cat("\n-- the cohort table is passed whole, so it is not prefixed again --\n")
# The one place wrk() is right. LOT takes input_cohort_table as the complete
# physical name - ndmm_NDMM_COHORT - so prefixing it would ask for
# ndmm_ndmm_NDMM_COHORT. The blanket wrk() -> qs_tbl() sweep broke exactly this.
dbl <- Filter(function(f) any(grepl("qs_tbl(cfg$input_cohort_table)",
                                    readLines(f, warn = FALSE), fixed = TRUE)), qs)
ok(!length(dbl),
   if (length(dbl)) paste0("prefixes the cohort table twice: ",
                           paste(basename(dbl), collapse = ", "))
   else "the cohort table goes through wrk(), not qs_tbl()")
# Not here. It is a governed production file, so a copy beside this script
# would be a second version of it, drifting from the one the study uses.
ok(!file.exists(file.path(ROOT, "steroid_codes.csv")),
   "no local copy of the steroid code list to drift from production")
vq <- readLines(file.path(ROOT, "validation_qs.R"), warn = FALSE)
ok(any(grepl("file.path(cfg$codelist_dir, \"steroid_codes.csv\")", vq, fixed = TRUE)),
   "...it is read from the production code-list directory")
vh <- readLines(file.path(ROOT, "validation_helpers.R"), warn = FALSE)
ok(any(grepl("md5sum(ster_csv)", vh, fixed = TRUE)),
   "...and its md5 is recorded, so a number can be traced to a version")
# CODELIST_FILES drives record_codelist_hashes(), which stops the LOT build
# when a listed file has no hash - and the LOT build never loads steroids.
cl <- readLines(file.path(LOT, "engine", "R", "codelists_lot.R"), warn = FALSE)
ok(!any(grepl("steroid_codes.csv", cl, fixed = TRUE)),
   "...without being added to the LOT build's own code-list contract")

cat("\n-- the questions run over the study population --\n")
# LOT_LONG is the run before a truncating criterion removed anyone, so a
# denominator taken from it counts patients the study excluded. LOT_LONG_FINAL
# is what ships, and it is the default.
clear(); Sys.setenv(DOMINO_USER_NAME = "usr00000", OBJECT_PREFIX = "ndmm_",
           INPUT_COHORT_TABLE = "ndmm_NDMM_COHORT")
invisible(qs_setup(ROOT))
ok(grepl("ndmm_LOT_LONG_FINAL$", qs_population()$table),
   "the default population is LOT_LONG_FINAL, not the pre-criteria table")
Sys.setenv(LOT_POPULATION = "PRECRITERIA")
ok(grepl("ndmm_LOT_LONG$", qs_population()$table),
   "...and the pre-criteria run can be asked for, when the question is what a criterion cost")
Sys.unsetenv("LOT_POPULATION")
Sys.setenv(LOT_POPULATION = "SOMETHING")
stops(qs_population(), "an unrecognised population is refused")
Sys.unsetenv("LOT_POPULATION")
# LOT_COHORT names a cohort this script does not produce. Silently
# reinterpreting it would be worse than stopping.
Sys.setenv(LOT_COHORT = "NDMM")
stops(qs_population(), "the retired LOT_COHORT stops the run and names what replaced it")
Sys.unsetenv("LOT_COHORT")
# The table that switch named appears nowhere in the code.
gone <- Filter(function(f) any(grepl("NDMM_LOT_LONG_FILT|LOT_COHORT",
                                     readLines(f, warn = FALSE))), qs)
ok(!length(gone),
   if (length(gone)) paste0("still expects the retired table: ",
                            paste(basename(gone), collapse = ", "))
   else "no script expects the filtered table the cohort build stopped producing")

cat("\n-- and they classify bone metastasis the way the cohort does --\n")
# poma treated secondary neoplasm of bone as MM-adjacent and removed it from
# its de-confounded analysis. The cohort build decided the opposite: C79.51,
# C79.52 and 198.5 are metastatic cancer and exclude. Two answers to one
# clinical question is the thing worth failing on.
poma <- readLines(file.path(ROOT, "poma_studyteam_qs.R"), warn = FALSE)
bdq  <- readLines(file.path(ROOT, "broad_studyteam_qs.R"), warn = FALSE)
# Not by keeping a matching copy of the list - by reading the build's own
# answer. is_mm_adjacent_override is what the cohort actually applied, so there
# is one derivation of the rule and the two cannot disagree at all.
ok(any(grepl('qs_tbl("NDMM_OTHER_MALIG_CODES")', bdq, fixed = TRUE)),
   "it reads the code list the cohort build resolved and persisted")
ok(any(grepl("is_mm_adjacent_override AS is_mm_adj", bdq, fixed = TRUE)),
   "...taking the build's own MM-adjacent decision rather than restating it")
ok(!any(grepl("SECONDARY MALIGNANT NEOPLASM OF BONE", c(poma, bdq), fixed = TRUE)),
   "...so no tumour-group list is duplicated here to drift")
# Loading the CSV would mean re-deriving the rule, which is what drifted.
ok(!any(grepl("load_codelist_csv", c(poma, bdq), fixed = TRUE)),
   "and it does not rebuild the list from the CSV")
# The code did the build's thing while the narrative beside it still told the
# reader the opposite. A workbook is read for its words, so that is a wrong
# answer shipped in the deliverable.
ok(!any(grepl("secondary bone - MM-spectrum", c(poma, bdq), fixed = TRUE)),
   "...and the narrative does not call secondary bone MM-spectrum")
# Q3's association is a BROAD-cohort question. One prefix is one cohort, and
# this cohort already excluded patients with a qualifying other cancer - so
# answering it from this run would be near-zero by construction.
ok(any(grepl("BROAD_PREFIX", bdq, fixed = TRUE)) &&
     !any(grepl("BROAD_PREFIX", poma, fixed = TRUE)),
   "the broad association names the broad run, and poma does not mention it")
ok(any(grepl("the association is skipped", bdq, fixed = TRUE)),
   "...and says it is skipped rather than answering from the study population")
clear()

cat("\n-- the trial flags come from the build that has them --\n")
# The two builds write different tables, and they are not alternate names for
# one contract. NDMM_FLAGS_ALL is the exclusion audit on PATID alone; the
# other-cancer and clinical-trial flags live in the broad build's
# ELIG_COH_ALLFLAGS, with ELIG_COH_FINAL saying which candidate index each row
# belongs to. Defaulting a trial question to NDMM_FLAGS_ALL is worse than a
# missing table: it is readable, so a readable() guard passes, and the query
# then stops on an unresolved column part way through the workbook.
clear(); Sys.setenv(DOMINO_USER_NAME = "usr00000", OBJECT_PREFIX = "ndmm_",
           INPUT_COHORT_TABLE = "ndmm_NDMM_COHORT")
invisible(qs_setup(ROOT))
tf <- qs_trial_flags()
ok(!grepl("NDMM_FLAGS_ALL", tf$flags, fixed = TRUE),
   "the trial flags never resolve to the cohort build's exclusion audit")
ok(grepl("ndmm_ELIG_COH_ALLFLAGS$", tf$flags) && !tf$named,
   "...blank falls back to this prefix, which is right when the broad build made the cohort")
# The flags carry the prefix of the build that wrote them, which need not be
# the prefix of the LOT run being asked about.
Sys.setenv(TRIAL_PREFIX = "overall_")
tf <- qs_trial_flags()
ok(grepl("overall_ELIG_COH_ALLFLAGS$", tf$flags) && tf$named,
   "...and another build's prefix can be named, since it is not this run's")
# The two tables are not named the same way. ELIG_COH_ALLFLAGS is a checkpoint,
# so it is written prefixed. The final cohort is persisted straight from that
# build's FINAL_TABLE_NAME with no prefix at all - overall/config.csv sets it
# to OVERALL_COH_FINAL. Deriving <prefix>ELIG_COH_FINAL asks for a table the
# build never writes.
ovc <- readLines(file.path(STUDY, "overall", "config.csv"), warn = FALSE)
ok(any(grepl("^FINAL_TABLE_NAME,OVERALL_COH_FINAL", ovc)),
   "the broad build names its final cohort OVERALL_COH_FINAL, not ELIG_COH_FINAL")
asm <- readLines(file.path(STUDY, "overall", "R", "steps", "08_assembly.R"),
                 warn = FALSE)
ok(any(grepl("full_name(cfg$personal_schema, cfg$final_table_name)", asm, fixed = TRUE)),
   "...and persists it unprefixed, which is why it cannot be derived from TRIAL_PREFIX")
ok(grepl("OVERALL_COH_FINAL$", tf$index) && !grepl("overall_OVERALL", tf$index),
   "so the index table defaults to that name and takes no prefix")
Sys.setenv(TRIAL_INDEX_TABLE = "MY_COH_FINAL")
ok(grepl("[.]MY_COH_FINAL$", qs_trial_flags()$index),
   "...and a build configured with another FINAL_TABLE_NAME can name it")
Sys.setenv(TRIAL_INDEX_TABLE = "x; DROP TABLE y")
stops(qs_trial_flags(), "...validated like every other configurable name")
Sys.unsetenv("TRIAL_INDEX_TABLE")
Sys.setenv(TRIAL_PREFIX = "x; DROP TABLE y")
stops(qs_trial_flags(), "...validated like every other configurable prefix")
Sys.unsetenv("TRIAL_PREFIX")
# Both tables, from one build. Aligning the flags to the NDMM cohort would put
# that build's diagnosis-based candidate against NDMM_COHORT.INDEX_DATE, the
# LOT1 start - two definitions of index, matching almost nothing, silently.
need <- c("PATID", "INDEX_DATE", "OTHER_MALIGN_FLAG", "CLINTRIAL_BASELINE",
          "CLINTRIAL_FOLLOWUP")
ok(identical(sort(QS_TRIAL_FLAG_COLS), sort(need)),
   "the columns a trial question needs are declared, so a mismatch is caught before Spark sees it")
nn6 <- readLines(file.path(STUDY, "ndmm", "R", "steps", "06_flags.R"),
                 warn = FALSE)
ok(!any(grepl("OTHER_MALIGN_FLAG", nn6, fixed = TRUE)) &&
   !any(grepl("CLINTRIAL_", nn6, fixed = TRUE)),
   "...and NDMM_FLAGS_ALL genuinely has none of them, which is why it cannot be the default")
ov <- readLines(file.path(STUDY, "overall", "R", "steps", "08_assembly.R"),
                warn = FALSE)
ok(any(grepl("OTHER_MALIGN_FLAG", ov, fixed = TRUE)) &&
   any(grepl("CLINTRIAL_BASELINE", ov, fixed = TRUE)),
   "...while ELIG_COH_ALLFLAGS does")
# The diagnosis-anchored source is one script's business now. Every other
# script is NDMM-only, so a second cohort's tables cannot reach a workbook
# about this one.
ok(any(grepl("qs_trial_flags_ready(con)", bdq, fixed = TRUE)),
   "the broad script checks the columns, not just that the table is readable")
users <- Filter(function(f) any(grepl("qs_trial_flags_ready", readLines(f, warn = FALSE),
                                      fixed = TRUE)), qs)
ok(identical(basename(users), "broad_studyteam_qs.R"),
   if (length(users) != 1L) paste0("more than one script reads the broad flags: ",
                                   paste(basename(users), collapse = ", "))
   else "...and it is the only script that reads them")
for (f in qs) {
  ln <- readLines(f, warn = FALSE)
  ok(!any(grepl("qs_flags_table", ln, fixed = TRUE)),
     paste0(basename(f), " does not treat the two flag tables as interchangeable"))
  # The join has to be flags-to-its-own-final. Against the cohort table it
  # compares a diagnosis-based index with the LOT1 start.
  ok(!any(grepl("{final_tbl} e ON", ln, fixed = TRUE)),
     paste0("...and does not align that build's flags to this cohort's INDEX_DATE"))
}
# The overlap-of-two-cohorts design is gone with the split. Each script now
# denominates on the population it is about: poma on this cohort, the broad
# script on the broad one. There is no match rate left to police because there
# is no second population inside either workbook.
pm <- readLines(file.path(ROOT, "poma_studyteam_qs.R"), warn = FALSE)
ok(!any(grepl("AS n_matched", pm, fixed = TRUE)) &&
     !any(grepl("AS pct_matched", pm, fixed = TRUE)),
   "poma has no cross-cohort overlap left to report")
ok(!any(grepl("ELIG_COH", pm, fixed = TRUE)) &&
     !any(grepl("ELIG_COH", readLines(file.path(ROOT, "lot1_studyteam_qs.R"),
                                      warn = FALSE), fixed = TRUE)),
   "...and neither NDMM script names the broad build's tables at all")
ok(any(grepl("count(DISTINCT a.PATID)", bdq, fixed = TRUE)),
   "the broad script counts over the population its flags belong to")
# Neither flag brackets the pre-LOT1 window: baseline ends before that build's
# diagnosis index, follow-up starts there and runs past LOT1.
ok(!any(grepl("HEADLINE on n_trial_baseline", pm, fixed = TRUE)),
   "...and baseline is not headlined as the prior-unobserved-therapy signal")

cat("\n-- the questions bind to the run that last wrote the tables --\n")
# Not the newest complete run. LOT replaces LOT_LONG_FINAL before validating
# it, so a rerun that replaced it and then failed leaves its table on disk
# while the previous complete row still looks like the newest good one - which
# is the case the guard exists for. The dashboard resolves ownership this way.
st <- readLines(file.path(ROOT, "_setup.R"), warn = FALSE)
ok(!any(grepl("upper(STATE) = 'COMPLETE'", st, fixed = TRUE)),
   "the binding does not filter to completed runs before taking the latest")
ok(any(grepl("ORDER BY UPDATED_AT DESC LIMIT 1", st, fixed = TRUE)) &&
   any(grepl("QS_IGNORE_BUILD_STATE", st, fixed = TRUE)),
   "...it takes the latest row whatever state it reached, and stops on an unfinished one")
dsh <- readLines(file.path(DASHPKG, "R", "db_utils_dash.R"),
                 warn = FALSE)
ok(any(grepl("DASH_IGNORE_BUILD_STATE", dsh, fixed = TRUE)),
   "...the same way the dashboard does, for the same reason")

cat("\n-- and the build behind the trial flags has to have finished --\n")
# The flags and the final cohort are separate writes. A run that stopped
# between them leaves two tables that are individually readable and carry every
# column, describing different attempts - columns alone cannot see that.
bc <- readLines(file.path(STUDY, "overall", "R", "build_cohort.R"),
                warn = FALSE)
ok(any(grepl('paste0(tolower(cfg$object_prefix), "build_status")', bc, fixed = TRUE)),
   "the broad build records how it ended, under its own prefix")
ok(any(grepl("CREATE OR REPLACE TABLE ", bc, fixed = TRUE)) &&
   any(grepl('q(state), " AS state, "', bc, fixed = TRUE)),
   "...one row, replaced each run, so that row is the last run on the prefix")
ok(any(grepl('q(cfg$final_table_name), " AS final_table_name, "', bc, fixed = TRUE)),
   "...and it records the final table it wrote, which is checkable")
ok(any(grepl("qs_trial_build_state(con, src)", st, fixed = TRUE)),
   "so the trial source is asked for that before its columns are trusted")
ok(any(grepl("QS_IGNORE_TRIAL_BUILD_STATE", st, fixed = TRUE)),
   "...with an override for a build known to have failed before writing either")
# That check guards a real pair: the flags and the final cohort are written
# separately, so a build that stopped between them leaves two readable,
# correctly shaped tables from different attempts, and the column checks
# downstream pass on both. So an unreadable status table cannot take the
# older-build path - it is this check not running, not a build that predates it.
drive_tbs <- function(x) {
  assign("db_q", function(con, sql) if (is.character(x)) stop(x) else x,
         envir = globalenv())
  qs_trial_build_state(NULL, list(prefix = "t_", index = "wk.T_FINAL"))
}
ok(isTRUE(drive_tbs("TABLE_OR_VIEW_NOT_FOUND: wk.t_build_status")$ok),
   "a build old enough to have written no status table is allowed through")
ok(!isTRUE(drive_tbs(data.frame())$ok),
   "...but an existing table with no row is not, since that build writes one")
for (case in list(list(m = "HTTP 403: permission denied", w = "a refused read"),
                  list(m = "Connection reset by peer",    w = "a dropped connection"))) {
  r <- drive_tbs(case$m)
  ok(!isTRUE(r$ok) && grepl("could not be read", r$why, fixed = TRUE) &&
       grepl(case$m, r$why, fixed = TRUE),
     paste0("...while ", case$w, " skips the trial sections rather than answering"))
}
rm("db_q", envir = globalenv())
# TRIAL_INDEX_TABLE defaults to a name from a config file this package does not
# read. The build's own record of what it wrote settles it.
ok(any(grepl('"TRIAL_INDEX_TABLE resolves to "', st, fixed = TRUE)),
   "...and a default that disagrees with what the build wrote names the right table")
# The two builds disagree on column case - LOT writes STATE, the broad build
# state. A bare d$STATE is NULL on the latter, which reads as no state at all.
ok(any(grepl("qs_col <- function(d, name)", st, fixed = TRUE)) &&
   !any(grepl("got$STATE", st, fixed = TRUE)) &&
   !any(grepl("d$state[1]", st, fixed = TRUE)),
   "both status tables are read case-insensitively, since they do not agree on case")

cat("\n-- and so does the broad run behind Q3's association --\n")
# Readable is not ownership there either: that run replaces LOT_LONG_FINAL
# before validating it, so a rerun that replaced it and then failed leaves
# lines that read perfectly well and were never checked.
ok(any(grepl("qs_lot_run_row(con, prefix)", st, fixed = TRUE)),
   "the two LOT status reads are one helper, so the broad prefix gets the same rule")
# A sensitivity cell is a complete, well-formed LOT run of a different
# algorithm - the sweep builds twelve of them. A workbook answered off one
# would read exactly like a workbook answered off the study.
ok(any(grepl("CONTRACT_DEVIATIONS", st, fixed = TRUE)),
   "the status read carries whether that run was the contract algorithm at all")
ok(any(grepl("LOT_CONTRACT_OVERRIDE", st, fixed = TRUE)),
   "...and a run built as an alternative stops the workbook")
# No override on this one, unlike the state and cohort checks. Those are
# inferences that can be wrong about a run; this is what the build wrote about
# itself, and there is no reading of it under which the answers are the study's.
dev_line <- grep("if \\(length\\(got\\$deviations\\)\\)", st)
ok(length(dev_line) == 1L &&
     !any(grepl("QS_IGNORE", st[dev_line + 0:8], fixed = TRUE)),
   "...with no way past it, because it is recorded fact rather than inference")
ok(!any(grepl("qs_tbl(\"LOT_BUILD_STATUS\")", st, fixed = TRUE)),
   "...rather than the binding check being hardcoded to this run's prefix")
# NULL from that helper means "no run is recorded", and the callers take it as
# a legacy build they can only warn about. So an unreadable status table must
# not return NULL: it would carry BOTH stops out with it - the refusal to
# answer off a sensitivity cell and the refusal to pair one run's lines with
# another's cohort - and still write a workbook that reads like the study's.
drive_row <- function(x) {
  assign("db_q", function(con, sql) if (is.character(x)) stop(x) else x,
         envir = globalenv())
  tryCatch(list(v = qs_lot_run_row(NULL, "p_")), error = conditionMessage)
}
ok(is.null(drive_row("TABLE_OR_VIEW_NOT_FOUND: wk.p_LOT_BUILD_STATUS")$v),
   "a status table that is not there is a legacy build, and returns no row")
ok(is.null(drive_row(data.frame())$v),
   "...as does one that is there with nothing in it")
for (case in list(list(m = "HTTP 403: permission denied", w = "a refused read"),
                  list(m = "Connection reset by peer",    w = "a dropped connection"))) {
  e <- drive_row(case$m)
  ok(is.character(e) && grepl("Could not read", e, fixed = TRUE) &&
       grepl("LOT_CONTRACT_OVERRIDE", e, fixed = TRUE),
     paste0("...while ", case$w, " stops, naming the stop it would have skipped"))
}
rm("db_q", envir = globalenv())
ok(any(grepl("qs_broad_run_state(con, broad_pfx)", bdq, fixed = TRUE)),
   "the broad script asks whether that run finished before reading its lines")
ok(any(grepl("QS_IGNORE_BROAD_BUILD_STATE", st, fixed = TRUE)),
   "...with its own override, for a broad run known to have failed early")
# Skips that half, not the workbook: the audit and every other tab are over
# this run's tables and do not depend on the broad one.
ok(any(grepl("Association skipped - ", bdq, fixed = TRUE)),
   "...and an unfinished broad run skips it with the reason")
# "The broad cohort" should name a population, not a prefix.
ok(any(grepl("built from ", bdq, fixed = TRUE)),
   "...and the log says which cohort that run was built from")

cat("\n-- and the two broad sources have to be one broad cohort --\n")
# BROAD_PREFIX names a LOT run, TRIAL_PREFIX the build behind the
# diagnosis-anchored flags. Nothing makes them the same study, and the flag
# section crosses them. Point them at two populations and every patient the LOT
# run lacks falls into 'other', which looks like not having had POMA.

# One side is INPUT_COHORT_TABLE as typed into the LOT run, the other a name
# resolved through the work schema - one is qualified and the other is not, so
# comparing them whole would call every matching pair a mismatch.
ok(qs_broad_pair_bound("overall_coh_final", "usr00000.OVERALL_COH_FINAL")$bound,
   "one cohort under two names is bound, schema qualifier and case aside")
mm <- qs_broad_pair_bound("BROAD_A_FINAL", "sch.BROAD_B_FINAL")
ok(!isTRUE(mm$bound) && isTRUE(mm$verified),
   "two different cohorts are a known mismatch, not an unknown")
ok(grepl("two different broad cohorts", mm$why, fixed = TRUE),
   "...and it says which pair disagreed and what that would have done")
# Missing is not the same as wrong. Older runs predate the status table, and
# refusing on an absent record takes the answer away from every one of them.
un <- qs_broad_pair_bound(NA_character_, "sch.OVERALL_COH_FINAL")
ok(!isTRUE(un$bound) && !isTRUE(un$verified),
   "an unrecorded cohort is unverified rather than a mismatch")
ok(!isTRUE(qs_broad_pair_bound("A", "")$verified),
   "...and so is an empty one, which would otherwise compare as a difference")
ok(any(grepl("qs_broad_pair_bound(broad$cohort, trial_idx)", bdq, fixed = TRUE)),
   "the broad script binds the LOT run's cohort to the flag build's own table")
# The split is the only part that crosses the two. The flags themselves are
# that build's and stand on their own, so a mismatch costs the split and not
# the section.
ok(any(grepl("grp_expr <- if (poma_split)", bdq, fixed = TRUE)) &&
     any(grepl("'all'", bdq, fixed = TRUE)),
   "...and reports the flags ungrouped when it cannot, rather than not at all")
# An unset BROAD_PREFIX must not interpolate an NA table name into the SQL,
# which would die inside best_effort() while the log claimed a clean split.
ok(!any(grepl("poma1l AS (SELECT DISTINCT cast(PATID as string) PATID FROM {broad_lot}\n                 WHERE",
              paste(bdq, collapse = "\n"), fixed = TRUE)),
   "...and does not name the broad table in a query that runs without it")

cat("\n-- an unverified pairing leaves the split off, and says why on the rows --\n")
# 'other' is not a group unless the two populations are one. It is the
# complement of a POMA set drawn from the LOT run, so a flag-build patient that
# run never held falls into it and is counted as not having had POMA rather
# than as not being in the run - the same arithmetic the known-mismatch case is
# dropped for. Disclosure does not make the denominator mean anything else, so
# an unverified pairing now leaves the split off too.
#
# The block is pulled out of the file and EVALUATED rather than grepped, so
# this tests the strings that ship. Braced, or parse() would split it at the
# first top-level `else`.
lin_a <- grep("^    split_off <-$", bdq)
lin_b <- grep("^    lineage_lit <- gsub", bdq)
ok(length(lin_a) == 1L && length(lin_b) == 1L && lin_b > lin_a,
   "the flags section decides one reason, then the lineage string from it")
run_lin <- function(pfx, ok_broad, pair) {
  e <- new.env()
  assign("broad_pfx", pfx, envir = e)
  assign("broad", list(ok = ok_broad), envir = e)
  assign("pair", pair, envir = e)
  eval(parse(text = paste(c("{", bdq[lin_a:(lin_b - 1L)], "}"), collapse = "\n")),
       envir = e)
  list(split = get("poma_split", envir = e), lineage = get("lineage", envir = e))
}
BOUND <- list(bound = TRUE,  verified = TRUE,  why = NULL)
UNVER <- list(bound = FALSE, verified = FALSE, why = "nothing records which cohort")
DIFFR <- list(bound = FALSE, verified = TRUE,  why = "two different broad cohorts")
r_ok <- run_lin("b_", TRUE, BOUND)
r_un <- run_lin("b_", TRUE, UNVER)
r_df <- run_lin("b_", TRUE, DIFFR)
r_np <- run_lin("",   TRUE, BOUND)
r_nb <- run_lin("b_", FALSE, BOUND)
ok(isTRUE(r_ok$split), "a verified pairing splits")
ok(!isTRUE(r_un$split),
   "...an unverified one does not, so nothing lands in an 'other' nobody defined")
ok(!isTRUE(r_df$split), "...nor does a pairing known to disagree")
ok(!isTRUE(r_np$split) && !isTRUE(r_nb$split),
   "...nor an unset BROAD_PREFIX or an unusable broad run")
# The reason has to survive to the CSV. One row of counts says nothing about
# why it is one row, and the log reaches only whoever ran the script.
ok(all(vapply(list(r_un, r_df, r_np, r_nb),
              function(r) grepl("^no POMA split - .", r$lineage), logical(1))),
   "...and every suppressed case says on the row that there is no split, and why")
ok(length(unique(vapply(list(r_ok, r_un, r_df, r_np, r_nb),
                        function(r) r$lineage, character(1)))) == 5L,
   "...with a different reason each time, so none reads as another")
ok(grepl("nothing records which cohort", r_un$lineage, fixed = TRUE) &&
     grepl("two different broad cohorts", r_df$lineage, fixed = TRUE),
   "...carrying the pairing's own words rather than restating them")
ok(any(grepl("AS lineage", bdq, fixed = TRUE)),
   "...as a column of the flags CSV rather than a log line only")
# The prose has an apostrophe in it. Interpolated raw, that closes the SQL
# literal early: the query dies inside best_effort() and the caveat takes the
# numbers it qualifies down with it.
ok(any(grepl("gsub(\"'\", \"''\", lineage, fixed = TRUE)", bdq, fixed = TRUE)) &&
     any(grepl("'{lineage_lit}'", bdq, fixed = TRUE)) &&
     !any(grepl("'{lineage}'", bdq, fixed = TRUE)),
   "...escaped on its way into the query, not interpolated raw")
ok(!any(vapply(list(r_ok, r_un, r_df, r_np, r_nb), function(r)
          nchar(gsub("[^']", "", gsub("'", "''", r$lineage, fixed = TRUE))) %% 2L != 0L,
        logical(1))),
   "...which leaves every one of them balanced as a SQL literal")
# One reason, not two that can drift: the log reads the same value the query
# reports rather than rebuilding the if/else chain beside it.
ok(any(grepl('log_msg("  NOTE: one row, grp=\'all\', with no POMA split - ", split_off)',
             bdq, fixed = TRUE)),
   "...and the log prints that same reason rather than deriving its own")

cat("\n-- a run records the CDM vintage it read --\n")
# STUDY_END picks the quarterly table and the quarterlies are cumulative. Q3
# takes lines and index dates from the broad run, then scans the raw CDM itself
# at this run's vintage - so a different STUDY_END pairs that run's patients
# with a later version of their claims. Without the date recorded the mismatch
# could only be declared, never detected.
bl <- readLines(file.path(LOT, "engine", "R", "build_lot.R"), warn = FALSE)
ok(any(grepl('STATE = "STRING", STUDY_END = "STRING"', bl, fixed = TRUE)),
   "the LOT build records STUDY_END in its status table")
ok(any(grepl('STUDY_END                  = glue("\'{cfg$study_end}\'")', bl, fixed = TRUE)),
   "...and writes the run's own value, not a default")
# One declaration drives CREATE, the ALTER-to-add and the INSERT, so a column
# added to the list with no value stops the build rather than reaching the
# warehouse. That check is what makes adding one safe.
ok(any(grepl("stopifnot(identical(names(vals), cols))", bl, fixed = TRUE)),
   "...and the three uses of that list are still held together")
# An older run's table predates the column. Naming it in the SELECT would make
# that table unreadable, which reads as no run recorded at all.
ok(any(grepl("SELECT * FROM {tbl} ORDER BY UPDATED_AT DESC LIMIT 1", st, fixed = TRUE)),
   "the questions read the status row without naming a column older runs lack")
ok(any(grepl("qs_vintage_note", st, fixed = TRUE)),
   "...and compare it with the vintage they are configured for")
ok(any(grepl('if (!is.null(broad$vintage)) log_msg', bdq, fixed = TRUE)),
   "...with the vintage mismatch carried where the two data ages meet")

cat("\n-- the trial question is answered on this cohort's own index --\n")
# The whole point of the ndmm flag: its windows are cut at the 1L start, so
# diagnosis-to-1L is a column rather than something split across two
# diagnosis-anchored flags that each miss half of it.
ct <- readLines(file.path(STUDY, "ndmm", "R", "steps", "08_clintrial.R"),
                warn = FALSE)
ok(any(grepl("AS CLINTRIAL_DX_TO_LOT1", ct, fixed = TRUE)),
   "the cohort build has a diagnosis-to-1L trial window")
ok(any(grepl("qs_ndmm_trial_flags(con)", pm, fixed = TRUE)),
   "...and Q4 reads it")
ok(any(grepl("n_dx_to_lot1", pm, fixed = TRUE)) &&
   any(grepl("median_days_dx_to_lot1", pm, fixed = TRUE)),
   "...headlining that window, with the timing beside it")
# The timing has to be over the same claims as the count printed beside it.
# Any-time-before-1L includes pre-diagnosis codes, so a patient who
# contributes nothing to the count would contribute to the median, and one
# with codes in both windows would contribute the older date.
ok(any(grepl("CLINTRIAL_DX_TO_LOT1_DAYS", ct, fixed = TRUE)) &&
   any(grepl("percentile_approx(t.CLINTRIAL_DX_TO_LOT1_DAYS", pm, fixed = TRUE)),
   "...over the same window as the count, not every claim before 1L")
ok(!any(grepl("percentile_approx(t.CLINTRIAL_DAYS_BEFORE_LOT1", pm, fixed = TRUE)),
   "...so the count and the timing cannot describe different patients")
# The table is written before the cohort table, the attrition and "complete",
# and a later completed rerun replaces it under the same name - which the LOT
# binding check, comparing that name, cannot see.
ok(any(grepl("COHORT_RUN_ID IS NOT NULL ORDER BY RUN_TIMESTAMP DESC", st,
             fixed = TRUE)),
   "the trial table is checked against the cohort run LOT actually read")
# That query ordered by RECORDED_AT, which LOT_RUN_METADATA does not have
# (08_persist.R writes RUN_TIMESTAMP). It failed inside its own tryCatch, took
# the "an older lot did not record it" path, and passed - so the guard never
# ran while the code and the docs both claimed it.
pers <- readLines(file.path(LOT, "engine", "R", "steps", "08_persist.R"),
                  warn = FALSE)
ok(any(grepl("RUN_ID STRING, RUN_TIMESTAMP TIMESTAMP", pers, fixed = TRUE)),
   "...by the name that table actually uses")
ok(!any(grepl("ORDER BY RECORDED_AT DESC LIMIT 1", st, fixed = TRUE)),
   "...so the check cannot fail into its own fallback")
# A re-run keeps its run id, so the id matching says nothing on its own - the
# stamp is what separates one attempt from the next, and the trial table is
# written early enough to be a later attempt's while the id still matches.
ok(any(grepl("is a later attempt's than the lines it would be paired with", st,
             fixed = TRUE)),
   "...and a cohort rewritten since LOT read it is a gap, not a warning")
ok(any(grepl("NDMM_BUILD_STATUS", st, fixed = TRUE)),
   "...and against whether that cohort build finished")
# On the documented command the broad flags are usually absent while this one
# is present, so a bare "Q4 skipped" would sit directly above the answer.
ok(!any(grepl('paste0("Q4 skipped. ", trial$why)', pm, fixed = TRUE)),
   "an absent diagnosis-anchored table does not report the whole of Q4 as skipped")
# A trial code identifies neither the study drug nor the condition treated.
ok(any(grepl("not proof of therapy", pm, fixed = TRUE)) &&
   any(grepl("a zero does not establish", pm, fixed = TRUE)),
   "...and the tab does not read a claims code as proven therapy")
# Two scripts giving two different trial numbers for the same patients is the
# drift this package exists to prevent.
l1b <- readLines(file.path(ROOT, "lot1_studyteam_qs.R"), warn = FALSE)
ok(any(grepl("qs_ndmm_trial_flags(con)", l1b, fixed = TRUE)) &&
   any(grepl("q1c_poma_trial_1l_anchored", l1b, fixed = TRUE)),
   "the LOT1 workbook answers Q1c from the same 1L-anchored flag POMA Q4 uses")
# One prefix, one cohort: nothing to reconcile, so a missing row is a broken
# join and is counted rather than read as a clean patient.
ok(any(grepl("AS missing_flag_rows", pm, fixed = TRUE)),
   "...and a LOT1 patient with no flag row is counted, not coerced to clean")
# The overlapping window must not be added to the partition.
ok(any(grepl("NOT add it to n_pre_dx or n_dx_to_lot1", pm, fixed = TRUE)),
   "...with the 12-month window marked as spanning two of the others")
# The diagnosis-anchored view stays, as context, and says what it cannot answer.
ok(any(grepl("cannot answer it: baseline stops before", bdq, fixed = TRUE)),
   "the diagnosis-anchored view says what it cannot answer")
ok(any(grepl("Clinical trial does NOT filter this cohort", pm, fixed = TRUE)),
   "...and the tab says the flag is descriptive, not a criterion")

cat("\n-- every script binds to its run, not just the two that read flags --\n")
# The guard is worth nothing in the scripts that skip it. All five bound
# raw-claim windows by INPUT_COHORT_TABLE, and all five read tables a newer
# failed run may have replaced.
nog <- Filter(function(f) !any(grepl("qs_check_run_binding(con)",
                                     readLines(f, warn = FALSE), fixed = TRUE)), qs)
ok(!length(nog),
   if (length(nog)) paste0("does not check the run binding: ",
                           paste(basename(nog), collapse = ", "))
   else "every question script checks the run binding before it reads anything")

cat("\n-- an unknown ICD family matches neither, the way the builds decide it --\n")
# "Not one of the ICD-9 spellings, therefore ICD-10" reads a genuine ICD-9
# claim with a blank flag as ICD-10, which then fails the family join
# silently - so the workbook can count a diagnosis the cohort build did not.
# raw_icd_flag is WAIVABLE, so a run can legitimately carry such flags.
ok(!any(grepl("THEN 'ICD9' ELSE 'ICD10' END", c(pm, bdq), fixed = TRUE)),
   "Q3 does not default an unrecognised claim flag to ICD10")
ok(any(grepl("qs_icd_family_sql('d.ICD_FLAG')", bdq, fixed = TRUE)),
   "...it uses the same three-way rule, with NULL for unknown")
ok(grepl("ELSE NULL END$", qs_icd_family_sql("x")),
   "...which really does yield NULL rather than a family")
# The lists cannot be sourced from ndmm - that file defines its own
# load_codelist_csv() and would replace lot's - so they are repeated, and this
# is what stops the copy drifting.
nc <- readLines(file.path(STUDY, "ndmm", "R", "codelists.R"), warn = FALSE)
grab <- function(v) {
  ln <- grep(paste0("^", v, "\\s*<-"), nc, value = TRUE)[1]
  sort(trimws(gsub('"', "", unlist(strsplit(gsub("^.*c\\(|\\).*$", "", ln), ",")))))
}
ok(identical(grab("RAW_ICD9"), sort(QS_RAW_ICD9)) &&
   identical(grab("RAW_ICD10"), sort(QS_RAW_ICD10)),
   "...and the spellings still match the cohort builds' own lists")
nw <- readLines(file.path(STUDY, "ndmm", "R", "build_ndmm.R"), warn = FALSE)
# The cohort build reports unrecognised flags rather than stopping, so a run
# can legitimately carry them - which is exactly why this package must use the
# same three-way rule instead of guessing ICD-10.
ok(any(grepl("ICD_FLAG names neither family on", nw, fixed = TRUE)),
   "...which matters because that build reports them rather than refusing them")

cat("\n-- no workbook tells anyone to edit a production code list --\n")
# steroid_codes.csv is read from CODELIST_DIR, the directory the LOT build
# reads its four from, and every steroid answer quotes its md5. Emptying it to
# change one workbook's display edits what other studies read.
lf <- readLines(file.path(ROOT, "lot_followup_qs.R"), warn = FALSE)
ok(!any(grepl("empty steroid_codes.csv", lf, fixed = TRUE) &
        !grepl("Do NOT empty steroid_codes.csv", lf, fixed = TRUE)),
   "the follow-up workbook does not say to empty the production steroid list")
ok(any(grepl("Do NOT empty steroid_codes.csv", lf, fixed = TRUE)),
   "...and says why not, since that instruction may already have been followed")

cat("\n-- Q3 takes its lines and its index dates from the same run --\n")
# Index dates from the NDMM cohort would drop every broad patient the NDMM
# exclusions removed out of the idx join. They stay in the denominator through
# the left join and can never match a diagnosis, so they read as having no
# other cancer - the opposite of the population Q3 recovers.
ok(any(grepl("broad_idx", bdq, fixed = TRUE)),
   "the broad run's own LOT_PATIENT_INPUT supplies the index dates")
ok(!any(grepl("index_date FROM {final_tbl}", bdq, fixed = TRUE)),
   "...not the NDMM cohort table beside it")

cat("\n-- Q5 does not claim an anchor its index date does not have --\n")
# The cohort sets INDEX_DATE = LOT1_START_DT, so Q5's index-anchored columns
# sit on the same date as its LOT1-anchored ones. Called a pre-diagnosis
# window they read as an independent second check, and two counts that look
# independent get added together.
nn <- readLines(file.path(STUDY, "ndmm", "R", "build_ndmm.R"), warn = FALSE)
ok(any(grepl("LOT1_START_DT AS INDEX_DATE", nn, fixed = TRUE)),
   "the cohort's INDEX_DATE is the 1L start, which is what makes the two anchors one")
ok(!any(grepl("parent-index", poma, fixed = TRUE)) &&
   !any(grepl("PARENT-INDEX", poma, fixed = TRUE)),
   "Q5 does not label those columns as a separate parent anchor")
ok(any(grepl("AS ce_gt_6mo_pre_index", poma, fixed = TRUE)) &&
   any(grepl("AS len_thal_gt_6mo_pre_index", poma, fixed = TRUE)),
   "...they are named for the window they measure and the anchor they measure it from")
ok(!any(grepl("obs_history_gt_6mo", poma, fixed = TRUE)) &&
   !any(grepl("early_len_thal_pre_baseline", poma, fixed = TRUE)),
   "...and no name implies a window before the diagnosis")

cat("\n-- an empty Blenrep line table says which of the two things it is --\n")
# MAP_STACKED is built before the line criteria, so it still holds belantamab
# exposure. no_belantamab is patient-level and truncates, so LOT_LONG_FINAL
# holds none of those patients' lines - an empty by-line table there is the
# study removing them, not the drug failing to reach a regimen.
clear(); Sys.setenv(DOMINO_USER_NAME = "usr00000", OBJECT_PREFIX = "ndmm_",
           INPUT_COHORT_TABLE = "ndmm_NDMM_COHORT")
invisible(qs_setup(ROOT))
apply_was <- Sys.getenv("APPLY_NO_BELANTAMAB", unset = NA)
Sys.setenv(APPLY_NO_BELANTAMAB = "FALSE")
ok(length(qs_truncating_criteria()) == 0,
   "with the criterion off, nothing was removed and the population can answer for itself")
Sys.setenv(APPLY_NO_BELANTAMAB = "TRUE")
tc <- qs_truncating_criteria()
# From the lot package's declaration, so a renamed flag cannot leave a
# hardcoded string here matching nothing and reporting 0 removed.
ok(length(tc) == 1L && identical(tc[[1]]$name, "no_belantamab") &&
   identical(tc[[1]]$flag, "NO_BELANTAMAB_ANY_LOT"),
   "...and with it on, the criterion and its flag come from the lot package")
ok(grepl("ndmm_LOT_LONG_ALLFLAGS$", qs_allflags_lines()),
   "the pre-truncate lines are that run's own, prefix and all")
if (is.na(apply_was)) Sys.unsetenv("APPLY_NO_BELANTAMAB") else
  Sys.setenv(APPLY_NO_BELANTAMAB = apply_was)
l1 <- readLines(file.path(ROOT, "lot1_studyteam_qs.R"), warn = FALSE)
ok(any(grepl("qs_truncating_criteria()", l1, fixed = TRUE)) &&
   any(grepl("qs_allflags_lines()", l1, fixed = TRUE)),
   "the Blenrep question asks what was removed, then reads the run before it was")
ok(!any(grepl("does not surface in any LOT_BASE_MEDS regimen string", l1, fixed = TRUE)),
   "...so it does not report a deliberate exclusion as an absent regimen")

cat("\n-- a steroid count says which version of the list produced it --\n")
# The LOT build refuses a code-list hash it cannot take: a count gets quoted
# whether or not the version behind it is known. This recorded "unknown" and
# carried on, which is the same number with nothing to trace it to.
source(file.path(ROOT, "validation_helpers.R"))
vh <- readLines(file.path(ROOT, "validation_helpers.R"), warn = FALSE)
# A directory passes file.exists() and hashes to NA - an unhashable file
# without needing to create one.
unhashable <- file.path(tempdir(), "qs_unhashable")
dir.create(unhashable, showWarnings = FALSE)
h <- suppressWarnings(vqs_build_steroid_claims(NULL, "lot_long", unhashable))
ok(is.null(h$view) && isTRUE(grepl("could not hash", h$note)),
   "an unhashable list skips Q3/Q4/Q5 rather than answering them against 'unknown'")
ok(!any(grepl('is.na(ster_md5), "unknown"', vh, fixed = TRUE)),
   "...so no steroid answer can carry a version nobody can look up")
ok(any(grepl("identical(ster_md5, ster_hash())", vh, fixed = TRUE)),
   "...and it is hashed again after the read, so a file re-issued mid-run is caught")
clear()

cat("\n-- Q6 asks the follow-up question the same way the dashboard does --\n")
# Q2 and Q4 are rates over a follow-up window, and the window is not the same
# length for every patient. Q6 is what says whether the two sides are
# comparable - so it has to carry both of the cohort's follow-up lengths, not
# whichever one is shorter to write.
q6 <- paste(pm, collapse = "\n")
ok(grepl("Q6 POMA & follow-up", q6, fixed = TRUE),
   "the POMA workbook has a follow-up tab")
ok(grepl("FU_DAYS", q6, fixed = TRUE) && grepl("FU_DAYS_CE", q6, fixed = TRUE),
   "...on both definitions - to death or study end, and capped at disenrolment")
# One grouping, used by all three of Q6's tables. A second spelling of the CASE
# on one tab is a second definition of who counts as a POMA patient, and the
# three tables would stop being about the same people. Counted as uses of the
# binding, not of the CASE text: other questions spell their own group label,
# and that is theirs to spell.
ok(grepl("q6_grp <- ", q6, fixed = TRUE) &&
     length(gregexpr("{q6_grp}", q6, fixed = TRUE)[[1]]) == 3L,
   "...with the POMA/other split written once and used by all three tables")
# A LOT1 patient with no cohort row has no follow-up columns, and
# percentile_approx ignores NULLs - so a silent drop shrinks the median's
# denominator while n_pts still reports the whole group.
ok(grepl("missing_cohort_rows", q6, fixed = TRUE) &&
     grepl("no cohort row (broken join)", q6, fixed = TRUE),
   "...and a patient with no cohort row is counted, not dropped into the median")
# Three things now report what ended follow-up: this workbook, the dashboard,
# and the paste-and-run script beside the cohort build. If they use different
# predicates they will disagree about who died, and nobody reading one of them
# can tell. Aliases differ between them, so they are compared with the alias
# stripped.
FU_SRC <- list(
  workbook  = file.path(ROOT, "poma_studyteam_qs.R"),
  dashboard = file.path(DASHPKG, "R", "sections.R"),
  sql       = file.path(STUDY, "ndmm", "followup_days.sql"))
nm <- function(f) gsub("\\s+", " ",
                       gsub("[fp]\\.", "",
                            paste(readLines(f, warn = FALSE), collapse = "\n")))
ok(all(vapply(FU_SRC, file.exists, logical(1))),
   paste0("every place that reports what ended follow-up is present (",
          length(FU_SRC), ")"))
txt <- lapply(FU_SRC, nm)
# Every death test bounded, not merely one of them somewhere in the file. A
# file with two and only one bounded still contains the right string, which is
# exactly the half-drift this is here to catch.
cnt <- function(pat, s) {
  g <- gregexpr(pat, s, fixed = TRUE)[[1]]
  if (length(g) == 1L && g[1] == -1L) 0L else length(g)
}
BOUND <- "DEATH_DT IS NOT NULL AND DEATH_DT <= ENDDATE_CE"
ok(all(vapply(txt, function(x) {
       n <- cnt("DEATH_DT IS NOT NULL", x)
       n > 0L && identical(n, cnt(BOUND, x))
     }, logical(1))),
   "...and every death test in all three is bounded by the CE follow-up end")
ok(all(vapply(txt, function(x) grepl("ENDDATE_CE < ENDDATE", x, fixed = TRUE),
              logical(1))),
   "...and all three read disenrolment the same way")
# The quick script exists so nobody has to wait for a build to see these
# numbers. That is only worth anything if they are the same numbers.
ok(grepl("FU_DAYS_CE", txt$sql, fixed = TRUE) &&
     grepl("percentile_approx(FU_DAYS, 0.5)", txt$sql, fixed = TRUE),
   "the quick script reports both follow-up lengths, as the other two do")

cat("\n", strrep("-", 52), "\n", sep = "")
cat(sprintf("%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
