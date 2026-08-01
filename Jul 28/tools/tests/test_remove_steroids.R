#!/usr/bin/env Rscript
# The rollup is a governed file shared with the source build, and the script edits
# it in place, so the things that matter are: it removes exactly the steroid
# rows, it leaves every other byte alone, and it refuses rather than guesses.
#
#   Rscript "tools/tests/test_remove_steroids.R"

ROOT <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                                 fixed = TRUE))) else getwd()
  dirname(d)
})
SCRIPT <- file.path(ROOT, "remove_steroids_from_rollup.R")

PASS <- 0L; FAIL <- 0L
ok <- function(cond, what) {
  if (isTRUE(cond)) { PASS <<- PASS + 1L; cat("  ok     ", what, "\n")
  } else            { FAIL <<- FAIL + 1L; cat("  FAIL   ", what, "\n") }
}
report <- function() {
  cat("\n----------------------------------------------------\n")
  cat(PASS, " passed, ", FAIL, " failed\n", sep = "")
  quit(status = if (FAIL > 0L) 1L else 0L)
}

# A rollup with enough medications to clear the minimum, plus the awkward
# cases: a lowercase padded class, a quoted field with a comma in it, and a
# dual-maintenance reference to a steroid that is about to go.
mk_rows <- function(n_keep) {
  keep <- vapply(seq_len(n_keep), function(i)
    sprintf("IMID,MED%02d,,No", i), character(1))
  keep[1] <- "IMID,MED01,\"DEX, BOR\",No"
  c("CL_MED_CLASS,CL_MED_ABBR,DUALMAINTENANCEWITH,MONOMAINTENANCE",
    keep, " steroid ,DEX,,No", "STEROID,PRED,,No")
}
write_raw <- function(path, lines, eol = "\n", final_eol = TRUE) {
  txt <- paste0(paste(lines, collapse = eol), if (final_eol) eol else "")
  con <- file(path, "wb"); writeBin(charToRaw(txt), con); close(con)
}
mk_dir <- function(eol = "\n", final_eol = TRUE, n_keep = 25L,
                   codelist = c("PI,BOR", "IMID,LEN"),
                   code_header = "CL_MED_CLASS,CL_MED_ABBR") {
  d <- file.path(tempdir(), paste0("cl", as.integer(runif(1, 1, 1e9))))
  dir.create(d, showWarnings = FALSE)
  write_raw(file.path(d, "cl_mma_rollup.csv"), mk_rows(n_keep), eol, final_eol)
  if (!is.null(codelist))
    write_raw(file.path(d, "cl_mma_codelist.csv"), c(code_header, codelist))
  d
}
run <- function(d, args = character(0)) {
  out <- suppressWarnings(system2("Rscript", c(shQuote(SCRIPT), args),
                                  stdout = TRUE, stderr = TRUE,
                                  env = paste0("CODELIST_DIR=", d)))
  list(out = paste(out, collapse = "\n"),
       status = if (is.null(attr(out, "status"))) 0L else attr(out, "status"))
}
bytes <- function(p) readBin(p, "raw", file.size(p))

cat("\n-- the rows that go, and only those --\n")
d <- mk_dir()
p <- file.path(d, "cl_mma_rollup.csv")
before <- bytes(p)
r <- run(d)
ok(r$status == 0L, "report mode succeeds")
ok(identical(bytes(p), before), "report mode does not touch the file")
ok(grepl("DEX, PRED", r$out), "it names both steroids, including the padded one")
ok(grepl("dual-maintenance partner", r$out),
   "and flags the reference left behind in a quoted field")

r <- run(d, "--write")
ok(r$status == 0L, "the write succeeds")
after <- readLines(p, warn = FALSE)
ok(!any(grepl("steroid", after, ignore.case = TRUE)), "no steroid row survives")
ok(length(after) == 26L, "every other row survives")
ok(any(grepl('"DEX, BOR"', after, fixed = TRUE)),
   "a quoted field with a comma is not reformatted")

cat("\n-- kept bytes are the original bytes --\n")
for (case in list(list(eol = "\r\n", fin = TRUE,  what = "CRLF endings survive"),
                  list(eol = "\n",   fin = FALSE, what = "a missing final newline survives"),
                  list(eol = "\r\n", fin = FALSE, what = "both at once survive"))) {
  d <- mk_dir(eol = case$eol, final_eol = case$fin)
  p <- file.path(d, "cl_mma_rollup.csv")
  orig <- bytes(p)
  invisible(run(d, "--write"))
  now <- bytes(p)
  # The output is the input minus the two steroid lines, byte for byte. They
  # are last, and each carries its own terminator except the final line of a
  # file with no trailing newline - so the last KEPT line keeps the terminator
  # it always had, and the result still ends in one.
  drop <- charToRaw(paste0(" steroid ,DEX,,No", case$eol, "STEROID,PRED,,No",
                           if (case$fin) case$eol else ""))
  ok(identical(now, orig[seq_len(length(orig) - length(drop))]), case$what)
}

cat("\n-- it refuses rather than guesses --\n")
d <- mk_dir(codelist = c("PI,BOR", "STEROID,DEX"))
p <- file.path(d, "cl_mma_rollup.csv"); before <- bytes(p)
r <- run(d, "--write")
ok(r$status != 0L, "a code list carrying a removed abbreviation stops it")
ok(identical(bytes(p), before), "and the rollup is untouched")
ok(grepl("DEX", r$out) && grepl("no class or flags", r$out),
   "the message says what would break")

d <- mk_dir(codelist = c("STEROID,PRED"))
r <- run(d, "--write")
ok(r$status != 0L, "a code list with STEROID rows of its own stops it")

