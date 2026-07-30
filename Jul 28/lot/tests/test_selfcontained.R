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
# This file names the things it forbids, so it would flag itself.
keep  <- rel != "tests/test_selfcontained.R"
files <- files[keep]; rel <- rel[keep]
code  <- setNames(lapply(files, readLines, warn = FALSE), rel)
# Comments talk about apr_30_2026 and the cohort build; only code matters here.
live  <- lapply(code, function(l) l[!grepl("^\\s*#", l)])

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

cat("\n-- the package names no cohort of its own --\n")
# A standalone LOT knows nothing about the studies that use it. The caller
# passes the cohort table and prefix; the moment a study name is baked in
# here, copying the folder stops being enough.
docs <- list.files(ROOT, pattern = "\\.(R|csv|md)$", recursive = TRUE,
                   full.names = TRUE)
docs <- docs[!grepl("tests/test_selfcontained\\.R$", docs)]
COHORT_NAMES <- c("OVERALL_COH_FINAL", "ELIG_COH_FINAL", "NDMM", "ndmm",
                  "overall_", "NNDM", "nndm")
for (f in docs) {
  nm <- sub(paste0("^", ROOT, "/"), "", f)
  txt <- readLines(f, warn = FALSE)
  hits <- unlist(lapply(COHORT_NAMES, function(cn)
    grep(cn, txt, fixed = TRUE, value = TRUE)))
  ok(length(hits) == 0,
     paste0(nm, ": names no cohort",
            if (length(hits)) paste0(" (", trimws(hits[1]), ")") else ""))
}

cat("\n-- the pieces a copy needs are all present --\n")
NEED <- c("build.R", "config.csv", "R/build_lot.R", "R/config_lot.R",
          "R/db_utils_lot.R", "R/codelists_lot.R", "R/line_criteria.R",
          "R/load_inputs.R", "tests/testutil.R")
for (f in NEED)
  ok(file.exists(file.path(ROOT, f)), paste0(f, " is in the folder"))

report()
