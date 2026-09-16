# Shared test helpers. Kept inside the LOT folder so the package stays
# copy-pasteable - nothing here reaches outside it.

pass <- 0L; fail <- 0L

# Coverage this run did NOT get. A suite whose executed blocks were skipped -
# no duckdb, no sqlglot, no python3 - has tested a fraction of what it claims,
# and reporting "0 failed" for it reads as a clean run. Each skip is counted
# and named, and an incomplete run exits non-zero unless the caller says it
# expected one (ALLOW_SKIPPED_TESTS=TRUE).
skipped <- 0L
# The reason is kept, not just counted. test_report_status() replays these at
# the end instead of guessing at a remedy - see there for what that cost.
skip_reasons <- character(0)
skip_note <- function(what) {
  skipped <<- skipped + 1L
  skip_reasons <<- c(skip_reasons, what)
  cat("  SKIP   ", what, "\n")   # skip_note's own print, not a bare one
}

# The tally is only as good as its wiring: a bare cat("SKIP ...") prints like a
# skip and counts as nothing, which is exactly how the first pass at this went
# wrong - eight sites in one suite and six in another were missed by hand. Each
# suite now checks its OWN source, so a skip site added later is caught by the
# suite it was added to rather than by whoever next reads the diff.
.suite_path <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  # The same "~+~" unescape. check_skip_wiring() reads THIS file, and without
  # it the path named no file, the check returned quietly, and the guard on
  # every suite's skip wiring was off on any checkout whose path has a space.
  if (length(a)) normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]), fixed = TRUE),
                               mustWork = FALSE) else NA_character_
})
check_skip_wiring <- function(path = .suite_path) {
  if (is.na(path) || !file.exists(path)) return(invisible(NULL))
  src <- readLines(path, warn = FALSE)
  # SKIP as a word, so a line that merely NAMES the ALLOW_SKIPPED_TESTS
  # variable is not read as a skip this suite printed. It is, spelt without
  # the lookahead - which is how the first run of this after the reporting
  # changed flagged the sentence that tells you how to accept a skip.
  bad <- grep('cat\\(.*"[^"]*SKIP(?![A-Za-z_])', src, perl = TRUE)
  # Not a comment describing one, and not skip_note's own printing line.
  bad <- bad[!grepl("^\\s*#", src[bad]) & !grepl("skip_note", src[bad], fixed = TRUE)]
  ok(length(bad) == 0L,
     paste0("every SKIP this suite prints goes through skip_note(), so it is counted",
            if (length(bad)) paste0(" [bare cat at line(s) ", paste(bad, collapse = ", "), "]") else ""))
}
test_report_status <- function(pass, fail, skipped) {
  cat(sprintf("%d passed, %d failed, %d skipped\n", pass, fail, skipped))
  if (skipped > 0L) {
    # What actually skipped, in its own words. This used to print the same
    # sentence in every suite - "Install duckdb and sqlglot" - whatever the
    # block had skipped for. On the dashboard suite that named the wrong
    # remedy: the block wanted survival::, both of the named packages were
    # already installed, and the reader was sent to reinstall them.
    cat("  ", skipped, " block(s) did not run, so this is NOT a clean run:\n", sep = "")
    for (r in skip_reasons) cat("    - ", r, "\n", sep = "")
    cat("  Fix those, or set ALLOW_SKIPPED_TESTS=TRUE to accept it.\n")
  }
  allow <- identical(toupper(trimws(Sys.getenv("ALLOW_SKIPPED_TESTS"))), "TRUE")
  if (fail > 0L || (skipped > 0L && !allow)) quit(status = 1L)
}
ok <- function(cond, what) {
  # `cond` is evaluated here, not by the caller, so an assertion whose
  # expression raises counts as a failure instead of aborting the run and
  # losing every result after it.
  cond <- tryCatch(cond, error = function(e) {
    what <<- paste0(what, "  [raised: ", conditionMessage(e), "]")
    FALSE
  })
  if (isTRUE(cond)) { pass <<- pass + 1L; cat("  ok    ", what, "\n") }
  else { fail <<- fail + 1L; cat("  FAIL  ", what, "\n") }
}
runs  <- function(expr, what) ok(!inherits(tryCatch(expr, error = function(e) e), "error"), what)
stops <- function(expr, what) ok(inherits(tryCatch(expr, error = function(e) e), "error"), what)
has   <- function(x, s) grepl(s, x, fixed = TRUE)

report <- function() {
  check_skip_wiring()
  cat("\n", strrep("-", 52), "\n", sep = "")
  test_report_status(pass, fail, skipped)
}

# glue is not installed everywhere; the templates only use {expr}, so a small
# stand-in keeps the tests runnable offline. Where the real package is present
# it must be attached, not merely loadable: the suites sys.source() each file
# into environments parented on globalenv, so glue() is found on the search
# path or not at all.
if (requireNamespace("glue", quietly = TRUE)) {
  library(glue)
} else {
  glue <- function(..., .envir = parent.frame()) {
    t <- paste0(..., collapse = "")
    m <- gregexpr("\\{[^{}]+\\}", t)[[1]]
    if (m[1] == -1L) return(t)
    len <- attr(m, "match.length"); out <- character(0); pos <- 1L
    for (i in seq_along(m)) {
      out <- c(out, substr(t, pos, m[i] - 1L),
               paste(as.character(eval(parse(
                 text = substr(t, m[i] + 1L, m[i] + len[i] - 2L)), .envir)),
                 collapse = ""))
      pos <- m[i] + len[i]
    }
    paste0(c(out, substr(t, pos, nchar(t))), collapse = "")
  }
  assign("glue", glue, envir = globalenv())
}
