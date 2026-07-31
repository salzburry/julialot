#!/usr/bin/env Rscript
# This folder is meant to be copied into another project as-is. That only
# stays true if nothing in it reaches outside itself, so check rather than
# hope.
#
#   Rscript "Jul 28/lot/tests/test_selfcontained.R"

ROOT <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                                 fixed = TRUE))) else getwd()
  dirname(d)
})
source(file.path(ROOT, "tests", "testutil.R"))

files <- list.files(ROOT, pattern = "\\.R$", recursive = TRUE, full.names = TRUE)
rel   <- sub(paste0("^", ROOT, "/"), "", files)
# Two exclusions, both justified below:
#   this file names the things it forbids, so it would flag itself;
#   test_same_as_source.R compares against apr_30_2026 on purpose, and is a
#   development check rather than part of the package - it is asserted to skip
#   cleanly when that folder is absent.
SELF <- "tests/test_selfcontained.R"; EQUIV <- "tests/test_same_as_source.R"
keep  <- !rel %in% c(SELF, EQUIV)
files <- files[keep]; rel <- rel[keep]
code  <- setNames(lapply(files, readLines, warn = FALSE), rel)
# Only code matters. Strip R comments and the SQL "--" comments inside the
# glue strings - those discuss other files by name and are not dependencies.
live  <- lapply(code, function(l) l[!grepl("^\\s*(#|--)", l)])

cat("\n-- nothing points outside this folder --\n")
ok(length(files) > 0, paste0("found ", length(files), " R files"))

# Only lines that resolve a path can leave the folder. Scanning every line
# instead flags R's own "..." and the cohort named "overall", which are not
# paths - and a check that cries wolf gets deleted.
PATH_CALL <- paste0("source\\(|sys\\.source\\(|file\\.path\\(|setwd\\(|",
                    "readLines\\(|read\\.csv\\(|list\\.files\\(|normalizePath\\(")
# R writes a parent hop as file.path(here, ".."), so match the quoted segment
# as well as the slash form.
OUTSIDE <- c("[\"']\\.\\.[\"']", "\\.\\./",
             "apr_30_2026", "jun_21_2026", "cohort_explorer",
             "[\"']overall[\"']", "overall/")
for (nm in names(live)) {
  path_lines <- grep(PATH_CALL, live[[nm]], value = TRUE)
  hits <- unlist(lapply(OUTSIDE, function(o) grep(o, path_lines, value = TRUE)))
  ok(length(hits) == 0,
     paste0(nm, ": no path outside the folder",
            if (length(hits)) paste0(" (", trimws(hits[1]), ")") else ""))
}

cat("\n-- every source() resolves inside the folder --\n")
srcs <- unlist(lapply(live, function(l) grep("source\\(|sys\\.source\\(", l, value = TRUE)))
ok(length(srcs) > 0, "there are source() calls to check")
ok(all(grepl("here|ROOT|steps", srcs)),
   "all of them are built from the folder root, not a fixed path")
ok(!any(grepl("source\\(\"/", srcs)), "none of them is an absolute path")

cat("\n-- the only outside dependencies are R packages --\n")
# Declared so adding one is a deliberate act. odbc/DBI reach the warehouse,
# glue writes the SQL; nothing else should creep in.
ALLOWED <- c("DBI", "odbc", "glue", "utils", "tools", "stats", "methods")
# Every occurrence, not one per line: build.R loads three on a single line.
all_lines <- unlist(live, use.names = FALSE)
grab <- function(pat, drop) {
  m <- regmatches(all_lines, gregexpr(pat, all_lines, perl = TRUE))
  sub(drop, "", unlist(m))
}
used <- unique(c(grab("(?<=library\\()[A-Za-z0-9.]+", ""),
                 grab("(?<=requireNamespace\\(\")[A-Za-z0-9.]+", ""),
                 grab("[A-Za-z0-9.]+(?=::)", "")))
