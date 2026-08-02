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
bad <- Filter(function(f) any(grepl("\\bwrk\\(", readLines(f, warn = FALSE))), qs)
ok(!length(bad),
   if (length(bad)) paste0("still calling wrk(): ", paste(basename(bad), collapse = ", "))
   else "every table reference goes through qs_tbl()")
clear()

cat("\n", strrep("-", 52), "\n", sep = "")
cat(sprintf("%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
