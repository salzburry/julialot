#!/usr/bin/env Rscript
# Checks on the question scripts' setup.
#
# These EXECUTE _setup.R rather than parsing it. Parsing proved nothing: the
# first version had a top-level expression using `%||%` before it was defined,
# which parses cleanly and dies the moment it is sourced. No warehouse - only
# the wiring is tested, up to the point a connection would be needed.
#
#   Rscript "questions/tests/test_setup.R"

ROOT <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                                 fixed = TRUE))) else getwd()
  dirname(d)
})

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
# older unprefixed table is in the schema it finds THAT, and answers about a
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
# NOT here. It is a governed production file, so a copy beside this script
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
cl <- readLines(file.path(dirname(ROOT), "lot", "R", "codelists_lot.R"), warn = FALSE)
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
# The old switch chose between two cohorts, one of which is not produced any
# more. Silently reinterpreting it would be worse than stopping.
Sys.setenv(LOT_COHORT = "NDMM")
stops(qs_population(), "the retired LOT_COHORT stops the run and names what replaced it")
Sys.unsetenv("LOT_COHORT")
# The table the old switch pointed at is gone from the code entirely.
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
# Not by keeping a matching copy of the list - by reading the build's own
# answer. is_mm_adjacent_override is what the cohort actually applied, so there
# is one derivation of the rule and the two cannot disagree at all.
ok(any(grepl('qs_tbl("NDMM_OTHER_MALIG_CODES")', poma, fixed = TRUE)),
   "it reads the code list the cohort build resolved and persisted")
ok(any(grepl("is_mm_adjacent_override AS is_mm_adj", poma, fixed = TRUE)),
   "...taking the build's own MM-adjacent decision rather than restating it")
ok(!any(grepl("SECONDARY MALIGNANT NEOPLASM OF BONE", poma, fixed = TRUE)),
   "...so no tumour-group list is duplicated here to drift")
# Loading the CSV would mean re-deriving the rule, which is what drifted.
ok(!any(grepl("load_codelist_csv", poma, fixed = TRUE)),
   "and it does not rebuild the list from the CSV")
# The code did the build's thing while the narrative beside it still told the
# reader the opposite. A workbook is read for its words, so that is a wrong
# answer shipped in the deliverable.
ok(!any(grepl("secondary bone - MM-spectrum", poma, fixed = TRUE)),
   "...and the narrative no longer calls secondary bone MM-spectrum")
# Q3's association is a BROAD-cohort question. One prefix is one cohort, and
# this cohort already excluded patients with a qualifying other cancer - so
# answering it from this run would be near-zero by construction.
ok(any(grepl("BROAD_PREFIX", poma, fixed = TRUE)),
   "Q3's broad-cohort association names the broad run explicitly")
ok(any(grepl("Q3 association: skipped", poma, fixed = TRUE)),
   "...and says it is skipped rather than answering from the study population")
clear()

cat("\n-- the trial flags come from the build that has them --\n")
# The two builds write different tables, and they are NOT alternate names for
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
# The two tables are NOT named the same way. ELIG_COH_ALLFLAGS is a checkpoint,
# so it is written prefixed. The final cohort is persisted straight from that
# build's FINAL_TABLE_NAME with no prefix at all - overall/config.csv sets it
# to OVERALL_COH_FINAL. Deriving <prefix>ELIG_COH_FINAL asks for a table the
# build never writes.
ovc <- readLines(file.path(dirname(ROOT), "overall", "config.csv"), warn = FALSE)
ok(any(grepl("^FINAL_TABLE_NAME,OVERALL_COH_FINAL", ovc)),
   "the broad build names its final cohort OVERALL_COH_FINAL, not ELIG_COH_FINAL")