used <- used[nzchar(used)]
extra <- setdiff(used, ALLOWED)
ok(length(extra) == 0,
   paste0("packages used: ", paste(sort(used), collapse = ", "),
          if (length(extra)) paste0(" -- undeclared: ", paste(extra, collapse = ", ")) else ""))

cat("\n-- the package registers no cohort --\n")
# Neutrality is structural, not a list of banned words: there is nowhere for a
# cohort to be registered, so the caller has to supply one. A blacklist of
# study names could not prove this, and would have put those names in here.
bl <- readLines(file.path(ROOT, "R", "build_lot.R"), warn = FALSE)
ok(!any(grepl("^COHORTS\\s*<-", bl)), "there is no cohort registry to fall out of date")
ok(any(grepl("pin_cohort <- function\\(cfg, cohort_table, prefix\\)", bl)),
   "the cohort table and prefix are arguments")
bd <- readLines(file.path(ROOT, "build.R"), warn = FALSE)
ok(any(grepl("commandArgs\\(trailingOnly = TRUE\\)", bd)) &&
     any(grepl("INPUT_COHORT_TABLE", bd)),
   "the entry point takes them from the caller or the environment")

cat("\n-- the one test that looks outside degrades cleanly --\n")
# It reads apr_30_2026 to prove the port is faithful. A copied-out package has
# no such folder, so it must skip rather than fail - otherwise the copy arrives
# with a red suite.
eq <- readLines(file.path(ROOT, EQUIV), warn = FALSE)
ok(any(grepl("if (!file.exists(SRC))", eq, fixed = TRUE)) &&
     any(grepl("quit(status = 0L)", eq, fixed = TRUE)),
   "test_same_as_source.R skips when apr_30_2026 is not there")
# One line resolves the path; the rest are the comment and the skip message.
eq_code <- eq[!grepl("^\\s*#", eq)]
eq_path <- grep("file\\.path\\(.*apr_30_2026", eq_code, value = TRUE)
ok(length(eq_path) == 1, "and only one line in it resolves that path")

cat("\n-- the pieces a copy needs are all present --\n")
NEED <- c("build.R", "config.csv", "R/build_lot.R", "R/config_lot.R",
          "R/db_utils_lot.R", "R/codelists_lot.R", "R/line_criteria.R",
          "R/load_inputs.R", "tests/testutil.R")
for (f in NEED)
  ok(file.exists(file.path(ROOT, f)), paste0(f, " is in the folder"))

cat("\n-- one definition per step, not two --\n")
# The fresh-session path used to carry its own copies of the code-list,
# cohort and SCT SQL. They drifted: guards added to the LOT1 code lists never
# reached them, and its cohort view ignored censor_at_disenrollment. It calls
# the LOT1 phases now, so a step must be defined exactly once.
defs <- list()
for (f in list.files(file.path(ROOT, "R", "steps"), "\\.R$", full.names = TRUE)) {
  for (n in unlist(regmatches(readLines(f, warn = FALSE),
        gregexpr('(?<=run_step\\(con, ")[^"]+', readLines(f, warn = FALSE), perl = TRUE))))
    defs[[n]] <- c(defs[[n]], basename(f))
}
dup <- names(defs)[vapply(defs, length, integer(1)) > 1]
ok(length(dup) == 0,
   if (length(dup)) paste0("step defined more than once: ", paste(dup, collapse = ", "))
   else paste0("all ", length(defs), " steps are defined exactly once"))
fresh <- readLines(file.path(ROOT, "R", "steps", "09_lot2_5_inputs.R"), warn = FALSE)
ok(!any(grepl("CREATE OR REPLACE TEMPORARY VIEW (mma_rollup|sct_codelist|lot_patient_input)",
               fresh)),
   "the fresh-session path defines no code-list or cohort view of its own")
ok(all(vapply(c("phase_codelists", "phase_patient_input", "phase_sct"),
              function(f) any(grepl(paste0(f, "(con"), fresh, fixed = TRUE)), logical(1))),
   "it calls the LOT1 phases instead")