d <- mk_dir(codelist = NULL)
r <- run(d, "--write")
ok(r$status != 0L, "a missing code list stops it - the premise is unverifiable")

# The claim is that the code list has no steroids, which cannot be shown
# without the class column - and 01_codelists.R requires it of the same file.
d <- mk_dir(code_header = "CL_MED_ABBR", codelist = c("BOR", "LEN"))
p <- file.path(d, "cl_mma_rollup.csv"); before <- bytes(p)
r <- run(d, "--write")
ok(r$status != 0L, "a code list with no CL_MED_CLASS stops it")
ok(grepl("CL_MED_CLASS", r$out), "and names the column it needs")
ok(identical(bytes(p), before), "leaving the rollup alone")

d <- mk_dir(n_keep = 5L)
p <- file.path(d, "cl_mma_rollup.csv"); before <- bytes(p)
r <- run(d, "--write")
ok(r$status != 0L, "an edit that would fall below the build's minimum stops it")
ok(identical(bytes(p), before), "and that rollup is untouched too")

d <- mk_dir()
r <- run(d, "--wrote")
ok(r$status != 0L, "a mistyped flag is refused, not silently read as report mode")

cat("\n-- a file that moves under it --\n")
# Real concurrency cannot be timed reliably from a test, so put the write
# exactly where it would hurt: take the real script and insert one line just
# before the backup, after both files have been read and md5'd. Everything
# downstream - including the two re-checks - is the shipped code.
inject <- function(d, line) {
  s <- readLines(SCRIPT, warn = FALSE)
  at <- grep("bak  <- paste0(path, \".bak.\"", s, fixed = TRUE)
  stopifnot(length(at) == 1)
  f <- file.path(d, "injected.R")
  writeLines(append(s, line, after = at - 1L), f)
  f
}
run_injected <- function(d, line) {
  f <- inject(d, line)
  out <- suppressWarnings(system2("Rscript", c(shQuote(f), "--write"),
                                  stdout = TRUE, stderr = TRUE,
                                  env = paste0("CODELIST_DIR=", d)))
  list(out = paste(out, collapse = "\n"),
       status = if (is.null(attr(out, "status"))) 0L else attr(out, "status"))
}
d <- mk_dir(); p <- file.path(d, "cl_mma_rollup.csv"); before <- bytes(p)
r <- run_injected(d, 'cat("STEROID,DEX\n", file = code_path, append = TRUE)')
ok(r$status != 0L, "a code list edited mid-run stops it before the rename")
ok(grepl("code list changed while this was running", r$out),
   "and says the premise may no longer hold")
ok(identical(bytes(p), before), "with the rollup untouched")

# A same-size edit, so this reaches the md5 check rather than being caught by
# the size comparison before it. Both guards are wanted; this is the one that
# would otherwise never be exercised.
d <- mk_dir(); p <- file.path(d, "cl_mma_rollup.csv")
r <- run_injected(d, paste(
  'local({ b <- readBin(path, "raw", file.size(path));',
  '        b[length(b) - 1L] <- charToRaw("X"); writeBin(b, path) })'))
ok(r$status != 0L, "a rollup edited mid-run stops it too")
ok(grepl("rollup changed while this was running", r$out), "and says which file")
ok(grepl("NX", rawToChar(bytes(p)), fixed = TRUE),
   "the other edit survives rather than being overwritten")

cat("\n-- the file keeps its permissions --\n")
d <- mk_dir(); p <- file.path(d, "cl_mma_rollup.csv")
Sys.chmod(p, "664", use_umask = FALSE)
was <- file.info(p)$mode
invisible(run(d, "--write"))
ok(identical(file.info(p)$mode, was),
   paste0("mode survives the replacement (", format(was), ")"))

cat("\n-- nothing is left behind --\n")
d <- mk_dir()
invisible(run(d, "--write"))
ok(!length(list.files(d, pattern = "\\.tmp\\.")), "no temporary file remains")
ok(length(list.files(d, pattern = "\\.bak\\.")) == 1L, "a backup was kept")
# Process death cannot be staged here, so assert the shape that makes it safe:
# the new bytes go to a temporary file and a rename is the only thing that ever
# touches the original. A writeBin or writeLines onto `path` would not be
# atomic no matter what checks surrounded it.
src <- readLines(SCRIPT, warn = FALSE)
ok(any(grepl("writeBin(unlist(lines_raw[keep]), tmp)", src, fixed = TRUE)) &&
     !any(grepl("write(Bin|Lines)\\([^)]*, *path\\)", src)),
   "the original is only ever replaced, never written over")
ok(any(grepl("file.rename(tmp, path)", src, fixed = TRUE)),
   "and replaced by rename, which is atomic within one filesystem")
r <- run(d, "--write")
ok(grepl("Nothing to do", r$out), "a second run has nothing to do")

cat("\n-- the minimum matches the one the build enforces --\n")
lot <- file.path(dirname(ROOT), "lot", "R", "steps", "01_codelists.R")
if (file.exists(lot)) {
  b <- grep("min_rollup_meds <- ", readLines(lot, warn = FALSE), value = TRUE)[1]
  s <- grep("MIN_ROLLUP_MEDS <- ", readLines(SCRIPT, warn = FALSE), value = TRUE)[1]
  num <- function(x) as.integer(gsub("\\D", "", sub("#.*", "", x)))
  ok(identical(num(b), num(s)),
     paste0("the script's minimum is the build's (", num(s), ")"))
} else {
  cat("  ..     lot/ is not beside this folder; skipping\n")
}

report()