asm <- readLines(file.path(dirname(ROOT), "overall", "R", "steps", "08_assembly.R"),
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
nn6 <- readLines(file.path(dirname(ROOT), "nndm", "R", "steps", "06_flags.R"),
                 warn = FALSE)
ok(!any(grepl("OTHER_MALIGN_FLAG", nn6, fixed = TRUE)) &&
   !any(grepl("CLINTRIAL_", nn6, fixed = TRUE)),
   "...and NDMM_FLAGS_ALL genuinely has none of them, which is why it cannot be the default")
ov <- readLines(file.path(dirname(ROOT), "overall", "R", "steps", "08_assembly.R"),
                warn = FALSE)
ok(any(grepl("OTHER_MALIGN_FLAG", ov, fixed = TRUE)) &&
   any(grepl("CLINTRIAL_BASELINE", ov, fixed = TRUE)),
   "...while ELIG_COH_ALLFLAGS does")
for (f in c("poma_studyteam_qs.R", "lot1_studyteam_qs.R")) {
  ln <- readLines(file.path(ROOT, f), warn = FALSE)
  ok(any(grepl("qs_trial_flags_ready(con)", ln, fixed = TRUE)),
     paste0(f, " checks the columns, not just that the table is readable"))
  ok(!any(grepl("qs_flags_table", ln, fixed = TRUE)),
     paste0("...and no longer treats the two flag tables as interchangeable"))
  # The join has to be flags-to-its-own-final. Against the cohort table it
  # compares a diagnosis-based index with the LOT1 start.
  ok(!any(grepl("{final_tbl} e ON", ln, fixed = TRUE)),
     paste0("...and does not align that build's flags to this cohort's INDEX_DATE"))
}
# The flag build is a different cohort. An inner join dropped the LOT1 patients
# it does not have, silently, and a loss that falls differently on POMA and
# other-1L makes the rates a comparison of who is in the second cohort.
pm <- readLines(file.path(ROOT, "poma_studyteam_qs.R"), warn = FALSE)
ok(any(grepl("FROM lot1 l LEFT JOIN f USING (PATID)", pm, fixed = TRUE)),
   "Q4 keeps the full NDMM group as the denominator rather than inner-joining it away")
ok(any(grepl("AS n_matched", pm, fixed = TRUE)) &&
   any(grepl("AS pct_matched", pm, fixed = TRUE)),
   "...and shows the overlap, so a low rate can be told from a small overlap")
# Q4's rates only. Q3's two tables denominate on their own full population by
# construction, and the NDMM audit reports its unmatched rows as a column.
ok(sum(grepl("nullif(count(f.PATID),0)", pm, fixed = TRUE)) >= 3,
   "...with Q4's rates over the matched count, not the unmatched-inflated one")
# Neither flag brackets the pre-LOT1 window: baseline ends before that build's
# diagnosis index, follow-up starts there and runs past LOT1.
ok(!any(grepl("HEADLINE on n_trial_baseline", pm, fixed = TRUE)),
   "...and baseline is no longer headlined as the prior-unobserved-therapy signal")

cat("\n-- the questions bind to the run that last wrote the tables --\n")
# Not the newest COMPLETE run. LOT replaces LOT_LONG_FINAL before validating
# it, so a rerun that replaced it and then failed leaves its table on disk
# while the previous complete row still looks like the newest good one - which
# is the case the guard exists for. The dashboard resolves ownership this way.
st <- readLines(file.path(ROOT, "_setup.R"), warn = FALSE)
ok(!any(grepl("upper(STATE) = 'COMPLETE'", st, fixed = TRUE)),
   "the binding does not filter to completed runs before taking the latest")
ok(any(grepl("ORDER BY UPDATED_AT DESC LIMIT 1", st, fixed = TRUE)) &&
   any(grepl("QS_IGNORE_BUILD_STATE", st, fixed = TRUE)),
   "...it takes the latest row whatever state it reached, and stops on an unfinished one")
dsh <- readLines(file.path(dirname(ROOT), "dashboard", "R", "db_utils_dash.R"),
                 warn = FALSE)
ok(any(grepl("DASH_IGNORE_BUILD_STATE", dsh, fixed = TRUE)),
   "...the same way the dashboard does, for the same reason")

cat("\n-- and the build behind the trial flags has to have finished --\n")
# The flags and the final cohort are separate writes. A run that stopped
# between them leaves two tables that are individually readable and carry every
# column, describing different attempts - columns alone cannot see that.
bc <- readLines(file.path(dirname(ROOT), "overall", "R", "build_cohort.R"),
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
ok(!any(grepl("qs_tbl(\"LOT_BUILD_STATUS\")", st, fixed = TRUE)),
   "...rather than the binding check being hardcoded to this run's prefix")
ok(any(grepl("qs_broad_run_state(con, broad_pfx)", pm, fixed = TRUE)),
   "Q3 asks whether the broad run finished before reading its lines")
ok(any(grepl("QS_IGNORE_BROAD_BUILD_STATE", st, fixed = TRUE)),
   "...with its own override, for a broad run known to have failed early")
# Skips that half, not the workbook: the audit and every other tab are over
# this run's tables and do not depend on the broad one.
ok(any(grepl("Q3 association: skipped - ", pm, fixed = TRUE)) &&
   any(grepl("The NDMM audit below still runs.", pm, fixed = TRUE)),
   "...and an unfinished broad run costs that half only")
# "The broad cohort" should name a population, not a prefix.
ok(any(grepl("BROAD RUN: lines and index dates from prefix", pm, fixed = TRUE)),
   "...and the tab says which cohort that run was built from")

cat("\n-- a run records the CDM vintage it read --\n")
# STUDY_END picks the quarterly table and the quarterlies are cumulative. Q3
# takes lines and index dates from the broad run, then scans the raw CDM itself
# at THIS run's vintage - so a different STUDY_END pairs that run's patients
# with a later version of their claims. Without the date recorded the mismatch
# could only be declared, never detected.
bl <- readLines(file.path(dirname(ROOT), "lot", "R", "build_lot.R"), warn = FALSE)
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
ok(any(grepl('paste0("VINTAGE: ", broad$vintage)', pm, fixed = TRUE)),
   "...with Q3 carrying the mismatch onto the tab, since that is where it bites")

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
ok(!any(grepl("THEN 'ICD9' ELSE 'ICD10' END", pm, fixed = TRUE)),
   "Q3 no longer defaults an unrecognised claim flag to ICD10")
ok(any(grepl("qs_icd_family_sql('d.ICD_FLAG')", pm, fixed = TRUE)),
   "...it uses the same three-way rule, with NULL for unknown")
ok(grepl("ELSE NULL END$", qs_icd_family_sql("x")),
   "...which really does yield NULL rather than a family")
# The lists cannot be sourced from nndm - that file defines its own
# load_codelist_csv() and would replace lot's - so they are repeated, and this
# is what stops the copy drifting.
nc <- readLines(file.path(dirname(ROOT), "nndm", "R", "codelists.R"), warn = FALSE)
grab <- function(v) {
  ln <- grep(paste0("^", v, "\\s*<-"), nc, value = TRUE)[1]
  sort(trimws(gsub('"', "", unlist(strsplit(gsub("^.*c\\(|\\).*$", "", ln), ",")))))
}
ok(identical(grab("RAW_ICD9"), sort(QS_RAW_ICD9)) &&
   identical(grab("RAW_ICD10"), sort(QS_RAW_ICD10)),
   "...and the spellings still match the cohort builds' own lists")
nw <- readLines(file.path(dirname(ROOT), "nndm", "R", "build_nndm.R"), warn = FALSE)
ok(any(grepl('"raw_icd_flag"', nw, fixed = TRUE)),
   "...which matters because that check is waivable, so the flags can be unrecognised")

cat("\n-- no workbook tells anyone to edit a production code list --\n")
# steroid_codes.csv is read from CODELIST_DIR, the directory the LOT build
# reads its four from, and every steroid answer quotes its md5. Emptying it to
# change one workbook's display edits what other studies read.
lf <- readLines(file.path(ROOT, "lot_followup_qs.R"), warn = FALSE)
ok(!any(grepl("empty steroid_codes.csv", lf, fixed = TRUE) &
        !grepl("Do NOT empty steroid_codes.csv", lf, fixed = TRUE)),
   "the follow-up workbook no longer says to empty the production steroid list")
ok(any(grepl("Do NOT empty steroid_codes.csv", lf, fixed = TRUE)),
   "...and says why not, since the old instruction may already have been followed")

cat("\n-- Q3 takes its lines and its index dates from the same run --\n")
# Index dates from the NDMM cohort would drop every broad patient the NDMM
# exclusions removed out of the idx join. They stay in the denominator through
# the left join and can never match a diagnosis, so they read as having no
# other cancer - the opposite of the population Q3 recovers.
ok(any(grepl("broad_idx", poma, fixed = TRUE)),
   "the broad run's own LOT_PATIENT_INPUT supplies the index dates")
ok(!any(grepl("index_date FROM {final_tbl}", poma, fixed = TRUE)),
   "...not the NDMM cohort table beside it")

cat("\n-- Q5 does not claim an anchor its index date does not have --\n")
# The cohort sets INDEX_DATE = LOT1_START_DT, so Q5's index-anchored columns
# sit on the SAME date as its LOT1-anchored ones. Called a pre-diagnosis
# window they read as an independent second check, and two counts that look
# independent get added together.
nn <- readLines(file.path(dirname(ROOT), "nndm", "R", "build_nndm.R"), warn = FALSE)
ok(any(grepl("LOT1_START_DT AS INDEX_DATE", nn, fixed = TRUE)),
   "the cohort's INDEX_DATE is the 1L start, which is what makes the two anchors one")
ok(!any(grepl("parent-index", poma, fixed = TRUE)) &&
   !any(grepl("PARENT-INDEX", poma, fixed = TRUE)),
   "Q5 no longer labels those columns as a separate parent anchor")
ok(any(grepl("AS ce_gt_6mo_pre_index", poma, fixed = TRUE)) &&
   any(grepl("AS len_thal_gt_6mo_pre_index", poma, fixed = TRUE)),
   "...they are named for the window they measure and the anchor they measure it from")
ok(!any(grepl("obs_history_gt_6mo", poma, fixed = TRUE)) &&
   !any(grepl("early_len_thal_pre_baseline", poma, fixed = TRUE)),
   "...and the old names, which implied a window before the diagnosis, are gone")

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
   "...so it no longer reports a deliberate exclusion as an absent regimen")

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

cat("\n", strrep("-", 52), "\n", sep = "")
cat(sprintf("%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
