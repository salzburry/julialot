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
          "LOT_POPULATION", "LOT_COHORT", "BROAD_PREFIX", "FLAGS_TABLE")
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

cat("\n-- the flag table is the one this build writes --\n")
# The two builds do not agree on a name: the standalone cohort build writes
# NDMM_FLAGS_ALL, the broad one ELIG_COH_ALLFLAGS. Asking for the wrong one is
# not a harmless miss - under a reused prefix an old ELIG_COH_ALLFLAGS can be
# sitting there with nothing linking it to this cohort or LOT run.
clear(); Sys.setenv(DOMINO_USER_NAME = "usr00000", OBJECT_PREFIX = "ndmm_",
           INPUT_COHORT_TABLE = "ndmm_NDMM_COHORT")
invisible(qs_setup(ROOT))
ok(grepl("ndmm_NDMM_FLAGS_ALL$", qs_flags_table()),
   "the default is the table the cohort build here actually writes")
Sys.setenv(FLAGS_TABLE = "ELIG_COH_ALLFLAGS")
ok(grepl("ndmm_ELIG_COH_ALLFLAGS$", qs_flags_table()),
   "...and a cohort built by the broad build can name its own")
Sys.setenv(FLAGS_TABLE = "x; DROP TABLE y")
stops(qs_flags_table(), "...validated like every other configurable name")
Sys.unsetenv("FLAGS_TABLE")
nof <- Filter(function(f) any(grepl('qs_tbl("ELIG_COH_ALLFLAGS")',
                                    readLines(f, warn = FALSE), fixed = TRUE)), qs)
ok(!length(nof),
   if (length(nof)) paste0("still hardcodes the broad build's flag table: ",
                           paste(basename(nof), collapse = ", "))
   else "no script hardcodes a flag table the cohort build may not write")

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
