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
          "OBJECT_PREFIX", "QS_ALLOW_NO_PREFIX")
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
runs(qs_setup(ROOT), "a named schema and prefix set the config up")
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
Sys.setenv(DOMINO_USER_NAME = "usr00000", QS_ALLOW_NO_PREFIX = "TRUE")
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
ok(file.exists(file.path(ROOT, "steroid_codes.csv")),
   "the steroid code list the timing questions need is here")

cat("\n-- the questions run over the study population --\n")
# LOT_LONG is the run before a truncating criterion removed anyone, so a
# denominator taken from it counts patients the study excluded. LOT_LONG_FINAL
# is what ships, and it is the default.
clear(); Sys.setenv(DOMINO_USER_NAME = "usr00000", OBJECT_PREFIX = "ndmm_")
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
i <- grep("mm_adj_in <- paste", poma)[1]
adj <- paste(poma[i:(i + 6)], collapse = " ")
ok(!grepl("SECONDARY MALIGNANT NEOPLASM OF BONE", adj, fixed = TRUE),
   "bone metastasis is not treated as MM-adjacent here either")
ok(grepl("MONOCLONAL GAMMOPATHY", adj, fixed = TRUE) &&
     grepl("PLASMA CELL LEUKEMIA", adj, fixed = TRUE),
   "...and the four the cohort build does keep are still kept")
clear()

cat("\n", strrep("-", 52), "\n", sep = "")
cat(sprintf("%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