cat("\n-- the entry point can actually run --\n")
# These fail until the rules are ported. That is the honest state: the previous
# version of this file checked only that files existed, so it passed a package
# whose entry point dies on an undefined function.
mod <- new.env(parent = globalenv())
for (f in c("R/load_inputs.R", "R/build_lot.R", "R/config_lot.R",
            "R/db_utils_lot.R", "R/codelists_lot.R", "R/line_criteria.R"))
  try(sys.source(file.path(ROOT, f), envir = mod), silent = TRUE)
steps_dir <- file.path(ROOT, "R", "steps")
step_files <- if (dir.exists(steps_dir)) list.files(steps_dir, "\\.R$") else character(0)
for (f in file.path(steps_dir, step_files)) try(sys.source(f, envir = mod), silent = TRUE)

ok(length(step_files) > 0, paste0("R/steps has the rules (", length(step_files), " files)"))

# Every bare call in build.R has to resolve, or the run dies at the first one.
src <- paste(readLines(file.path(ROOT, "build.R"), warn = FALSE), collapse = "\n")
src <- gsub('"[^"]*"', '""', src)
src <- gsub("'[^']*'", "''", src)
src <- gsub("#[^\n]*", "", src)
called <- unique(sub("\\($", "", regmatches(src,
  gregexpr("(?<![$:\\w.])[A-Za-z_][A-Za-z0-9_.]*\\(", src, perl = TRUE))[[1]]))
unresolved <- Filter(function(f) !exists(f, envir = mod) && !exists(f), called)
ok(length(unresolved) == 0,
   if (length(unresolved)) paste0("build.R calls undefined: ",
                                  paste(unresolved, collapse = ", "))
   else paste0("all ", length(called), " calls in build.R resolve"))

# Every step has to parse. A syntax error here would only surface mid-run,
# after the connection is open and the earlier phases have already written.
for (f in file.path(steps_dir, step_files)) {
  e <- tryCatch({ parse(f); NULL }, error = function(e) e)
  ok(is.null(e), paste0(basename(f), ": parses",
                        if (!is.null(e)) paste0(" -- ", conditionMessage(e)) else ""))
}

# ...and every function the steps call has to exist. glue comes from the
# package build.R loads, so it resolves at run time even when absent here.
sraw <- paste(unlist(lapply(file.path(steps_dir, step_files), readLines, warn = FALSE)),
              collapse = "\n")
ssrc <- gsub("#[^\n]*", "", sraw)
ssrc <- gsub('"[^"]*"', '""', ssrc)
ssrc <- gsub("'[^']*'", "''", ssrc)
scalled <- unique(sub("\\($", "", regmatches(ssrc,
  gregexpr("(?<![$:\\w.])[A-Za-z_][A-Za-z0-9_.]*\\(", ssrc, perl = TRUE))[[1]]))
FROM_PKG <- c("glue")
# Functions assigned inside another one - sanitize_col lives in the middle of
# phase_codelists - are not visible in `mod`, so collect them from the source.
# Looser than scoping, but this check exists to catch a name that exists
# nowhere, and R itself catches one called out of scope.
#
# From the comment-stripped source, not the quote-collapsed one: an apostrophe
# in a comment shifts every quote pairing after it, and a span of real code
# then gets blanked out. That is why comments are stripped first above.
sdefs <- gsub("#[^\n]*", "", sraw)
slocal <- trimws(sub("\\s*<-.*", "", regmatches(sdefs,
  gregexpr("(?m)^\\s*[A-Za-z_][A-Za-z0-9_.]*\\s*<- function\\(",
           sdefs, perl = TRUE))[[1]]))
sbad <- Filter(function(f) !exists(f, envir = mod) && !exists(f) &&
                 !f %in% FROM_PKG && !f %in% slocal,
               scalled)
ok(length(sbad) == 0,
   if (length(sbad)) paste0("steps call undefined: ", paste(sbad, collapse = ", "))
   else paste0("all ", length(scalled), " calls in the steps resolve"))

report()
