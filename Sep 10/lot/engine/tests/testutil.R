# Shared test helpers. Kept inside the LOT folder so the package stays
# copy-pasteable - nothing here reaches outside it.

pass <- 0L; fail <- 0L

# Coverage this run did NOT get. A suite whose executed blocks were skipped -
# no duckdb, no sqlglot, no python3 - has tested a fraction of what it claims,
# and reporting "0 failed" for it reads as a clean run. Each skip is counted
# and named, and an incomplete run exits non-zero unless the caller says it
# expected one (ALLOW_SKIPPED_TESTS=TRUE).
skipped <- 0L
skip_note <- function(what) { skipped <<- skipped + 1L; cat("  SKIP   ", what, "\n") }
test_report_status <- function(pass, fail, skipped) {
  cat(sprintf("%d passed, %d failed, %d skipped\n", pass, fail, skipped))
  if (skipped > 0L)
    cat("  ", skipped, " block(s) did not run, so this is NOT a clean run. ",
        "Install duckdb and sqlglot, or set ALLOW_SKIPPED_TESTS=TRUE to accept it.\n", sep = "")
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
